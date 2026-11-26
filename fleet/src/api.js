'use strict';

const crypto = require('node:crypto');
const ids = require('./ids');
const commands = require('./commands');
const { presence } = require('./store');

const API_PREFIX = '/api/v1';
const OPENAPI_VERSION = [3, 1, 0].join('.');
const MAX_JSON = 16 * 1024;
const RATE_WINDOW_MS = 60_000;
const RATE_LIMIT = 120;
const RATE_BUCKETS = 2048;
const ACTIONS = new Set(['start', 'stop', 'restart', 'update', 'reboot', 'log']);
const SETUP_FIELDS = new Set(['wallet', 'pool', 'coin', 'mode', 'threads', 'worker', 'maxtemp']);

function json(response, status, body, headers = {}) {
  const payload = Buffer.from(JSON.stringify(body));
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff',
    'content-length': payload.length,
    ...headers,
  });
  response.end(payload);
}

function fail(response, status, code, message, headers = {}) {
  json(response, status, { ok: false, error: { code, message } }, headers);
}

function openapi() {
  return {
    openapi: OPENAPI_VERSION,
    info: {
      title: 'ZMRIG Fleet API',
      version: 'v1',
      description: 'Operator API for reading rig status and queueing validated commands. All control changes are queued until a rig checks in.',
    },
    servers: [{ url: '/' }],
    security: [{ FleetBearer: [] }],
    paths: {
      '/api/v1/audit': {
        get: {
          operationId: 'listAuditEvents',
          summary: 'List recent operator actions',
          parameters: [{ name: 'limit', in: 'query', schema: { type: 'integer', minimum: 1, maximum: 100, default: 50 } }],
          responses: { '200': { description: 'Recent actions without command payloads', content: { 'application/json': { schema: { type: 'object', properties: { ok: { const: true }, items: { type: 'array', items: { $ref: '#/components/schemas/AuditEvent' } } }, required: ['ok', 'items'] } } } }, '401': { $ref: '#/components/responses/Unauthorized' } },
        },
      },
      '/api/v1/devices': {
        get: {
          operationId: 'listDevices',
          summary: 'List enrolled rigs',
          parameters: [
            { name: 'limit', in: 'query', schema: { type: 'integer', minimum: 1, maximum: 100, default: 50 } },
            { name: 'after', in: 'query', schema: { type: 'string', pattern: '^ZMR-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}$' } },
          ],
          responses: { '200': { description: 'A page of enrolled rigs', content: { 'application/json': { schema: { $ref: '#/components/schemas/DevicePage' } } } }, '401': { $ref: '#/components/responses/Unauthorized' } },
        },
      },
      '/api/v1/devices/{id}': {
        get: {
          operationId: 'getDevice',
          summary: 'Read one enrolled rig',
          parameters: [{ name: 'id', in: 'path', required: true, schema: { type: 'string' } }],
          responses: { '200': { description: 'Rig status without device credentials', content: { 'application/json': { schema: { type: 'object', properties: { ok: { const: true }, device: { $ref: '#/components/schemas/Device' } }, required: ['ok', 'device'] } } } }, '404': { $ref: '#/components/responses/NotFound' } },
        },
      },
      '/api/v1/devices/{id}/commands': {
        post: {
          operationId: 'queueDeviceCommand',
          summary: 'Queue a validated action or setup change',
          parameters: [{ name: 'id', in: 'path', required: true, schema: { type: 'string' } }],
          requestBody: { required: true, content: { 'application/json': { schema: { $ref: '#/components/schemas/CommandRequest' } } } },
          responses: { '202': { description: 'Command queued for the next check-in', content: { 'application/json': { schema: { type: 'object', properties: { ok: { const: true }, status: { const: 'queued' }, command_id: { type: 'string' }, device_id: { type: 'string' }, applies: { const: 'next_checkin' } }, required: ['ok', 'status', 'command_id', 'device_id', 'applies'] } } } }, '400': { $ref: '#/components/responses/BadRequest' }, '401': { $ref: '#/components/responses/Unauthorized' }, '404': { $ref: '#/components/responses/NotFound' }, '409': { description: 'The device command queue is full' } },
        },
      },
      '/api/v1/openapi.json': {
        get: { operationId: 'getOpenApi', summary: 'Get this OpenAPI 3.1 contract', security: [], responses: { '200': { description: 'OpenAPI document' } } },
      },
    },
    components: {
      securitySchemes: { FleetBearer: { type: 'http', scheme: 'bearer', bearerFormat: 'opaque API token' } },
      schemas: {
        Device: {
          type: 'object',
          properties: {
            id: { type: 'string' }, label: { type: 'string' }, presence: { enum: ['online', 'offline', 'waiting'] },
            last_seen: { type: ['integer', 'null'] }, config_version: { type: 'integer' }, queued_commands: { type: 'integer' },
            status: { type: 'object', additionalProperties: true },
          },
          required: ['id', 'label', 'presence', 'config_version', 'queued_commands', 'status'],
        },
        DevicePage: { type: 'object', properties: { ok: { const: true }, items: { type: 'array', items: { $ref: '#/components/schemas/Device' } }, next_cursor: { type: ['string', 'null'] }, total: { type: 'integer' } }, required: ['ok', 'items', 'next_cursor', 'total'] },
        AuditEvent: { type: 'object', properties: { at: { type: 'integer' }, actor: { type: 'string' }, action: { type: 'string' }, device_id: { type: ['string', 'null'] } }, required: ['at', 'actor', 'action', 'device_id'] },
        CommandRequest: {
          oneOf: [
            { type: 'object', properties: { command: { enum: ['start', 'stop', 'restart', 'update', 'reboot', 'log'] }, args: { type: 'object', additionalProperties: false, properties: { lines: { type: 'integer', minimum: 5, maximum: 80 } } } }, required: ['command'], additionalProperties: false },
            { type: 'object', properties: { command: { const: 'setup' }, args: { type: 'object', additionalProperties: false, properties: { wallet: { type: 'string', maxLength: 106 }, pool: { type: 'string', maxLength: 200 }, coin: { enum: Object.keys(commands.COINS) }, mode: { enum: Object.keys(commands.MODES) }, threads: { oneOf: [{ type: 'integer', minimum: 1, maximum: 199 }, { const: 'auto' }] }, worker: { type: 'string', pattern: '^[A-Za-z0-9_.-]{1,32}$' }, maxtemp: { type: 'integer', minimum: 45, maximum: 95 } } } }, required: ['command', 'args'], additionalProperties: false },
          ],
        },
      },
      responses: {
        Unauthorized: { description: 'Missing or invalid bearer token' },
        NotFound: { description: 'No enrolled rig with this ID' },
        BadRequest: { description: 'Invalid JSON or a field failed validation' },
      },
    },
  };
}

function readJson(request) {
  return new Promise((resolve, reject) => {
    const type = String(request.headers['content-type'] || '').split(';', 1)[0].trim().toLowerCase();
    if (type !== 'application/json') {
      const error = new Error('content-type must be application/json');
      error.status = 415;
      return reject(error);
    }
    const contentLength = Number(request.headers['content-length']);
    if (Number.isFinite(contentLength) && contentLength > MAX_JSON) {
      const error = new Error('request body exceeds 16 KiB');
      error.status = 413;
      request.resume();
      return reject(error);
    }
    let size = 0;
    const chunks = [];
    let finished = false;
    request.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_JSON) {
        finished = true;
        const error = new Error('request body exceeds 16 KiB');
        error.status = 413;
        reject(error);
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });
    request.on('end', () => {
      if (finished) return;
      try {
        const body = JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}');
        if (!body || typeof body !== 'object' || Array.isArray(body)) throw new Error('body must be a JSON object');
        resolve(body);
      } catch (error) {
        error.status = 400;
        reject(error);
      }
    });
    request.on('error', (error) => {
      if (!finished) reject(error);
    });
  });
}

function cleanStatus(status) {
  const copy = {};
  for (const [key, value] of Object.entries(status || {})) {
    if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean' || value === null) copy[key] = value;
  }
  return copy;
}

function deviceView(record, config, now) {
  return {
    id: record.id,
    label: record.label || '',
    presence: presence(record, config, now),
    last_seen: Number.isFinite(record.last_seen) ? record.last_seen : null,
    config_version: Number.isInteger(record.config_version) ? record.config_version : 0,
    queued_commands: Array.isArray(record.queue) ? record.queue.length : 0,
    status: cleanStatus(record.status),
  };
}

function setupCommand(args, record) {
  if (!args || typeof args !== 'object' || Array.isArray(args)) return { error: 'setup requires an args object' };
  const keys = Object.keys(args);
  if (keys.length === 0) return { error: 'setup args cannot be empty' };
  const unknown = keys.find((key) => !SETUP_FIELDS.has(key));
  if (unknown) return { error: `unsupported setup field: ${unknown}` };
  const result = {};
  const coin = args.coin ?? record.config?.coin ?? record.status?.coin ?? 'xmr';
  if (args.wallet !== undefined) {
    if (typeof args.wallet !== 'string' || commands.walletProblem(args.wallet, coin)) return { error: 'wallet is invalid for the selected coin' };
    result.wallet = args.wallet;
  }
  if (args.pool !== undefined) {
    if (typeof args.pool !== 'string' || !commands.validPool(args.pool)) return { error: 'pool must be a valid host:port or ws(s) URL' };
    result.pool = args.pool;
  }
  if (args.coin !== undefined) {
    if (typeof args.coin !== 'string' || !commands.COINS[args.coin.toLowerCase()]) return { error: 'coin is not supported' };
    result.coin = args.coin.toLowerCase();
  }
  if (args.mode !== undefined) {
    if (typeof args.mode !== 'string' || !commands.MODES[args.mode.toLowerCase()]) return { error: 'mode is not supported' };
    result.mode = args.mode.toLowerCase();
  }
  if (args.threads !== undefined) {
    if (!(args.threads === 'auto' || (Number.isInteger(args.threads) && args.threads >= 1 && args.threads <= 199))) return { error: 'threads must be an integer from 1 to 199, or "auto"' };
    result.threads = String(args.threads);
  }
  if (args.worker !== undefined) {
    if (typeof args.worker !== 'string' || !/^[\w.-]{1,32}$/.test(args.worker)) return { error: 'worker must be 1-32 letters, digits, dot, dash or underscore' };
    result.worker = args.worker;
  }
  if (args.maxtemp !== undefined) {
    const mode = result.mode ?? record.config?.mode ?? record.status?.mode ?? 'max';
    if (!Number.isInteger(args.maxtemp) || args.maxtemp < 45 || args.maxtemp > 95) return { error: 'maxtemp must be an integer from 45 to 95 C' };
    if (mode !== 'safe') return { error: 'maxtemp is only effective in safe mode; include mode: "safe"' };
    result.maxtemp = args.maxtemp;
  }
  return { command: { cmd: 'setup', args: result } };
}

function createApi({ config, store, now = () => Date.now() }) {
  const buckets = new Map();
  const contract = Buffer.from(JSON.stringify(openapi()));

  function limited(request, response) {
    const address = request.socket.remoteAddress || 'unknown';
    const stamp = now();
    let bucket = buckets.get(address);
    if (!bucket || stamp - bucket.since >= RATE_WINDOW_MS) bucket = { since: stamp, count: 0 };
    bucket.count += 1;
    buckets.delete(address);
    buckets.set(address, bucket);
    while (buckets.size > RATE_BUCKETS) buckets.delete(buckets.keys().next().value);
    if (bucket.count <= RATE_LIMIT) return false;
    fail(response, 429, 'rate_limited', 'API request rate exceeded; retry after the current minute.', { 'retry-after': String(Math.max(1, Math.ceil((RATE_WINDOW_MS - (stamp - bucket.since)) / 1000))) });
    return true;
  }

  function authenticated(request) {
    const token = config.api_token;
    if (!token) return false;
    const match = /^Bearer\s+(.+)$/i.exec(String(request.headers.authorization || '').trim());
    if (!match) return false;
    const actual = crypto.createHash('sha256').update(match[1]).digest();
    const expected = crypto.createHash('sha256').update(token).digest();
    return crypto.timingSafeEqual(actual, expected);
  }

  return async function handleApi(request, response, url = new URL(request.url, 'http://localhost')) {
    const pathname = url.pathname;
    if (pathname === `${API_PREFIX}/openapi.json` && request.method === 'GET') {
      return json(response, 200, JSON.parse(contract.toString('utf8')), { 'cache-control': 'public, max-age=300' });
    }
    if (!pathname.startsWith(`${API_PREFIX}/`)) return false;
    if (typeof config.api_token !== 'string' || config.api_token.length < 32) return fail(response, 404, 'not_found', 'API is not enabled or the configured token is too short.');
    if (limited(request, response)) return true;
    if (!authenticated(request)) return fail(response, 401, 'unauthorized', 'A valid bearer API token is required.', { 'www-authenticate': 'Bearer realm="zmrig-fleet-api"' });

    if (!['GET', 'POST'].includes(request.method)) {
      return fail(response, 405, 'method_not_allowed', 'Use GET or POST.', { allow: 'GET, POST' });
    }

    if (pathname === `${API_PREFIX}/audit`) {
      if (request.method !== 'GET') return fail(response, 405, 'method_not_allowed', 'Use GET for this resource.', { allow: 'GET' });
      const rawLimit = url.searchParams.get('limit');
      const limit = rawLimit === null ? 50 : Number(rawLimit);
      if (!Number.isInteger(limit) || limit < 1 || limit > 100) return fail(response, 400, 'invalid_limit', 'limit must be an integer from 1 to 100.');
      const items = store.recent(limit).map((event) => ({
        at: event.at,
        actor: String(event.actor || 'unknown'),
        action: String(event.action || 'unknown'),
        device_id: event.device || null,
      }));
      return json(response, 200, { ok: true, items });
    }

    if (pathname === `${API_PREFIX}/devices`) {
      if (request.method !== 'GET') return fail(response, 405, 'method_not_allowed', 'Use GET for this resource.', { allow: 'GET' });
      const rawLimit = url.searchParams.get('limit');
      const limit = rawLimit === null ? 50 : Number(rawLimit);
      if (!Number.isInteger(limit) || limit < 1 || limit > 100) return fail(response, 400, 'invalid_limit', 'limit must be an integer from 1 to 100.');
      const after = url.searchParams.get('after') || '';
      if (after && !ids.isDeviceId(after.toUpperCase())) return fail(response, 400, 'invalid_cursor', 'after must be a full Device ID.');
      const devices = store.devices().filter((item) => Boolean(item.owner)).sort((a, b) => a.id.localeCompare(b.id));
      const remaining = devices.filter((item) => item.id > after.toUpperCase());
      const selected = remaining.slice(0, limit);
      const next = remaining.length > selected.length ? selected[selected.length - 1].id : null;
      return json(response, 200, { ok: true, items: selected.map((item) => deviceView(item, config, now())), next_cursor: next, total: devices.length });
    }

    const detail = new RegExp(`^${API_PREFIX}/devices/([^/]+)$`).exec(pathname);
    if (detail) {
      if (request.method !== 'GET') return fail(response, 405, 'method_not_allowed', 'Use GET for this resource.', { allow: 'GET' });
      let id;
      try { id = decodeURIComponent(detail[1]).toUpperCase(); } catch { return fail(response, 400, 'invalid_id', 'Device ID is not valid URL encoding.'); }
      if (!ids.isDeviceId(id)) return fail(response, 400, 'invalid_id', 'A full Device ID is required.');
      const record = store.get(id);
      if (!record || !record.owner) return fail(response, 404, 'device_not_found', 'No enrolled device with this ID.');
      return json(response, 200, { ok: true, device: deviceView(record, config, now()) });
    }

    const commandRoute = new RegExp(`^${API_PREFIX}/devices/([^/]+)/commands$`).exec(pathname);
    if (commandRoute) {
      if (request.method !== 'POST') return fail(response, 405, 'method_not_allowed', 'Use POST to queue a command.', { allow: 'POST' });
      let id;
      try { id = decodeURIComponent(commandRoute[1]).toUpperCase(); } catch { return fail(response, 400, 'invalid_id', 'Device ID is not valid URL encoding.'); }
      if (!ids.isDeviceId(id)) return fail(response, 400, 'invalid_id', 'A full Device ID is required.');
      const record = store.get(id);
      if (!record || !record.owner) return fail(response, 404, 'device_not_found', 'No enrolled device with this ID.');

      let body;
      try { body = await readJson(request); } catch (error) {
        const status = error.status || 400;
        const code = status === 413 ? 'payload_too_large' : status === 415 ? 'unsupported_media_type' : 'invalid_json';
        return fail(response, status, code, error.message || 'Request body is invalid.');
      }
      if (Object.keys(body).some((key) => !['command', 'args'].includes(key))) return fail(response, 400, 'unknown_field', 'Only command and args are accepted.');
      if (typeof body.command !== 'string') return fail(response, 400, 'invalid_command', 'command must be a string.');

      let entry;
      if (body.command === 'setup') {
        const result = setupCommand(body.args, record);
        if (result.error) return fail(response, 400, 'invalid_setup', result.error);
        entry = result.command;
      } else if (ACTIONS.has(body.command)) {
        let args;
        if (body.command === 'log') {
          const logArgs = body.args || {};
          if (!logArgs || typeof logArgs !== 'object' || Array.isArray(logArgs) || Object.keys(logArgs).some((key) => key !== 'lines')) return fail(response, 400, 'invalid_args', 'log accepts only an optional integer lines value from 5 to 80.');
          const lines = logArgs.lines === undefined ? 40 : logArgs.lines;
          if (!Number.isInteger(lines) || lines < 5 || lines > 80) return fail(response, 400, 'invalid_args', 'log lines must be an integer from 5 to 80.');
          args = { lines };
        } else if (body.args !== undefined && (!body.args || typeof body.args !== 'object' || Array.isArray(body.args) || Object.keys(body.args).length > 0)) {
          return fail(response, 400, 'invalid_args', `${body.command} does not accept arguments.`);
        }
        entry = { cmd: body.command, ...(args ? { args } : {}) };
      } else {
        return fail(response, 400, 'invalid_command', 'Supported commands: start, stop, restart, update, reboot, log, setup.');
      }

      const queued = store.push(id, entry, config.queue_limit || 10);
      if (!queued) return fail(response, 409, 'queue_full', 'The rig command queue is full. Wait for its next check-in before retrying.');
      store.audit({ actor: 'api', action: entry.cmd === 'setup' ? `setup:${Object.keys(entry.args).sort().join(',')}` : entry.cmd, device: id });
      return json(response, 202, { ok: true, status: 'queued', command_id: queued.id, device_id: id, applies: 'next_checkin' });
    }

    return fail(response, 404, 'not_found', 'No API route matches this path.');
  };
}

module.exports = { createApi, openapi, setupCommand };

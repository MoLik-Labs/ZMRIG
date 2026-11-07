// The device-facing side: one endpoint, one credential, no sessions.
//
//   POST /v1/hello        a rig checks in and receives whatever was queued
//   GET  /healthz         for the host's health check
//   GET  /                a page a person can open without reading JSON
//
// The rig authenticates with the key it generated for itself. The server derives
// the Device ID from that key, so a stolen ID is worth nothing without the key,
// and the key never travels anywhere except over TLS to this endpoint.

'use strict';

const http = require('node:http');
const ids = require('./ids');
const format = require('./format');
const alerts = require('./alerts');
const { presence } = require('./store');
const { createWeb } = require('./web');

const MAX_BODY = 64 * 1024;

function json(response, status, body) {
  const payload = JSON.stringify(body);
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(payload),
    'cache-control': 'no-store',
  });
  response.end(payload);
}

function readBody(request) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    request.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY) {
        reject(new Error('body too large'));
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });
    request.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    request.on('error', reject);
  });
}

function bearer(request) {
  const header = request.headers.authorization || '';
  const match = /^Bearer\s+([0-9a-fA-F]{64})$/.exec(header.trim());
  if (match) return match[1].toLowerCase();
  return null;
}

function cleanStatus(status) {
  if (!status || typeof status !== 'object') return {};
  const keep = ['state', 'hashrate', 'measured', 'temp', 'maxtemp', 'uptime', 'mode', 'wallet', 'pool', 'worker', 'coin', 'threads', 'version', 'slot', 'installed', 'reason'];
  const out = {};
  for (const key of keep) {
    const value = status[key];
    if (value === undefined || value === null) continue;
    if (typeof value === 'string') out[key] = value.slice(0, 256);
    else if (typeof value === 'number' && Number.isFinite(value)) out[key] = value;
    else if (typeof value === 'boolean') out[key] = value;
  }
  return out;
}

function cleanAcks(acks) {
  if (!Array.isArray(acks)) return [];
  return acks.slice(0, 20).map((ack) => ({
    id: String(ack && ack.id || '').slice(0, 32),
    cmd: String(ack && ack.cmd || '').slice(0, 32),
    ok: Boolean(ack && ack.ok),
    detail: String(ack && ack.detail || '').slice(0, 200),
  }));
}

/**
 * The device-facing request handler, on its own.
 *
 * `createServer` below is this handler plus an `http.Server`; the unified host
 * (host/server.js on Render) is this handler plus the documentation site in one
 * socket. Splitting them is what lets one process and one instance hour do both
 * jobs instead of paying for two services that each answer on their own port.
 *
 * `fallthrough` is called for anything the fleet does not own (only `/v1/*`,
 * `/healthz` and, when a password is set, the dashboard). Without it the
 * handler answers 404, which is the standalone behaviour.
 */
function createHandler({
  config,
  store,
  log = () => {},
  now = () => Date.now(),
  onEvent = () => {},
  onCheckIn = () => {},
  releases = null,
  roster = null,
  dashboard = true,
  fallthrough = null,
}) {
  const lastHello = new Map();
  // Null when no password is configured: the dashboard is opt-in, and a bot-only
  // host has no HTML surface at all.
  const web = dashboard ? createWeb({ config, store, log, releases, now, roster }) : null;

  const handler = async function handle(request, response) {
    const url = new URL(request.url, 'http://localhost');

    if (url.pathname === '/healthz') return json(response, 200, { ok: true, up: true });

    // The dashboard owns everything that is not the device protocol or the
    // health check, including `/`.
    if (url.pathname !== '/v1/hello') {
      if (web) {
        await web.handle(request, response);
        return;
      }
      if (fallthrough) {
        await fallthrough(request, response);
        return;
      }
      if (url.pathname === '/' && request.method === 'GET' && !web) return page(response, store, config, now());
      return json(response, 404, { ok: false, error: 'not found' });
    }

    if (request.method !== 'POST') return json(response, 405, { ok: false, error: 'use POST' });

    const secret = bearer(request);
    if (!secret) return json(response, 401, { ok: false, error: 'missing device key' });

    let body;
    try {
      body = JSON.parse(await readBody(request) || '{}');
    } catch (error) {
      return json(response, 400, { ok: false, error: `unreadable body: ${error.message}` });
    }

    const claimedId = ids.deviceId(secret);
    if (body.device && String(body.device).toUpperCase() !== claimedId) {
      // The key and the claimed ID disagree: either a typo or someone holding
      // one rig's key trying to speak for another.
      return json(response, 403, { ok: false, error: 'the device key does not match the device id' });
    }

    const existing = store.get(claimedId);

    // A rig the roster named before it ever checked in. The roster knows the
    // Device ID and not the key - it cannot, the key never leaves the machine -
    // so the first secret that hashes to that ID binds the record, and every
    // later request is held to it exactly as if the rig had enrolled itself.
    // Landing on the ID at all is 48 bits of proof; nobody types their way in.
    if (existing && !existing.secret_hash && existing.roster) {
      existing.secret_hash = ids.sha256(secret);
      existing.code = ids.enrolCode(secret);
      store.touch();
    }

    if (existing && !ids.verifySecret(secret, existing)) {
      return json(response, 403, { ok: false, error: 'device key rejected' });
    }

    // A key nobody has enrolled still gets a record, and that is the door a
    // stranger can walk through with curl: random 64-hex tokens, one record
    // each, each one a full rewrite of the state file. Enrolment is what makes
    // a device worth keeping, so the unenrolled ones are bounded and expire.
    const stamp = now();
    // A rig the roster names is expected, so its record is created even when the
    // door is full: the operator has already decided this machine is theirs.
    const expected = Boolean(roster && roster.rigs && roster.rigs.has(claimedId));
    if (!existing && !expected) {
      const { unowned_limit: limit = 200, unowned_ttl: ttl = 86400 } = config;
      if (ttl > 0) store.pruneUnowned(ttl * 1000, stamp);
      const evicted = store.makeRoom(limit, stamp);
      if (evicted) log(`hello ${claimedId}: evicted ${evicted} unenrolled device(s) to stay under ${limit}`);
    }

    const record = store.claim(secret, { address: request.socket.remoteAddress });

    // A check-in every second is a loop that forgot to sleep, not a fleet.
    const last = lastHello.get(record.id) || 0;
    if (stamp - last < 2000) {
      return json(response, 429, { ok: false, error: 'too frequent', interval: config.interval });
    }
    lastHello.set(record.id, stamp);

    const before = { ...(record.status || {}) };
    record.status = cleanStatus(body.status);
    record.status.state = record.status.state || 'unknown';
    record.last_seen = stamp;

    const acks = cleanAcks(body.acks);
    if (acks.length) {
      alerts.onAcks(record, acks, stamp).forEach((event) => onEvent(event, record));
      record.acks = record.acks.slice(0, 0);
    }

    if (record.want_log && typeof body.log === 'string') {
      record.log = body.log.slice(0, 8000);
      record.log_at = stamp;
      record.want_log = false;
    }

    const events = alerts.onHello(record, config, stamp, before);
    events.forEach((event) => onEvent(event, record));

    // Last thing before the queue is emptied: compare what the roster says this
    // rig should be with what it just said it is, and queue the difference. A
    // restart of this process changes nothing, because nothing was remembered.
    // A failure here must never cost a check-in its answer, so it is contained.
    try {
      onCheckIn(record, stamp);
    } catch (error) {
      log(`check-in hook: ${error.message}`);
    }

    const enrolled = Boolean(record.owner);
    const commands = enrolled ? store.take(record.id) : [];

    store.touch();
    log(`hello ${record.id} ${record.status.state} ${enrolled ? '' : '(unclaimed)'}`);

    return json(response, 200, {
      ok: true,
      enrolled,
      interval: config.interval,
      config_version: record.config_version || 0,
      commands: commands.map((command) => ({ id: command.id, cmd: command.cmd, ...(command.args || {}) })),
      server_time: stamp,
    });
  };

  // The dashboard object (or null) rides on the function, so a caller that wants
  // to mount it elsewhere can, and `createServer` can keep reporting it.
  handler.web = web;

  return handler;
}

/** The standalone façade: one handler, one port. */
function createServer(options) {
  const handler = createHandler(options);
  const server = http.createServer(handler);

  server.on('clientError', (error, socket) => {
    if (socket.writable) socket.end('HTTP/1.1 400 Bad Request\r\n\r\n');
  });

  return { server, web: handler.web };
}

function escape(text) {
  return String(text).replace(/[&<>"]/g, (character) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[character]));
}

/** Deliberately boring: a green page with counts, and nothing that identifies a
 *  wallet or an address. It exists so the URL is not a 404 when somebody checks
 *  whether the service is up. */
function page(response, store, config, now) {
  const devices = store.devices();
  const online = devices.filter((device) => presence(device, config, now) === 'online');
  const enrolled = devices.filter((device) => device.owner);
  let total = 0;
  for (const device of online) total += Number(device.status && device.status.hashrate) || 0;

  const rows = devices
    .filter((device) => device.owner)
    .map((device) => {
      const state = presence(device, config, now);
      return `<tr><td>${escape(device.label || device.id)}</td><td>${escape(state)}</td><td>${escape(
        format.hashrate(device.status && device.status.hashrate),
      )}</td><td>${escape(format.ago(device.last_seen, now))}</td></tr>`;
    })
    .join('');

  const body = `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>ZMRIG fleet</title>
<style>
:root{color-scheme:light dark}
body{font:15px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;margin:0;padding:2rem;max-width:52rem}
h1{font-size:1.1rem;letter-spacing:.08em;text-transform:uppercase;opacity:.7;font-weight:600}
table{border-collapse:collapse;width:100%}
td,th{text-align:left;padding:.35rem .8rem .35rem 0;border-bottom:1px solid rgba(128,128,128,.25)}
.big{font-size:2rem;font-weight:600;margin:0}
.note{opacity:.6;margin-top:2rem}
</style></head><body>
<h1>ZMRIG fleet</h1>
<p class="big">${escape(format.hashrate(total))}</p>
<p>${online.length} of ${enrolled.length} rig${enrolled.length === 1 ? '' : 's'} checking in.</p>
<table><thead><tr><th>rig</th><th>state</th><th>hashrate</th><th>seen</th></tr></thead>
<tbody>${rows || '<tr><td colspan="4">no rigs enrolled yet</td></tr>'}</tbody></table>
<p class="note">Control is the bot: enrol a rig with <code>/enroll &lt;device id&gt; &lt;code&gt;</code>.</p>
</body></html>`;

  response.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
  response.end(body);
}

module.exports = { createServer, createHandler, cleanStatus, cleanAcks, bearer };

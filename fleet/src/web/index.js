// The dashboard: a router, a login, and a cache.
//
// The rules that matter here:
//
//   * nothing is served without a valid signed cookie, except the login page and
//     the two static files it needs;
//   * every form carries a CSRF token that came out of that cookie, and a POST
//     without one is refused before anything is read;
//   * every mutation is validated by the same helpers the bot uses and lands in
//     the same queue, so the two front ends cannot drift;
//   * a rendered page is cached against `store.revision`, so a browser that
//     refreshes twice costs one template evaluation, not two;
//   * a POST always answers with a redirect, and the message travels in the
//     query string, so a refresh cannot resubmit a form.

'use strict';

const crypto = require('node:crypto');
const zlib = require('node:zlib');

const { Sessions } = require('./session');
const { page, login } = require('./layout');
const { CSS, JS } = require('./theme');
const screens = require('./pages');
const commands = require('../commands');

const MAX_FORM = 16 * 1024;
const LOGIN_WINDOW = 15 * 60 * 1000;
const LOGIN_LIMIT = 10;
const CACHE_ENTRIES = 256;

const SECURITY = {
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'no-referrer',
  'X-Frame-Options': 'DENY',
  'Cross-Origin-Opener-Policy': 'same-origin',
  'Content-Security-Policy':
    "default-src 'none'; style-src 'self' 'unsafe-inline'; script-src 'self'; img-src 'self' data:; " +
    "form-action 'self'; base-uri 'none'; frame-ancestors 'none'; connect-src 'self'",
};

const ACTIONS = ['start', 'stop', 'restart', 'update', 'log', 'reboot'];

function sha(text) {
  return crypto.createHash('sha256').update(String(text)).digest('hex');
}

function readForm(request, limit = MAX_FORM) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    request.on('data', (chunk) => {
      size += chunk.length;
      if (size > limit) {
        reject(new Error('too large'));
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });
    request.on('end', () => {
      const text = Buffer.concat(chunks).toString('utf8');
      if (String(request.headers['content-type'] || '').includes('application/json')) {
        try {
          resolve(JSON.parse(text || '{}'));
        } catch {
          reject(new Error('bad json'));
        }
        return;
      }
      resolve(Object.fromEntries(new URLSearchParams(text)));
    });
    request.on('error', reject);
  });
}

/** Every field the setup form may carry, in the order they are applied. */
const SETUP_FIELDS = ['wallet', 'pool', 'coin', 'mode', 'threads', 'worker', 'maxtemp'];

function createWeb({ config, store, releases = null, log = () => {}, now = () => Date.now(), roster = null }) {
  if (!config.web_enabled || !config.web_password) return null;

  const sessions = new Sessions({ password: config.web_password, now });
  const assets = new Map([
    ['/assets/app.css', { body: Buffer.from(CSS), type: 'text/css; charset=utf-8' }],
    ['/assets/app.js', { body: Buffer.from(JS), type: 'text/javascript; charset=utf-8' }],
  ]);
  for (const entry of assets.values()) {
    entry.etag = `"${sha(entry.body).slice(0, 20)}"`;
    entry.br = zlib.brotliCompressSync(entry.body, { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 9 } });
    entry.gz = zlib.gzipSync(entry.body, { level: 9 });
  }

  /** ip -> how many wrong passwords, since when, blocked until */
  const attempts = new Map();
  /** what a GET renders, keyed by everything it depends on */
  const cache = new Map();

  function clientIp(request) {
    const forwarded = String(request.headers['x-forwarded-for'] || '').split(',')[0].trim();
    return forwarded || request.socket.remoteAddress || 'unknown';
  }

  function isSecure(request) {
    return Boolean(request.socket.encrypted) || String(request.headers['x-forwarded-proto'] || '') === 'https';
  }

  function negotiate(entry, request) {
    const accept = String(request.headers['accept-encoding'] || '').toLowerCase();
    if (entry.body.length >= 512) {
      if (entry.br && /\bbr\b|\*/.test(accept)) return { body: entry.br, encoding: 'br' };
      if (entry.gz && /\bgzip\b|\*/.test(accept)) return { body: entry.gz, encoding: 'gzip' };
    }
    return { body: entry.body, encoding: null };
  }

  function send(request, response, status, entry, extraHeaders = {}) {
    const chosen = negotiate(entry, request);
    const headers = {
      ...SECURITY,
      'content-type': entry.type,
      'cache-control': entry.cache || 'private, no-store',
      vary: 'Accept-Encoding',
      ...extraHeaders,
    };
    if (entry.etag) headers.etag = entry.etag;
    if (chosen.encoding) headers['content-encoding'] = chosen.encoding;
    headers['content-length'] = chosen.body.length;

    const noneMatch = request.headers['if-none-match'];
    if (noneMatch && entry.etag && noneMatch.split(',').some((tag) => tag.trim() === entry.etag)) {
      delete headers['content-length'];
      delete headers['content-encoding'];
      response.writeHead(304, headers);
      response.end();
      return;
    }

    response.writeHead(status, headers);
    response.end(request.method === 'HEAD' ? undefined : chosen.body);
  }

  function html(request, response, status, markup) {
    const body = Buffer.from(markup);
    send(request, response, status, {
      body,
      type: 'text/html; charset=utf-8',
      cache: 'private, no-store',
      etag: null,
      br: null,
      gz: null,
    });
  }

  function redirect(response, location, cookie = null) {
    const headers = { ...SECURITY, location, 'cache-control': 'no-store', 'content-length': 0 };
    if (cookie) headers['set-cookie'] = cookie;
    response.writeHead(303, headers);
    response.end();
  }

  /** Rendered pages keyed on everything they are a function of. */
  function rendered(key, produce) {
    const hit = cache.get(key);
    if (hit) return hit;
    const body = Buffer.from(produce());
    const entry = {
      body,
      type: 'text/html; charset=utf-8',
      cache: 'private, no-store',
      etag: `"${sha(body).slice(0, 20)}"`,
      br: zlib.brotliCompressSync(body, { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 9 } }),
      gz: zlib.gzipSync(body, { level: 9 }),
    };
    cache.set(key, entry);
    while (cache.size > CACHE_ENTRIES) cache.delete(cache.keys().next().value);
    return entry;
  }

  // ------------------------------------------------------------------- auth

  function throttle(ip) {
    const record = attempts.get(ip);
    if (!record) return 0;
    if (record.blockedUntil > now()) return Math.ceil((record.blockedUntil - now()) / 1000);
    return 0;
  }

  function noteFailure(ip) {
    const stamp = now();
    const record = attempts.get(ip) || { failed: 0, since: stamp, blockedUntil: 0 };
    if (stamp - record.since > LOGIN_WINDOW) {
      record.failed = 0;
      record.since = stamp;
    }
    record.failed += 1;
    if (record.failed >= LOGIN_LIMIT) {
      record.blockedUntil = stamp + LOGIN_WINDOW;
      log(`web: ${ip} blocked after ${record.failed} wrong passwords`);
    }
    attempts.set(ip, record);
    if (attempts.size > 2000) attempts.delete(attempts.keys().next().value);
  }

  async function handleLogin(request, response) {
    const ip = clientIp(request);
    const wait = throttle(ip);
    if (wait) {
      html(request, response, 429, login({ error: `too many attempts. Try again in ${Math.ceil(wait / 60)} minutes.` }));
      return;
    }

    const form = await readForm(request).catch(() => ({}));
    if (!sessions.check(form.password || '')) {
      noteFailure(ip);
      log(`web: wrong password from ${ip}`);
      html(request, response, 401, login({ error: 'wrong password.' }));
      return;
    }

    attempts.delete(ip);
    const { token } = sessions.issue();
    const next = typeof form.next === 'string' && form.next.startsWith('/') && !form.next.startsWith('//') ? form.next : '/';
    redirect(response, next, sessions.cookie(token, { secure: isSecure(request) }));
  }

  // ---------------------------------------------------------------- routes

  async function handle(request, response) {
    const url = new URL(request.url, 'http://localhost');
    const path = url.pathname;
    const method = request.method || 'GET';

    if (!['GET', 'HEAD', 'POST'].includes(method)) {
      response.writeHead(405, { ...SECURITY, allow: 'GET, HEAD, POST', 'content-length': 0 });
      response.end();
      return;
    }

    // The two static files are the only things served before a login: the login
    // page needs them, and they hold no fleet data.
    const asset = assets.get(path);
    if (asset) {
      send(request, response, 200, { ...asset, cache: 'public, max-age=31536000, immutable' });
      return;
    }

    if (path === '/login') {
      if (method !== 'POST') {
        if (sessions.from(request)) return redirect(response, '/');
        html(request, response, 200, login({ publicUrl: config.public_url }));
        return;
      }
      await handleLogin(request, response);
      return;
    }

    const session = sessions.from(request);

    if (!session) {
      // The front door is the login page itself; everywhere else is a redirect,
      // except a POST, which is answered with the form a person needs.
      if (method === 'POST') {
        html(request, response, 200, login({ error: 'sign in first.' }));
        return;
      }
      if (path === '/' || path === '') {
        html(request, response, 200, login({ publicUrl: config.public_url }));
        return;
      }
      redirect(response, '/login');
      return;
    }

    if (path === '/logout') {
      // Signing out is not a state change anybody can be tricked into caring
      // about, so it needs no CSRF token: the worst case is being signed out.
      redirect(response, '/login', sessions.clear({ secure: isSecure(request) }));
      return;
    }

    if (method === 'POST') {
      const form = await readForm(request).catch(() => null);
      if (!form) {
        html(request, response, 400, page({ title: 'Bad request', body: '<h1>Bad request</h1><p>That form could not be read.</p>', csrf: session.csrf }));
        return;
      }
      if (!form.csrf || form.csrf !== session.csrf) {
        log(`web: CSRF refusal on ${path} from ${clientIp(request)}`);
        html(request, response, 403, page({
          title: 'Refused',
          body: `<h1>Refused</h1><p>That form did not carry a valid token. Reload the page and try again.</p>`,
          csrf: session.csrf,
        }));
        return;
      }
      await handlePost(request, response, path, form, session);
      return;
    }

    await handleGet(request, response, path, url, session);
  }

  async function handlePost(request, response, path, form, session) {
    if (path === '/enrol') {
      const id = String(form.id || '').trim().toUpperCase();
      const code = String(form.code || '').trim();
      const label = String(form.label || '').trim().slice(0, 40);

      const result = commands.route(
        { text: `/enroll ${id} ${code}${label ? ` ${label}` : ''}`, platform: 'web' },
        { store, config, actor: { key: config.admins[0] || 'web:operator', platform: 'web', role: 'admin' }, now: now() },
      );

      if (result.text.startsWith('⚠️')) {
        redirect(response, `/enrol?err=${encodeURIComponent(result.text.replace(/^⚠️\s*/, '').replace(/\*\*/g, '').replace(/`/g, ''))}`);
        return;
      }

      const record = store.get(id);
      redirect(response, `/rig/${encodeURIComponent(record ? record.id : id)}?ok=${encodeURIComponent('enrolled; it is yours now.')}`);
      return;
    }

    const match = /^\/rig\/([^/]+)\/(action|setup|remove|rename)$/.exec(path);
    if (!match) {
      html(request, response, 404, page({ title: 'Not found', body: '<h1>Not found</h1>', csrf: session.csrf }));
      return;
    }

    const id = decodeURIComponent(match[1]).toUpperCase();
    const record = store.get(id);
    if (!record || !record.owner) {
      html(request, response, 404, page({ title: 'No such rig', body: '<h1>No such rig</h1><p>It may have been removed.</p>', csrf: session.csrf }));
      return;
    }

    if (match[2] === 'action') {
      const action = String(form.action || '');
      if (!ACTIONS.includes(action)) {
        redirect(response, `/rig/${encodeURIComponent(record.id)}?err=${encodeURIComponent(`unknown action: ${action}`)}`);
        return;
      }
      // The bot lets you ask for 5-80 lines; so does the form. A number out of
      // range is clamped rather than refused, because it is a display setting.
      const asked = Number.parseInt(form.lines, 10);
      const lines = Math.min(Math.max(Number.isFinite(asked) ? asked : config.log_lines || 40, 5), 80);
      const problem = queue(record, { cmd: action, args: action === 'log' ? { lines } : undefined }, 'web', action);
      const flashName = problem ? 'err' : 'ok';
      const message = problem || `${action} queued; it applies on the next check-in.`;
      redirect(response, `/rig/${encodeURIComponent(record.id)}?${flashName}=${encodeURIComponent(message)}`);
      return;
    }

    // A name lives on this side of the wire - the rig never learns it - so unlike
    // every other change it is applied immediately instead of queued.
    if (match[2] === 'rename') {
      const label = String(form.label || '').trim().slice(0, 40);
      if (!/^[\w .:-]{1,40}$/.test(label)) {
        redirect(response, `/rig/${encodeURIComponent(record.id)}?err=${encodeURIComponent('a name is 1-40 letters, digits, space, dot, colon or dash')}`);
        return;
      }
      record.label = label;
      store.touch();
      store.audit({ actor: 'web', action: 'rename', device: record.id });
      redirect(response, `/rig/${encodeURIComponent(record.id)}?ok=${encodeURIComponent(`renamed to ${label}`)}`);
      return;
    }

    if (match[2] === 'remove') {
      record.owner = null;
      record.claimed_at = null;
      store.touch();
      store.audit({ actor: 'web', action: 'remove', device: record.id });
      redirect(response, `/?ok=${encodeURIComponent(`forgot ${record.id}; the rig keeps mining.`)}`);
      return;
    }

    await handleSetup(request, response, record, form);
  }

  /** One form, one queued `setup`, so a wallet and the coin it belongs to are
   *  applied together instead of in two check-ins. */
  async function handleSetup(request, response, record, form) {
    const status = record.status || {};
    const args = {};
    const problems = [];

    for (const field of SETUP_FIELDS) {
      const raw = String(form[field] ?? '').trim();
      if (!raw) continue; // empty never means "clear"

      if (field === 'maxtemp') {
        const temperature = Number.parseInt(raw, 10);
        if (!Number.isFinite(temperature) || temperature < 45 || temperature > 95) {
          problems.push('the heat cap is 45-95 C');
          continue;
        }
        // Only meaningful with the thermal governor, and the governor only runs
        // in safe mode: queueing it otherwise would be a number with no effect.
        const mode = String(form.mode || status.mode || 'max');
        if (mode !== 'safe') {
          problems.push('the heat cap only applies in safe mode');
          continue;
        }
        args.maxtemp = temperature;
        continue;
      }

      if (field === 'coin') {
        if (!commands.COINS[raw.toLowerCase()]) {
          problems.push(`unknown coin "${raw}"`);
          continue;
        }
        args.coin = raw.toLowerCase();
        continue;
      }

      if (field === 'mode') {
        if (!commands.MODES[raw.toLowerCase()]) {
          problems.push(`unknown mode "${raw}"`);
          continue;
        }
        args.mode = raw.toLowerCase();
        continue;
      }

      if (field === 'threads') {
        if (raw !== 'auto' && !/^([1-9]|[1-9][0-9]|1[0-9][0-9])$/.test(raw)) {
          problems.push('threads is a number, or auto');
          continue;
        }
        args.threads = raw;
        continue;
      }

      if (field === 'worker') {
        if (!/^[\w.-]{1,32}$/.test(raw)) {
          problems.push('a worker name is 1-32 letters, digits, dot, dash or underscore');
          continue;
        }
        args.worker = raw;
        continue;
      }

      if (field === 'pool') {
        if (!commands.validPool(raw)) {
          problems.push('a pool is host:port');
          continue;
        }
        args.pool = raw;
        continue;
      }

      if (field === 'wallet') {
        const coin = args.coin || status.coin || 'xmr';
        if (!commands.validWallet(raw, coin)) {
          problems.push(coin === 'xmr'
            ? 'that is not a Monero address: 95 or 106 base58 characters starting with 4 or 8'
            : `that does not look like a ${coin} address`);
          continue;
        }
        args.wallet = raw;
        continue;
      }
    }

    // Only what actually differs: queueing the wallet that is already there
    // would restart the miner for nothing.
    const changed = {};
    for (const [key, value] of Object.entries(args)) {
      const current = key === 'maxtemp' ? record.config && record.config.maxtemp : status[key];
      if (String(current ?? '') !== String(value)) changed[key] = value;
    }

    if (problems.length) {
      redirect(response, `/rig/${encodeURIComponent(record.id)}?err=${encodeURIComponent(problems[0])}`);
      return;
    }

    if (!Object.keys(changed).length) {
      redirect(response, `/rig/${encodeURIComponent(record.id)}?err=${encodeURIComponent('nothing changed')}`);
      return;
    }

    const problem = queue(record, { cmd: 'setup', args: changed }, 'web', 'setup');
    if (problem) {
      redirect(response, `/rig/${encodeURIComponent(record.id)}?err=${encodeURIComponent(problem)}`);
      return;
    }

    record.config = { ...(record.config || {}), ...changed };
    store.touch();
    redirect(response, `/rig/${encodeURIComponent(record.id)}?ok=${encodeURIComponent(`queued: ${Object.keys(changed).join(', ')}`)}`);
  }

  /** The queue is shared with the bot, so the depth limit is the same one. */
  function queue(record, command, actor, action) {
    const entry = store.push(record.id, command, config.queue_limit || 10);
    if (!entry) return 'the queue for this rig is full; it has not checked in for a while';
    store.audit({ actor, action, device: record.id });
    return null;
  }

  async function handleGet(request, response, path, url, session) {
    const flash = {
      ok: url.searchParams.get('ok'),
      err: url.searchParams.get('err'),
      csrf: session.csrf,
    };

    const context = {
      store,
      config,
      now: now(),
      csrf: session.csrf,
      flash: flash.err || flash.ok,
      flashBad: Boolean(flash.err),
      // The dashboard shows what the roster pins so nobody spends an evening
      // fighting a value that is re-derived from the environment every minute.
      roster,
    };
    const plainPage = Boolean(flash.ok || flash.err);

    if (path === '/' || path === '') {
      if (plainPage) return html(request, response, 200, screens.dashboard(context));
      return send(request, response, 200, rendered(`/${store.revision}`, () => screens.dashboard(context)));
    }

    if (path === '/rigs') {
      if (plainPage) return html(request, response, 200, screens.rigs(context));
      return send(request, response, 200, rendered(`/rigs/${store.revision}`, () => screens.rigs(context)));
    }

    if (path === '/enrol') {
      html(request, response, 200, screens.enrol(context));
      return;
    }

    if (path === '/downloads') {
      const data = releases ? await releases.latest() : null;
      const record = { ...context, releases: data };
      if (plainPage) return html(request, response, 200, screens.downloads(record));
      return send(request, response, 200, rendered(`/downloads/${data && data.fetchedAt ? data.fetchedAt : 0}`, () => screens.downloads(record)));
    }

    if (path === '/docs') {
      if (plainPage) return html(request, response, 200, screens.docs(context));
      return send(request, response, 200, rendered('/docs', () => screens.docs(context)));
    }

    const match = /^\/rig\/([^/]+)\/?$/.exec(path);
    if (match) {
      const id = decodeURIComponent(match[1]).toUpperCase();
      const record = store.get(id);
      if (!record || !record.owner) {
        html(request, response, 404, page({ title: 'No such rig', body: '<h1>No such rig</h1><p>It may have been removed, or never enrolled.</p>', csrf: session.csrf }));
        return;
      }
      const view = { ...context, record };
      if (plainPage) return html(request, response, 200, screens.rig(view));
      return send(request, response, 200, rendered(`/rig/${record.id}/${store.revision}`, () => screens.rig(view)));
    }

    html(request, response, 404, page({ title: 'Not found', body: '<h1>Not found</h1><p>That page does not exist.</p>', csrf: session.csrf }));
  }

  return {
    handle,
    sessions,
    stats: () => ({ cached: cache.size, attempts: attempts.size }),
  };
}

module.exports = { createWeb, readForm };

// The pool side of the proxy: what a miner would do, done once for all rigs.
//
// Deliberately the same protocol a miner speaks (login / job / submit /
// keepalived) so any pool works, including this repository's own pool at
// `pool/` and a P2Pool node's stratum port.
//
// The two behaviours that matter for income:
//
//   * reconnect without dropping the rigs. When the pool connection dies, the
//     downstream miners stay connected to the proxy and keep their sockets;
//     they are simply not given new jobs until the pool is back. A rig that
//     reconnects on its own loses 15-30 s of hashrate to the dataset check, ten
//     rigs do it ten times.
//   * failover across a list of pools, with the *same* login (the wallet), so a
//     dead pool costs a share of a minute instead of an evening.

'use strict';

const net = require('node:net');
const tls = require('node:tls');
const { EventEmitter } = require('node:events');

/// Why a pool said no, and how long to leave it alone. A wrong wallet retried
/// every five seconds is how a farm's public IP gets banned on every pool it
/// knows; a ban retried immediately is how a ten-minute ban becomes an hour.
const Refusal = {
  banned: 'banned',
  credentials: 'credentials',
  throttled: 'throttled',
  full: 'full',
  invalidShare: 'invalid share',
  unknown: 'unknown',
};

const REFUSAL_COOLDOWN_MS = {
  banned: 900_000,
  credentials: 1_800_000,
  throttled: 60_000,
  full: 60_000,
  'invalid share': 60_000,
  unknown: 0,
};

/** Turns a pool's error text into a refusal. Order matters: "invalid share"
 *  also contains "invalid", so shares are matched before credentials. */
function classifyRefusal(text) {
  const reason = String(text || '').toLowerCase();
  if (!reason) return Refusal.unknown;

  if (/(ban|blocked|blacklist|not allowed|denied)/.test(reason)) return Refusal.banned;
  if (/(invalid share|low difficulty|bad share|invalid result|invalid nonce|invalid hash)/.test(reason)) return Refusal.invalidShare;
  if (/(too many|rate limit|ratelimit|slow down|throttl|retry later)/.test(reason)) return Refusal.throttled;
  if (/(full|no slots|busy)/.test(reason)) return Refusal.full;
  if (/(invalid login|invalid address|invalid user|invalid wallet|unauthenticated|unauthorized|unauthorised|wrong password|bad login)/.test(reason)) return Refusal.credentials;

  return Refusal.unknown;
}

const KEEPALIVE_MS = 60_000;

class Upstream extends EventEmitter {
  /**
   * @param {object} options
   * @param {string[]} options.pools   "host:port", "tls://host:port"
   * @param {string} options.user      wallet (or wallet.worker)
   * @param {string} options.password  pool password
   * @param {string} options.agent     user agent reported to the pool
   */
  constructor(options = {}) {
    super();

    this.pools = (options.pools || []).filter(Boolean).map(parsePool);
    this.user = options.user || '';
    this.password = options.password || 'x';
    this.agent = options.agent || 'ocean-proxy/1.0';
    // What the pool may switch this proxy between. Every rig behind it runs a
    // miner that implements the whole RandomX family, so by default the pool is
    // told the truth: it can move the farm to whatever pays best per hash.
    this.algos = Array.isArray(options.algos) ? options.algos.filter(Boolean) : [];
    this.rigId = options.rigId || null;
    this.log = options.logger || (() => {});
    this.keepaliveMs = Number(options.keepaliveMs || KEEPALIVE_MS);
    this.retryPauseMs = Number(options.retryPauseMs || 5000);
    this.maxRetryPauseMs = Number(options.maxRetryPauseMs || 60_000);

    this.socket = null;
    this.buffer = '';
    this.poolIndex = 0;
    this.attempt = 0;
    // Pool string -> timestamp before which it is not contacted again.
    this.cooldowns = new Map();
    this.closed = false;
    this.loggedIn = false;
    this.job = null;            // the raw job object, as the pool sent it
    this.difficulty = null;
    this.sessionId = null;
    this.nextId = 1;
    this.loginId = null;
    this.pending = new Map();   // request id -> { resolve, reject, timer }
    this.keepalive = null;
    this.reconnectTimer = null;
    this.stats = {
      connects: 0,
      disconnects: 0,
      jobs: 0,
      submitted: 0,
      accepted: 0,
      rejected: 0,
      stale: 0,
      lastError: null,
      lastRefusal: null,
      lastJobAt: 0,
    };
  }

  get connected() {
    return Boolean(this.socket && this.loggedIn);
  }

  start() {
    this.closed = false;
    this.connect();

    return this;
  }

  connect() {
    if (this.closed) return;
    if (!this.pools.length) {
      this.emit('fatal', new Error('no upstream pool configured'));

      return;
    }

    const chosen = this.nextPool();

    if (!chosen) {
      // Every pool refused recently. Knocking on all of them is what turns one
      // refusal into a ban on all of them, so wait for the first one to expire.
      const { waitMs, pool: cooling } = this.earliestCooldown();
      this.log('warn', `all pools are cooling down (${cooling.host} next); waiting ${Math.ceil(waitMs / 1000)} s`);
      this.reconnectTimer = setTimeout(() => this.connect(), Math.max(250, Math.min(waitMs, 60_000)));
      this.reconnectTimer.unref?.();
      return;
    }

    this.poolIndex = chosen.index;
    const pool = chosen.pool;
    this.log('info', `connecting upstream to ${pool.tls ? 'tls://' : 'tcp://'}${pool.host}:${pool.port}`);

    const onConnect = () => {
      this.attempt = 0;
      this.stats.connects += 1;
      this.log('info', `upstream connected to ${pool.host}:${pool.port}`);
      this.sendLogin();
    };

    try {
      this.socket = pool.tls
        ? tls.connect({ host: pool.host, port: pool.port, servername: pool.host }, onConnect)
        : net.connect({ host: pool.host, port: pool.port }, onConnect);
    } catch (error) {
      this.onError(error);
      return;
    }

    this.socket.setNoDelay(true);
    this.socket.setKeepAlive(true, 30_000);
    this.socket.on('data', (chunk) => this.onData(chunk));
    this.socket.on('error', (error) => this.onError(error));
    this.socket.on('close', () => this.onClose());
  }

  onData(chunk) {
    this.buffer += chunk.toString('utf8');

    // A pool that never sends a newline is not speaking stratum; do not let it
    // grow this string without bound.
    if (this.buffer.length > 1024 * 1024) {
      this.log('warn', 'upstream sent 1 MiB without a newline, dropping it');
      this.drop('protocol');
      return;
    }

    // Cursor plus charCodeAt for the CR, as in pool/src/stratum.js: a pool that
    // answers a batch of shares in one read paid one regular expression per
    // answer to strip a byte.
    const text = this.buffer;
    let start = 0;
    let end;

    while ((end = text.indexOf('\n', start)) >= 0) {
      let line = text.slice(start, end);
      if (line.charCodeAt(line.length - 1) === 13) line = line.slice(0, -1); // CR
      start = end + 1;
      if (line.trim()) this.onLine(line);
    }

    this.buffer = start === 0 ? text : text.slice(start);
  }

  onLine(line) {
    let message;
    try {
      message = JSON.parse(line);
    } catch (_) {
      this.log('debug', `upstream sent non-JSON: ${line.slice(0, 80)}`);
      return;
    }

    // A response to something we asked.
    if (message.id !== undefined && message.id !== null && this.pending.has(message.id)) {
      const waiter = this.pending.get(message.id);
      this.pending.delete(message.id);
      clearTimeout(waiter.timer);
      waiter.resolve(message);
    }

    // A pool that answers the login with an error usually keeps the socket
    // open. Waiting for it to close means the proxy sits on a dead pool
    // forever while every rig is idle, so a refusal goes straight to failover.
    if (this.loginId !== null && message.id === this.loginId && message.error && !this.loggedIn) {
      this.loginId = null;
      this.onLoginError(message.error);

      return;
    }

    if (typeof message.method !== 'string') {
      // Login reply: the first response carrying a job and a status.
      if (!this.loggedIn && message.result && message.result.job) {
        this.onLoginReply(message);
      } else if (message.error) {
        this.log('debug', `upstream error: ${JSON.stringify(message.error).slice(0, 120)}`);
      }

      return;
    }

    if (message.method === 'job') {
      this.onJob(message.params || {});
      return;
    }

    if (message.method === 'client.reconnect') {
      this.log('warn', 'pool asked for a reconnect');
      this.drop('client.reconnect');
    }
  }

  onLoginReply(message) {
    const result = message.result;
    this.loggedIn = true;
    this.loginId = null;
    this.sessionId = result.id ?? null;

    if (result.job) this.onJob(result.job);

    this.log('info', `upstream login ok (session ${this.sessionId ?? '?'}, difficulty ${this.difficulty ?? '?'})`);
    this.emit('login', result);
  }

  onJob(job) {
    this.job = job;
    this.stats.jobs += 1;
    this.stats.lastJobAt = Date.now();

    // The difficulty lives in the target, not in a separate field.
    this.emit('job', job);

    // Keep the session alive: some pools drop a silent connection and only the
    // keepalived reply proves both ends are still there.
    this.startKeepalive();
  }

  sendLogin() {
    const params = {
      login: this.user,
      pass: this.password,
      agent: this.agent,
    };
    if (this.rigId) params.rigid = this.rigId;
    if (this.algos.length) params.algo = this.algos;

    this.loginId = this.nextId++;
    this.write({ id: this.loginId, jsonrpc: '2.0', method: 'login', params });
  }

  /** First pool, from the current index on, that is not cooling down. */
  nextPool() {
    const now = Date.now();

    for (let offset = 0; offset < this.pools.length; offset++) {
      const index = (this.poolIndex + offset) % this.pools.length;
      const pool = this.pools[index];
      const until = this.cooldowns.get(poolKey(pool)) || 0;

      if (until <= now) return { index, pool };
    }

    return null;
  }

  earliestCooldown() {
    const now = Date.now();
    let best = { pool: this.pools[0], waitMs: 0 };

    for (const pool of this.pools) {
      const until = this.cooldowns.get(poolKey(pool)) || 0;
      const waitMs = Math.max(250, until - now);

      if (!best.pool || waitMs < best.waitMs) best = { pool, waitMs };
    }

    return best;
  }

  cool(pool, ms) {
    if (ms <= 0) return;
    this.cooldowns.set(poolKey(pool), Date.now() + ms);
  }

  /** The pool refused the login. Rotate now, and leave that pool alone for a
   *  while: repeating a refusal is what gets the farm's IP banned. */
  onLoginError(error) {
    const reason = error?.message || JSON.stringify(error);
    const refusal = classifyRefusal(reason);
    this.stats.lastError = reason;

    const pool = this.pools[this.poolIndex % this.pools.length];
    const wait = REFUSAL_COOLDOWN_MS[refusal] || 0;
    this.cool(pool, wait);

    if (refusal === Refusal.credentials) {
      this.log('error', `${pool.host} rejected the wallet or password: ${reason}. Pausing it for ${Math.round(wait / 60_000)} min instead of retrying every few seconds, because repeated logins are what gets an IP banned`);
    } else if (refusal === Refusal.banned) {
      this.log('error', `${pool.host} banned this IP: ${reason}. Pausing it for ${Math.round(wait / 60_000)} min`);
    } else {
      this.log('warn', `pool refused the login (${refusal}): ${reason}`);
    }

    this.stats.lastRefusal = refusal;
    this.poolIndex += 1;
    this.attempt = 0;
    this.drop('login rejected');
  }

  /** Sends a share upstream. Resolves with true when the pool accepted it. */
  submit({ jobId, nonce, result, algo, height }) {
    const id = this.nextId++;

    const params = {
      id: this.user,
      job_id: jobId,
      nonce,
      result,
    };
    if (algo) params.algo = algo;
    if (height) params.height = height;

    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        this.stats.rejected += 1;
        resolve({ ok: false, reason: 'timeout' });
      }, 30_000);
      timer.unref?.();

      this.pending.set(id, {
        timer,
        resolve: (message) => {
          if (message.error) {
            const reason = message.error.message || JSON.stringify(message.error);
            this.stats.rejected += 1;
            if (/stale|job not found|expired/i.test(reason)) this.stats.stale += 1;
            resolve({ ok: false, reason });
            return;
          }

          this.stats.accepted += 1;
          resolve({ ok: true });
        },
      });

      this.stats.submitted += 1;
      this.write({ id, jsonrpc: '2.0', method: 'submit', params });
    });
  }

  startKeepalive() {
    if (this.keepalive) return;

    this.keepalive = setInterval(() => {
      if (!this.connected) return;
      this.write({ id: this.nextId++, jsonrpc: '2.0', method: 'keepalived', params: { id: this.sessionId } });
    }, this.keepaliveMs);
    this.keepalive.unref?.();
  }

  write(object) {
    if (!this.socket || this.socket.destroyed) return false;

    try {
      this.socket.write(`${JSON.stringify(object)}\n`);

      return true;
    } catch (error) {
      this.onError(error);

      return false;
    }
  }

  /** Closes the socket; the reconnect loop takes over unless `closed`. */
  drop(reason) {
    if (!this.socket) return;

    this.log('warn', `upstream connection dropped (${reason})`);
    this.stats.disconnects += 1;

    try { this.socket.destroy(); } catch (_) {}
  }

  onError(error) {
    this.stats.lastError = error.message;

    // ECONNREFUSED on the first try is the normal "pool is down" case; the log
    // line that matters is the reconnect, not the error.
    this.log('debug', `upstream error: ${error.message}`);
  }

  onClose() {
    const wasLoggedIn = this.loggedIn;

    this.socket = null;
    this.loggedIn = false;
    this.loginId = null;
    this.buffer = '';

    for (const [, waiter] of this.pending) {
      clearTimeout(waiter.timer);
      waiter.resolve({ error: { message: 'connection closed' } });
    }
    this.pending.clear();

    if (this.closed) return;

    // A pool that accepted the login and then died is worth retrying at once;
    // one that never answered gets an exponential pause.
    this.attempt = wasLoggedIn ? 0 : this.attempt + 1;
    const nominal = Math.min(this.retryPauseMs * 2 ** Math.min(this.attempt, 4), this.maxRetryPauseMs);

    // ±20 %, so a farm that restarts together does not arrive at the pool in
    // the same millisecond -- from the other side that is a login flood.
    const pause = nominal < 100 ? nominal : Math.round(nominal * (0.8 + Math.random() * 0.4));

    if (!wasLoggedIn && this.attempt >= 3) {
      this.poolIndex += 1;
      this.log('warn', `upstream failing, moving to the next pool (${this.pools[this.poolIndex % this.pools.length].host})`);
    }

    this.emit('down');
    this.reconnectTimer = setTimeout(() => this.connect(), pause);
    this.reconnectTimer.unref?.();
  }

  close() {
    this.closed = true;

    if (this.keepalive) clearInterval(this.keepalive);
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.keepalive = null;
    this.reconnectTimer = null;

    try { this.socket?.destroy(); } catch (_) {}
    this.socket = null;
    this.loggedIn = false;
  }

  snapshot() {
    const pool = this.pools.length ? this.pools[this.poolIndex % this.pools.length] : null;

    return {
      connected: this.connected,
      pool: pool ? `${pool.tls ? 'tls://' : 'tcp://'}${pool.host}:${pool.port}` : null,
      pools: this.pools.map((p) => `${p.tls ? 'tls://' : 'tcp://'}${p.host}:${p.port}`),
      difficulty: this.difficulty,
      height: this.job?.height ?? null,
      ...this.stats,
    };
  }
}

/** Identity of a pool for the cooldown table: TLS or not is a different
 *  endpoint, and treating them as one would cool down the wrong one. */
function poolKey(pool) {
  return `${pool.tls ? 'tls' : 'tcp'}://${pool.host}:${pool.port}`;
}

function parsePool(text) {
  const value = String(text).trim();
  const tls = /^(tls|ssl|stratum\+ssl):\/\//.test(value);
  const hostPort = value.replace(/^[a-z+]+:\/\//i, '');
  const lastColon = hostPort.lastIndexOf(':');
  const host = lastColon > 0 ? hostPort.slice(0, lastColon) : hostPort;
  const port = lastColon > 0 ? Number(hostPort.slice(lastColon + 1)) : 3333;

  return { host, port: Number.isFinite(port) ? port : 3333, tls };
}

module.exports = { REFUSAL_COOLDOWN_MS, Refusal, Upstream, classifyRefusal, parsePool };

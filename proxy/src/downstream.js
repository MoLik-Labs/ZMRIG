// The miner side of the proxy: rigs connect here instead of to the pool.
//
// It speaks exactly what the pool speaks, so a rig needs no new software, just
// a different host:port. What it adds is the three things a pool cannot do for
// a farm behind one line:
//
//   * one upstream connection for every rig (pools rate-limit logins, and a
//     shared 3G link does not want ten copies of the same job stream),
//   * a distinct extranonce per rig, so two rigs never compute the same nonce
//     (see blob.js; this is where shares otherwise silently vanish),
//   * per-rig difficulty, so a 500 H/s box and a 20 kH/s box both report shares
//     at the same rate and can never starve each other.
//
// The transport is abstracted the same way the pool does it: `write(text)`,
// `on('data'|'message'|'close')`. TCP (this file's own listener), WebSocket and
// TLS all plug in unchanged.

'use strict';

const { applyExtranonce, honoursPrefix, nonceOffsetFor } = require('./blob');
const { ExtranonceAllocator } = require('./extranonce');
const { Vardiff } = require('./vardiff');
const { hashrateFromShares, xmrPerDay } = require('./network');
const { difficultyFromTarget, meetsTarget, targetHex } = require('../../pool/src/target');
const { hexToBytes, isHex, isHexOf, nowSeconds, looksLikeAddress, splitLogin } = require('../../pool/src/util');

const MAX_LINE = 16 * 1024;
const LOGIN_TIMEOUT = 30;
const JOB_TTL = 120;          // seconds a job stays acceptable for a late share
const MAX_JOBS = 64;          // per connection

class Downstream {
  /**
   * @param {object} options
   * @param {import('./upstream').Upstream} options.upstream
   * @param {string} [options.user]        wallet the pool is paid to
   * @param {boolean} [options.forwardWorkers] report each rig as its own worker
   * @param {number} [options.targetShareSeconds]
   * @param {object} [options.logger]
   */
  constructor(options = {}) {
    this.upstream = options.upstream;
    this.user = options.user || '';
    this.forwardWorkers = options.forwardWorkers !== false;
    this.target = Number(options.targetShareSeconds || 15);
    this.localFactor = Number(options.localFactor || 1);
    // The token a rig must send as its stratum *password*. Every miner already
    // has a password field, so this needs no client change and no custom header
    // a tunnel provider could strip.
    this.token = String(options.token || '');
    // Optional: turns the per-rig share counts into H/s and XMR/day. Without
    // it /status still reports hashrate and shares/hour -- it just refuses to
    // price them.
    this.network = options.network || null;
    this.log = options.logger || (() => {});

    this.allocator = new ExtranonceAllocator();
    this.connections = new Set();
    this.pendingLogins = new Map();  // conn -> { id, params, timer }
    this.sessionSeq = 0;
    this.jobSeq = 0;

    this.job = null;             // the newest upstream job, as received
    this.upstreamDifficulty = null;
    this.upstreamPrefix = null;  // set once we have seen a job
    this.prefixHonoured = 0;
    this.prefixIgnored = 0;
    this.stats = {
      accepted: 0,
      forwarded: 0,
      absorbed: 0,      // cleared the miner's target but not the pool's
      rejected: 0,
      stale: 0,
      duplicate: 0,
      loginOk: 0,
      loginFailed: 0,
    };
    this.startedAt = nowSeconds();

    if (this.upstream) {
      this.upstream.on('job', (job) => this.onUpstreamJob(job));
      this.upstream.on('down', () => this.log('warn', 'upstream down: rigs stay connected on the last job'));
    }
  }

  // --- upstream -------------------------------------------------------------

  onUpstreamJob(job) {
    if (!job || typeof job.blob !== 'string' || !isHex(job.blob)) {
      this.log('debug', 'upstream job without a usable blob, ignoring');

      return;
    }

    const difficulty = difficultyFromTarget(job.target);
    if (!(difficulty > 0)) {
      this.log('debug', `upstream target ${job.target} does not parse, keeping the previous difficulty`);

      return;
    }

    const changed = job.job_id !== this.job?.job_id;
    const retargeted = difficulty !== this.upstreamDifficulty;
    const switched = (job.algo || 'rx/0') !== (this.job?.algo || 'rx/0');
    this.job = job;
    this.upstreamDifficulty = difficulty;

    if (this.upstreamPrefix === null || switched) {
      // A new algorithm can move the nonce (panthera: 147), so the byte the pool
      // already owns has to be read again from the new position.
      const offset = nonceOffsetFor(job.algo);
      this.upstreamPrefix = readPrefix(job.blob, offset);
      if (this.upstreamPrefix !== 0) {
        this.log('warn', `upstream already uses nonce byte 0x${byteHex(this.upstreamPrefix)}; rigs share that space`);
      }
    }

    for (const conn of this.connections) {
      if (!conn.authorised) continue;
      if (retargeted) conn.vardiff.setUpstream(difficulty, false);
      // A new difficulty is useless to the rig until it arrives in a job, so
      // either change is announced.
      if (changed || retargeted || switched) this.sendJob(conn, changed || switched);
    }

    // A rig that logged in during the seconds before this job existed is
    // answered now instead of being told to reconnect: a reconnect costs it the
    // 16-30 s dataset check, which is the most expensive thing a rig does.
    this.flushPendingLogins();

    if (changed) this.log('info', `new job from upstream: height ${job.height ?? '?'}, difficulty ${difficulty}`);
  }

  // --- transport plumbing ---------------------------------------------------

  attach(conn, meta = {}) {
    conn.meta = meta;
    conn.remote = meta.remote || 'unknown';
    conn.authorised = false;
    conn.closed = false;
    conn.dropped = false;
    conn.lineBuffer = '';
    conn.login = null;
    conn.address = null;
    conn.worker = '';
    conn.agent = '';
    conn.prefix = 0;
    conn.prefixWarned = false;
    conn.jobs = new Map();
    conn.accepted = 0;
    conn.rejected = 0;
    conn.connectedAt = nowSeconds();
    conn.lastSeen = nowSeconds();
    conn.vardiff = new Vardiff({
      upstream: this.upstreamDifficulty || 1,
      target: this.target,
      now: nowSeconds(),
    });

    if (this.localFactor !== 1 && this.upstreamDifficulty) {
      conn.vardiff.current = Math.max(this.upstreamDifficulty * this.localFactor, 0.01);
    }

    this.connections.add(conn);

    const timer = setTimeout(() => {
      if (!conn.authorised) this.drop(conn, 'login timeout');
    }, LOGIN_TIMEOUT * 1000);
    timer.unref?.();

    conn.on('data', (chunk) => this.onData(conn, chunk));
    conn.on('message', (text) => this.onMessage(conn, text));
    conn.on('line', (line) => this.onLine(conn, line));
    conn.on('close', () => {
      clearTimeout(timer);
      this.connections.delete(conn);
      const pending = this.pendingLogins.get(conn);
      if (pending) {
        clearTimeout(pending.timer);
        this.pendingLogins.delete(conn);
      }
      conn.closed = true;
      if (conn.prefix) this.allocator.release(conn.prefix);
      conn.prefix = 0;
    });

    // A rig that is already talking to us before a job exists gets its job the
    // moment the pool delivers one; nothing here waits on that.
    this.log('debug', `rig connected from ${conn.remote}`);
  }

  onData(conn, chunk) {
    conn.lineBuffer += chunk.toString('utf8');

    if (conn.lineBuffer.length > MAX_LINE * 4) {
      this.drop(conn, 'flood');

      return;
    }

    // A cursor over the string, sliced once at the end and once per line, and
    // the CR checked with charCodeAt instead of `.replace(/\r$/, '')`.
    //
    // The regex was the cost: `slice()` on a string is O(1) in V8 (it returns
    // a SlicedString, not a copy), but `/\r$/.replace()` compiles its way to a
    // RegExpResult per line, on the one path every message from every rig goes
    // through. Measured in isolation, 400 000 submits in 8-message reads: 92 ms
    // before, 64 ms after, and 0.27 -> 0.20 microseconds per message on a
    // 1000-message read. At pool level, with JSON.parse on both sides of it,
    // that is below the noise of this machine - the tests below pin the
    // behaviour, not the number.
    //
    // The second reason is not measurable: a dropped connection used to leave
    // its buffer in place. Two lines instead of zero is worth having on a pool
    // that sees a lot of dropped connections.
    const text = conn.lineBuffer;
    let start = 0;
    let end;

    while ((end = text.indexOf('\n', start)) >= 0) {
      let line = text.slice(start, end);
      if (line.charCodeAt(line.length - 1) === 13) line = line.slice(0, -1); // CR
      start = end + 1;

      if (line.length > MAX_LINE) {
        conn.lineBuffer = '';
        this.drop(conn, 'line too long');

        return;
      }

      if (line.trim()) this.onLine(conn, line);

      // `onLine` can drop the connection (a bad share, a flood). The rest of
      // this read belongs to nobody, and a closed connection holding a buffer
      // is a slow leak on a pool that sees a lot of them.
      if (conn.closed) {
        conn.lineBuffer = '';

        return;
      }
    }

    conn.lineBuffer = start === 0 ? text : text.slice(start);
  }

  onMessage(conn, text) {
    for (const line of String(text).split('\n')) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      if (trimmed.length > MAX_LINE) {
        this.drop(conn, 'line too long');

        return;
      }
      this.onLine(conn, trimmed);
      if (conn.closed) return;
    }
  }

  send(conn, object) {
    if (conn.closed) return;

    try {
      conn.write(`${JSON.stringify(object)}\n`);
    } catch (_) {
      this.drop(conn, 'write failed');
    }
  }

  reply(conn, id, result, error = null) {
    this.send(conn, { id, jsonrpc: '2.0', error, result });
  }

  drop(conn, reason) {
    if (conn.dropped) return;
    conn.dropped = true;
    this.log('debug', `closing rig ${conn.remote}: ${reason}`);
    try { conn.close(); } catch (_) {}
  }

  close() {
    for (const [, pending] of this.pendingLogins) clearTimeout(pending.timer);
    this.pendingLogins.clear();

    for (const conn of [...this.connections]) this.drop(conn, 'shutdown');
    this.connections.clear();
  }

  /** Re-runs any held logins now that a job exists. */
  flushPendingLogins() {
    if (!this.job) return;

    for (const [conn, pending] of [...this.pendingLogins]) {
      clearTimeout(pending.timer);
      this.pendingLogins.delete(conn);
      if (conn.closed) continue;

      this.onLogin(conn, pending.id, pending.params);
    }
  }

  // --- protocol -------------------------------------------------------------

  onLine(conn, line) {
    conn.lastSeen = nowSeconds();

    let message;
    try {
      message = JSON.parse(line);
    } catch (_) {
      this.reply(conn, 0, null, { code: -32700, message: 'invalid JSON' });

      return;
    }

    const id = message.id ?? 0;

    if (typeof message.method !== 'string') {
      this.reply(conn, id, null, { code: -32600, message: 'missing method' });

      return;
    }

    switch (message.method) {
      case 'login':
        this.onLogin(conn, id, message.params || {});
        break;
      case 'submit':
        this.onSubmit(conn, id, message.params || {});
        break;
      case 'keepalived':
        this.reply(conn, id, { status: 'KEEPALIVED' });
        break;
      case 'getjob':
        if (!conn.authorised) { this.reply(conn, id, null, { code: -1, message: 'not logged in' }); break; }
        this.sendJob(conn, true);
        this.reply(conn, id, { status: 'OK' });
        break;
      default:
        this.reply(conn, id, null, { code: -32601, message: `unknown method ${message.method}` });
        break;
    }
  }

  onLogin(conn, id, params) {
    if (conn.authorised) {
      this.reply(conn, id, { status: 'OK' });

      return;
    }

    const login = String(params.login || '').trim();
    const agent = String(params.agent || conn.meta.userAgent || '').slice(0, 96);

    if (!login) {
      this.stats.loginFailed += 1;
      this.reply(conn, id, null, { code: -1, message: 'empty login' });
      this.drop(conn, 'empty login');

      return;
    }

    if (this.token) {
      const supplied = String(params.pass ?? '');

      if (supplied !== this.token) {
        this.stats.loginFailed += 1;
        this.reply(conn, id, null, { code: -1, message: 'wrong token: the stratum password must match --token' });
        this.log('warn', `rig ${conn.remote} sent the wrong token`);
        this.drop(conn, 'wrong token');

        return;
      }
    }

    const { address, worker } = splitLogin(login);

    // Who gets paid. `--user` wins so the whole farm lands on one wallet;
    // without it the first rig's address is adopted, which is what someone
    // running a single wallet expects.
    if (!this.user) {
      if (!looksLikeAddress(address)) {
        this.stats.loginFailed += 1;
        this.reply(conn, id, null, { code: -1, message: 'proxy has no --user and this is not a wallet address' });
        this.drop(conn, 'no payout wallet');

        return;
      }

      this.user = address;
      this.log('info', `payout wallet taken from the first rig: ${address.slice(0, 12)}…`);
      if (this.upstream && !this.upstream.user) this.upstream.user = this.upstreamLogin(address, worker);
    } else if (looksLikeAddress(address) && address !== this.user) {
      // Someone pointed a rig at the proxy with a different wallet. Their work
      // still pays the proxy wallet; saying so once is the honest thing.
      this.log('warn', `rig ${conn.remote} logged in with ${address.slice(0, 10)}… but this proxy pays ${this.user.slice(0, 10)}…`);
    }

    // A job is needed in the reply: a miner that gets none reconnects, and a
    // reconnect costs it the dataset check. Replaying the last job while the
    // pool is down is therefore free hashrate, not stale work.
    if (!this.job) {
      // Hold the reply: the pool connection is usually a fraction of a second
      // behind a rig that was just started. Three seconds is long enough for
      // any reachable pool and short enough that a miner's own timeout is not
      // hit; after that the honest answer is "reconnect".
      if (!this.pendingLogins.has(conn)) {
        const timer = setTimeout(() => {
          this.pendingLogins.delete(conn);
          if (conn.closed || conn.authorised) return;
          this.stats.loginFailed += 1;
          this.reply(conn, id, null, { code: -1, message: 'no job yet: the proxy has not reached a pool, retry in a second' });
          this.log('warn', `rig ${conn.remote} waited for a job and the pool has still not answered`);
        }, 3000);
        timer.unref?.();

        this.pendingLogins.set(conn, { id, params, timer });
        this.log('debug', `rig ${conn.remote} is waiting for the first job`);
      }

      return;
    }

    const prefix = this.allocator.acquire(conn.meta.id || `conn-${++this.sessionSeq}`);
    if (prefix === null) {
      this.stats.loginFailed += 1;
      this.reply(conn, id, null, { code: -1, message: 'proxy is full (255 rigs), connect a second proxy' });
      this.drop(conn, 'no extranonce left');

      return;
    }

    // A rig that spent time waiting for the first job was created before the
    // pool's difficulty was known; without this its vardiff would start from a
    // guess of 1 and hand out targets a thousand times too easy.
    this.syncDifficulty(conn);

    conn.prefix = prefix;
    conn.authorised = true;
    // The estimate divides by this, so it must be the moment the rig started
    // producing shares, not the moment the TCP socket opened.
    conn.connectedAt = nowSeconds();
    conn.login = login;
    conn.address = address;
    conn.worker = worker;
    conn.agent = agent;
    conn.suffix = `proxy-${prefix}`;
    this.stats.loginOk += 1;

    this.log('info', `rig ${conn.remote} logged in (${agent || 'no agent'}, prefix 0x${byteHex(prefix)})`);

    this.reply(conn, id, {
      id: conn.suffix,
      job: this.jobFor(conn),
      status: 'OK',
      extensions: ['algo', 'keepalive'],
      // Stated in the reply the miner logs, not buried in a README.
      fee: 0,
      pool: this.upstream ? this.upstream.snapshot().pool : null,
    });
  }

  /** Puts a fresh rig on the pool's current difficulty (times `localFactor`).
   *  Only for a connection that has not started mining yet: calling it later
   *  would throw away the rig's own tuning. */
  syncDifficulty(conn) {
    const upstream = this.upstreamDifficulty;
    if (!(upstream > 0)) return;

    conn.vardiff.setUpstream(upstream, true);
    conn.vardiff.current = Math.max(upstream * this.localFactor, 0.01);
    conn.vardiff.shares = 0;
    conn.vardiff.lastAdjust = nowSeconds();
    conn.vardiff.startedAt = nowSeconds();
  }

  /** What a miner's reply needs: the blob with its own nonce byte, and a
   *  target matching its own difficulty. */
  jobFor(conn) {
    const job = this.job;
    if (!job) return null;

    const difficulty = conn.vardiff.current;
    // Read the offset from the algorithm: a panthera job has its nonce at 147,
    // and patching 39 instead yields a blob no miner can produce a valid hash for.
    const offset = nonceOffsetFor(job.algo);
    const { blob, mode } = applyExtranonce(job.blob, {
      offset,
      upstreamPrefix: this.upstreamPrefix || 0,
      minerPrefix: conn.prefix,
    });

    const id = `p${++this.jobSeq}`;
    conn.jobs.set(id, {
      upstreamId: String(job.job_id),
      difficulty,
      announcedAt: nowSeconds(),
      mode,
      algo: job.algo || 'rx/0',
    });

    while (conn.jobs.size > MAX_JOBS) {
      conn.jobs.delete(conn.jobs.keys().next().value);
    }

    return {
      job_id: id,
      blob,
      target: targetHex(difficulty),
      height: job.height ?? 0,
      seed_hash: job.seed_hash,
      next_seed_hash: job.next_seed_hash || job.seed_hash,
      algo: job.algo || 'rx/0',
      // Announce a clean job only when the template really changed; a pure
      // difficulty change must not throw away the rig's current work.
      clean_jobs: false,
    };
  }

  sendJob(conn, fresh) {
    if (!this.job || conn.closed) return;

    const params = this.jobFor(conn);
    if (!params) return;

    if (fresh) params.clean_jobs = true;

    this.send(conn, { jsonrpc: '2.0', method: 'job', params });
  }

  onSubmit(conn, id, params) {
    if (!conn.authorised) {
      this.reply(conn, id, null, { code: -1, message: 'not logged in' });

      return;
    }

    const jobId = String(params.job_id || '');
    const nonce = String(params.nonce || '');
    const result = String(params.result || '');

    if (!jobId || !isHexOf(nonce, 4) || !isHexOf(result, 32)) {
      this.stats.rejected += 1;
      this.reply(conn, id, null, { code: -1, message: 'malformed share' });

      return;
    }

    const entry = conn.jobs.get(jobId);
    if (!entry) {
      this.stats.stale += 1;
      this.reply(conn, id, null, { code: -21, message: 'job not found (stale)' });

      return;
    }

    if (nowSeconds() - entry.announcedAt > JOB_TTL) {
      this.stats.stale += 1;
      this.reply(conn, id, null, { code: -21, message: 'job expired' });

      return;
    }

    // Did this rig respect the nonce byte it was given? A miner started without
    // extranonce support stamps its own value over the top byte, and then two
    // rigs can walk into the same nonce. Still a valid share, but the operator
    // has to know, once, instead of discovering it from a 30 % income gap.
    const nonceValue = Number.parseInt(nonce, 16);
    if (!honoursPrefix(nonceValue, conn.prefix)) {
      this.prefixIgnored += 1;
      if (!conn.prefixWarned) {
        conn.prefixWarned = true;
        this.log('warn', `rig ${conn.remote} overwrote its extranonce (0x${byteHex((nonceValue >>> 24) & 0xff)} instead of 0x${byteHex(conn.prefix)}); duplicate work possible with another rig`);
      }
    } else {
      this.prefixHonoured += 1;
    }

    const hashBytes = hexToBytes(result);
    if (!hashBytes) {
      this.stats.rejected += 1;
      this.reply(conn, id, null, { code: -1, message: 'bad hash' });

      return;
    }

    // Validate against what *this* rig was asked for. Cheap and local; the pool
    // verifies the hash itself, so a lying miner gains nothing.
    if (!meetsTarget(hashBytes, entry.difficulty)) {
      this.stats.rejected += 1;
      conn.rejected += 1;
      this.reply(conn, id, null, { code: -1, message: 'low difficulty share' });

      return;
    }

    this.stats.accepted += 1;
    conn.accepted += 1;

    const forwards = meetsTarget(hashBytes, this.upstreamDifficulty || entry.difficulty);

    if (!forwards) {
      // Accepted locally, useless to the pool. Counted, not hidden.
      this.stats.absorbed += 1;
      conn.vardiff.record(nowSeconds(), false);
      this.reply(conn, id, { status: 'OK' });

      return;
    }

    if (!this.upstream || !this.upstream.connected) {
      // Real work, nowhere to send it. Answered, counted, never called
      // forwarded -- the two counters must not overlap.
      this.stats.absorbed += 1;
      conn.vardiff.record(nowSeconds(), false);
      this.reply(conn, id, { status: 'OK' });
      this.log('debug', `share from ${conn.remote} not forwarded: pool is disconnected`);

      return;
    }

    this.stats.forwarded += 1;
    conn.vardiff.record(nowSeconds(), true);

    // Answer the rig now, forward in the background: the pool round trip is
    // 50-400 ms and the rig has work to do.
    this.reply(conn, id, { status: 'OK' });

    this.upstream.submit({
      jobId: entry.upstreamId,
      nonce,
      result,
      algo: entry.algo,
      height: this.job?.height,
    }).then((outcome) => {
      if (!outcome.ok) this.log('debug', `pool rejected a share from ${conn.remote}: ${outcome.reason}`);
    });
  }

  upstreamLogin(address, worker) {
    if (!this.forwardWorkers || !worker) return address;

    // The rig's own name shows up on the pool dashboard, per rig, which is the
    // only per-rig income report an operator gets for free.
    return `${address}.${worker}`;
  }

  /** Called on a timer; returns nothing, sends jobs when a rig's difficulty
   *  moved enough to matter. */
  tick(now = nowSeconds()) {
    for (const conn of this.connections) {
      if (!conn.authorised) continue;

      const next = conn.vardiff.poll(now);
      if (next === null) continue;

      this.sendJob(conn, true);
      this.log('debug', `rig ${conn.remote} difficulty -> ${next.toFixed(2)} (pool ${this.upstreamDifficulty})`);
    }
  }

  status() {
    const rigs = [...this.connections].filter((c) => c.authorised);

    return {
      uptime: nowSeconds() - this.startedAt,
      rigs: rigs.length,
      reportedRigs: this.connections.size,
      wallet: this.user || null,
      upstream: this.upstream ? this.upstream.snapshot() : null,
      job: this.job ? { id: this.job.job_id, height: this.job.height ?? null } : null,
      difficulty: this.upstreamDifficulty,
      extranonce: this.allocator.snapshot(),
      prefixHonoured: this.prefixHonoured,
      prefixIgnored: this.prefixIgnored,
      ...this.stats,
      estimate: this.network ? this.network.snapshot() : null,
      ...this.fleetTotals(rigs),
      connections: rigs.map((c) => {
        const seconds = Math.max(1, nowSeconds() - (c.connectedAt || this.startedAt));
        // The difficulty the rig was actually given: a rig on a lowered local
        // difficulty produces more shares of less value each, and dividing by
        // that difficulty makes two rigs comparable again.
        const hashrate = hashrateFromShares({
          shares: c.accepted,
          difficulty: c.vardiff.current,
          seconds,
        });

        return {
          remote: c.remote,
          worker: c.worker || null,
          agent: c.agent || null,
          prefix: c.prefix,
          uptime: Math.round(seconds),
          difficulty: Number(c.vardiff.current.toFixed(4)),
          accepted: c.accepted,
          rejected: c.rejected,
          hashrate: Number(hashrate.toFixed(1)),
          sharesPerHour: Number(((c.accepted / seconds) * 3600).toFixed(2)),
          xmrPerDay: this.priceOf(hashrate),
        };
      }),
    };
  }

  /** XMR/day for a hashrate, or null when the network figure is unknown. */
  priceOf(hashrate) {
    if (!this.network) return null;

    const value = xmrPerDay({
      hashrate,
      networkDifficulty: this.network.difficulty,
      reward: this.network.reward,
    });

    return value === null ? null : Number(value.toFixed(6));
  }

  /** Fleet-wide sums, so an operator reads one number instead of adding up
   *  twenty rigs by hand. */
  fleetTotals(rigs) {
    let hashrate = 0;
    let sharesPerHour = 0;

    for (const c of rigs) {
      const seconds = Math.max(1, nowSeconds() - (c.connectedAt || this.startedAt));
      hashrate += hashrateFromShares({ shares: c.accepted, difficulty: c.vardiff.current, seconds });
      sharesPerHour += (c.accepted / seconds) * 3600;
    }

    return {
      hashrate: Number(hashrate.toFixed(1)),
      sharesPerHour: Number(sharesPerHour.toFixed(2)),
      xmrPerDay: this.priceOf(hashrate),
    };
  }
}

/** Reads the top byte of the blob's nonce (little-endian u32) without pulling
 *  in the whole blob module: this only needs the byte, not the value. */
function readPrefix(blobHex, offset) {
  const hex = String(blobHex).slice((offset + 3) * 2, (offset + 4) * 2);

  return Number.parseInt(hex || '0', 16) || 0;
}

function byteHex(value) {
  return (value & 0xff).toString(16).padStart(2, '0');
}

module.exports = { Downstream };

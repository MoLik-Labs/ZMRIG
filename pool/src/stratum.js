// The stratum side of the pool: login, jobs, vardiff, share acceptance.
//
// A connection is transport-agnostic: TCP sockets and WebSocket connections are
// both adapted to the same tiny shape (`write`, `on('line')`, `on('close')`),
// so the protocol code below is identical for `stratum+tcp` and `wss`.

'use strict';

const { clamp, hexToBytes, isHex, isHexOf, nowSeconds, splitLogin, looksLikeAddress } = require('./util');
const { meetsTarget, nextDifficulty } = require('./target');

const MAX_LINE = 16 * 1024;
const LOGIN_TIMEOUT = 30;

class StratumPool {
  constructor({ config, ledger, jobs, verifier, daemon, logger }) {
    this.config = config;
    this.ledger = ledger;
    this.jobs = jobs;
    this.verifier = verifier;
    this.daemon = daemon;
    this.log = logger;

    this.connections = new Set();
    this.sessionSeq = 0;
    this.stats = {
      accepted: 0,
      rejected: 0,
      stale: 0,
      badShares: 0,
      blocksFound: 0,
      loginOk: 0,
      loginFailed: 0,
    };
    this.startedAt = nowSeconds();
    this.onTemplate = null;
  }

  /** Called by the template feeder whenever a new job exists. */
  broadcastTemplate(job) {
    for (const conn of this.connections) {
      if (!conn.authorised) continue;
      this.sendJob(conn, job, false);
    }
  }

  // --- connection plumbing ---------------------------------------------

  attach(conn, meta = {}) {
    conn.meta = meta;
    conn.authorised = false;
    conn.difficulty = Number(this.config.initial_difficulty || 2000);
    conn.jobs = new Map();      // job id -> difficulty (plain number) at announce time
    conn.shareTimes = [];       // recent share timestamps, for vardiff
    conn.accepted = 0;
    conn.rejected = 0;
    conn.login = null;
    conn.address = null;
    conn.agent = '';
    conn.connectedAt = nowSeconds();
    conn.lastSeen = nowSeconds();
    conn.lineBuffer = ''; // partial JSON line; distinct from the WS frame buffer
    conn.closed = false;
    conn.lastVardiff = nowSeconds();
    conn.dropped = false;

    this.connections.add(conn);

    if (meta.remote) conn.remote = meta.remote;

    const timer = setTimeout(() => {
      if (!conn.authorised) this.drop(conn, 'login timeout');
    }, LOGIN_TIMEOUT * 1000);
    timer.unref?.();

    // TCP delivers bytes, WebSocket delivers whole text frames. Both end up in
    // the same line splitter.
    conn.on('data', (chunk) => this.onData(conn, chunk));
    conn.on('message', (text) => this.onMessage(conn, text));
    conn.on('line', (line) => this.onLine(conn, line));
    conn.on('close', () => {
      clearTimeout(timer);
      this.connections.delete(conn);
      conn.closed = true;
    });

    this.log('debug', `connection from ${conn.remote || 'unknown'}`);
  }

  onData(conn, chunk) {
    conn.lineBuffer += chunk.toString('utf8');

    if (conn.lineBuffer.length > MAX_LINE * 4) {
      this.drop(conn, 'flood');

      return;
    }

    let index;
    while ((index = conn.lineBuffer.indexOf('\n')) >= 0) {
      const line = conn.lineBuffer.slice(0, index).replace(/\r$/, '');
      conn.lineBuffer = conn.lineBuffer.slice(index + 1);

      if (line.length > MAX_LINE) {
        this.drop(conn, 'line too long');
        return;
      }

      if (line.trim()) this.onLine(conn, line);
      if (conn.closed) return;
    }
  }

  /**
   * WebSocket transport: one frame is one message. Miners built for
   * stratum-over-WS may or may not end their JSON with a newline, so a frame is
   * treated as a complete line (and may carry several newline-separated ones).
   */
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

    this.log('info', `closing connection ${conn.remote || ''}: ${reason}`);
    try { conn.close(); } catch (_) {}
  }

  // --- protocol ---------------------------------------------------------

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
        this.sendJob(conn, this.jobs.current, true);
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

    const { address, worker } = splitLogin(login);

    // Something shaped exactly like an address but with a broken checksum is a
    // typo, and a typo is the one failure the miner cannot see: the rig hashes
    // happily, the pool credits it, and the payout goes to an address nobody
    // holds. Refusing the login says so at the only moment somebody is looking
    // at the screen. Plain names (test rigs, `wallet.rig` with no address) are
    // untouched: they never matched the shape in the first place.
    if (/^[48][1-9A-HJ-NP-Za-km-z]{94}$/.test(address) || /^[48][1-9A-HJ-NP-Za-km-z]{105}$/.test(address)) {
      const verdict = require('./address').check(address);
      if (!verdict.ok) {
        this.stats.loginFailed += 1;
        this.reply(conn, id, null, { code: -1, message: `wallet address is not valid: ${verdict.reason}` });
        this.drop(conn, 'invalid address checksum');
        this.log('warn', `login from ${conn.remote || 'unknown'} refused: ${verdict.reason}`);

        return;
      }
      if (verdict.net !== 'mainnet') {
        this.log('warn', `login ${address.slice(0, 8)}… is a ${verdict.net} address: it will mine but cannot be paid`);
      }
    }

    // A wallet address is required to be payable later. Anything else is
    // accepted (test rigs use plain names) but flagged, and it never gets a
    // payout because `duePayouts` skips non-addresses.
    if (this.config.strict_address && !looksLikeAddress(address) && this.config.payout_mode === 'wallet') {
      this.stats.loginFailed += 1;
      this.reply(conn, id, null, { code: -1, message: 'login must be a Monero address (wallet.worker)' });
      this.drop(conn, 'invalid address');

      return;
    }

    const job = this.jobs.current;
    if (!job) {
      this.reply(conn, id, null, { code: -1, message: 'no job yet, retry in a second' });
      return;
    }

    conn.authorised = true;
    conn.login = login;
    conn.address = address;
    conn.agent = agent;
    conn.difficulty = Number(this.config.initial_difficulty || 2000);
    conn.session = `${++this.sessionSeq}`;
    this.stats.loginOk += 1;

    this.ledger.workerFor(address, worker);

    this.log('info', `login ${address.slice(0, 8)}…${worker ? `.${worker}` : ''} from ${conn.remote || 'unknown'} (${agent || 'no agent'})`);

    this.reply(conn, id, {
      id: conn.session,
      job: this.jobs.forMiner(job, conn.difficulty),
      status: 'OK',
      extensions: ['algo', 'keepalive'],
      // Published, not buried: the miner logs this, the status page shows it.
      fee: Number(this.config.fee_percent),
      pool: this.config.name,
    });
  }

  sendJob(conn, job, force) {
    if (!job) return;
    if (!force && conn.lastJobId === job.id) return;

    conn.lastJobId = job.id;
    // Plain difficulty, not the scaled BigInt: mixing the two made every
    // recorded share weight 1e6 times too large.
    conn.jobs.set(job.id, Number(conn.difficulty));

    // Keep the map small: jobs expiring anyway are useless.
    if (conn.jobs.size > 32) {
      const first = conn.jobs.keys().next().value;
      conn.jobs.delete(first);
    }

    conn.write(`${JSON.stringify({
      jsonrpc: '2.0',
      method: 'job',
      params: this.jobs.forMiner(job, conn.difficulty),
    })}\n`);
  }

  async onSubmit(conn, id, params) {
    if (!conn.authorised) {
      this.reply(conn, id, null, { code: -1, message: 'not logged in' });
      return;
    }

    const jobId = String(params.job_id || '');
    const nonce = String(params.nonce || '');
    const result = String(params.result || '');

    if (!jobId || !isHexOf(nonce, 4) || !isHexOf(result, 32)) {
      this.stats.badShares += 1;
      this.reply(conn, id, null, { code: -1, message: 'malformed share' });
      return;
    }

    const job = this.jobs.get(jobId);
    if (!job) {
      this.stats.stale += 1;
      this.reply(conn, id, null, { code: -21, message: 'job not found (stale)' });
      return;
    }

    if (!this.jobs.isFresh(job)) {
      this.stats.stale += 1;
      this.reply(conn, id, null, { code: -21, message: 'job expired' });
      return;
    }

    const difficulty = Number(conn.jobs.get(jobId) ?? conn.difficulty);
    let computed = null;

    // Recompute the hash ourselves. Without this the pool would be taking the
    // miner's word for work it never did.
    if (this.config.verify_shares && this.verifier) {
      try {
        computed = await this.verifier.verify({
          seed: job.seed,
          blob: job.blob,
          nonce,
          nonceOffset: job.nonceOffset,
        });
      } catch (error) {
        this.log('warn', `verification failed for ${conn.address?.slice(0, 8) || '?'}: ${error.message}`);
        this.stats.rejected += 1;
        conn.rejected += 1;
        this.reply(conn, id, null, { code: -1, message: 'verification unavailable, share dropped' });

        return;
      }

      if (computed.toLowerCase() !== result.toLowerCase()) {
        // The miner sent a hash that does not match the blob it was given.
        this.stats.badShares += 1;
        conn.rejected += 1;
        this.reply(conn, id, null, { code: -1, message: 'result does not match the job' });
        this.drop(conn, 'bad share hash');

        return;
      }
    }

    const hashBytes = hexToBytes(computed || result);
    if (!hashBytes) {
      this.stats.badShares += 1;
      this.reply(conn, id, null, { code: -1, message: 'bad hash' });

      return;
    }

    if (!meetsTarget(hashBytes, difficulty)) {
      this.stats.rejected += 1;
      conn.rejected += 1;
      this.reply(conn, id, null, { code: -1, message: 'low difficulty share' });

      return;
    }

    // --- accepted --------------------------------------------------------
    this.stats.accepted += 1;
    conn.accepted += 1;
    conn.shareTimes.push(nowSeconds());
    this.ledger.addShare(conn.login, difficulty);

    this.reply(conn, id, { status: 'OK' });

    // Block candidate? Compare against the network difficulty, not the share
    // difficulty. Synthetic mode never finds a block on purpose.
    if (this.config.mode !== 'synthetic' && job.networkDifficulty > 0) {
      if (meetsTarget(hashBytes, job.networkDifficulty)) {
        this.onBlockFound(job, nonce, result);
      }
    }

    if (this.config.vardiff) this.maybeAdjustDifficulty(conn);
  }

  maybeAdjustDifficulty(conn) {
    const now = nowSeconds();
    const window = now - conn.lastVardiff;

    if (window < 30) return;

    // Shares in the last `window` seconds, excluding the very first seconds of
    // a session (a fresh connection has no history and would jump wildly).
    const recent = conn.shareTimes.filter((ts) => ts > now - window);
    conn.shareTimes = recent;

    if (recent.length === 0) {
      // No shares in 30 s: the difficulty is too high for this miner.
      const lower = nextDifficulty(conn.difficulty, window * 2, Number(this.config.target_share_seconds), {
        min: this.config.min_difficulty,
        max: this.config.max_difficulty,
      });

      if (lower < conn.difficulty * 0.99) {
        conn.difficulty = clamp(lower, this.config.min_difficulty, this.config.max_difficulty);
        conn.lastVardiff = now;
        if (this.jobs.current) this.sendJob(conn, this.jobs.current, true);
      }

      return;
    }

    const observed = window / recent.length;
    const adjusted = nextDifficulty(conn.difficulty, observed, Number(this.config.target_share_seconds), {
      min: this.config.min_difficulty,
      max: this.config.max_difficulty,
    });

    // Only change when it matters (>15 %), otherwise every job announcement
    // looks like a difficulty change to the miner and statistics get noisy.
    if (Math.abs(adjusted - conn.difficulty) / conn.difficulty > 0.15) {
      conn.difficulty = clamp(adjusted, this.config.min_difficulty, this.config.max_difficulty);
      conn.lastVardiff = now;
      if (this.jobs.current) this.sendJob(conn, this.jobs.current, true);
      this.log('debug', `vardiff ${conn.address?.slice(0, 8)} -> ${conn.difficulty.toFixed(2)}`);
    } else {
      conn.lastVardiff = now;
    }
  }

  onBlockFound(job, nonce, hash) {
    this.stats.blocksFound += 1;
    this.log('info', `BLOCK candidate at height ${job.height}, hash ${hash.slice(0, 16)}…`);

    // The full template blob still holds a zero nonce; patch ours in before
    // handing it to the daemon.
    const blob = hexToBytes(job.fullBlob || job.blob);
    if (!blob) return;

    const nonceBytes = hexToBytes(nonce);
    if (nonceBytes) {
      for (let i = 0; i < 4 && job.nonceOffset + i < blob.length; i++) {
        blob[job.nonceOffset + i] = nonceBytes[i];
      }
    }

    const blockHex = blob.toString('hex');

    if (!this.daemon) return;

    this.daemon.submitBlock(blockHex).then((result) => {
      this.log('info', `block accepted: ${JSON.stringify(result).slice(0, 120)}`);

      const reward = BigInt(job.blockReward || '0');
      const record = this.ledger.distributeBlock({
        height: job.height,
        hash,
        rewardAtomic: reward,
        ts: nowSeconds(),
      });

      this.log('info', `distributed ${record.rewardXmr} XMR (fee ${record.feeXmr}) to ${record.distributed.length} miners`);
    }).catch((error) => {
      this.log('error', `submit_block failed: ${error.message}`);
    });
  }

  status() {
    const now = nowSeconds();

    return {
      pool: this.config.name,
      feePercent: Number(this.config.fee_percent),
      height: this.jobs.current?.height || 0,
      uptime: now - this.startedAt,
      connections: this.connections.size,
      miners: [...this.connections].filter((c) => c.authorised).length,
      accepted: this.stats.accepted,
      rejected: this.stats.rejected,
      stale: this.stats.stale,
      badShares: this.stats.badShares,
      blocksFound: this.stats.blocksFound,
      logins: this.stats.loginOk,
      verifier: this.verifier ? this.verifier.stats : null,
    };
  }
}

module.exports = { StratumPool };

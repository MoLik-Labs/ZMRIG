// Wires the pool together: TCP stratum, HTTP + WebSocket stratum, template
// feeder, verifier and payout timer. One process, no dependencies.

'use strict';

const fs = require('node:fs');
const http = require('node:http');
const net = require('node:net');

const { Daemon, TemplateFeeder } = require('./daemon');
const { JobStore } = require('./jobs');
const { Ledger } = require('./ledger');
const { StratumPool } = require('./stratum');
const { Verifier } = require('./verifier');
const { fastModeWarning } = require('./fit');
const { Wallet } = require('./wallet');
const httpApi = require('./http');
const ws = require('./ws');

class PoolServer {
  constructor(config, options = {}) {
    this.config = config;
    this.logger = options.logger || (() => {});
    this.log = (level, message) => this.logger(level, message);

    this.jobs = new JobStore({ ttl: config.job_ttl, logger: this.logger });
    this.ledger = new Ledger({
      feePercent: Number(config.fee_percent),
      operatorAddress: config.operator_address,
      windowSeconds: Number(config.pplns_window),
      minPayout: require('./util').parseXmr(config.payout_min).toString(),
      stateFile: config.state_file,
      auditFile: config.audit_file,
      logger: this.logger,
    });

    this.daemon = config.mode === 'monerod' ? new Daemon(config, { logger: this.logger }) : null;
    this.feeder = new TemplateFeeder({
      config,
      daemon: this.daemon || { getTemplate: async () => JobStore.synthetic() },
      jobs: this.jobs,
      logger: this.logger,
    });

    // Say it before the children are spawned, not after the OOM killer takes
    // one: `fast` is 2336 MB per verifier and the default is one per core.
    if (config.verify_shares && String(config.verifier_mode || '').trim().toLowerCase() === 'fast') {
      let meminfo;
      try {
        meminfo = fs.readFileSync('/proc/meminfo', 'utf8');
      } catch (_) {
        // Not Linux: no arithmetic, no warning.
      }
      const warning = fastModeWarning(meminfo, {
        mode: config.verifier_mode,
        concurrency: config.verifier_concurrency,
      });
      if (warning) this.log('warn', warning);
    }

    this.verifier = config.verify_shares
      ? new Verifier({
        binary: config.verifier_binary,
        concurrency: config.verifier_concurrency,
        timeout: config.verifier_timeout,
        mode: config.verifier_mode,
        threads: config.verifier_threads,
        pipeline: config.verifier_pipeline,
        logger: this.logger,
      })
      : null;

    this.pool = new StratumPool({
      config,
      ledger: this.ledger,
      jobs: this.jobs,
      verifier: this.verifier,
      daemon: this.daemon,
      logger: this.logger,
    });

    this.wallet = new Wallet(config, { logger: this.logger });
    this.servers = [];
    this.timers = [];
    this.startedAt = Date.now();
  }

  async start() {
    if (this.verifier) this.verifier.start();

    this.feeder.onTemplate = (job) => this.pool.broadcastTemplate(job);
    this.feeder.start();

    // The first job must exist before the listeners accept miners, otherwise
    // the first login gets "no job yet".
    if (this.config.mode === 'synthetic') {
      this.jobs.setTemplate(JobStore.synthetic(1000));
      this.pool.broadcastTemplate(this.jobs.current);
    } else {
      try {
        const template = await this.daemon.getTemplate();
        const job = this.jobs.setTemplate(template);
        this.pool.broadcastTemplate(job);
      } catch (error) {
        this.log('error', `no template at startup (${error.message}); miners will get jobs when the daemon answers`);
      }
    }

    // --- HTTP: status page, API, and the WebSocket stratum endpoint -------
    const httpServer = http.createServer((request, response) => {
      httpApi.handle(request, response, {
        pool: this.pool,
        ledger: this.ledger,
        config: this.config,
      }).catch((error) => {
        this.log('error', `http: ${error.message}`);
        try { response.writeHead(500); response.end('internal error'); } catch (_) {}
      });
    });

    ws.attach(httpServer, {
      path: this.config.ws_path,
      logger: this.logger,
      onConnection: (connection, request) => {
        this.pool.attach(connection, {
          remote: remoteOf(request, this.config),
          userAgent: request.headers['user-agent'] || '',
        });
      },
    });

    await listen(httpServer, this.config.bind, this.config.http_port);
    this.servers.push(httpServer);
    this.log('info', `http api + ws stratum on http://${this.config.bind}:${this.config.http_port}${this.config.ws_path}`);

    // --- TCP stratum (classic miners) -------------------------------------
    if (this.config.tcp_enabled) {
      const tcpServer = net.createServer((socket) => {
        socket.setNoDelay(true);

        const connection = {
          remote: `${socket.remoteAddress}:${socket.remotePort}`,
          write: (text) => socket.write(text),
          close: () => socket.destroy(),
          on: (event, handler) => {
            if (event === 'data') socket.on('data', handler);
            if (event === 'close') {
              socket.on('close', handler);
              socket.on('error', () => socket.destroy());
            }
          },
        };

        this.pool.attach(connection, { remote: connection.remote });
      });

      tcpServer.on('error', (error) => this.log('error', `tcp stratum: ${error.message}`));

      await listen(tcpServer, this.config.bind, this.config.port);
      this.servers.push(tcpServer);
      this.log('info', `tcp stratum on ${this.config.bind}:${this.config.port}`);
    } else {
      this.log('info', 'tcp stratum disabled (port == http port): WebSocket only');
    }

    // --- payouts ----------------------------------------------------------
    const payoutTimer = setInterval(() => {
      this.wallet.runRound(this.ledger).then((summary) => {
        if (summary.paid || summary.failed) {
          this.log('info', `payout round: paid ${summary.paid}, failed ${summary.failed}, skipped ${summary.skipped}`);
        }
      }).catch((error) => this.log('error', `payout round: ${error.message}`));
    }, Math.max(60, Number(this.config.payout_interval)) * 1000);
    payoutTimer.unref?.();
    this.timers.push(payoutTimer);

    // Persist the ledger regularly as well: a crash between blocks should not
    // lose the last few shares.
    const saveTimer = setInterval(() => this.ledger.save(), 60_000);
    saveTimer.unref?.();
    this.timers.push(saveTimer);

    this.log('info', `pool ready: fee ${this.config.fee_percent}% to ${this.config.operator_address.slice(0, 10)}…, mode ${this.config.mode}`);

    return this;
  }

  async stop() {
    for (const timer of this.timers) clearInterval(timer);
    this.timers = [];

    this.feeder.stop();
    if (this.verifier) this.verifier.close();

    for (const server of this.servers) {
      await new Promise((resolve) => server.close(resolve));
    }
    this.servers = [];

    this.ledger.save();
  }

  stats() {
    return { pool: this.pool.status(), ledger: this.ledger.stats() };
  }
}

function listen(server, host, port) {
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, host, () => {
      server.removeListener('error', reject);
      resolve();
    });
  });
}

function remoteOf(request, config) {
  if (config.trust_proxy) {
    const forwarded = request.headers['cf-connecting-ip'] || request.headers['x-forwarded-for'];
    if (forwarded) return String(forwarded).split(',')[0].trim();
  }

  return request.socket?.remoteAddress || 'unknown';
}

module.exports = { PoolServer };

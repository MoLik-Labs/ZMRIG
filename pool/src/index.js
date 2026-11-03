#!/usr/bin/env node
// Entry point.
//
//   node pool/src/index.js --config pool/config.json
//   POOL_FEE_PERCENT=1 OPERATOR_ADDRESS=4... node pool/src/index.js
//
// Prints one line per event to stdout so a PaaS log view is readable, and exits
// non-zero on a configuration error instead of starting a pool that cannot pay.

'use strict';

const path = require('node:path');
const fs = require('node:fs');

const { loadConfig, validateConfig } = require('./config');
const { PoolServer } = require('./server');
const { formatXmr } = require('./util');

function parseArgs(argv) {
  const out = { config: null, check: false };

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--config' || arg === '-c') out.config = argv[++i];
    else if (arg.startsWith('--config=')) out.config = arg.slice('--config='.length);
    else if (arg === '--check') out.check = true;
    else if (arg === '--help' || arg === '-h') out.help = true;
    else if (arg === '--version') out.version = true;
  }

  return out;
}

function makeLogger(level) {
  const order = { debug: 10, info: 20, warn: 30, error: 40 };
  const threshold = order[level] || 20;

  return (lvl, message) => {
    if ((order[lvl] || 20) < threshold) return;

    const stamp = new Date().toISOString().replace('T', ' ').slice(0, 19);
    const stream = lvl === 'error' || lvl === 'warn' ? process.stderr : process.stdout;
    stream.write(`[${stamp}] ${lvl.padEnd(5)} ${message}\n`);
  };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));

  if (args.help) {
    process.stdout.write(`zmrig-pool - ZMRIG's self-hosted Monero pool (by @nggkhaiz)

  node pool/src/index.js --config pool/config.json
  node pool/src/index.js --check          validate the configuration and exit

Environment overrides: PORT, HTTP_PORT, BIND, DAEMON, POOL_MODE, POOL_FEE_PERCENT,
OPERATOR_ADDRESS, WALLET_RPC, PAYOUT_MODE, VERIFY_SHARES, STATE_FILE, LOG_LEVEL.

Docs: pool/README.md - https://github.com/MoLik-Labs/ZMRIG
`);
    return;
  }

  if (args.version) {
    const pkg = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'package.json'), 'utf8'));
    process.stdout.write(`zmrig-pool ${pkg.version} - ZMRIG by @nggkhaiz\n`);

    return;
  }

  const config = loadConfig(args.config);
  const problems = validateConfig(config);
  const logger = makeLogger(config.log_level);

  if (problems.length) {
    for (const problem of problems) process.stderr.write(`config: ${problem}\n`);
    process.exit(1);
  }

  // Show the money path before anything else starts: an operator should always
  // be able to answer "where does the fee go" in one glance.
  logger('info', `${config.name}: fee ${config.fee_percent}% -> ${config.operator_address}`);
  logger('info', `mode ${config.mode}, payouts ${config.payout_mode}, verification ${config.verify_shares ? 'on' : 'OFF'}`);

  if (!config.verify_shares) {
    logger('warn', 'share verification is disabled: miners can submit work they never did');
  }

  if (config.mode === 'synthetic') {
    logger('warn', 'synthetic jobs: this pool cannot find real blocks (test mode)');
  }

  if (args.check) {
    logger('info', `config ok: tcp ${config.tcp_enabled ? config.port : 'off'}, http ${config.http_port}, ws ${config.ws_path}`);
    logger('info', `minimum payout ${formatXmr(BigInt(Math.round(Number(config.payout_min) * 1e12)))} XMR, reserve ${config.reserve} XMR`);

    return;
  }

  const server = new PoolServer(config, { logger });

  const shutdown = async (signal) => {
    logger('info', `${signal}: shutting down`);
    try {
      await server.stop();
    } catch (error) {
      logger('error', `shutdown: ${error.message}`);
    }
    process.exit(0);
  };

  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  // A bug in one handler must not take the pool down with it.
  process.on('uncaughtException', (error) => logger('error', `uncaught: ${error.stack || error.message}`));
  process.on('unhandledRejection', (error) => logger('error', `unhandled: ${error?.stack || error}`));

  await server.start();
}

main().catch((error) => {
  process.stderr.write(`fatal: ${error.stack || error.message}\n`);
  process.exit(1);
});

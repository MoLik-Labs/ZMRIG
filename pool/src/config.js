// Configuration: one JSON file plus environment overrides (hosts that only
// give you env vars, like Render or Fly, still work).

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const { operatorAddress } = require('./operator');
const { check } = require('./address');

// Long enough to hold a standard address and nothing else: the shape a typo
// preserves, which is exactly why the checksum below has to run.
const ADDRESS_SHAPE = /^[48][1-9A-HJ-NP-Za-km-z]{94}$/;

const DEFAULTS = {
  // --- identity ---------------------------------------------------------
  name: 'Ocean Pool',
  // Published, never hidden: this is what the pool keeps from every block.
  fee_percent: 1.0,
  // Where the fee goes. `null` means the built-in address in operator.js; set
  // OPERATOR_ADDRESS to redirect every piconero to your own wallet.
  operator_address: null,

  // --- network ----------------------------------------------------------
  port: 3333,                 // stratum over TCP (classic miners)
  http_port: 8080,            // HTTP API + status page + WebSocket stratum
  bind: '0.0.0.0',
  ws_path: '/stratum',        // WebSocket endpoint for --cloudflare miners
  // Cloudflare, nginx, or any reverse proxy in front: trust X-Forwarded-For.
  trust_proxy: true,

  // --- upstream chain ---------------------------------------------------
  // monerod JSON-RPC. A public node works for testing; for real blocks run
  // your own (see pool/README.md, "A node you actually own").
  daemon: 'http://127.0.0.1:18081',
  daemon_user: null,
  daemon_password: null,
  // How often to ask the daemon for a fresh template.
  template_interval: 5,
  // Optional second daemon; used when the first one fails.
  daemon_fallback: null,
  // "monerod" = real blocks. "synthetic" = deterministic test jobs, no daemon.
  mode: 'monerod',

  // --- shares -----------------------------------------------------------
  initial_difficulty: 2000,
  min_difficulty: 100,
  max_difficulty: 4e6,
  target_share_seconds: 15,
  vardiff: true,
  // A share is valid until its job is this old (Monero blocks are 2 minutes).
  job_ttl: 600,
  // Reject a share timestamped more than this many seconds away.
  clock_skew: 300,

  // --- verification -----------------------------------------------------
  // The pool re-hashes every share with zmrig --verify-share. Turning this off
  // means trusting miners, which is only reasonable for a private test pool.
  verify_shares: true,
  verifier_binary: 'zmrig',
  verifier_concurrency: 2,
  verifier_timeout: 10000,
  // `light` keeps a 256 MiB cache and rebuilds the dataset for every share:
  // 25 ms a share, warm, on the 2 vCPU test host. `fast` builds the 2 GiB
  // dataset once and reads it: 2.9 ms a share, measured, same hashes. It costs
  // 2.3 GiB of RAM *per verifier process* and 21 s at startup, so it is a
  // deliberate choice and not a default - see doc/POOLS.md.
  verifier_mode: 'light',

  // --- accounting -------------------------------------------------------
  // PPLNS: the last N seconds of shares split the block reward.
  pplns_window: 3600,
  // Minimum balance before a payout is sent (atomic units: 0.01 XMR).
  payout_min: '0.010000000000',
  payout_interval: 600,
  // wallet-rpc for payouts; "ledger" keeps balances without sending anything.
  payout_mode: 'ledger',
  wallet_rpc: 'http://127.0.0.1:18083',
  wallet_user: null,
  wallet_password: null,
  // Keep this much in the hot wallet for fees.
  reserve: '0.05',

  // --- housekeeping -----------------------------------------------------
  state_file: './data/state.json',
  audit_file: './data/audit.jsonl',
  log_level: 'info',
  // Refuse to start without an operator address that looks like Monero.
  strict_address: true,
};

function env(name, fallback) {
  const value = process.env[name];
  return value === undefined || value === '' ? fallback : value;
}

function envNumber(name, fallback) {
  const value = Number(process.env[name]);
  return Number.isFinite(value) && process.env[name] !== '' && process.env[name] !== undefined ? value : fallback;
}

function envBool(name, fallback) {
  const value = String(env(name, '')).toLowerCase();
  if (['1', 'true', 'yes', 'on'].includes(value)) return true;
  if (['0', 'false', 'no', 'off'].includes(value)) return false;
  return fallback;
}

function loadConfig(file, overrides = {}) {
  let fromFile = {};

  if (file) {
    const resolved = path.resolve(file);
    if (fs.existsSync(resolved)) {
      fromFile = JSON.parse(fs.readFileSync(resolved, 'utf8'));
    }
  }

  const config = {
    ...DEFAULTS,
    ...fromFile,
    ...overrides,
  };

  // Environment wins over the file: that is how a PaaS injects secrets.
  config.port = envNumber('PORT', envNumber('POOL_PORT', config.port));
  config.http_port = envNumber('HTTP_PORT', config.http_port);
  config.bind = env('BIND', config.bind);
  config.daemon = env('DAEMON', config.daemon);
  config.daemon_user = env('DAEMON_USER', config.daemon_user);
  config.daemon_password = env('DAEMON_PASSWORD', config.daemon_password);
  config.mode = env('POOL_MODE', config.mode);
  config.operator_address = env('OPERATOR_ADDRESS', config.operator_address) || operatorAddress();
  config.fee_percent = envNumber('POOL_FEE_PERCENT', config.fee_percent);
  config.name = env('POOL_NAME', config.name);
  config.wallet_rpc = env('WALLET_RPC', config.wallet_rpc);
  config.wallet_user = env('WALLET_USER', config.wallet_user);
  config.wallet_password = env('WALLET_PASSWORD', config.wallet_password);
  config.payout_mode = env('PAYOUT_MODE', config.payout_mode);
  config.verify_shares = envBool('VERIFY_SHARES', config.verify_shares);
  config.state_file = env('STATE_FILE', config.state_file);
  config.audit_file = env('AUDIT_FILE', config.audit_file);
  config.log_level = env('LOG_LEVEL', config.log_level);
  config.ws_path = env('WS_PATH', config.ws_path);

  // Difficulty and accounting knobs, also useful to tests.
  config.initial_difficulty = envNumber('INITIAL_DIFFICULTY', config.initial_difficulty);
  config.min_difficulty = envNumber('MIN_DIFFICULTY', config.min_difficulty);
  config.max_difficulty = envNumber('MAX_DIFFICULTY', config.max_difficulty);
  config.target_share_seconds = envNumber('TARGET_SHARE_SECONDS', config.target_share_seconds);
  config.vardiff = envBool('VARDIFF', config.vardiff);
  config.job_ttl = envNumber('JOB_TTL', config.job_ttl);
  config.pplns_window = envNumber('PPLNS_WINDOW', config.pplns_window);
  config.payout_min = env('PAYOUT_MIN', config.payout_min);
  config.payout_interval = envNumber('PAYOUT_INTERVAL', config.payout_interval);
  config.reserve = env('RESERVE', config.reserve);
  config.verifier_binary = env('VERIFIER_BINARY', config.verifier_binary);
  config.verifier_concurrency = envNumber('VERIFIER_CONCURRENCY', config.verifier_concurrency);
  // Trimmed as well as lowercased: `VERIFIER_MODE="fast "` in a compose file
  // is a fast pool, not a silent light one.
  config.verifier_mode = String(env('VERIFIER_MODE', config.verifier_mode)).trim().toLowerCase();
  config.template_interval = envNumber('TEMPLATE_INTERVAL', config.template_interval);
  config.strict_address = envBool('STRICT_ADDRESS', config.strict_address);

  // A single HTTP port is common on free hosts: when HTTP_PORT equals PORT the
  // TCP stratum listener is skipped and only the WebSocket endpoint is served.
  config.tcp_enabled = config.port > 0 && config.port !== config.http_port;

  return config;
}

/** Problems that must stop the pool instead of quietly taking fees for
 *  nothing. Returned as strings so the caller can print them all at once. */
function validateConfig(config) {
  const problems = [];
  const fee = Number(config.fee_percent);

  if (!Number.isFinite(fee) || fee < 0 || fee > 10) {
    problems.push(`fee_percent must be between 0 and 10, got ${config.fee_percent}`);
  }

  // The fee destination is the one address in this process that never logs in,
  // so the pool's own login check never sees it. A single wrong character in it
  // is still a 95-character base58 string: it looks like an address, it is
  // published on the status page, and every fee payment would go to a key
  // nobody holds. Ledger mode still tolerates a placeholder - nothing leaves
  // the box - but a string shaped like an address has to decode.
  const feeAddress = String(config.operator_address ?? '').trim();
  if (ADDRESS_SHAPE.test(feeAddress)) {
    const verdict = check(feeAddress);
    if (!verdict.ok) {
      problems.push(`operator_address cannot be paid: ${verdict.reason} (${feeAddress})`);
    }
  } else if (config.strict_address && config.payout_mode !== 'ledger') {
    // Only enforced when real money can move, and only for values that are not
    // address-shaped at all (a placeholder like "not-an-address").
    const { looksLikeAddress } = require('./util');
    if (!looksLikeAddress(config.operator_address)) {
      problems.push(`operator_address does not look like a Monero address: ${config.operator_address}`);
    }
  }

  if (!['monerod', 'synthetic'].includes(config.mode)) {
    problems.push(`mode must be monerod or synthetic, got ${config.mode}`);
  }

  if (!['ledger', 'wallet'].includes(config.payout_mode)) {
    problems.push(`payout_mode must be ledger or wallet, got ${config.payout_mode}`);
  }

  if (Number(config.pplns_window) < 60) {
    problems.push('pplns_window below 60 s makes payouts a lottery');
  }

  return problems;
}

module.exports = { DEFAULTS, loadConfig, validateConfig };

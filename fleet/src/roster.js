// The roster: the fleet, written down before it checks in.
//
// A free host keeps nothing. Render's filesystem is empty after a redeploy, a
// restart, or fifteen minutes with no traffic, so an enrolment that lives in a
// file is an enrolment that is lost every night - and re-enrolling twelve rigs
// by hand every morning is not a control plane. The state that matters (who
// owns which rig, and what each one should be running) therefore lives in the
// environment, where it survives every restart because it was never on the disk.
//
//   FLEET_ROSTER='{"rigs": {"ZMR-1A2B-3C4D-5E6F": {"label": "basement", "wallet": "4..."}}}'
//
// The same JSON can sit in `fleet/roster.json` for people who would rather keep
// it in the repository; the environment wins when both exist, so a deploy hook
// can override one entry without editing a file. Nothing here is secret: the
// rig's own key never appears in it, and the wallet is an address.
//
// Everything in an entry except the ID is optional, and an entry that sets
// nothing is still useful: it makes a rig enrolled, which is what lets commands
// reach it.

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const ids = require('./ids');
const { walletProblem, validPool } = require('./commands');

const MODES = new Set(['max', 'balanced', 'eco', 'light', 'safe']);
const COINS = new Set(['xmr', 'wow', 'arq', 'graft', 'sfx', 'yada', 'xla']);
// The keys an entry may carry. Anything else is a typo, and a typo in a roster
// is a setting that silently does nothing - so it is reported, not ignored.
const KEYS = new Set(['label', 'owner', 'wallet', 'pool', 'coin', 'mode', 'maxtemp', 'threads', 'worker']);

function text(value) {
  return typeof value === 'string' ? value.trim() : value === 0 ? '0' : '';
}

/** One entry, validated. Returns `{ entry, problems }`; a bad field is dropped
 *  rather than taking the whole rig with it, because a rig that is in the
 *  roster but misconfigured still needs to be reachable. */
function normalise(id, raw, defaults) {
  const problems = [];
  const entry = { id, desired: {} };
  if (raw === null || raw === undefined) return { entry, problems };
  if (typeof raw !== 'object' || Array.isArray(raw)) {
    problems.push(`${id}: expected an object`);
    return { entry, problems };
  }

  for (const key of Object.keys(raw)) {
    if (!KEYS.has(key) && !key.startsWith('$')) problems.push(`${id}: unknown key "${key}"`);
  }

  const label = text(raw.label);
  if (label) entry.label = label.slice(0, 40);

  const owner = text(raw.owner) || defaults.owner;
  if (owner) entry.owner = owner;

  // `wallet`/`pool` at the top of the roster are the ones a farm shares: six
  // machines in a shed mine into one address, and writing it six times is six
  // chances to mistype one and quietly split the balance.
  const wallet = text(raw.wallet) || defaults.wallet;
  const coin = text(raw.coin).toLowerCase() || 'xmr';
  if (raw.coin !== undefined && !COINS.has(coin)) {
    problems.push(`${id}: unknown coin "${raw.coin}"`);
  } else {
    entry.desired.coin = COINS.has(coin) ? coin : 'xmr';
  }
  if (wallet) {
    const problem = walletProblem(wallet, entry.desired.coin);
    if (!problem) entry.desired.wallet = wallet;
    else problems.push(`${id}: wallet ${problem}`);
  }

  const pool = text(raw.pool) || defaults.pool;
  if (pool) {
    if (validPool(pool)) entry.desired.pool = pool;
    else problems.push(`${id}: pool must be host:port`);
  }

  const mode = text(raw.mode).toLowerCase();
  if (mode) {
    if (MODES.has(mode)) entry.desired.mode = mode;
    else problems.push(`${id}: unknown mode "${raw.mode}" (${[...MODES].join(' ')})`);
  }

  if (raw.maxtemp !== undefined) {
    const temp = Number.parseInt(String(raw.maxtemp), 10);
    if (Number.isFinite(temp) && temp >= 45 && temp <= 95) entry.desired.maxtemp = temp;
    else problems.push(`${id}: maxtemp must be 45..95`);
  }

  if (raw.threads !== undefined && raw.threads !== null && raw.threads !== '') {
    const threads = String(raw.threads).trim().toLowerCase();
    if (threads === 'auto') entry.desired.threads = 'auto';
    else if (/^[0-9]{1,3}$/.test(threads) && Number(threads) > 0) entry.desired.threads = threads;
    else problems.push(`${id}: threads must be a number or "auto"`);
  }

  const worker = text(raw.worker);
  if (worker) entry.desired.worker = worker.slice(0, 32);

  return { entry, problems };
}

/** Accepts `{"rigs": {...}}`, a bare `{"ZMR-...": {...}}` map, or an array of
 *  `{"id": "ZMR-...", ...}` objects. Three shapes is two too many, but the
 *  third is what a person writes by hand and the first is what a tool emits. */
function shape(parsed, problems) {
  if (Array.isArray(parsed)) {
    const rigs = new Map();
    for (const item of parsed) {
      const id = text(item && item.id).toUpperCase();
      if (!ids.isDeviceId(id)) {
        problems.push(`array entry without a usable id: ${JSON.stringify(item).slice(0, 60)}`);
        continue;
      }
      rigs.set(id, item);
    }
    return { rigs, defaults: { owner: text(parsed.length && parsed[0] && parsed[0].owner) } };
  }
  if (!parsed || typeof parsed !== 'object') {
    problems.push('the roster is not an object');
    return { rigs: new Map(), defaults: { owner: '' } };
  }
  const defaults = {
    owner: text(parsed.owner),
    wallet: text(parsed.wallet),
    pool: text(parsed.pool),
  };
  const source = parsed.rigs && typeof parsed.rigs === 'object' ? parsed.rigs : parsed;
  const rigs = new Map();
  for (const [key, value] of Object.entries(source)) {
    if (key.startsWith('$') || key === 'owner' || key === 'wallet' || key === 'pool' || key === 'rigs') continue;
    const id = key.trim().toUpperCase();
    if (!ids.isDeviceId(id)) {
      problems.push(`${key}: not a Device ID (ZMR-XXXX-XXXX-XXXX)`);
      continue;
    }
    rigs.set(id, value);
  }
  return { rigs, defaults };
}

/** Parse roster JSON. Never throws: a broken roster must not stop the bot, it
 *  must be reported, because the bot is how the person finds out. */
function parse(raw, log = () => {}) {
  const problems = [];
  let parsed;
  try {
    parsed = typeof raw === 'string' ? JSON.parse(raw) : raw;
  } catch (error) {
    problems.push(`the roster is not valid JSON: ${error.message}`);
    log(`roster: ${problems[0]}`);
    return { rigs: new Map(), problems };
  }

  const { rigs, defaults } = shape(parsed, problems);
  const clean = new Map();
  for (const [id, value] of rigs) {
    const { entry, problems: bad } = normalise(id, value, defaults);
    problems.push(...bad);
    clean.set(id, entry);
  }
  for (const problem of problems) log(`roster: ${problem}`);
  return { rigs: clean, problems };
}

/** Environment first, then `<fleet>/roster.json`, then nothing. Reading a file
 *  is the documented alternative for people who want their fleet in git; it is
 *  never written to. */
function load(env = process.env, options = {}) {
  const log = options.log || (() => {});
  const inline = typeof env.FLEET_ROSTER === 'string' ? env.FLEET_ROSTER.trim() : '';
  if (inline) return { ...parse(inline, log), source: 'FLEET_ROSTER' };

  const file = env.FLEET_ROSTER_FILE || options.file || '';
  if (file) {
    try {
      return { ...parse(fs.readFileSync(path.resolve(file), 'utf8'), log), source: file };
    } catch (error) {
      if (error.code !== 'ENOENT') log(`roster: cannot read ${file}: ${error.message}`);
      return { rigs: new Map(), problems: [], source: '' };
    }
  }
  return { rigs: new Map(), problems: [], source: '' };
}

/** Write the roster into the store: create the record if the rig has never
 *  checked in, and refresh what the roster owns on every start. Live fields
 *  (status, log, queue) are never touched - they belong to the rig. */
function apply(store, roster, now = Date.now()) {
  if (!roster || !roster.rigs || roster.rigs.size === 0) return [];
  const applied = [];
  for (const entry of roster.rigs.values()) {
    const record = store.define(entry.id, entry, now);
    if (record) applied.push(record);
  }
  return applied;
}

module.exports = { load, parse, apply, normalise, MODES, COINS, KEYS };

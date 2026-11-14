// Reconciliation, not commands.
//
// On a host that keeps nothing, the bot has to be able to disappear and come
// back without changing what the fleet is running. So the roster says what each
// rig *should* be, the check-in says what it *is*, and this module computes the
// difference every time the rig calls in. Nothing else is stored: a restart
// re-derives the same answer from the same two inputs.
//
// That also makes the roster authoritative in a way a command queue is not. A
// queued command is a message that may never arrive; a roster entry is a fact
// that is re-checked a minute from now, and the minute after that.

'use strict';

const { validPool } = require('./commands');

// How long to wait before pushing the same correction again. A rig that refuses
// a command (a wallet for the wrong coin, a pool it cannot resolve) reports the
// old value back on every check-in; without this it would be re-told every
// minute for ever, and the operator would see a robot shouting at a machine
// that is already doing what it can.
const RETRY_AFTER = 300_000;

/** What the rig would have to be told to match the roster. Only fields the
 *  roster actually sets are considered: an entry that says nothing about the
 *  pool leaves the pool alone. */
function diff(status = {}, desired = {}) {
  const args = {};

  if (desired.wallet && status.wallet !== desired.wallet) args.wallet = desired.wallet;
  if (desired.pool && status.pool !== desired.pool && validPool(desired.pool)) args.pool = desired.pool;
  if (desired.coin && (status.coin || 'xmr') !== desired.coin) args.coin = desired.coin;

  if (desired.mode && status.mode !== desired.mode) {
    args.mode = desired.mode;
    // The heat cap only means anything in safe mode, so it travels with a mode
    // change into it. It is also compared on its own below: a roster that only
    // turns the cap down is a decision, not decoration.
    if (desired.mode === 'safe' && desired.maxtemp) args.maxtemp = desired.maxtemp;
  }

  // A rig reports the cap it is holding. Until 6.48 it did not, which made the
  // roster's `maxtemp` unenforceable: the diff could not see a difference, so
  // changing only the cap queued nothing and the rig kept the old one for ever.
  // `status.maxtemp` absent means an older agent, and an old agent must not be
  // told every five minutes about a field it has never heard of.
  if (desired.maxtemp && status.maxtemp !== undefined && status.maxtemp !== null && status.maxtemp !== '') {
    if (String(status.maxtemp) !== String(desired.maxtemp)) args.maxtemp = desired.maxtemp;
  }

  // `threads` is compared as text because the rig answers `auto` or a number.
  // It is the one field a rig may legitimately move on its own (it measures the
  // machine and pins the result), so a roster entry that sets it is a decision
  // to stop that: `zmrig-os setup --threads N` clears the measurement.
  if (desired.threads && String(status.threads || '') !== String(desired.threads)) {
    args.threads = desired.threads;
  }

  if (desired.worker && status.worker !== desired.worker) args.worker = desired.worker;

  return args;
}

/** Called on every check-in for a rig the roster knows about. Returns the
 *  command it queued, or a short reason it did not. */
function run(store, record, entry, options = {}) {
  const now = options.now || Date.now();
  const log = options.log || (() => {});
  const limit = options.queue_limit || 10;
  const retry = options.retry_after || RETRY_AFTER;
  const status = record.status || {};

  // Nothing to reconcile until the machine has said something about itself.
  if (!status.state) return { queued: null, why: 'no status yet' };

  const args = diff(status, entry.desired || {});
  const fields = Object.keys(args);
  if (fields.length === 0) {
    // It matches. Forget the last correction so that a later drift is pushed
    // at once rather than waiting out a cooldown that no longer means anything.
    if (record.correction_at) {
      record.correction_at = 0;
      record.correction_args = '';
      record.correction_fields = '';
      store.touch();
    }
    return { queued: null, why: 'matches' };
  }

  const signature = JSON.stringify(args);
  if (record.correction_at && record.correction_args === signature && now - record.correction_at < retry) {
    return { queued: null, why: 'already asked, waiting' };
  }

  // One setup command in flight at a time. Two overlapping ones would be applied
  // in order and the second would be a change nobody asked for.
  if (record.queue.some((entry2) => entry2.cmd === 'setup')) {
    return { queued: null, why: 'one is already queued' };
  }

  const queued = store.push(record.id, { cmd: 'setup', args }, limit);
  if (!queued) return { queued: null, why: 'queue is full' };

  record.correction_at = now;
  record.correction_args = signature;
  record.correction_fields = fields.join(',');
  store.touch();

  log(`roster: ${record.id} told to apply ${fields.join(', ')}`);
  return { queued, why: `pushed ${fields.join(',')}` };
}

/** Apply the roster to a store at startup. Kept here so a caller has one import
 *  for "make the store reflect the roster". */
function apply(store, roster, now = Date.now()) {
  const module = require('./roster');
  return module.apply(store, roster, now);
}

module.exports = { diff, run, apply, RETRY_AFTER };

// One wallet, many machines.
//
// A farm is not a directory of rigs, it is a wallet: everything mining to the
// same address is one number at the pool, one balance, and one answer to "how am
// I doing". The rigs are only how that number gets produced. So the fleet groups
// by wallet - not by machine, not by name - and the group total is the number
// that matters when somebody has six boxes in a shed.
//
// Nothing here is stored: the group is a function of the check-ins that are
// already in memory, recomputed every time somebody looks.

'use strict';

const format = require('./format');
const { presence } = require('./store');

// Rigs that have not reported a wallet yet are their own group rather than being
// silently folded into the first one: a rig mining into the wrong address is the
// mistake this view exists to make visible.
const UNKNOWN = '';

function label(wallet) {
  return wallet ? format.wallet(wallet) : 'no wallet yet';
}

/** Group records by the wallet they are mining into.
 *
 *  Only rigs that are online contribute hashrate: a rig that has been silent for
 *  an hour did not stop mining, but reporting its last number as current is how a
 *  dashboard lies. The count of rigs is always every rig in the group. */
function group(devices, config, now = Date.now()) {
  const groups = new Map();

  for (const record of devices) {
    if (!record || !record.owner) continue;
    const status = record.status || {};
    const wallet = String(status.wallet || '').trim();
    const key = wallet || UNKNOWN;

    if (!groups.has(key)) {
      groups.set(key, { wallet: key, label: label(key), coin: '', rigs: 0, mining: 0, online: 0, rate: 0, hottest: 0, devices: [] });
    }

    const entry = groups.get(key);
    // The coin travels with the group so the dashboard can judge the address:
    // the same 95 characters are a typo under Monero and an ordinary login
    // under another chain's algorithm.
    if (!entry.coin) entry.coin = String((record.status && record.status.coin) || '').toLowerCase();
    entry.rigs += 1;
    entry.devices.push(record);
    const state = presence(record, config, now);
    if (state !== 'online') continue;

    entry.online += 1;
    entry.rate += Number(status.hashrate) || 0;
    entry.hottest = Math.max(entry.hottest, Number(status.temp) || 0);
    if (status.state === 'mining') entry.mining += 1;
  }

  // Biggest first, and the "no wallet" group last whatever its size, because it
  // is the one that needs attention rather than the one that matters.
  return [...groups.values()].sort((a, b) => {
    if ((a.wallet === UNKNOWN) !== (b.wallet === UNKNOWN)) return a.wallet === UNKNOWN ? 1 : -1;
    if (b.rate !== a.rate) return b.rate - a.rate;
    return b.rigs - a.rigs;
  });
}

/** One line per wallet, with its share of the fleet.
 *
 *  The share is of the total the fleet is producing right now, so a group that is
 *  entirely offline reads 0% instead of dividing by zero. */
function lines(groups, options = {}) {
  const total = groups.reduce((sum, entry) => sum + entry.rate, 0);
  const max = options.max || 8;

  return groups.slice(0, max).map((entry) => {
    const share = total > 0 ? Math.round((entry.rate / total) * 100) : 0;
    const rigs = entry.rigs === 1 ? '1 rig' : `${entry.rigs} rigs`;
    const state = entry.online === 0 ? 'offline' : `${entry.mining}/${entry.rigs} mining`;
    return `${entry.label}  ${format.hashrate(entry.rate)}  ${share}%  ${rigs}, ${state}`;
  });
}

module.exports = { group, lines, UNKNOWN };

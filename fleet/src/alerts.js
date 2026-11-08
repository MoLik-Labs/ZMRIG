// Alerts are the reason a fleet bot exists. Everything else is convenience.
//
// Two rules shape this file:
//   * an alert is an event, not a state. A rig at 91 C must not send a message
//     every minute until somebody reads it, so each kind has a cooldown and the
//     recovery is reported separately.
//   * a rig that stops checking in is the most common failure of all, and no
//     message from it will ever say so. That is the sweep.

'use strict';

const format = require('./format');
const address = require('./address');

function mark(record, kind, now) {
  record.alerts = record.alerts || {};
  record.alerts[kind] = now;
}

function cooling(record, kind, config, now) {
  const last = (record.alerts || {})[kind];
  if (!last) return true;
  return now - last > config.alert_cooldown * 1000;
}

function name(record) {
  return record.label || record.id;
}

/** How many rigs report this wallet, and whether one of them has already told
 *  the chat inside the same cooldown window. */
function farmOn(store, wallet, config, now, selfId) {
  if (!store) return { count: 1, others: 0 };

  let count = 0;
  let others = 0;
  for (const other of store.devices()) {
    if (String((other.status && other.status.wallet) || '') !== wallet) continue;
    count += 1;
    if (other.id === selfId) continue;
    const told = (other.alerts || {}).wallet;
    if (told && now - told <= config.alert_cooldown * 1000) others += 1;
  }

  return { count: Math.max(count, 1), others };
}

/** Fires on a check-in, comparing what the rig says now with what it said at the
 *  last one. `before` is that previous status, or null on the first check-in.
 *  `store`, when given, is used for one thing: a bad wallet is a property of the
 *  address, not of the rig, so the message says how many rigs it affects and is
 *  sent once per cooldown instead of once per rig. */
function onHello(record, config, now, before, store) {
  const out = [];
  const status = record.status || {};
  const previous = before || {};

  // A rig cannot report that it is offline: it is silent, and `sweep` is what
  // notices. So `offline_notified` is the only evidence that the humans were
  // told, and a check-in carrying it is the recovery. This used to also require
  // that the last status was not `mining` - which is what a rig that dropped
  // out is almost always reporting - so the one case people care about, a rig
  // that came back and is hashing again, was the one case that stayed quiet.
  if (record.offline_notified) {
    out.push({ kind: 'online', level: 'info', text: `🟢 **${name(record)}** is back after ${format.duration((now - (record.last_gap || now)) / 1000)}` });
    record.offline_notified = false;
  }

  const temp = Number(status.temp) || 0;
  if (temp >= config.alert_temp && cooling(record, 'temp', config, now)) {
    mark(record, 'temp', now);
    out.push({ kind: 'temp', level: 'warn', text: `🔥 **${name(record)}** is at ${format.temperature(temp)}` });
  }

  if (
    status.state === 'stopped' &&
    previous.state &&
    previous.state !== 'stopped' &&
    cooling(record, 'stopped', config, now)
  ) {
    mark(record, 'stopped', now);
    out.push({ kind: 'stopped', level: 'warn', text: `⏸ **${name(record)}** stopped mining (${status.reason || 'no reason given'})` });
  }

  // The wallet the rig is mining to. A rig that reports an address with a
  // broken checksum is mining for nobody: the pool refuses the login, or - on a
  // pool that only looks at the alphabet - credits an account that can never be
  // paid. This is checked here, on the dashboard and in the chat, because the
  // rig itself has no way to notice.
  const wallet = String(status.wallet || '');
  if ((wallet.length === 95 || wallet.length === 106) && cooling(record, 'wallet', config, now)) {
    const verdict = address.check(wallet);
    if (!verdict.ok || verdict.net !== 'mainnet') {
      mark(record, 'wallet', now);

      // One farm, one wallet, one message. Every rig on the farm reports the
      // same address, and they check in within seconds of each other, so the
      // first version of this alert sent eleven identical warnings about one
      // typo - and a chat that cries wolf eleven times is a chat people mute.
      // The rig is still marked, so it will not alert again on its own later;
      // what it does not do is repeat what another rig just said.
      // Skipping the message must not skip the rest of the check-in: a rig
      // whose wallet warning was already sent by its neighbour still gets to
      // report that its hashrate halved.
      const farm = farmOn(store, wallet, config, now, record.id);
      if (farm.others === 0) {
        const plural = farm.count > 1;
        const who = plural ? `${farm.count} rigs` : name(record);
        out.push({
          kind: 'wallet',
          level: 'warn',
          text: verdict.ok
            ? `💸 **${who}** ${plural ? 'mine' : 'mines'} to a ${verdict.net} address: a mainnet pool cannot pay it`
            : plural
              ? `💸 **${who}** all mine to an address that cannot be paid - ${verdict.reason}. Nothing mined to it can be paid.`
              : `💸 **${who}** has an invalid wallet address - ${verdict.reason}. Nothing mined to it can be paid.`,
        });
      }
    }
  }

  const rate = Number(status.hashrate) || 0;
  const was = Number(previous.hashrate) || 0;
  if (status.state === 'mining' && was > 0 && rate > 0 && rate < was * config.alert_hashrate_drop && cooling(record, 'hashrate', config, now)) {
    mark(record, 'hashrate', now);
    out.push({
      kind: 'hashrate',
      level: 'warn',
      text: `📉 **${name(record)}** hashrate fell from ${format.hashrate(was)} to ${format.hashrate(rate)}`,
    });
  }

  // The comparison above is between two check-ins a minute apart: it catches a
  // rig that just fell over and says nothing about one that has been sliding
  // for a week. This is the other half -- the rate the rig measured on itself
  // when it tuned, which does not move with the weather.
  const measured = Number(status.measured) || 0;
  if (
    status.state === 'mining' &&
    measured > 0 &&
    rate > 0 &&
    rate < measured * config.alert_hashrate_drop &&
    cooling(record, 'drift', config, now)
  ) {
    mark(record, 'drift', now);
    out.push({
      kind: 'drift',
      level: 'warn',
      text: `🐌 **${name(record)}** is at ${format.hashrate(rate)}, ${Math.round((rate / measured) * 100)}% of the ${format.hashrate(measured)} it measured itself`,
    });
  }

  return out;
}

/** Called on a timer: silence is the failure mode that has no message. */
function sweep(store, config, now) {
  const out = [];
  for (const record of store.devices()) {
    if (!record.owner || !record.last_seen) continue;
    const silent = now - record.last_seen;
    if (silent > config.offline_after * 1000 && !record.offline_notified) {
      record.offline_notified = true;
      record.last_gap = record.last_seen;
      store.touch();
      out.push({
        kind: 'offline',
        level: 'warn',
        text: `⚫ **${name(record)}** has not checked in for ${format.duration(silent / 1000)}`,
        record,
      });
    }
  }
  return out;
}

/** Results of the instructions the rig has executed, reported back to the chat
 *  that asked for them (or to the operators, when the request came from a
 *  button press by somebody who is still in the chat). */
function onAcks(record, acks, now) {
  const out = [];
  for (const ack of acks || []) {
    if (ack.ok) {
      out.push({ kind: 'ack', level: 'info', text: `✅ **${name(record)}**: ${ack.cmd}${ack.detail ? ` - ${ack.detail}` : ''}` });
    } else {
      out.push({ kind: 'ack', level: 'warn', text: `❌ **${name(record)}**: ${ack.cmd} failed - ${ack.detail || 'no detail'}` });
    }
  }
  return out;
}

module.exports = { onHello, sweep, onAcks, cooling, mark };

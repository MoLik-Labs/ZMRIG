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

/** Fires on a check-in, comparing what the rig says now with what it said at the
 *  last one. `before` is that previous status, or null on the first check-in. */
function onHello(record, config, now, before) {
  const out = [];
  const status = record.status || {};
  const previous = before || {};

  if (previous.state === 'offline' || (record.offline_notified && previous.state !== 'mining')) {
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

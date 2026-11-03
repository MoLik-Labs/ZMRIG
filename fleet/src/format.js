// How numbers become sentences. Kept apart from the commands so the same line
// reads the same on Telegram and on Discord, and so a test can assert it.

'use strict';

function hashrate(value) {
  const rate = Number(value) || 0;
  if (rate <= 0) return '0 H/s';
  if (rate >= 1e6) return `${(rate / 1e6).toFixed(2)} MH/s`;
  if (rate >= 1e3) return `${(rate / 1e3).toFixed(1)} kH/s`;
  return `${rate.toFixed(0)} H/s`;
}

function duration(seconds) {
  const total = Math.max(0, Math.floor(Number(seconds) || 0));
  const days = Math.floor(total / 86400);
  const hours = Math.floor((total % 86400) / 3600);
  const minutes = Math.floor((total % 3600) / 60);

  if (days > 0) return `${days}d ${hours}h`;
  if (hours > 0) return `${hours}h ${minutes}m`;
  if (minutes > 0) return `${minutes}m`;
  return `${total}s`;
}

function ago(then, now = Date.now()) {
  if (!then) return 'never';
  const seconds = Math.round((now - then) / 1000);
  if (seconds < 60) return `${Math.max(0, seconds)}s ago`;
  return `${duration(seconds)} ago`;
}

function temperature(value) {
  const degrees = Number(value);
  if (!Number.isFinite(degrees) || degrees <= 0) return '-';
  return `${degrees.toFixed(0)} C`;
}

function wallet(address) {
  const text = String(address || '');
  if (text.length <= 12) return text || '-';
  return `${text.slice(0, 6)}...${text.slice(-4)}`;
}

const STATE_ICON = {
  mining: '🟢',
  stopped: '⚪',
  starting: '🟡',
  error: '🔴',
  waiting: '🟡',
  offline: '⚫',
};

function icon(state) {
  return STATE_ICON[state] || '❔';
}

/** Fixed-width-ish table for a monospace font. Discord and Telegram both render
 *  a fenced block in monospace, and a rig list that does not line up is a rig
 *  list nobody scans. */
function table(rows, headers) {
  const all = [headers, ...rows];
  const widths = headers.map((_, column) =>
    Math.max(...all.map((row) => String(row[column] ?? '').length)),
  );
  return all
    .map((row) =>
      row
        .map((cell, column) => String(cell ?? '').padEnd(widths[column]))
        .join('  ')
        .trimEnd(),
    )
    .join('\n');
}

module.exports = { hashrate, duration, ago, temperature, wallet, icon, table };

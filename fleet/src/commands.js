// What the bot can do, written once for every chat platform.
//
// This module is pure: text in, text and buttons out. Neither Telegram nor
// Discord appears in it, which is why the whole command surface - enrolment,
// the wallet validator, the queue depth, the permission checks - can be tested
// without a token, a network or a bot account.

'use strict';

const ids = require('./ids');
const format = require('./format');
const { presence } = require('./store');

const COINS = {
  xmr: 'rx/0',
  monero: 'rx/0',
  wow: 'rx/wow',
  wownero: 'rx/wow',
  arq: 'rx/arq',
  graft: 'rx/graft',
  sfx: 'rx/sfx',
  yada: 'rx/yada',
  xla: 'panthera',
};

const MODES = {
  max: 'every core the cache allows, high priority',
  balanced: 'one core left for the system',
  eco: 'half the cores, watts over hashrate',
  light: '256 MiB cache mode, for small machines',
  safe: 'one core left, low priority, thermal governor on',
};

const HELP = [
  '**ZMRIG fleet**',
  '',
  '**Enrol a rig**',
  '`/enroll ZMR-XXXX-XXXX-XXXX ABCD-1234 [name]`',
  'The ID and the code are printed on the machine (`zmrig-os id`). The code is',
  'derived from the rig\'s own key, so it proves the machine is in front of you.',
  '',
  '**Every rig**',
  '`/devices` - all of them, with state, hashrate and temperature',
  '`/status` - the fleet, one screen',
  '`/device <rig>` - one rig, with buttons',
  '',
  '**One rig** (`<rig>` is the ID, a unique part of it, or the name you gave it)',
  '`/wallet <rig> <address>` - set the wallet',
  '`/pool <rig> host:port` - set the pool',
  '`/coin <rig> xmr` - xmr wow arq graft sfx yada xla',
  '`/mode <rig> max|balanced|eco|light|safe [C]` - aggression, and a heat cap',
  '`/threads <rig> 8|auto` - pin the thread count',
  '`/worker <rig> name` - the name the pool sees',
  '`/start <rig>`  `/stop <rig>`  `/restart <rig>`',
  '`/update <rig>` - newest miner, and the OS into the spare slot',
  '`/log <rig> [n]` - the last lines of the rig\'s own log',
  '`/reboot <rig>`, `/rename <rig> name`, `/remove <rig>`',
  '',
  'Every change is queued and applied on the rig\'s next check-in, so a rig',
  'that is offline right now still receives it later. `/log <rig>` shows what',
  'happened, and nothing is applied silently.',
].join('\n');

/** Split a line into the command and its arguments. Telegram puts the bot's
 *  own name after the command in groups (`/help@zmrig_bot`), Discord uses `!`
 *  or a mention, and neither of those prefixes is an argument. */
function words(text) {
  return String(text || '')
    .trim()
    .replace(/^!\s*/, '')
    .replace(/^\//, '')
    .replace(/^([A-Za-z0-9_]+)@[A-Za-z0-9_]+/, '$1')
    .split(/\s+/)
    .filter(Boolean);
}

function isMoneroWallet(address) {
  const value = String(address || '');
  if (!/^[1-9A-HJ-NP-Za-km-z]{90,110}$/.test(value)) return false;
  if (!/^[48]/.test(value)) return false;
  return value.length === 95 || value.length === 106;
}

/** Unknown coins accept any base58-shaped address of a plausible length; the
 *  rig's own validator has the last word and refuses anything else. */
function isOtherWallet(address) {
  return /^[1-9A-HJ-NP-Za-km-z]{90,120}$/.test(String(address || ''));
}

function validWallet(address, coin) {
  const name = String(coin || 'xmr').toLowerCase();
  if (name === 'xmr' || name === 'monero') return isMoneroWallet(address);
  return isOtherWallet(address);
}

function validPool(value) {
  const pool = String(value || '').trim();
  if (pool.length < 4 || pool.length > 200) return false;
  if (/^wss?:\/\/[A-Za-z0-9.-]+(:\d{1,5})?(\/[^\s]*)?$/.test(pool)) return true;
  if (!/^[A-Za-z0-9.-]+:\d{1,5}$/.test(pool)) return false;
  const port = Number(pool.split(':').pop());
  return port > 0 && port < 65536;
}

/** `<rig>` is an ID, a unique part of one, or the name somebody gave it. */
function findDevice(store, token) {
  const query = String(token || '').trim();
  if (!query) return { error: 'which rig? `/devices` lists them' };

  const devices = store.devices();
  const upper = query.toUpperCase();

  if (ids.isDeviceId(upper)) {
    const record = store.get(upper);
    return record ? { record } : { error: `no rig with ID ${upper}` };
  }

  const bySuffix = devices.filter((device) => device.id.replace(/^ZMR-/, '').includes(upper));
  if (bySuffix.length === 1) return { record: bySuffix[0] };

  const byLabel = devices.filter(
    (device) => device.label && device.label.toLowerCase() === query.toLowerCase(),
  );
  if (byLabel.length === 1) return { record: byLabel[0] };

  if (bySuffix.length > 1) return { error: `${query} matches ${bySuffix.length} rigs; be more specific` };
  return { error: `no rig called ${query}; \`/devices\` lists them` };
}

function owned(record, actor) {
  return record && record.owner === actor.key;
}

/** The rigs one operator can see, in the shape the printers expect. Filtering
 *  here and not in the printers is what stops a second operator's rigs from
 *  appearing in somebody else's `/devices`. */
function visible(store, actor) {
  return {
    devices: () => store.devices().filter((device) => device.owner === actor.key),
    get: (id) => store.get(id),
  };
}

function requireDevice(store, actor, token) {
  const found = findDevice(store, token);
  if (found.error) return { error: found.error };
  if (!found.record.owner) return { error: `rig ${found.record.id} is not enrolled yet; \`/enroll\` it` };
  if (!owned(found.record, actor)) return { error: `rig ${found.record.id} belongs to another operator` };
  return { record: found.record };
}

function state(record, config, now) {
  const online = presence(record, config, now);
  if (online !== 'online') return online;
  return record.status && record.status.state ? record.status.state : 'online';
}

function card(record, config, now = Date.now()) {
  const status = record.status || {};
  const online = presence(record, config, now);
  const lines = [
    `**${record.label || record.id}**  ${format.icon(state(record, config, now))} ${state(record, config, now)}`,
    `\`${record.id}\``,
    '',
  ];

  if (status.state) {
    lines.push(`hashrate   ${format.hashrate(status.hashrate)}`);
    lines.push(`threads    ${status.threads || 'auto'}`);
    lines.push(`temp       ${format.temperature(status.temp)}`);
    lines.push(`uptime     ${format.duration(status.uptime)}`);
    lines.push(`wallet     \`${format.wallet(status.wallet)}\``);
    lines.push(`pool       \`${status.pool || '-'}\``);
    lines.push(`coin       ${status.coin || 'xmr'} (${status.mode || 'max'} mode)`);
    lines.push(`version    ${status.version || '?'}${status.slot ? `, slot ${status.slot}` : ''}`);
  } else {
    lines.push('no check-in yet');
  }

  lines.push(`seen       ${format.ago(record.last_seen, now)}`);

  const applied = record.config_version || 0;
  const pending = record.queue.length;
  if (pending) {
    lines.push('');
    lines.push(`⏳ ${pending} change${pending === 1 ? '' : 's'} waiting for the next check-in (revision ${applied + 1})`);
  }

  return lines.join('\n');
}

function row(record, config, now) {
  const status = record.status || {};
  const stateName = state(record, config, now);
  return [
    `${format.icon(stateName)} ${record.label || record.id}`,
    record.id.slice(-9),
    stateName,
    format.hashrate(status.hashrate),
    format.temperature(status.temp),
    format.ago(record.last_seen, now),
  ];
}

function devicesText(view, config, now = Date.now()) {
  const devices = view.devices();
  if (devices.length === 0) {
    return [
      'No rigs enrolled yet.',
      '',
      'On the machine: `zmrig-os id` prints a Device ID and an enrolment code.',
      'Then: `/enroll ZMR-XXXX-XXXX-XXXX ABCD-1234 rig-1`',
    ].join('\n');
  }
  const body = format.table(
    devices.map((device) => row(device, config, now)),
    ['rig', 'id', 'state', 'hashrate', 'temp', 'seen'],
  );
  return `**${devices.length} rig${devices.length === 1 ? '' : 's'}**\n\n\`\`\`\n${body}\n\`\`\``;
}

function fleetText(view, config, now = Date.now()) {
  const devices = view.devices();
  if (devices.length === 0) return devicesText(view, config, now);

  let total = 0;
  let mining = 0;
  let offline = 0;
  let hottest = 0;
  for (const device of devices) {
    const online = presence(device, config, now) === 'online';
    if (!online) {
      offline += 1;
      continue;
    }
    total += Number(device.status && device.status.hashrate) || 0;
    if (device.status && device.status.state === 'mining') mining += 1;
    hottest = Math.max(hottest, Number(device.status && device.status.temp) || 0);
  }

  return [
    '**Fleet**',
    `rigs       ${devices.length} (${mining} mining, ${offline} offline)`,
    `hashrate   ${format.hashrate(total)}`,
    `hottest    ${format.temperature(hottest)}`,
    '',
    devicesText(view, config, now).split('\n\n').slice(1).join('\n\n'),
  ].join('\n');
}

function menu(id) {
  return [
    [
      { text: '⏵ Start', data: `a:start:${id}` },
      { text: '⏸ Stop', data: `a:stop:${id}` },
      { text: '⟳ Restart', data: `a:restart:${id}` },
    ],
    [
      { text: '⤓ Update', data: `a:update:${id}` },
      { text: '📜 Log', data: `a:log:${id}` },
      { text: '⏻ Reboot', data: `a:reboot:${id}` },
    ],
    [{ text: '↻ Refresh', data: `a:card:${id}` }],
  ];
}

/** Queue with the fleet's configured depth, so a stuck rig cannot accumulate a
 *  hundred instructions that all apply at once when it comes back. */
function queue(store, config, id, command) {
  return store.push(id, command, (config && config.queue_limit) || 10);
}

function ok(text, keyboard) {
  return { text, keyboard };
}

function fail(text) {
  return { text: `⚠️ ${text}` };
}

/**
 * `route` answers one message. `actor` is who sent it, `store` is the fleet,
 * `config` is the server's thresholds, `now` is injectable so tests are not
 * racing a clock.
 */
function route(message, { store, config, actor, now = Date.now() }) {
  const parts = words(message.text);
  const command = (parts.shift() || '').toLowerCase();
  const view = visible(store, actor);

  // `/start` with no argument is "hello"; with an argument it is "mine".
  if (command === 'start' && parts.length === 0) {
    return ok(
      [
        '**ZMRIG fleet control**',
        '',
        `You are \`${actor.key}\`.`,
        '',
        '`/enroll <device id> <code>` links a rig to you.',
        '`/devices` shows them, `/status` sums them up, `/help` lists the rest.',
        '',
        'Rigs check in every minute. Changes are queued, applied on the next',
        'check-in, and reported back.',
      ].join('\n'),
    );
  }

  if (command === 'help' || command === 'commands') return ok(HELP);
  if (command === 'whoami') {
    return ok(`you are \`${actor.key}\` (${actor.role}), on ${actor.platform}`);
  }

  if (command === 'enroll') {
    const id = (parts[0] || '').toUpperCase();
    const code = ids.normaliseCode(parts[1] || '');
    const label = parts.slice(2).join(' ').slice(0, 40) || null;

    if (!ids.isDeviceId(id)) return fail('that is not a Device ID. It looks like `ZMR-1A2B-3C4D-5E6F`.');
    if (!ids.isCode(code)) return fail('the enrolment code is eight hex characters, like `ABCD-1234`.');
    if (label && !/^[\w .:-]{1,40}$/.test(label)) return fail('the name can be letters, digits, space, `.`, `:` and `-`.');

    const record = store.get(id);
    if (!record) {
      return fail(
        `no rig has checked in with that ID yet.\n\nOn the machine: \`zmrig-os fleet --url <this server>\`, then \`zmrig-os id\` and repeat the code.`,
      );
    }
    if (record.owner && record.owner !== actor.key) {
      return fail(`rig ${id} is enrolled to another operator.`);
    }
    if (record.owner === actor.key) return ok(`rig ${id} is already yours.`, [[{ text: 'Open the rig', data: `a:card:${id}` }]]);
    if (!record.code) return fail(`rig ${id} has no enrolment code on record; run \`zmrig-os id\` on it and retry.`);
    if (!ids.sameDigest(ids.sha256(code), ids.sha256(record.code))) {
      return fail(
        'the code does not match that rig.\n\nRun `zmrig-os id` on the machine and copy the eight characters under "enrol code".',
      );
    }

    // The web dashboard enrols rigs on behalf of the operator's chat account, so
    // a rig enrolled in the browser is also visible in the bot.
    const owner = actor.enrolAs || actor.key;
    store.enrol(id, owner, label);
    store.audit({ actor: actor.key, action: 'enrol', device: id });
    return ok(
      [
        `✅ **${label || id}** is yours.`,
        '`' + id + '`',
        '',
        'Next, give it something to mine into:',
        `\`/wallet ${id} <your Monero address>\``,
        '`/pool ' + id + ' <host:port>` and `/mode ' + id + ' balanced` are optional.',
        '',
        'It is `waiting` until its first check-in.',
      ].join('\n'),
      [[{ text: 'Open the rig', data: `a:card:${id}` }]],
    );
  }

  if (command === 'devices' || command === 'list' || command === 'rigs') {
    const devices = view.devices();
    const text = devicesText(view, config, now);
    if (devices.length === 0) return ok(text);
    return ok(text, [[{ text: 'Fleet totals', data: 'a:fleet:' }]]);
  }

  if (command === 'status' || command === 'fleet') {
    return ok(fleetText(view, config, now));
  }

  if (command === 'device') {
    const found = requireDevice(store, actor, parts[0]);
    if (found.error) return fail(found.error);
    return ok(card(found.record, config, now), menu(found.record.id));
  }

  const withDevice = ['wallet', 'pool', 'coin', 'mode', 'threads', 'worker', 'rename', 'update', 'reboot', 'log', 'stop', 'restart', 'remove'];
  if (withDevice.includes(command)) {
    const found = requireDevice(store, actor, parts[0]);
    if (found.error) return fail(found.error);
    const record = found.record;
    const args = parts.slice(1);
    const id = record.id;

    switch (command) {
      case 'wallet': {
        const address = args[0] || '';
        const coin = (record.config && record.config.coin) || (record.status && record.status.coin) || 'xmr';
        if (!address) return fail(`usage: \`/wallet ${id} 4...\``);
        if (!validWallet(address, coin)) {
          return fail(
            coin === 'xmr'
              ? 'that is not a Monero address: 95 (or 106 for a subaddress) base58 characters starting with 4 or 8.'
              : `that does not look like a ${coin} address.`,
          );
        }
        queue(store, config, id, { cmd: 'setup', args: { wallet: address } });
        store.audit({ actor: actor.key, action: 'wallet', device: id });
        return ok(`💾 wallet for **${record.label || id}** set to \`${format.wallet(address)}\`; applied on the next check-in.`);
      }

      case 'pool': {
        const pool = args[0] || '';
        if (!validPool(pool)) return fail('a pool is `host:port`, for example `gulf.moneroocean.stream:10001`.');
        queue(store, config, id, { cmd: 'setup', args: { pool } });
        store.audit({ actor: actor.key, action: 'pool', device: id });
        return ok(`💾 pool for **${record.label || id}** set to \`${pool}\`.`);
      }

      case 'coin': {
        const coin = (args[0] || '').toLowerCase();
        if (!COINS[coin]) return fail(`unknown coin "${coin}". Known: ${Object.keys(COINS).filter((c) => c.length <= 5).join(' ')}`);
        queue(store, config, id, { cmd: 'setup', args: { coin } });
        store.audit({ actor: actor.key, action: 'coin', device: id });
        return ok(`💾 **${record.label || id}** mines ${coin} (${COINS[coin]}).`);
      }

      case 'mode': {
        const mode = (args[0] || '').toLowerCase();
        if (!MODES[mode]) return fail(`unknown mode. One of: ${Object.keys(MODES).join(' ')}.`);
        const args2 = { mode };
        if (mode === 'safe') {
          const temp = Number.parseInt(args[1] || '72', 10);
          if (!Number.isFinite(temp) || temp < 50 || temp > 95) return fail('the heat cap is a temperature in C between 50 and 95.');
          args2.maxtemp = temp;
        }
        queue(store, config, id, { cmd: 'setup', args: args2 });
        store.audit({ actor: actor.key, action: 'mode', device: id });
        return ok(`💾 **${record.label || id}** is ${mode}${args2.maxtemp ? ` at ${args2.maxtemp} C` : ''} - ${MODES[mode]}.`);
      }

      case 'threads': {
        const threads = (args[0] || '').toLowerCase();
        if (threads !== 'auto' && !/^([1-9]|[1-9][0-9]|1[0-9][0-9])$/.test(threads)) {
          return fail('threads is a number, or `auto` to let the miner decide.');
        }
        queue(store, config, id, { cmd: 'setup', args: { threads } });
        store.audit({ actor: actor.key, action: 'threads', device: id });
        return ok(`💾 **${record.label || id}** uses ${threads} threads.`);
      }

      case 'worker': {
        const name = (args[0] || '').slice(0, 32);
        if (!/^[\w.-]{1,32}$/.test(name)) return fail('a worker name is 1-32 letters, digits, `_`, `-` or `.`.');
        queue(store, config, id, { cmd: 'setup', args: { worker: name } });
        store.audit({ actor: actor.key, action: 'worker', device: id });
        return ok(`💾 **${record.label || id}** reports as \`${name}\` at the pool.`);
      }

      case 'rename': {
        const label = args.join(' ').slice(0, 40);
        if (!/^[\w .:-]{1,40}$/.test(label)) return fail('a name is 1-40 letters, digits, space, `.`, `:` or `-`.');
        record.label = label;
        store.touch();
        store.audit({ actor: actor.key, action: 'rename', device: id });
        return ok(`renamed to **${label}**.`);
      }

      case 'update': {
        queue(store, config, id, { cmd: 'update' });
        store.audit({ actor: actor.key, action: 'update', device: id });
        return ok(`⤓ **${record.label || id}** will fetch the newest miner on the next check-in. The OS goes into the spare slot.`);
      }

      case 'reboot': {
        queue(store, config, id, { cmd: 'reboot' });
        store.audit({ actor: actor.key, action: 'reboot', device: id });
        return ok(`⏻ **${record.label || id}** will reboot after the next check-in.`);
      }

      case 'log': {
        const lines = Math.min(Math.max(Number.parseInt(args[0] || '30', 10) || 30, 5), 80);
        queue(store, config, id, { cmd: 'log', args: { lines } });
        store.audit({ actor: actor.key, action: 'log', device: id });
        return ok(`📜 asked **${record.label || id}** for the last ${lines} lines; they arrive with the next check-in.`);
      }

      case 'stop': {
        queue(store, config, id, { cmd: 'stop' });
        store.audit({ actor: actor.key, action: 'stop', device: id });
        return ok(`⏸ **${record.label || id}** stops mining on the next check-in. The machine stays up and reachable.`);
      }

      case 'restart': {
        queue(store, config, id, { cmd: 'restart' });
        store.audit({ actor: actor.key, action: 'restart', device: id });
        return ok(`⟳ **${record.label || id}** restarts the miner on the next check-in.`);
      }

      case 'remove': {
        if ((args[0] || '').toLowerCase() !== 'confirm') {
          return ok(`Remove **${record.label || id}** from the bot?\nThe machine keeps mining; only this chat forgets it.`, [
            [{ text: 'Remove', data: `a:rm:${id}` }, { text: 'Keep', data: `a:card:${id}` }],
          ]);
        }
        record.owner = null;
        record.claimed_at = null;
        store.touch();
        store.audit({ actor: actor.key, action: 'remove', device: id });
        return ok(`removed ${id}. The rig keeps mining with its current settings.`);
      }

      default:
        return fail('unknown command. `/help` lists them.');
    }
  }

  return fail(`unknown command "${command}". \`/help\` lists them.`);
}

/** Button presses. `data` is `a:<verb>:<device id>`, kept under 64 bytes
 *  because that is all Telegram gives a callback. */
function press(data, { store, config, actor, now = Date.now() }) {
  const parts = String(data || '').split(':');
  if (parts[0] !== 'a') return { text: 'stale button' };
  const verb = parts[1];
  const id = (parts[2] || '').toUpperCase();

  if (verb === 'fleet') return ok(fleetText(visible(store, actor), config, now));

  const record = store.get(id);
  if (!record || record.owner !== actor.key) return { text: 'that rig is not yours' };

  if (verb === 'card') return ok(card(record, config, now), menu(id));

  if (verb === 'rm') {
    record.owner = null;
    record.claimed_at = null;
    store.touch();
    store.audit({ actor: actor.key, action: 'remove', device: id });
    return ok(`removed ${id}.`);
  }

  const mapping = { start: 'start', stop: 'stop', restart: 'restart', update: 'update', reboot: 'reboot', log: 'log' };
  if (mapping[verb]) {
    queue(store, config, id, { cmd: mapping[verb] });
    store.audit({ actor: actor.key, action: verb, device: id });
    return ok(`${verb} queued for **${record.label || id}**; it applies on the next check-in.`, menu(id));
  }

  return { text: 'unknown button' };
}

module.exports = {
  route,
  press,
  card,
  devicesText,
  fleetText,
  findDevice,
  visible,
  validWallet,
  validPool,
  isMoneroWallet,
  COINS,
  MODES,
  HELP,
  menu,
};

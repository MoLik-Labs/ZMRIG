'use strict';

const test = require('node:test');
const assert = require('node:assert');

const { render, chunks, keyboard } = require('../src/telegram');
const { Discord } = require('../src/discord');
const format = require('../src/format');
const configLoader = require('../src/config');

test('telegram markup: bold, code, and the three characters that break HTML', () => {
  assert.equal(render('**hello**'), '<b>hello</b>');
  assert.equal(render('`ZMR-1234`'), '<code>ZMR-1234</code>');
  assert.equal(render('```\na  b\n```'), '<pre>a  b</pre>');
  assert.equal(render('<script>&'), '&lt;script&gt;&amp;');
  assert.equal(render('**a < b**'), '<b>a &lt; b</b>');
  // An underscore is a literal in this scheme, which is why the command layer
  // never uses single `*` for anything else.
  assert.equal(render('rig_1'), 'rig_1');
});

test('a long message is split without cutting a table in half', () => {
  const block = ['rig   hashrate', 'a     1 kH/s', 'b     2 kH/s'].join('\n');
  const body = Array.from({ length: 200 }, () => block).join('\n\n');
  const parts = chunks(body, 900);

  assert.ok(parts.length > 1);
  for (const part of parts) {
    assert.ok(part.length <= 900);
    assert.equal(part.startsWith('\n'), false);
  }
  assert.equal(parts.join('\n\n').replace(/\n+/g, '\n'), body.replace(/\n+/g, '\n'));
});

test('a button payload is cut to what telegram accepts', () => {
  const rows = [[{ text: 'x'.repeat(100), data: `a:card:${'Z'.repeat(80)}` }]];
  const markup = keyboard(rows);
  assert.ok(markup.inline_keyboard[0][0].callback_data.length <= 64);
  assert.equal(keyboard([]), undefined);
});

test('discord components: five rows at most, five buttons per row', () => {
  const discord = new Discord({ token: 'x', log: () => {} });
  const rows = Array.from({ length: 8 }, () =>
    Array.from({ length: 7 }, (_, index) => ({ text: `b${index}`, data: `a:card:1` })),
  );
  const components = discord.components(rows);

  assert.equal(components.length, 5);
  assert.equal(components[0].components.length, 5);
  assert.equal(components[0].type, 1);
  assert.equal(components[0].components[0].type, 2);
});

test('discord messages stay under the 2000 character limit', () => {
  const discord = new Discord({ token: 'x', log: () => {} });
  const parts = discord.chunks('line\n'.repeat(900));
  assert.ok(parts.length > 1);
  assert.ok(parts.every((part) => part.length <= 1900));
});

test('numbers read the same everywhere', () => {
  assert.equal(format.hashrate(0), '0 H/s');
  assert.equal(format.hashrate(950), '950 H/s');
  assert.equal(format.hashrate(1234.5), '1.2 kH/s');
  assert.equal(format.hashrate(1234567), '1.23 MH/s');
  assert.equal(format.duration(0), '0s');
  assert.equal(format.duration(90), '1m');
  assert.equal(format.duration(3700), '1h 1m');
  assert.equal(format.duration(90000), '1d 1h');
  assert.equal(format.ago(null), 'never');
  assert.equal(format.temperature('abc'), '-');
  assert.equal(format.wallet('4abcdefghijklmnopqrstuvwxyz'), '4abcde...wxyz');
});

test('the environment is read without a file and refuses to start half-configured', () => {
  const empty = configLoader.load({});
  assert.equal(empty.telegram_token, '');
  assert.deepEqual(empty.admins, []);
  assert.equal(empty.interval, 60);
  assert.ok(configLoader.validate(empty).problems.length >= 2);

  const configured = configLoader.load({
    TELEGRAM_BOT_TOKEN: '123456789:AAH4kLpQ9vYbXc2mNq7Rt5Zs8Wf3Gh1JkEo',
    FLEET_ADMIN_IDS: '111, tg:222',
    DISCORD_ADMIN_IDS: '333',
    FLEET_INTERVAL: '120',
    FLEET_OFFLINE_AFTER: '10',
    PORT: '9000',
  });
  assert.deepEqual(configured.admins, ['tg:111', 'tg:222', 'dc:333']);
  assert.equal(configured.port, 9000);
  // An offline threshold below three intervals is not a threshold, it is noise.
  assert.equal(configured.offline_after, 360);
  assert.deepEqual(configLoader.validate(configured).problems, []);
});

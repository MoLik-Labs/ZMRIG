'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');

const { Store } = require('../src/store');
const ids = require('../src/ids');
const commands = require('../src/commands');
const { build } = require('../src/index');
const { integrated, substitute } = require('../../tests/common/monero');

const WALLET = '46SQLW7DXaq6GJaQbHUFMAhd1VYpfQFJQ2gfZo9TCB8bf9vnf1MUwAD2Fwj6KMsY4RU3oKA3x6hByg8BKg7FfMWn6ysb5tJ';
const OTHER = '888tNkZrPN6JsEgekjMnABU4TBzc2Dt29EPAvkRxbANsAnjyPbb3iQ1YBRk1UXcdRsiKc9dhwMVgN5S9cQUiyoogDavup3H';
const CONFIG = { interval: 60, offline_after: 300, queue_limit: 10, alert_temp: 85, alert_cooldown: 1800 };

const OWNER = { platform: 'tg', key: 'tg:1', id: '1', name: 'owner', role: 'admin' };

function fleet() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zmrig-cmd-'));
  const store = new Store(path.join(dir, 'state.json')).load();
  const key = crypto.randomBytes(32).toString('hex');
  const record = store.claim(key);
  record.status = { state: 'mining', hashrate: 1200, temp: 63, threads: 8, wallet: WALLET, pool: 'gulf.moneroocean.stream:10001', coin: 'xmr', mode: 'max' };
  record.last_seen = Date.now() - 30_000;
  return { store, record, key, config: CONFIG };
}

const say = (store, text, actor = OWNER, config = CONFIG) => commands.route({ text, actor }, { store, config, actor });

test('help and hello are always available', () => {
  const { store } = fleet();
  assert.match(say(store, '/start').text, /ZMRIG fleet control/);
  assert.match(say(store, '/help').text, /\/enroll/);
  assert.match(say(store, '/help').text, /\/wallet/);
  assert.match(say(store, '/whoami').text, /tg:1/);
  assert.match(say(store, '!help').text, /ZMRIG fleet/);
});

test('enrolment needs a rig that has checked in, and the right code', () => {
  const { store, record, key } = fleet();

  const unknown = say(store, '/enroll ZMR-AAAA-BBBB-CCCC ABCD-1234');
  assert.match(unknown.text, /no rig has checked in/);

  const badShape = say(store, '/enroll nonsense ABCD-1234');
  assert.match(badShape.text, /not a Device ID/);

  const badCode = say(store, `/enroll ${record.id} AAAA-AAAA`);
  assert.match(badCode.text, /does not match/);

  const ok = say(store, `/enroll ${record.id} ${ids.enrolCode(key).toLowerCase()} basement`);
  assert.match(ok.text, /is yours/);
  assert.equal(store.get(record.id).label, 'basement');
  assert.equal(store.get(record.id).owner, 'tg:1');
  assert.equal(store.state.audit.at(-1).action, 'enrol');

  const again = say(store, `/enroll ${record.id} ${ids.enrolCode(key)}`);
  assert.match(again.text, /already yours/);

  const stranger = say(store, `/enroll ${record.id} ${ids.enrolCode(key)}`, { ...OWNER, key: 'tg:2', id: '2' });
  assert.match(stranger.text, /another operator/);
});

test('a rig belongs to one operator', () => {
  const { store, record, key } = fleet();
  say(store, `/enroll ${record.id} ${ids.enrolCode(key)}`);
  const other = { ...OWNER, key: 'tg:2', id: '2' };

  assert.match(say(store, `/wallet ${record.id} ${WALLET}`, other).text, /belongs to another/);
  assert.match(say(store, '/devices', other).text, /No rigs enrolled/);
  assert.equal(store.get(record.id).queue.length, 0);
});

test('the wallet is validated before it is queued', () => {
  const { store, record, key } = fleet();
  say(store, `/enroll ${record.id} ${ids.enrolCode(key)}`);

  const wrong = say(store, `/wallet ${record.id} not-an-address`);
  assert.match(wrong.text, /not a Monero address/);
  assert.equal(store.get(record.id).queue.length, 0, 'nothing is queued when the address is wrong');

  const ok = say(store, `/wallet ${record.id} ${WALLET}`);
  assert.match(ok.text, /applied on the next check-in/);
  assert.deepEqual(store.get(record.id).queue[0].args, { wallet: WALLET });

  const missing = say(store, `/wallet ${record.id}`);
  assert.match(missing.text, /usage/);

  // 106 characters - an address carrying a payment id - must be accepted too.
  assert.match(say(store, `/wallet ${record.id} ${integrated(WALLET)}`).text, /set to/);
});

test('a wallet with one wrong character is refused before it reaches a rig', () => {
  const { store, record, key } = fleet();
  say(store, `/enroll ${record.id} ${ids.enrolCode(key)}`);

  // The failure this exists for: every character is base58, the length is
  // right, and the address belongs to nobody. Queued, it would make the rig
  // mine for a week into a hole, and nothing on the rig would notice.
  const typo = substitute(WALLET, 40);
  const refused = say(store, `/wallet ${record.id} ${typo}`);

  assert.match(refused.text, /checksum does not match/);
  assert.match(refused.text, /at least one character is wrong/);
  assert.equal(store.get(record.id).queue.length, 0, 'a typo is never queued');

  // A testnet address is a real address on a chain that cannot pay; saying so
  // is more useful than "invalid", which sends the operator looking for a typo
  // that is not there.
  const testnet = require('../../tests/common/monero').onNetwork(WALLET, 53);
  const other = say(store, `/wallet ${record.id} ${testnet}`);
  assert.match(other.text, /testnet/);
  assert.match(other.text, /cannot pay/);
  assert.equal(store.get(record.id).queue.length, 0);
});

test('pool, coin, mode, threads and worker each queue exactly one change', () => {
  const { store, record, key } = fleet();
  say(store, `/enroll ${record.id} ${ids.enrolCode(key)}`);

  assert.match(say(store, `/pool ${record.id} pool.example.org:3333`).text, /pool.example.org:3333/);
  assert.match(say(store, `/pool ${record.id} nope`).text, /host:port/);
  assert.match(say(store, `/pool ${record.id} pool.example.org:99999`).text, /host:port/);

  assert.match(say(store, `/coin ${record.id} wow`).text, /rx\/wow/);
  assert.match(say(store, `/coin ${record.id} doge`).text, /unknown coin/);

  const mode = say(store, `/mode ${record.id} safe 70`);
  assert.match(mode.text, /safe at 70 C/);
  assert.deepEqual(store.get(record.id).queue.at(-1).args, { mode: 'safe', maxtemp: 70 });
  assert.match(say(store, `/mode ${record.id} safe 120`).text, /between 50 and 95/);
  assert.match(say(store, `/mode ${record.id} turbo`).text, /unknown mode/);

  assert.match(say(store, `/threads ${record.id} 6`).text, /6 threads/);
  assert.match(say(store, `/threads ${record.id} all`).text, /number, or `auto`/);
  assert.match(say(store, `/worker ${record.id} basement-1`).text, /basement-1/);
  assert.match(say(store, `/worker ${record.id} bad/name`).text, /worker name/);

  const queued = store.get(record.id).queue.map((entry) => entry.cmd);
  assert.deepEqual(queued, ['setup', 'setup', 'setup', 'setup', 'setup']);
});

test('operations queue and are reported in the card', () => {
  const { store, record, key } = fleet();
  say(store, `/enroll ${record.id} ${ids.enrolCode(key)}`);

  assert.match(say(store, `/stop ${record.id}`).text, /stops mining/);
  assert.match(say(store, `/restart ${record.id}`).text, /restarts the miner/);
  assert.match(say(store, `/update ${record.id}`).text, /newest miner/);
  assert.match(say(store, `/reboot ${record.id}`).text, /reboot/);
  assert.match(say(store, `/log ${record.id} 50`).text, /last 50 lines/);
  assert.deepEqual(store.get(record.id).queue.at(-1).args, { lines: 50 });
  assert.match(say(store, `/log ${record.id} 500`).text, /last 80 lines/, 'a log request is capped');

  const card = say(store, `/device ${record.id}`).text;
  assert.match(card, /6 changes/);
  assert.match(card, /hashrate {3}1\.2 kH\/s/);
});

test('a rig can be found by id, by part of it, and by name', () => {
  const { store, record, key } = fleet();
  say(store, `/enroll ${record.id} ${ids.enrolCode(key)} basement`);

  assert.match(say(store, '/device basement').text, /basement/);
  assert.match(say(store, `/device ${record.id.slice(4, 10)}`).text, /basement/);
  assert.match(say(store, '/device nope').text, /no rig called/);
  assert.match(say(store, '/device').text, /which rig/);
});

test('rename, remove and the confirmation that guards it', () => {
  const { store, record, key } = fleet();
  say(store, `/enroll ${record.id} ${ids.enrolCode(key)}`);

  assert.match(say(store, `/rename ${record.id} attic rig`).text, /attic rig/);
  assert.equal(store.get(record.id).label, 'attic rig');

  const ask = say(store, `/remove ${record.id}`);
  assert.match(ask.text, /keeps mining/);
  assert.equal(ask.keyboard[0][0].data, `a:rm:${record.id}`);

  assert.match(say(store, `/remove ${record.id}`).text, /keeps mining/);
  assert.match(say(store, `/remove ${record.id} confirm`).text, /removed/);
  assert.equal(store.get(record.id).owner, null);
});

test('buttons do what they say, and only for their owner', () => {
  const { store, record, key } = fleet();
  say(store, `/enroll ${record.id} ${ids.enrolCode(key)}`);

  const menu = commands.press(`a:card:${record.id}`, { store, config: CONFIG, actor: OWNER });
  assert.match(menu.text, /mining/);
  assert.equal(menu.keyboard.length, 3);

  const stop = commands.press(`a:stop:${record.id}`, { store, config: CONFIG, actor: OWNER });
  assert.match(stop.text, /stop queued/);
  assert.equal(store.get(record.id).queue.at(-1).cmd, 'stop');

  const stranger = commands.press(`a:stop:${record.id}`, { store, config: CONFIG, actor: { ...OWNER, key: 'tg:2' } });
  assert.match(stranger.text, /not yours/);

  const removal = commands.press(`a:rm:${record.id}`, { store, config: CONFIG, actor: OWNER });
  assert.match(removal.text, /removed/);
});

test('the fleet screen totals the rigs that are actually up', () => {
  const { store, record, key } = fleet();
  say(store, `/enroll ${record.id} ${ids.enrolCode(key)}`);

  const secondKey = crypto.randomBytes(32).toString('hex');
  const second = store.claim(secondKey);
  second.owner = 'tg:1';
  second.status = { state: 'mining', hashrate: 800, temp: 71 };
  second.last_seen = Date.now() - 20_000;

  const thirdKey = crypto.randomBytes(32).toString('hex');
  const third = store.claim(thirdKey);
  third.owner = 'tg:1';
  third.status = { state: 'mining', hashrate: 9999, temp: 90 };
  third.last_seen = Date.now() - 3_600_000; // offline, so excluded from the total

  const fleetText = say(store, '/status').text;
  assert.match(fleetText, /rigs {7}3 \(2 mining, 1 offline\)/);
  assert.match(fleetText, /hashrate {3}2\.0 kH\/s/, 'an offline rig does not contribute its last hashrate');
  assert.match(fleetText, /hottest {4}71 C/);

  const devices = say(store, '/devices').text;
  assert.match(devices, /3 rigs/);
});

test('two wallets are two farms on the status screen', () => {
  const { store, record, key } = fleet();
  say(store, `/enroll ${record.id} ${ids.enrolCode(key)}`);
  const second = store.claim(crypto.randomBytes(32).toString('hex'));
  second.owner = 'tg:1';
  second.status = { state: 'mining', hashrate: 800, temp: 65, wallet: OTHER };
  second.last_seen = Date.now() - 10_000;

  const text = say(store, '/status').text;
  assert.match(text, /By wallet/, 'more than one address gets a breakdown');
  assert.match(text, new RegExp(`${record.status.wallet.slice(0, 6)}`), 'the farm is named by its wallet');
  assert.match(text, /60%/, 'the bigger farm is 60% of what the fleet is producing');
  assert.match(text, /40%/);

  // One wallet and there is nothing to break down: the breakdown must not appear.
  store.devices().find((d) => d.status && d.status.wallet === OTHER).status.wallet = record.status.wallet;
  assert.doesNotMatch(say(store, '/status').text, /By wallet/);
});

test('unknown commands are refused, not guessed', () => {
  const { store } = fleet();
  assert.match(say(store, '/mine-everything').text, /unknown command/);
  assert.match(say(store, '/wallet').text, /which rig|no rig/i);
});

test('permissions live outside the command layer, and a stranger learns nothing', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zmrig-gate-'));
  const app = build({
    FLEET_ADMIN_IDS: '1',
    FLEET_STATE: path.join(dir, 'state.json'),
    FLEET_QUIET: '1',
  });

  const stranger = app.handlers.onMessage({
    text: '/devices',
    actor: { platform: 'tg', id: '99', key: 'tg:99', name: 'x', role: 'operator' },
    chatId: '99',
  });
  assert.match(stranger.text, /private/);
  assert.match(stranger.text, /tg:99/);

  const admin = app.handlers.onMessage({
    text: '/devices',
    actor: { platform: 'tg', id: '1', key: 'tg:1', name: 'x', role: 'operator' },
    chatId: '1',
  });
  assert.match(admin.text, /No rigs enrolled yet/);

  // A flood from one operator is cut off, and everybody else still works.
  for (let index = 0; index < 40; index += 1) {
    app.handlers.onMessage({ text: '/help', actor: { platform: 'tg', id: '1', key: 'tg:1', name: 'x' }, chatId: '1' });
  }
  const blocked = app.handlers.onMessage({ text: '/help', actor: { platform: 'tg', id: '1', key: 'tg:1', name: 'x' }, chatId: '1' });
  assert.match(blocked.text, /too many commands/);
});

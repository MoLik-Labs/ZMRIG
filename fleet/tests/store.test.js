'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');

const { Store, presence } = require('../src/store');
const ids = require('../src/ids');

function tempStore() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zmrig-fleet-'));
  return { dir, file: path.join(dir, 'state.json'), store: new Store(path.join(dir, 'state.json')).load() };
}

test('a device that checks in is recorded before anybody enrols it', () => {
  const { store } = tempStore();
  const key = crypto.randomBytes(32).toString('hex');

  const record = store.claim(key, { address: '127.0.0.1' });

  assert.equal(record.id, ids.deviceId(key));
  assert.equal(record.owner, null);
  assert.equal(record.code, ids.enrolCode(key));
  assert.equal(record.secret_hash, ids.sha256(key));
  // The key itself is never stored: the file only ever holds its digest.
  assert.equal(JSON.stringify(store.state).includes(key), false);
});

test('claiming twice does not reset the record', () => {
  const { store } = tempStore();
  const key = crypto.randomBytes(32).toString('hex');

  const first = store.claim(key);
  first.label = 'rig-1';
  const second = store.claim(key);

  assert.equal(second.label, 'rig-1');
  assert.equal(store.devices().length, 1);
});

test('enrolment binds one owner and refuses a second', () => {
  const { store } = tempStore();
  const key = crypto.randomBytes(32).toString('hex');
  const record = store.claim(key);

  assert.deepEqual(store.enrol(record.id, 'tg:1', 'rig-1').ok, true);
  assert.equal(store.get(record.id).label, 'rig-1');

  const second = store.enrol(record.id, 'tg:2');
  assert.equal(second.ok, false);
  assert.equal(second.error, 'taken');
  assert.equal(store.get(record.id).owner, 'tg:1');

  // The same owner enrolling again is not an error.
  assert.equal(store.enrol(record.id, 'tg:1').ok, true);
  assert.equal(store.enrol('ZMR-0000-0000-0000', 'tg:1').error, 'unknown');
});

test('the queue is bounded, and taking it empties it', () => {
  const { store } = tempStore();
  const record = store.claim(crypto.randomBytes(32).toString('hex'));

  for (let index = 0; index < 12; index += 1) store.push(record.id, { cmd: 'restart' }, 10);
  assert.equal(store.get(record.id).queue.length, 10, 'eleven queued instructions would apply at once');

  const taken = store.take(record.id);
  assert.equal(taken.length, 10);
  assert.equal(taken[0].id.length >= 6, true);
  assert.equal(store.take(record.id).length, 0);
});

test('state survives a restart, and a corrupt file is kept rather than lost', () => {
  const { dir, file, store } = tempStore();
  const key = crypto.randomBytes(32).toString('hex');
  const record = store.claim(key);
  store.enrol(record.id, 'tg:7', 'basement');
  store.flush();

  const reopened = new Store(file).load();
  assert.equal(reopened.get(record.id).label, 'basement');
  assert.equal(reopened.get(record.id).owner, 'tg:7');

  fs.writeFileSync(file, '{"schema":1,"devices":');
  const rescued = new Store(file).load();
  assert.deepEqual(rescued.devices(), []);
  const backups = fs.readdirSync(dir).filter((name) => name.includes('.corrupt-'));
  assert.equal(backups.length, 1);
  assert.equal(fs.readFileSync(path.join(dir, backups[0]), 'utf8'), '{"schema":1,"devices":');
});

test('writes are atomic: the temporary name never survives a flush', () => {
  const { dir, file, store } = tempStore();
  store.claim(crypto.randomBytes(32).toString('hex'));
  store.flush();

  assert.equal(fs.readFileSync(file, 'utf8').includes('"devices"'), true);
  assert.equal(fs.readdirSync(dir).includes('state.json.tmp'), false);
});

test('presence: waiting, online, offline', () => {
  const config = { interval: 60, offline_after: 300 };
  const now = 10_000_000;

  assert.equal(presence({ last_seen: null }, config, now), 'waiting');
  assert.equal(presence({ last_seen: now - 60_000 }, config, now), 'online');
  assert.equal(presence({ last_seen: now - 301_000 }, config, now), 'offline');
});

test('the audit log keeps the last 500 and never grows', () => {
  const { store } = tempStore();
  for (let index = 0; index < 620; index += 1) store.audit({ actor: 'tg:1', action: 'wallet', device: 'ZMR-AAAA-BBBB-CCCC' });

  assert.equal(store.state.audit.length, 500);
  assert.equal(store.recent(1)[0].action, 'wallet');
});

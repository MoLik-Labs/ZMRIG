'use strict';

// The roster is the only reason a fleet survives a free host: the process is
// restarted, the disk is emptied, and the rigs are still enrolled because
// nothing about them was ever stored. These tests are mostly about that
// property - what happens after a restart - and about the roster not being able
// to do anything surprising to a rig that is already correct.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');

const rosterModule = require('../src/roster');
const reconcile = require('../src/reconcile');
const { Store, presence } = require('../src/store');
const ids = require('../src/ids');
const { createServer } = require('../src/http');

const WALLET = '46SQLW7DXaq6GJaQbHUFMAhd1VYpfQFJQ2gfZo9TCB8bf9vnf1MUwAD2Fwj6KMsY4RU3oKA3x6hByg8BKg7FfMWn6ysb5tJ';
const OTHER = '48aBcDeFgHiJkLmNoPqRsTuVwXyZaBcDeFgHiJkLmNoPqRsTuVwXyZaBcDeFgHiJkLmNoPqRsTuVwXyZaBcDeF';

const CONFIG = {
  interval: 60,
  offline_after: 300,
  queue_limit: 10,
  alert_temp: 85,
  alert_cooldown: 1800,
  alert_hashrate_drop: 0.5,
};

function tmpdir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'zmrig-roster-'));
}

function storeAt(dir) {
  return new Store(path.join(dir, 'state.json')).load();
}

test('the documented shape, a bare map and an array all parse', () => {
  const id = 'ZMR-1A2B-3C4D-5E6F';
  const full = rosterModule.parse(JSON.stringify({
    rigs: {
      [id]: {
        label: 'basement',
        wallet: WALLET,
        pool: 'gulf.moneroocean.stream:10001',
        mode: 'safe',
        maxtemp: 72,
        threads: 8,
        worker: 'rig-1',
      },
    },
  }));
  assert.deepEqual(full.problems, []);
  const entry = full.rigs.get(id);
  assert.equal(entry.label, 'basement');
  assert.equal(entry.desired.wallet, WALLET);
  assert.equal(entry.desired.mode, 'safe');
  assert.equal(entry.desired.maxtemp, 72);
  assert.equal(entry.desired.threads, '8');
  assert.equal(entry.desired.worker, 'rig-1');

  const bare = rosterModule.parse({ 'zmr-1a2b-3c4d-5e6f': { label: 'x' } });
  assert.equal(bare.rigs.size, 1, 'a lower-case key is normalised, not rejected');
  assert.ok(bare.rigs.has(id));

  const array = rosterModule.parse([{ id, label: 'from an array' }]);
  assert.equal(array.rigs.get(id).label, 'from an array');
});

test('a broken roster is reported, never thrown', () => {
  const seen = [];
  const broken = rosterModule.parse('{"rigs":', (message) => seen.push(message));
  assert.equal(broken.rigs.size, 0);
  assert.match(broken.problems[0], /not valid JSON/);
  assert.equal(seen.length, 1, 'the reason reaches the log, which is how an operator finds out');

  const typo = rosterModule.parse({
    rigs: {
      'ZMR-1A2B-3C4D-5E6F': { labl: 'basement', mode: 'turbo', threads: 'many', wallet: '4nope' },
    },
  });
  const problems = typo.problems.join('\n');
  assert.match(problems, /unknown key "labl"/);
  assert.match(problems, /unknown mode "turbo"/);
  assert.match(problems, /threads must be a number/);
  assert.match(problems, /wallet is not valid/);
  // The rig is still in the roster: a misconfigured entry must not make a rig
  // unreachable, it must make it reachable and obviously wrong.
  assert.ok(typo.rigs.has('ZMR-1A2B-3C4D-5E6F'));
  assert.equal(typo.rigs.get('ZMR-1A2B-3C4D-5E6F').desired.wallet, undefined);

  const wrongShape = rosterModule.parse({ rigs: { 'not-an-id': { label: 'x' } } });
  assert.match(wrongShape.problems.join('\n'), /not a Device ID/);
});

test('one owner can be set for the whole roster', () => {
  const parsed = rosterModule.parse({
    owner: 'tg:42',
    rigs: { 'ZMR-1A2B-3C4D-5E6F': { label: 'a' }, 'ZMR-AAAA-BBBB-CCCC': { owner: 'dc:7' } },
  });
  assert.equal(parsed.rigs.get('ZMR-1A2B-3C4D-5E6F').owner, 'tg:42');
  assert.equal(parsed.rigs.get('ZMR-AAAA-BBBB-CCCC').owner, 'dc:7');
});

test('applying the roster enrols a rig that has never checked in', () => {
  const dir = tmpdir();
  const store = storeAt(dir);
  const key = crypto.randomBytes(32).toString('hex');
  const id = ids.deviceId(key);
  const roster = rosterModule.parse({ owner: 'tg:1', rigs: { [id]: { label: 'basement' } } });

  const applied = rosterModule.apply(store, roster, 1000);
  assert.equal(applied.length, 1);

  const record = store.get(id);
  assert.equal(record.owner, 'tg:1');
  assert.equal(record.label, 'basement');
  assert.equal(record.secret_hash, null, 'a roster knows the id, not the key');
  assert.equal(presence(record, CONFIG, 1000), 'waiting');
});

test('the difference is only what the roster actually sets', () => {
  const status = { state: 'mining', wallet: WALLET, pool: 'a:1', coin: 'xmr', mode: 'max', threads: '8', worker: 'rig' };
  assert.deepEqual(reconcile.diff(status, {}), {}, 'an entry that says nothing changes nothing');
  assert.deepEqual(reconcile.diff(status, { wallet: WALLET, mode: 'max' }), {}, 'matching fields are not repeated');
  assert.deepEqual(reconcile.diff(status, { pool: 'other.example.com:3333' }), { pool: 'other.example.com:3333' });
  assert.deepEqual(reconcile.diff(status, { threads: 'auto' }), { threads: 'auto' });
  assert.deepEqual(
    reconcile.diff(status, { mode: 'safe', maxtemp: 70 }),
    { mode: 'safe', maxtemp: 70 },
    'the heat cap travels with the mode it belongs to',
  );
  assert.deepEqual(
    reconcile.diff({ ...status, mode: 'safe' }, { mode: 'safe', maxtemp: 70 }),
    {},
    'and is not re-sent every minute, because the rig cannot report it back',
  );
});

test('a correction is queued once, not once a minute', () => {
  const dir = tmpdir();
  const store = storeAt(dir);
  const key = crypto.randomBytes(32).toString('hex');
  const record = store.claim(key);
  record.status = { state: 'mining', wallet: '', pool: 'gulf.moneroocean.stream:10001', mode: 'max', threads: '8' };
  const roster = rosterModule.parse({ owner: 'tg:1', rigs: { [record.id]: { wallet: WALLET } } });
  const entry = roster.rigs.get(record.id);

  const first = reconcile.run(store, record, entry, { now: 10_000 });
  assert.ok(first.queued);
  assert.deepEqual(first.queued.args, { wallet: WALLET });

  const queued = store.take(record.id);
  assert.equal(queued.length, 1);
  assert.equal(queued[0].cmd, 'setup');

  // The rig has not applied it yet and says so again a minute later.
  const second = reconcile.run(store, record, entry, { now: 70_000 });
  assert.equal(second.queued, null);
  assert.equal(second.why, 'already asked, waiting');
  assert.equal(store.get(record.id).queue.length, 0);

  // Once it matches, the cooldown is forgotten so a later drift is immediate.
  record.status.wallet = WALLET;
  assert.equal(reconcile.run(store, record, entry, { now: 80_000 }).why, 'matches');
  assert.equal(record.correction_at, 0);
  record.status.wallet = '';
  assert.ok(reconcile.run(store, record, entry, { now: 90_000 }).queued);
});

test('the fleet survives a restart with nothing on disk', async () => {
  const dir = tmpdir();
  const key = crypto.randomBytes(32).toString('hex');
  const id = ids.deviceId(key);
  const roster = rosterModule.parse({
    owner: 'tg:1',
    rigs: { [id]: { label: 'basement', wallet: WALLET, mode: 'safe', maxtemp: 72 } },
  });

  async function checkIn(store) {
    const server = createServer({
      config: CONFIG,
      store,
      now: () => 1_700_000_000_000,
      onCheckIn: (record, stamp) => {
        const entry = roster.rigs.get(record.id);
        if (entry) reconcile.run(store, record, entry, { now: stamp });
      },
    }).server;
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    const base = `http://127.0.0.1:${server.address().port}`;
    try {
      const response = await fetch(`${base}/v1/hello`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', authorization: `Bearer ${key}` },
        body: JSON.stringify({ status: { state: 'mining', hashrate: 1000, threads: '8', mode: 'max' } }),
      });
      return await response.json();
    } finally {
      await new Promise((resolve) => server.close(resolve));
    }
  }

  // First life: nothing on disk, the roster is all there is.
  const before = storeAt(dir);
  rosterModule.apply(before, roster, 1);
  const first = await checkIn(before);
  assert.equal(first.enrolled, true, 'a rig in the roster is enrolled before it is ever claimed');
  assert.equal(first.commands.length, 1);
  assert.equal(first.commands[0].cmd, 'setup');
  assert.equal(first.commands[0].wallet, WALLET);
  assert.equal(first.commands[0].mode, 'safe');

  // The restart: a brand new store, an empty directory, the same roster.
  const empty = fs.mkdtempSync(path.join(os.tmpdir(), 'zmrig-restart-'));
  const after = storeAt(empty);
  rosterModule.apply(after, roster, 2);
  const second = await checkIn(after);
  assert.equal(second.enrolled, true, 'still enrolled after the disk was emptied');
  assert.equal(second.commands.length, 1, 'and still reconciled, because the rig still disagrees');
  assert.equal(after.get(id).label, 'basement');

  // A rig that already matches is left alone on the next check-in.
  after.get(id).status.wallet = WALLET;
  after.get(id).status.mode = 'safe';
  const plan = reconcile.run(after, after.get(id), roster.rigs.get(id), { now: 1_700_000_060_000 });
  assert.equal(plan.queued, null);
});

test('the first key to present a roster id is the one it keeps', async () => {
  const dir = tmpdir();
  const store = storeAt(dir);
  const key = crypto.randomBytes(32).toString('hex');
  const id = ids.deviceId(key);
  const roster = rosterModule.parse({ owner: 'tg:1', rigs: { [id]: { label: 'basement' } } });
  rosterModule.apply(store, roster, 1);
  assert.equal(store.get(id).secret_hash, null);

  async function knock() {
    const server = createServer({ config: CONFIG, store, now: () => 1_700_000_000_000 }).server;
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    const base = `http://127.0.0.1:${server.address().port}`;
    try {
      const response = await fetch(`${base}/v1/hello`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', authorization: `Bearer ${key}` },
        body: JSON.stringify({ status: { state: 'mining', hashrate: 1 } }),
      });
      return { code: response.status, body: await response.json() };
    } finally {
      await new Promise((resolve) => server.close(resolve));
    }
  }

  const first = await knock();
  assert.equal(first.code, 200, 'the machine that owns the ID is let in');
  assert.equal(first.body.enrolled, true);
  const bound = store.get(id);
  assert.equal(bound.secret_hash, ids.sha256(key), 'and the record is pinned to its key');
  assert.equal(ids.verifySecret(key, bound), true);

  // Pinned means pinned: another hash is refused, exactly as for a rig that
  // enrolled itself through the chat.
  bound.secret_hash = 'f'.repeat(64);
  const second = await knock();
  assert.equal(second.code, 403);
});

test('a rig that is not in the roster is untouched', async () => {
  const dir = tmpdir();
  const store = storeAt(dir);
  const key = crypto.randomBytes(32).toString('hex');
  const roster = rosterModule.parse({ rigs: { 'ZMR-1A2B-3C4D-5E6F': { wallet: OTHER } } });

  const server = createServer({
    config: CONFIG,
    store,
    now: () => 1_700_000_000_000,
    onCheckIn: (record, stamp) => {
      const entry = roster.rigs.get(record.id);
      if (entry) reconcile.run(store, record, entry, { now: stamp });
    },
  }).server;
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    const body = await (await fetch(`${base}/v1/hello`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${key}` },
      body: JSON.stringify({ status: { state: 'mining', hashrate: 1 } }),
    })).json();
    assert.equal(body.enrolled, false);
    assert.equal(body.commands.length, 0, 'an unknown rig gets no instructions at all');
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('the environment wins over the file, and neither is written', () => {
  const dir = tmpdir();
  const file = path.join(dir, 'roster.json');
  fs.writeFileSync(file, JSON.stringify({ rigs: { 'ZMR-1A2B-3C4D-5E6F': { label: 'from file' } } }));

  const fromFile = rosterModule.load({ FLEET_ROSTER_FILE: file, FLEET_ROSTER: '' });
  assert.equal(fromFile.rigs.get('ZMR-1A2B-3C4D-5E6F').label, 'from file');
  assert.equal(fromFile.source, file);

  const fromEnv = rosterModule.load({
    FLEET_ROSTER_FILE: file,
    FLEET_ROSTER: JSON.stringify({ rigs: { 'ZMR-1A2B-3C4D-5E6F': { label: 'from env' } } }),
  });
  assert.equal(fromEnv.rigs.get('ZMR-1A2B-3C4D-5E6F').label, 'from env');
  assert.equal(fromEnv.source, 'FLEET_ROSTER');

  const missing = rosterModule.load({ FLEET_ROSTER_FILE: path.join(dir, 'absent.json') });
  assert.equal(missing.rigs.size, 0);
  assert.deepEqual(missing.problems, [], 'a missing file is not an error, it is an empty roster');

  // And the file is still exactly what it was: the roster is read, never updated.
  assert.equal(JSON.parse(fs.readFileSync(file, 'utf8')).rigs['ZMR-1A2B-3C4D-5E6F'].label, 'from file');
});

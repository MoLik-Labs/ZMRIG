'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');

const { Store } = require('../src/store');
const ids = require('../src/ids');
const { createServer } = require('../src/http');
const { MINER, substitute } = require('../../tests/common/monero');

const CONFIG = {
  interval: 60,
  offline_after: 300,
  queue_limit: 10,
  alert_temp: 85,
  alert_cooldown: 1800,
  alert_hashrate_drop: 0.5,
};

async function rig(overrides = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zmrig-http-'));
  const store = new Store(path.join(dir, 'state.json')).load();
  const events = [];
  // The server takes its clock from here, so "an hour later" is a variable and
  // the suite does not sleep through the rate limiter and the alert windows.
  let clock = 1_700_000_000_000;
  const { server } = createServer({
    config: { ...CONFIG, ...overrides },
    store,
    log: () => {},
    now: () => clock,
    onEvent: (event) => events.push(event),
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  return {
    store,
    events,
    base,
    advance: (ms) => {
      clock += ms;
    },
    // The sweep runs on a timer in the process; here it is called by hand, and
    // it has to see the same clock the handler does.
    now: () => clock,
    key: crypto.randomBytes(32).toString('hex'),
    close: () => new Promise((resolve) => server.close(resolve)),
  };
}

function hello(fleet, body, options = {}) {
  const key = 'key' in options ? options.key : fleet.key;
  return fetch(`${fleet.base}/v1/hello`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      ...(key ? { authorization: `Bearer ${key}` } : {}),
    },
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });
}

test('a rig with no key gets nothing', async () => {
  const fleet = await rig();
  try {
    const response = await hello(fleet, { status: {} }, { key: null });
    assert.equal(response.status, 401);

    const short = await hello(fleet, { status: {} }, { key: 'abc' });
    assert.equal(short.status, 401);
  } finally {
    await fleet.close();
  }
});

test('the first check-in claims the id and waits for an operator', async () => {
  const fleet = await rig();
  try {
    const response = await hello(fleet, { status: { state: 'mining', hashrate: 900 } });
    const body = await response.json();

    assert.equal(response.status, 200);
    assert.equal(body.ok, true);
    assert.equal(body.enrolled, false, 'an unclaimed rig is told it is not enrolled');
    assert.deepEqual(body.commands, []);
    assert.equal(body.interval, 60);

    const record = fleet.store.get(ids.deviceId(fleet.key));
    assert.equal(record.owner, null);
    assert.equal(record.status.hashrate, 900);
    assert.equal(record.status.state, 'mining');
    assert.ok(record.last_seen > 0);
  } finally {
    await fleet.close();
  }
});

test('a valid key speaking for another id is refused', async () => {
  const fleet = await rig();
  try {
    const other = ids.deviceId(crypto.randomBytes(32).toString('hex'));
    const response = await hello(fleet, { device: other, status: {} });
    assert.equal(response.status, 403);

    const spoof = await hello(fleet, { device: 'ZMR-AAAA-BBBB-CCCC', status: {} });
    assert.equal(spoof.status, 403);
  } finally {
    await fleet.close();
  }
});

test('an enrolled rig receives its queued changes exactly once', async () => {
  const fleet = await rig();
  try {
    await (await hello(fleet, { status: { state: 'mining' } })).json();
    const record = fleet.store.get(ids.deviceId(fleet.key));
    fleet.store.enrol(record.id, 'tg:1', 'basement');
    fleet.store.push(record.id, { cmd: 'setup', args: { wallet: '4abc' } });
    fleet.store.push(record.id, { cmd: 'restart' });
    fleet.advance(3000);

    const first = await (await hello(fleet, { status: { state: 'mining', hashrate: 1200 } })).json();
    assert.equal(first.enrolled, true);
    assert.equal(first.commands.length, 2);
    assert.deepEqual(first.commands[0].cmd, 'setup');
    assert.equal(first.commands[0].wallet, '4abc', 'arguments are flattened onto the command');
    assert.deepEqual(first.commands[1].cmd, 'restart');
    assert.ok(first.commands[0].id);

    fleet.advance(3000);
    const second = await (await hello(fleet, { status: { state: 'mining' } })).json();
    assert.deepEqual(second.commands, [], 'a change is not applied twice');
  } finally {
    await fleet.close();
  }
});

test('a check-in flood is bounded', async () => {
  const fleet = await rig();
  try {
    assert.equal((await hello(fleet, { status: {} })).status, 200);
    const again = await hello(fleet, { status: {} });
    assert.equal(again.status, 429);
    const body = await again.json();
    assert.equal(body.interval, 60);
  } finally {
    await fleet.close();
  }
});

test('a broken body is a 400, not a crash', async () => {
  const fleet = await rig();
  try {
    const broken = await hello(fleet, '{"device":');
    assert.equal(broken.status, 400);

    // A body over the limit is refused; depending on timing that is a 400 or a
    // dropped connection, and either is acceptable. What is not acceptable is a
    // server that buffers it and falls over.
    let status = 0;
    try {
      status = (await hello(fleet, { status: { state: 'x'.repeat(70_000) } })).status;
    } catch (error) {
      status = 413;
    }
    assert.equal([400, 413].includes(status), true);
  } finally {
    await fleet.close();
  }
});

test('unknown paths, health and the landing page', async () => {
  const fleet = await rig();
  try {
    assert.equal((await fetch(`${fleet.base}/nope`)).status, 404);

    const health = await (await fetch(`${fleet.base}/healthz`)).json();
    assert.equal(health.ok, true);

    await (await hello(fleet, { status: { state: 'mining', hashrate: 1500 } })).json();
    const record = fleet.store.get(ids.deviceId(fleet.key));
    fleet.store.enrol(record.id, 'tg:1', 'basement');

    const page = await (await fetch(`${fleet.base}/`)).text();
    assert.match(page, /ZMRIG fleet/);
    assert.match(page, /basement/);
    assert.match(page, /1\.5 kH\/s/);
    // The page is public: it must never show an address or a key.
    assert.equal(page.includes(fleet.key), false);
    assert.equal(page.includes('4abc'), false);
  } finally {
    await fleet.close();
  }
});

test('a rig that comes back after an outage says so', async () => {
  const alerts = require('../src/alerts');
  const fleet = await rig();
  try {
    await hello(fleet, { status: { state: 'mining', hashrate: 1000, temp: 60 } });
    const record = fleet.store.get(ids.deviceId(fleet.key));
    fleet.store.enrol(record.id, 'tg:1');

    // Silence past the threshold: the sweep is the only thing that notices, and
    // the rig's own last status still says it is mining - which is precisely
    // the case the old condition treated as "nothing to say".
    fleet.advance((CONFIG.offline_after + 60) * 1000);
    const swept = alerts.sweep(fleet.store, CONFIG, fleet.now());
    assert.equal(swept.length, 1);
    assert.equal(swept[0].kind, 'offline');

    fleet.advance(30_000);
    await hello(fleet, { status: { state: 'mining', hashrate: 1000, temp: 60 } });

    const back = fleet.events.find((event) => event.kind === 'online');
    assert.ok(back, 'the check-in that ended the outage reports it');
    assert.match(back.text, /is back after/);
    assert.equal(record.offline_notified, false, 'and the flag is cleared, so it is said once');

    fleet.advance(30_000);
    await hello(fleet, { status: { state: 'mining', hashrate: 1000, temp: 60 } });
    assert.equal(fleet.events.filter((event) => event.kind === 'online').length, 1);
  } finally {
    await fleet.close();
  }
});

test('alerts fire on heat, on a stop and on a return', async () => {
  const fleet = await rig();
  try {
    const record = (await (await hello(fleet, { status: { state: 'mining', hashrate: 1000, temp: 60 } })).json(), fleet.store.get(ids.deviceId(fleet.key)));
    fleet.store.enrol(record.id, 'tg:1');

    fleet.advance(3000);
    await (await hello(fleet, { status: { state: 'mining', hashrate: 1000, temp: 91 } })).json();
    assert.equal(fleet.events.some((event) => event.kind === 'temp'), true);

    fleet.advance(3000);
    await (await hello(fleet, { status: { state: 'stopped', hashrate: 0, temp: 70, reason: 'no wallet' } })).json();
    const stopped = fleet.events.find((event) => event.kind === 'stopped');
    assert.ok(stopped);
    assert.match(stopped.text, /no wallet/);
  } finally {
    await fleet.close();
  }
});

test('a rig that reports a wallet it cannot be paid on is reported once', async () => {
  const fleet = await rig();
  try {
    const record = (await (await hello(fleet, { status: { state: 'mining', hashrate: 1000, temp: 60 } })).json(), fleet.store.get(ids.deviceId(fleet.key)));
    fleet.store.enrol(record.id, 'tg:1');

    // Every character base58, the right length, the wrong address: the rig is
    // hashing into nothing and has no way to know. The control plane is the
    // only place this can be noticed before the pool statement arrives.
    fleet.advance(3000);
    await (await hello(fleet, { status: { state: 'mining', hashrate: 1000, temp: 60, wallet: substitute(MINER, 20) } })).json();

    const wallet = fleet.events.filter((event) => event.kind === 'wallet');
    assert.equal(wallet.length, 1, 'one alert, not one per check-in');
    assert.match(wallet[0].text, /invalid wallet address/);
    assert.match(wallet[0].text, /checksum does not match/);
    assert.match(wallet[0].text, /can be paid|Nothing mined/);

    // The same broken address again is the same alert: an alert is an event.
    fleet.advance(3000);
    await (await hello(fleet, { status: { state: 'mining', hashrate: 1000, temp: 60, wallet: substitute(MINER, 20) } })).json();
    assert.equal(fleet.events.filter((event) => event.kind === 'wallet').length, 1);

    // A good address, a worker name and nothing at all say nothing - otherwise
    // every rig in the fleet would page its owner on the first check-in.
    fleet.advance(60_000 * 40);
    for (const value of [MINER, `${MINER}.shed-1`, 'rig-1', '']) {
      await (await hello(fleet, { status: { state: 'mining', hashrate: 1000, temp: 60, wallet: value } })).json();
    }
    assert.equal(fleet.events.filter((event) => event.kind === 'wallet').length, 1);
  } finally {
    await fleet.close();
  }
});

test('a rig mining under its own measurement is reported once', async () => {
  const fleet = await rig();
  try {
    const record = (await (await hello(fleet, { status: { state: 'mining', hashrate: 900, measured: 2000 } })).json(), fleet.store.get(ids.deviceId(fleet.key)));
    fleet.store.enrol(record.id, 'tg:1');

    const drift = fleet.events.find((event) => event.kind === 'drift');
    assert.ok(drift, 'a rig at half its measured rate is an alert');
    assert.match(drift.text, /45%/);
    assert.match(drift.text, /2\.0 kH\/s/);

    // An alert is an event, not a state: the next check-in says the same thing
    // and must not say it again.
    fleet.advance(3000);
    await (await hello(fleet, { status: { state: 'mining', hashrate: 900, measured: 2000 } })).json();
    assert.equal(fleet.events.filter((event) => event.kind === 'drift').length, 1);

    // A rig with no measurement, or one that is fine, says nothing.
    fleet.advance(60_000 * 10);
    await (await hello(fleet, { status: { state: 'mining', hashrate: 1900, measured: 2000 } })).json();
    assert.equal(fleet.events.filter((event) => event.kind === 'drift').length, 1);
  } finally {
    await fleet.close();
  }
});

test('a command result is reported back to the operators', async () => {
  const fleet = await rig();
  try {
    const record = (await (await hello(fleet, { status: {} })).json(), fleet.store.get(ids.deviceId(fleet.key)));
    fleet.store.enrol(record.id, 'tg:1');

    fleet.advance(3000);
    await (await hello(fleet, {
      status: { state: 'mining' },
      acks: [{ id: 'abc', cmd: 'setup', ok: false, detail: 'wallet rejected' }],
    })).json();

    const failure = fleet.events.find((event) => event.kind === 'ack');
    assert.ok(failure);
    assert.match(failure.text, /wallet rejected/);
  } finally {
    await fleet.close();
  }
});

test('a stranger cannot fill the state file with unenrolled devices', async () => {
  // Any 64-hex Bearer token produces a record, because a rig that has never been
  // enrolled still has to be able to knock. That is also an open door on a host
  // with a public URL: curl in a loop, a record each, and every one of them is a
  // full rewrite of the JSON file the fleet keeps its state in — which on Render
  // is /tmp, so it is RAM, and a free instance has 512 MB of it.
  const fleet = await rig({ unowned_limit: 20, unowned_ttl: 3600 });
  try {
    for (let index = 0; index < 60; index += 1) {
      const key = crypto.randomBytes(32).toString('hex');
      const response = await hello(fleet, { status: { state: 'mining' } }, { key });
      assert.equal(response.status, 200, 'a stranger is still answered, it is the table that is bounded');
    }
    assert.ok(fleet.store.unowned() <= 20, `the table stays under the cap, found ${fleet.store.unowned()}`);

    // A real rig is not locked out by the cap, which is the whole reason this
    // evicts instead of refusing: an operator cannot enrol a machine whose first
    // check-in was refused, because the enrolment code is checked against the
    // record that check-in would have made.
    const fresh = crypto.randomBytes(32).toString('hex');
    const checkingIn = async () => {
      fleet.advance(61_000);
      return hello(fleet, { status: { state: 'mining' } }, { key: fresh });
    };
    assert.equal((await hello(fleet, { status: { state: 'starting' } }, { key: fresh })).status, 200);
    for (let index = 0; index < 5; index += 1) {
      assert.equal((await checkingIn()).status, 200, 'a rig that keeps checking in keeps its record');
    }
    assert.ok(fleet.store.get(ids.deviceId(fresh)), 'the rig waiting to be enrolled survived the flood');

    // Enrolled, it is out of the pool entirely.
    fleet.store.enrol(ids.deviceId(fresh), 'tg:1');
    assert.equal((await checkingIn()).status, 200, 'and an owned rig checks in whatever the cap says');

    // Which rigs were evicted is the oldest by last check-in, which is what keeps
    // the flood from ever touching the ones that are waiting to be enrolled.
    const survivor = fleet.store.get(ids.deviceId(fresh));
    assert.ok(survivor.owner, 'the survivor is the one that was enrolled');
  } finally {
    await fleet.close();
  }
});

test('one typo on a shared wallet is one message, not one per rig', async () => {
  const fleet = await rig();
  try {
    // A farm: five rigs, one wallet, and the wallet has a typo in it. They
    // check in within seconds of each other because that is what rigs do.
    const keys = [fleet.key, ...Array.from({ length: 4 }, () => crypto.randomBytes(32).toString('hex'))];
    for (const key of keys) fleet.store.claim(key);

    const typo = substitute(MINER, 20);
    // The check-in rate limiter is per rig, so each rig gets its own minute;
    // they are still all inside one cooldown window, which is the point.
    for (const [index, key] of keys.entries()) {
      fleet.advance(CONFIG.interval * 1000 + 1000);
      await hello(fleet, { status: { state: 'mining', hashrate: 1000, temp: 60 } }, { key });
      fleet.advance(CONFIG.interval * 1000 + 1000);
      const answer = await hello(fleet, { status: { state: 'mining', hashrate: 1000, temp: 60, wallet: typo } }, { key });
      assert.equal(answer.status, 200, `rig ${index + 1} check-in`);
      assert.equal(
        fleet.events.filter((event) => event.kind === 'wallet').length,
        1,
        `rig ${index + 1} of 5 must not repeat the warning`
      );
    }

    // The first rig's message is honest about its own rig; the ones that follow
    // are still marked, so after the cooldown the message says "5 rigs" instead
    // of naming a single machine that happens to have spoken first.
    fleet.advance(CONFIG.alert_cooldown * 1000 + 60_000);
    await hello(fleet, { status: { state: 'mining', hashrate: 1000, temp: 60, wallet: typo } }, { key: keys[0] });

    const wallet = fleet.events.filter((event) => event.kind === 'wallet');
    assert.equal(wallet.length, 2, 'one per cooldown, not one per rig');
    assert.match(wallet[1].text, /5 rigs/);
    assert.match(wallet[1].text, /checksum does not match/);
  } finally {
    await fleet.close();
  }
});

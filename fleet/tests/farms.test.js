'use strict';

const test = require('node:test');
const assert = require('node:assert');

const farms = require('../src/farms');

const CONFIG = { interval: 60, offline_after: 300 };
const NOW = 1_700_000_000_000;

const WALLET_A = '46SQLW7DXaq6GJaQbHUFMAhd1VYpfQFJQ2gfZo9TCB8bf9vnf1MUwAD2Fwj6KMsY4RU3oKA3x6hByg8BKg7FfMWn6ysb5tJ';
const WALLET_B = '888tNkZrPN6JsEgekjMnABU4TBzc2Dt29EPAvkRxbANsAnjyPbb3iQ1YBRk1UXcdRsiKc9dhwMVgN5S9cQUiyoogDavup3H';

function rig({ id, wallet, hashrate = 0, temp = 60, state = 'mining', seen = NOW, owner = 'tg:1' }) {
  return {
    id,
    owner,
    label: id,
    last_seen: seen,
    queue: [],
    acks: [],
    status: { wallet, hashrate, temp, state },
  };
}

test('rigs on one wallet are one number', () => {
  const devices = [
    rig({ id: 'A1', wallet: WALLET_A, hashrate: 1000 }),
    rig({ id: 'A2', wallet: WALLET_A, hashrate: 2500 }),
    rig({ id: 'A3', wallet: WALLET_A, hashrate: 500 }),
  ];

  const groups = farms.group(devices, CONFIG, NOW);
  assert.equal(groups.length, 1);
  assert.equal(groups[0].wallet, WALLET_A);
  assert.equal(groups[0].rate, 4000, 'the farm total is the sum, not the biggest rig');
  assert.equal(groups[0].rigs, 3);
  assert.equal(groups[0].mining, 3);
});

test('two wallets are two farms, biggest first', () => {
  const devices = [
    rig({ id: 'A1', wallet: WALLET_A, hashrate: 100 }),
    rig({ id: 'B1', wallet: WALLET_B, hashrate: 900 }),
  ];

  const groups = farms.group(devices, CONFIG, NOW);
  assert.deepEqual(groups.map((g) => g.wallet), [WALLET_B, WALLET_A]);
  assert.deepEqual(groups.map((g) => g.rate), [900, 100]);
});

test('a rig that stopped answering stops contributing, but is still counted', () => {
  const devices = [
    rig({ id: 'A1', wallet: WALLET_A, hashrate: 1000 }),
    rig({ id: 'A2', wallet: WALLET_A, hashrate: 1000, seen: NOW - 3_600_000 }),
  ];

  const groups = farms.group(devices, CONFIG, NOW);
  assert.equal(groups[0].rate, 1000, 'the silent rig does not keep its last number in the total');
  assert.equal(groups[0].rigs, 2, 'but it is still one of the farm rigs');
  assert.equal(groups[0].online, 1);
});

test('a rig with no wallet yet is its own group, listed last', () => {
  const devices = [
    rig({ id: 'X1', wallet: '', hashrate: 5000 }),
    rig({ id: 'A1', wallet: WALLET_A, hashrate: 10 }),
  ];

  const groups = farms.group(devices, CONFIG, NOW);
  assert.equal(groups[0].wallet, WALLET_A, 'a working farm outranks the unconfigured rig');
  assert.equal(groups[1].wallet, farms.UNKNOWN);
  assert.match(farms.lines(groups)[1], /no wallet yet/);
});

test('the share is of what the fleet is producing right now', () => {
  const devices = [
    rig({ id: 'A1', wallet: WALLET_A, hashrate: 750 }),
    rig({ id: 'B1', wallet: WALLET_B, hashrate: 250 }),
  ];

  const lines = farms.lines(farms.group(devices, CONFIG, NOW));
  assert.match(lines[0], /75%/, 'the big wallet is three quarters');
  assert.match(lines[1], /25%/);

  // Everything offline: no division by zero, and no invented percentage.
  const quiet = farms.lines(farms.group([
    rig({ id: 'A1', wallet: WALLET_A, hashrate: 900, seen: NOW - 3_600_000 }),
  ], CONFIG, NOW));
  assert.match(quiet[0], /0%/, 'a farm that is entirely offline reads 0%');
});

test('a rig nobody owns is not in a farm', () => {
  const devices = [
    rig({ id: 'A1', wallet: WALLET_A, hashrate: 100 }),
    rig({ id: 'Z1', wallet: WALLET_A, hashrate: 999999, owner: null }),
  ];

  const groups = farms.group(devices, CONFIG, NOW);
  assert.equal(groups.length, 1);
  assert.equal(groups[0].rate, 100, 'an unclaimed record must not add to somebody else\'s total');
});

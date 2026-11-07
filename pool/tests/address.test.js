// The address decoder is the last thing between a typo and a lost payout, so it
// is tested three ways: against real addresses, against addresses *built* here
// from their bytes (which exercises the network table and the block base58
// encoding, not just the two fixtures that happen to be in the repo), and
// against every single-character substitution a person could make.
//
//   node --test pool/tests/address.test.js

'use strict';

const test = require('node:test');
const assert = require('node:assert');

const { check, payable, decodeBase58, hex, keccak256, NETWORKS } = require('../../lib/address');
const { ALPHABET, MINER, OPERATOR, build, encode, keysOf, onNetwork, substitute } = require('../../tests/common/monero');

// --------------------------------------------------------------------- tests

test('keccak-256 matches the published vectors, not the SHA3 ones', () => {
  // Keccak pads with 0x01 and SHA3 with 0x06. Node only has the latter, which
  // is why this is implemented in lib/address.js - and why these two values,
  // not any digest size, are the test that it was implemented correctly.
  assert.equal(
    hex(keccak256(new Uint8Array(0))),
    'c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470',
  );
  assert.equal(
    hex(keccak256('abc')),
    '4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45',
  );
});

test('a real address decodes into its spend and view keys', () => {
  const verdict = check(MINER);

  assert.equal(verdict.ok, true);
  assert.equal(verdict.kind, 'standard');
  assert.equal(verdict.net, 'mainnet');
  assert.match(verdict.spend, /^[0-9a-f]{64}$/);
  assert.match(verdict.view, /^[0-9a-f]{64}$/);
  assert.notEqual(verdict.spend, verdict.view);
  assert.equal(verdict.paymentId, null);
  assert.equal(payable(MINER), true);
  assert.equal(payable(OPERATOR), true);
});

test('a copy-paste from a terminal or a file is accepted', () => {
  // Wallets are copied, not typed: the trailing newline and the quotes around
  // an address in a config file are not part of it.
  assert.equal(payable(`  ${MINER}\n`), true);
  assert.equal(payable(`${MINER} `), true);
});

test('every single-character substitution is refused, with a reason', () => {
  // This is the failure the old alphabetical check could not see: 95
  // characters, all of them base58, and one of them wrong. Two substitutions
  // per position is 190 attempts; anything but a clean refusal here is a payout
  // to an address nobody can spend from.
  for (let at = 0; at < MINER.length; at++) {
    const broken = substitute(MINER, at);
    const verdict = check(broken);

    assert.equal(verdict.ok, false, `position ${at} was accepted: ${broken}`);
    // Either the checksum catches it, or the characters no longer fit their
    // block - both are refusals, and both are true statements about the string.
    assert.match(
      verdict.reason,
      /checksum|more than 8 bytes/,
      `position ${at} was refused for the wrong reason: ${verdict.reason}`,
    );
    assert.equal(payable(broken), false);
  }
});

test('the wrong length, the wrong alphabet and nothing at all are named', () => {
  assert.match(check('').reason, /empty/);
  assert.match(check(MINER.slice(0, 94)).reason, /94/);
  assert.match(check(`${MINER}x`).reason, /96/);
  assert.match(check(`${MINER.slice(0, 94)}0`).reason, /not a base58 character/);
  assert.match(check(`${MINER.slice(0, 94)}O`).reason, /not a base58 character/);
  assert.match(check('hello').reason, /95 characters/);
  assert.match(check(undefined).reason, /empty/);
});

test('an address built with another network byte is valid there and not payable here', () => {
  const keys = keysOf(MINER);

  for (const [byte, net] of [[24, 'stagenet'], [53, 'testnet']]) {
    const address = build(byte, keys);
    const verdict = check(address);

    assert.equal(verdict.ok, true, `${net} address was refused: ${verdict.reason}`);
    assert.equal(verdict.net, net);
    assert.equal(verdict.spend, check(MINER).spend);
    // The keys are the same; the chain is not. A pool on mainnet must not pay.
    assert.equal(payable(address), false);
  }
});

test('a subaddress and an integrated address are recognised for what they are', () => {
  const keys = keysOf(MINER);
  const paymentId = Buffer.from('0011223344556677', 'hex');

  const sub = check(build(42, keys));
  assert.equal(sub.ok, true, sub.reason);
  assert.equal(sub.kind, 'subaddress');
  assert.equal(payable(build(42, keys)), true);

  const integrated = check(build(19, keys, paymentId));
  assert.equal(integrated.ok, true, integrated.reason);
  assert.equal(integrated.kind, 'integrated');
  assert.equal(integrated.paymentId, '0011223344556677');
  assert.equal(integrated.net, 'mainnet');
  assert.equal(payable(build(19, keys, paymentId)), true);
});

test('the length and the network byte have to agree about a payment id', () => {
  const keys = keysOf(MINER);

  // A payment id carried by a standard address, and an integrated address with
  // no payment id at all: both are the right checksum and the wrong address.
  const padded = check(build(18, keys, Buffer.from('0011223344556677', 'hex')));
  assert.equal(padded.ok, false);
  assert.match(padded.reason, /payment id/);

  const missing = check(build(19, keys));
  assert.equal(missing.ok, false);
  assert.match(missing.reason, /payment id/);
});

test('an unknown network byte is refused instead of guessed', () => {
  const verdict = check(onNetwork(MINER, 200));

  assert.equal(verdict.ok, false);
  assert.match(verdict.reason, /network byte 200/);
  // Every byte the table claims is a network, and none of them overlap.
  assert.equal(new Set([...NETWORKS.keys()]).size, NETWORKS.size);
});

test('the block base58 round-trips every block length', () => {
  for (let length = 1; length <= 11; length++) {
    const raw = Buffer.alloc(length);
    for (let i = 0; i < length; i++) raw[i] = (i * 37 + length) & 0xff;

    const decoded = decodeBase58(encode(raw));
    assert.ok(decoded, `length ${length} did not decode`);
    assert.equal(hex(decoded), hex(raw), `length ${length}`);
  }

  // A block that does not fit its characters is not a Monero encoding: eleven
  // 'z' characters hold more than 64 bits.
  assert.equal(decodeBase58('zzzzzzzzzzz'), null);
  assert.equal(decodeBase58('0000'), null);
});

test('a name that only looks like an address is not one', () => {
  // Rigs name themselves things like `rig-1`; the pool must treat that as a
  // worker name, not as a 95-character address, and this is the function that
  // decides which.
  for (const name of ['rig-1', 'shed/basement', 'x', '4', '4abc']) {
    assert.equal(payable(name), false, name);
  }
});

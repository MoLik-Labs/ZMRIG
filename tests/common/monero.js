// Building Monero addresses by hand, for tests.
//
// The validator in `lib/address.js` decodes; this encodes. Tests that only use
// the two addresses committed to the repository cannot tell whether the network
// table or the block encoding is right - they only prove two strings decode. An
// address built here from a network byte and 64 bytes of key material can be
// any kind on any chain, which is what those tests need.
//
// Not used by the pool, the bot or the rig agent: this is test scaffolding, and
// it lives in tests/ so that nothing can import it by accident.

'use strict';

const { ALPHABET, keccak256 } = require('../../lib/address');

/** A real mainnet wallet (the one the docs use). */
const MINER = '4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge';

/** A real mainnet address used as the pool operator's own. */
const OPERATOR = '46SQLW7DXaq6GJaQbHUFMAhd1VYpfQFJQ2gfZo9TCB8bf9vnf1MUwAD2Fwj6KMsY4RU3oKA3x6hByg8BKg7FfMWn6ysb5tJ';

// Bytes -> characters, Monero's table: at most 8 bytes per 8-byte block.
const BLOCK_CHARS = [0, 2, 3, 5, 6, 7, 9, 10, 11];

/** Monero base58: independent blocks, so 8 bytes become 11 characters. */
function encode(raw) {
  let out = '';

  for (let offset = 0; offset < raw.length; offset += 8) {
    const chunk = raw.subarray(offset, offset + 8);
    const size = BLOCK_CHARS[chunk.length];
    let value = BigInt(`0x${Buffer.concat([Buffer.alloc(8 - chunk.length), chunk]).toString('hex')}`);
    let text = '';

    for (let i = 0; i < size; i++) {
      text = ALPHABET[Number(value % 58n)] + text;
      value /= 58n;
    }
    out += text;
  }

  return out;
}

/**
 * A syntactically perfect address: network byte, 64 bytes of keys, optional
 * 8-byte payment id, and the checksum the address itself would carry.
 */
function build(networkByte, keys, paymentId) {
  const head = Buffer.from([networkByte]);
  const body = Buffer.concat([head, keys, paymentId].filter(Boolean));
  const sum = keccak256(body).subarray(0, 4);

  return encode(Buffer.concat([body, sum]));
}

/** The 64 bytes of key material inside a real address, as one Buffer. */
function keysOf(address) {
  const { check } = require('../../lib/address');
  const verdict = check(address);

  return Buffer.concat([Buffer.from(verdict.spend, 'hex'), Buffer.from(verdict.view, 'hex')]);
}

/** A real 106-character mainnet integrated address. */
function integrated(address = MINER, paymentId = '0011223344556677') {
  return build(19, keysOf(address), Buffer.from(paymentId, 'hex'));
}

/** The same address on another chain: same keys, different network byte. */
function onNetwork(address, networkByte) {
  return build(networkByte, keysOf(address));
}

/** One character changed to the next one in the alphabet. */
function substitute(text, at) {
  const replacement = ALPHABET[(ALPHABET.indexOf(text[at]) + 1) % 58];

  return text.slice(0, at) + replacement + text.slice(at + 1);
}

module.exports = { ALPHABET, MINER, OPERATOR, build, encode, integrated, keysOf, onNetwork, substitute };

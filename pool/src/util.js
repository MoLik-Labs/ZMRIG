// Small helpers shared by the pool. No dependencies.

'use strict';

const HEX = /^[0-9a-fA-F]*$/;

function isHex(text) {
  return typeof text === 'string' && HEX.test(text);
}

function isHexOf(text, bytes) {
  return isHex(text) && text.length === bytes * 2;
}

/** Little-endian u64 from the last 8 bytes of a 32-byte hash. BigInt on purpose:
 *  a double would lose the low bits of a 64-bit target. */
function hashValue(hashBytes) {
  let value = 0n;
  for (let i = 0; i < 8; i++) {
    value |= BigInt(hashBytes[24 + i]) << BigInt(8 * i);
  }
  return value;
}

function hexToBytes(text) {
  if (!isHex(text) || text.length % 2 !== 0) return null;
  return Buffer.from(text, 'hex');
}

function bytesToHex(bytes) {
  return Buffer.from(bytes).toString('hex');
}

/** 32 bytes of randomness as hex, used for job ids and nonce windows. */
function randomHex(bytes) {
  return require('node:crypto').randomBytes(bytes).toString('hex');
}

function nowSeconds() {
  return Math.floor(Date.now() / 1000);
}

function clamp(value, min, max) {
  return Math.min(Math.max(value, min), max);
}

/** XMR amounts are atomic units (1e-12). Keep them as BigInt everywhere. */
const ATOMIC = 1000000000000n;

function parseXmr(text) {
  const value = String(text).trim();
  if (!/^\d+(\.\d{1,12})?$/.test(value)) return null;

  const [whole, fraction = ''] = value.split('.');
  const padded = (fraction + '0'.repeat(12)).slice(0, 12);

  return BigInt(whole) * ATOMIC + BigInt(padded);
}

function formatXmr(atomic) {
  const value = BigInt(atomic);
  const whole = value / ATOMIC;
  const fraction = (value % ATOMIC).toString().padStart(12, '0');

  return `${whole}.${fraction}`;
}

/**
 * True for an address this pool can pay: 95 base58 characters *and* a checksum
 * that matches.
 *
 * The alphabet check alone accepts one wrong character in fifty. A miner with a
 * typo then mines for a week, is credited correctly, and the payout goes to an
 * address whose spend key nobody holds - so the check moved to `address.js`,
 * which decodes and verifies. The regex stays as a fast reject.
 */
function looksLikeAddress(text) {
  if (typeof text !== 'string') return false;
  const address = text.split('.')[0].trim();
  if (!/^[48][1-9A-HJ-NP-Za-km-z]{94}$/.test(address)) return false;

  return require('./address').payable(address);
}

/** `wallet.rig` or `wallet/rig` login -> { address, worker } */
function splitLogin(login) {
  const text = String(login || '').trim();
  const match = text.match(/^([^.^/]+)[./](.*)$/);

  if (!match) return { address: text, worker: '' };

  return { address: match[1], worker: match[2].slice(0, 32) };
}

module.exports = {
  ATOMIC,
  bytesToHex,
  clamp,
  formatXmr,
  hashValue,
  hexToBytes,
  isHex,
  isHexOf,
  looksLikeAddress,
  nowSeconds,
  parseXmr,
  randomHex,
  splitLogin,
};

// A Monero address is 95 base58 characters carrying a checksum, and a regex
// that only looks at the alphabet accepts roughly one typo in fifty.
//
// Why this file exists: the pool paid out to whatever came out of `splitLogin`,
// and `looksLikeAddress` was `/^[48][1-9A-HJ-NP-Za-km-z]{94}$/`. Change one
// character of a real address to another character of the same alphabet and it
// still matches - so a miner with a typo in their config mined for a week, was
// credited correctly, and the payout would have gone to an address whose spend
// key nobody holds. The coins are not lost to a bug in the pool; they are lost
// to a typo that nothing in the chain would ever question.
//
// Structure of what is decoded:
//
//   standard      1 + 32 + 32 + 4 = 69 bytes, 95 characters
//   integrated    1 + 32 + 32 + 8 + 4 = 77 bytes, 106 characters
//
// The first byte is the network, the next two 32-byte halves are the public
// spend and view keys, and the last four are the first four bytes of
// Keccak-256 over everything before them.
//
// Keccak-256, not SHA3-256. Node's `crypto` has the FIPS variant, which pads
// differently and produces a different digest, so this is implemented here.

'use strict';

const ALPHABET = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

// Network byte -> what the address is. Mainnet, stagenet and testnet all use
// the same layout, so an address from another network is a valid address that
// this pool must not pay: the keys live on a different chain.
const NETWORKS = new Map([
  [18, { kind: 'standard', net: 'mainnet' }],
  [19, { kind: 'integrated', net: 'mainnet' }],
  [42, { kind: 'subaddress', net: 'mainnet' }],
  [43, { kind: 'integrated-subaddress', net: 'mainnet' }],
  [24, { kind: 'standard', net: 'stagenet' }],
  [25, { kind: 'integrated', net: 'stagenet' }],
  [36, { kind: 'subaddress', net: 'stagenet' }],
  [37, { kind: 'integrated-subaddress', net: 'stagenet' }],
  [53, { kind: 'standard', net: 'testnet' }],
  [54, { kind: 'integrated', net: 'testnet' }],
  [63, { kind: 'subaddress', net: 'testnet' }],
  [64, { kind: 'integrated-subaddress', net: 'testnet' }],
]);

// ---------------------------------------------------------------- keccak-256

const ROUND_CONSTANTS = [
  0x0000000000000001n, 0x0000000000008082n, 0x800000000000808an, 0x8000000080008000n,
  0x000000000000808bn, 0x0000000080000001n, 0x8000000080008081n, 0x8000000000008009n,
  0x000000000000008an, 0x0000000000000088n, 0x0000000080008009n, 0x000000008000000an,
  0x000000008000808bn, 0x800000000000008bn, 0x8000000000008089n, 0x8000000000008003n,
  0x8000000000008002n, 0x8000000000000080n, 0x000000000000800an, 0x800000008000000an,
  0x8000000080008081n, 0x8000000000008080n, 0x0000000080000001n, 0x8000000080008008n,
];

// Rotation offsets, indexed [x + 5y].
const ROTATIONS = [
  0, 1, 62, 28, 27,
  36, 44, 6, 55, 20,
  3, 10, 43, 25, 39,
  41, 45, 15, 21, 8,
  18, 2, 61, 56, 14,
];

const MASK = 0xffffffffffffffffn;

function rotl(value, shift) {
  if (shift === 0) return value;
  const bits = BigInt(shift);

  return ((value << bits) | (value >> (64n - bits))) & MASK;
}

function keccakF(state) {
  for (let round = 0; round < 24; round++) {
    // theta
    const c = new Array(5);
    for (let x = 0; x < 5; x++) c[x] = state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20];
    for (let x = 0; x < 5; x++) {
      const d = c[(x + 4) % 5] ^ rotl(c[(x + 1) % 5], 1);
      for (let y = 0; y < 25; y += 5) state[y + x] ^= d;
    }

    // rho + pi
    const b = new Array(25);
    for (let x = 0; x < 5; x++) {
      for (let y = 0; y < 5; y++) {
        b[y + 5 * ((2 * x + 3 * y) % 5)] = rotl(state[x + 5 * y], ROTATIONS[x + 5 * y]);
      }
    }

    // chi
    for (let y = 0; y < 25; y += 5) {
      for (let x = 0; x < 5; x++) {
        state[y + x] = b[y + x] ^ (~b[y + ((x + 1) % 5)] & MASK & b[y + ((x + 2) % 5)]);
      }
    }

    // iota
    state[0] ^= ROUND_CONSTANTS[round];
  }
}

/** Bytes in, bytes out: a string is read as UTF-8, a Buffer or any typed array
 *  as its bytes. Deliberately `Uint8Array` and not `Buffer`: the same file runs
 *  in the pool, in the bot and in the browser bundle of the documentation site,
 *  where `Buffer` does not exist. */
function toBytes(input) {
  if (typeof input === 'string') {
    const bytes = new Uint8Array(input.length);
    for (let i = 0; i < input.length; i++) bytes[i] = input.charCodeAt(i) & 0xff;
    return bytes;
  }
  if (input instanceof Uint8Array) return input;
  if (Array.isArray(input)) return Uint8Array.from(input);
  return new Uint8Array(input && input.buffer ? input.buffer : 0);
}

function readU64LE(bytes, offset) {
  let value = 0n;
  for (let i = 7; i >= 0; i--) value = (value << 8n) | BigInt(bytes[offset + i]);
  return value;
}

function writeU64LE(bytes, offset, value) {
  let rest = value;
  for (let i = 0; i < 8; i++) {
    bytes[offset + i] = Number(rest & 0xffn);
    rest >>= 8n;
  }
}

/** Lower-case hex of a byte array. */
function hex(bytes) {
  let out = '';
  for (let i = 0; i < bytes.length; i++) out += bytes[i].toString(16).padStart(2, '0');
  return out;
}

/** Keccak-256 of bytes or a string, as 32 bytes. */
function keccak256(input) {
  const source = toBytes(input);
  const rate = 136; // 1088 bits
  const padded = new Uint8Array(Math.floor(source.length / rate) * rate + rate);
  padded.set(source);

  // pad10*1 with the Keccak (not SHA3) domain byte 0x01
  padded[source.length] ^= 0x01;
  padded[padded.length - 1] ^= 0x80;

  const state = new Array(25).fill(0n);
  for (let offset = 0; offset < padded.length; offset += rate) {
    for (let i = 0; i < rate / 8; i++) {
      state[i] ^= readU64LE(padded, offset + i * 8);
    }
    keccakF(state);
  }

  const out = new Uint8Array(32);
  for (let i = 0; i < 4; i++) writeU64LE(out, i * 8, state[i]);

  return out;
}

// ------------------------------------------------------------------- base58

/**
 * Decodes a base58 string into bytes, or null if it is not a valid encoding.
 *
 * Monero does not use plain big-integer base58: it encodes *blocks*, 8 bytes to
 * 11 characters, and pads the last block. Reading the whole string as one
 * number therefore gives 70 bytes for a 69-byte address - which is one of the
 * two ways a naive decoder rejects every real address in the world.
 */
function decodeBase58(text) {
  const out = [];

  for (let i = 0; i < text.length;) {
    const size = Math.min(11, text.length - i);
    const bytesInBlock = Math.floor((size * 8) / 11);
    let value = 0n;

    for (let k = 0; k < size; k++) {
      const index = ALPHABET.indexOf(text[i + k]);
      if (index < 0) return null;
      value = value * 58n + BigInt(index);
    }

    const block = [];
    for (let b = 0; b < bytesInBlock; b++) {
      block.push(Number(value & 0xffn));
      value >>= 8n;
    }
    // Anything left over did not fit its block: not a Monero encoding.
    if (value > 0n) return null;

    out.push(...block.reverse());
    i += size;
  }

  return Uint8Array.from(out);
}

/**
 * Checks a Monero address: alphabet, length, network byte and checksum.
 *
 * Returns `{ ok: true, kind, net, spend, view, paymentId }` or
 * `{ ok: false, reason }` with a reason meant to be shown to whoever typed it.
 */
function check(input) {
  const text = String(input ?? '').trim();
  if (!text) return { ok: false, reason: 'empty' };

  if (text.length !== 95 && text.length !== 106) {
    return { ok: false, reason: `a Monero address is 95 characters (106 with a payment id), this is ${text.length}` };
  }

  for (const character of text) {
    if (!ALPHABET.includes(character)) {
      return { ok: false, reason: `'${character}' is not a base58 character, so this is not an address` };
    }
  }

  // The alphabet is already known good at this point, so the only way for the
  // decoder to fail is a block whose characters hold more than its 8 bytes -
  // still a refusal, but with a reason that is true.
  const raw = decodeBase58(text);
  if (!raw) return { ok: false, reason: 'one block of characters holds more than 8 bytes, so this cannot be an address' };

  const integrated = text.length === 106;
  const body = integrated ? 73 : 65;
  if (raw.length !== body + 4) {
    return { ok: false, reason: `decoded to ${raw.length} bytes, expected ${body + 4}` };
  }

  const digest = keccak256(raw.subarray(0, body));
  for (let i = 0; i < 4; i++) {
    if (digest[i] !== raw[body + i]) {
      return { ok: false, reason: 'checksum does not match: at least one character is wrong' };
    }
  }

  const network = NETWORKS.get(raw[0]);
  if (!network) return { ok: false, reason: `network byte ${raw[0]} is not a Monero network` };
  if (integrated !== (network.kind === 'integrated' || network.kind === 'integrated-subaddress')) {
    return { ok: false, reason: `a ${network.kind} address cannot carry ${integrated ? '' : 'no '}payment id` };
  }

  return {
    ok: true,
    kind: network.kind,
    net: network.net,
    spend: hex(raw.subarray(1, 33)),
    view: hex(raw.subarray(33, 65)),
    paymentId: integrated ? hex(raw.subarray(65, 73)) : null,
  };
}

/** True for an address a mainnet pool can pay: right checksum, right chain. */
function payable(input) {
  const result = check(input);
  return result.ok && result.net === 'mainnet';
}

module.exports = { ALPHABET, NETWORKS, check, decodeBase58, hex, keccak256, payable };

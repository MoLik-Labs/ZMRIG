'use strict';

const test = require('node:test');
const assert = require('node:assert');
const crypto = require('node:crypto');

const ids = require('../src/ids');

const secret = () => crypto.randomBytes(32).toString('hex');

test('a device id is stable and shaped like the console prints it', () => {
  const key = secret();
  const id = ids.deviceId(key);

  assert.match(id, /^ZMR-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}$/);
  assert.equal(ids.deviceId(key), id, 'the same key is always the same rig');
  assert.equal(ids.deviceId(key).length, 18);
});

test('different keys give different ids', () => {
  const seen = new Set();
  for (let index = 0; index < 200; index += 1) seen.add(ids.deviceId(secret()));
  assert.equal(seen.size, 200);
});

test('the enrolment code is derivable from the key and normalised on input', () => {
  const key = secret();
  const code = ids.enrolCode(key);

  assert.match(code, /^[0-9A-F]{4}-[0-9A-F]{4}$/);
  assert.equal(ids.normaliseCode(code.toLowerCase()), code);
  assert.equal(ids.normaliseCode(code.replace('-', ' ')), code);
  assert.equal(ids.normaliseCode('abcd1234'), 'ABCD-1234');
  assert.equal(ids.isCode('abcd-1234'), true);
  assert.equal(ids.isCode('abcd'), false);
});

test('a key only authenticates the rig it belongs to', () => {
  const mine = secret();
  const other = secret();
  const record = { id: ids.deviceId(mine), secret_hash: ids.sha256(mine) };

  assert.equal(ids.verifySecret(mine, record), true);
  assert.equal(ids.verifySecret(other, record), false);
  assert.equal(ids.verifySecret('not-a-key', record), false);
  // A valid key presented against somebody else's record is rejected because the
  // id is a function of the key.
  assert.equal(ids.verifySecret(other, { id: ids.deviceId(mine), secret_hash: ids.sha256(other) }), false);
});

test('a wrong code leaks nothing and a right one matches', () => {
  const key = secret();
  const record = { code: ids.enrolCode(key) };

  assert.equal(ids.sameDigest(ids.sha256(record.code), ids.sha256(record.code)), true);
  assert.equal(ids.sameDigest(ids.sha256('AAAA-AAAA'), ids.sha256(record.code)), false);
  assert.equal(ids.sameDigest(ids.sha256(''), ids.sha256(record.code)), false);
});

test('ids are recognised with the case and spaces people actually type', () => {
  const id = ids.deviceId(secret());
  assert.equal(ids.isDeviceId(id), true);
  assert.equal(ids.isDeviceId(` ${id.toLowerCase()} `), true);
  assert.equal(ids.isDeviceId('ZMR-1234-5678'), false);
  assert.equal(ids.isDeviceId('hello'), false);
});

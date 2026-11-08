// The verifier's contract with the binary: stdout carries JSON lines and
// nothing else, and anything else on that pipe must not become a rejected
// share.
//
// This exists because it did: `zmrig --verify-share` printed its fee banner on
// stdout before switching the log to stderr, so a pool that queued a share in
// the first moments of the child's life got the banner back as the reply and
// dropped the share - "verification unavailable" on a pool that was working
// perfectly.

'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');

const { Verifier } = require('../src/verifier');

const MINER = process.env.ZMRIG_BINARY || path.join(__dirname, '..', '..', 'zmrig', 'out', 'zmrig');

function share() {
  return {
    seed: crypto.randomBytes(32).toString('hex'),
    blob: crypto.randomBytes(76).toString('hex'),
    nonce: '00000001',
  };
}

test('a log line on the verifier pipe is not a share reply', async () => {
  // A stand-in with the same shape as a build that banners: one log line, then
  // the JSON the caller is waiting for.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zmrig-verifier-'));
  const fake = path.join(dir, 'fake-verifier.sh');
  fs.writeFileSync(fake, '#!/bin/sh\nprintf "[04:00:00] info developer fee\\n"\n'
    + 'while read -r line; do printf \'{"hash":"%s"}\\n\' "' + 'a'.repeat(64) + '"; done\n');
  fs.chmodSync(fake, 0o755);

  const verifier = new Verifier({ binary: fake, concurrency: 1, timeout: 5000 });
  verifier.start();
  try {
    const reply = await verifier.verify(share());
    assert.equal(reply, 'a'.repeat(64));
    assert.equal(verifier.stats.failed, 0, 'noise is skipped, not counted as a failure');
  } finally {
    verifier.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('a queue larger than the pool still drains', async () => {
  // One slot, five shares at once. `drain` used to run only when a caller
  // arrived, so the four shares queued behind the busy slot waited for the next
  // share to arrive - and timed out instead of being verified on a pool with
  // one verifier, which is the default on a 1 GB VPS.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zmrig-verifier-'));
  const fake = path.join(dir, 'fake-verifier.sh');
  fs.writeFileSync(fake, '#!/bin/sh\nwhile read -r line; do printf \'{"hash":"%s"}\\n\' "' + 'b'.repeat(64) + '"; done\n');
  fs.chmodSync(fake, 0o755);

  const verifier = new Verifier({ binary: fake, concurrency: 1, timeout: 4000 });
  verifier.start();
  try {
    const hashes = await Promise.all(Array.from({ length: 5 }, () => verifier.verify(share())));
    assert.equal(hashes.length, 5);
    for (const hash of hashes) assert.equal(hash, 'b'.repeat(64));
    assert.equal(verifier.stats.failed, 0);
  } finally {
    verifier.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('the binary the pool ships with answers on stdout alone', { skip: !fs.existsSync(MINER) }, async () => {
  const verifier = new Verifier({ binary: MINER, concurrency: 1, timeout: 20000 });
  verifier.start();
  try {
    // Queued immediately, before the child has had time to say anything: this
    // is the race that dropped the first share.
    const first = await verifier.verify(share());
    assert.match(first, /^[0-9a-f]{64}$/, 'the first share gets a hash, not a banner');
    assert.equal(verifier.stats.failed, 0);

    const rest = await Promise.all([share(), share(), share()].map((s) => verifier.verify(s)));
    for (const hash of rest) assert.match(hash, /^[0-9a-f]{64}$/);
  } finally {
    verifier.close();
  }
});

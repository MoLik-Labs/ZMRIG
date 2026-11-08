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

test('mode fast is passed to the binary, and anything else is not', async () => {
  // The verifier's speed comes from the child's `--mode`, so the flag has to
  // reach the child's argv. A typo in VERIFIER_MODE must not become a third
  // state: `fast` or `light`, nothing else.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zmrig-verifier-'));
  const fake = path.join(dir, 'echo-args.sh');
  // Prints its own arguments as the "hash", so the reply says what it was given.
  fs.writeFileSync(fake, '#!/bin/sh\necho "{\\"hash\\":\\"$*\\"}"\n'
    + 'while read -r line; do echo "{\\"hash\\":\\"$*\\"}"; done\n');
  fs.chmodSync(fake, 0o755);

  const fast = new Verifier({ binary: fake, concurrency: 1, timeout: 5000, mode: 'fast' });
  fast.start();
  const odd = new Verifier({ binary: fake, concurrency: 1, timeout: 5000, mode: 'FAST ' });
  odd.start();
  const typo = new Verifier({ binary: fake, concurrency: 1, timeout: 5000, mode: 'turbo' });
  typo.start();
  try {
    assert.match(await fast.verify(share()), /--verify-share --no-color --mode fast$/);
    // Padding and case are noise, a different word is not.
    assert.match(await odd.verify(share()), /--mode fast$/);
    assert.doesNotMatch(await typo.verify(share()), /--mode/, 'an unknown mode must fall back to light');
  } finally {
    fast.close();
    odd.close();
    typo.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('replies are matched to shares in the order they were written', async () => {
  // With a pipeline the child has several shares at once and answers them in
  // order; the pool must hand each hash back to the share that asked for it.
  // A queue that resolved "the first promise" instead would credit one rig
  // with another rig's hash, and the pool would reject both.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zmrig-verifier-'));
  const fake = path.join(dir, 'echo-nonce.sh');
  // Answers with the nonce it was given, so the reply identifies the request.
  fs.writeFileSync(fake, '#!/bin/sh\n'
    + 'while read -r line; do\n'
    + '  nonce=$(printf "%s" "$line" | sed -n "s/.*\\"nonce\\":\\"\\([0-9a-f]*\\)\\".*/\\1/p")\n'
    + '  printf \'{"hash":"%s"}\\n\' "$nonce"\n'
    + 'done\n');
  fs.chmodSync(fake, 0o755);

  const verifier = new Verifier({ binary: fake, concurrency: 1, threads: 2, pipeline: 4, timeout: 5000 });
  verifier.start();
  try {
    const nonces = Array.from({ length: 12 }, (_, i) => String(i + 1).padStart(8, '0'));
    const hashes = await Promise.all(nonces.map((nonce) => verifier.verify({ seed: 'aa'.repeat(32), blob: 'bb'.repeat(76), nonce })));
    assert.deepEqual(hashes, nonces, 'each share got its own answer, in order');
    assert.equal(verifier.stats.failed, 0);
  } finally {
    verifier.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('a silent verifier is replaced, not left with a share half answered', async () => {
  // A timeout with several shares in flight means the replies are out of step
  // with the requests: the share after the slow one would be answered by the
  // slow one's hash. The child is killed and every share in it fails - one
  // failed share is honest, a wrong hash is not.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zmrig-verifier-'));
  const fake = path.join(dir, 'silent.sh');
  fs.writeFileSync(fake, '#!/bin/sh\nwhile read -r line; do :; done\n');
  fs.chmodSync(fake, 0o755);

  const verifier = new Verifier({ binary: fake, concurrency: 1, threads: 2, pipeline: 3, timeout: 300 });
  verifier.start();
  try {
    const results = await Promise.allSettled(Array.from({ length: 3 }, (_, i) => verifier.verify({
      seed: 'aa'.repeat(32), blob: 'bb'.repeat(76), nonce: String(i + 1).padStart(8, '0'),
    })));
    for (const result of results) {
      assert.equal(result.status, 'rejected');
      assert.match(result.reason.message, /timed out/);
    }
    assert.equal(verifier.stats.failed, 3, 'every share in the dead child is counted, once');
  } finally {
    verifier.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('threads reach the child as -t, and one thread is the default', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zmrig-verifier-'));
  const fake = path.join(dir, 'echo-args.sh');
  fs.writeFileSync(fake, '#!/bin/sh\necho "{\\"hash\\":\\"$*\\"}"\n'
    + 'while read -r line; do echo "{\\"hash\\":\\"$*\\"}"; done\n');
  fs.chmodSync(fake, 0o755);

  const two = new Verifier({ binary: fake, concurrency: 1, threads: 2, timeout: 5000 });
  two.start();
  const one = new Verifier({ binary: fake, concurrency: 1, timeout: 5000 });
  one.start();
  try {
    assert.match(await two.verify(share()), /--verify-share --no-color -t 2$/);
    assert.doesNotMatch(await one.verify(share()), /-t/, 'the default is one thread, named by nobody');
  } finally {
    two.close();
    one.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('threaded verification returns the same hashes as one thread', { skip: !fs.existsSync(MINER) }, async () => {
  // The whole point of `-t` is that it is the same computation split up. This
  // is the test that says so with the real binary: same shares, two seeds (so
  // the dataset is rebuilt while the workers are running), and the answers must
  // match a single-threaded verifier byte for byte.
  const seeds = [crypto.randomBytes(32).toString('hex'), crypto.randomBytes(32).toString('hex')];
  const shares = [];
  for (const seed of seeds) {
    for (let i = 0; i < 6; i++) {
      shares.push({ seed, blob: crypto.randomBytes(76).toString('hex'), nonce: (i + 1).toString(16).padStart(8, '0') });
    }
  }

  const single = new Verifier({ binary: MINER, concurrency: 1, timeout: 60000 });
  const threaded = new Verifier({ binary: MINER, concurrency: 1, threads: 2, pipeline: 4, timeout: 60000 });
  single.start();
  threaded.start();
  try {
    // Sequential for the reference, all at once for the threaded one.
    const expected = [];
    for (const share of shares) expected.push(await single.verify(share));

    const actual = await Promise.all(shares.map((share) => threaded.verify(share)));

    assert.deepEqual(actual, expected, 'two threads agree with one, across a seed change');
    assert.equal(threaded.stats.failed, 0);
  } finally {
    single.close();
    threaded.close();
  }
});

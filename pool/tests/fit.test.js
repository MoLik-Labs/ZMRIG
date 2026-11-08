// The arithmetic behind the `VERIFIER_MODE=fast` warning.
//
// A fast verifier is 2336 MB of dataset + cache; the default is one verifier
// per core. On the 2 vCPU / 3.9 GiB test host that is 4.6 GiB of intent in
// 3.9 GiB of machine, and the kernel's answer is to kill a child that the pool
// then restarts - so the symptom is shares lost every few minutes, not a
// startup error. These tests pin the warning, and the cases where there must
// not be one.

'use strict';

const test = require('node:test');
const assert = require('node:assert');

const { roomMb, fastSlots, fastModeWarning, FAST_MODE_MB } = require('../src/fit');

const meminfo = (availableKb, hugeFree = 0) => ['MemTotal:        4034452 kB',
  `MemFree:         1254268 kB`,
  `MemAvailable:    ${availableKb} kB`,
  `HugePages_Total:    ${hugeFree}`,
  `HugePages_Free:     ${hugeFree}`].join('\n');

test('free huge pages count as room, because the verifier asks for them', () => {
  // The test host exactly: 1.3 GiB available plus 2.3 GiB of reserved huge
  // pages. Anonymous memory cannot use the pool, but a mapping that asks for
  // MAP_HUGETLB can - and the verifier does, then falls back.
  assert.equal(roomMb(meminfo(1336500, 1168)), 1305 + 1168 * 2);
  assert.equal(fastSlots(meminfo(1336500, 1168)), 1, 'one fast verifier fits, two do not');
});

test('a host that has nothing to say gets no warning', () => {
  // Not Linux, or a kernel without MemAvailable. "No idea" must not be
  // reported as "no room" - a pool on a BSD box would get a warning it cannot
  // act on.
  assert.equal(roomMb(''), null);
  assert.equal(roomMb(undefined), null);
  assert.equal(roomMb('MemTotal: 4034452 kB\n'), null);
  assert.equal(roomMb(meminfo(1000)), 0, 'under a MiB of MemAvailable is no room, not unknown');
  assert.equal(fastModeWarning('', { mode: 'fast', concurrency: 2 }), null);
});

test('a big host is not second-guessed', () => {
  assert.equal(fastModeWarning(meminfo(64 * 1024 * 1024), { mode: 'fast', concurrency: 8 }), null);
  assert.equal(fastSlots(meminfo(64 * 1024 * 1024)), 28);
});

test('light mode never warns, whatever the memory', () => {
  assert.equal(fastModeWarning(meminfo(1024), { mode: 'light', concurrency: 8 }), null);
  assert.equal(fastModeWarning(meminfo(1024), {}), null);
});

test('one verifier too many is named, with the number that fits', () => {
  const warning = fastModeWarning(meminfo(6 * 1024 * 1024), { mode: 'fast', concurrency: 4 });

  assert.match(warning, /needs 9344 MB/);
  assert.match(warning, /6144 MB can be allocated/);
  assert.match(warning, /VERIFIER_CONCURRENCY=2/);
});

test('a host that cannot hold one says so instead of suggesting zero', () => {
  const warning = fastModeWarning(meminfo(300 * 1024, 0), { mode: 'fast', concurrency: 2 });

  assert.match(warning, /cannot hold one fast verifier/);
  assert.match(warning, /light cache/);
  assert.doesNotMatch(warning, /VERIFIER_CONCURRENCY=0/);
});

test('the default is the number the docs quote', () => {
  // 2080 MB dataset + 256 MB cache, as zmrig's api.Algo reports them.
  assert.equal(FAST_MODE_MB, 2336);
});

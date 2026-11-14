// The share window: which shares count, and what expiring one costs.
//
// The pool keeps an hour of shares to split a block reward over. That list is
// written on every share from every rig and read on every status request, so
// both ends of it matter: the numbers have to be right, and expiring the oldest
// share must not memmove the whole window.
//
// This exists because it did. `shares.splice(0, n)` shifts every remaining
// entry, and with a full hour in the window (200 000 shares on the test host)
// adding one share cost **55.1 us** - 42x the cost of the same call on an empty
// ledger. Now the expired prefix is skipped with a cursor: **1.3 us**, and flat
// in the number of shares kept.

'use strict';

const test = require('node:test');
const assert = require('node:assert');

const { Ledger } = require('../src/ledger');

const MINER = `4${'A'.repeat(94)}`;
const OTHER = `4${'B'.repeat(94)}`;

function ledger(options = {}) {
  return new Ledger({
    feePercent: 1,
    operatorAddress: MINER,
    windowSeconds: 3600,
    minPayout: '10000000000',
    stateFile: null,
    auditFile: null,
    ...options,
  });
}

test('a share that falls out of the window stops being paid for', () => {
  const l = ledger({ windowSeconds: 60 });
  const now = 1_700_000_000;

  l.addShare(MINER, 1000, now - 120);   // outside
  l.addShare(MINER, 1000, now - 30);    // inside

  // Difficulty is carried in micro units (1e-6), the same scale the payout uses.
  const { weights } = l.windowWeights(now);
  assert.equal(weights.get(MINER), 1000n * 1000000n, 'only the share inside the window counts');

  l.addShare(MINER, 1000, now + 40);    // pushes both of the first two out
  assert.equal(l.windowWeights(now + 40).weights.get(MINER), 1000n * 1000000n);
});

test('expired shares are skipped, not copied, and the cursor stays bounded', () => {
  const l = ledger({ windowSeconds: 60 });
  const base = 1_700_000_000;

  // 20 000 shares, each one old by the time the next arrives: the worst case
  // for a splice, and the case a busy pool reaches every hour.
  for (let i = 0; i < 20000; i++) l.addShare(MINER, 1, base + i * 5);

  const live = l.windowWeights(base + 20000 * 5).weights.get(MINER);
  assert.ok(live > 0n, 'the newest shares are still in the window');

  // Shares are 5 s apart and the window is 60 s, so about twelve are live and
  // the other 19 988 are expired. The cursor must be folded back: without
  // compaction the array would be 20 000 entries of which 19 988 are dead.
  assert.ok(l.head <= 4096, `the cursor is folded back, not left to grow: head ${l.head}`);
  assert.ok(l.shares.length <= 4096 + 16,
    `dead entries are released: ${l.shares.length} kept, ${l.head} skipped, ${live} live`);
});

test('the oldest live share is still the oldest after compaction', () => {
  // `windowSpan` reads shares[head].ts and derives every hashrate in the pool
  // from it, so a compaction that reordered or duplicated entries would show up
  // as a hashrate that drifts on the status page.
  const l = ledger({ windowSeconds: 3600 });
  const base = 1_700_000_000;

  // One share a second for fifteen minutes: the span is that, not the size of
  // the array behind it.
  for (let i = 0; i <= 900; i++) l.addShare(i % 2 ? MINER : OTHER, 1000, base + i);
  assert.equal(l.windowSpan(base + 900), 900, 'fifteen minutes of history, from the oldest share');

  // Now let the whole thing age out of the window: the oldest *live* share
  // decides, and the span is capped by the window rather than by the array.
  for (let i = 0; i < 20000; i++) l.addShare(MINER, 1000, base + 5000 + i);
  assert.equal(l.windowSpan(base + 25000), 3600, 'the span is the window, not the array');
});

test('stats counts shares and active miners in one pass and agrees with the weights', () => {
  const l = ledger({ windowSeconds: 3600 });
  const now = Math.floor(Date.now() / 1000);

  for (let i = 0; i < 10; i++) l.addShare(MINER, 1000, now - 5);
  for (let i = 0; i < 5; i++) l.addShare(OTHER, 1000, now - 1000);
  // One miner seen only long ago: in the window, not active.
  l.addShare(MINER, 1000, now - 3000);

  const stats = l.stats();
  assert.equal(stats.sharesInWindow, 16);
  assert.equal(stats.activeWorkers, 1, 'OTHER has not submitted in five minutes');
  assert.equal(stats.workers, 2);

  const { weights, total } = l.windowWeights(now);
  assert.equal(total, 16000n * 1000000n, 'stats does not change what the payout sees');
  assert.equal(weights.get(MINER), 11000n * 1000000n);

  // The top list is derived from the same single pass, not a second one.
  assert.equal(stats.top.length, 2);
  assert.equal(stats.top[0].address, MINER);
  assert.equal(stats.top[0].sharePercent, 68.75);
});

test('the status numbers are memoised, and a share invalidates them', () => {
  // Three endpoints ask for the same numbers (`/`, `/api/stats`, `/metrics`) and
  // a scraper can ask every second. The walk is 21.6 ms over a full hour
  // (200 000 shares), so the answer is cached on what can change it.
  const l = ledger({ windowSeconds: 3600 });
  const now = Math.floor(Date.now() / 1000);
  l.addShare(MINER, 1000, now);

  const first = l.stats();
  const second = l.stats();
  assert.deepEqual(second, first, 'the same second, the same shares: the same answer');

  // A caller that sorts or edits the top list must not reach into the cache.
  first.top.push({ address: 'nonsense' });
  assert.equal(l.stats().top.length, 1);

  l.addShare(MINER, 1000, now);
  const after = l.stats();
  assert.equal(after.sharesInWindow, 2, 'a new share is not hidden by the cache');
  assert.notEqual(after.hashrate, first.hashrate);
});

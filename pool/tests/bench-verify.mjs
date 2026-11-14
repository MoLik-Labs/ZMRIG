// How fast can this machine verify shares?
//
// The pool re-hashes every share, so the verifier is the only thing between a
// rig and its credit. Its cost is not one number: the first share of a round
// pays for the 256 MB RandomX cache build, and every share after that reuses
// it. A job template changes with every block (~2 minutes on Monero), so the
// steady state is what matters and the build is a once-per-block hiccup.
//
// The three numbers printed below are exactly that:
//
//   seed      the cost of the first share after the seed changes
//   warm      shares/s with the cache already built
//   round     shares/s once the build is amortised over a 2-minute round
//
// Run it against a built miner:
//
//   ZMRIG_BINARY=$PWD/zmrig/out/zmrig node pool/tests/bench-verify.mjs
//
// Nothing here is a timing assertion: CI machines share cores with everything
// else, so a threshold would go red for reasons that have nothing to do with
// this repository. The numbers are printed, quoted in the docs, and measured
// again whenever they are quoted.

import { Verifier } from '../src/verifier.js';
import { randomBytes } from 'node:crypto';

const BINARY = process.env.ZMRIG_BINARY || 'zmrig';
const SHARES = Number(process.env.SHARES || 200);
const CONCURRENCY = Number(process.env.CONCURRENCY || 2);
const ROUND_SECONDS = Number(process.env.ROUND_SECONDS || 120);

// A share is a blob whose hash is below a target. The verifier does not care
// whether this particular nonce wins - it recomputes the hash and compares - so
// any blob exercises the real code path. What must vary is the *seed*.
function seed() {
  return randomBytes(32).toString('hex');
}

function blob() {
  return randomBytes(76).toString('hex');
}

async function measure(verifier, shares) {
  const started = process.hrtime.bigint();
  for (let i = 0; i < shares; i++) {
    // Every share is its own nonce in the same round: this is the arrival
    // pattern of real traffic from one rig.
    await verifier.verify({ seed: blob().slice(0, 64), blob: blob(), nonce: randomBytes(4).toString('hex') });
  }

  return Number(process.hrtime.bigint() - started) / 1e9;
}

const verifier = new Verifier({ binary: BINARY, concurrency: CONCURRENCY, timeout: 60000, logger: () => {} });
verifier.start();

try {
  // One round: the first share builds the cache for that seed.
  const roundSeed = seed();
  const firstStart = process.hrtime.bigint();
  await verifier.verify({ seed: roundSeed, blob: blob(), nonce: randomBytes(4).toString('hex') });
  const build = Number(process.hrtime.bigint() - firstStart) / 1e9;

  const warmSeconds = await measure(verifier, SHARES);
  // Note: `measure` sends its own (random) seed per share. That is the honest
  // worst case - a seed that changes constantly - so it is reported separately
  // rather than folded into the warm number below.
  const coldRate = SHARES / warmSeconds;

  // The warm number: one seed, the shares a rig actually submits in a round.
  const steady = seed();
  await verifier.verify({ seed: steady, blob: blob(), nonce: randomBytes(4).toString('hex') });
  const steadyStart = process.hrtime.bigint();
  for (let i = 0; i < SHARES; i++) {
    await verifier.verify({ seed: steady, blob: blob(), nonce: randomBytes(4).toString('hex') });
  }
  const steadySeconds = Number(process.hrtime.bigint() - steadyStart) / 1e9;
  const warmRate = SHARES / steadySeconds;

  const roundRate = SHARES / ((SHARES / warmRate) + build / ROUND_SECONDS);

  const out = [
    `binary        ${BINARY}`,
    `slots         ${CONCURRENCY}`,
    `shares        ${SHARES} per measurement`,
    '',
    `cache build   ${build.toFixed(3)} s   (first share of a round, once per block)`,
    `warm          ${warmRate.toFixed(1)} shares/s   (one seed, cache reused)`,
    `round         ${roundRate.toFixed(1)} shares/s  (steady state incl. one build per ${ROUND_SECONDS}s round)`,
    `seed churn    ${coldRate.toFixed(2)} shares/s   (a new seed for every share - pathological, shown for scale)`,
    '',
    `A rig at 1 kH/s on difficulty 300 submits ~3.3 shares/s, so this host`,
    `verifies it with room to spare.`,
  ];

  process.stdout.write(`${out.join('\n')}\n`);
} finally {
  verifier.close();
}

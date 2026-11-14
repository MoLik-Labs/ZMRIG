// Can this host pay for `VERIFIER_MODE=fast`?
//
// A fast verifier maps the 2336 MB RandomX dataset (2080 MB dataset + 256 MB
// cache) and keeps it for the life of the process. Two of them are 4.6 GiB. On
// the 2 vCPU / 3.9 GiB test host that is the whole machine, and the honest
// failure mode is not a clean error: the kernel picks a child and kills it, the
// pool restarts it (because that is what it does with a dead verifier), and the
// shares that were in flight are lost every few minutes - while `light` mode
// would have kept up with the rigs.
//
// So the pool reads /proc/meminfo once at startup and says the arithmetic out
// loud. This is a check, not a limiter: a pool on a 64 GB box must not be
// second-guessed, and /proc/meminfo is not the only truth (cgroups). It warns,
// and it is never allowed to stop the pool from starting.

'use strict';

/** Dataset + cache for rx/0, in MiB. From zmrig: 2079 + 256, rounded up. */
const FAST_MODE_MB = 2336;

/** Free huge pages are 2 MiB each and count as room: the verifier asks for
 *  them and falls back to anonymous pages, so a host that reserved 2.3 GiB for
 *  mining can run a fast verifier without also needing 2.3 GiB free. */
const HUGE_PAGE_MB = 2;

/**
 * Room a new mapping can actually be given, in MiB, or `null` if the text has
 * no `MemAvailable` (not Linux, or a kernel without it - both mean "no idea",
 * which is not the same as "no room").
 */
function roomMb(meminfo) {
  if (typeof meminfo !== 'string' || meminfo.length === 0) return null;

  const values = Object.create(null);
  for (const line of meminfo.split('\n')) {
    // `MemAvailable` is in kB; `HugePages_Free` is a count of 2 MiB pages and
    // has no unit at all, which is why this is not one pattern.
    const match = /^(MemAvailable|HugePages_Free):\s+(\d+)/.exec(line);
    if (match) values[match[1]] = Number(match[2]);
  }

  if (values.MemAvailable === undefined) return null;

  const anonymous = values.MemAvailable / 1024;
  const huge = (values.HugePages_Free || 0) * HUGE_PAGE_MB;

  return Math.floor(anonymous + huge);
}

/**
 * How many fast verifiers this host can hold without the OOM killer deciding
 * for us. `0` means even one does not fit and light mode is the answer.
 */
function fastSlots(meminfo, options = {}) {
  const perSlot = Number(options.datasetMb || FAST_MODE_MB);
  const room = roomMb(meminfo);
  if (room === null || !(perSlot > 0)) return null;

  return Math.floor(room / perSlot);
}

/**
 * A warning for the log, or `null` when there is nothing to say. Silence is the
 * normal outcome: either the mode is light, or the host has the RAM, or the
 * filesystem is not Linux and guessing would be worse than saying nothing.
 */
function fastModeWarning(meminfo, options = {}) {
  const mode = String(options.mode || 'light').trim().toLowerCase();
  const concurrency = Math.max(1, Number(options.concurrency || 1));
  if (mode !== 'fast') return null;

  const room = roomMb(meminfo);
  if (room === null) return null;

  const perSlot = Number(options.datasetMb || FAST_MODE_MB);
  const needed = perSlot * concurrency;
  if (needed <= room) return null;

  const slots = Math.max(0, Math.floor(room / perSlot));
  const how = slots === 0
    ? 'this host cannot hold one fast verifier: every child will fall back to the light cache (about 9x slower per share)'
    : `set VERIFIER_CONCURRENCY=${slots} to fit`;

  return `VERIFIER_MODE=fast needs ${needed} MB for ${concurrency} verifier(s) and ${room} MB can be allocated here: ${how}`;
}

module.exports = { FAST_MODE_MB, HUGE_PAGE_MB, roomMb, fastSlots, fastModeWarning };

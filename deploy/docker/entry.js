#!/usr/bin/env node
'use strict';

// zmrig in a container: one image, two jobs.
//
//   docker run --rm ghcr.io/molik-labs/zmrig version
//   docker run --rm -e WALLET=4... -e POOL=pool.example:3333 ghcr.io/molik-labs/zmrig
//   docker run --rm ghcr.io/molik-labs/zmrig pool
//   docker run --rm -e WALLET=4... ghcr.io/molik-labs/zmrig args
//
// Why a dispatcher instead of an ENTRYPOINT of `/usr/local/bin/zmrig`:
//
// A miner is configured with flags, and a container is configured with the
// environment - `docker run -e ...`, a compose file, a Kubernetes manifest, a
// PaaS form. Those two only meet in a shim, and the shim is this file. It reads
// the same names the appliance writes to /etc/zmrig/os.conf (WALLET, POOL,
// MODE, THREADS, DONATE, MSR, ...), so a person who has used `zmrig-os` already
// knows what to put in a compose file.
//
// `args` prints the command line without running it. That is the debugging
// entry point: when a rig mines with fewer threads than expected, the first
// question is what the container actually asked the miner to do.
//
// The wallet is checked at startup, by the miner itself (`--check-wallet`), so
// the verdict in the log is the same one `zmrig --check-wallet` prints on a
// bare-metal rig. The check is advisory: `rx/0` refuses a bad checksum on its
// own, and a pool on another coin legitimately takes a login that is not a
// Monero address. Duplicating that policy here would be a second opinion that
// could disagree with the binary.

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');

const DEFAULTS = {
  MODE: 'max',
  ALGO: 'auto',
  THREADS: 'auto',
  DONATE: '3',
  SAFE_TEMP: '72',
  MSR: 'auto',
  API_PORT: '0',
  WORKER: 'x',
};

// Every variable this file reads. `deploy/docker/tests/keys.test.js` compares
// this list with the table in doc/DOCKER.md, so a setting cannot be added here
// and left undocumented (the appliance has the same test for os.conf).
const KNOWN_ENV = [
  'WALLET',
  'POOL',
  'WORKER',
  'MODE',
  'ALGO',
  'THREADS',
  'DONATE',
  'SAFE_TEMP',
  'MSR',
  'API_PORT',
  'API_HOST',
  'API_TOKEN',
  'EXTRA_ARGS',
  'CHECK_WALLET',
  'POOL_CONFIG',
  'ZMRIG_BIN',
  'ZMRIG_CGROUP_DIR',
];

const USAGE = `zmrig in a container

  mine | (nothing)   run the miner (the default)
  pool               run the Ocean Pool in this image
  check              check WALLET and exit; the miner's own verdict
  args               print the miner command line and exit
  update --check     is a newer image published? (exit 3 = yes, 2 = cannot tell)
  version            print the image and miner versions
  <command> [args]   run any other command, e.g. sh

Environment (see doc/DOCKER.md): WALLET, POOL, WORKER, MODE, ALGO, THREADS,
DONATE, SAFE_TEMP, MSR, API_PORT, API_HOST, API_TOKEN, EXTRA_ARGS.
`;

function envOf(env, name, fallback) {
  const value = env[name];
  if (value === undefined || value === null || String(value).trim() === '') return fallback;
  return String(value).trim();
}

function boolOf(env, name, fallback) {
  const value = envOf(env, name, '').toLowerCase();
  if (['1', 'true', 'yes', 'on'].includes(value)) return true;
  if (['0', 'false', 'no', 'off'].includes(value)) return false;
  return fallback;
}

// --- the container's real CPU budget ---------------------------------------
//
// `--cpus=2` is a CFS quota, not an affinity mask: the process still sees every
// host CPU, so the miner's "one thread per physical core" heuristic asks for the
// whole machine and then has to share a fifth of it. Under a quota that is
// slower than the same number of threads at full speed - the run queue is not
// throttled thread by thread, the whole group is stopped when the quota is spent,
// so a thread that has a scratchpad in L3 sits idle for the rest of the period.
//
// Two files, because cgroup v2 is one line ("200000 100000", or "max 100000")
// and cgroup v1 is two, and a host can be either.
function cgroupCpus(env) {
  const root = envOf(env, 'ZMRIG_CGROUP_DIR', '/sys/fs/cgroup');

  const v2 = readPair(path.join(root, 'cpu.max'));
  if (v2) return v2;

  const quota = readNumber(path.join(root, 'cpu', 'cpu.cfs_quota_us'));
  const period = readNumber(path.join(root, 'cpu', 'cpu.cfs_period_us'));
  if (quota && period && quota > 0 && period > 0) return Math.max(1, Math.floor(quota / period));

  return null;
}

// The container's memory ceiling, in MiB, or null when there is none. This is
// the number that decides how RandomX runs: the dataset mode needs 2336 MB and
// `--mode=light` is the fallback, which is **10x slower** on the same cores
// (measured here: 973 H/s against 99 H/s with 2 threads). Nothing else about a container changes the hash rate that much, and the
// failure is silent - the miner keeps hashing, just slower - so `args` and the
// startup notes say it out loud.
function cgroupMemoryMb(env) {
  const root = envOf(env, 'ZMRIG_CGROUP_DIR', '/sys/fs/cgroup');

  for (const file of [path.join(root, 'memory.max'), path.join(root, 'memory', 'memory.limit_in_bytes')]) {
    const text = readText(file).trim();
    if (!text) continue;
    if (text === 'max') return null;
    const bytes = Number(text);
    if (!Number.isFinite(bytes) || bytes <= 0) continue;
    // cgroup v1 reports a sentinel near 2^63 for "unlimited".
    if (bytes >= 1 << 60) return null;
    return Math.floor(bytes / (1024 * 1024));
  }

  return null;
}

function readPair(file) {
  let text;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch {
    return null;
  }

  const [quotaText, periodText] = text.trim().split(/\s+/);
  if (!quotaText || quotaText === 'max') return null;

  const quota = Number(quotaText);
  const period = Number(periodText);
  if (!Number.isFinite(quota) || !Number.isFinite(period) || quota <= 0 || period <= 0) return null;

  return Math.max(1, Math.floor(quota / period));
}

function readNumber(file) {
  try {
    const value = Number(fs.readFileSync(file, 'utf8').trim());
    return Number.isFinite(value) ? value : null;
  } catch {
    return null;
  }
}

// --- what this container cannot see ---------------------------------------
//
// Two of the three things that move RandomX hashrate most are properties of the
// *container*, not of the rig: the huge page pool and `/dev/cpu/*/msr`. Both
// fail silently - the miner falls back to 4 KiB pages, or skips the prefetcher
// preset, and keeps hashing - so a container mines 18 % under the host next to
// it and nothing in the log says why. `args` is where an operator goes to ask
// that question, and these notes answer it before the command line.
//
// What it does *not* say: "you need --cap-add=IPC_LOCK". An anonymous
// MAP_HUGETLB mapping needs no capability - measured on this repo's test host,
// an unprivileged uid with CapEff=0 mapped 2336 MB from the pool inside a
// container, and the miner reported "2336 MB of 2336 MB came from the reserved
// pool". CAP_IPC_LOCK is about mlock(), and /dev/hugepages is about hugetlbfs
// files; neither is the path the miner takes. What does block the mapping is an
// empty pool (the host's `vm.nr_hugepages`) or a cgroup hugetlb limit of 0.
// Measured on the 2 vCPU test host, 2 threads, `--bench`: 973 H/s with the
// dataset and 99 H/s without. RandomX's own documentation says light mode is
// about 8x slower, so this is not a quirk of one machine.
const LIGHT_MODE_RATIO = 10;

function meminfoField(text, key) {
  if (!text) return 0;
  const match = new RegExp(`^${key}:\\s+(\\d+)`, 'm').exec(text);
  return match ? Number(match[1]) : 0;
}

function readText(file) {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch {
    return '';
  }
}

// `hugetlb.2MB.max` is a byte count, "max" when unlimited, and absent on a
// kernel with no hugetlb controller. Only the 0 case matters: it is the one
// that makes the mapping fail inside a container whose host has pages.
function hugetlbLimitBytes(env) {
  const root = envOf(env, 'ZMRIG_CGROUP_DIR', '/sys/fs/cgroup');
  for (const file of [path.join(root, 'hugetlb.2MB.max'), path.join(root, 'hugetlb', 'hugetlb.2MB.max')]) {
    const text = readText(file).trim();
    if (!text) continue;
    if (text === 'max') return null;
    const value = Number(text);
    return Number.isFinite(value) ? value : null;
  }
  return null;
}

// `smaps`/`meminfo` are the host's in a container, which is why these numbers
// are worth reporting: they are the pool the container *would* use if it could.
function perfNotes(env = process.env, opts = {}) {
  const notes = [];
  const meminfo = opts.meminfo ?? readText('/proc/meminfo');
  if (!meminfo) return notes; // not Linux: nothing here is true

  const freePages = meminfoField(meminfo, 'HugePages_Free');
  const pageKb = meminfoField(meminfo, 'Hugepagesize') || 2048;
  const limit = opts.hugetlbBytes !== undefined ? opts.hugetlbBytes : hugetlbLimitBytes(env);

  if (freePages === 0) {
    notes.push(
      `huge pages: none are reserved on the host, so RandomX reads 4 KiB pages instead of ${pageKb / 1024} MiB ` +
        '(about 18 % slower, measured); reserve them once on the host: sysctl -w vm.nr_hugepages=1168',
    );
  } else if (limit === 0) {
    notes.push(
      `huge pages: the host has ${freePages} free pages of ${pageKb / 1024} MiB but this container's hugetlb limit is 0, ` +
        'so it cannot map them: raise --hugetlb-2m on the container, or drop the limit',
    );
  }

  const msr = envOf(env, 'MSR', DEFAULTS.MSR).toLowerCase();
  const mode = envOf(env, 'MODE', DEFAULTS.MODE).toLowerCase();
  const hasMsr = opts.hasMsr !== undefined ? opts.hasMsr : fs.existsSync('/dev/cpu/0/msr');
  if (!hasMsr && msr !== 'off' && mode !== 'safe') {
    notes.push(
      'msr: /dev/cpu/0/msr is not in this container, so the prefetcher preset is skipped ' +
        '(5-15 % on bare metal, nothing in a VM); it needs --device /dev/cpu/0/msr --cap-add SYS_RAWIO --user 0',
    );
  }

  // The memory ceiling decides light vs dataset mode, which is worth more than
  // the two notes above put together (~2x on the same cores). `MODE=light` asked
  // for it, so that case is not a warning.
  if (mode !== 'light') {
    const limitMb = opts.memoryLimitMb !== undefined ? opts.memoryLimitMb : cgroupMemoryMb(env);
    // 2336 MB for the dataset + cache, plus the process itself and the JIT.
    const needMb = 2560;
    if (limitMb !== null && limitMb < needMb) {
      notes.push(
        `memory: this container is limited to ${limitMb} MB, so RandomX builds no dataset and hashes from the ` +
          `256 MB cache instead - ${LIGHT_MODE_RATIO}x slower, measured (973 H/s against 99 H/s on 2 threads). ` +
          `A dataset needs ${needMb} MB: docker run --memory=${Math.ceil(needMb / 512) * 512}m ...`,
      );
    } else if (limitMb === null) {
      // No limit of its own: the host's MemAvailable is what decides. Cheap to
      // ask, and it is the same question the miner will ask a second later.
      const available = Math.floor(meminfoField(meminfo, 'MemAvailable') / 1024);
      if (available > 0 && available < needMb) {
        notes.push(
          `memory: ${available} MB is available on this host and a RandomX dataset needs ${needMb} MB, ` +
            `so the miner will hash from the 256 MB cache: ${LIGHT_MODE_RATIO}x slower, measured (973 H/s against ` +
            '99 H/s on 2 threads). Free memory, or mine a smaller coin',
        );
      }
    }
  }

  return notes;
}

// Whole numbers only, and a donation of 3 is three: `--donate-level 3%` would be
// passed straight to a parser that rejects it, one argument after the wallet.
function number(env, name, fallback) {
  const raw = envOf(env, name, fallback);
  if (!/^-?\d+$/.test(raw)) return null;
  return Number(raw);
}

// --- the miner command line -----------------------------------------------
//
// Pure: environment in, argv out. `plan()` is what the tests drive, so the
// mapping is checked without Docker, a compiler, or a pool.
function minerArgs(env, opts = {}) {
  const notes = [];
  const mode = envOf(env, 'MODE', DEFAULTS.MODE).toLowerCase();
  const wallet = envOf(env, 'WALLET', '');
  const pool = envOf(env, 'POOL', '');
  const algo = envOf(env, 'ALGO', DEFAULTS.ALGO);

  if (!wallet) {
    return {
      error: 'no wallet: pass -e WALLET=<address>. The rig cannot be paid without one.\n' +
        'Check an address with: docker run --rm -e WALLET=4... ghcr.io/molik-labs/zmrig check',
    };
  }
  if (!pool) {
    return {
      error: 'no pool: pass -e POOL=host:port (tcp by default; tls://, ws://, wss:// work too).\n' +
        'See doc/POOLS.md for the URL forms.',
    };
  }

  if (!['max', 'eco', 'safe', 'light'].includes(mode)) {
    return { error: `MODE=${mode} is not one of max, eco, safe, light` };
  }

  const donate = number(env, 'DONATE', DEFAULTS.DONATE);
  if (donate === null || donate < 0 || donate > 10) {
    return { error: `DONATE=${envOf(env, 'DONATE', '')} is not a percentage between 0 and 10; use DONATE=0 to turn the developer fee off` };
  }

  const args = ['-o', pool, '-u', wallet, '-p', envOf(env, 'WORKER', DEFAULTS.WORKER)];

  // `auto` is not a missing value: it advertises every RandomX variant so a pool
  // that pays the best coin per hash can move this rig between them. Passing
  // `-a auto` explicitly is fine but noise, and the OS image omits it too.
  if (algo && algo !== 'auto') args.push('-a', algo);

  const threads = envOf(env, 'THREADS', DEFAULTS.THREADS);
  const quota = cgroupCpus(env);
  // The CPUs this container may actually run on, not the ones the host has.
  // `os.cpus()` lists the host, so a container started with
  // `--cpuset-cpus=0-1` (or under a Kubernetes cpuset) looked like a 16-CPU
  // machine and the shim pinned it to a thread count it could never run - the
  // miner's own heuristic reads sched_getaffinity and would have said 2.
  // `availableParallelism` is the same call the miner makes.
  const visible = (opts.cpus || Math.max(1, os.availableParallelism?.() || os.cpus().length || 1));

  if (threads !== 'auto') {
    if (!/^\d+$/.test(threads) || Number(threads) < 1) {
      return { error: `THREADS=${threads} is not a number; leave it unset to let the miner size itself` };
    }
    args.push('-t', threads);
    // An explicit request is respected even above the quota: an operator who
    // typed a number has a reason, and `--cpus` can be raised at any time.
    if (quota && Number(threads) > quota) {
      notes.push(`THREADS=${threads} is more than the ${quota}-CPU quota allows; the container will be throttled`);
    }
  } else if (quota && quota < visible) {
    args.push('-t', String(quota));
    notes.push(`the container is limited to ${quota} CPU${quota === 1 ? '' : 's'} (${visible} usable): ${quota} mining thread${quota === 1 ? '' : 's'}`);
  } else if (visible < hostCpus() && !quota) {
    // A cpuset without a quota: no `-t`, because the miner reads the same
    // affinity mask and sizes itself correctly. Saying so once is what turns
    // "why does it use 2 of my 16 cores" into an answer.
    notes.push(`cpuset: this container may only run on ${visible} of the ${hostCpus()} CPUs; the miner sizes itself to ${visible}`);
  }

  switch (mode) {
    case 'eco':
      args.push('--profile', 'watt');
      break;
    case 'safe':
      args.push('--profile', 'watt', '--max-temp', envOf(env, 'SAFE_TEMP', DEFAULTS.SAFE_TEMP));
      break;
    case 'light':
      args.push('--mode', 'light');
      break;
    default:
      args.push('--profile', 'free');
  }

  // MSR needs /dev/cpu/0/msr and bare metal. `auto` lets the miner's own probe
  // decide, which is the only setting that is right in a container it has not
  // seen yet. `safe` never writes a register, whatever this says.
  const msr = envOf(env, 'MSR', DEFAULTS.MSR).toLowerCase();
  if (mode === 'safe') args.push('--no-msr');
  else if (msr === 'on') args.push('--msr');
  else if (msr === 'off') args.push('--no-msr');

  // The fee is passed explicitly, always. `zmrig` defaults to 3 % too; writing
  // it into the command line means `docker run ... args` shows the number a rig
  // runs with instead of hiding a default inside the binary.
  args.push('--donate-level', String(donate));

  const apiPort = envOf(env, 'API_PORT', DEFAULTS.API_PORT);
  if (apiPort !== '0') {
    if (!/^\d+$/.test(apiPort)) return { error: `API_PORT=${apiPort} is not a port number` };
    // 0.0.0.0, not the miner's 127.0.0.1: inside a container a loopback bind is
    // reachable only from inside it, so a published port would answer nothing
    // and look like a broken API rather than a bind address.
    args.push('--http-port', apiPort, '--http-host', envOf(env, 'API_HOST', '0.0.0.0'));
    const token = envOf(env, 'API_TOKEN', '');
    if (token) args.push('--http-access-token', token);
  }

  args.push('--print-time', '60', '--health-restart', '900');
  if (!opts.tty) args.push('--no-color');

  const extra = envOf(env, 'EXTRA_ARGS', '');
  if (extra) args.push(...extra.split(/\s+/).filter(Boolean));

  return { args, notes, mode, wallet, pool, algo, donate, threads };
}

// --- plan: what would run, without running it ------------------------------
function plan(argv, env = process.env, opts = {}) {
  const command = argv[0] || 'mine';
  const rest = argv.slice(1);
  const bin = envOf(env, 'ZMRIG_BIN', '/usr/local/bin/zmrig');

  // `docker run img -o pool -u wallet ...`: flags instead of the environment.
  // Everything XMRig-shaped works this way, so an operator's existing command
  // line has to work too - and the env mapping is skipped rather than merged,
  // because half a command line from each is nobody's intent.
  if (command.startsWith('-')) {
    return { command: 'mine', bin, argv, check: false, passthrough: true };
  }

  switch (command) {
    case 'mine':
    case 'miner':
    case 'run': {
      const built = minerArgs(env, opts);
      if (built.error) return { error: built.error };
      return {
        command: 'mine',
        bin,
        argv: built.args,
        notes: built.notes,
        check: boolOf(env, 'CHECK_WALLET', true),
        wallet: built.wallet,
      };
    }

    case 'pool':
      return {
        command: 'pool',
        bin: process.execPath,
        argv: [path.join(__dirname, '..', '..', 'pool', 'src', 'index.js')].concat(
          envOf(env, 'POOL_CONFIG', '') ? ['--config', envOf(env, 'POOL_CONFIG', '')] : [],
          rest,
        ),
      };

    case 'check': {
      const wallet = envOf(env, 'WALLET', '') || rest[0] || '';
      if (!wallet) return { error: 'no wallet: pass -e WALLET=<address>, or `check <address>`' };
      return { command: 'check', bin, argv: ['--check-wallet', wallet] };
    }

    case 'args': {
      const built = minerArgs(env, opts);
      if (built.error) return { error: built.error };
      // Container-shaped notes belong to `args` only: a rig that restarts every
      // hour should not print the same advice into the log every time, and the
      // miner itself already warns about light mode and 4 KiB pages when it
      // starts. This is the answer to "why is this number lower than on the
      // host", asked once, by hand.
      return { command: 'args', bin, argv: built.args, notes: built.notes, perf: perfNotes(env, opts) };
    }

    case 'version':
      return { command: 'version', bin, argv: ['--version'] };

    case 'help':
    case '-h':
    case '--help':
      return { command: 'help' };

    case 'update':
      return { command: 'update', argv: rest };

    default:
      // Anything else runs as itself, so `docker run --rm img sh` is a shell in
      // the image and `docker run --rm img node -e ...` works.
      return { command: 'exec', bin: command, argv: rest };
  }
}

// --- running it -------------------------------------------------------------
//
// The child is the miner or the pool; this process is a shim. Signals have to be
// forwarded, because PID 1 is tini and it signals the shim, not the grandchild:
// without this, `docker stop` waits out its ten seconds and then kills a miner
// that never got the chance to write its last share to the log.
function run(bin, argv, env) {
  const child = spawn(bin, argv, { stdio: 'inherit', env });

  const forward = (signal) => {
    try {
      child.kill(signal);
    } catch {
      /* the child is already gone */
    }
  };

  for (const signal of ['SIGTERM', 'SIGINT', 'SIGHUP', 'SIGQUIT']) process.on(signal, () => forward(signal));

  child.on('error', (error) => {
    console.error(`zmrig: cannot run ${bin}: ${error.message}`);
    process.exit(127);
  });

  child.on('exit', (code, signal) => {
    if (signal) process.exit(128 + (os.constants.signals[signal] || 0));
    process.exit(code === null ? 1 : code);
  });
}

// The host's CPU count, for the message above: `os.cpus()` ignores a cpuset and
// `availableParallelism()` honours it, and the gap between the two is exactly
// what an operator needs told when a 16-core machine uses two cores.
function hostCpus() {
  return os.cpus().length || 1;
}

function describe() {
  const version = process.env.ZMRIG_VERSION || '';
  const tag = process.env.ZMRIG_TAG || 'latest';
  const image = process.env.ZMRIG_IMAGE || 'ghcr.io/molik-labs/zmrig';
  return { version, tag, image };
}

function main(argv, env) {
  const tty = Boolean(process.stdout.isTTY);
  const decision = plan(argv, env, { tty });

  if (decision.command === 'help') {
    process.stdout.write(USAGE);
    return 0;
  }

  if (decision.error) {
    console.error(`zmrig: ${decision.error}`);
    return 2;
  }

  if (decision.command === 'args') {
    for (const note of decision.notes || []) console.error(`zmrig: ${note}`);
    for (const note of decision.perf || []) console.error(`zmrig: ${note}`);
    console.log([decision.bin, ...decision.argv].join(' '));
    return 0;
  }

  // The image says which release it is, and the binary says which miner it is.
  // They are built from the same commit, so a mismatch means someone mounted a
  // different miner over the image - worth one line rather than a mystery.
  if (decision.command === 'version') {
    const image = describe();
    if (image.version) console.log(`image      ${image.image}:${image.tag} (${image.version})`);
    run(decision.bin, decision.argv, env);
    return null;
  }

  if (decision.command === 'update') {
    const { check } = require('./update.js');
    return check(decision.argv, env).then((code) => process.exit(code));
  }

  for (const note of decision.notes || []) console.error(`zmrig: ${note}`);

  // The wallet verdict, from the binary, before the pool is dialled. Printed and
  // not judged: see the comment at the top of this file.
  if (decision.command === 'mine' && decision.check) {
    try {
      const result = spawnSync(decision.bin, ['--check-wallet', decision.wallet], { stdio: 'inherit' });
      if (result.error) console.error(`zmrig: cannot check the wallet: ${result.error.message}`);
    } catch {
      /* a missing binary fails loudly below, with the miner's own error */
    }
  }

  run(decision.bin, decision.argv, env);
  return null;
}

if (require.main === module) {
  const code = main(process.argv.slice(2), process.env);
  if (typeof code === 'number') process.exit(code);
}

module.exports = { plan, minerArgs, perfNotes, cgroupCpus, main, KNOWN_ENV, DEFAULTS, describe, USAGE };

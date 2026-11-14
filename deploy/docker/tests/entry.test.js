'use strict';

// The container's environment -> the miner's command line.
//
// No Docker here on purpose. Everything that decides what a rig runs is a pure
// function (entry.js `plan`), so the interesting cases - a typo in MODE, a
// donation of 11 %, a container with a two-CPU quota - are checked in
// milliseconds instead of in a ten-minute image build, and the image job in CI
// only has to prove that the thing starts.

const test = require('node:test');
const assert = require('node:assert');
const os = require('node:os');
const fs = require('node:fs');
const path = require('node:path');

const { plan, minerArgs, cgroupCpus, KNOWN_ENV } = require('../entry.js');

const BASE = { WALLET: '4' + 'A'.repeat(94), POOL: 'pool.example:3333' };

function args(env, opts = { cpus: 4, tty: false }) {
  const decision = plan([], { ...BASE, ...env }, opts);
  assert.equal(decision.error, undefined, decision.error);
  return decision.argv;
}

function has(argv, ...needle) {
  for (let i = 0; i + needle.length <= argv.length; i += 1) {
    if (needle.every((value, j) => argv[i + j] === value)) return true;
  }
  return false;
}

test('the wallet, the pool and the worker are the login line', () => {
  const argv = args({ WORKER: 'rig-7' });
  assert.deepEqual(argv.slice(0, 6), ['-o', 'pool.example:3333', '-u', BASE.WALLET, '-p', 'rig-7']);
});

test('no wallet and no pool are refusals, not defaults', () => {
  const noWallet = plan([], { POOL: 'p:1' });
  assert.match(noWallet.error, /no wallet/);
  // The message has to say how to check one, or the next step is a search engine.
  assert.match(noWallet.error, /zmrig check/);

  const noPool = plan([], { WALLET: BASE.WALLET });
  assert.match(noPool.error, /no pool/);
});

test('the fee is always on the command line, so `args` shows what a rig pays', () => {
  assert.ok(has(args({}), '--donate-level', '3'));
  assert.ok(has(args({ DONATE: '0' }), '--donate-level', '0'));
  assert.ok(has(args({ DONATE: '1' }), '--donate-level', '1'));
});

test('a donation outside 0..10 is refused before the miner sees it', () => {
  for (const value of ['11', '-1', '3%', 'three']) {
    const decision = plan([], { ...BASE, DONATE: value });
    assert.match(decision.error, /DONATE/, value);
    assert.match(decision.error, /DONATE=0/, 'the message must say how to turn it off');
  }
});

test('the four modes map onto the miner the way the appliance maps them', () => {
  assert.ok(has(args({}), '--profile', 'free'), 'max is the default: full speed');
  assert.ok(has(args({ MODE: 'eco' }), '--profile', 'watt'));
  assert.ok(has(args({ MODE: 'light' }), '--mode', 'light'));
  assert.ok(has(args({ MODE: 'safe' }), '--profile', 'watt'));
  assert.ok(has(args({ MODE: 'safe' }), '--max-temp', '72'));
  assert.ok(has(args({ MODE: 'safe', SAFE_TEMP: '65' }), '--max-temp', '65'));
  assert.match(plan([], { ...BASE, MODE: 'turbo' }).error, /MODE=turbo/);
});

test('safe never writes an MSR register, whatever MSR says', () => {
  assert.ok(!has(args({ MODE: 'safe', MSR: 'on' }), '--msr'));
  assert.ok(has(args({ MODE: 'safe', MSR: 'on' }), '--no-msr'));
  assert.ok(has(args({ MSR: 'on' }), '--msr'));
  assert.ok(has(args({ MSR: 'off' }), '--no-msr'));
  assert.ok(!has(args({ MSR: 'auto' }), '--msr'), 'auto leaves the decision to the miner probe');
});

test('algo auto is omitted, an explicit algo is passed', () => {
  assert.ok(!has(args({}), '-a'));
  assert.ok(has(args({ ALGO: 'auto' }), '-a') === false);
  assert.ok(has(args({ ALGO: 'rx/wow' }), '-a', 'rx/wow'));
});

// The one optimisation that is specific to a container, and the reason it
// matters: `--cpus=2` is a quota, so the miner still sees every host CPU and
// asks for one thread per core, and the whole group is then throttled together.
test('a CPU quota caps the automatic thread count', () => {
  const argv = args({}, { cpus: 16 });
  // No /sys/fs/cgroup/cpu.max in this test environment that says otherwise, so
  // drive the quota explicitly through a fixture directory.
  assert.ok(Array.isArray(argv));

  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'cgroup-'));
  fs.writeFileSync(path.join(dir, 'cpu.max'), '200000 100000\n');
  assert.equal(cgroupCpus({ ZMRIG_CGROUP_DIR: dir }), 2);

  const capped = plan([], { ...BASE, ZMRIG_CGROUP_DIR: dir }, { cpus: 16, tty: false });
  assert.ok(has(capped.argv, '-t', '2'), 'two CPUs of quota is two mining threads');
  assert.match(capped.notes.join(' '), /limited to 2 CPUs/);

  // cgroup v1: the same answer from two files.
  const v1 = fs.mkdtempSync(path.join(os.tmpdir(), 'cgroup1-'));
  fs.mkdirSync(path.join(v1, 'cpu'));
  fs.writeFileSync(path.join(v1, 'cpu', 'cpu.cfs_quota_us'), '150000\n');
  fs.writeFileSync(path.join(v1, 'cpu', 'cpu.cfs_period_us'), '100000\n');
  assert.equal(cgroupCpus({ ZMRIG_CGROUP_DIR: v1 }), 1);

  // No limit is no answer, not a limit of zero.
  const open = fs.mkdtempSync(path.join(os.tmpdir(), 'cgroup-none-'));
  fs.writeFileSync(path.join(open, 'cpu.max'), 'max 100000\n');
  assert.equal(cgroupCpus({ ZMRIG_CGROUP_DIR: open }), null);
  assert.equal(cgroupCpus({ ZMRIG_CGROUP_DIR: path.join(open, 'missing') }), null);
});

test('an explicit thread count is respected, and warned about above the quota', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'cgroup-'));
  fs.writeFileSync(path.join(dir, 'cpu.max'), '200000 100000\n');

  const decision = plan([], { ...BASE, THREADS: '8', ZMRIG_CGROUP_DIR: dir }, { cpus: 16 });
  assert.ok(has(decision.argv, '-t', '8'), 'the operator typed 8');
  assert.match(decision.notes.join(' '), /more than the 2-CPU quota/);
});

test('a thread count that is not a number is refused', () => {
  assert.match(plan([], { ...BASE, THREADS: 'half' }).error, /THREADS=half/);
});

test('the API binds where a published port can reach it', () => {
  assert.ok(!has(args({}), '--http-port'), 'off unless asked for');
  const on = args({ API_PORT: '8080' });
  assert.ok(has(on, '--http-port', '8080', '--http-host', '0.0.0.0'));
  assert.ok(has(args({ API_PORT: '8080', API_TOKEN: 'secret' }), '--http-access-token', 'secret'));
  assert.ok(has(args({ API_PORT: '8080', API_HOST: '127.0.0.1' }), '--http-host', '127.0.0.1'));
  assert.match(plan([], { ...BASE, API_PORT: 'eighty' }).error, /API_PORT/);
});

test('colour is turned off when stdout is not a terminal', () => {
  assert.ok(has(args({}), '--no-color'));
  const tty = plan([], BASE, { cpus: 4, tty: true }).argv;
  assert.ok(!has(tty, '--no-color'));
});

test('EXTRA_ARGS is split, and never evaluated as a shell', () => {
  const argv = args({ EXTRA_ARGS: '--print-time 10 --verbose' });
  assert.ok(has(argv, '--print-time', '10'));
  assert.ok(has(argv, '--verbose'));

  // A semicolon inside EXTRA_ARGS stays inside one argument: the split is on
  // whitespace and the result is passed to spawn as an argv array, so there is
  // no shell to interpret it. The dangerous version of this shim would be
  // `exec $EXTRA_ARGS`.
  const quoted = args({ EXTRA_ARGS: '--ws-path /x; rm -rf /' });
  assert.ok(quoted.includes('/x;'), JSON.stringify(quoted));
  assert.ok(!quoted.includes(';'), 'the semicolon must not become its own argument either');
});

test('flags instead of the environment are passed through untouched', () => {
  const decision = plan(['-o', 'pool.example:3333', '-u', '4abc'], {});
  assert.equal(decision.command, 'mine');
  assert.equal(decision.passthrough, true);
  assert.deepEqual(decision.argv, ['-o', 'pool.example:3333', '-u', '4abc']);
});

test('the wallet check is a separate command and does not need a pool', () => {
  const decision = plan(['check'], { WALLET: BASE.WALLET });
  assert.deepEqual(decision.argv, ['--check-wallet', BASE.WALLET]);

  assert.match(plan(['check'], {}).error, /no wallet/);
  assert.deepEqual(plan(['check'], { WALLET: '4xyz' }).argv, ['--check-wallet', '4xyz']);
});

test('the pool job runs the pool from this image, with an optional config', () => {
  const plain = plan(['pool'], {});
  assert.equal(plain.command, 'pool');
  assert.match(plain.argv[0], /pool[\/\\]src[\/\\]index\.js$/);

  const configured = plan(['pool'], { POOL_CONFIG: '/etc/pool.json' });
  assert.deepEqual(configured.argv.slice(1), ['--config', '/etc/pool.json']);
});

test('anything else is executed as itself', () => {
  assert.equal(plan(['sh'], {}).bin, 'sh');
  assert.deepEqual(plan(['node', '-e', '1'], {}).argv, ['-e', '1']);
});

test('every variable the shim reads is in the documented list', () => {
  const source = fs.readFileSync(path.join(__dirname, '..', 'entry.js'), 'utf8');
  // envOf(env, 'NAME', ...) is the only way this file reads the environment, so
  // anything it asks for that is not in KNOWN_ENV is an undocumented setting.
  const used = new Set();
  for (const match of source.matchAll(/(?:envOf|boolOf|number)\(env, '([A-Z][A-Z0-9_]*)'/g)) used.add(match[1]);
  for (const name of used) {
    assert.ok(KNOWN_ENV.includes(name), `${name} is read but not listed in KNOWN_ENV (and so not in doc/DOCKER.md)`);
  }
});

// --- what the container cannot see ----------------------------------------
//
// The notes `args` prints are the answer to "why is this container slower than
// the host it runs on". They are computed from /proc/meminfo and the cgroup, so
// they are tested with those two things injected: a test host's page pool must
// not decide whether CI passes.
const { perfNotes } = require('../entry.js');

const MEMINFO = (free, size = 2048) =>
  `HugePages_Total:   ${free}\nHugePages_Free:    ${free}\nHugepagesize:      ${size} kB\n`;

test('a host with no reserved pages is reported, with the command that fixes it', () => {
  const notes = perfNotes({}, { meminfo: MEMINFO(0), hasMsr: true });
  assert.equal(notes.length, 1);
  assert.match(notes[0], /huge pages: none are reserved on the host/);
  assert.match(notes[0], /sysctl -w vm\.nr_hugepages=1168/);
});

test('a reserved pool in a container that may use it is silent', () => {
  const notes = perfNotes({}, { meminfo: MEMINFO(1168), hugetlbBytes: null, hasMsr: true });
  assert.deepEqual(notes, []);
});

test('a pool the container may not touch is reported, not praised', () => {
  const notes = perfNotes({}, { meminfo: MEMINFO(1168), hugetlbBytes: 0, hasMsr: true });
  assert.equal(notes.length, 1);
  assert.match(notes[0], /the host has 1168 free pages of 2 MiB but this container's hugetlb limit is 0/);
});

test('1 GiB pages are described in their own size, not as 512 MiB', () => {
  const notes = perfNotes({}, { meminfo: MEMINFO(0, 1048576), hasMsr: true });
  assert.match(notes[0], /4 KiB pages instead of 1024 MiB/);
});

test('the MSR preset is reported as unavailable, and not when it cannot apply', () => {
  const absent = perfNotes({}, { meminfo: MEMINFO(1168), hasMsr: false });
  assert.equal(absent.length, 1);
  assert.match(absent[0], /\/dev\/cpu\/0\/msr is not in this container/);

  // `--no-msr` and `safe` never open the device, so telling them about it is noise.
  assert.deepEqual(perfNotes({ MSR: 'off' }, { meminfo: MEMINFO(1168), hasMsr: false }), []);
  assert.deepEqual(perfNotes({ MODE: 'safe' }, { meminfo: MEMINFO(1168), hasMsr: false }), []);
});

test('both notes can appear at once, and neither repeats the thread-count note', () => {
  const notes = perfNotes({}, { meminfo: MEMINFO(0), hasMsr: false });
  assert.equal(notes.length, 2);
  assert.match(notes[0], /huge pages/);
  assert.match(notes[1], /msr:/);
});

test('a kernel without /proc/meminfo says nothing rather than guessing', () => {
  assert.deepEqual(perfNotes({}, { meminfo: '', hasMsr: false }), []);
});

test('the notes belong to `args`, so a restarting rig does not log advice', () => {
  const env = { ...BASE };
  const opts = { cpus: 4, tty: false, meminfo: MEMINFO(0), hasMsr: false };

  const mine = plan([], env, opts);
  assert.equal(mine.perf, undefined, 'mine must not carry the container notes');

  const listing = plan(['args'], env, opts);
  assert.equal(listing.perf.length, 2);
  // and the command line itself is unchanged by them
  assert.deepEqual(listing.argv, mine.argv);
});

// The memory ceiling is the single biggest thing a container can get wrong:
// with less than a dataset's worth of RAM the miner falls back to the 256 MB
// cache, which measured **10x slower** on the same cores (973 H/s against
// 99 H/s, 2 threads). It fails silently - the rig keeps hashing - so `args` has
// to say it, with the number that fixes it.

test('a container too small for the dataset is told what it costs', () => {
  const notes = perfNotes({}, { meminfo: MEMINFO(1168), hugetlbBytes: null, hasMsr: true, memoryLimitMb: 1024 });

  assert.equal(notes.length, 1);
  assert.match(notes[0], /limited to 1024 MB/);
  assert.match(notes[0], /10x slower/, 'the measured ratio, not a guess');
  assert.match(notes[0], /--memory=2560m/, 'the flag that fixes it, with the number');
});

test('a container with room for the dataset says nothing', () => {
  assert.deepEqual(
    perfNotes({}, { meminfo: MEMINFO(1168), hugetlbBytes: null, hasMsr: true, memoryLimitMb: 4096 }),
    [],
  );
  // 2560 MB is the threshold: at exactly that, the dataset fits.
  assert.deepEqual(
    perfNotes({}, { meminfo: MEMINFO(1168), hugetlbBytes: null, hasMsr: true, memoryLimitMb: 2560 }),
    [],
  );
});

test('MODE=light is not warned about, because it was asked for', () => {
  assert.deepEqual(
    perfNotes({ MODE: 'light' }, { meminfo: MEMINFO(1168), hugetlbBytes: null, hasMsr: true, memoryLimitMb: 512 }),
    [],
  );
});

test('an unlimited container is judged by the host, and a small host is reported', () => {
  const small = 'HugePages_Free: 1168\nHugepagesize: 2048 kB\nMemAvailable: 800000 kB\n';
  const notes = perfNotes({}, { meminfo: small, hugetlbBytes: null, hasMsr: true, memoryLimitMb: null });

  assert.equal(notes.length, 1);
  assert.match(notes[0], /781 MB is available/);
  assert.match(notes[0], /10x slower/);

  // A host with room is the normal case and must stay quiet.
  const big = 'HugePages_Free: 1168\nHugepagesize: 2048 kB\nMemAvailable: 8388608 kB\n';
  assert.deepEqual(perfNotes({}, { meminfo: big, hugetlbBytes: null, hasMsr: true, memoryLimitMb: null }), []);
});

// --- the dataset cache ------------------------------------------------------
//
// A pool that moves a rig between RandomX forks is the normal case on a
// multi-algorithm pool, and every move back used to cost a full 2 GiB rebuild:
// 16.5-20.3 s of zero hashrate on two cores, measured. The miner keeps the old
// dataset mapped by default and decides per switch whether the memory is there.
// The shim only gets to say "off" or "at most N MB" - it has no business
// deciding how much RAM the container can spare.
test('DATASET_CACHE=off is a real off switch, not a missing value', () => {
  const built = minerArgs({ ...BASE, DATASET_CACHE: 'off' });

  assert.ok(built.args.includes('--no-dataset-cache'));
  assert.ok(!built.args.includes('--dataset-cache'));
});

test('DATASET_CACHE=2048 caps the retained datasets', () => {
  const built = minerArgs({ ...BASE, DATASET_CACHE: '2048' });

  const at = built.args.indexOf('--dataset-cache');
  assert.ok(at !== -1);
  assert.equal(built.args[at + 1], '2048');
});

test('an unset DATASET_CACHE adds no flag at all, so the miner decides', () => {
  const built = minerArgs({ ...BASE });

  assert.ok(!built.args.includes('--dataset-cache'));
  assert.ok(!built.args.includes('--no-dataset-cache'));
});

test('DATASET_CACHE=auto is the same as unset', () => {
  const built = minerArgs({ ...BASE, DATASET_CACHE: 'auto' });

  assert.ok(!built.args.includes('--dataset-cache'));
  assert.ok(!built.args.includes('--no-dataset-cache'));
});

test('a DATASET_CACHE that is not a size is refused, with the two things that work', () => {
  const built = minerArgs({ ...BASE, DATASET_CACHE: 'lots' });

  assert.ok(built.error);
  assert.match(built.error, /DATASET_CACHE=lots/);
  assert.match(built.error, /DATASET_CACHE=0/);
});

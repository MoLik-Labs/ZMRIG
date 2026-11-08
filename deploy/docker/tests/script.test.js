'use strict';

// zmrig-docker-update, the host-side half.
//
// It talks to `docker` through $PATH, so a stub binary that answers the four
// commands it uses tests the script's decisions - check, apply only when there
// is something to apply, never recreate a container after a failed pull - on a
// machine with no daemon in it. The alternative is a test that only runs where
// Docker runs, which this repository has learned is a test that does not run.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const SCRIPT = path.join(__dirname, '..', 'zmrig-docker-update');

// A fake docker: records every call, and answers the two inspects the script
// makes. `CHECK_EXIT` is what the in-image checker "returns".
function fakeDocker({ checkExit = 0, pullExit = 0, upExit = 0, image = 'ghcr.io/molik-labs/zmrig:latest', version = '6.48.0' } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fake-docker-'));
  const log = path.join(dir, 'calls.log');

  fs.writeFileSync(path.join(dir, 'docker'), `#!/bin/sh
printf '%s\\n' "$*" >> ${JSON.stringify(log)}
case "$1" in
  inspect)
    case "$*" in
      *'{{.Config.Image}}'*) printf '%s\\n' ${JSON.stringify(image)} ;;
      *'{{range .Config.Env}}'*) printf 'PATH=/usr/bin\\nZMRIG_VERSION=${version}\\n' ;;
      *) exit 0 ;;
    esac
    ;;
  run)
    printf 'running    %s\\n' ${JSON.stringify(version)}
    printf 'available  %s\\n' ${JSON.stringify(version)}
    exit ${checkExit}
    ;;
  compose)
    case "$*" in
      *pull*) exit ${pullExit} ;;
      *up*) exit ${upExit} ;;
    esac
    exit 0
    ;;
esac
exit 0
`, { mode: 0o755 });

  return {
    dir,
    calls() {
      return fs.existsSync(log) ? fs.readFileSync(log, 'utf8').trim().split('\n').filter(Boolean) : [];
    },
  };
}

function run(fake, args, extraEnv = {}) {
  return spawnSync('sh', [SCRIPT, ...args], {
    cwd: fake.cwd || os.tmpdir(),
    env: { PATH: `${fake.dir}:/usr/bin:/bin`, ...extraEnv },
    encoding: 'utf8',
  });
}

test('the script is portable shell and parses under both sh and bash', () => {
  for (const shell of ['sh', 'bash']) {
    const result = spawnSync(shell, ['-n', SCRIPT], { encoding: 'utf8' });
    assert.equal(result.status, 0, `${shell}: ${result.stderr}`);
  }
});

test('--check asks the image, and passes its exit code through', () => {
  for (const [exit, expected] of [[0, 0], [3, 3], [2, 2]]) {
    const fake = fakeDocker({ checkExit: exit });
    const result = run(fake, ['--check']);
    assert.equal(result.status, expected, result.stderr);

    const calls = fake.calls();
    assert.ok(calls.some((call) => call.startsWith('inspect --format {{.Config.Image}}')), calls.join('\n'));
    // The checker runs from the image already on disk - a check that pulls is a
    // check that can fail on a slow link at 3am.
    const checker = calls.find((call) => call.startsWith('run --rm --entrypoint node'));
    assert.ok(checker, calls.join('\n'));
    assert.match(checker, /ZMRIG_VERSION=6\.48\.0/);
    assert.match(checker, /\/app\/deploy\/docker\/update\.js --check/);
  }
});

test('--apply with nothing new pulls nothing and says so', () => {
  const fake = fakeDocker({ checkExit: 0 });
  const result = run(fake, ['--apply', '--compose', '/tmp/compose.yaml']);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /is current/);

  const calls = fake.calls();
  assert.ok(!calls.some((call) => call.includes('compose')), 'a current image must not be pulled again');
});

test('--apply with an update pulls first, then recreates', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'compose-'));
  const compose = path.join(dir, 'compose.yaml');
  fs.writeFileSync(compose, 'services: {}\n');

  const fake = fakeDocker({ checkExit: 3 });
  const result = run(fake, ['--apply', '--compose', compose]);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /applied/);

  const calls = fake.calls().filter((call) => call.startsWith('compose'));
  assert.equal(calls.length, 2, calls.join('\n'));
  assert.match(calls[0], /^compose -f \S+ pull/);
  assert.match(calls[1], /^compose -f \S+ up --detach/);
});

test('a failed pull leaves the running container alone', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'compose-'));
  const compose = path.join(dir, 'compose.yaml');
  fs.writeFileSync(compose, 'services: {}\n');

  const fake = fakeDocker({ checkExit: 3, pullExit: 1 });
  const result = run(fake, ['--apply', '--compose', compose]);
  assert.equal(result.status, 2, 'the exit code has to be non-zero or a timer reports success');
  assert.match(result.stderr, /left alone/);
  assert.ok(!fake.calls().some((call) => call.startsWith('compose -f') && call.includes(' up ')), 'no recreate after a failed pull');
});

test('--apply without a compose file refuses instead of guessing the flags', () => {
  const fake = fakeDocker({ checkExit: 3 });
  fake.cwd = fs.mkdtempSync(path.join(os.tmpdir(), 'empty-'));
  const result = run(fake, ['--apply']);
  assert.equal(result.status, 2);
  assert.match(result.stderr, /no compose file/);
  assert.ok(!fake.calls().some((call) => call.startsWith('compose')), 'nothing was pulled');
});

test('an unknown option and a missing container are errors, not silence', () => {
  const fake = fakeDocker();
  assert.equal(run(fake, ['--reboot']).status, 2);

  // `docker inspect` fails for a name that does not exist; the script has to say
  // which name it looked for, because the default is a convention.
  const broken = fakeDocker();
  fs.writeFileSync(path.join(broken.dir, 'docker'), '#!/bin/sh\nexit 1\n', { mode: 0o755 });
  const result = run(broken, ['--check', '--container', 'nope']);
  assert.equal(result.status, 2);
  assert.match(result.stderr, /no container named nope/);
});

// The two files have to agree with the page: this is the drift that makes an
// automated update fail at 03:17 for one person and nowhere else.
test('the timer and the service install where the page says they do', () => {
  const unitDir = path.join(__dirname, '..');
  const service = fs.readFileSync(path.join(unitDir, 'zmrig-docker-update.service'), 'utf8');
  const timer = fs.readFileSync(path.join(unitDir, 'zmrig-docker-update.timer'), 'utf8');
  const doc = fs.readFileSync(path.join(__dirname, '..', '..', '..', 'doc', 'DOCKER.md'), 'utf8');

  const exec = /^ExecStart=(\S+)/m.exec(service);
  assert.ok(exec, 'the service has no ExecStart');
  assert.equal(path.basename(exec[1]), 'zmrig-docker-update');
  assert.ok(doc.includes(`install -m 0755 deploy/docker/zmrig-docker-update ${path.dirname(exec[1])}/`),
    `doc/DOCKER.md must install the script to ${path.dirname(exec[1])}/`);

  assert.match(service, /^SuccessExitStatus=2$/m, 'a registry blip must not mark the unit failed');
  assert.match(timer, /^OnCalendar=/m);
  assert.match(timer, /^Unit=zmrig-docker-update\.service$/m);

  // The compose file the unit points at has to be the one in this directory.
  const compose = /^Environment=COMPOSE=(\S+)/m.exec(service);
  assert.ok(compose);
  assert.ok(doc.includes(path.basename(compose[1])));
});

test('--help explains the exit codes', () => {
  const fake = fakeDocker();
  const result = run(fake, ['--help']);
  assert.equal(result.status, 0);
  assert.match(result.stdout, /--check/);
  assert.match(result.stdout, /--apply/);
});

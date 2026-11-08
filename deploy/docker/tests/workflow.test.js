'use strict';

// `.github/workflows/image.yml`, the part that decides what gets published.
//
// This is the only code in the repository whose failure mode is "the release
// published nothing and reported success". A `publish=false` string that is not
// `true` makes the `if:` on the push step skip the push, the job goes green, and
// the tag list on GHCR stays empty until somebody tries to pull it. That happened
// on the first draft of this file, so the tag decision is extracted from the
// workflow and run here for every event that can trigger it.
//
// No Docker and no GitHub: the step is shell, so it is run as shell with the
// `${{ }}` expressions substituted the way the runner substitutes them.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.join(__dirname, '..', '..', '..');
const WORKFLOW = path.join(ROOT, '.github', 'workflows', 'image.yml');

// A deliberately small reader: the workflow is a list of steps with indented
// `run: |` blocks, and pulling one block out by its `- name:` is enough. A YAML
// parser would need a dependency this repository does not have.
function stepScript(name) {
  const lines = fs.readFileSync(WORKFLOW, 'utf8').split('\n');
  const start = lines.findIndex((line) => line.trim() === `- name: ${name}`);
  assert.notEqual(start, -1, `no step called ${name} in image.yml`);

  const runAt = lines.findIndex((line, index) => index > start && line.trim() === 'run: |');
  assert.notEqual(runAt, -1, `${name} has no run block`);

  const indent = lines[runAt].length - lines[runAt].trimStart().length;
  const block = [];
  for (let index = runAt + 1; index < lines.length; index += 1) {
    const line = lines[index];
    if (line.trim() === '') {
      block.push('');
      continue;
    }
    const depth = line.length - line.trimStart().length;
    if (depth <= indent) break;
    block.push(line);
  }

  return block.join('\n').replace(/\n+$/, '') + '\n';
}

function run(script, substitutions, env = {}) {
  let body = script;
  for (const [expression, value] of Object.entries(substitutions).sort((a, b) => b[0].length - a[0].length)) {
    body = body.split(`\${{ ${expression} }}`).join(value);
  }

  const leftover = body.indexOf('${{');
  assert.equal(leftover, -1, `unsubstituted expression: ${body.slice(leftover, leftover + 60)}`);

  const output = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'gh-out-')), 'output');
  fs.writeFileSync(output, '');

  const result = spawnSync('bash', ['-e', '-c', body], {
    cwd: ROOT,
    encoding: 'utf8',
    env: { ...process.env, GITHUB_OUTPUT: output, ...env },
  });

  const values = {};
  for (const line of fs.readFileSync(output, 'utf8').split('\n')) {
    const match = /^([^=]+)=(.*)$/.exec(line);
    if (match) values[match[1]] = match[2];
  }

  return { status: result.status, stdout: result.stdout, stderr: result.stderr, values };
}

const named = run(stepScript('Name the image'), {}, {
  REGISTRY: 'ghcr.io',
  IMAGE: 'MoLik-Labs/ZMRIG',
  GITHUB_SHA: 'c0ffee11' + 'a'.repeat(32),
});

const NAMES = {
  'steps.name.outputs.image': named.values.image,
  'steps.name.outputs.version': named.values.version,
  'steps.name.outputs.short': named.values.short,
  'steps.name.outputs.head': named.values.short,
};

function tags(ref, event, { publish = '', extra = '' } = {}) {
  const result = run(stepScript('Decide the tags'), {
    ...NAMES,
    'inputs.tag': extra,
    'inputs.publish': publish,
    'github.event_name': event,
  }, { GITHUB_REF: ref });

  assert.equal(result.status, 0, result.stderr);
  return result.values;
}

test('the image name is lower case, because a registry tag cannot be anything else', () => {
  assert.equal(named.status, 0, named.stderr);
  assert.equal(named.values.image, 'ghcr.io/molik-labs/zmrig');
  assert.match(named.values.version, /^\d+\.\d+\.\d+$/);
  assert.equal(named.values.short, 'c0ffee11');
});

test('a release tag publishes the version, latest and edge', () => {
  const result = tags('refs/tags/v6.48.0', 'push');
  assert.equal(result.publish, 'true', 'a tag must publish: a skipped push is a silent release failure');

  const list = result.tags.split(' ');
  const version = named.values.version;
  assert.ok(list.includes(`ghcr.io/molik-labs/zmrig:${version}`), result.tags);
  assert.ok(list.includes('ghcr.io/molik-labs/zmrig:latest'));
  assert.ok(list.includes('ghcr.io/molik-labs/zmrig:edge'));
  // A minor-version alias, so `:6.48` is not a tag somebody has to guess at.
  assert.ok(list.includes(`ghcr.io/molik-labs/zmrig:${version.split('.').slice(0, 2).join('.')}`));
});

test('BETA moves edge and nothing else', () => {
  const result = tags('refs/heads/BETA', 'push');
  assert.equal(result.publish, 'true');
  assert.equal(result.tags, 'ghcr.io/molik-labs/zmrig:edge');
});

test('master publishes only a commit-addressed tag', () => {
  // `latest` from master would promise a version the master tree does not claim
  // (the version constant is bumped in BETA), and `edge` from master would point
  // at a tree older than BETA. So neither moves without a tag.
  const result = tags('refs/heads/master', 'push');
  assert.equal(result.publish, 'true');
  assert.equal(result.tags, `ghcr.io/molik-labs/zmrig:sha-${named.values.short}`);
});

test('an ordinary branch publishes a commit-addressed tag, never latest', () => {
  const result = tags('refs/heads/arena/whatever', 'push');
  assert.equal(result.publish, 'true');
  assert.equal(result.tags, `ghcr.io/molik-labs/zmrig:sha-${named.values.short}`);
  assert.ok(!result.tags.includes('latest'));
  assert.ok(!result.tags.includes('edge'));
});

test('a manual run publishes only when asked, and then really does', () => {
  const built = tags('refs/heads/BETA', 'workflow_dispatch', { publish: 'false' });
  assert.equal(built.publish, '', 'a build-only run must not push');

  const pushed = tags('refs/heads/BETA', 'workflow_dispatch', { publish: 'true' });
  assert.equal(pushed.publish, 'true', 'the string has to be exactly true or the if: skips the push');
  assert.equal(pushed.tags, 'ghcr.io/molik-labs/zmrig:edge');
});

test('an extra tag is added without displacing the policy', () => {
  const result = tags('refs/heads/BETA', 'workflow_dispatch', { publish: 'true', extra: 'nightly' });
  assert.equal(result.tags, 'ghcr.io/molik-labs/zmrig:edge ghcr.io/molik-labs/zmrig:nightly');
});

test('the documentation says what the workflow does', () => {
  const doc = fs.readFileSync(path.join(ROOT, 'doc', 'DOCKER.md'), 'utf8');
  const setup = fs.readFileSync(path.join(ROOT, 'doc', 'SETUP.md'), 'utf8');

  // `edge` is BETA. A page that says master moves it is a page that will be
  // believed by whoever wonders why the tag they pulled is two weeks old.
  assert.match(doc, /:edge/, 'doc/DOCKER.md must list the edge tag');
  assert.match(doc, /moves on a tag, never on a merge/, 'doc/DOCKER.md must say when latest moves');
  assert.match(doc, /the tip of BETA/, 'doc/DOCKER.md must say what edge is');
  assert.match(setup, /`v\*` tag/);
  assert.ok(!/edge` from `BETA`\/`master`/.test(setup), 'SETUP.md still says master publishes edge');
});

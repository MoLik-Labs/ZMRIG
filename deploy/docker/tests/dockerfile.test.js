'use strict';

// The Dockerfile, read like a compiler would read it.
//
// An image build is ten minutes and, when it fails, one line about a file that
// is "not found" without saying whether the path was misspelt or whether
// .dockerignore removed it. Both of those are decidable in a millisecond:
//
//   * every COPY source exists in the repository,
//   * no COPY source is excluded by .dockerignore (the trap: the file is in git,
//     the build cannot see it),
//   * every COPY --from names a stage that exists,
//   * every ${ARG} a RUN uses is declared,
//   * the entrypoint is a file that exists and the default command is one the
//     shim knows.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..', '..', '..');
const DOCKERFILE = path.join(__dirname, '..', 'Dockerfile');
const IGNORE = path.join(ROOT, '.dockerignore');

const text = fs.readFileSync(DOCKERFILE, 'utf8');

// Dockerfile logical lines: a trailing backslash joins, a `#` line does not.
function instructions(source) {
  const out = [];
  let buffer = '';
  for (const raw of source.split('\n')) {
    const line = raw.replace(/\s+$/, '');
    if (buffer === '' && (line === '' || line.startsWith('#'))) continue;
    if (line.endsWith('\\')) {
      buffer += line.slice(0, -1) + ' ';
      continue;
    }
    out.push((buffer + line).trim());
    buffer = '';
  }
  if (buffer.trim()) out.push(buffer.trim());
  return out;
}

function ignorePatterns() {
  return fs.readFileSync(IGNORE, 'utf8')
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith('#'));
}

// Docker's .dockerignore rules, the part that matters here: a pattern with no
// slash matches at any depth, a pattern with a slash is anchored at the root,
// and a `**` is any sequence. `!` re-includes, which no pattern here uses.
function ignored(file, patterns) {
  for (const pattern of patterns.filter((entry) => !entry.startsWith('!'))) {
    const anchored = pattern.includes('/');
    const body = pattern.replace(/^\//, '').replace(/\*\*/g, '.*').replace(/\*/g, '[^/]*');
    const expression = new RegExp(`^${body}$`);
    if (anchored) {
      if (expression.test(file)) return pattern;
    } else {
      const segments = file.split('/');
      if (segments.some((segment) => expression.test(segment))) return pattern;
    }
  }
  return null;
}

const lines = instructions(text);
const stages = new Set();
for (const line of lines) {
  const match = /^FROM\s+\S+(?:\s+AS\s+(\S+))?/i.exec(line);
  if (match && match[1]) stages.add(match[1].toLowerCase());
}

test('every COPY source exists, and .dockerignore does not hide it', () => {
  const patterns = ignorePatterns();
  let checked = 0;

  for (const line of lines) {
    if (!/^COPY\s/i.test(line)) continue;
    const from = /--from=(\S+)/i.exec(line);
    if (from) {
      assert.ok(stages.has(from[1].toLowerCase()), `COPY --from=${from[1]} names no stage (stages: ${[...stages].join(', ')})`);
      continue;
    }

    const rest = line.replace(/^COPY\s+/i, '').replace(/--\S+=\S+/g, '').trim().split(/\s+/);
    const sources = rest.slice(0, -1);
    assert.ok(sources.length, `COPY with no source: ${line}`);

    for (const source of sources) {
      assert.ok(!source.includes('*'), `the test cannot resolve a glob: ${source}`);
      const full = path.join(ROOT, source);
      assert.ok(fs.existsSync(full), `COPY ${source}: no such file in the repository`);

      const hit = ignored(source.replace(/^\.\//, ''), patterns);
      assert.equal(hit, null, `COPY ${source} is excluded by .dockerignore ("${hit}") - the file is in git and the build cannot see it`);
      checked += 1;
    }
  }

  assert.ok(checked >= 5, `only ${checked} COPY sources checked; the parser is probably not reading the file`);
});

test('every ARG a build step reads is declared', () => {
  const declared = new Set();
  for (const line of lines) {
    const match = /^ARG\s+([A-Z0-9_]+)/i.exec(line);
    if (match) declared.add(match[1]);
  }

  for (const line of lines) {
    if (!/^(RUN|COPY|ENV)\b/i.test(line)) continue;
    for (const match of line.matchAll(/\$\{([A-Z0-9_]+)\}/g)) {
      const name = match[1];
      // ENV defines its own names earlier or later in the file; an ARG has to be
      // declared before it is used, which is why a stage that forgets one builds
      // an image with an empty version label and no error.
      if (/^ENV\b/i.test(line) && new RegExp(`^ENV\\s+${name}=`, 'im').test(text)) continue;
      assert.ok(declared.has(name) || process.env[name] !== undefined, `${name} is used but never declared as ARG`);
    }
  }
});

test('the entrypoint exists and is executable by the image, not by this checkout', () => {
  const entry = /^ENTRYPOINT\s+\[(.*)\]$/im.exec(text);
  assert.ok(entry, 'the image has no ENTRYPOINT');

  const parts = JSON.parse(`[${entry[1]}]`);
  const shim = parts[parts.length - 1];
  assert.equal(path.basename(shim), 'zmrig-docker', 'the entrypoint should be the symlink the Dockerfile creates');

  // The symlink target is COPY'd from the repository.
  assert.match(text, /ln -s \/app\/deploy\/docker\/entry\.js \/usr\/local\/bin\/zmrig-docker/);
  assert.ok(fs.existsSync(path.join(ROOT, 'deploy', 'docker', 'entry.js')));

  const cmd = /^CMD\s+\[(.*)\]$/im.exec(text);
  assert.ok(cmd, 'the image has no default CMD');
  const [command] = JSON.parse(`[${cmd[1]}]`);
  const { plan } = require('../entry.js');
  const decision = plan([command], { WALLET: '4' + 'A'.repeat(94), POOL: 'p:1' });
  assert.equal(decision.command, 'mine', `CMD ${command} does not resolve to the miner`);
});

test('the version label is a build argument, not a hard-coded number', () => {
  // A label with a literal version is a label that goes stale, and the update
  // checker compares against it.
  assert.match(text, /ARG ZMRIG_VERSION=/);
  assert.match(text, /org\.opencontainers\.image\.version="\$\{ZMRIG_VERSION\}"/);
  // And the workflow has to pass the real one, from the source of truth.
  const workflow = fs.readFileSync(path.join(ROOT, '.github', 'workflows', 'image.yml'), 'utf8');
  assert.match(workflow, /sed -n 's\/\^pub const version/, 'the workflow must read the version out of zmrig/src/main.zig');
  assert.match(workflow, /--build-arg "ZMRIG_VERSION=\$version"/);
});

test('.dockerignore keeps the things a build needs and drops what it does not', () => {
  const patterns = ignorePatterns();
  // The four directories both Dockerfiles copy must survive.
  for (const needed of ['src', 'zmrig', 'lib', 'pool', 'deploy/docker/entry.js', 'deploy/docker/update.js']) {
    assert.equal(ignored(needed, patterns), null, `.dockerignore excludes ${needed}, which a build copies`);
  }
  // And the ones that cost minutes of upload must not.
  for (const dropped of ['.git', 'node_modules', 'site/node_modules', 'site/build', 'web']) {
    assert.ok(ignored(dropped, patterns), `.dockerignore should drop ${dropped}`);
  }
});

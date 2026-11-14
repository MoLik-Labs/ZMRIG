'use strict';

// The container's settings, against the page that documents them.
//
// The appliance has the same test for /etc/zmrig/os.conf (tests/docs/config-keys.sh)
// and it caught two keys that only existed in the binary. A container is worse,
// because there is no file to read: if an environment variable is not on the
// docs page, it does not exist for anyone who has not read the source.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const DOC = path.join(__dirname, '..', '..', '..', 'doc', 'DOCKER.md');
const ENTRY = path.join(__dirname, '..', 'entry.js');
const UPDATE = path.join(__dirname, '..', 'update.js');

// Rows of the form `| \`NAME\` | default | what it does |`. Prose mentions are
// not rows: a name that is only talked about is not a name that is documented
// as a setting.
function documentedNames(text) {
  const names = new Set();
  for (const line of text.split('\n')) {
    const match = /^\|\s*`([A-Z][A-Z0-9_]*)`\s*\|/.exec(line);
    if (match) names.add(match[1]);
  }
  return names;
}

function readNames(file) {
  const source = fs.readFileSync(file, 'utf8');
  const names = new Set();
  for (const match of source.matchAll(/(?:envOf|boolOf|number)\(env, '([A-Z][A-Z0-9_]*)'/g)) names.add(match[1]);
  for (const match of source.matchAll(/process\.env\.([A-Z][A-Z0-9_]*)/g)) names.add(match[1]);
  return names;
}

test('every setting the image reads is a row in doc/DOCKER.md', () => {
  const doc = fs.readFileSync(DOC, 'utf8');
  const documented = documentedNames(doc);

  for (const file of [ENTRY, UPDATE]) {
    for (const name of readNames(file)) {
      assert.ok(documented.has(name), `${path.basename(file)} reads ${name} and doc/DOCKER.md does not document it`);
    }
  }
});

test('every row in doc/DOCKER.md is a setting the image reads', () => {
  const documented = documentedNames(fs.readFileSync(DOC, 'utf8'));
  const read = new Set([...readNames(ENTRY), ...readNames(UPDATE)]);

  for (const name of documented) {
    assert.ok(read.has(name), `doc/DOCKER.md documents ${name} and nothing reads it`);
  }
});

test('the defaults on the page are the defaults in the code', () => {
  const doc = fs.readFileSync(DOC, 'utf8');
  const { DEFAULTS } = require('../entry.js');
  const { DEFAULTS: UPDATE_DEFAULTS } = require('../update.js');

  const rows = new Map();
  for (const line of doc.split('\n')) {
    const match = /^\|\s*`([A-Z][A-Z0-9_]*)`\s*\|\s*([^|]*?)\s*\|/.exec(line);
    if (match) rows.set(match[1], match[2].replace(/`/g, '').trim());
  }

  const expected = { ...DEFAULTS, ...UPDATE_DEFAULTS };
  for (const [name, value] of Object.entries(expected)) {
    const documented = rows.get(name);
    if (documented === undefined) continue; // covered by the test above

    // Some rows document a computed default in prose ("0.0.0.0 when API_PORT is
    // set", "built in"); those are checked by the test that follows this one.
    if (!/^[a-z0-9.]+$/i.test(documented)) continue;
    assert.equal(documented, value, `${name}: doc/DOCKER.md says "${documented}", the code says "${value}"`);
  }
});

test('the fee the page quotes is the fee the image passes', () => {
  const doc = fs.readFileSync(DOC, 'utf8');
  const { minerArgs } = require('../entry.js');

  // The default in the code, the default on the page and the default in the
  // binary are three places. `scripts/verify-fee.sh` owns the third.
  const argv = minerArgs({ WALLET: '4' + 'A'.repeat(94), POOL: 'p:1' }).args;
  const index = argv.indexOf('--donate-level');
  assert.ok(index > 0, 'the shim must pass the fee explicitly');
  const fee = argv[index + 1];

  const row = /\|\s*`DONATE`\s*\|[^|]*\|/.exec(doc);
  assert.ok(row, 'DONATE has no row in doc/DOCKER.md');
  assert.match(doc, new RegExp(`\\|\\s*\`DONATE\`\\s*\\|\\s*\`${fee}\``), `the page's DONATE default is not ${fee}`);
});

test('the modes the page lists are the modes the shim accepts', () => {
  const doc = fs.readFileSync(DOC, 'utf8');
  const { minerArgs } = require('../entry.js');
  const base = { WALLET: '4' + 'A'.repeat(94), POOL: 'p:1' };

  for (const mode of ['max', 'eco', 'safe', 'light']) {
    assert.doesNotThrow(() => assert.ok(minerArgs({ ...base, MODE: mode }).args), mode);
    // The row is written as `max`, `eco`, `safe`, `light`; a mode nobody
    // documented is a mode nobody can find.
    assert.match(doc, new RegExp('`' + mode + '`'), `MODE=${mode} is not mentioned on the page`);
  }
});

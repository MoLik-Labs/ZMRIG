// The version the fleet prints must be the version that was released.
//
// This is a drift test, not a formatting test: the dashboard footer said 6.44.0
// and the Discord user agent 6.37 while the release was 6.48, so the assertion
// that matters is "one number, and it is the repository's".

'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const { VERSION, read } = require('../src/version');
const ROOT = path.join(__dirname, '..', '..');

test('the version comes from package.json, not from a constant', () => {
  const released = JSON.parse(fs.readFileSync(path.join(ROOT, 'package.json'), 'utf8')).version;
  assert.equal(VERSION, released);
  assert.equal(read(), released);
});

test('nothing in fleet/src spells out a version of its own', () => {
  const stray = [];
  for (const file of walk(path.join(ROOT, 'fleet', 'src'))) {
    if (file.endsWith(path.join('src', 'version.js'))) continue;
    const text = fs.readFileSync(file, 'utf8');
    // A literal like 6.44.0 in code; changelog prose and comments in the docs
    // are not this file's business.
    for (const match of text.matchAll(/['"`]\s*\d+\.\d+\.\d+\s*['"`]/g)) {
      stray.push(`${path.relative(ROOT, file)}: ${match[0]}`);
    }
  }

  assert.deepEqual(stray, []);
});

test('the dashboard and the Discord client print the same version', () => {
  const layout = require('../src/web/layout');
  assert.equal(layout.VERSION, VERSION);
});

function walk(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walk(full));
    else if (entry.name.endsWith('.js')) out.push(full);
  }

  return out;
}

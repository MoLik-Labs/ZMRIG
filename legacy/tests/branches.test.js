// Branch names are load-bearing here: the one-line installer, the site's command
// builder and every documentation link point at a branch by name. The project
// used to point them at a short-lived session branch, and the failure was silent
// — `oneclick.sh update` fetched nothing, checked out nothing and still printed
// a commit hash, while the published one-liner returned 404.
//
// This test pins the rule: install paths may only use the three long-lived
// branches, and the default must be BETA (the default branch on GitHub).
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..', '..');
const LONG_LIVED = new Set(['ALPHA', 'BETA', 'master']);

// Files that carry a clone URL, a raw URL or a script default.
const CARRIERS = [
  'README.md',
  'oneclick.sh',
  'doc/INSTALL.md',
  'doc/SETUP.md',
  'legacy/index.html',
  'legacy/assets/command.js',
  'legacy/assets/builder.js',
  'legacy/content/vi/gioi-thieu.md',
];

function read(file) {
  return fs.readFileSync(path.join(ROOT, file), 'utf8');
}

// Every branch name that appears in a URL for this repository.
function branchesInUrls(text) {
  const found = new Set();
  const patterns = [
    /raw\.githubusercontent\.com\/NggKhaiz\/ZMRIG\/([^/\s"'`]+)/g,
    /github\.com\/NggKhaiz\/ZMRIG\/(?:blob|tree|raw)\/([^/\s"'`]+)/g,
  ];

  for (const pattern of patterns) {
    let match;
    while ((match = pattern.exec(text)) !== null) found.add(match[1]);
  }

  return found;
}

test('every branch named in a repository URL is a long-lived one', () => {
  for (const file of CARRIERS) {
    const branches = branchesInUrls(read(file));

    for (const branch of branches) {
      assert.ok(
        LONG_LIVED.has(branch),
        `${file} points at "${branch}", which is not one of ALPHA/BETA/master`,
      );
    }
  }
});

test('the published one-liner installs from BETA', () => {
  // The owner is deliberately not written down here: the repository moved once,
  // and the copy broke everywhere it was spelled out. tests/docs/identity.sh
  // holds the owner to the git remote; this test holds the two copies to each
  // other, and both to BETA.
  const pattern =
    /https:\/\/raw\.githubusercontent\.com\/[^/\s]+\/ZMRIG\/BETA\/oneclick\.sh/;

  const readme = read('README.md').match(pattern);
  assert.ok(readme, 'README one-liner installs from BETA');

  // The URL lives in command.js too, because the wizard and the quick builder
  // both build their commands there. One branch, one URL.
  const builder = read('legacy/assets/command.js').match(pattern);
  assert.ok(builder, 'the site builder installs from BETA');

  assert.equal(
    builder[0],
    readme[0],
    'the site builder uses the same URL as the README',
  );
});

test('oneclick.sh defaults to BETA and can be overridden', () => {
  const script = read('oneclick.sh');

  assert.match(
    script,
    /REPO_BRANCH="\$\{MINER_BRANCH:-BETA\}"/,
    'the installer default is BETA, overridable with MINER_BRANCH',
  );
  assert.ok(!/MINER_BRANCH:-arena/.test(script), 'no session branch is the default');
});

test('no session branch name survives anywhere in the tree', () => {
  // An arena/ or agent/ branch is created per session and deleted afterwards,
  // so a reference to one is always a bug waiting to 404.
  const skip = new Set(['node_modules', '.git', 'build', 'out']);
  const offenders = [];

  function walk(dir) {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      if (skip.has(entry.name)) continue;

      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        walk(full);
        continue;
      }
      if (!/\.(md|sh|js|html|json|ya?ml|txt|toml)$/.test(entry.name)) continue;

      const text = fs.readFileSync(full, 'utf8');
      if (/\b(?:arena|agent)\/[0-9a-z-]+-xmrig-ocean\b/.test(text)) {
        offenders.push(path.relative(ROOT, full));
      }
    }
  }

  walk(ROOT);

  // doc/SETUP.md is allowed to name the pattern in prose, as the rule itself.
  assert.deepStrictEqual(
    offenders.filter((file) => file !== path.join('doc', 'SETUP.md')),
    [],
  );
});

// A miniature build of the site: the shapes `assets.load` has to understand,
// without asking a test to run Docusaurus first.

'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const FILES = {
  'index.html': '<!doctype html><html lang="en"><head><title>ZMRIG</title><link rel="stylesheet" href="/assets/css/main.abc123.css"></head><body><h1>ZMRIG</h1></body></html>',
  '404.html': '<!doctype html><html lang="en"><body><h1>Page not found</h1></body></html>',
  'docs/index.html': '<!doctype html><html lang="en"><body><h1>Documentation</h1></body></html>',
  'guide/index.html': '<!doctype html><html lang="en"><body><h1>The guide</h1></body></html>',
  'docs/intro.html': '<!doctype html><html lang="en"><body><h1>Introduction</h1></body></html>',
  'docs/fleet/dashboard.html': '<!doctype html><html lang="en"><body><h1>The browser dashboard</h1></body></html>',
  'vi/docs/intro.html': '<!doctype html><html lang="vi"><body><h1>Giới thiệu</h1></body></html>',
  'assets/css/main.abc123.css': `:root{--x:1}${'/* padding */'.repeat(200)}`,
  'assets/js/main.def456.js': `(function(){${'var a=1;'.repeat(200)}})();`,
  'img/logo.svg': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><path d="M4 5h24v5z"/></svg>',
  'search-index.json': JSON.stringify({ docs: [{ t: 'Introduction', u: '/docs/intro' }] }),
  'sitemap.xml': '<?xml version="1.0"?><urlset><url><loc>https://example.test/</loc></url></urlset>',
  'robots.txt': 'User-agent: *\nAllow: /\n',
  'notes.txt': 'small\n',
};

function makeSite(overrides = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zmrig-site-'));
  const files = { ...FILES, ...overrides };
  for (const [name, body] of Object.entries(files)) {
    // `undefined` deletes a fixture file: a build without docs/index.html is a
    // shape the server has to handle, and the only way to produce one.
    if (body === undefined) continue;
    const full = path.join(root, name);
    fs.mkdirSync(path.dirname(full), { recursive: true });
    fs.writeFileSync(full, body);
  }
  return root;
}

function removeSite(root) {
  fs.rmSync(root, { recursive: true, force: true });
}

function fakeReleases(data) {
  return {
    calls: 0,
    latest() {
      this.calls += 1;
      return Promise.resolve(data);
    },
  };
}

const STABLE = {
  tag: 'v6.38.0',
  name: 'ZMRIG OS 6.38.0',
  prerelease: false,
  published_at: new Date('2026-10-30T10:00:00Z').toISOString(),
  assets: [
    {
      name: 'zmrig-os-6.38.0-x86-64-v3.iso',
      size: 165_000_000,
      downloads: 41,
      url: 'https://github.com/MoLik-Labs/ZMRIG/releases/download/v6.38.0/zmrig-os-6.38.0-x86-64-v3.iso',
      sha256: 'a'.repeat(64),
    },
    {
      name: 'zmrig-os-6.38.0-x86-64-v3.iso.sha256',
      size: 96,
      downloads: 3,
      url: 'https://github.com/MoLik-Labs/ZMRIG/releases/download/v6.38.0/zmrig-os-6.38.0-x86-64-v3.iso.sha256',
      sha256: null,
    },
    {
      name: 'zmrig-os-6.38.0-x86-64-v2.iso',
      size: 160_500_000,
      downloads: 12,
      url: 'https://github.com/MoLik-Labs/ZMRIG/releases/download/v6.38.0/zmrig-os-6.38.0-x86-64-v2.iso',
      sha256: 'b'.repeat(64),
    },
  ],
};

const BETA = {
  tag: 'os-beta',
  name: 'ZMRIG OS (rolling beta)',
  prerelease: true,
  published_at: new Date('2026-11-01T09:00:00Z').toISOString(),
  assets: [
    {
      name: 'zmrig-os-6.39.0-x86-64-v3.iso',
      size: 166_000_000,
      downloads: 7,
      url: 'https://github.com/MoLik-Labs/ZMRIG/releases/download/os-beta/zmrig-os-6.39.0-x86-64-v3.iso',
      sha256: 'c'.repeat(64),
    },
  ],
};

const EMPTY = { stable: null, beta: null, fetchedAt: Date.now(), error: null };

function data(overrides = {}) {
  return { stable: STABLE, beta: BETA, fetchedAt: 1_700_000_000_000, error: null, ...overrides };
}

module.exports = { makeSite, removeSite, fakeReleases, data, STABLE, BETA, EMPTY, FILES };

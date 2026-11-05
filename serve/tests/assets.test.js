'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const assets = require('../src/assets');
const { makeSite, removeSite } = require('./fixture');

test('the file table answers both spellings of a page', () => {
  const root = makeSite();
  try {
    const table = assets.load(root);

    assert.ok(table.files.get('/'), 'index is at /');
    assert.equal(table.files.get('/').type, 'text/html; charset=utf-8');
    assert.ok(table.files.get('/docs/intro'), 'extensionless page resolves');
    assert.ok(table.files.get('/docs/intro.html'), 'the file name resolves too');
    assert.equal(table.files.get('/docs/intro'), table.files.get('/docs/intro.html'));
    assert.ok(table.files.get('/vi/docs/intro'), 'a second locale is just another path');
    assert.ok(table.files.get('/docs/fleet/dashboard'), 'nested pages resolve');
    assert.equal(table.files.get('/404.html'), undefined, '404 is not a route');
    assert.ok(table.notFound, '404 is kept separately');
  } finally {
    removeSite(root);
  }
});

test('cache policy separates fingerprinted assets from pages', () => {
  const root = makeSite();
  try {
    const table = assets.load(root);
    assert.match(table.files.get('/assets/js/main.def456.js').cache, /immutable/);
    assert.match(table.files.get('/assets/css/main.abc123.css').cache, /max-age=31536000/);
    assert.match(table.files.get('/docs/intro').cache, /must-revalidate/);
    assert.match(table.files.get('/img/logo.svg').cache, /max-age=604800/);
    assert.match(table.files.get('/sitemap.xml').cache, /max-age=3600/);
  } finally {
    removeSite(root);
  }
});

test('text is compressed when it is first asked for, and small files are left alone', () => {
  const root = makeSite();
  try {
    const table = assets.load(root);
    const css = table.files.get('/assets/css/main.abc123.css');

    // Loading the table is cheap on purpose: a free instance is 0.1 CPU, and
    // compressing the whole site at boot is what made a cold start take minutes.
    assert.equal(css.br, null, 'nothing is compressed at boot');
    assert.equal(css.gz, null);
    assert.equal(table.packedCount, 0, 'so no compressed copy exists yet');
    assert.ok(table.packed <= table.raw, 'and the table holds only the files themselves');

    // A browser asks for brotli: one copy is made, and only that one.
    const chosen = assets.pick(css, 'gzip, deflate, br');
    assert.equal(chosen.encoding, 'br');
    assert.ok(chosen.body.length < css.body.length, 'brotli is smaller than the original');
    assert.ok(css.br, 'the copy is kept');
    assert.equal(css.gz, null, 'and the gzip copy the client never asked for is not made');
    assert.equal(table.packedCount, 1, 'exactly the file that was asked for');

    // Second visitor, same bytes: no work at all.
    const again = Date.now();
    assert.strictEqual(assets.pick(css, 'gzip, deflate, br').body, css.br);
    assert.ok(Date.now() - again < 50);

    // A client that can only take gzip gets gzip, made on demand.
    assert.equal(assets.pick(css, 'gzip').encoding, 'gzip');
    assert.ok(css.gz);

    assert.ok(table.files.get('/notes.txt').br === null, 'a 6-byte file is not worth compressing');
    assert.equal(assets.pick(table.files.get('/notes.txt'), 'gzip, deflate, br').encoding, null);
    assert.ok(table.files.get('/img/logo.svg').body.length > 0);
    assert.equal(assets.pick(table.files.get('/img/logo.svg'), 'br').encoding, null, 'an image is already compressed');
    assert.equal(assets.pick(table.files.get('/docs/intro'), 'br').encoding, null, 'a 90-byte page is not compressed either');
  } finally {
    removeSite(root);
  }
});

test('the compression level follows the size of the file', () => {
  // The ratio of brotli's cost to its gain flattens out; a 300 KB bundle at
  // quality 11 is seconds of one visitor's afternoon and a few percent.
  assert.equal(assets.quality(4 * 1024), 11);
  assert.equal(assets.quality(32 * 1024), 11);
  assert.equal(assets.quality(33 * 1024), 9);
  assert.equal(assets.quality(256 * 1024), 9);
  assert.equal(assets.quality(1024 * 1024), 6);
});

test('a sidecar written at build time is used instead of compressing again', () => {
  const root = makeSite();
  try {
    const file = path.join(root, 'assets/js/main.def456.js');
    fs.writeFileSync(`${file}.br`, Buffer.from('sidecar-brotli'));
    fs.writeFileSync(`${file}.gz`, Buffer.from('sidecar-gzip'));
    const table = assets.load(root);
    const entry = table.files.get('/assets/js/main.def456.js');
    assets.pack(entry, 'br');
    assets.pack(entry, 'gzip');
    assert.equal(entry.br.toString(), 'sidecar-brotli');
    assert.equal(entry.gz.toString(), 'sidecar-gzip');
    assert.equal(table.files.get('/assets/js/main.def456.js.br'), undefined, 'sidecars are not routes');
  } finally {
    removeSite(root);
  }
});

test('content negotiation picks the smallest representation the client accepts', () => {
  const entry = { body: Buffer.from('raw'), br: Buffer.from('b'), gz: Buffer.from('g') };

  assert.equal(assets.pick(entry, 'gzip, deflate, br').encoding, 'br');
  assert.equal(assets.pick(entry, 'gzip, deflate').encoding, 'gzip');
  assert.equal(assets.pick(entry, undefined).encoding, null);
  assert.equal(assets.pick(entry, 'identity').encoding, null);
  // A client that asked only for brotli does not get gzip it never said it
  // could read; it gets the bytes.
  assert.equal(assets.pick({ body: entry.body, br: null, gz: entry.gz }, 'br').encoding, null);
  assert.equal(assets.pick({ body: entry.body, br: null, gz: entry.gz }, 'br, gzip').encoding, 'gzip');
  assert.equal(assets.pick({ body: entry.body, br: null, gz: null }, 'br').encoding, null);

  // A wildcard means "anything you have", not "nothing".
  assert.equal(assets.pick(entry, '*').encoding, 'br');
});

test('an etag changes when the file changes and not before', () => {
  const root = makeSite();
  try {
    const first = assets.load(root).files.get('/docs/intro').etag;
    const second = assets.load(root).files.get('/docs/intro').etag;
    assert.equal(first, second);

    const file = path.join(root, 'docs/intro.html');
    fs.appendFileSync(file, ' ');
    fs.utimesSync(file, new Date(), new Date(Date.now() + 5000));
    const third = assets.load(root).files.get('/docs/intro').etag;
    assert.notEqual(first, third);
  } finally {
    removeSite(root);
  }
});

test('the table refuses to walk out of its root', () => {
  const root = makeSite();
  try {
    const table = assets.load(root);
    for (const attempt of ['/../package.json', '/docs/../../etc/passwd', '/%2e%2e/%2e%2e/etc/passwd']) {
      assert.equal(table.files.get(attempt), undefined, `${attempt} is not a route`);
    }
  } finally {
    removeSite(root);
  }
});

test('a precompressed copy older than its page is not served', () => {
  const root = makeSite();
  try {
    const css = path.join(root, 'assets/css/main.abc123.css');
    // A sidecar from a previous build: correct brotli, wrong content.
    const stale = require('node:zlib').brotliCompressSync(Buffer.from('/* the previous build */'));
    fs.writeFileSync(`${css}.br`, stale);
    const old = new Date('2020-01-01T00:00:00Z');
    fs.utimesSync(`${css}.br`, old, old);
    fs.utimesSync(css, new Date('2026-01-01T00:00:00Z'), new Date('2026-01-01T00:00:00Z'));

    const table = assets.load(root);
    const entry = table.files.get('/assets/css/main.abc123.css');
    assets.pack(entry, 'br');
    assert.notEqual(entry.br, stale, 'the stale sidecar is ignored');
    assert.ok(entry.br.length > stale.length, 'a fresh copy was made from the file itself');
    assert.equal(require('node:zlib').brotliDecompressSync(entry.br).toString(), entry.body.toString());

    // The same sidecar, newer than the page, is used as-is: that is the point
    // of shipping them, and it is what makes a deploy skip the compression.
    fs.writeFileSync(css, entry.body);
    fs.utimesSync(css, new Date('2020-01-01T00:00:00Z'), new Date('2020-01-01T00:00:00Z'));
    fs.writeFileSync(`${css}.br`, entry.br);
    const reloaded = assets.load(root).files.get('/assets/css/main.abc123.css');
    assets.pack(reloaded, 'br');
    assert.deepEqual(reloaded.br, entry.br);
  } finally {
    removeSite(root);
  }
});

test('q=0 is a refusal, not a preference', () => {
  const root = makeSite();
  try {
    const entry = assets.load(root).files.get('/assets/css/main.abc123.css');

    assert.equal(assets.pick(entry, 'gzip;q=0, identity').encoding, null);
    assert.equal(assets.pick(entry, 'br;q=0, gzip').encoding, 'gzip');
    assert.equal(assets.pick(entry, 'br;q=0.4, gzip;q=0.9').encoding, 'br', 'brotli is preferred when acceptable at all');
    assert.equal(assets.pick(entry, 'gzip;q=0.5').encoding, 'gzip');
    assert.equal(assets.pick(entry, '*').encoding, 'br');
    assert.equal(assets.pick(entry, '').encoding, null);
    assert.equal(assets.pick(entry, 'deflate').encoding, null);

    // Nothing acceptable at all: send the compressed body rather than an empty
    // 406 - the client can almost certainly still decode it.
    assert.equal(assets.pick(entry, 'identity;q=0').encoding, 'br');
    assert.equal(assets.identityAllowed('identity;q=0'), false);
    assert.equal(assets.identityAllowed('*;q=0'), false);
    assert.equal(assets.identityAllowed('gzip'), true);
  } finally {
    removeSite(root);
  }
});

test('a build made for a subdirectory is rebased to the root', () => {
  // The committed `web/` is the GitHub Pages build: every internal reference is
  // written `/ZMRIG/...`. Served from a host's root it was a page with no
  // stylesheet and no navigation, and nothing failed loudly.
  const root = makeSite({
    'index.html': '<!doctype html><html lang="en"><head><link rel="stylesheet" href="/ZMRIG/assets/css/main.abc123.css"><link rel="canonical" href="https://molik-labs.github.io/ZMRIG/"><meta property="og:image" content="https://molik-labs.github.io/ZMRIG/img/og-en.png"></head><body><a href="/ZMRIG/docs/intro">Intro</a><script src="/ZMRIG/assets/js/main.def456.js"></script>' + '<!-- ' + 'x'.repeat(1200) + ' --></body></html>',
    'docs/intro.html': '<!doctype html><html lang="en"><body><a href="/ZMRIG/docs/intro">self</a></body></html>',
    'search-index.json': JSON.stringify({ docs: [{ t: 'Introduction', u: '/ZMRIG/docs/intro' }] }),
  });
  try {
    const table = assets.load(root);
    assert.equal(assets.rebase(table), '/ZMRIG', 'the prefix is detected from the build itself');

    const home = table.files.get('/').body.toString();
    assert.match(home, /href="\/assets\/css\/main\.abc123\.css"/);
    assert.match(home, /href="\/docs\/intro"/);
    assert.ok(!/["'(]\/ZMRIG\//.test(home), 'no root-relative prefixed reference is left');
    // An absolute URL into GitHub Pages is a canonical link, not a route: it
    // must survive untouched or the two hosts disagree about what the page is.
    assert.match(home, /rel="canonical" href="https:\/\/molik-labs\.github\.io\/ZMRIG\/"/);
    assert.match(home, /content="https:\/\/molik-labs\.github\.io\/ZMRIG\/img\/og-en\.png"/);

    // Search results too, or the local index links into a 404.
    assert.match(table.files.get('/search-index.json').body.toString(), /"u":"\/docs\/intro"/);

    // A rebased body is not the file on disk, so the file's sidecar is not its
    // compressed form any more.
    const entry = table.files.get('/');
    assert.equal(entry.rebased, true);
    assert.match(entry.etag, /-r[0-9a-f]+"$/, 'the ETag marks bytes that came from a rewrite');

    // The sidecar on disk still holds the pre-rewrite HTML, so packing must not
    // use it: the page would carry `/ZMRIG/` links under an ETag for the page
    // that does not.
    require('node:fs').writeFileSync(require('node:path').join(root, 'index.html.br'),
      require('node:zlib').brotliCompressSync(Buffer.from('<!doctype html><html><head><link href="/ZMRIG/assets/css/main.abc123.css"></head></html>')));
    const packed = assets.load(root);
    assets.rebase(packed);
    const packedHome = packed.files.get('/');
    assets.pack(packedHome, 'br');
    const decoded = require('node:zlib').brotliDecompressSync(packedHome.br).toString();
    assert.match(decoded, /href="\/assets\/css\/main\.abc123\.css"/, 'compressed from the rebased body');

    // A build that already targets the root is left alone.
    const plain = makeSite();
    try {
      assert.equal(assets.rebase(assets.load(plain)), '', 'nothing to do');
    } finally {
      removeSite(plain);
    }
  } finally {
    removeSite(root);
  }
});

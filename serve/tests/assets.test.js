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

test('text is compressed once, at load, and small files are left alone', () => {
  const root = makeSite();
  try {
    const table = assets.load(root);
    const css = table.files.get('/assets/css/main.abc123.css');
    assert.ok(css.br && css.gz, 'a 2 KB stylesheet gets both copies');
    assert.ok(css.br.length < css.body.length, 'brotli is smaller than the original');
    assert.ok(table.files.get('/notes.txt').br === null, 'a 6-byte file is not worth compressing');
    assert.ok(table.files.get('/img/logo.svg').body.length > 0);
    assert.equal(table.files.get('/img/logo.svg').gz, null, 'an image is already compressed');

    // The same bytes every run: the sidecar files are what a deploy ships.
    assert.equal(table.files.get('/docs/intro').br, null, 'a 90-byte page is not compressed either');
  } finally {
    removeSite(root);
  }
});

test('a sidecar written at build time is used instead of compressing again', () => {
  const root = makeSite();
  try {
    const file = path.join(root, 'assets/js/main.def456.js');
    fs.writeFileSync(`${file}.br`, Buffer.from('sidecar-brotli'));
    fs.writeFileSync(`${file}.gz`, Buffer.from('sidecar-gzip'));
    const table = assets.load(root);
    const entry = table.files.get('/assets/js/main.def456.js');
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
    assert.notEqual(entry.br, stale, 'the stale sidecar is ignored');
    assert.ok(entry.br.length > stale.length, 'a fresh copy was made from the file itself');
    assert.equal(require('node:zlib').brotliDecompressSync(entry.br).toString(), entry.body.toString());

    // The same sidecar, newer than the page, is used as-is: that is the point
    // of shipping them, and it is what makes a deploy skip the compression.
    fs.writeFileSync(css, entry.body);
    fs.utimesSync(css, new Date('2020-01-01T00:00:00Z'), new Date('2020-01-01T00:00:00Z'));
    fs.writeFileSync(`${css}.br`, entry.br);
    const reloaded = assets.load(root).files.get('/assets/css/main.abc123.css');
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

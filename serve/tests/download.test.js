'use strict';

const test = require('node:test');
const assert = require('node:assert');

const download = require('../src/download');
const { data, STABLE, BETA } = require('./fixture');

test('the page lists both channels with sizes and checksums', () => {
  const html = download.page({ data: data(), now: Date.parse('2026-11-02T00:00:00Z'), host: 'https://zmrig.example.com' });

  assert.match(html, /Download ZMRIG OS/);
  assert.match(html, /Stable/);
  assert.match(html, /Beta/);
  assert.match(html, /v6\.38\.0/);
  assert.match(html, /os-beta/);

  for (const asset of STABLE.assets.filter((a) => a.name.endsWith('.iso'))) {
    assert.ok(html.includes(asset.url), `${asset.name} has a link`);
    assert.ok(html.includes(asset.name));
  }
  assert.ok(html.includes('157.4 MB'), 'the v3 image is printed in MB with one decimal');
  assert.ok(html.includes('a'.repeat(64)), 'the checksum travels with the image');
  assert.ok(html.includes('https://zmrig.example.com/iso/v3'), 'the permanent links are on the page');
  assert.ok(html.includes('sha256sum -c'), 'verification is one copy-paste away');
  assert.ok(html.includes('dd if=zmrig-os-*.iso'), 'so is writing the stick');
});

test('v3 is offered before v2', () => {
  const html = download.page({ data: data(), now: Date.now() });
  const v3 = html.indexOf('x86-64-v3.iso');
  const v2 = html.indexOf('x86-64-v2.iso');
  assert.ok(v3 > 0 && v2 > v3, 'the newer instruction level comes first');
});

test('an empty feed still produces a usable page', () => {
  const html = download.page({ data: { stable: null, beta: null, fetchedAt: 1, error: null }, now: Date.now() });
  assert.match(html, /No image has been published/);
  assert.match(html, /github\.com\/MoLik-Labs\/ZMRIG\/releases/);
});

test('a GitHub outage is explained, not hidden', () => {
  const html = download.page({
    data: { stable: STABLE, beta: null, fetchedAt: 1, error: 'could not reach GitHub (offline); showing the last copy' },
    now: Date.now(),
  });
  assert.match(html, /could not reach GitHub/);
  assert.ok(html.includes(STABLE.assets[0].url), 'the last known links survive the outage');
});

test('every value that comes from GitHub is escaped', () => {
  const nasty = {
    stable: {
      tag: '<script>alert(1)</script>',
      name: 'x',
      prerelease: false,
      published_at: new Date().toISOString(),
      assets: [
        {
          name: 'zmrig-os-<img src=x onerror=alert(1)>.iso',
          size: 1,
          downloads: 0,
          url: 'javascript:alert(1)',
          sha256: '"><b>',
        },
      ],
    },
    beta: null,
    fetchedAt: 1,
    error: null,
  };
  const html = download.page({ data: nasty, now: Date.now() });
  assert.ok(!html.includes('<script>alert(1)</script>'));
  assert.ok(!html.includes('<img src=x'));
  assert.ok(!html.includes('javascript:alert(1)'), 'a hostile URL is escaped, not executed');
  assert.match(html, /&lt;script&gt;/);
});

test('the JSON feed is stable and complete', () => {
  const json = download.payload({ data: data(), now: Date.parse('2026-11-02T00:00:00Z') });
  assert.equal(json.stable.tag, 'v6.38.0');
  assert.equal(json.beta.prerelease, true);
  assert.equal(json.stable.assets.length, STABLE.assets.length);
  assert.equal(json.stable.assets[0].sha256.length, 64);
  assert.equal(json.generated_at, '2026-11-02T00:00:00.000Z');
  assert.equal(json.error, null);
});

test('the permanent links resolve to the newest asset on each channel', () => {
  const state = data();
  assert.match(download.resolve(state, 'v3').url, /6\.38\.0-x86-64-v3\.iso$/);
  assert.match(download.resolve(state, 'v2').url, /6\.38\.0-x86-64-v2\.iso$/);
  assert.match(download.resolve(state, 'beta').url, /os-beta\/.*v3\.iso$/);

  assert.equal(download.resolve(state, 'v9'), null, 'an unknown channel is a 404');
  assert.equal(download.resolve({ stable: null, beta: null }, 'v3'), null);
  assert.equal(download.resolve({ stable: { ...STABLE, assets: [] }, beta: null }, 'v3'), null, 'a release with no ISO is a 404');

  // The beta channel ships one architecture today; asking for the other one
  // must not silently hand back a v3 image labelled v2.
  assert.equal(download.resolve({ stable: null, beta: BETA }, 'v2'), null);
});

test('a beta without a v3 image still answers the beta link', () => {
  const beta = {
    ...BETA,
    assets: [{ ...BETA.assets[0], name: 'zmrig-os-6.39.0-x86-64-v2.iso', url: 'https://example.test/beta-v2.iso' }],
  };
  const asset = download.resolve({ stable: null, beta }, 'beta');
  assert.equal(asset.url, 'https://example.test/beta-v2.iso');
});

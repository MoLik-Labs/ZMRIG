// The release feed against a fake GitHub: the caching, the manifest lookup and
// every way the API can let us down.

'use strict';

const test = require('node:test');
const assert = require('node:assert');

const { Releases, describe } = require('../../lib/releases');

const ASSETS = [
  { name: 'zmrig-os-6.38.0-x86-64-v3.iso', size: 165_000_000, download_count: 9, browser_download_url: 'https://example.test/v3.iso' },
  { name: 'zmrig-os-6.38.0-x86-64-v3.iso.sha256', size: 96, download_count: 1, browser_download_url: 'https://example.test/v3.sha256' },
  { name: 'zmrig-os-stable-x86-64-v3.json', size: 512, download_count: 2, browser_download_url: 'https://example.test/manifest.json' },
];

function github({ fails = false, status = 200 } = {}) {
  const calls = [];
  const fetchImpl = async (url) => {
    calls.push(String(url));
    if (fails) throw new Error('getaddrinfo ENOTFOUND api.github.com');
    if (status !== 200) return { ok: false, status, json: async () => ({}) };
    if (String(url).includes('/releases')) {
      return {
        ok: true,
        status: 200,
        json: async () => [
          {
            tag_name: 'v6.38.0',
            name: 'ZMRIG OS 6.38.0',
            prerelease: false,
            draft: false,
            published_at: '2026-10-30T10:00:00Z',
            assets: ASSETS,
          },
          { tag_name: 'os-beta', name: 'beta', prerelease: true, draft: false, published_at: '2026-11-01T10:00:00Z', assets: [] },
          { tag_name: 'v9', name: 'draft', prerelease: false, draft: true, published_at: null, assets: [] },
        ],
      };
    }
    return { ok: true, status: 200, text: async () => '{"iso_sha256": "' + 'd'.repeat(64) + '"}' };
  };
  return { fetchImpl, calls };
}

test('the first call fetches, the second is a cache hit', async () => {
  const gh = github();
  let clock = 1_700_000_000_000;
  const releases = new Releases({ fetchImpl: gh.fetchImpl, now: () => clock });
  const first = await releases.latest();
  assert.equal(first.stable.tag, 'v6.38.0');
  assert.equal(first.beta.tag, 'os-beta');

  const before = gh.calls.length;
  clock += 60_000;
  await releases.latest();
  assert.equal(gh.calls.length, before, 'a minute later, nothing goes out');

  clock += 700_000; // past the ten-minute ttl
  await releases.latest();
  assert.ok(gh.calls.length > before, 'after the ttl it asks again');
});

test('drafts are dropped and the sha256 comes from the manifest', async () => {
  const gh = github();
  const releases = new Releases({ fetchImpl: gh.fetchImpl });
  const data = await releases.latest();
  const tags = [data.stable, data.beta].filter(Boolean).map((release) => release.tag);
  assert.deepEqual(tags, ['v6.38.0', 'os-beta']);

  // The manifest is fetched after the list, so give it a tick.
  await new Promise((resolve) => setTimeout(resolve, 20));
  const iso = data.stable.assets.find((asset) => asset.name.endsWith('.iso'));
  assert.equal(iso.sha256, 'd'.repeat(64));
  assert.equal(data.stable.assets.find((asset) => asset.name.endsWith('.sha256')).sha256, null);
});

test('a dead API keeps the last good answer', async () => {
  let fail = false;
  const base = github();
  const fetchImpl = async (url) => (fail ? Promise.reject(new Error('offline')) : base.fetchImpl(url));
  const releases = new Releases({ fetchImpl, ttl: 0 });
  const first = await releases.latest();
  assert.equal(first.error, null);
  assert.equal(first.stable.tag, 'v6.38.0');

  fail = true;
  const second = await releases.latest();
  assert.equal(second.stable.tag, 'v6.38.0', 'the last list survives');
  assert.match(second.error, /could not reach GitHub/);
});

test('a failure says what to fix, not just that something failed', async () => {
  const dns = new Error('fetch failed');
  dns.cause = { code: 'ENOTFOUND' };
  assert.match(describe(dns), /name lookup failed/);

  // The shape Node actually produces here: `fetch failed` on top, the code one
  // level down, and nothing in the top-level message.
  const cert = new Error('fetch failed');
  cert.cause = Object.assign(new Error('unable to verify the first certificate'), { code: 'UNABLE_TO_VERIFY_LEAF_SIGNATURE' });
  assert.match(describe(cert), /TLS certificate rejected/);

  const timeout = new Error('fetch failed');
  timeout.cause = { code: 'UND_ERR_CONNECT_TIMEOUT' };
  assert.match(describe(timeout), /did not answer in time/);

  const reset = new Error('fetch failed');
  reset.cause = { code: 'ECONNRESET' };
  assert.match(describe(reset), /reset before a reply/);

  // Every address of a name failed: Node aggregates them under `errors`.
  const aggregate = new Error('fetch failed');
  aggregate.cause = Object.assign(new Error('connect ECONNREFUSED 140.82.121.6:443'), {
    errors: [Object.assign(new Error('connect ECONNREFUSED'), { code: 'ECONNREFUSED' })],
  });
  assert.match(describe(aggregate), /connection refused/);

  // Anything unrecognised is passed through rather than replaced by a guess.
  assert.equal(describe(new Error('socket hang up')), 'socket hang up');

  const releases = new Releases({
    fetchImpl: async () => {
      const error = new Error('fetch failed');
      error.cause = { code: 'ENOTFOUND' };
      throw error;
    },
  });
  const data = await releases.latest();
  assert.match(data.error, /name lookup failed/);
  assert.equal(data.stable, null);
});

test('a non-200 is a failure, not a page full of undefined', async () => {
  const gh = github({ status: 503 });
  const releases = new Releases({ fetchImpl: gh.fetchImpl });
  const data = await releases.latest();
  assert.equal(data.stable, null);
  assert.equal(data.beta, null);
  assert.match(data.error, /503/);
});

test('a malformed answer is rejected instead of half-parsed', async () => {
  const releases = new Releases({ fetchImpl: async () => ({ ok: true, status: 200, json: async () => ({ message: 'rate limited' }) }) });
  const data = await releases.latest();
  assert.equal(data.stable, null);
  assert.match(data.error, /unexpected answer/);
});

test('one in-flight request serves every concurrent caller', async () => {
  const gh = github();
  let release;
  const slow = async (url) => {
    await new Promise((resolve) => { release = resolve; setTimeout(resolve, 5); });
    return gh.fetchImpl(url);
  };
  const releases = new Releases({ fetchImpl: slow });
  const results = await Promise.all([releases.latest(), releases.latest(), releases.latest()]);
  assert.equal(results[0].stable.tag, 'v6.38.0');
  assert.equal(results[1], results[0], 'the same object is handed to every caller');
  assert.equal(gh.calls.filter((url) => url.includes('/releases')).length, 1);
  if (release) release();
});

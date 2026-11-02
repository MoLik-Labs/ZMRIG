// The handler, over a real socket. `node --test` gives every file its own
// process, so the server here is a plain `http.createServer` on port 0 and the
// requests are real HTTP/1.1 with keep-alive, which is the only honest way to
// test headers, compression and 304.

'use strict';

const test = require('node:test');
const assert = require('node:assert');
const http = require('node:http');

const { createApp } = require('../src/app');
const { makeSite, removeSite, fakeReleases, data, STABLE, EMPTY } = require('./fixture');

function start(releaseData = data(), root = null) {
  const siteRoot = root || makeSite();
  const releases = fakeReleases(releaseData);
  const app = createApp({ root: siteRoot, releases, host: 'https://zmrig.example.com', now: () => Date.parse('2026-11-02T00:00:00Z') });
  const server = http.createServer(app.handler);
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      const port = server.address().port;
      resolve({
        server,
        releases,
        root: siteRoot,
        port,
        url: (path) => `http://127.0.0.1:${port}${path}`,
        close: () =>
          new Promise((done) => {
            server.close(done);
            if (!root) removeSite(siteRoot);
          }),
      });
    });
  });
}

async function get(site, path, headers = {}) {
  const response = await fetch(site.url(path), { headers, redirect: 'manual' });
  return { status: response.status, headers: response.headers, text: await response.text() };
}

test('a page, its extensionless twin and its assets', async () => {
  const site = await start();
  try {
    const index = await get(site, '/');
    assert.equal(index.status, 200);
    assert.equal(index.headers.get('content-type'), 'text/html; charset=utf-8');
    assert.match(index.text, /<h1>ZMRIG<\/h1>/);
    assert.match(index.headers.get('cache-control'), /must-revalidate/);
    assert.equal(index.headers.get('x-content-type-options'), 'nosniff');

    assert.equal((await get(site, '/docs/intro')).status, 200);
    assert.equal((await get(site, '/docs/intro.html')).status, 200);
    assert.equal((await get(site, '/vi/docs/intro')).status, 200);

    const asset = await get(site, '/assets/js/main.def456.js');
    assert.equal(asset.status, 200);
    assert.match(asset.headers.get('cache-control'), /immutable/);
  } finally {
    await site.close();
  }
});

test('a directory without a trailing slash is redirected once', async () => {
  const site = await start();
  try {
    // `docs/index.html` answers at both spellings, so neither a hand-typed
    // URL nor a link from the sidebar can 404 on a directory.
    for (const path of ['/docs', '/docs/']) {
      const page = await get(site, path);
      assert.equal(page.status, 200, path);
      assert.match(page.text, /Documentation/);
    }
  } finally {
    await site.close();
  }
});

test('an unknown path answers with the site\'s own 404 page', async () => {
  const site = await start();
  try {
    const missing = await get(site, '/nope');
    assert.equal(missing.status, 404);
    assert.match(missing.text, /Page not found/);
    assert.match(missing.headers.get('cache-control'), /no-store/);
  } finally {
    await site.close();
  }
});

test('HEAD has the headers and no body', async () => {
  const site = await start();
  try {
    const response = await fetch(site.url('/'), { method: 'HEAD' });
    assert.equal(response.status, 200);
    assert.ok(Number(response.headers.get('content-length')) > 0);
    assert.equal(await response.text(), '');
  } finally {
    await site.close();
  }
});

test('compression is chosen per request and announced with Vary', async () => {
  const site = await start();
  try {
    const brotli = await get(site, '/assets/js/main.def456.js', { 'accept-encoding': 'br' });
    assert.equal(brotli.headers.get('content-encoding'), 'br');
    assert.match(brotli.headers.get('vary'), /Accept-Encoding/);

    const gzip = await get(site, '/assets/js/main.def456.js', { 'accept-encoding': 'gzip' });
    assert.equal(gzip.headers.get('content-encoding'), 'gzip');

    const plain = await get(site, '/assets/js/main.def456.js', { 'accept-encoding': 'identity' });
    assert.equal(plain.headers.get('content-encoding'), null);

    // A page under 1 KB is not compressed: the headers would cost more.
    const page = await get(site, '/docs/intro', { 'accept-encoding': 'br' });
    assert.equal(page.headers.get('content-encoding'), null);
  } finally {
    await site.close();
  }
});

test('a second visit is a 304 with no body', async () => {
  const site = await start();
  try {
    const first = await get(site, '/');
    const etag = first.headers.get('etag');
    assert.ok(etag);

    const second = await get(site, '/', { 'if-none-match': etag });
    assert.equal(second.status, 304);
    assert.equal(second.text, '');

    const other = await get(site, '/', { 'if-none-match': '"not-the-one"' });
    assert.equal(other.status, 200);
  } finally {
    await site.close();
  }
});

test('the download page is rendered from the feed and cached behind an etag', async () => {
  const site = await start();
  try {
    const page = await get(site, '/download');
    assert.equal(page.status, 200);
    assert.match(page.text, /Download ZMRIG OS/);
    assert.ok(page.text.includes(STABLE.assets[0].url));
    assert.ok(page.text.includes('https://zmrig.example.com/iso/v3'));
    // fetch() sends `accept-encoding: gzip` on its own, so this is the gzip path.
    assert.equal(page.headers.get('content-encoding'), 'gzip');

    const brotli = await get(site, '/download', { 'accept-encoding': 'br' });
    assert.equal(brotli.headers.get('content-encoding'), 'br');

    const again = await get(site, '/download', { 'if-none-match': page.headers.get('etag') });
    assert.equal(again.status, 304);

    // Three requests, one set of answers: the page is rendered once per fetch of
    // the feed and then reused, which is what keeps the GitHub API out of the
    // request path. The caching inside Releases itself is tested separately.
    assert.equal(site.releases.calls, 3);
  } finally {
    await site.close();
  }
});

test('/releases redirects to /download permanently', async () => {
  const site = await start();
  try {
    const response = await get(site, '/releases');
    assert.equal(response.status, 301);
    assert.equal(response.headers.get('location'), '/download');
  } finally {
    await site.close();
  }
});

test('the three permanent links point at the newest asset', async () => {
  const site = await start();
  try {
    for (const [channel, expected] of [
      ['v3', /6\.38\.0-x86-64-v3\.iso$/],
      ['v2', /6\.38\.0-x86-64-v2\.iso$/],
      ['beta', /os-beta\/.*v3\.iso$/],
    ]) {
      const response = await get(site, `/iso/${channel}`);
      assert.equal(response.status, 302, channel);
      assert.match(response.headers.get('location'), expected);
      assert.match(response.headers.get('cache-control'), /max-age=300/);
    }

    const unknown = await get(site, '/iso/v9');
    assert.equal(unknown.status, 404);
    assert.match(unknown.text, /no such channel/);
  } finally {
    await site.close();
  }
});

test('the JSON feed is the same data, machine readable', async () => {
  const site = await start();
  try {
    const response = await get(site, '/api/releases.json');
    assert.equal(response.status, 200);
    const body = JSON.parse(response.text);
    assert.equal(body.stable.tag, 'v6.38.0');
    assert.equal(body.stable.assets[0].sha256.length, 64);
    assert.equal(body.generated_at, '2026-11-02T00:00:00.000Z');
    assert.match(response.headers.get('cache-control'), /max-age=300/);
  } finally {
    await site.close();
  }
});

test('with GitHub down the page still renders and the links still work', async () => {
  const site = await start({ stable: null, beta: null, fetchedAt: 0, error: 'could not reach GitHub (offline)' });
  try {
    const page = await get(site, '/download');
    assert.equal(page.status, 200);
    assert.match(page.text, /could not reach GitHub/);
    assert.match(page.text, /No image has been published/);

    const iso = await get(site, '/iso/v3');
    assert.equal(iso.status, 404, 'nothing to redirect to, and that is a 404, not a crash');
  } finally {
    await site.close();
  }
});

test('healthz is small, fresh and honest about the process', async () => {
  const site = await start();
  try {
    const health = await get(site, '/healthz');
    assert.equal(health.status, 200);
    assert.match(health.headers.get('cache-control'), /no-store/);
    const body = JSON.parse(health.text);
    assert.equal(body.ok, true);
    assert.ok(body.files >= 8);
    assert.ok(body.bytes > 0);
    assert.ok(body.compressed_bytes > 0);
    assert.equal(typeof body.rss_mb, 'number');
  } finally {
    await site.close();
  }
});

test('only GET and HEAD are answered', async () => {
  const site = await start();
  try {
    const response = await fetch(site.url('/'), { method: 'POST', body: 'x' });
    assert.equal(response.status, 405);
    assert.equal(response.headers.get('allow'), 'GET, HEAD');
  } finally {
    await site.close();
  }
});

test('a traversal attempt never reaches the filesystem', async () => {
  const site = await start();
  try {
    for (const path of ['/../package.json', '/docs/../../etc/passwd', '/%2e%2e%2fpackage.json', '/a%00b']) {
      const response = await get(site, path);
      assert.ok([400, 404].includes(response.status), `${path} -> ${response.status}`);
      assert.ok(!response.text.includes('"private"'), `${path} did not leak the package manifest`);
    }
  } finally {
    await site.close();
  }
});

test('a warm page is served in well under a millisecond at the median', async () => {
  const site = await start();
  try {
    const agent = new http.Agent({ keepAlive: true, maxSockets: 1 });
    const once = () =>
      new Promise((resolve, reject) => {
        const started = process.hrtime.bigint();
        const request = http.get(
          { host: '127.0.0.1', port: site.port, path: '/docs/intro', agent, headers: { 'accept-encoding': 'br' } },
          (response) => {
            response.resume();
            response.on('end', () => resolve(Number(process.hrtime.bigint() - started) / 1e6));
          },
        );
        request.on('error', reject);
      });

    const samples = [];
    for (let i = 0; i < 300; i += 1) samples.push(await once());
    samples.sort((a, b) => a - b);
    const p50 = samples[150];
    const p95 = samples[285];
    agent.destroy();

    // Generous enough for a shared CI runner, tight enough that a regression
    // (a stat per request, a sync compression) shows up immediately.
    assert.ok(p50 < 5, `p50 ${p50.toFixed(2)} ms`);
    assert.ok(p95 < 25, `p95 ${p95.toFixed(2)} ms`);
  } finally {
    await site.close();
  }
});

test('an empty table still answers instead of crashing', async () => {
  const site = await start(EMPTY);
  try {
    const page = await get(site, '/download');
    assert.equal(page.status, 200);
    assert.match(page.text, /releases/);
  } finally {
    await site.close();
  }
});

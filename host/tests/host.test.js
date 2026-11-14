// One process, three jobs, over a real socket.
//
// The point of this suite is not that each half works — `serve/tests` and
// `fleet/tests` already prove that — but that they coexist on one port without
// one of them shadowing the other. A rig that reaches `/v1/hello` must not be
// answered by a static file handler, and a person opening `/` must not be
// answered by the device protocol.
//
//   node --test host/tests/

'use strict';

const test = require('node:test');
const assert = require('node:assert');
const http = require('node:http');
const path = require('node:path');

const host = require('../server');
const { makeSite, removeSite, fakeReleases, data } = require('../../serve/tests/fixture');

function env(extra = {}) {
  return {
    // A fresh state file per test: the fleet's memory is a file on the host, and
    // a test must never inherit another test's rigs.
    FLEET_STATE: path.join(require('node:os').tmpdir(), `zmrig-host-${process.pid}-${Math.random().toString(16).slice(2)}.json`),
    FLEET_ADMIN_IDS: 'tg:1',
    FLEET_INTERVAL: '60',
    FLEET_QUIET: '1',
    ...extra,
  };
}

function start(options = {}) {
  const siteRoot = options.siteRoot || makeSite();
  const releases = options.releases || fakeReleases(data());
  const built = host.createServer(env(options.env || {}), { siteRoot, releases });

  return new Promise((resolve) => {
    built.server.listen(0, '127.0.0.1', () => {
      const port = built.server.address().port;
      resolve({
        ...built,
        port,
        url: (path_) => `http://127.0.0.1:${port}${path_}`,
        close: () => new Promise((done) => built.server.close(done)),
        cleanup: () => removeSite(siteRoot),
      });
    });
  });
}

async function get(server, path_, init = {}) {
  const response = await fetch(server.url(path_), { redirect: 'manual', ...init });
  const body = await response.text();
  return { status: response.status, headers: response.headers, body };
}

test('the documentation is the front door, not the device protocol', async () => {
  const server = await start();
  try {
    const root = await get(server, '/');
    assert.strictEqual(root.status, 200);
    assert.match(root.headers.get('content-type'), /text\/html/);
    assert.match(root.body, /ZMRIG/);

    // A page the build actually contains, and its Vietnamese twin.
    assert.strictEqual((await get(server, '/docs/intro.html')).status, 200);
    assert.strictEqual((await get(server, '/vi/docs/intro.html')).status, 200);
  } finally {
    await server.close();
    server.cleanup();
  }
});

test('a rig and a browser are answered by different halves of the same port', async () => {
  const server = await start();
  try {
    // No device key: the device protocol answers, the site does not.
    const unauthorised = await get(server, '/v1/hello', { method: 'POST' });
    assert.strictEqual(unauthorised.status, 401);
    assert.match(unauthorised.headers.get('content-type'), /application\/json/);
    assert.strictEqual(JSON.parse(unauthorised.body).ok, false);

    // A key that hashes to a Device ID enrols itself and gets an answer.
    const enrolled = await get(server, '/v1/hello', {
      method: 'POST',
      headers: { authorization: 'Bearer a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1', 'content-type': 'application/json' },
      body: JSON.stringify({ status: { state: 'mining', hashrate: 1201.4 } }),
    });
    assert.strictEqual(enrolled.status, 200);
    const answer = JSON.parse(enrolled.body);
    assert.strictEqual(answer.ok, true);
    assert.strictEqual(answer.enrolled, false, 'a rig that nobody claimed is not enrolled');
    assert.strictEqual(answer.interval, 60);

    // The same path with GET is a protocol error, not a page.
    const wrongMethod = await get(server, '/v1/hello');
    assert.strictEqual(wrongMethod.status, 405);
  } finally {
    await server.close();
    server.cleanup();
  }
});

test('one health check answers for all three jobs', async () => {
  const server = await start();
  try {
    const health = await get(server, '/healthz');
    assert.strictEqual(health.status, 200);

    const body = JSON.parse(health.body);
    assert.strictEqual(body.ok, true);
    assert.deepStrictEqual(body.bots, { telegram: false, discord: false });
    assert.strictEqual(body.fleet.rigs, 0);
    assert.ok(body.site.files > 0, 'the site is loaded, so a deploy that lost it is visible here');
    assert.ok(body.uptime_s >= 0);
  } finally {
    await server.close();
    server.cleanup();
  }
});

test('the download page and the channel links come from the release feed', async () => {
  const server = await start();
  try {
    const download = await get(server, '/download');
    assert.strictEqual(download.status, 200);
    assert.match(download.body, /sha256/i, 'the checksums are the point of the page');

    await new Promise((done) => setTimeout(done, 50));
    const iso = await get(server, '/iso/v3');
    assert.strictEqual(iso.status, 302, 'a channel link is a redirect to the newest image');
    assert.match(iso.headers.get('location'), /x86-64-v3\.iso$/);

    const feed = await get(server, '/api/releases.json');
    assert.strictEqual(feed.status, 200);
    assert.ok(JSON.parse(feed.body).stable, 'the feed carries the stable release');
  } finally {
    await server.close();
    server.cleanup();
  }
});

test('nothing answers on a path that neither half owns', async () => {
  const server = await start();
  try {
    const missing = await get(server, '/definitely-not-a-page');
    assert.strictEqual(missing.status, 404);
    // The site's 404 page, not the fleet's JSON: a person who mistyped a URL
    // should get a page.
    assert.match(missing.headers.get('content-type'), /text\/html/);
  } finally {
    await server.close();
    server.cleanup();
  }
});

test('the fleet dashboard is not mounted on the public host', async () => {
  // The dashboard is an HTML control surface that logs in; the unified host has
  // no business publishing one next to the documentation. It stays available
  // when `fleet/` runs on its own.
  const server = await start({ env: { FLEET_WEB_PASSWORD: 'secret' } });
  try {
    const fleetPage = await get(server, '/fleet');
    assert.strictEqual(fleetPage.status, 404);
    const login = await get(server, '/login');
    assert.strictEqual(login.status, 404);
  } finally {
    await server.close();
    server.cleanup();
  }
});

test('a missing site does not stop the rigs', async () => {
  const empty = path.join(require('node:os').tmpdir(), `zmrig-empty-${process.pid}-${Date.now()}`);
  require('node:fs').mkdirSync(empty, { recursive: true });
  const server = await start({ siteRoot: empty });
  try {
    // The rig half is unaffected: this is the half that earns the money.
    const health = await get(server, '/healthz');
    assert.strictEqual(health.status, 200);
    const hello = await get(server, '/v1/hello', {
      method: 'POST',
      headers: { authorization: 'Bearer b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2', 'content-type': 'application/json' },
      body: '{}',
    });
    assert.strictEqual(hello.status, 200);
  } finally {
    await server.close();
    require('node:fs').rmSync(empty, { recursive: true, force: true });
  }
});

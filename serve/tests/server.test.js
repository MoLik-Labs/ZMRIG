// The entry point, started the way Render starts it: a child process, a port
// from the environment, a signal to stop. Everything else in the suite tests the
// handler in-process; this one proves the process boots, serves and exits.

'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { spawn } = require('node:child_process');
const path = require('node:path');

const { makeSite, removeSite } = require('./fixture');

const SERVER = path.join(__dirname, '..', 'server.js');

function boot(root, extra = {}) {
  const child = spawn(process.execPath, [SERVER], {
    env: {
      ...process.env,
      PORT: '0',
      HOST: '127.0.0.1',
      SITE_ROOT: root,
      // Nothing listens on port 9 here, so the release feed fails immediately
      // instead of waiting on a real network in CI.
      GITHUB_API: 'http://127.0.0.1:9',
      RELEASES_TTL: '60000',
      PUBLIC_URL: 'https://zmrig.example.com',
      ...extra,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  let output = '';
  const port = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`no port in 10s:\n${output}`)), 10_000);
    child.stdout.on('data', (chunk) => {
      output += chunk;
      const match = /listening on [\d.]+:(\d+)/.exec(output);
      if (match) {
        clearTimeout(timer);
        resolve(Number(match[1]));
      }
    });
    child.stderr.on('data', (chunk) => { output += chunk; });
    child.on('exit', (code) => {
      clearTimeout(timer);
      reject(new Error(`exited ${code}:\n${output}`));
    });
  });

  return { child, port, output: () => output };
}

test('the process boots, serves and shuts down on SIGTERM', async () => {
  const root = makeSite();
  const server = boot(root);
  try {
    const port = await server.port;
    assert.ok(port > 0);

    const health = await fetch(`http://127.0.0.1:${port}/healthz`);
    assert.equal(health.status, 200);
    const body = await health.json();
    assert.equal(body.ok, true);

    const page = await fetch(`http://127.0.0.1:${port}/`);
    assert.equal(page.status, 200);
    assert.match(await page.text(), /ZMRIG/);

    // The feed cannot be reached, and the download page has to say so while
    // staying a 200 with working links.
    const download = await fetch(`http://127.0.0.1:${port}/download`);
    assert.equal(download.status, 200);
    assert.match(await download.text(), /could not reach GitHub/);

    const logs = server.output();
    assert.match(logs, /files \d+ routes/);
    assert.match(logs, /release feed: stable none/);
  } finally {
    const exited = new Promise((resolve) => server.child.once('exit', (code, signal) => resolve({ code, signal })));
    server.child.kill('SIGTERM');
    const result = await exited;
    assert.equal(result.code, 0, 'a clean shutdown exits 0');
    removeSite(root);
  }
});

test('it refuses to start without a site to serve', async () => {
  const child = spawn(process.execPath, [SERVER], {
    env: { ...process.env, PORT: '0', SITE_ROOT: path.join(__dirname, 'does-not-exist') },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const code = await new Promise((resolve) => child.on('exit', resolve));
  assert.equal(code, 2);
});

test('the Pages build is served from the root, and its old paths redirect', async () => {
  // The build in `web/` was made for GitHub Pages under `/ZMRIG/`. Started as
  // Render starts it — a child process, the committed build, no rebuild — this
  // is the case that used to answer 404 for the stylesheet the home page asks
  // for, which is a page that renders but does nothing.
  const root = makeSite({
    'index.html': '<!doctype html><html lang="en"><head><link rel="stylesheet" href="/ZMRIG/assets/css/main.abc123.css"></head><body><a href="/ZMRIG/docs/intro">Docs</a></body></html>',
  });
  const server = boot(root);
  try {
    const port = await server.port;
    const home = await fetch(`http://127.0.0.1:${port}/`);
    assert.equal(home.status, 200);
    const html = await home.text();
    assert.match(html, /href="\/assets\/css\/main\.abc123\.css"/, 'the stylesheet link is root-relative');

    const css = await fetch(`http://127.0.0.1:${port}/assets/css/main.abc123.css`);
    assert.equal(css.status, 200, 'and the file it names is served');
    assert.match(css.headers.get('content-type') || '', /text\/css/);

    const docs = await fetch(`http://127.0.0.1:${port}/docs/intro`);
    assert.equal(docs.status, 200, 'the link in the body resolves too');

    // A link copied out of the Pages site, or out of this host before the
    // rewrite, lands on the page instead of a 404.
    const old = await fetch(`http://127.0.0.1:${port}/ZMRIG/docs/intro`, { redirect: 'manual' });
    assert.equal(old.status, 301);
    assert.equal(old.headers.get('location'), '/docs/intro');
    const root301 = await fetch(`http://127.0.0.1:${port}/ZMRIG/`, { redirect: 'manual' });
    assert.equal(root301.headers.get('location'), '/');

    assert.match(server.output(), /rebase\s+\/ZMRIG\/ -> \//);
  } finally {
    const exited = new Promise((resolve) => server.child.once('exit', (code) => resolve(code)));
    server.child.kill('SIGTERM');
    await exited;
    removeSite(root);
  }
});

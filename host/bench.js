// What the host actually serves, measured rather than assumed.
//
//   node host/bench.js                 # 8 concurrent, 5 s per path
//   node host/bench.js --conc 32
//   node host/bench.js --root web      # the committed site, not a fixture
//
// The free Render plan gives a service 0.1 CPU and 512 MB, and a cold start of
// ~30 s. Neither number tells you what a page costs to serve, which is what this
// prints: requests per second, p50/p99 latency, and bytes on the wire with the
// gzip and brotli the client actually asked for.
//
// Three things are measured, because they are the three paths a visitor takes:
//
//   /                    the documentation index, precompressed, immutable assets
//   /docs/intro          a prose page with no data behind it
//   /api/releases.json   the release feed, which is fetched from GitHub once and
//                        then served from the rendered cache
//
// The device protocol is left out on purpose: it is a rig's path, it runs on a
// timer, and a load test on it measures the test.
'use strict';

const http = require('node:http');
const path = require('node:path');

const host = require('./server');

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  if (i === -1) return fallback;
  const value = process.argv[i + 1];
  return value === undefined || value.startsWith('--') ? true : value;
}

const CONCURRENCY = Number(arg('conc', 8)) || 8;
const SECONDS = Number(arg('seconds', 5)) || 5;
const ROOT = path.resolve(__dirname, '..', String(arg('root', 'web')));
// A hashed asset is discovered rather than guessed: its name carries a content
// hash, and a benchmark that quietly asks for a 404 measures the 404 path.
function assetPath() {
  const fs = require('node:fs');
  const dir = path.join(ROOT, 'assets', 'css');
  try {
    const name = fs.readdirSync(dir).find((f) => f.endsWith('.css'));
    if (name) return `/assets/css/${name}`;
  } catch {
    // fall through to a JS bundle
  }
  return '/assets/js/main.js';
}

const PATHS = ['/', '/docs/intro', '/api/releases.json', assetPath()];

// A release feed with no network: the same shape the live one returns, so the
// cache path is exercised instead of skipped.
function fakeReleases() {
  const payload = {
    stable: { tag: 'v6.48.0', published_at: new Date().toISOString(), assets: [] },
    beta: { tag: 'v6.48.0', published_at: new Date().toISOString(), assets: [] },
    fetchedAt: Date.now(),
    error: null,
  };
  return { latest: async () => payload };
}

function request(port, urlPath) {
  return new Promise((resolve, reject) => {
    const started = process.hrtime.bigint();
    const req = http.get(
      { host: '127.0.0.1', port, path: urlPath, headers: { 'accept-encoding': 'br, gzip' } },
      (res) => {
        let bytes = 0;
        res.on('data', (chunk) => { bytes += chunk.length; });
        res.on('end', () => {
          const ms = Number(process.hrtime.bigint() - started) / 1e6;
          resolve({ status: res.statusCode, bytes, ms, encoding: res.headers['content-encoding'] || 'identity' });
        });
      },
    );
    req.on('error', reject);
  });
}

function percentile(sorted, p) {
  if (sorted.length === 0) return 0;
  const i = Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length));
  return sorted[i];
}

async function measure(port, urlPath) {
  const samples = [];
  const deadline = Date.now() + SECONDS * 1000;

  async function worker() {
    while (Date.now() < deadline) {
      const result = await request(port, urlPath);
      samples.push(result);
    }
  }

  await Promise.all(Array.from({ length: CONCURRENCY }, worker));

  const times = samples.map((s) => s.ms).sort((a, b) => a - b);
  const elapsed = SECONDS;
  const first = samples[0] || { bytes: 0, encoding: '-' };
  return {
    path: urlPath,
    requests: samples.length,
    rps: Math.round(samples.length / elapsed),
    p50: percentile(times, 50).toFixed(2),
    p99: percentile(times, 99).toFixed(2),
    mbps: ((samples.reduce((sum, s) => sum + s.bytes, 0) / elapsed) / 1048576).toFixed(1),
    bytes: first.bytes,
    encoding: first.encoding,
    status: first.status,
  };
}

async function main() {
  const built = host.createServer(
    {
      FLEET_STATE: path.join(require('node:os').tmpdir(), `zmrig-bench-${process.pid}.json`),
      FLEET_ADMIN_IDS: 'tg:1',
      FLEET_INTERVAL: '600',
      FLEET_QUIET: '1',
    },
    { siteRoot: ROOT, releases: fakeReleases() },
  );

  await new Promise((resolve) => built.server.listen(0, '127.0.0.1', resolve));
  const port = built.server.address().port;

  console.log(`\nroot         ${ROOT}`);
  console.log(`concurrency  ${CONCURRENCY}, ${SECONDS}s per path, gzip/brotli offered\n`);
  console.log('  path                  req/s     p50 ms   p99 ms   MB/s    bytes   encoding');
  console.log('  --------------------  -------  -------  -------  ------  -------  --------');

  for (const urlPath of PATHS) {
    // One warm-up request per path: the first request to a page allocates and
    // compresses it, and that cost belongs to the first visitor, not the sample.
    await request(port, urlPath).catch(() => {});
    const row = await measure(port, urlPath);
    console.log(
      `  ${row.path.padEnd(20)}  ${String(row.rps).padStart(7)}  ${row.p50.padStart(7)}  ` +
      `${row.p99.padStart(7)}  ${row.mbps.padStart(6)}  ${String(row.bytes).padStart(7)}  ${row.encoding}`,
    );
  }

  console.log(`\nrss ${Math.round(process.memoryUsage().rss / 1048576)} MB, node ${process.version}\n`);
  await new Promise((resolve) => built.server.close(resolve));
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});

'use strict';

// "Is a newer image published?", against a fake registry.
//
// The real one is ghcr.io, which needs the network, an anonymous pull token and
// a release that exists. None of those are properties of the code that decides
// whether 6.49.0 is newer than 6.48.0, or whether a manifest list resolves to
// the right architecture, so the test serves the four documents a registry
// would serve and asserts the answer.

const test = require('node:test');
const assert = require('node:assert');
const http = require('node:http');

const { check, resolve, versionOf, newer, tokenUrl, archName } = require('../update.js');

const VERSION = '6.48.0';
const NEWER = '6.49.0';

// A registry that requires a token, like ghcr.io does for a public package:
// the first request gets 401 with a WWW-Authenticate header, and the same
// request with `authorization: Bearer ...` gets the document.
function registry({ version, arch = 'amd64', index = true, requireToken = true } = {}) {
  const manifestDigest = 'sha256:' + 'c'.repeat(64);
  const configDigest = 'sha256:' + 'd'.repeat(64);
  const seen = [];

  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://127.0.0.1');
    seen.push({ path: url.pathname, query: url.search, auth: req.headers.authorization || null });

    if (url.pathname === '/token') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ token: 'test-token' }));
      return;
    }

    if (requireToken && req.headers.authorization !== 'Bearer test-token') {
      // The realm has to look like the real one: absolute URL, service and scope
      // in the header rather than in the body.
      res.writeHead(401, {
        'www-authenticate': `Bearer realm="${base}/token",service="fake",scope="repository:molik-labs/zmrig:pull"`,
      });
      res.end('{}');
      return;
    }

    if (index && url.pathname === '/v2/molik-labs/zmrig/manifests/latest') {
      res.writeHead(200, {
        'content-type': 'application/vnd.oci.image.index.v1+json',
        'docker-content-digest': 'sha256:' + 'a'.repeat(64),
      });
      res.end(JSON.stringify({
        manifests: [
          { platform: { architecture: 'arm64', os: 'linux' }, digest: 'sha256:' + 'b'.repeat(64) },
          { platform: { architecture: arch, os: 'linux' }, digest: manifestDigest },
        ],
      }));
      return;
    }

    if (!index && url.pathname === '/v2/molik-labs/zmrig/manifests/latest') {
      res.writeHead(200, {
        'content-type': 'application/vnd.oci.image.manifest.v1+json',
        'docker-content-digest': manifestDigest,
      });
      res.end(JSON.stringify({ config: { digest: configDigest } }));
      return;
    }

    if (url.pathname.endsWith('/manifests/' + manifestDigest)) {
      res.writeHead(200, { 'content-type': 'application/vnd.oci.image.manifest.v1+json' });
      res.end(JSON.stringify({ config: { digest: configDigest } }));
      return;
    }

    if (url.pathname.endsWith('/blobs/' + configDigest)) {
      res.writeHead(200, { 'content-type': 'application/octet-stream' });
      res.end(JSON.stringify({
        config: {
          Labels: {
            'org.opencontainers.image.version': version,
            'org.opencontainers.image.revision': 'e'.repeat(40),
            'org.opencontainers.image.source': 'https://github.com/MoLik-Labs/ZMRIG',
          },
        },
      }));
      return;
    }

    res.writeHead(404).end('{}');
  });

  let base = '';

  return {
    seen,
    async start() {
      await new Promise((done) => server.listen(0, '127.0.0.1', done));
      base = `http://127.0.0.1:${server.address().port}`;
      return base;
    },
    stop() {
      return new Promise((done) => server.close(done));
    },
  };
}

function envFor(base, extra = {}) {
  return { ZMRIG_REGISTRY: base, ZMRIG_IMAGE: 'molik-labs/zmrig', ZMRIG_TAG: 'latest', ZMRIG_VERSION: VERSION, ...extra };
}

// The check prints; capture it so a test can assert on the wording a person
// reads, not just the exit code.
async function capture(fn) {
  const out = [];
  const err = [];
  const log = console.log;
  const error = console.error;
  console.log = (...args) => out.push(args.join(' '));
  console.error = (...args) => err.push(args.join(' '));
  try {
    const code = await fn();
    return { code, out: out.join('\n'), err: err.join('\n') };
  } finally {
    console.log = log;
    console.error = error;
  }
}

test('versions compare numerically, not as strings', () => {
  assert.ok(newer('6.9.0', '6.10.0') === false, '9 is not greater than 10');
  assert.ok(newer('6.10.0', '6.9.0'));
  assert.ok(newer('7.0.0', '6.99.99'));
  assert.ok(!newer('6.48.0', '6.48.0'));
  assert.ok(newer('v6.49.0', '6.48.0'), 'a leading v is tolerated');
  assert.equal(versionOf('edge'), null);
  assert.equal(versionOf(''), null);
  assert.equal(versionOf('6.48'), null, 'a partial version is not a version');
  assert.ok(!newer('junk', '6.48.0'), 'an unparseable tag never becomes an update');
});

test('the registry API is spoken the way a pull speaks it', async () => {
  const fake = registry({ version: NEWER });
  const base = await fake.start();
  try {
    const found = await resolve(envFor(base));
    assert.ok(found.ok, JSON.stringify(found));
    assert.equal(found.version, NEWER);
    assert.equal(found.revision, 'e'.repeat(40));
    assert.equal(found.arch, 'amd64');

    // The token dance happened, and the last request carried it.
    assert.ok(fake.seen.some((request) => request.path === '/token'));
    const manifests = fake.seen.filter((request) => request.path.startsWith('/v2/'));
    assert.ok(manifests.some((request) => request.auth === 'Bearer test-token'));
  } finally {
    await fake.stop();
  }
});

test('a single-arch manifest is read without the index hop', async () => {
  const fake = registry({ version: VERSION, index: false });
  const base = await fake.start();
  try {
    const found = await resolve(envFor(base));
    assert.ok(found.ok, JSON.stringify(found));
    assert.equal(found.version, VERSION);
  } finally {
    await fake.stop();
  }
});

test('the index is resolved for this architecture, not the first entry', async () => {
  const fake = registry({ version: NEWER, arch: archName() });
  const base = await fake.start();
  try {
    const found = await resolve(envFor(base), { arch: 'amd64' });
    assert.equal(found.arch, 'amd64');
    assert.ok(found.ok);
  } finally {
    await fake.stop();
  }
});

test('an architecture the tag does not carry is "cannot tell", not an update', async () => {
  const fake = registry({ version: NEWER, arch: 's390x' });
  const base = await fake.start();
  try {
    const found = await resolve({ ...envFor(base) }, { arch: 'amd64' });
    assert.equal(found.ok, false);
    assert.match(found.reason, /no linux\/amd64 manifest/);
  } finally {
    await fake.stop();
  }
});

test('current, available and unknown exit with 0, 3 and 2', async () => {
  for (const [remote, expected, word] of [[VERSION, 0, 'current'], [NEWER, 3, 'available']]) {
    const fake = registry({ version: remote });
    const base = await fake.start();
    try {
      const result = await capture(() => check(['--check'], envFor(base)));
      assert.equal(result.code, expected, `${remote}: ${result.out} ${result.err}`);
      assert.match(result.out, new RegExp(VERSION));
      assert.match(result.out, new RegExp(remote));
      assert.match(result.out, new RegExp(word));
      if (expected === 3) assert.match(result.out, /zmrig-docker-update --apply/);
    } finally {
      await fake.stop();
    }
  }

  // No registry at all: a miner behind a firewall keeps mining, and the exit
  // code says "cannot tell" rather than "up to date".
  const dead = await capture(() => check(['--check'], { ZMRIG_VERSION: VERSION, ZMRIG_REGISTRY: 'http://127.0.0.1:1', ZMRIG_TIMEOUT: '500' }));
  assert.equal(dead.code, 2);
  assert.match(dead.err, /cannot check/);
});

test('--json is one line and says what a dashboard needs', async () => {
  const fake = registry({ version: NEWER });
  const base = await fake.start();
  try {
    const result = await capture(() => check(['--check', '--json'], envFor(base)));
    assert.equal(result.code, 3);
    const json = JSON.parse(result.out.trim());
    assert.equal(json.running, VERSION);
    assert.equal(json.available, NEWER);
    assert.equal(json.update, 'available');
    assert.match(json.digest, /^sha256:/);
  } finally {
    await fake.stop();
  }
});

test('a container that does not know its version says so instead of guessing', async () => {
  const fake = registry({ version: NEWER });
  const base = await fake.start();
  try {
    const result = await capture(() => check(['--check'], { ZMRIG_REGISTRY: base, ZMRIG_IMAGE: 'molik-labs/zmrig', ZMRIG_TAG: 'latest' }));
    assert.equal(result.code, 2, 'no version baked in means cannot tell');
    assert.match(result.out, /unknown version/);
  } finally {
    await fake.stop();
  }
});

test('the bearer challenge is parsed into a token request', () => {
  const url = tokenUrl('Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="repository:molik-labs/zmrig:pull"', 'molik-labs/zmrig');
  const parsed = new URL(url);
  assert.equal(parsed.origin + parsed.pathname, 'https://ghcr.io/token');
  assert.equal(parsed.searchParams.get('service'), 'ghcr.io');
  assert.equal(parsed.searchParams.get('scope'), 'repository:molik-labs/zmrig:pull');

  // A challenge with only a realm still produces a usable scope: the registry
  // decides, but an empty scope would be rejected.
  assert.match(tokenUrl('Bearer realm="https://r.example/token"', 'a/b'), /scope=repository%3Aa%2Fb%3Apull|scope=repository:a%2Fb:pull/);
  assert.equal(tokenUrl('', 'a/b'), null);
  assert.equal(tokenUrl('Basic realm="x"', 'a/b'), null);
});

test('architecture names are the registry\'s, not Node\'s', () => {
  assert.equal(archName('x64'), 'amd64');
  assert.equal(archName('arm64'), 'arm64');
});

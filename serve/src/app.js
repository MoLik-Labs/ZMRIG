// The request handler.
//
// Three rules hold everywhere in this file:
//
//   1. A static request does no I/O and allocates nothing it can reuse.
//   2. Anything that depends on GitHub is generated once per fetch and cached
//      behind the same validator, so a page refresh costs 304 and a few bytes.
//   3. Nothing throws to the client: a broken release feed still renders a page
//      with working links, which is the only failure mode that matters on a
//      download page.

'use strict';

const zlib = require('node:zlib');
const assets = require('./assets');
const download = require('./download');
const { ARCHES } = require('./arches');

// The only pages this process renders are its own HTML and JSON, so they can
// carry a policy that forbids everything. The documentation is left out: it is
// a Docusaurus build with scripts of its own, and a policy that fits it would
// have to be permissive enough to be pointless.
const PAGE_CSP = "default-src 'none'; style-src 'unsafe-inline'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'self'";
const JSON_CSP = "default-src 'none'; frame-ancestors 'self'";

const BASE_HEADERS = {
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'strict-origin-when-cross-origin',
  'X-Frame-Options': 'SAMEORIGIN',
  'Permissions-Policy': 'geolocation=(), camera=(), microphone=()',
  'Cross-Origin-Opener-Policy': 'same-origin',
};

function encode(body, acceptEncoding, cache) {
  if (body.length < 1024) return { body, encoding: null };
  if (cache && cache.body) return cache;
  let result = { body, encoding: null };
  if (assets.accepts(acceptEncoding, 'br')) {
    result = { body: zlib.brotliCompressSync(body, { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 9 } }), encoding: 'br' };
  } else if (assets.accepts(acceptEncoding, 'gzip')) {
    result = { body: zlib.gzipSync(body, { level: 9 }), encoding: 'gzip' };
  }
  return result;
}

function send(req, res, { status = 200, body, encoding = null, type, etag, cache, extra = {} }) {
  const headers = { ...BASE_HEADERS, ...extra };
  headers['Content-Type'] = type;
  headers['Cache-Control'] = cache;
  if (etag) headers.ETag = etag;
  if (encoding) headers['Content-Encoding'] = encoding;
  headers.Vary = 'Accept-Encoding';
  headers['Content-Length'] = body.length;

  // A conditional GET is answered before a single byte of the body is touched:
  // this is the path a returning visitor takes on every page.
  const ifNoneMatch = req.headers['if-none-match'];
  if (ifNoneMatch && etag && ifNoneMatch.split(',').some((tag) => tag.trim() === etag)) {
    delete headers['Content-Length'];
    delete headers['Content-Encoding'];
    res.writeHead(304, headers);
    res.end();
    return;
  }

  res.writeHead(status, headers);
  res.end(req.method === 'HEAD' ? undefined : body);
}

function clean(pathname) {
  let value = pathname;
  try {
    value = decodeURIComponent(pathname);
  } catch {
    return null;
  }
  if (value.includes('\0')) return null;
  value = value.split('?')[0];
  if (!value.startsWith('/')) value = `/${value}`;
  value = value.replace(/\/{2,}/g, '/');
  if (value.length > 512) return null;
  if (value.split('/').some((part) => part === '..')) return null;
  return value;
}

function createApp({
  root,
  releases,
  host = '',
  now = () => Date.now(),
  log = () => {},
  cache = null,
  version = '',
} = {}) {
  const table = cache || assets.load(root, { log });
  const started = Date.now();

  // Rendered once per successful fetch of the release feed.
  let rendered = { key: null, html: null, json: null, etag: null, br: null, gz: null };

  async function feed() {
    return releases.latest();
  }

  function renderDynamic(data) {
    const key = `${data.fetchedAt}:${data.error ? 1 : 0}:${data.stable ? data.stable.tag : '-'}:${data.beta ? data.beta.tag : '-'}`;
    if (rendered.key === key) return rendered;

    const html = Buffer.from(download.page({ data, now: now(), host, version }));
    const json = Buffer.from(JSON.stringify(download.payload({ data, now: now() })));
    const etag = `"d${data.fetchedAt.toString(16)}-${html.length.toString(16)}"`;
    rendered = {
      key,
      html,
      json,
      etag,
      br: zlib.brotliCompressSync(html, { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 9 } }),
      gz: zlib.gzipSync(html, { level: 9 }),
    };
    return rendered;
  }

  function dynamic(req, res, body, { type, cache, etag, csp = PAGE_CSP }) {
    const accept = req.headers['accept-encoding'];
    let out = { body, encoding: null };
    if (body.length >= 1024) {
      if (rendered.br && body === rendered.html && assets.accepts(accept, 'br')) {
        out = { body: rendered.br, encoding: 'br' };
      } else if (rendered.gz && body === rendered.html && assets.accepts(accept, 'gzip')) {
        out = { body: rendered.gz, encoding: 'gzip' };
      }
    }
    send(req, res, { body: out.body, encoding: out.encoding, type, cache, etag, extra: { 'Content-Security-Policy': csp } });
  }

  async function handler(req, res) {
    const method = req.method || 'GET';
    if (method !== 'GET' && method !== 'HEAD') {
      const body = Buffer.from(JSON.stringify({ error: 'method not allowed' }));
      res.writeHead(405, { ...BASE_HEADERS, Allow: 'GET, HEAD', 'Content-Type': 'application/json', 'Content-Length': body.length });
      res.end(body);
      return;
    }

    const url = clean(req.url || '/');
    if (url === null) {
      res.writeHead(400, { ...BASE_HEADERS, 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('bad request');
      return;
    }

    if (url === '/healthz') {
      const body = Buffer.from(JSON.stringify({
        ok: true,
        files: table.count,
        bytes: table.raw,
        compressed_bytes: table.packed,
        uptime_s: Math.round((Date.now() - started) / 1000),
        rss_mb: Math.round(process.memoryUsage().rss / 1048576),
      }));
      send(req, res, { body, type: 'application/json; charset=utf-8', cache: 'no-store' });
      return;
    }

    if (url === '/api/releases.json') {
      const data = await feed();
      const state = renderDynamic(data);
      dynamic(req, res, state.json, {
        type: 'application/json; charset=utf-8',
        cache: 'public, max-age=300',
        etag: state.etag,
        csp: JSON_CSP,
      });
      return;
    }

    if (url === '/iso' || url.startsWith('/iso/')) {
      const wanted = url.slice('/iso/'.length).replace(/\/$/, '');
      const data = await feed();
      const asset = download.resolve(data, wanted);
      if (!asset) {
        const body = Buffer.from(JSON.stringify({
          error: 'no such channel',
          channels: ['v3', 'v2', 'beta'],
          hint: 'the release feed may be empty; see https://github.com/MoLik-Labs/ZMRIG/releases',
        }));
        send(req, res, { status: 404, body, type: 'application/json; charset=utf-8', cache: 'no-store' });
        return;
      }
      res.writeHead(302, { ...BASE_HEADERS, Location: asset.url, 'Cache-Control': 'public, max-age=300', 'Content-Length': 0 });
      res.end();
      return;
    }

    if (url === '/download' || url === '/download/' || url === '/download/index.html') {
      const data = await feed();
      const state = renderDynamic(data);
      dynamic(req, res, state.html, {
        type: 'text/html; charset=utf-8',
        cache: 'public, max-age=0, must-revalidate',
        etag: state.etag,
      });
      return;
    }

    if (url === '/releases') {
      // The old name for the same page, and the one people type.
      res.writeHead(301, { ...BASE_HEADERS, Location: '/download', 'Cache-Control': 'public, max-age=86400', 'Content-Length': 0 });
      res.end();
      return;
    }

    // `/docs` is not a page in the build: Docusaurus writes `/docs/intro`, and
    // the build ships a `docs.html` stub that meta-refreshes to
    // `/ZMRIG/docs/intro` — correct on GitHub Pages, wrong on a host that
    // serves from its own root. Answering with a real redirect here means the
    // stub is never what a visitor on this host gets.
    const moved = { '/docs': '/docs/intro', '/docs/': '/docs/intro', '/docs.html': '/docs/intro', '/vi/docs': '/vi/docs/intro', '/vi/docs/': '/vi/docs/intro', '/vi/docs.html': '/vi/docs/intro' }[url];
    if (moved) {
      res.writeHead(301, { ...BASE_HEADERS, Location: moved, 'Content-Length': 0, 'Cache-Control': 'public, max-age=86400' });
      res.end();
      return;
    }

    const entry = table.files.get(url);
    if (entry) {
      const chosen = assets.pick(entry, req.headers['accept-encoding']);
      send(req, res, {
        body: chosen.body,
        encoding: chosen.encoding,
        type: entry.type,
        etag: entry.etag,
        cache: entry.cache,
      });
      return;
    }

    // Directory without its index: /docs/fleet -> /docs/fleet/ (and the
    // opposite), so a hand-typed URL lands on the page instead of a 404.
    if (!url.endsWith('/')) {
      const withSlash = table.files.get(`${url}/`);
      if (withSlash) {
        res.writeHead(301, { ...BASE_HEADERS, Location: `${url}/`, 'Content-Length': 0, 'Cache-Control': 'public, max-age=3600' });
        res.end();
        return;
      }
    }

    const fallback = table.notFound;
    if (fallback) {
      send(req, res, {
        status: 404,
        body: fallback.body,
        type: fallback.type,
        cache: 'no-store',
        etag: null,
      });
      return;
    }
    const body = Buffer.from('not found\n');
    res.writeHead(404, { ...BASE_HEADERS, 'Content-Type': 'text/plain; charset=utf-8', 'Content-Length': body.length });
    res.end(body);
  }

  return {
    handler: (req, res) => {
      handler(req, res).catch((error) => {
        log(`request failed: ${error.stack || error.message}`);
        if (!res.headersSent) {
          const body = Buffer.from('internal error\n');
          res.writeHead(500, { ...BASE_HEADERS, 'Content-Type': 'text/plain; charset=utf-8', 'Content-Length': body.length });
          res.end(body);
        } else {
          res.end();
        }
      });
    },
    table,
    arches: ARCHES,
  };
}

module.exports = { createApp, clean, encode };

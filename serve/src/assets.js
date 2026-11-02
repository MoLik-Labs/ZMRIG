// The file table the web host serves from.
//
// Everything is read once, at boot, into memory: the whole documentation site is
// a few megabytes and 179 files, which is smaller than the buffers Node would
// allocate to stream them one at a time. A request after that is a Map lookup, a
// pre-built header object and one `end()` — no `stat`, no `open`, no regexp.
//
// Compressed copies are kept next to the original (`.br`, `.gz`). `npm run
// build` writes them to disk so a deploy ships them; this module also makes them
// in memory when a sidecar is missing, which is what makes `npm start` on a bare
// checkout work without a build step.

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');

// Long enough to matter, short enough to read.
const IMMUTABLE = 'public, max-age=31536000, immutable';
const HTML = 'public, max-age=0, must-revalidate';
const MEDIA = 'public, max-age=604800';
const DATA = 'public, max-age=3600';

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.webmanifest': 'application/manifest+json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.gif': 'image/gif',
  '.ico': 'image/x-icon',
  '.woff2': 'font/woff2',
  '.woff': 'font/woff',
  '.txt': 'text/plain; charset=utf-8',
  '.xml': 'application/xml; charset=utf-8',
  '.map': 'application/json; charset=utf-8',
  '.wasm': 'application/wasm',
};

const COMPRESSIBLE = new Set(['.html', '.js', '.mjs', '.css', '.json', '.svg', '.txt', '.xml', '.map', '.webmanifest']);

// Below this a compressed copy costs more bytes than it saves, because every
// response already carries the headers that make it worth sending.
const MIN_COMPRESS = 1024;

function cacheControl(url) {
  // Docusaurus fingerprints everything under /assets/, so those can never
  // change and a browser may keep them forever.
  if (url.startsWith('/assets/')) return IMMUTABLE;
  if (url.endsWith('.html') || url === '/') return HTML;
  if (/\.(png|jpe?g|webp|gif|ico|svg|woff2?)$/.test(url)) return MEDIA;
  return DATA;
}

function contentType(file) {
  return TYPES[path.extname(file).toLowerCase()] || 'application/octet-stream';
}

function etagOf(stat) {
  return `"${stat.size.toString(16)}-${Math.floor(stat.mtimeMs).toString(16)}"`;
}

function walk(dir, out, root) {
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const entry of entries) {
    if (entry.name.startsWith('.')) continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      walk(full, out, root);
    } else if (entry.isFile()) {
      if (/\.(br|gz)$/.test(entry.name)) continue; // sidecars are not files of their own
      out.push(full);
    }
  }
  return out;
}

function readSidecar(file, suffix) {
  try {
    return fs.readFileSync(`${file}${suffix}`);
  } catch {
    return null;
  }
}

function load(root, { log = () => {}, compress = true } = {}) {
  const files = new Map();
  let raw = 0;
  let packed = 0;
  let notFound = null;

  for (const file of walk(root, [], root)) {
    const stat = fs.statSync(file);
    const body = fs.readFileSync(file);
    const rel = `/${path.relative(root, file).split(path.sep).join('/')}`;
    const type = contentType(file);
    const kind = path.extname(file).toLowerCase();

    const entry = {
      file: rel,
      size: stat.size,
      etag: etagOf(stat),
      type,
      cache: cacheControl(rel),
      body,
      br: null,
      gz: null,
    };
    raw += body.length;

    if (compress && COMPRESSIBLE.has(kind) && body.length >= MIN_COMPRESS) {
      try {
        entry.br = readSidecar(file, '.br') || zlib.brotliCompressSync(body, {
          params: {
            [zlib.constants.BROTLI_PARAM_QUALITY]: 11,
            [zlib.constants.BROTLI_PARAM_SIZE_HINT]: body.length,
          },
        });
        entry.gz = readSidecar(file, '.gz') || zlib.gzipSync(body, { level: 9 });
        // A compressed copy that is not smaller is a copy that makes the
        // response slower; drop it.
        if (entry.br.length >= body.length) entry.br = null;
        if (entry.gz.length >= body.length) entry.gz = null;
        packed += (entry.br ? entry.br.length : body.length);
      } catch (error) {
        log(`compress failed for ${rel}: ${error.message}`);
      }
    } else {
      packed += body.length;
    }

    if (rel === '/404.html') {
      notFound = entry;
      continue;
    }

    files.set(rel, entry);
    // `trailingSlash: false` means a page is written as docs/intro.html and
    // answers at /docs/intro. Register both spellings so neither 404s.
    if (rel.endsWith('/index.html')) {
      const dirUrl = rel.slice(0, -'index.html'.length);
      files.set(dirUrl, entry);
      files.set(`${dirUrl.replace(/\/$/, '')}`, entry);
    } else if (rel.endsWith('.html')) {
      files.set(rel.slice(0, -'.html'.length), entry);
    }
  }

  return { files, notFound, raw, packed, count: files.size };
}

function accepts(header, encoding) {
  if (!header) return false;
  const value = String(header).toLowerCase();
  if (encoding === 'br') return /(^|,)\s*br\b/.test(value) || value.includes('*');
  return /(^|,)\s*gzip\b/.test(value) || value.includes('*');
}

/** Pick the smallest representation the client can take. */
function pick(entry, acceptEncoding) {
  if (entry.br && accepts(acceptEncoding, 'br')) return { body: entry.br, encoding: 'br' };
  if (entry.gz && accepts(acceptEncoding, 'gzip')) return { body: entry.gz, encoding: 'gzip' };
  return { body: entry.body, encoding: null };
}

module.exports = { load, pick, accepts, cacheControl, contentType, etagOf, IMMUTABLE, HTML, MEDIA, DATA };

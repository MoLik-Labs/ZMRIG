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
//
// They are made on demand, not at boot. Compressing the whole table up front is
// fine on a laptop and wrong on the machine this actually runs on: a free Render
// instance is 0.1 CPU, and brotli at quality 11 over the site is minutes of work
// there, during which the health check fails and the deploy is rolled back. So
// boot does the cheap half - read, stat, hash - and each file is compressed the
// first time somebody asks for it, then kept. `warm()` in `app.js` does the first
// few for the visitor who arrives before the process has settled.

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

// Brotli's cost grows far faster than its gain. Against a 2 vCPU sandbox, a
// 300 KB bundle at quality 11 takes over a second and saves a low single-digit
// percentage over quality 9; on a free instance that is half a minute of one
// visitor's afternoon. The thresholds are where the two curves cross: small
// pages are cheap enough at 11 to be worth the best ratio, bundles are not.
function quality(size) {
  if (size <= 32 * 1024) return 11;
  if (size <= 256 * 1024) return 9;
  return 6;
}

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

function readSidecar(file, suffix, mtimeMs) {
  try {
    const stat = fs.statSync(`${file}${suffix}`);
    // A sidecar older than the file it belongs to came from a previous build.
    // Serving it would pin a page to content that no longer exists, with an
    // ETag that matches the new file - the worst of both, and invisible until
    // somebody notices the site is a version behind.
    if (mtimeMs && stat.mtimeMs < mtimeMs) return null;
    return fs.readFileSync(`${file}${suffix}`);
  } catch {
    return null;
  }
}

/**
 * Make one representation of one file, if it is worth having.
 *
 * A sidecar from the build wins: it was made once, by a machine that had the
 * time, and shipping it means a deploy does no compression at all. Otherwise it
 * is done here, once, under the quality policy above.
 */
function make(entry, encoding, log) {
  const suffix = encoding === 'br' ? '.br' : '.gz';
  const sidecar = entry.rebased ? null : readSidecar(entry.path, suffix, entry.mtime);
  if (sidecar) return sidecar.length < entry.body.length ? sidecar : null;
  try {
    const body =
      encoding === 'br'
        ? zlib.brotliCompressSync(entry.body, {
            params: {
              [zlib.constants.BROTLI_PARAM_QUALITY]: quality(entry.body.length),
              [zlib.constants.BROTLI_PARAM_SIZE_HINT]: entry.body.length,
            },
          })
        : zlib.gzipSync(entry.body, { level: entry.body.length <= 256 * 1024 ? 9 : 6 });
    // A compressed copy that is not smaller is a copy that makes the response
    // slower; drop it.
    return body.length < entry.body.length ? body : null;
  } catch (error) {
    log(`compress failed for ${entry.file}: ${error.message}`);
    return null;
  }
}

/**
 * Fill in the representations this client can read, and only those: a browser
 * that asked for brotli never causes a gzip copy to exist, which is half the CPU
 * of the eager version for the same bytes on the wire.
 */
function pack(entry, encoding, log = () => {}) {
  if (!entry.packable) return entry;
  if (encoding === 'br') {
    if (!entry.triedBr) {
      entry.triedBr = true;
      entry.br = make(entry, 'br', log);
    }
  } else if (encoding === 'gzip') {
    if (!entry.triedGz) {
      entry.triedGz = true;
      entry.gz = make(entry, 'gzip', log);
    }
  }
  return entry;
}

/**
 * Make a build that was made for a subdirectory work at the root of a domain.
 *
 * `site/` is built for GitHub Pages, which serves it from `/ZMRIG/`, and the
 * committed `web/` is that build. Everything a page links to — the stylesheet,
 * the bundles, every internal link, the icon — is therefore written `/ZMRIG/...`,
 * and a host serving `web/` from its own root answers 404 for all of it: the
 * page arrives, unstyled and inert, and the only visible symptom is a site that
 * looks wrong in a screenshot nobody takes.
 *
 * Rebuilding for the host is the documented answer and still works
 * (`SITE_BASE_URL=/`), but a deploy should not be able to land in that state by
 * accident, and the committed build is one build, not two. So the prefix is
 * detected from the HTML itself and removed in memory, once, at boot: 64 files
 * and about 3 600 references, 20 ms, and every route is then the same route on
 * both hosts. Absolute URLs are untouched — only a quote or a parenthesis
 * directly before the prefix makes a reference root-relative.
 */
function rebase(table, log = () => {}) {
  const probe = table.files.get('/index.html') || table.files.get('/');
  if (!probe || !probe.body) return '';
  const found = probe.body.toString('utf8').match(/["'(](\/[^"'/]+)\/(?:assets|img|docs)\//);
  const prefix = found ? found[1] : '';
  if (!prefix || prefix === '' || !/^\/[A-Za-z0-9._-]+$/.test(prefix)) return '';

  const pattern = new RegExp(`(["'(])${prefix.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}/`, 'g');
  let files = 0;
  let replaced = 0;
  for (const entry of new Set(table.files.values())) {
    if (!/text\/|json|javascript/.test(entry.type)) continue;
    const before = entry.body.toString('utf8');
    if (!before.includes(`${prefix}/`)) continue;
    let hits = 0;
    const after = before.replace(pattern, (_match, quote) => {
      hits += 1;
      return `${quote}/`;
    });
    if (!hits) continue;
    entry.body = Buffer.from(after);
    entry.rebased = true;
    entry.size = entry.body.length;
    entry.etag = `"${entry.mtime.toString(16)}-r${entry.body.length.toString(16)}"`;
    entry.br = null;
    entry.gz = null;
    entry.triedBr = false;
    entry.triedGz = false;
    files += 1;
    replaced += hits;
  }
  if (files) log(`rebase   ${prefix}/ -> / in ${files} files (${replaced} references)`);
  return prefix;
}

function load(root, { log = () => {}, compress = true } = {}) {
  const files = new Map();
  let raw = 0;
  let notFound = null;

  for (const file of walk(root, [], root)) {
    const stat = fs.statSync(file);
    const body = fs.readFileSync(file);
    const rel = `/${path.relative(root, file).split(path.sep).join('/')}`;
    const type = contentType(file);
    const kind = path.extname(file).toLowerCase();

    const entry = {
      file: rel,
      mtime: stat.mtimeMs,
      size: stat.size,
      etag: etagOf(stat),
      type,
      cache: cacheControl(rel),
      body,
      // Read lazily by `pack()`. A file that nobody opens costs nothing.
      packable: Boolean(compress && COMPRESSIBLE.has(kind) && body.length >= MIN_COMPRESS),
      // Set by `rebase()` when the bytes in memory no longer match the file on
      // disk. A sidecar belongs to the file, so it must not be used for one.
      rebased: false,
      br: null,
      gz: null,
      triedBr: false,
      triedGz: false,
    };
    raw += body.length;
    // Where it came from, so a sidecar can be found and its mtime compared. Not
    // enumerable: this object is logged and asserted on, and an absolute path
    // from the build machine has no business in either.
    Object.defineProperty(entry, 'path', { value: file });

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

  const table = { files, notFound, raw, count: files.size };

  // The bytes the table actually holds, which grows as files are asked for. This
  // is the number worth reporting: it says how much memory the site costs and how
  // much of it has been compressed so far. `entries()` de-duplicates, because a
  // page is reachable under two URLs and is one buffer.
  const entries = () => new Set(files.values());
  Object.defineProperty(table, 'packed', {
    get() {
      let total = 0;
      for (const entry of entries()) total += (entry.br || entry.gz || entry.body).length;
      return total;
    },
  });
  Object.defineProperty(table, 'packedCount', {
    get() {
      let total = 0;
      for (const entry of entries()) if (entry.br || entry.gz) total += 1;
      return total;
    },
  });
  return table;
}

// `Accept-Encoding` is a weighted list: `br;q=0` means "anything but brotli",
// and `*` is the fallback for encodings that are not named. Matching on the
// bare word is easy and wrong - a client that says `gzip;q=0, identity` must
// get the uncompressed body, and a proxy that says `gzip;q=0.1, identity;q=0`
// has to get gzip even though it asked for it last.
function weights(header) {
  const out = new Map();
  if (!header) return out;
  for (const part of String(header).toLowerCase().split(',')) {
    const [rawName, ...params] = part.split(';');
    const name = rawName.trim();
    if (!name) continue;
    let q = 1;
    for (const param of params) {
      const [key, value] = param.split('=');
      if (String(key).trim() !== 'q') continue;
      const parsed = Number.parseFloat(value);
      q = Number.isFinite(parsed) ? Math.min(Math.max(parsed, 0), 1) : 0;
    }
    out.set(name, q);
  }
  return out;
}

function accepts(header, encoding) {
  const map = weights(header);
  const direct = map.get(encoding);
  if (direct !== undefined) return direct > 0;
  const star = map.get('*');
  return star !== undefined && star > 0;
}

/** RFC 9110 12.5.3: identity is acceptable unless it is refused by name or by `*`. */
function identityAllowed(header) {
  const map = weights(header);
  const direct = map.get('identity');
  if (direct !== undefined) return direct > 0;
  if (map.has('*')) return map.get('*') > 0;
  return true;
}

/** Pick the smallest representation the client can take. */
function pick(entry, acceptEncoding, log) {
  if (entry.packable) {
    const br = accepts(acceptEncoding, 'br');
    const gzip = accepts(acceptEncoding, 'gzip');
    if (br) pack(entry, 'br', log);
    else if (gzip) pack(entry, 'gzip', log);
    else if (!identityAllowed(acceptEncoding)) pack(entry, 'br', log);
  }
  if (entry.br && accepts(acceptEncoding, 'br')) return { body: entry.br, encoding: 'br' };
  if (entry.gz && accepts(acceptEncoding, 'gzip')) return { body: entry.gz, encoding: 'gzip' };
  // `identity;q=0` with nothing else acceptable: a compressed body the client
  // very likely still decodes beats a 406 with nothing in it.
  if (!identityAllowed(acceptEncoding)) {
    if (entry.br) return { body: entry.br, encoding: 'br' };
    if (entry.gz) return { body: entry.gz, encoding: 'gzip' };
  }
  return { body: entry.body, encoding: null };
}

module.exports = { load, rebase, pack, make, pick, quality, accepts, identityAllowed, weights, cacheControl, contentType, etagOf, IMMUTABLE, HTML, MEDIA, DATA };

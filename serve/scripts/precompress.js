#!/usr/bin/env node
// Write `.br` and `.gz` next to every text file the site serves.
//
// The server can compress in memory at boot, but doing it at build time means a
// deploy starts serving immediately and the compressed bytes are the same on
// every instance. Run after `docusaurus build`:
//
//   node scripts/precompress.js [root]     (default: ../site/build)

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');

const COMPRESSIBLE = new Set(['.html', '.js', '.mjs', '.css', '.json', '.svg', '.txt', '.xml', '.map', '.webmanifest']);
const MIN = 1024;

function walk(dir, out) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name.startsWith('.')) continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full, out);
    else if (entry.isFile() && !/\.(br|gz)$/.test(entry.name)) out.push(full);
  }
  return out;
}

function main() {
  const root = path.resolve(process.argv[2] || path.join(__dirname, '..', '..', 'site', 'build'));
  if (!fs.existsSync(root)) {
    console.error(`no such directory: ${root}`);
    process.exit(1);
  }

  let files = 0;
  let raw = 0;
  let br = 0;
  let gz = 0;

  for (const file of walk(root, [])) {
    if (!COMPRESSIBLE.has(path.extname(file).toLowerCase())) continue;
    const body = fs.readFileSync(file);
    if (body.length < MIN) continue;

    const brotli = path.join(path.dirname(file), `${path.basename(file)}.br`);
    const gzip = path.join(path.dirname(file), `${path.basename(file)}.gz`);

    const brotliBody = zlib.brotliCompressSync(body, {
      params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 11, [zlib.constants.BROTLI_PARAM_SIZE_HINT]: body.length },
    });
    const gzipBody = zlib.gzipSync(body, { level: 9 });

    // Never write a copy that is bigger than the original.
    if (brotliBody.length < body.length) fs.writeFileSync(brotli, brotliBody);
    if (gzipBody.length < body.length) fs.writeFileSync(gzip, gzipBody);

    files += 1;
    raw += body.length;
    br += Math.min(brotliBody.length, body.length);
    gz += Math.min(gzipBody.length, body.length);
  }

  const mb = (n) => (n / 1048576).toFixed(1);
  console.log(`precompressed ${files} files: ${mb(raw)} MB -> ${mb(br)} MB brotli / ${mb(gz)} MB gzip`);
}

main();

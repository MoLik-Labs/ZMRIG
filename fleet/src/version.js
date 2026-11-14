// The fleet's version is the repository's version, read once.
//
// Two places used to spell it out: the dashboard footer said 6.44.0 and the
// Discord user agent said 6.37 while the release was 6.48, because a constant
// in source only moves when somebody remembers. `package.json` at the root is
// bumped by the release process, so it is the only copy worth keeping, and
// tests/version.test.js fails if this file and that one disagree.

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const FALLBACK = '6.48.0';

function read() {
  // src/ -> fleet/ -> repository root. A deployment that copies only `fleet/`
  // gets the fallback rather than an exception, because a version string is
  // not worth refusing to start over.
  const candidate = path.join(__dirname, '..', '..', 'package.json');
  try {
    const parsed = JSON.parse(fs.readFileSync(candidate, 'utf8'));
    if (parsed && typeof parsed.version === 'string' && parsed.version) return parsed.version;
  } catch (_) {
    /* fall through */
  }

  return FALLBACK;
}

const VERSION = read();

module.exports = { VERSION, FALLBACK, read };

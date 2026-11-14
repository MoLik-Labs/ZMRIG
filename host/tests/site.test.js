// Every link the committed site offers, followed.
//
// The unit tests in `serve/tests` prove the handler; this proves the build. The
// failure it exists for is the one that shipped: the committed `web/` is the
// GitHub Pages build, every reference in it is `/ZMRIG/...`, and a host serving
// from its own root answered 404 for the stylesheet, the bundles and every
// internal link — a site that renders and does nothing. Nothing threw, no test
// failed, and the only symptom was visible in a browser.
//
// It runs against `web/` when that directory exists (it is committed, so it
// does), and skips when the tree was built without it.

'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const host = require('../server');

const ROOT = path.resolve(__dirname, '..', '..', 'web');
const HAVE_SITE = fs.existsSync(path.join(ROOT, 'index.html'));

test('every internal link in the committed build resolves', { skip: !HAVE_SITE && 'web/ is not in this tree' }, async () => {
  const state = path.join(os.tmpdir(), `zmrig-site-test-${process.pid}.json`);
  const built = host.createServer(
    { FLEET_QUIET: '1', FLEET_STATE: state },
    { siteRoot: ROOT, releases: { latest: () => Promise.resolve({ fetchedAt: 1, stable: null, beta: null, error: null }) } },
  );
  const server = built.server;
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;

  try {
    // The page set is the table's own, not a crawl: a link only reachable from a
    // page is still a link, and the table is every file the host will answer.
    const pages = [...new Set(built.site.table.files.keys())]
      .filter((route) => route.endsWith('.html') || route.endsWith('/'));
    assert.ok(pages.length > 20, `expected the whole site, found ${pages.length} pages`);

    const checked = new Set();
    const broken = [];
    const unreachable = [];

    for (const page of pages) {
      const response = await fetch(`${base}${page}`, { redirect: 'manual' });
      // 301 is a real answer here: the build ships `docs.html` stubs that the
      // host deliberately redirects, and answering them with a redirect is the
      // whole point of the stub not being served.
      if (response.status !== 200 && response.status !== 301) {
        // 404.html is a document, not a route: the host deliberately answers
        // `/404` with the not-found page and a 404, which is the correct answer.
        if (!/404\/?$/.test(page)) unreachable.push(`${page} -> ${response.status}`);
        continue;
      }
      if (!(response.headers.get('content-type') || '').includes('text/html')) continue;

      const html = await response.text();
      for (const match of html.matchAll(/(?:href|src)="(\/[^"]*)"/g)) {
        const href = match[1].split('#')[0].split('?')[0];
        if (!href || href === '/' || checked.has(href)) continue;
        checked.add(href);
        const target = await fetch(`${base}${href}`, { redirect: 'manual' });
        if (target.status >= 400 && !/^\/404$/.test(href)) broken.push(`${page} -> ${href} (${target.status})`);
      }
    }

    assert.deepStrictEqual(unreachable, [], 'every page in the build is served');
    assert.deepStrictEqual(broken, [], `every link resolves: ${broken.slice(0, 5).join(', ')}`);
    // Every page shares the same navigation, so the unique count is far smaller
    // than the number of links: 73 distinct same-origin references across 61
    // pages, which is the whole site. A number this small is the point — the
    // figure that matters is `broken`, and this only catches a crawl that
    // followed nothing at all.
    assert.ok(checked.size > 40, `expected to follow the whole site, followed ${checked.size}`);
  } finally {
    await new Promise((resolve) => server.close(resolve));
    fs.rmSync(state, { force: true });
  }
});

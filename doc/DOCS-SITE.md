# The documentation site

The site at <https://nggkhaiz.github.io/ZMRIG/docs/intro> is a Docusaurus 3
project in [`site/`](../site). It is two locales (English is the default,
Vietnamese is a full translation), one sidebar with a fixed order, and three
calculators that run in the browser.

This page covers what only a maintainer needs: how the site is published given
this repository's Pages configuration, how to turn on Algolia DocSearch, and
which files are generated and must not be edited by hand.

## How it is published

Two deployments point at the same URL. `Deploy site`
(`.github/workflows/pages.yml`) uploads `web/` as the Pages artifact; GitHub's
own *pages build and deployment* publishes the branch root, because
**Settings → Pages → Source** is still *Deploy from a branch*. Whichever runs
last wins, so `scripts/publish-site.sh` writes the same build to both and
`--check` fails the moment they disagree:

```bash
./scripts/publish-site.sh            # build in site/, copy to web/ and the root
./scripts/publish-site.sh --check    # fail if either copy is stale
```

`web/` is replaced whole — a stale asset cannot survive a deploy. In the
repository root only the paths Docusaurus owns are replaced (`index.html`,
`404.html`, `search.html`, `search-index.json`, `sitemap.xml`, `robots.txt`,
`assets/`, `docs/`, `vi/`, `img/`), so nothing a human wrote can be lost.

`web/wizard.html` and `web/docs.html` are not part of the build: they come from
`site/static/` and redirect old links (`/ZMRIG/wizard.html?pool=c3pool`) into the
documentation. The previous hand-written site is kept at `legacy/`, which is
never uploaded.

`tests/docs/pages.sh` fails if either copy differs from `site/build`, so a
content change that was not published cannot be merged silently. Switching the
Pages source to *GitHub Actions* would make the root copy unnecessary; the
settings are in [`doc/SETUP.md`](SETUP.md) §4a.

## Working on it

```bash
cd site
npm install          # once
npm start            # http://localhost:3000/ZMRIG/
npm run build        # both locales; throws on a broken link
npm test             # unit tests for the builders, calculators and i18n
```

`npm run build` is the real check: `onBrokenLinks` and
`onBrokenMarkdownLinks` are both `throw`, so a page that was renamed without
updating its links fails the build rather than shipping a 404.

### Layout

```text
site/
├── docusaurus.config.js    locales, baseUrl, navbar, footer, search
├── sidebars.js             one ordered sidebar; every page is listed by id
├── docs/                   English pages (the source of truth for facts)
├── i18n/vi/                Vietnamese pages + theme strings
├── src/lib/                pools, coins, command builder, report codes, messages
├── src/components/         PoolTable, InstallBuilder, ProfitCalculator,
│                           CoinMatrix, CopyButton
├── src/theme/              ColorModeToggle: system / light / dark
├── src/pages/index.jsx     the home page
├── static/img/             logo and the donation QR
└── tests/                  command, report, pools, i18n
```

`src/lib/*.mjs` is deliberately free of React and of the DOM: the components
render it and `site/tests/*.test.mjs` calls it directly, so the page and the
tests cannot disagree about what a command or a payout means.

`src/lib/coins.mjs` is the one list of coins behind the builder, the calculator
and the docs page. It carries the algorithm each coin is mined with, the address
shape this repository can actually check, and network defaults — which only
Monero has. A coin without numbers is `null`, never a plausible-looking guess:
`rankCoins` reports the fields a row is missing so the table can say "missing
network hashrate" instead of drawing a zero that reads like $0.00/day. Adding a
coin means editing that file and the two pages under `docs/pools/coins.mdx`;
`site/tests/coins.test.mjs` fails if the new entry claims an algorithm no engine
implements, ships a pool preset for a non-Monero coin, or invents a price.

## Search: Algolia DocSearch

The site is built to use DocSearch and ships with a local index only as a
fallback for the period before the application is approved. Both produce exactly
one search box in the navbar — never two.

1. Apply at <https://docsearch.algolia.com/apply> with:
   - URL: `https://nggkhaiz.github.io/ZMRIG/`
   - email: the address you read
   - repository: `https://github.com/NggKhaiz/ZMRIG`
2. When the crawler is approved, Algolia issues three values: `appId`,
   `apiKey` (the **search-only** key) and `indexName`.
3. Put them in the build environment, not in the repository:

   ```bash
   cd site
   ALGOLIA_APP_ID=XXXXXXXXXX \
   ALGOLIA_API_KEY=0123456789abcdef0123456789abcdef \
   ALGOLIA_INDEX_NAME=zmrig \
   npm run build
   cd .. && ./scripts/publish-site.sh
   ```

   `scripts/publish-site.sh` runs `npm run build` itself, so export the three
   variables before calling it.
4. `docusaurus.config.js` attaches `themeConfig.algolia` only when all three
   exist; otherwise `@easyops-cn/docusaurus-search-local` builds the local index
   that is in `search-index.json` today.

The keys are public by design — a search-only key can only query. They are not
committed because every rebuild would otherwise ship a stale index name.

Search is a build-time feature: the crawler indexes the *published* pages, so it
will not see a page until that page has been published at least once.

## Language

English is the default and is served at `/ZMRIG/`; Vietnamese is served at
`/ZMRIG/vi/`. The switch is the `localeDropdown` in the navbar.

A page is translated by copying it to the same relative path under
`site/i18n/vi/docusaurus-plugin-content-docs/current/`. `site/tests/i18n.test.mjs`
checks that

- every English page has a Vietnamese counterpart and vice versa,
- each keeps its front matter, `slug` and component imports,
- the four theme JSON files are translated rather than left in English.

Adding a page therefore means two files plus one line in `sidebars.js`.

## Theme

`src/theme/ColorModeToggle/index.js` replaces Docusaurus' two-state switch with
three buttons — **Hệ thống / System**, **Sáng / Light**, **Tối / Dark** — because
a visitor who once picked "dark" could otherwise never return to following the
system. Docusaurus already stores `null` for that choice; the component exposes
it. `docusaurus.config.js` sets `defaultMode: "light"` and
`respectPrefersColorScheme: true`, so a first visit follows the operating system.

## The mark

One geometry, drawn once and reused: `site/tools/make-logo.py` writes
`logo.svg` (black), `logo-dark.svg` (white), `favicon.svg` and the three PNG
icons; `site/tools/make-art.py` pastes the same render into the social cards.

```bash
python3 site/tools/make-logo.py     # the mark, all formats
python3 site/tools/make-art.py      # the social cards, which use it
```

The shape is a bold **Z sitting on a wave**: bar, diagonal, bar, with the lower
edge of the bottom bar rising and falling like a water line. The name is ZMRIG,
the miner is written in Zig — a bold zigzag is the shape both words already
share — and the rig swims in the pool and the proxy, so the base of the letter is
water. The wave is part of the same outline rather than a second element next to
it: a stroke drawn under the letter would be a smudge at 16 px and a seam at
32 px, and a wave drawn *inside* the stroke (a curved diagonal, a split stem, a
ring) stops reading as a letter at all.

One tone only, because a mark that needs an accent colour is a mark that changes
its meaning in a dark theme. The straight parts are whole and half units on a 32
unit grid, so the 16, 32 and 48 pixel renders land on pixels instead of on grey
fringes; the water line is sampled from a sine at a fixed step so it stays the
same curve in the SVG, the PNGs and the social cards.

Light and dark pages get the same file in opposite tones (`logo.svg` /
`logo-dark.svg`), the navbar swaps them with `srcDark`, the home page swaps them
with `.zm-mark--light` / `.zm-mark--dark`, and `favicon.svg` picks its tone from
`prefers-color-scheme` so it survives either tab bar.

Both copies of `static/img` are committed — `site/static/img/` for the build and
`img/` for the branch-root mirror — and `scripts/publish-site.sh` keeps them
identical.

## Social previews

Two 1200×630 cards exist, `site/static/img/og-en.png` and `og-vi.png`. They are
generated, not drawn by hand:

```bash
python3 site/tools/make-art.py
```

The script reads the pool rows out of `site/src/lib/pools.mjs`, so the card
quotes the same fees and endpoints the page does. Vietnamese needs
`DejaVu Sans` — the mono face on this machine has no Latin Extended Additional,
and the diacritics come out as empty boxes.

`themeConfig` sets **no** `image`. A theme-level default is not locale-aware, so
every Vietnamese page previewed with the English card; a root-relative path is
also resolved against the locale base (`/ZMRIG/vi/img/…`), which Docusaurus
fills with a second copy of every static file. Instead every page carries an
absolute URL in its front matter:

```yaml
image: https://nggkhaiz.github.io/ZMRIG/img/og-vi.png
```

The home page sets the same tags in `src/pages/index.jsx` (`Layout` in
Docusaurus 3 takes only `title` and `description`). If the site moves to a
custom domain, those 42 front-matter lines and the two constants in
`src/pages/index.jsx` are what has to change — `grep -rn "og-" site/docs
site/i18n site/src` finds them.

## Manual settings this repository still needs

These cannot be done by a token and are the only steps left for a maintainer:

| Setting | Where | Value |
| --- | --- | --- |
| Pages source | Settings → Pages | Deploy from a branch → `BETA` → `/` |
| Custom domain (optional) | Settings → Pages | add it, then change `url` in `site/docusaurus.config.js` and republish |
| DocSearch application | docsearch.algolia.com/apply | see above |
| Repository topics | Settings | `monero`, `miner`, `randomx`, `zig` |

Everything else — the build, the tests, the published files — runs from the
repository.

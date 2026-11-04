# ZMRIG web host

The documentation site, the download page, the release feed and three links that
always point at the newest image — in one Node process with no dependencies.

This package is the site on its own. The deployment this project ships is one
level up, in [`host/`](../host/server.js), which mounts this handler and the
fleet's device protocol on the same port so that one free Render instance covers
both. Everything here is still the thing that answers a page request.

```
/                      the documentation (English)
/vi/                   the documentation (Vietnamese)
/download              stable and beta, sizes, checksums, dd and sha256sum
/api/releases.json     the same data for a script
/iso/v3 /iso/v2        -> 302 to the newest asset on that channel
/iso/beta
/docs                  -> 301 to /docs/intro (what people type)
/healthz               file count, bytes, RSS, uptime
```

## Run it

```bash
cd ../site && npm install && npm run build && cd ../serve
cp .env.example .env          # every value in it is already the default
npm start                     # http://localhost:8080
npm test                      # 46 checks, no network
```

`npm run build` writes the `.br`/`.gz` copies at deploy time so the first request
after a restart does not pay for compression. Without them each file is
compressed the first time it is asked for — not at boot, because the machine this
runs on is a tenth of a CPU and compressing a whole site there is what turns a
deploy into a failed health check. A sidecar older than its file is ignored
either way, so a stale one cannot serve last build's HTML under this build's
`ETag`.

The site is built for GitHub Pages under `/ZMRIG/`. This host serves from the
root of its own domain, so build it with the base URL overridden:

```bash
cd ../site && SITE_BASE_URL=/ SITE_URL=https://zmrig.example.com \
  SITE_DOWNLOAD_URL=https://zmrig.example.com/download npx docusaurus build
```

## Environment

| variable | default | |
| --- | --- | --- |
| `PORT` | `8080` | Render sets it |
| `HOST` | `0.0.0.0` | |
| `SITE_ROOT` | `site/build` | the built site |
| `GITHUB_REPO` | `MoLik-Labs/ZMRIG` | owner/name for the release feed |
| `GITHUB_API` | `https://api.github.com` | for tests and GitHub Enterprise |
| `RELEASES_TTL` | `600000` | ten minutes, well inside the anonymous rate limit |
| `PUBLIC_URL` | `RENDER_EXTERNAL_URL` | what `/download` prints as copyable links |
| `ZMRIG_VERSION` | `package.json` | shown in the page footer |

No secrets: the release feed is read anonymously. `.env.example` is the same
table with the details; copy it and nothing else is needed.

A rig or a script on a network where `api.github.com` is blocked can ask this
service instead:

```bash
./scripts/latest-iso.sh --host https://your-host
```

## Why it is fast

Every file of the built site is read into memory at boot: 244 routes, 6.84 MB, in
17 ms. A request after that is a Map lookup, a pre-built header set and one
`end()`. Brotli and gzip are made on demand — at deploy by `node
scripts/precompress.js`, or on the first request for that file, with the quality
chosen from its size (11 up to 32 KB, 9 up to 256 KB, 6 above). A browser that
accepts brotli never causes a gzip copy to exist. Every response carries an
`ETag`; a conditional request is answered with `304` before the body is touched.
Fingerprinted assets are `immutable` for a year, HTML revalidates.

Measured on a 2 vCPU machine, keep-alive, 60 requests per route: `/` 0.34 ms p50 /
1.12 ms p95 after a 31.0 ms first request, `/docs/intro` 0.31 ms after 33.5 ms,
`/vi/` 0.26 ms after 22.1 ms, eight concurrent 3.49 ms p50. The first request for
a file pays for its compression, once. Nothing has been measured on Render
itself.

## When GitHub is unreachable

The feed keeps the last good answer and the page says so. If it has never been
reachable, the page says that too, the links it has still work, and `/iso/*`
answers `404` instead of redirecting into nothing.

`doc/WEB.md` has the operator notes. The repository root's `render.yaml` runs
[`host/server.js`](../host/server.js), which is this handler plus the fleet on one
port; there is no separate site service, because a free workspace only fits one
always-on instance and the site is the cheapest of the three jobs to carry.

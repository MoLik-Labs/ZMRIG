# ZMRIG web host

The documentation site, the download page, the release feed and three links that
always point at the newest image — in one Node process with no dependencies.

```
/                      the documentation (English)
/vi/                   the documentation (Vietnamese)
/download              stable and beta, sizes, checksums, dd and sha256sum
/api/releases.json     the same data for a script
/iso/v3 /iso/v2        -> 302 to the newest asset on that channel
/iso/beta
/healthz               file count, bytes, RSS, uptime
```

## Run it

```bash
cd ../site && npm ci && npm run build && cd ../serve
npm start                     # http://localhost:8080
npm test                      # 39 checks, no network
```

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
| `ZMRIG_VERSION` | | shown in the page footer |

No secrets: the release feed is read anonymously.

## Why it is fast

Every file of the built site is read into memory at boot (238 routes, 6.31 MB raw,
1.63 MB compressed). A request after that is a Map lookup, a pre-built header set
and one `end()`. Brotli and gzip are written once — at deploy by
`node scripts/precompress.js`, or at boot when a sidecar is missing — and chosen
per request. Every response carries an `ETag`; a conditional request is answered
with `304` before the body is touched. Fingerprinted assets are `immutable` for a
year, HTML revalidates.

Measured on a 2 vCPU machine, keep-alive, warm: `/` 0.25 ms p50 / 0.81 ms p95,
`/docs/intro` 0.19 ms, an asset 0.35 ms, eight concurrent 0.89 ms p50. Nothing has
been measured on Render itself.

## When GitHub is unreachable

The feed keeps the last good answer and the page says so. If it has never been
reachable, the page says that too, the links it has still work, and `/iso/*`
answers `404` instead of redirecting into nothing.

`doc/WEB.md` has the operator notes; `render.yaml` in the repository root deploys
this alongside the pool.

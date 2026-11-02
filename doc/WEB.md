# Hosting the site and the downloads yourself

`serve/` is the web host: one Node process, no dependencies, no build step of
its own. It serves the documentation that Docusaurus produces, a download page
built from the GitHub releases API, that same data as JSON, and three links that
always point at the newest image.

You do not need it to use ZMRIG — GitHub Pages serves the same documentation and
GitHub serves the images. It exists for three reasons: a link that does not
change when a version does (`/iso/v3`), a download page that lists every asset
with its checksum without a redeploy, and a place to put the site on your own
domain when GitHub Pages is blocked or too slow where your users are.

## Run it

```bash
cd site && npm install && npm run build && cd ..   # the documentation
cd serve && npm start                          # http://localhost:8080
```

`npm start` reads the built site from `site/build`. Two environment variables are
worth knowing before you deploy, and both have sensible defaults:

```bash
PORT=8080                 # Render sets this
SITE_ROOT=site/build
GITHUB_REPO=MoLik-Labs/ZMRIG
RELEASES_TTL=600000       # ten minutes
PUBLIC_URL=https://zmrig.example.com   # what /download prints as copyable links
```

## Deploy on Render

`render.yaml` in the repository root is a blueprint with two services: the pool
and this host. *New → Blueprint*, pick the repository, and Render builds the
documentation with `SITE_BASE_URL=/` (the host serves from its own root, not from
`/ZMRIG/`), precompresses every page and asset, and starts the server.

Nothing in it is a secret. The GitHub API is read anonymously, and the feed is
cached for ten minutes: at most 60 calls an hour, comfortably inside the
unauthenticated rate limit even with a lot of visitors.

Free instances sleep after fifteen minutes without traffic. A sleeping site wakes
on the next request in about a second, which is acceptable for a download page;
if you want it always warm, point any free uptime monitor at `/healthz` every
five minutes.

## What it answers

| path | |
| --- | --- |
| `/` | the documentation, English |
| `/vi/` | the documentation, Vietnamese |
| `/download` | stable and beta, sizes, checksums, `dd` and `sha256sum` lines |
| `/api/releases.json` | the same data for a script |
| `/iso/v3` `.../v2` `.../beta` | 302 to the newest asset on that channel |
| `/healthz` | file count, bytes, RSS, uptime — small and uncached |

`/iso/*` reads the release feed, which is cached, so a redirect costs one Map
lookup. Point a script at it and it never has to know a version:

```bash
curl -L -O https://zmrig.example.com/iso/v3
```

## Why it is fast

The whole point is that a request for a page is a memory read. At boot the server
reads every file of the built site into memory once — 179 files, 238 routes once
the extensionless spellings are counted, 6.31 MB, 1.63 MB after compression — and
keeps a pre-built header set for each. After that:

* **No filesystem syscall per request** — no `stat`, no `open`, no `readdir`.
* **Brotli and gzip are generated once**, at boot if no `.br`/`.gz` sidecar
  exists, or at deploy time by `npm run build` in `serve/`. A request picks one
  and sets `Content-Encoding` and `Vary`.
* **`ETag` on everything**, and a conditional request is answered before a byte
  of the body is touched: `304 Not Modified` with no body.
* **Fingerprinted assets are `immutable`** with a one-year lifetime, because
  Docusaurus hashes their names; HTML revalidates, so a deploy is visible on the
  next page load.
* **Keep-alive is held for 65 seconds**, so a page and its twelve assets use one
  connection.
* **The release feed is fetched once per ten minutes**, not once per visit, and
  the rendered download page is cached against the feed's timestamp.

Measured on the development machine (2 vCPU), 300 requests each, HTTP keep-alive,
warm cache:

| path | p50 | p95 |
| --- | ---: | ---: |
| `/` | 0.25 ms | 0.81 ms |
| `/docs/intro` | 0.19 ms | 0.34 ms |
| a fingerprinted JS asset | 0.35 ms | 0.63 ms |
| eight at a time, `/docs/intro` | 0.89 ms | 4.92 ms |

Brotli takes the home page from 16 KB to 3.9 KB. These numbers are from this
machine; a Render instance has different CPU and a real network in front of it,
and nothing here has been measured there.

`/healthz` reports the actual figures for the process that is running:

```json
{"ok":true,"files":238,"bytes":6614860,"compressed_bytes":1711249,"uptime_s":3600,"rss_mb":38}
```

The first three numbers are the table this process loaded; `rss_mb` is the whole
Node process and depends on the instance.

## When GitHub is unreachable

The feed keeps the last good answer and says so on the page. If GitHub has never
been reachable since the process started, `/download` says that too and the links
it has still work; `/iso/*` answers `404` rather than redirecting into nothing.
Nothing 500s because a third party is down.

## Tests

```bash
cd serve && npm test        # 39 checks
```

The suite covers the file table, negotiation, the 304 path, traversal attempts,
HTML escaping of anything that comes from GitHub, a `javascript:` URL in a
release asset, the three redirects, a feed that fails, and the real process
booting and shutting down on a socket.

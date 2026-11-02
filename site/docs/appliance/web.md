---
title: Host the site and the downloads
description: One Node process serves the documentation, a download page built from GitHub releases, a JSON feed and permanent links to the newest image — no dependencies, no build step of its own.
image: https://molik-labs.github.io/ZMRIG/img/og-en.png
---

# Host the site and the downloads

GitHub Pages serves this documentation and GitHub serves the images, so nothing
here is required. `serve/` exists because three things are nicer on your own
host: a link that does not change when a version does, a download page that
always lists the current asset with its checksum, and a site that works where
GitHub Pages is blocked or slow.

One Node process, no dependencies, no build step of its own.

```bash
cd site && npm ci && npm run build && cd ..
cd serve && npm start          # http://localhost:8080
```

## What it answers

| path | |
| --- | --- |
| `/` | the documentation, English |
| `/vi/` | the documentation, Vietnamese |
| `/download` | stable and beta with sizes, checksums, `dd` and `sha256sum` |
| `/api/releases.json` | the same data for a script |
| `/iso/v3` `.../v2` `.../beta` | 302 to the newest asset on that channel |
| `/healthz` | file count, bytes, RSS, uptime |

```bash
curl -L -O https://your-host/iso/v3     # always the newest v3 image
```

`/iso/*` resolves through the release feed, which is cached, so a redirect is a
Map lookup and a `302`. That is the whole point: a script, a Ventoy menu or a
sticky note can name the same URL for a year.

## Deploy on Render

`render.yaml` is a blueprint with two services — the pool and this host. *New →
Blueprint*, pick the repository, and Render:

1. builds the documentation with `SITE_BASE_URL=/`, because this host serves from
   the root of its own domain rather than from `/ZMRIG/`;
2. writes the precompressed copies once, at deploy time;
3. starts `node serve/server.js`.

Nothing in it is a secret. The GitHub API is read anonymously and the feed is
cached for ten minutes — 60 calls an hour at most, well inside the limit.

A free instance sleeps after fifteen minutes without traffic and wakes on the
next request in about a second. If that is not good enough, point any free uptime
monitor at `/healthz` every five minutes.

## Why it is fast

Everything the site serves is read into memory once, at boot: 238 routes, 6.31 MB
raw, 1.63 MB compressed. After that a request is a Map lookup and one `end()`.

- no `stat`, no `open`, no `readdir` per request;
- Brotli and gzip written once at deploy (or at boot when a sidecar is missing);
- `ETag` on every response, and a conditional request is answered with `304`
  before the body is touched;
- fingerprinted assets are `immutable` for a year, HTML revalidates;
- one connection stays open for 65 seconds, so a page and its assets share it;
- the release feed is fetched once per ten minutes, not once per visit.

Measured here (2 vCPU, keep-alive, warm): `/` at 0.25 ms p50 and 0.81 ms p95,
`/docs/intro` at 0.19 ms, an asset at 0.35 ms, eight concurrent requests at
0.89 ms p50. Brotli takes the home page from 16 KB to 3.9 KB. A Render instance
has different CPU and a real network in front of it; nothing here has been
measured there.

## When GitHub is down

The feed keeps the last good answer and the page says so. If GitHub has never
answered since the process started, the page says that too and the links it has
still work, and `/iso/*` answers `404` instead of redirecting into nothing.
Nothing 500s because a third party is unavailable.

## Tests

```bash
cd serve && npm test      # 39 checks
```

File table, negotiation, `304`, traversal attempts, escaping of everything that
comes from GitHub — including a `javascript:` URL in a release asset — the three
redirects, a failing feed, and the real process booting and stopping on a socket.

The full operator notes — every environment variable, the cache lifetimes and how
to tune them — are in
[doc/WEB.md](https://github.com/MoLik-Labs/ZMRIG/blob/BETA/doc/WEB.md).

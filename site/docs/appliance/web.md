---
title: "One service: the site, the downloads and the fleet"
description: One Node process answers three clients — people reading the documentation, rigs checking in every minute, and the Telegram and Discord bots — on one port, with no dependencies and no build step.
image: https://molik-labs.github.io/ZMRIG/img/og-en.png
---

# One service: the site, the downloads and the fleet

GitHub Pages serves this documentation and GitHub serves the images, so nothing
here is required. `host/` exists because four things are nicer on your own host: a
link that does not change when a version does, a download page that always lists
the current asset with its checksum, a site that works where GitHub is blocked or
slow, and somewhere for a fleet of rigs to check in.

It is one Node process, one port, no dependencies, no build step:

| who | asks for | answered by |
| --- | --- | --- |
| people | `/`, `/vi/`, `/download`, `/iso/v3`, `/api/releases.json` | the committed build in `web/` |
| rigs | `POST /v1/hello`, once a minute each | the device protocol |
| the bots | nothing — they poll Telegram and Discord outwards | two long-poll loops |

## Why one process and not three

A free Render workspace is allowed **750 instance hours per calendar month**,
shared by every free service, with no rollover. A 31-day month is 744 hours, so
exactly one always-on service fits; a second one puts the workspace over the
limit and Render suspends the free services until the next month. That is not a
bill, it is an outage.

Everything fits in one process because everything is small: the site is a
directory read into memory, the device protocol is a `POST` handler, and the bots
are two loops. Separating them would cost the fleet its only free month.

The three stay separate in the repository, so each runs and is tested alone:

```bash
node host/server.js    # all three, one port   <- what Render starts
cd serve && npm start  # the site and the downloads only
cd fleet && npm start  # the bots, the rigs and the browser dashboard
```

## Run it

```bash
node host/server.js             # http://localhost:8080
```

The pages come from `web/`, the committed build of `site/`. It is regenerated
deliberately, never by a deploy:

```bash
npm run publish:site            # builds site/ and replaces web/
```

Every setting is an environment variable with a default, so an empty environment
is a working configuration: `PORT`, `SITE_ROOT`, `TELEGRAM_BOT_TOKEN`,
`DISCORD_BOT_TOKEN`, `FLEET_ADMIN_IDS`, `FLEET_ROSTER`, `FLEET_PUBLIC_URL`,
`GITHUB_REPO`, `RELEASES_TTL`. With no token and no roster it still starts: it
serves the documentation, accepts check-ins, and says in the log that no bot is
connected. Only a broken `PORT` stops it.

## What it answers

| path | |
| --- | --- |
| `/` | the documentation, English |
| `/vi/` | the documentation, Vietnamese |
| `/download` | stable and beta with sizes, checksums, `dd` and `sha256sum` |
| `/api/releases.json` | the same data for a script |
| `/iso/v3` `.../v2` `.../beta` | 302 to the newest asset on that channel |
| `/healthz` | one answer covering all three jobs |
| `POST /v1/hello` | the device protocol: `401` without a key, `405` on `GET` |

```bash
curl -L -O https://your-host/iso/v3     # always the newest v3 image
```

And the download helper can ask this service instead of GitHub, which is the
point on a network where `api.github.com` is blocked:

```bash
./scripts/latest-iso.sh --host https://your-host          # newest stable
./scripts/latest-iso.sh --host https://your-host --beta   # the rolling beta
```

`/iso/*` resolves through the release feed, which is cached, so a redirect is a
Map lookup and a `302`. That is the whole point: a script, a Ventoy menu or a
sticky note can name the same URL for a year.

`/healthz` reports all three jobs, so a deploy that lost one of them is visible
from the outside, not from a user:

```json
{"ok":true,"bots":{"telegram":true,"discord":false},
 "fleet":{"rigs":3,"known":4},
 "site":{"root":"/opt/render/project/src/web","files":244},
 "uptime_s":3600,"rss_mb":64}
```

There is no dashboard on this host. The front door is the documentation, and two
HTML surfaces on one origin is one too many to keep safe; `cd fleet && npm start`
brings the dashboard back, with `FLEET_WEB_PASSWORD` and CSRF on every form.

## Deploy on Render

`render.yaml` is the blueprint: one service, `node host/server.js`, health check
`/healthz`. The
[deploy button](https://render.com/deploy?repo=https://github.com/MoLik-Labs/ZMRIG)
reads that file; *New → Blueprint* and picking the repository does the same
thing.

There is no build step. `web/` is committed, so a deploy installs nothing, spends
no build minutes, and cannot break on a documentation dependency that published a
broken minor version.

The pool is not in that blueprint: it is needed only while somebody is mining, and
`deploy/render-pool.yaml` exists for whoever wants to run it instead. Applying
both to the same workspace is what exhausts the month.

Nothing in it is a secret except the values Render asks for once. The GitHub API
is read anonymously and the feed is cached for ten minutes — 60 calls an hour at
most, well inside the limit. With a fleet reporting every minute the service
never sleeps; with an empty fleet, point any free uptime monitor at `/healthz`
every five minutes.

## The build is for GitHub Pages; this serves it from the root

The committed `web/` is the GitHub Pages build, so everything in it links to
`/ZMRIG/assets/...` and `/ZMRIG/docs/...`. Served from the root of a domain that
is a page with no stylesheet, no navigation and no fonts — it renders, so nothing
errors, and the only evidence is that it looks wrong.

At boot the prefix is found in the home page and removed in memory: 125 files,
about 4 000 references, 20 ms, one time. Absolute URLs are left alone, because a
`rel="canonical"` pointing at `https://molik-labs.github.io/ZMRIG/` has to keep
pointing there. A request that still arrives with the prefix — an old bookmark, a
link copied out of the Pages site — is a `301` to the same path without it, and
`/healthz` reports `site.rebased_from` so a deploy can be checked from outside.

`SITE_BASE_URL=/` at build time produces a build with no prefix to remove, and
that is still the cleaner answer when you control the build.

## Why it is fast

Everything the site serves is read into memory once, at boot: **238 routes,
6.73 MB, in 14 ms** (the numbers move with the build; this is the 6.48 site).
After that a request is a Map lookup and one `end()`.

- no `stat`, no `open`, no `readdir` per request;
- Brotli and gzip are made **the first time a file is asked for**, not at boot —
  compressing a whole site with brotli on the tenth of a CPU a free instance gets
  is what turns a deploy into a failed health check. A browser that accepts Brotli
  never causes a gzip copy to exist at all;
- the quality follows the measured cost, not a hunch: 11 below 8 KB, 10 up to
  64 KB, 9 up to 1 MB, 6 above. On a 32 KB page quality 11 costs 43 ms and saves
  0.1 KB over quality 10 at 14 ms; on the 488 KB bundle 11 costs 948 ms and saves
  11 KB over 9 at 44 ms. A tenth of a CPU makes that the only question;
- the pages most likely to be opened first are compressed just after the socket
  opens, one per tick, between requests;
- `ETag` on every response, and a conditional request is answered with `304`
  before the body is touched;
- fingerprinted assets are `immutable` for a year, HTML revalidates;
- one connection stays open for 65 seconds, so a page and its assets share it;
- the release feed is fetched once per ten minutes, not once per visit;
- a compressed copy older than the page it belongs to is ignored, so a stale
  sidecar from an earlier build cannot pin the site to last week's content.

The two pages this process renders itself (`/download` and the JSON feed) carry
`Content-Security-Policy: default-src 'none'` — one HTML file, no script at all.

Measured here (2 vCPU, keep-alive, 60 requests per route):

| | first request | p50 | p95 |
| --- | ---: | ---: | ---: |
| the process, listening | — | — | — |
| `/` | 31.0 ms | 0.34 ms | 1.12 ms |
| `/docs/intro` | 33.5 ms | 0.31 ms | 0.45 ms |
| `/download` | 62.7 ms | 0.29 ms | 1.02 ms |
| `/vi/` | 22.1 ms | 0.26 ms | 0.49 ms |

The first request for a page pays for its compression; every one after it is
0.3 ms. Brotli takes the home page from 16 KB to 3.9 KB. A Render instance has
different CPU and a real network in front of it; nothing here has been measured
there.

Properly saturated, on the same 2 vCPU sandbox (`npm run bench:host`, 8 clients,
3 s per path, `Accept-Encoding: br, gzip`):

| path | req/s | p50 | p99 | on the wire |
| --- | ---: | ---: | ---: | ---: |
| `/` | 8 195 | 0.74 ms | 2.89 ms | 3 909 B (brotli) |
| `/docs/intro` | 10 991 | 0.64 ms | 1.83 ms | 6 034 B (brotli) |
| `/api/releases.json` | 12 431 | 0.60 ms | 1.38 ms | 256 B |
| `/assets/css/styles.<hash>.css` | 9 115 | 0.74 ms | 2.91 ms | 18 090 B (brotli, from 25 KB) |

`npm run bench:host` takes `--conc`, `--seconds` and `--root`, and it is a
benchmark of the real server object, not of a mock: the same `createServer` the
deploy uses, over a real socket. The device protocol is deliberately left out —
it is a rig's path on a timer, and a load test on it measures the test.

## When GitHub is down

The feed keeps the last good answer and the page says so — and says what to fix
(`name lookup failed`, `timed out`, `TLS certificate rejected`) rather than
Node's `fetch failed`. If GitHub has never
answered since the process started, the page says that too and the links it has
still work, and `/iso/*` answers `404` instead of redirecting into nothing.
Nothing 500s because a third party is unavailable, and nothing about the fleet
depends on GitHub at all.

## Tests

```bash
node --test host/tests/*.test.js    # 7 checks: one port, three jobs
cd serve && npm test                # 46 checks: the site itself
cd fleet && npm test                # 84 checks: bots, protocol, store
```

The first suite is the one this deployment shape needs: a rig and a browser on
the same port must be answered by different halves, `/healthz` must report all
three jobs, the dashboard must not be published, and a missing site must not stop
the rigs.

The full operator notes — every environment variable, the cache lifetimes and how
to tune them — are in
[doc/WEB.md](https://github.com/MoLik-Labs/ZMRIG/blob/BETA/doc/WEB.md).

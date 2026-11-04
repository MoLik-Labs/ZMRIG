# Hosting the site, the downloads and the fleet yourself

`host/` is the process this project deploys: one Node process, one port, no
dependencies, no build step. It answers three different clients at once.

| who | what they ask for | answered by |
| --- | --- | --- |
| people | `GET /`, `/vi/`, `/download`, `/iso/v3`, `/api/releases.json` | the committed documentation build in `web/` |
| rigs | `POST /v1/hello`, once a minute each | the device protocol from `fleet/` |
| the bots | nothing — they poll Telegram and Discord outwards | `fleet/src/telegram.js`, `fleet/src/discord.js` |

You do not need any of it. GitHub Pages serves the same documentation and GitHub
serves the images. It exists for four reasons: links that do not change when a
version does (`/iso/v3`), a download page that lists every asset with its
checksum without a redeploy, a place to put all of it on your own domain when
GitHub is blocked or slow, and a control plane for a fleet of rigs that needs
somewhere to run.

## Why one process and not three

A free Render workspace is allowed **750 instance hours per calendar month**,
shared by every free service in it, with no rollover. A 31-day month is 744
hours, so exactly one always-on service fits — a second one puts the workspace
over the limit and Render suspends the free services until the next month. That
is not a bill, it is an outage, and it is why the deployment unit is one process.

Everything is in it because everything is small: the site is a directory of files
read into memory, the device protocol is a `POST` handler, and the bots are two
long-poll loops. None of them needs a service of its own, and separating them
would cost the fleet its only free month.

The pieces stay separate in the repository, so each can be run and tested on its
own:

```bash
node host/server.js              # all three, one port   <- what Render runs
cd serve && npm start            # the site and the downloads only
cd fleet && npm start            # the bots, the rigs and the dashboard
```

## Run it

```bash
node host/server.js             # http://localhost:8080
```

The documentation it serves is `web/`, the committed build of `site/`. It is
regenerated deliberately, not by a deploy:

```bash
npm run publish:site            # builds site/ and replaces web/
```

Configuration is the environment, and every variable has a default:

```bash
PORT=8080                        # Render sets this
SITE_ROOT=web                    # where the pages come from
TELEGRAM_BOT_TOKEN=...           # optional: the Telegram bot
DISCORD_BOT_TOKEN=...            # optional: the Discord bot
FLEET_ADMIN_IDS=tg:123456789     # who may command it
FLEET_ROSTER={"rigs":[...]}      # who the rigs are; see fleet/roster.example.json
FLEET_PUBLIC_URL=https://zmrig.example.com   # what the pages print as links
GITHUB_REPO=MoLik-Labs/ZMRIG
RELEASES_TTL=600000              # ten minutes
```

[`serve/.env.example`](../serve/.env.example) and
[`fleet/config.example.env`](../fleet/config.example.env) are the same lists with
the details. With no token and no roster it still runs: it serves the
documentation, accepts check-ins, and says in the log that no bot is connected.
Only a broken `PORT` stops it.

## Deploy on Render

`render.yaml` in the repository root is the blueprint: one service, `node
host/server.js`, health check `/healthz`. The
[deploy button](https://render.com/deploy?repo=https://github.com/MoLik-Labs/ZMRIG)
reads that file; *New → Blueprint* and picking the repository does the same
thing. Then fill in the variables marked `sync: false` once.

There is no build step. `web/` is committed, so there is no `npm install`, no
Docusaurus build, and no build minutes spent on a deploy — and a documentation
dependency that publishes a broken minor version cannot break the deployment
that runs your fleet.

The pool is **not** in that blueprint: it is needed only while somebody is
actually mining, and `deploy/render-pool.yaml` exists for whoever wants to run it
instead. Applying both to the same workspace is what exhausts the month. A
second workspace, or a paid plan, is the honest answer if you need both.

Nothing in the blueprint is a secret except the four values Render asks for once.
The GitHub API is read anonymously and the feed is cached for ten minutes — at
most 60 calls an hour, well inside the unauthenticated limit at any traffic this
site sees.

A free instance sleeps after fifteen minutes without traffic and wakes on the
next request in about a second. With a fleet reporting every minute it never
sleeps; with an empty fleet, point any free uptime monitor at `/healthz` every
five minutes (`.github/workflows/keepalive.yml` does this from the repository,
which is the option that needs no third party).

## What it answers

| path | |
| --- | --- |
| `/` | the documentation, English |
| `/vi/` | the documentation, Vietnamese |
| `/download` | stable and beta, sizes, checksums, `dd` and `sha256sum` lines |
| `/api/releases.json` | the same data for a script |
| `/iso/v3` `.../v2` `.../beta` | 302 to the newest asset on that channel |
| `/healthz` | one answer covering all three jobs |
| `/docs` | `301` to `/docs/intro`, because that is what a hand-typed URL means |
| `POST /v1/hello` | the device protocol; `401` without a device key, `405` on `GET` |

`/iso/*` reads the release feed, which is cached, so a redirect costs one Map
lookup. Point a script at it and it never has to know a version:

```bash
curl -L -O https://zmrig.example.com/iso/v3
```

A rig or a script that cannot reach `api.github.com` can ask this service
instead; the answer is the same one the page shows:

```bash
./scripts/latest-iso.sh --host https://zmrig.example.com          # newest stable
./scripts/latest-iso.sh --host https://zmrig.example.com --beta   # the rolling beta
./scripts/latest-iso.sh --host https://zmrig.example.com --json   # for a script
```

The hash comes with the document, so the helper prints it without downloading
160 MB first. If the host itself has never reached GitHub, it says so and the
helper repeats that reason instead of claiming nothing has been published.

`/healthz` answers for all three jobs, so a deploy that lost one of them is
visible from the outside instead of from a user:

```json
{"ok":true,
 "bots":{"telegram":true,"discord":false},
 "fleet":{"rigs":3,"known":4},
 "site":{"root":"/opt/render/project/src/web","files":244},
 "uptime_s":3600,"rss_mb":64}
```

`rigs` counts check-ins that an admin has claimed; `known` includes a machine
that has enrolled but not been named yet. A `site.files` of zero means the
process is serving a directory that is not the documentation.

There is no dashboard on this host. The front door is the documentation, and two
HTML surfaces on one origin is one too many to keep safe; `cd fleet && npm start`
brings the dashboard back, with `FLEET_WEB_PASSWORD` and CSRF on every form. The
bots themselves are unaffected either way.

## Why it is fast

A page request is a memory read. At boot the process reads every file of the
built site once — 244 routes, 6.84 MB, in 17 ms — and keeps a pre-built header
set for
each. After that:

* **No filesystem syscall per request** — no `stat`, no `open`, no `readdir`.
* **Compression happens on demand**, not at boot. This is the one place where
  the obvious optimisation is wrong: compressing the whole site with Brotli up
  front is a few seconds on a laptop and minutes on the 0.1 CPU of a free Render
  instance, during which the health check fails and the deploy is rolled back. So
  each file is compressed the first time somebody asks for it, and kept. A
  browser that accepts Brotli never causes a gzip copy to exist at all.
  `.br`/`.gz` sidecars written by `npm run build` in `serve/` are still preferred
  when they are there, which makes a deploy that ships them do no work.
* **The quality follows the size**: 11 up to 32 KB, 9 up to 256 KB, 6 above it.
  Brotli's cost grows far faster than its gain, and on an old CPU quality 11 on a
  bundle is a visitor waiting for two percent.
* **Warm-up**, the pages most likely to be opened first, compressed just
  after the socket opens, one per tick,
  between requests. A cold start answers immediately and the copy is ready by the
  time somebody clicks a link.
* **`ETag` on everything**, and a conditional request is answered before a byte
  of the body is touched: `304 Not Modified` with no body.
* **Fingerprinted assets are `immutable`** with a one-year lifetime, because
  Docusaurus hashes their names; HTML revalidates, so a deploy is visible on the
  next page load.
* **Keep-alive is held for 65 seconds**, so a page and its twelve assets use one
  connection.
* **A compressed copy older than its file is ignored**, not served: a sidecar
  left behind by a previous build would otherwise pin a page to content that no
  longer exists while the `ETag` matched the new file — the site would be one
  release behind and nothing would say so.
* **The release feed is fetched once per ten minutes**, not once per visit, and
  the rendered download page is cached against the feed's timestamp.

Measured on the development machine (2 vCPU, 3939 MB, HTTP keep-alive), 60
requests per route after the first:

| path | boot | first request | p50 | p95 |
| --- | ---: | ---: | ---: | ---: |
| the whole process, listening | 17 ms | — | — | — |
| `/` | | 31.0 ms | 0.34 ms | 1.12 ms |
| `/docs/intro` | | 33.5 ms | 0.31 ms | 0.45 ms |
| `/download` | | 62.7 ms | 0.29 ms | 1.02 ms |
| `/vi/` | | 22.1 ms | 0.26 ms | 0.49 ms |
| eight at a time, `/` | | | 3.49 ms | |

The first request for a page pays for its compression (22–63 ms here, ten times
that on a free instance's tenth of a CPU); every request after it is 0.3 ms. Brotli takes the home page from 16 KB to 3.9 KB. These numbers are from
this machine; a Render instance has different CPU and a real network in front of
it, and nothing here has been measured there.

The two pages this process renders itself — `/download` and the release feed —
carry `Content-Security-Policy: default-src 'none'` with only inline styles
allowed, because they are one HTML file with no script at all. The documentation
is left alone: it is a Docusaurus build with scripts of its own.

`Accept-Encoding` is read as the weighted list it is. `br;q=0` is a refusal, not a
preference, and `identity;q=0` gets a compressed body rather than an empty `406`.

## When GitHub is unreachable

The feed keeps the last good answer and says so on the page, with what to fix
(`name lookup failed`, `timed out`, `TLS certificate rejected`) rather than
Node's `fetch failed`. If GitHub has never been reachable since the process
started, `/download` says that too and the links it has still work; `/iso/*`
answers `404` rather than redirecting into nothing. Nothing 500s because a third
party is down, and nothing about the fleet depends on GitHub at all.

## Tests

```bash
node --test host/tests/*.test.js    # 7 checks: one port, three jobs
cd serve && npm test                # 46 checks: the site itself
cd fleet && npm test                # 84 checks: bots, protocol, store
```

`host/tests` is the one that matters for this deployment shape: a rig and a
browser hitting the same port must be answered by different halves, `/healthz`
must report all three jobs, the dashboard must not be published, and a missing
site must not stop the rigs. The rest is covered by the two suites below it —
the file table, negotiation, the `304` path, traversal attempts, HTML escaping of
anything that comes from GitHub, a `javascript:` URL in a release asset, the
three redirects, a feed that fails and explains why, a stale precompressed
sidecar, `q=0` in `Accept-Encoding`, and the real process booting and stopping on
a socket.

## Run it without Render at all

```bash
node host/server.js                                  # systemd, a container, a spare box
```

A single `node host/server.js` under any supervisor is the whole deployment. It
writes nothing to disk except the fleet's scratch cache (`FLEET_STATE`, default
`/tmp/fleet.json`), which is rebuilt by the next check-in, so a restart, a
redeploy and a fresh container are all the same event.

---
title: The browser dashboard
description: The whole fleet as a web page — one password, no accounts, per-rig controls, enrolment and the current ISO. Set FLEET_WEB_PASSWORD and it appears on the same port as the bot.
image: https://molik-labs.github.io/ZMRIG/img/og-en.png
---

# The browser dashboard

The bot is the fast path. Sometimes a page is the right shape: a laptop on the
sofa, a phone at work, somebody who is not in your chat. The same fleet, the same
commands, rendered as HTML — and **off until you ask for it**.

```bash
FLEET_WEB_PASSWORD='at-least-twelve-characters'
```

That is the whole configuration. With it set, `GET /` is the overview. With it
empty, no HTML exists at all: `/` stays the read-only status page and every
dashboard path answers `404`. One password, one operator. No accounts, no email,
no invites, nothing to leak on somebody else's server.

## What is there

| path | |
| --- | --- |
| `/` | fleet total: hashrate, rigs mining, offline count, hottest, and what needs attention |
| `/rigs` | one row per machine: state, hashrate, temperature, last seen |
| `/rig/<id>` | everything about one rig, plus its controls |
| `/enrol` | the three-step enrolment, with your URL already filled in |
| `/downloads` | the current ISO and its checksum, straight from the releases API |
| `/docs` | the commands the bot accepts, for reference |

A rig page carries what the chat carries: **Start, Stop, Restart, Update, Fetch
log, Reboot**, a wallet-and-pool form, a coin / mode / heat-cap / threads / worker
form, rename, and remove. Everything is *queued* — the rig applies it on its next
check-in, 60 seconds by default, and reports the result back to the page and to
the chat. Nothing is pushed down a live connection, so a click in a browser
cannot wedge a miner mid-share.

Two rules that surprise people:

* An empty wallet or pool field means **leave it alone**, never "clear it".
  Changing a wallet means typing a different one.
* A rig enrolled in the browser belongs to the primary chat admin, so `/devices`
  in Telegram lists it next to everything else.

## Enrolling from the page

On the machine:

```bash
zmrig-os fleet --url https://your-fleet.onrender.com
zmrig-os id
```

```
  device      ZMR-1A2B-3C4D-5E6F
  enrol code  ABCD-1234
```

Then `/enrol`, two fields, one optional name. The code is derived from the rig's
own key and is verified server-side, so a stolen Device ID cannot be enrolled
without somebody standing at the machine. `zmrig-os sync --now` makes it appear
immediately instead of within a minute.

## Why it is cheap to run

* Pages are rendered by the server from the same store the bot writes to, then
  cached in memory until the fleet's revision counter moves. A refresh with no
  new check-ins does not touch the templating code.
* 5.3 KB of CSS, under 1 KB of JS, both `immutable` and cached for a year. No
  font, no framework, no third-party request of any kind.
* Brotli or gzip when the browser asks and the page is over 512 bytes, plus an
  `ETag` and `304 Not Modified` — a phone on mobile data refreshes the fleet for
  a few hundred bytes.
* It is the same Node process as the bot. Nothing extra to host, nothing extra to
  pay for, and killing the dashboard does not stop the bot.

## Security

* the password is compared with `timingSafeEqual` against `FLEET_WEB_PASSWORD`;
* ten failed logins from one address in fifteen minutes ⇒ `429` for that address;
* every form carries a CSRF token bound to the session; a form without one is
  `403` and changes nothing;
* the session cookie is `HttpOnly`, `SameSite=Lax`, seven days, and `Secure` when
  the request arrived over HTTPS;
* `Content-Security-Policy: default-src 'none'` — no third-party script, font or
  image can load, so a compromised CDN cannot watch your fleet;
* the password lives in the environment, never in the repository, never in the
  state file, and it is not printed at startup.

Serve it over HTTPS. On Render that is automatic; anywhere else, put it behind a
reverse proxy, because a password typed into plain HTTP is a password on the
wire.

## Getting an image without the bot

`scripts/latest-iso.sh` asks the GitHub releases API and downloads the current
image for your CPU:

```bash
./scripts/latest-iso.sh                 # newest stable, your CPU's variant
./scripts/latest-iso.sh --beta          # newest beta
./scripts/latest-iso.sh --arch v3       # force x86-64-v3
./scripts/latest-iso.sh --json          # just the facts, for a script
```

It prints the checksum and the size and leaves the comparison to `sha256sum -c`;
it needs `node` (which the rig already has) and falls back to printing the
releases page when it is missing. The same table is at `/downloads` on the
dashboard.

The full operator manual — every environment variable, the wire protocol, what
each alert means — is [doc/FLEET.md](https://github.com/MoLik-Labs/ZMRIG/blob/BETA/doc/FLEET.md).

# ZMRIG fleet

A Telegram and Discord bot that configures and watches ZMRIG OS rigs.

A rig shows a **Device ID** and an **enrolment code** on its console. You type
them into the bot once. From then on the wallet, the pool, the coin, the mining
mode, the heat cap, the thread count and the worker name are all set from the
chat window, and the rig reports back. No SSH, no keyboard on the rig, no wallet
entered on every machine.

```
  rig                                    bot                             you
  ───                                    ───                             ───
  zmrig-os id  →  ZMR-1A2B-3C4D-5E6F                                     
                  ABCD-1234  ────────────── /enroll ZMR-1A2B-3C4D-5E6F ABCD-1234
  POST /v1/hello  ─────────────────────→  store, alerts, queue
  (every 60 s)    ←─────────────────────  {"commands":[{"cmd":"setup","wallet":…}]}
  save_conf, restart miner                 ✅ setup applied
```

## Why the rig calls out, and only out

A rig is behind NAT, on a phone hotspot, or in a shed. It never listens. The
agent makes one small HTTPS request a minute; the answer is usually
`"commands":[]`, and when it is not, the commands are applied and acknowledged on
the next check-in.

The **Device ID is derived from a key generated on the machine** and that key
never leaves it:

```
ZMR-XXXX-XXXX-XXXX   sha256(key)[0..6), upper-case hex
enrol code XXXX-XXXX sha256("enroll:" + key)[0..4), upper-case hex
```

The server recomputes both from the key the rig presents, so a Device ID can
never be claimed by a machine that does not hold the key, and typing the code
proves the machine is in front of you. A leaked Device ID is worth nothing.

## Commands

| | |
| --- | --- |
| `/enroll <id> <code> [name]` | link a rig to you |
| `/devices` `/status` | the fleet, with state, hashrate, temperature |
| `/device <rig>` | one rig, with buttons: start, stop, restart, update, log, reboot |
| `/wallet <rig> 4…` | set the wallet (validated before it is queued) |
| `/pool <rig> host:port` | set the pool |
| `/coin <rig> xmr\|wow\|arq\|graft\|sfx\|yada\|xla` | set the coin |
| `/mode <rig> max\|balanced\|eco\|light\|safe [C]` | aggression, and a heat cap |
| `/threads <rig> 8\|auto` | pin the thread count |
| `/worker <rig> name` | the name the pool sees |
| `/update <rig>` | newest miner; the OS goes into the spare A/B slot |
| `/log <rig> [n]` | the rig's own log, brought back with the next check-in |
| `/rename` `/remove` `/whoami` `/help` | the rest |

`<rig>` is the full ID, a unique part of it (`3C4D`), or the name you gave it.
Every change is queued, so a rig that is offline right now still receives it when
it comes back - and every result is reported to you, including refusals.

## Deploy

The service is one Node process with no dependencies. It needs Node 20+ (Node 22
for Discord, which uses the built-in `WebSocket`).

### 1. Make the bot

**Telegram**: `@BotFather` → `/newbot` → the token. Your own id comes from
`@userinfobot`.

**Discord**: `discord.com/developers/applications` → *New Application* → *Bot* →
*Reset Token*. Turn on **Message Content Intent** under *Privileged Gateway
Intents*, invite it with the `bot` scope and *Send Messages*, and copy your user
id (Developer Mode → *Copy User ID*).

### 2. Run it

Locally:

```bash
cd fleet
cp config.example.env .env      # fill in the tokens and ids
set -a; . ./.env; set +a
npm start                       # or: node src/index.js
npm run check                   # what the environment says, no socket opened
```

On [Render](https://render.com): *New → Blueprint*, pick this repository, and
choose `fleet/render.yaml`. Render asks for the four secrets.

A free instance **sleeps after 15 minutes without traffic**, and a sleeping bot
does not answer. Either point a free uptime pinger at `https://<service>/healthz`
every 5 minutes (this is the cheapest fix and the one that keeps the bot awake
for the check-ins), or move to a paid instance. The rigs keep mining while it
sleeps; they simply check in with nobody listening.

The fleet's memory is one JSON file at `FLEET_STATE`. On a free instance that is
`/var/data` and is empty after every deploy, which means every rig has to be
enrolled again. Attach a disk and point `FLEET_STATE` at it once the fleet is
real.

### 3. Point the rigs at it

On the rig, once:

```bash
zmrig-os fleet --url https://zmrig-fleet.onrender.com
```

or, for a stick that boots a hundred machines, on the kernel command line:

```
zmrig.os.fleet=https://zmrig-fleet.onrender.com
```

Then `zmrig-os id` prints the ID and the code, and `/enroll` does the rest.

## What it will not do

* No telemetry. Nothing leaves a rig that the operator did not configure.
* No wallet, no key and no address is stored on the rig's behalf anywhere except
  the rig and the control plane's JSON file.
* No inbound connection to a rig, ever.
* No silent change: every queued instruction is acknowledged, applied or refused,
  and the result appears in the chat.
* No mining without a wallet, and no command that removes one.

## Tests

```bash
npm test                        # 42: identity, store, commands, HTTP, rendering
bash ../os/tests/fleet.sh       # 26: the shell agent against this server
```

`os/tests/fleet.sh` starts this server on loopback with a test-only control port
and drives the real `zmrig-os`, including the refusals: a bad wallet is refused
and nothing is written, an unknown mode is refused, a failed command is reported.

## Layout

```
fleet/
  src/config.js      environment -> config, with the refusals to start
  src/ids.js         Device ID and enrolment code, identical to the shell
  src/store.js       one JSON file, atomic writes, queue, audit
  src/commands.js    the whole command surface, platform-free and testable
  src/alerts.js      heat, stops, hashrate drops, and the silence sweep
  src/http.js        POST /v1/hello, /healthz, the landing page
  src/telegram.js    long polling, HTML rendering, inline keyboards
  src/discord.js     gateway, buttons, DMs, no dependency
  src/index.js       wiring, permissions, rate limits, shutdown
```

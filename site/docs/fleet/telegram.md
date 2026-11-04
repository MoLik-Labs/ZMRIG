---
title: Telegram and Discord control
description: Enrol a rig by its Device ID, set the wallet, pool, coin and mode from a chat window, get an alert when one goes quiet. A bot with no dependencies, on your own host.
image: https://molik-labs.github.io/ZMRIG/img/og-en.png
---

# Telegram and Discord control

A rig prints a **Device ID** and an **enrolment code** on its console. Type them
into the bot once, and that machine is yours to configure from the chat: wallet,
pool, coin, mining mode, heat cap, thread count, worker name. It reports back —
hashrate, temperature, uptime, the log on request — and alerts you when it goes
quiet.

```bash
# on the rig, once
zmrig-os fleet --url https://your-fleet.onrender.com
zmrig-os id
```

```
  device      ZMR-1A2B-3C4D-5E6F
  enrol code  ABCD-1234
```

```
# in the chat
/enroll ZMR-1A2B-3C4D-5E6F ABCD-1234 basement
/wallet ZMR-1A2B-3C4D-5E6F 4YourMoneroAddress...
```

That is the whole onboarding. The wallet is typed once, in the chat, for as many
rigs as you own.

## What the bot can do

| Command | |
| --- | --- |
| `/enroll <id> <code> [name]` | link a rig to you |
| `/devices` | every rig: state, hashrate, temperature, last seen |
| `/status` | one screen: rigs, total hashrate, hottest, offline count, then one line per wallet once there is more than one |
| `/device <rig>` | one rig, with buttons |
| `/wallet <rig> 4…` | set the wallet, validated before it is queued |
| `/pool <rig> host:port` | set the pool |
| `/coin <rig> xmr\|wow\|arq\|graft\|sfx\|yada\|xla` | set the coin |
| `/mode <rig> max\|balanced\|eco\|light\|safe [C]` | aggression, and a heat cap |
| `/threads <rig> 8\|auto` | pin the thread count |
| `/worker <rig> name` | the name the pool sees |
| `/update <rig>` | newest miner; the OS goes into the spare A/B slot |
| `/log <rig> [n]` | the rig's last lines, with the next check-in |
| `/reboot <rig>` `/rename` `/remove` | the rest |

`<rig>` is the full ID, a unique part of it (`3C4D`), or the name you gave it.

Changes are **queued**, not pushed: a rig that is offline right now receives them
when it comes back, and every result — applied or refused — is reported in the
chat. `zmrig-os` validates everything again on the machine, so a hand-built
request to the control plane cannot talk a rig into a wallet it would reject.

## Alerts

* a rig that has not checked in for five minutes;
* a rig that came back;
* temperature at or above 85 °C;
* the miner stopping when it was mining;
* hashrate below half of the previous check-in;
* hashrate below half of the rate the rig measured on itself, which catches the
  machine that has been sliding for a week rather than the one that fell over
  just now;
* every command result, including refusals.

Each kind has a cooldown per rig, so a hot machine does not shout every minute
(`FLEET_ALERT_COOLDOWN`, seconds, default 1800). The threshold is
`FLEET_ALERT_TEMP` (default 85 °C) and the hashrate rule is
`FLEET_ALERT_HASHRATE_DROP` (default 0.5, meaning "half").

The temperature is the hottest reading the rig can find, not the first one:
`coretemp`, `k10temp` or `x86_pkg_temp` before the board's Super I/O chip, and
`acpitz` — which reports a southbridge estimate 10–20 °C below the die — only
when nothing else exists. A rig whose number is 0 has no sensor at all, and
`zmrig-os doctor` says so in one line; the alert cannot fire on a machine that
cannot measure itself, which is why it is worth looking at.

The second hashrate rule is the slow one, and it says what it compared:

```
🐌 rig-2 is at 640.0 H/s, 45% of the 1.4 kH/s it measured itself
```

## Hosting it

One Node process, **no dependencies**, one JSON file of state.

```bash
cd fleet
cp config.example.env .env      # TELEGRAM_BOT_TOKEN, FLEET_ADMIN_IDS
set -a; . ./.env; set +a
npm run check                   # prints the config, opens no socket
npm start
```

The blueprint in the repository root deploys one service that runs the bot,
Discord, the rigs' check-ins **and** the documentation site — `node
host/server.js`, one port, one health check. The browser dashboard is the one
surface it does not mount: the public host's front door is the documentation, and
`cd fleet && npm start` is what gives you the dashboard. Three facts about
Render's free plan are worth knowing before you deploy, because they decide the
shape of the whole thing:

| Fact | What it means here |
| --- | --- |
| **750 instance hours** per workspace per month | a 31-day month is 744 hours, so exactly one always-on service fits; two would exhaust the allowance and Render suspends free services until the next month |
| sleeps after **15 minutes** without inbound traffic | the rigs' minute-by-minute check-ins keep it awake; `.github/workflows/keepalive.yml` pings `/healthz` twice an hour for a quiet fleet |
| the filesystem is **ephemeral** | nothing about the fleet is stored there — see the roster below |

### The roster: why a restart changes nothing

`FLEET_ROSTER` — one JSON value in Render's *Environment* tab — names every rig
and, optionally, what it should be running:

```json
{
  "owner": "tg:123456789",
  "wallet": "46SQL...",
  "pool": "gulf.moneroocean.stream:10001",
  "rigs": {
    "ZMR-1A2B-3C4D-5E6F": {
      "label": "basement",
      "mode": "safe",
      "maxtemp": 72,
      "threads": 8
    }
  }
}
```

`wallet` and `pool` at the top are the ones the whole farm shares: six machines in
a shed mine into one address, and writing it six times is six chances to mistype
one and split the balance. A rig that sets its own keeps it.

It can also live in `fleet/roster.json`; the environment wins when both exist.
Nothing in it is secret — a Device ID is public and a wallet is an address — and a
rig listed there is enrolled before it has ever checked in.

The roster is **desired state, not a message**. On every check-in the server
compares what the roster says a rig should be with what the rig says it is, and
queues the difference: at most once per rig per five minutes, never twice while a
change is in flight, and immediately when it matters. A queued command is a
message that may never arrive; a roster entry is a fact re-checked a minute from
now. That is why a redeploy, a restart or a spin-down leaves the fleet exactly
where it was.

The token lives in an environment variable, never in a file in the repository.
Your own id is the only one the bot answers until you add more to
`FLEET_ADMIN_IDS`.

## How the identity works

```
ZMR-XXXX-XXXX-XXXX   sha256(key)[0..6), upper case
enrol code XXXX-XXXX sha256("enroll:" + key)[0..4), upper case
```

The 32-byte key is generated on the rig and never leaves it. The server
recomputes both strings from the key presented on every check-in, so an ID cannot
be claimed by a machine that does not hold its key, and the code proves the
machine is in front of you. Nothing connects *to* a rig: it calls out, once a
minute, and everything else waits for that call.

On a live stick the key lives in RAM — install to disk, or give the stick a
`ZMRIGDATA` partition with `zmrig-os persist`, or the rig reports a new ID after
a reboot.

## Without a fleet

Leave `FLEET_URL` empty and nothing changes: the rig never contacts anything, and
`zmrig-os setup` remains the way to configure it. The control plane is an
addition, not a dependency.

Operator-level detail — every environment variable, the wire format, the failure
modes — is in [doc/FLEET.md](https://github.com/MoLik-Labs/ZMRIG/blob/BETA/doc/FLEET.md).

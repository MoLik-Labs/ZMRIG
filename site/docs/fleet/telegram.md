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
| `/status` | one screen: rigs, total hashrate, hottest, offline count |
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

Each kind has a cooldown per rig, so a hot machine does not shout every minute.
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

`fleet/render.yaml` is a Render blueprint. On the free plan the instance sleeps
after 15 minutes without traffic, so point a free uptime monitor at `/healthz`
every 5 minutes — a sleeping bot answers nothing, though the rigs keep mining and
catch up when it wakes.

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

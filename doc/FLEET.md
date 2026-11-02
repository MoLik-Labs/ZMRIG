# The control plane: a Telegram and Discord bot for a fleet of rigs

This is the page for somebody who has more than one rig, or one rig they do not
want to walk over to. It covers making the bot, hosting it, pointing rigs at it,
and what it can and cannot do.

Everything here is optional. A rig with no `FLEET_URL` behaves exactly as it did
before: it mines and it never contacts anything.

## What it replaces

| Before | With the bot |
| --- | --- |
| type the wallet on every machine | type it once, in a chat |
| change a pool by ssh-ing to each rig | `/pool <rig> host:port` |
| find out a rig is hot by touching it | an alert the moment it passes the limit |
| discover a rig went offline when the payout drops | an alert after three missed check-ins |
| update each rig by hand | `/update <rig>`, and the daily job stays |

## The Device ID

Every machine makes its own 32-byte key the first time it boots
(`/etc/zmrig/device.key` on a live stick, `<boot media>/zmrig/device.key` on an
installed disk). The key never leaves the machine. Two strings are derived from
it and printed on the console at first boot and by `zmrig-os id`:

```
  device      ZMR-1A2B-3C4D-5E6F
  enrol code  ABCD-1234
```

* `ZMR-...` is `sha256(key)` — public, safe to say out loud, and useless without
  the key.
* `ABCD-1234` is `sha256("enroll:" + key)` — typing it proves the machine is in
  front of you. It is not a password, and it changes only if the key does.

The control plane recomputes both from the key the rig presents on every
check-in, so a rig cannot claim an ID that is not its own, and a stolen ID cannot
be enrolled without somebody holding the machine.

On a **live stick the key lives in RAM** - the rig gets a new ID after a reboot
unless it was installed to a disk or given a `ZMRIGDATA` partition. `zmrig-os id`
says which case you are in.

## 1. Make the bot

### Telegram

1. Talk to [@BotFather](https://t.me/BotFather): `/newbot`, pick a name, copy the
   token (`123456789:AAH...`).
2. Talk to [@userinfobot](https://t.me/userinfobot) and copy your numeric id.
   That number is the only account that may use the bot until you add more.

### Discord (optional, can run at the same time)

1. <https://discord.com/developers/applications> → *New Application* → *Bot* →
   *Reset Token*. Copy the token.
2. *Privileged Gateway Intents* → enable **Message Content**.
3. *OAuth2 → URL Generator*: scope `bot`, permissions *Send Messages*, *Embed
   Links*, *Read Message History*. Invite the bot to your server.
4. Your user id: Discord settings → *Advanced* → *Developer Mode*, then
   right-click your name → *Copy User ID*.

## 2. Host it

It is one Node process with **no dependencies**: nothing to install, nothing to
compile, no database.

```bash
cd fleet
cp config.example.env .env     # tokens and admin ids
set -a; . ./.env; set +a
npm run check                  # prints the configuration, opens no socket
npm start
```

The service listens on `PORT`, answers `GET /healthz`, serves a read-only status
page at `/`, and accepts rigs at `POST /v1/hello`.

### Render

`fleet/render.yaml` is a blueprint: *New → Blueprint* in Render, pick the
repository, choose that file, and it asks for the four secrets.

Two things the free plan does that matter:

* **It sleeps after 15 minutes without traffic.** A sleeping bot answers
  nothing. Add a free uptime monitor (cron-job.org, UptimeRobot, a GitHub Action
  on a schedule) hitting `https://<service>/healthz` every 5 minutes. Rigs keep
  mining while it sleeps — they check in with nobody listening, and catch up when
  it wakes.
* **The disk is empty after every deploy.** `FLEET_STATE` is one JSON file; on a
  free instance it is recreated on each deploy, so every rig has to be enrolled
  again. Attach a disk and point `FLEET_STATE` at it once the fleet is real.

Any other host works the same way: Node 20+, one port, two environment variables.

### Environment

| variable | default | meaning |
| --- | --- | --- |
| `TELEGRAM_BOT_TOKEN` | - | from @BotFather |
| `DISCORD_BOT_TOKEN` | - | optional, runs alongside Telegram |
| `FLEET_ADMIN_IDS` | - | Telegram ids, comma separated; `tg:` prefix optional |
| `DISCORD_ADMIN_IDS` | - | Discord user ids |
| `FLEET_NOTIFY` | every admin | where alerts go |
| `PORT` | `8080` | HTTP port |
| `FLEET_STATE` | `./data/fleet.json` | the fleet's memory |
| `FLEET_PUBLIC_URL` | - | printed in the status page, optional |
| `FLEET_INTERVAL` | `60` | seconds between check-ins |
| `FLEET_OFFLINE_AFTER` | `300` | silence before "offline" (never below 3 intervals) |
| `FLEET_ALERT_TEMP` | `85` | °C that raises an alert |
| `FLEET_ALERT_HASHRATE_DROP` | `0.5` | alert when hashrate falls below this fraction |
| `FLEET_ALERT_COOLDOWN` | `1800` | seconds before the same rig may repeat an alert |
| `FLEET_RATE_LIMIT` | `30` | commands per window per operator |
| `FLEET_QUEUE_LIMIT` | `10` | instructions a rig may have waiting |

With no admin id the process refuses to start: a bot nobody owns would accept
commands from an Internet stranger.

## 3. Point a rig at it

Once per rig, or once per stick:

```bash
zmrig-os fleet --url https://zmrig-fleet.onrender.com
```

For media that boots many machines, the kernel command line is better — it
survives a read-only stick and needs no console:

```
zmrig.os.fleet=https://zmrig-fleet.onrender.com
```

In Ventoy that is just a line in the boot menu entry, next to
`zmrig.os.install=` and `zmrig.os.wallet=`.

The rig checks in within a minute (`zmrig-os sync --now` forces one now), and
`zmrig-os fleet` shows the last check-in. Then, in the bot:

```
/enroll ZMR-1A2B-3C4D-5E6F ABCD-1234 basement
```

If the bot says **no rig has checked in with that ID**, the URL is wrong, the rig
is offline, or it has not restarted since `zmrig-os fleet --url` was set.

## 4. Run the fleet

```
/wallet ZMR-1A2B-3C4D-5E6F 4YourAddress...
/mode   ZMR-1A2B-3C4D-5E6F safe 72
/devices
```

Every instruction is queued and applied on the next check-in; anything that
changes the miner's command line restarts it, and the result comes back to the
chat (`✅ setup - applied, miner restarted`, or `❌ setup failed - wallet
rejected`).

Buttons on `/device <rig>` do the same for the impatient: start, stop, restart,
update, log, reboot.

### Alerts

Sent to every admin, once, with a cooldown:

* a rig that has not checked in for `FLEET_OFFLINE_AFTER`
* a rig that came back
* temperature at or above `FLEET_ALERT_TEMP`
* the miner stopped when it was mining
* hashrate below half of the previous check-in
* every command result, including the refusals

## What is on the wire

One request a minute from the rig:

```json
POST /v1/hello
Authorization: Bearer <64 hex characters: the device key>
{"device":"ZMR-1A2B-3C4D-5E6F","version":"6.37.0",
 "status":{"state":"mining","hashrate":1201.4,"temp":64,"uptime":86400,
           "mode":"max","wallet":"4...","pool":"gulf.moneroocean.stream:10001",
           "coin":"xmr","threads":"8","slot":"a","installed":true},
 "acks":[{"id":"mvze5j5cr4m","cmd":"setup","ok":true,"detail":"applied"}],
 "log":null}
```

and the answer:

```json
{"ok":true,"enrolled":true,"interval":60,"config_version":3,
 "commands":[{"id":"mwa1","cmd":"setup","wallet":"4...","mode":"safe","maxtemp":72}]}
```

Commands: `setup` (`wallet`, `pool`, `coin`, `mode`, `maxtemp`, `threads`,
`worker`), `start`, `stop`, `restart`, `update`, `log`, `reboot`.

The rig validates everything again before applying it — the bot's validation is a
convenience, not the security boundary. A wallet that fails `zmrig-os`'s own
validator is refused on the machine, nothing is written, and the refusal is
reported.

## Security

* The key is generated on the rig, stored `0600`, and never sent anywhere except
  in an `Authorization` header over TLS to the URL you configured.
* The server stores only `sha256(key)`. Reading the state file does not let you
  impersonate a rig.
* Nothing connects *to* a rig. There is no port to open, no tunnel, no reverse
  proxy on the rig.
* Only ids in `FLEET_ADMIN_IDS` / `DISCORD_ADMIN_IDS` are answered; everybody
  else is told their own id and nothing else.
* Losing the state file (a free-host redeploy) loses the enrolment records, not
  the rigs: they keep mining, and re-enrolling is two strings per rig.

## Troubleshooting

| symptom | cause |
| --- | --- |
| `no rig has checked in with that ID` | URL not set, DNS blocked, or the rig has not synced since |
| the code does not match | you copied the ID from one machine and the code from another; run `zmrig-os id` again |
| the rig changes ID after a reboot | live stick without persistence — install to disk, `zmrig-os persist`, or keep the media writable |
| a command stays "waiting" | the rig is offline; it applies on the next check-in |
| alerts are silent | `FLEET_NOTIFY` set to a chat the bot cannot write to, or the free instance is asleep |
| `another process is polling this bot token` | two deployments of the same bot; stop one |

`zmrig-os status` on the rig shows the fleet URL and the last check-in, and
`zmrig-os sync` (without `--quiet`) says what it did.

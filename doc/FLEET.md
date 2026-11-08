# The control plane: a Telegram and Discord bot for a fleet of rigs

This is the page for somebody who has more than one rig, or one rig they do not
want to walk over to. It covers making the bot, hosting it, pointing rigs at it,
the browser dashboard that comes with it, and what it can and cannot do.

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
| notice a rig has been slow for a week | an alert against the rate the rig measured on itself |

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
page at `/` (or the dashboard, if you set a password — §3), and accepts rigs at
`POST /v1/hello`.

### Render

The blueprint in the repository root deploys this service: *New → Blueprint* in
Render, pick the repository, apply. It asks for the secrets once — they are
marked `sync: false`, so they are typed into Render and never read from the
repository. It starts `node host/server.js`, which is this service **and** the
documentation site on one port and one instance — see
[`WEB.md`](WEB.md) for the shape and for why one service is not a preference but
the only deployment the free plan allows. `cd fleet && npm start` runs the same
fleet without the site, which is what gives you the browser dashboard.

Three things about the free plan shape the design, and none of them is a
workaround for a bug in this code:

* **750 instance hours per workspace per calendar month**, shared by every free
  service. A 31-day month is 744 hours, so exactly one always-on service fits.
  Two services that both stay awake run the workspace out of hours, and Render
  then suspends the free services until the next month. This is why the Telegram
  bot, the Discord bot, the rigs' check-ins and the documentation are one
  process, and why the pool is not part of this blueprint.
* **It sleeps after 15 minutes without inbound traffic.** A sleeping bot answers
  nothing. While a fleet is checking in every sixty seconds that traffic keeps it
  awake by itself; `.github/workflows/keepalive.yml` covers the quiet case by
  asking `/healthz` twice an hour (set the repository variable
  `FLEET_HEALTH_URL`). Rigs keep mining while it sleeps — they check in with
  nobody listening and catch up when it wakes.
* **The filesystem is empty after every deploy, restart and spin-down.** So the
  fleet is not stored there. `FLEET_STATE` is a scratch cache; what survives is
  `FLEET_ROSTER`, in the environment, which says who the rigs are and what they
  should be running. Every check-in is reconciled against it — see below.

### What is hosted, and what is not

One process, and only one:

* **hosted** — the Telegram and Discord bots that check and control the machines,
  the endpoint the rigs check in to, and the documentation with its download
  page. One process, one port, one health check.
* **hosted only when you run it alone** — the browser dashboard. It is an HTML
  login surface, and the public host's front door is the documentation, so
  `node host/server.js` does not mount it; `cd fleet && npm start` does, with
  `FLEET_WEB_PASSWORD` and CSRF on every form. The bots and the rigs are the same
  either way.
* **not hosted, ever** — the pool. Its code stays in the repository because it is
  a useful thing to have built, but nothing here deploys it, and a rig points at
  whatever pool the operator chooses. There is also no database, no object
  storage, no uploads, no accounts and no analytics: the service holds the fleet
  in memory and reads the roster from the environment.
* **not hosted here** — anything that needs a disk. There is no disk worth
  having: see the third point under Render above, and `doc/PERSISTENT_OPTIONS.md`
  for the reasoning behind that being a feature rather than a limitation.

The direction of traffic is one way. Rigs push and poll; the service never
connects out to a rig, which is why a rig behind a carrier NAT is a normal rig and
not a support case.

Any other host works the same way: Node 20+, one port, the environment.

### Environment

| variable | default | meaning |
| --- | --- | --- |
| `TELEGRAM_BOT_TOKEN` | - | from @BotFather |
| `DISCORD_BOT_TOKEN` | - | optional, runs alongside Telegram |
| `FLEET_ADMIN_IDS` | - | Telegram ids, comma separated; `tg:` prefix optional |
| `DISCORD_ADMIN_IDS` | - | Discord user ids |
| `FLEET_NOTIFY` | every admin | where alerts go |
| `PORT` | `8080` | HTTP port |
| `FLEET_STATE` | `./data/fleet.json` | scratch cache; on a free host it is recreated on every deploy |
| `FLEET_ROSTER` | — | the fleet, as JSON: who the rigs are and what they should run (see below) |
| `FLEET_ROSTER_FILE` | `fleet/roster.json` | where to read that JSON instead, when the variable is empty |
| `FLEET_PUBLIC_URL` | - | printed in the status page, optional |
| `FLEET_INTERVAL` | `60` | seconds between check-ins |
| `FLEET_OFFLINE_AFTER` | `300` | silence before "offline" (never below 3 intervals) |
| `FLEET_ALERT_TEMP` | `85` | °C that raises an alert |
| `FLEET_ALERT_HASHRATE_DROP` | `0.5` | alert below this fraction of the previous check-in, and of the rate the rig measured on itself |
| `FLEET_ALERT_COOLDOWN` | `1800` | seconds before the same rig may repeat an alert |
| `FLEET_RATE_LIMIT` | `30` | commands per window per operator |
| `FLEET_QUEUE_LIMIT` | `10` | instructions a rig may have waiting |
| `FLEET_WEB_PASSWORD` | - | password for the browser dashboard; empty means no dashboard |
| `FLEET_TRUST_PROXY` | on where the platform says so | believe `X-Forwarded-For` and `X-Forwarded-Proto` |
| `FLEET_UNOWNED_LIMIT` | `200` | records kept for rigs nobody has enrolled yet |
| `FLEET_UNOWNED_TTL` | `86400` | seconds before an unenrolled record expires |

Any 64-hex `Authorization: Bearer` token produces a device record, because a rig
that has never been enrolled still has to be able to knock — and that means
anybody with `curl` can make one. Each record is memory plus a rewrite of the
state file, which on Render lives in `/tmp` and is therefore RAM, so the
unenrolled ones are bounded: past `FLEET_UNOWNED_LIMIT` the **least recently seen
unenrolled record** is evicted, and one that has been silent for
`FLEET_UNOWNED_TTL` is dropped on the next check-in from anyone.

Eviction rather than refusal is deliberate. An operator cannot enrol a machine
whose first check-in was refused: `/enroll` checks the enrolment code against the
record that check-in would have created. A rig waiting to be enrolled is checking
in every minute, so it is never the oldest, and a flood of strangers can only
displace other strangers. Measured: 5 000 anonymous check-ins leave 200 records
and a 78 KB state file, where before the file grew by one record per request.

Through real HTTP the same handler took **4 662 anonymous check-ins per second**
for five seconds (23 313 requests, 16 keep-alive sockets, one core): 200 records
afterwards, a 118 KB state file, 13 debounced writes, 101 MB resident. The
per-device rate limiter cannot slow this down, because every request arrives
with a different key — the cap is what bounds it, and the cap does its job.

`FLEET_TRUST_PROXY` decides two things the dashboard does with headers, and both
are wrong in a way nobody notices until it matters:

* **who is asking.** The login throttle is keyed by address. `X-Forwarded-For`
  is a list the client starts — a request with `X-Forwarded-For: 1.2.3.4` reaches
  a proxied service as `1.2.3.4, <the address the proxy saw>` — so reading the
  first entry (which is what this did, until 6.48.1) lets anybody be a new client
  on every request and step around the block. The **last** entry is the one the
  proxy appended, and that is what is used. With no proxy declared the header is
  ignored entirely and the socket address is used, because a directly connected
  client writes that header itself.
* **whether the cookie is `Secure`.** A proxy terminates TLS and says so in
  `X-Forwarded-Proto`; a direct client says whatever it likes. The default is on
  for Render and Fly (both set an environment variable naming the platform) and
  off everywhere else, so `FLEET_TRUST_PROXY=1` is what to set behind nginx,
  Caddy or Cloudflare.

Whatever the header says, a second budget counts wrong passwords from *every*
address: past ten in fifteen minutes, each attempt pays a delay of up to two
seconds first. Rotating addresses buys an attacker a few attempts a second
instead of thousands, and the owner's correct password still works on the first
try.

With no admin id the process refuses to start: a bot nobody owns would accept
commands from an Internet stranger.

### The roster: the fleet that survives a restart

`FLEET_ROSTER` is one JSON object naming every rig and, optionally, what it
should be running:

```json
{
  "owner": "tg:123456789",
  "wallet": "46SQL...",
  "pool": "gulf.moneroocean.stream:10001",
  "rigs": {
    "ZMR-1A2B-3C4D-5E6F": {
      "label": "basement",
      "coin": "xmr",
      "mode": "safe",
      "maxtemp": 72,
      "threads": 8,
      "worker": "rig-basement"
    }
  }
}
```

`wallet` and `pool` at the top are the ones the whole farm shares. Six machines in
a shed mine into one address; writing it six times is six chances to mistype one
and split the balance between two addresses nobody is watching. A rig that sets
its own `wallet` keeps it, so a borrowed machine still pays its owner.

The same JSON can live in `fleet/roster.json` if you would rather keep it in the
repository; the environment wins when both exist, so one entry can be overridden
by a deploy hook without editing a file. `fleet/roster.example.json` has every
field, and nothing in it is secret: a Device ID is public and a wallet is an
address.

Three consequences worth understanding:

* **A rig in the roster is enrolled before it has ever checked in.** The roster
  knows the Device ID and not the key — it cannot, the key never leaves the
  machine — so the first secret that hashes to that ID binds the record, and
  every later request is held to it exactly as if the rig had enrolled itself in
  the chat.
* **The roster is desired state, not a message.** A queued command is a message
  that may never arrive; a roster entry is a fact that is re-checked on the next
  check-in. If a rig drifts — somebody edits the config on the box, a mode change
  sheds threads, a wallet is replaced by hand — the difference is queued again,
  at most once per rig per five minutes, and never twice while a change is
  already in flight. Restarting the service changes nothing, because nothing was
  remembered.
* **Hashrate is added up per wallet, not per machine.** The dashboard and the
  `status` command group every rig by the address it reports and show one number
  per address with its share of the fleet: that is the number the pool pays, and
  the rigs are only how it gets produced. A rig that has gone quiet stops adding
  to the total — it has not stopped mining, but its last reading is not the
  present — while still being counted as a rig of the farm. A rig that has not
  reported a wallet yet is listed as its own group, last, because a machine
  mining into the wrong address is the mistake that view exists to make visible.

Empty `FLEET_ROSTER` is a supported state: the bot then works exactly as before,
with enrolments living in `FLEET_STATE` until the next restart.

The hashrate rule is two rules, because a fleet fails in two time scales. One
compares each check-in with the one before it (a minute apart) and catches a rig
that fell over just now. The other compares the rig with the rate it measured on
itself when it tuned (`MEASURED_HS`, reported on every check-in) and catches the
one that has been sliding for a week — dust, a failing DIMM, a background job
somebody left running. The second is reported once per cooldown, and the message
names the difference:

```
🐌 rig-2 is at 640.0 H/s, 45% of the 1.4 kH/s it measured itself
```

The rig acts on the same comparison by itself; see
[the appliance page](OS.md#when-the-rig-stops-keeping-its-own-number). The
alert is for the operator who wants to know before the rig decides to re-measure.

## 3. The browser dashboard

The bot is the fast path. The dashboard is the one you can hand to a laptop, a
phone, or somebody who is not in your chat: same fleet, same commands, rendered
as a page. It is off until you give it a password.

```bash
FLEET_WEB_PASSWORD='at-least-twelve-characters'
```

With that set, `GET /` is the overview instead of the read-only status page.
With it empty, nothing HTML exists — `/` stays the old public page and every
dashboard path is a 404. There are no accounts, no email addresses, no invites:
**one password, one operator**. Rigs enrolled in the browser are attributed to
the primary chat admin, so the bot and the page see the same fleet.

| path | |
| --- | --- |
| `/` | fleet total: hashrate, rigs mining, offline count, hottest, and what needs attention |
| `/rigs` | one row per machine: state, hashrate, temperature, last seen |
| `/rig/<id>` | everything about one rig, plus its controls |
| `/enrol` | the three-step enrolment, with your URL already filled in |
| `/downloads` | the current ISO and the checksum file, straight from the releases API |
| `/docs` | the commands it accepts, for reference |

What a rig page can do is what the bot can do: **Start, Stop, Restart, Update,
Fetch log, Reboot**, a wallet-and-pool form, a coin/mode/heat-cap/threads/worker
form, and rename. Everything is *queued*: the rig applies it on the next
check-in — 60 seconds by default — and reports the result back to the page and to
the chat. Nothing is pushed down a live connection, so a dashboard click cannot
wedge a miner mid-share.

Two details worth knowing:

* An empty wallet or pool field means **leave it alone**, never "clear it". The
  only way to change a wallet is to type a different one.
* A rig whose reported address fails its checksum is marked in the dashboard
  (a red **wallet ✗** in the rig list, the reason on its page, and it appears
  under *needs attention*), not only in the one alert the chat sent. The mark
  describes the last address the rig reported; the alert fires once.
* A wallet is **decoded before it is queued**, in the chat, in the browser and in
  the roster: the checksum is verified and a typo is refused with the reason
  (`that is not a Monero address - checksum does not match: at least one
  character is wrong`). Sending a rig an address nobody can spend from would cost
  a week of hashing that no screen would explain.
* Enrolling from the browser ties the rig to the primary chat admin, not to
  "the web", so `/devices` in Telegram still lists everything you own.

It is server-rendered HTML with 5.3 KB of CSS and under 1 KB of JS, both cached
by the browser for a year (`immutable`). Pages are compressed with Brotli or gzip
when the browser asks for it and the page is over 512 bytes, carry an ETag,
and answer `304 Not Modified` when the fleet has not changed — a phone on mobile
data refreshes the fleet for a few hundred bytes. A rendered page is cached in
memory and rebuilt only when the store's revision counter moves, so a refresh
with no new check-ins never touches the templating code at all.

Security, in the order it matters:

* the password is compared with `timingSafeEqual` against `FLEET_WEB_PASSWORD`;
* ten failed logins from one address in fifteen minutes ⇒ `429` for that address;
* every form carries a CSRF token bound to the session; a form without one is
  `403` and does nothing;
* the session cookie is `HttpOnly`, `SameSite=Lax`, seven days, and `Secure` when
  the request arrived over HTTPS;
* `Content-Security-Policy: default-src 'none'` — no third-party script, font,
  or image can load, so a compromised CDN cannot see your fleet.

The dashboard is a convenience over the same store the bot writes to. If it is
switched off, the bot keeps working; if the bot is switched off, the dashboard
keeps working.

### Getting an image without the bot

`scripts/latest-iso.sh` asks the GitHub releases API for the current image and
downloads it, verifying nothing it cannot verify — it prints the checksum and
the size and leaves the comparison to `sha256sum -c`:

```bash
./scripts/latest-iso.sh                 # newest stable, your CPU's variant
./scripts/latest-iso.sh --beta          # newest beta
./scripts/latest-iso.sh --arch v3       # force x86-64-v3
./scripts/latest-iso.sh --json          # just the facts, for a script
./scripts/latest-iso.sh --host https://your-fleet   # ask your own host, not GitHub
```

It needs `node` (which the rig already has) and falls back to printing the
releases page when it is missing. `--host` is for a network where GitHub is
blocked: the same service that runs the bot can run the web host
([`doc/WEB.md`](WEB.md)), and its `/api/releases.json` answers the same question
from its own cache. The same table is at `/downloads` in the
dashboard.

## 4. Point a rig at it

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

## 5. Run the fleet

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
* a rig reporting a wallet address that fails its checksum, or one on another
  network: `💸 rig-1 has an invalid wallet address - checksum does not match: at
  least one character is wrong. Nothing mined to it can be paid.` The wallet is
  the unit, not the rig: rigs that share an address are one message for the
  whole farm (`💸 5 rigs all mine to an address that cannot be paid - …`), sent
  once per cooldown, because eleven identical warnings about one typo is how a
  chat gets muted.
* every command result, including the refusals

## What is on the wire

One request a minute from the rig:

```json
POST /v1/hello
Authorization: Bearer <64 hex characters: the device key>
{"device":"ZMR-1A2B-3C4D-5E6F","version":"6.48.0",
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
validator (which asks the miner for a checksum, not a character count) is refused
on the machine, nothing is written, and the refusal is reported.

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
* The dashboard adds no way in that the bot does not already have: one password
  compared in constant time, a login throttle, CSRF on every form, and a CSP that
  forbids every third-party origin. Delete `FLEET_WEB_PASSWORD` and the surface
  is gone.

## Troubleshooting

| symptom | cause |
| --- | --- |
| `no rig has checked in with that ID` | URL not set, DNS blocked, or the rig has not synced since |
| the code does not match | you copied the ID from one machine and the code from another; run `zmrig-os id` again |
| the rig changes ID after a reboot | live stick without persistence — install to disk, `zmrig-os persist`, or keep the media writable |
| a command stays "waiting" | the rig is offline; it applies on the next check-in |
| alerts are silent | `FLEET_NOTIFY` set to a chat the bot cannot write to, or the free instance is asleep |
| `another process is polling this bot token` | two deployments of the same bot; stop one |
| the dashboard 404s | `FLEET_WEB_PASSWORD` is empty, or the deploy has not restarted since it was set |
| `429` on the login form | ten wrong passwords from that address in fifteen minutes; wait, or restart the service to clear it |
| `/downloads` says nothing is published | GitHub was unreachable when the page was rendered, or the release has no ISO asset yet; the page retries after ten minutes |

`zmrig-os status` on the rig shows the fleet URL and the last check-in, and
`zmrig-os sync` (without `--quiet`) says what it did.

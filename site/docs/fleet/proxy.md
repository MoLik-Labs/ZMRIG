---
title: Farm proxy
description: One pool connection for many rigs. Extranonce per rig, difficulty per rig, one login for the whole farm, and tunnels for rigs in another building.
image: https://molik-labs.github.io/ZMRIG/img/og-en.png
---

# Farm proxy

Ten rigs in two buildings, one wallet, one connection to the pool. `proxy/` does
that: Node 18+, no dependencies, nothing to compile.

```bash
sudo ./proxy/install.sh --user=4YourMoneroAddress --pool=gulf.moneroocean.stream:10001
```

Or without installing anything:

```bash
node proxy/src/main.js start --user=4YourMoneroAddress --pool=gulf.moneroocean.stream:10001
```

`install.sh --dry-run` prints the systemd unit before writing it, and the banner
prints the exact line each rig has to run.

## Why a proxy earns more

Three ways a farm loses money, all with the same root:

1. **Duplicated work.** A Monero nonce is 32 bits. Two rigs searching the same
   range means a share only gets paid once. The proxy gives each rig its own
   top nonce byte and keeps the bottom 24 bits for the rig — the same scheme as
   `xmrig-proxy`. The trap: **prefix 0 is not a prefix.** A blob with nonce 0 is
   the miner's signal to turn extranonce mode off, so handing a rig 0 silently
   puts it back into the shared range and earns less.
2. **One difficulty for every rig.** A 500 H/s machine and a 20 kH/s machine on
   the same target produce one share an hour and one a minute. The small rig
   starves while still using full power. The proxy assigns difficulty per rig,
   targeting about 15 seconds per share.
3. **A login storm.** The pool sees one login per rig, and a pool behind
   Cloudflare — or any free-tier service — rate-limits logins and then bans the
   IP. One connection from the proxy covers the farm, while each rig still shows
   up as its own worker (`--user=wallet.rig3`).

The proxy does **not** hash. It checks each share's target (a BigInt comparison,
microseconds) and forwards it; the pool re-hashes. It cannot fake work, and this
implementation does not try.

## Check before pointing rigs at it

```bash
node proxy/src/main.js doctor --user=4YourMoneroAddress --pool=gulf.moneroocean.stream:10001
```

```text
ok   pool gulf.moneroocean.stream:10001 answered -- 168 ms
ok   job difficulty -- 60011.2
ok   a 5 kH/s rig would find -- 0.30 shares/hour at this difficulty
```

The last line is the calculation people skip: shares per hour is
`hashrate × 3600 / difficulty`. 0.30 means one share every three hours — fine for
a long-window PPLNS pool, fatal for one with a high payout threshold.

## Reaching rigs in another building

| Flag | Transport | Stable address | Third party | Verdict |
| --- | --- | --- | --- | --- |
| `--tunnel=wireguard` | WireGuard over UDP, in the kernel | `10.66.66.1` | none | **use this** |
| `--tunnel=tailscale` | WireGuard via a coordination server | `*.ts.net` | Tailscale | good when nothing can be forwarded |
| `--tunnel=cf` | named Cloudflare tunnel, WebSocket | your hostname | Cloudflare | works, one more edge hop |
| `--tunnel=cf-quick` | `*.trycloudflare.com`, WebSocket | random, new every run | Cloudflare | **demo only** |

```bash
# once, on the machine that runs the proxy
node proxy/src/main.js tunnel wireguard --rigs=10 --dir=wg
sudo cp wg/ocean-proxy.conf /etc/wireguard/ocean-proxy.conf
sudo systemctl enable --now wg-quick@ocean-proxy

node proxy/src/main.js start --user=4YourMoneroAddress \
  --pool=gulf.moneroocean.stream:10001 --tunnel=wireguard
```

That writes the server config plus one file per rig (`wg/rig-1.conf` …), each
with its own key and an address from `10.66.66.2` upward, and an `INSTALL.txt`
with the copy commands. **One file per machine** — sharing a file is the
WireGuard version of the duplicate-nonce bug.

Why this is the default recommendation: stable addresses (a changed ISP address
requires no rig edits), UDP handled in the kernel so no added latency, no third
party, and only one UDP port (`51820`) opened on the router — the stratum port
stays on localhost.

## Tailscale, when nothing can be forwarded

```bash
node proxy/src/main.js start --user=4YourMoneroAddress \
  --pool=gulf.moneroocean.stream:10001 \
  --tunnel=tailscale --tunnel-token=tskey-auth-…
```

Three things to know before choosing it: Funnel only serves **443/8443/10000**,
TLS only, and its bandwidth is not enough to poll a dashboard every second (it is
plenty for stratum, a few kB/s). The free Personal plan is **non-commercial**. If
the rigs are in the same tailnet, skip Funnel entirely and point them at
`<host>.<tailnet>.ts.net:3333`; nothing is exposed to the internet.

## Cloudflare tunnels, stated plainly

**A quick tunnel is not a production path.** It is good for exactly one thing:
proving in two minutes that the network works.

| Property | Consequence for mining |
| --- | --- |
| Random hostname every start | every rig needs updating after every restart |
| No uptime commitment | a dropped tunnel stops every rig at once |
| No access control | anyone with the name can mine to your wallet |
| One more hop | added latency on every job notification |

A named tunnel with a token fixes the hostname and the access control, and it is
the right choice when only 443 is allowed. Even then the proxy stays the only
thing exposed, and the rigs never see the internet.

## Status and income per rig

```bash
curl -s http://127.0.0.1:3334/status | python3 -m json.tool
```

`/status` reports, per rig, the hashrate derived from accepted shares and the
local difficulty it was given, plus XMR/day when the network difficulty is known:

```bash
node proxy/src/main.js start --user=4YourMoneroAddress \
  --pool=gulf.moneroocean.stream:10001 \
  --network-difficulty=350000000000 --block-reward=0.6
```

The figure is measured, not inferred from a CPU name, and it is `null` rather
than a guess when the network difficulty is unknown.

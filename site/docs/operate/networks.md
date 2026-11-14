---
title: Networks that only allow 443
description: Cloudflare relays, SOCKS5 and HTTP proxies, --connect-to and pinned CAs, for VPS providers and office networks that block everything except HTTPS.
image: https://molik-labs.github.io/ZMRIG/img/og-en.png
---

# Networks that only allow 443

A "picky" VPS usually lands in one of four situations:

1. Only outbound 443/tcp; 3333, 10001, 5555 are blocked.
2. TLS required, plaintext stratum dropped, or DPI cutting unfamiliar packets.
3. Everything must go through the organisation's proxy.
4. Only certain address ranges are reachable (a CDN's anycast, an internal relay).

The Zig engine handles all four. The C++ engine has no WebSocket client, so it
cannot handle (1) and most of (2) — the installer switches engines rather than
writing a config that cannot connect.

## One flag for the common case

```bash
sudo ./oneclick.sh install --wallet 4YourMoneroAddress \
  --pool my-relay.example.com \
  --cloudflare=my-relay.example.com --ws-path /pool
```

`--cloudflare` means: `wss://<host>:443<path>`, TLS on, engine `zmrig`. Forcing
`--engine xmrig` alongside it is refused, not silently ignored.

The same thing by hand:

```bash
zmrig -o wss://my-relay.example.com:443/pool -u 4YourMoneroAddress -p x
```

## Do you need a relay?

If the pool publishes a WebSocket endpoint on 443, no. If it does not, something
has to bridge WebSocket to raw stratum. Two options that work:

| Relay | When it fits | Cost |
| --- | --- | --- |
| `pool/worker/` in this repository | the pool speaks plain TCP and you want a `wss://` endpoint | free Workers plan is enough for a farm |
| Your own Worker | you want to read every line of it | free Workers plan |

The Worker in `pool/worker/` is a byte pipe: it opens a TCP socket to the pool and
pipes frames both ways. It does not see your wallet, and the pool sees the
Worker's address, not your VPS. It does see the stratum traffic, which is why
self-hosting matters if that concerns you.

```bash
# 1. cd pool/worker && edit wrangler.toml, then: npx wrangler deploy
# 2. point the miner at it
sudo ./oneclick.sh install --wallet 4YourMoneroAddress \
  --pool your-worker.workers.dev --cloudflare \
  --ws-path /relay/YOUR_TOKEN --yes
```

## Proxies

```bash
# SOCKS5, no auth
zmrig -o pool.example.com:3333 -u 4YourMoneroAddress --proxy socks5://127.0.0.1:1080

# HTTP CONNECT with credentials
zmrig -o pool.example.com:3333 -u 4YourMoneroAddress \
  --proxy http://user:pass@proxy.corp.example:3128
```

The Zig engine resolves the pool name through the proxy (remote DNS), so a
poisoned local resolver does not matter.

## When DNS is the problem, not the firewall

Quad9 returns NXDOMAIN for `gulf.moneroocean.stream`; Cloudflare's malware
resolver does the same for `pool.supportxmr.com`. A blocked name looks identical
to a blocked port in a miner log.

```bash
# keep the hostname for SNI and Host, dial a known-good address
zmrig -o pool.example.com:3333 -u 4YourMoneroAddress \
  --connect-to 203.0.113.10:3333

# or pin the CA of your own relay
zmrig -o wss://relay.example.com/pool -u 4YourMoneroAddress \
  --tls-ca /etc/zmrig/tls-ca.pem
```

The installer copies a CA you supply to `/etc/zmrig/tls-ca.pem`: the unit runs
with `PrivateTmp=true`, so a file in `/tmp` can disappear on restart.

## What the miner will not do

- Retry a wrong wallet every five seconds. A rejected wallet is identified, that
  pool is left alone for 30 minutes, and the log says what to fix.
- Reconnect immediately after `your IP is banned`. Fifteen minutes per pool
  (`--ban-cooldown`), then the next pool in the failover list.
- Keep submitting after three shares were called invalid — a ten-minute pause
  instead of the hour-long ban `xmrpool.eu` hands out.
- Let twenty rebooting rigs reconnect in the same millisecond. Every retry is
  jittered ±20 %.

These are the behaviours that separate one bad evening from a permanent block.
More on pool choice in [Pools](/docs/pools/choosing).

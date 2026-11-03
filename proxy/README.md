# zmrig-proxy

One pool connection for a whole farm. Part of [ZMRIG](https://github.com/MoLik-Labs/ZMRIG),
by [@nggkhaiz](https://github.com/NggKhaiz). GPL-3.0 (this component is MIT so
it can be vendored anywhere; see [`package.json`](package.json)).

```bash
sudo ./install.sh --user=<wallet> --pool=gulf.moneroocean.stream:10001
```

That installs a systemd unit and prints the line each rig has to run. Nothing
else is needed: no database, no `npm install`, no build step.

## Why a proxy at all

A farm of twenty rigs connecting directly to a pool loses money in three ways
that never show up in a miner log:

| Problem | What it costs | What this does |
| --- | --- | --- |
| Two rigs compute the same nonce | duplicate shares, rejected work | one **extranonce byte per rig** (255 rigs), written at the right offset for each algorithm |
| One difficulty for every machine | the small rig starves, the big rig floods | **vardiff per rig**: ~15 s between shares on a 500 H/s box and on a 20 kH/s one |
| Twenty logins per reboot | the public IP gets rate-limited or banned | **one upstream login** for the whole farm, jittered retries, per-pool cooldowns |

It also survives the pool dying: rig sockets stay open, the last job is
replayed, and the proxy reconnects on its own. A rig never learns that the pool
had a bad minute.

## Commands

```bash
zmrig-proxy start   --user=<wallet> --pool=<host:port>   # run (default)
zmrig-proxy doctor  --user=<wallet> --pool=<host:port>   # test pool, wallet, network
zmrig-proxy status                                        # counters of a running proxy
zmrig-proxy tunnel wireguard --rigs=20 --dir=/etc/wireguard
```

`--pool` accepts a comma-separated list for failover (`a:3333,b:3333`) and
`tls://host:port` for stratum+ssl. `--bind`, `--allow`, `--token` and
`--max-rigs` control who may connect; the default bind is `127.0.0.1` and the
default allow-list is loopback plus RFC1918.

Rigs connect with the pool name they already use:

```bash
zmrig -o <proxy-host>:3333 -u <wallet>.<worker> -t 4
```

## Income per rig

`/status` reports, for every connected rig, the hashrate derived from accepted
shares and the local difficulty it was given, plus XMR/day when the network
difficulty is known:

```bash
zmrig-proxy start --user=<wallet> --pool=<host:port> \
  --network-difficulty=350000000000 --block-reward=0.6
```

The number is measured, not inferred from a CPU name, and it is `null` rather
than a guess when the network difficulty is unknown. Measuring two rigs with
the same reported hashrate but different H/W is the point.

## Tunnels

| Flag | What it is | When |
| --- | --- | --- |
| `--tunnel=none` | default: the rigs reach this host directly | same LAN, same VPC |
| `--tunnel=wireguard` | this host becomes a WireGuard server, rigs get fixed `10.66.66.x` | recommended for a remote farm |
| `--tunnel=tailscale` | WireGuard plus a coordination server, no port forwarding | quick setup, non-commercial terms |
| `--tunnel=cf` | a named Cloudflare tunnel with a token | only when 443 is all you have |
| `--tunnel=cf-quick` | `cloudflared tunnel --url`, random hostname | **demo only**, never production |

The honest comparison, including why a quick tunnel is not a production path,
is in [`doc/PROXY.md`](../doc/PROXY.md).

## Tests

```bash
npm test        # 60 tests, real sockets and a WebSocket rig
```

The suite covers nonce and extranonce allocation, vardiff behaviour, job
forwarding against a fake pool, failover, a pool that bans the IP (left alone,
not retried), a wrong wallet (one connection, then a message), and the
end-to-end path with actual `zmrig` processes.

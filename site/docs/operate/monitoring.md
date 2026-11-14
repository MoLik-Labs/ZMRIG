---
title: Monitoring
description: The read-only HTTP API, the health watchdog, and ZMRIG1. report codes — what each one gives you and when to use it.
image: https://molik-labs.github.io/ZMRIG/img/og-en.png
---

# Monitoring

Two ways to get numbers out of the miner:

| | HTTP API | Report code |
| --- | --- | --- |
| Use when | the machine is on your network or VPN, or a script needs it | the machine is behind NAT, or you want a number in a spreadsheet |
| Security | binds `127.0.0.1`, optional Bearer token | opens no port; you copy the code yourself |
| Data | everything, updated every second | a snapshot at the moment it was written |
| Many machines | one endpoint each | paste several codes at once |

## HTTP API

Enabled by `--http-port`; the installer turns it on at 18080.

```bash
curl -s 127.0.0.1:18080/1/summary
curl -s 127.0.0.1:18080/2/summary | python3 -m json.tool
```

| Path | Content |
| --- | --- |
| `/1/summary`, `/summary` | compact single-line JSON, XMRig shape |
| `/1/status` | connection state |
| `/2/summary`, `/2/status` | same data, pretty-printed |
| `/json_rpc` | same as `/1/summary`, for older clients |

```bash
zmrig ... --http-port 18080 --http-access-token "$TOKEN"
curl -s -H "Authorization: Bearer $TOKEN" 127.0.0.1:18080/1/summary
```

A missing token returns `401` with JSON, an unknown path `404` with JSON, `HEAD`
works for health checks, and every response carries `Cache-Control: no-store`.

```json
{"id":"zmrig","worker_id":"vps-sg-02","uptime":3600,"version":"6.32.1",
 "kind":"miner","ua":"zmrig/6.32.1","algo":"rx/0","paused":false,
 "donate_level":0,
 "connection":{"pool":"wss://relay.example.com:443","uptime":3600,"failures":0,"tls":true},
 "hashrate":{"total":[814.2,810.5,805.1],"highest":902.7},
 "hugepages":[1168,1168],"cpu":{"threads":2},
 "results":{"shares_good":42,"shares_total":42,"hashes_total":2931842,"error_log":[]}}
```

The API is **read-only**: there is no endpoint that changes a wallet or restarts
anything. Even so, do not bind it to `0.0.0.0` without a token and a firewall —
it reveals the worker name, the pool and your address.

## Health: still running, or still earning?

That is a different question from "is the service active", and it is where money
disappears quietly: a pool that rejects every share leaves a miner that is
running, connected, printing hashrate, and earning nothing.

The miner judges itself once a second and reports one of five states:

| State | Meaning | What happens |
| --- | --- | --- |
| `warming` | building the dataset, or paused | nothing (pausing is a feature) |
| `ok` | hashrate near this session's best, shares accepted | nothing |
| `degraded` | below 80 % of the 10-minute peak (heat, a noisy neighbour) | warning |
| `stalled` | the process is alive but not hashing | error |
| `rejected` | shares were sent and none were accepted | error |

```bash
sudo ./oneclick.sh status
#   hashrate: 1042.6 H/s (10s/60s/15m)
#   shares:   184/0/0 accepted
#   health:   ok
```

`stalled` or `rejected` for **15 minutes** makes the process exit with code 3,
and `Restart=always` turns that into a clean start. The trade is explicit: 16–30
seconds of lost hashrate instead of hours of earning zero.

```bash
zmrig ... --no-health-restart     # never exit on its own
zmrig ... --health-restart=1800   # wait longer before giving up (seconds)
zmrig ... --health-warmup=300     # ignore the first 5 minutes
```

The state is also in the `health` field of a report code, so a fleet table can
show the machines that are running and earning nothing.

## Report codes

One measurement, one line:

```bash
$ sudo ./oneclick.sh report --power 45
ZMRIG1.eyJ2IjoxLCJpZCI6InZwc…     # about 380–520 characters
```

It takes 25–30 seconds: 15–20 s to build the dataset, 10 s of warm-up, 15 s of
measurement, then a power sample. `oneclick.sh report` stops the service first —
the running miner holds the huge pages, and a second dataset does not fit.

| Field | Meaning |
| --- | --- |
| `id`, `cpu`, `cores`, `thr` | machine name, CPU model, physical cores, mining threads |
| `algo`, `mode` | algorithm, `auto`/`fast`/`light` |
| `hs[0..3]` | hashrate over 10 s, 60 s, 15 min, session best |
| `hp` | huge pages granted / needed |
| `shares`, `hash`, `up` | accepted, rejected, failed; total hashes; uptime in seconds |
| `pw`, `pwsrc` | watts and where they came from: `rapl`/`hwmon` (CPU package), `user` (wall meter), `none` |
| `pool`, `ts`, `ver` | pool, timestamp, miner version |

A code contains **no wallet address, no pool token, no public IP**. It is
base64url-encoded JSON and you can read it yourself:

```bash
cut -d. -f2 report.txt | tr '_-' '/+' | base64 -d | python3 -m json.tool
```

While mining, let the miner keep the file fresh:

```bash
--report-file /var/lib/zmrig/report.txt --report-interval 60
```

The installer enables that for the `zmrig` engine, so a later `sudo cat
/var/lib/zmrig/report.txt` is enough.

## From one code to a fleet

1. Give each machine its own `--report-id` (or `--rig-id`).
2. Let the miner write its report file.
3. Paste the codes into the [profitability calculator](/docs/economics/profitability),
   one per line.
4. The calculator totals hashrate, watts, kWh, power cost, revenue and profit,
   and exports JSON.

There is no intermediate server. For 24/7 monitoring, scrape the API into
Prometheus or Netdata over your own VPN; do not expose it to the internet.

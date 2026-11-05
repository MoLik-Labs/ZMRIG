---
title: Configuration file
description: Precedence, a complete config.json written by the installer, and every key the Zig engine understands.
image: https://molik-labs.github.io/ZMRIG/img/og-en.png
---

# Configuration file

Precedence, highest first:

1. command-line flags
2. the file passed with `-c/--config`
3. the miner's defaults

Only flags you actually type override the file. `zmrig -c config.json --verbose`
does not lose `"mode": "light"` or `"huge-pages": false`. (Before `6.26.0-mo9`
it did; see the changelog.)

## A file the installer wrote

```json
{
  "api": { "id": null, "worker-id": "vps-sg-02" },
  "http": {
    "enabled": true,
    "host": "127.0.0.1",
    "port": 18080,
    "access-token": null,
    "restricted": true
  },
  "autosave": true,
  "background": false,
  "colors": false,
  "randomx": {
    "mode": "auto",
    "rdmsr": true,
    "msr": "auto",
    "numa": true,
    "scratchpad_prefetch_mode": 1
  },
  "cpu": {
    "huge-pages": true,
    "huge-pages-jit": true,
    "priority": 5,
    "max-threads-hint": 100,
    "asm": true
  },
  "donate-level": 0,
  "pools": [
    {
      "algo": null,
      "url": "gulf.moneroocean.stream:10001",
      "user": "YOUR_WALLET",
      "pass": "x",
      "rig-id": "vps-sg-02",
      "keepalive": true,
      "enabled": true,
      "tls": false,
      "transport": "wss",
      "ws-path": "/pool"
    }
  ],
  "print-time": 60,
  "retries": 5,
  "retry-pause": 5,
  "idle-timeout": 300,
  "keepalive-interval": 60,
  "report": { "enabled": true, "file": "/var/lib/zmrig/report.txt", "interval": 60 },
  "power": 45
}
```

`transport`, `ws-path`, `ws-origin`, `proxy`, `connect-to`, `tls-ca`,
`idle-timeout`, `keepalive-interval`, `report` and `power` are understood by the
Zig engine. The C++ engine ignores keys it does not know, so the same file works
for both.

## Keys

| Key | Type | Default | Notes |
| --- | --- | --- | --- |
| `algo` | string | automatic | `rx/0`, `rx/wow`, `panthera`, … or `auto` |
| `print-time` | number | 60 | seconds between hashrate lines, 0 disables |
| `retries` | number | 5 | attempts per pool before failover |
| `retry-pause` | number | 5 | seconds between attempts, jittered ±20 % |
| `idle-timeout` | number | 300 | drop a silent connection, 0 disables |
| `keepalive-interval` | number | 60 | seconds between keepalives |
| `colors` | bool | true | log colour; log files are always plain text |
| `background` | bool | false | fork into the background |
| `log-file` | string | null | also write the log to a file |
| `power` | number | — | wall watts, included in report codes |
| `report.file` | string | null | where to write the report code |
| `report.interval` | number | 60 | seconds between writes |
| `report.id` | string | `rig-id` | machine name in the report |
| `http.enabled` | bool | false | monitoring API |
| `http.port` / `http.host` | number / string | 18080 / 127.0.0.1 | |
| `http.access-token` | string | null | require a Bearer token |
| `randomx.mode` | `auto`/`fast`/`light` | auto | `fast` builds the 2 GiB dataset |
| `randomx.msr` | `"auto"` / true / false | `"auto"` | the prefetcher-off preset: `auto` asks the machine first, worth 5-15 % on bare metal; `wrmsr` with a bool is the same key |
| `cpu.threads` | number or array | cache-aware | an array is one entry per thread |
| `cpu.huge-pages` | bool | true | |
| `cpu.huge-pages-jit` | bool | true | |
| `cpu.asm` | bool | true | JIT; disabling is about six times slower |
| `cpu.priority` | number | -1 | XMRig scale 1..5, or a raw nice value |

Pool objects accept `url`, `user`, `pass`, `rig-id`, `algo`, `keepalive`, `tls`,
`transport`, `ws-path`, `ws-origin`, `host-header`, `connect-to`, `tls-ca`,
`proxy`, `enabled`.

## Editing it safely

```bash
sudo systemctl stop zmrig
sudo cp /etc/zmrig/config.json /etc/zmrig/config.json.bak
sudo -e /etc/zmrig/config.json
zmrig --check -c /etc/zmrig/config.json    # parse and validate, do not mine
sudo systemctl start zmrig
```

`--check` exits non-zero and prints the offending key, which is faster than
reading the journal after the service has already restarted four times.

:::note Autosave
`"autosave": true` lets the miner rewrite the file when it changes something it
owns (a tuned thread count, for example). If you want a file the miner never
touches, set it to `false` and restart rather than editing a running config.
:::

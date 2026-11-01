---
title: Installer reference
description: Every oneclick.sh subcommand and flag, the files it installs, the systemd units it writes, how it migrates an old installation, and how it removes itself.
image: https://nggkhaiz.github.io/ZMRIG/img/og-en.png
---

# Installer reference

```text
oneclick.sh [subcommand] [options]
```

The default subcommand is `install` when a wallet is given and `status` when it
is not.

## Subcommands

| Subcommand | What it does |
| --- | --- |
| `install` | dependencies, build, tune, config, service, self-check (default) |
| `build` | compile only; keeps the previous binary until the new one links |
| `tune` | huge pages, THP, governor, MSR — root only |
| `config` | (re)generate `/etc/zmrig/config.json` without touching the service |
| `start`, `stop`, `restart`, `status`, `logs` | service control |
| `bench` | reproducible RandomX measurement (`--bench=20000`) |
| `report` | measure and print a `ZMRIG1.` code for the calculator |
| `verify` | self-test, then audit the developer fee (rate, address, off switch) |
| `plan` | print every automatic decision and change nothing |
| `update` | fetch the configured branch, rebuild, restart |
| `uninstall` | stop, remove service and binaries, keep the config |
| `purge` | remove everything the tool ever created |

## Options

### Pool and identity

| Flag | Meaning |
| --- | --- |
| `--wallet ADDR` | wallet address or pool login (asked for if omitted) |
| `--pass VALUE` | pool password, default `x` |
| `--rig-id NAME` | worker name on the pool dashboard and in report codes |
| `--pool HOST:PORT` | endpoint; a preset also works: `moneroocean`, `supportxmr`, `c3pool`, `herominers`, `xmrpool`, `p2pool`, `p2pool-nano` |
| `--failover LIST` | comma-separated backups, written to `config.json` |
| `--algo NAME` | pin one algorithm; `auto` advertises the RandomX family |
| `--engine xmrig\|zmrig` | C++ engine or Zig engine |

### Network

| Flag | Meaning |
| --- | --- |
| `--tls` | TLS for the pool connection |
| `--cloudflare[=HOST[:PORT]]` | pool over `wss://` on 443; switches to `zmrig` |
| `--transport tcp\|tls\|ws\|wss` | override the scheme |
| `--ws-path PATH` | WebSocket path (default `/stratum`) |
| `--ws-origin URL` | `Origin` header for the upgrade |
| `--proxy URL` | `http://user:pass@host:port` or `socks5://host:port` |
| `--connect-to HOST:PORT` | dial a different address, keep the pool's SNI and `Host` |
| `--tls-ca FILE` | trust a private CA, or pin a relay certificate |
| `--idle-timeout N` | drop the connection after N silent seconds (0 disables) |
| `--ban-cooldown N` | seconds to leave a pool alone after it bans the IP (default 900) |

### Machine

| Flag | Meaning |
| --- | --- |
| `--profile free\|watt` | maximum hashrate, or maximum hashes per watt |
| `--mode fast\|light\|auto` | dataset size; `light` needs about 300 MB |
| `--cpu-hint N` | `max-threads-hint` percentage (default 100) |
| `--no-autotune` | keep the default thread count |
| `--no-tune` | do not touch huge pages, THP, governor or MSR |
| `--msr`, `--no-msr` | force or forbid MSR writes |
| `--nicehash` | mask the nonce for a rental pool |
| `--http-port PORT` | monitoring API port (default 18080) |
| `--http-token TOKEN` | require `Authorization: Bearer TOKEN` |
| `--no-http` | disable the monitoring API |
| `--power W` | wall power of this machine, used in report codes |

### Behaviour

| Flag | Meaning |
| --- | --- |
| `--force` | overwrite an existing config |
| `--yes` | never prompt (unattended installs) |
| `--no-service` | install and configure, do not create a unit |
| `--all-backends` | also build OpenCL/CUDA support |
| `--build-dir DIR` | where to compile (default `/usr/local/src/zmrig-build`) |

## What it installs

| Path | What |
| --- | --- |
| `/usr/local/bin/zmrig` | the Zig miner |
| `/usr/local/bin/xmrig` | the C++ miner, when that engine is selected |
| `/usr/local/bin/zmrig-tune` | host tuning (`--status`, `--hugepages 1G`, `--algo panthera` sizes the reservation for that coin, …) |
| `/usr/local/bin/zmrig-bench` | reproducible hashrate measurement |
| `/usr/local/bin/zmrig-verify` | the developer-fee audit |
| `/etc/zmrig/config.json` | configuration, mode 600 |
| `/var/lib/zmrig/` | state and the report file |
| `zmrig.service` | the miner: `Restart=always`, `RestartSec=5`, `Nice=-10`, `LimitMEMLOCK=infinity`, `PrivateTmp=true` |
| `zmrig-tune.service` | oneshot tuner, runs before the miner at boot |
| `http://127.0.0.1:18080/1/summary` | read-only monitoring API |

## Migration from the old name

Up to installer 1.2 the tool installed itself as `xmrig-ocean`. A new install
does not silently leave the old one behind:

1. `/etc/xmrig-ocean/config.json` is copied to `/etc/zmrig/config.json`
   (mode 600) if the new path does not exist yet.
2. `/var/lib/xmrig-ocean` is moved to `/var/lib/zmrig`.
3. The old unit is stopped, disabled and removed, so the machine does not end up
   running two miners after a reboot.
4. `purge` removes both name sets, so an upgrade does not leave orphan files.

## Branches

```text
ALPHA  ──►  BETA  ──►  master
newest      default     upstream history
```

Every command in these pages uses `BETA`. To try `ALPHA` once:

```bash
MINER_BRANCH=ALPHA sudo -E ./oneclick.sh install --wallet 4YourMoneroAddress
sudo ./oneclick.sh update    # back to the default branch
```

`update` fetches the configured branch before checking it out, and stops with
the branch name if it does not exist. That used to fail quietly.

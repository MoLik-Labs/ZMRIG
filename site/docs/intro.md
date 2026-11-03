---
title: What ZMRIG is
description: A RandomX miner with a 1 % developer fee you can see and switch off, the installer that sets it up, a farm proxy and a self-hosted pool. What each part does, what it costs, and where the code came from.
slug: /intro
image: https://molik-labs.github.io/ZMRIG/img/og-en.png
---

# What ZMRIG is

ZMRIG is a complete Monero mining setup, not a collection of scripts:

| Part | What it is | What it costs |
| --- | --- | --- |
| **Miner** | XMRig 6.26.0 with every line of donation code removed, plus a complete Zig miner on the same RandomX engine | **1 %** of Monero time on the Zig engine, printed and switchable off; the C++ engine has no fee code |
| **Installer** | `oneclick.sh`: one flag, host tuning, systemd unit, self-check, purge | free |
| **Proxy** | one pool connection for a farm: extranonce per rig, per-rig difficulty, tunnels | free |
| **Pool** | self-hosted Monero pool: stratum over TCP and WebSocket, PPLNS, every share verified | 1 % of each block, nothing else |

The miner works with any pool. The 1 % on the pool in this repository is what
keeps the project running; the miner itself takes nothing either way, and there
is no account, token or telemetry anywhere in it.

## Three decisions that shape everything else

**The fee is provable, so it is checked.** `sudo ./oneclick.sh verify` greps the
binary for the upstream donation endpoints and known wallets, then runs hash
self-tests so that "it found nothing" cannot mean "it looked at the wrong file".
See [the fee page](/docs/reference/fee) for the rate, the log lines and how to turn it off.

**There are no flags to start.** `--wallet` is the only required input. The
installer reads the CPU, the RAM, the hypervisor and the battery, then picks the
engine, the thread count, the huge-page strategy and the governor, and prints
the reason for each choice before it acts. `./oneclick.sh plan` shows every
decision and changes nothing.

**A miner that is not earning should say so.** A rig whose pool rejects every
share looks perfectly healthy from outside. `zmrig` judges its own numbers once
a second and exits so the supervisor restarts it — twenty seconds of lost
hashrate instead of a night of zero.

## Requirements

- Linux x86-64 (Debian/Ubuntu, RHEL/Fedora, Arch; the script detects the distro).
  macOS and Windows can build the C++ engine, but the installer targets Linux.
- 2 GB of free RAM for `fast` mode, or `--mode light` with about 300 MB.
- `systemd` if you want it as a service.
- root, for huge pages, MSR and the service.
- A network connection for the first build. Everything is compiled on the
  machine; no binary is downloaded from anywhere.

## Where the code came from

Nothing here was written from scratch, and the parts that were not are credited
in the repository's `NOTICE` file:

| Project | What it contributes | Licence |
| --- | --- | --- |
| [XMRig](https://github.com/xmrig/xmrig) | the C++ miner, the RandomX engine, the config format, the CLI | GPL-3.0 |
| [RandomX](https://github.com/tevador/RandomX) | the proof-of-work algorithm and its JIT | BSD-3-Clause |
| [MoneroOcean](https://github.com/MoneroOcean/xmrig) | the switching-pool model and the `-mo` lineage | GPL-3.0 |
| [Monero](https://github.com/monero-project/monero) | the coin, the daemon and wallet RPC | BSD-3-Clause |
| libuv, hwloc, rapidjson, `{fmt}` | networking, topology, config, formatting | MIT / BSD / ICU |

The Zig miner, the installer, the proxy, the pool and this site are original.
Everything is GPL-3.0, Copyright (C) 2026 @nggkhaiz.

## Next

- [Install in one command](/docs/install/quickstart) — the five minutes most
  people need.
- [Choosing an engine](/docs/install/engines) — `zmrig` or `xmrig`.
- [Pools and money](/docs/pools/choosing) — fees, minimums, and how not to get
  an IP banned.
- [Profitability calculator](/docs/economics/profitability) — paste the codes
  your machines print.

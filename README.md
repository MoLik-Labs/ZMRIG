<div align="center">

<img src="site/static/img/logo.svg" alt="" width="72" height="72">

# ZMRIG

**A RandomX miner with a developer fee you can see and switch off,<br>the pool that pays for it, a proxy for the whole farm, and the site that puts it together.**

by **[@nggkhaiz](https://github.com/NggKhaiz)**

[![release](https://img.shields.io/badge/release-6.34.0-f2763f)](CHANGELOG.md)
[![licence](https://img.shields.io/badge/licence-GPL--3.0-blue)](LICENSE)
[![dev fee](https://img.shields.io/badge/developer%20fee-1%25%20%C2%B7%20off%20switch-f2763f)](doc/FEE.md)
[![platform](https://img.shields.io/badge/platform-Linux%20x86--64%20%C2%B7%20macOS%20%C2%B7%20Windows-lightgrey)](#build-from-source)
[![tests](https://img.shields.io/badge/tests-12%20suites-46b17b)](#tests)
[![stars](https://img.shields.io/github/stars/NggKhaiz/ZMRIG?style=flat&color=f2763f)](https://github.com/MoLik-Labs/ZMRIG/stargazers)
[![last commit](https://img.shields.io/github/last-commit/NggKhaiz/ZMRIG)](https://github.com/MoLik-Labs/ZMRIG/commits/BETA)

[Install](#install-in-one-command) · [Docs](https://molik-labs.github.io/ZMRIG/docs/intro) · [Documentation](#documentation) · [Performance](#performance) · [Credits](#credits) · [Donate (optional)](#support)

</div>

---

ZMRIG is a complete Monero mining setup, not a loose collection of scripts:

| Part | What it is | What it costs |
| --- | --- | --- |
| **Miner** — `src/`, `zmrig/`, `oneclick.sh` | XMRig `6.26.0` fork with every line of donation code removed, plus a complete Zig miner on the same RandomX engine | **1 %** of Monero time on the Zig engine, printed and switchable off; the C++ engine has no fee code at all |
| **Proxy** — `proxy/` | One pool connection for a farm: extranonce per rig, per-rig difficulty, tunnels for rigs in another building | free |
| **Pool** — `pool/`, `worker/`, `deploy/` | Self-hosted Monero pool: stratum over TCP and WebSocket, PPLNS, every share re-hashed before it is paid | 1 % of each block, and nothing else |
| **Image** — `os/` | A bootable ZMRIG OS: kernel, read-only Alpine root, `zmrig`, a wallet wizard, four hashrate modes, verified updates, and CI that rebuilds the ISO on every change | free |
| **Docs** — `site/` | Docusaurus site: command builder, profitability calculator, pool table, every guide — English and Vietnamese | free to host |

Point the miner at any pool. If you point it at the pool in this repository,
the 1 % fee is what keeps the project alive; the miner itself takes nothing
from you either way, and there is no account, no token and no telemetry
anywhere in it.

---

## Table of contents

[What makes it different](#what-makes-it-different) ·
[Install](#install-in-one-command) ·
[Bootable image](#bootable-image) ·
[Check the fee](#check-the-fee) ·
[Pools, and not getting banned](#pools-and-not-getting-banned) ·
[Farms](#farms-one-connection) ·
[Self-hosted pool](#self-hosted-pool) ·
[Performance](#performance) ·
[Repository layout](#repository-layout) ·
[Tests](#tests) ·
[Documentation](#documentation) ·
[Branches](#branches-and-releases) ·
[Credits](#credits) ·
[Licence](#licence) ·
[Support](#support)

---

## What makes it different

Most miners ask you to trust a percentage. This one is built so the percentage
can be checked, and so the things that quietly cost money are handled where
they happen:

1. **A 1 % fee that is printed, earned and can be switched off.** A pool pays
   whoever logs in, so the fee is time — 60 s of Monero mining per 100 minutes —
   on the developer's wallet, through the pool you already use. `--check`, the
   banner, every session in the log and `--donate-level=0` all say so, and
   `scripts/verify-fee.sh` reads the rate, the address and the off switch out of
   the binary. [`doc/FEE.md`](doc/FEE.md).
2. **Zero flags to start.** `--wallet <address>` is the only required input: the
   installer detects the CPU, the RAM, the hypervisor and the battery, then picks
   the engine, the thread count, the huge-page strategy and the CPU governor,
   and prints the reason for each choice before it acts.
3. **It tells you when it stops earning.** A miner whose pool rejects every
   share looks perfectly healthy from outside. `zmrig` judges its own numbers
   once a second and exits so the supervisor can restart it — 20 seconds of
   lost hashrate instead of a night of zero.
4. **A refusal is a decision, not a retry loop.** A banned IP, a wrong wallet,
   a rate limit: each is classified, each gets its own cooldown per pool, and
   reconnects are jittered so a rack of rebooting rigs does not arrive in the
   same millisecond. This is the difference between one bad evening and a
   permanent block.
5. **One command that can be undone.** `purge --dry-run` lists every path the
   tool created, with sizes, before anything is deleted, and a test asserts it
   never touches a file it did not make.

## Install in one command

```bash
curl -fsSL https://raw.githubusercontent.com/NggKhaiz/ZMRIG/BETA/oneclick.sh \
  | sudo bash -s -- --wallet 4YourMoneroAddress...
```

That is the whole install. It fetches the sources, builds for this CPU, tunes
the host (huge pages, THP, governor, MSR), measures the machine to find the best
thread count, writes a systemd unit, audits the developer fee and prints live stats.
Re-running is safe: an existing config is never overwritten without `--force`.

Do not want to remember flags? The **[command builder](https://molik-labs.github.io/ZMRIG/docs/install/builder)**
asks for the wallet, the pool and the network of the machine, validates the
address as you type, and prints exactly this command — plus a `plan` variant
that resolves everything and changes nothing. The builder and the pool table on
the site are generated from one module, and `site/tests/pools.test.mjs` fails if
that table ever disagrees with `oneclick.sh` or `doc/POOLS.md`. The step-by-step
wizard it replaced was folded into that page; `web/wizard.html` now redirects
into the documentation.

### Other coins

Both engines hash the whole RandomX family plus Panthera, so the same installer
mines seven coins. `--coin` is the short form of `--algo`, and the plan prints
which coin it resolved:

| `--coin` | Coin | Algorithm |
| --- | --- | --- |
| `xmr` | Monero (default) | `rx/0` |
| `wow` | Wownero | `rx/wow` |
| `arq` | ArQmA | `rx/arq` |
| `graft` | Graft | `rx/graft` |
| `sfx` | Safex Cash | `rx/sfx` |
| `yada` | YadaCoin | `rx/yada` |
| `xla` | Scala | `panthera` |

```bash
sudo ./oneclick.sh plan --wallet YourWowneroAddress... --coin wow --pool pool.example.org:3333
sudo ./oneclick.sh install --wallet YourWowneroAddress... --coin wow --pool pool.example.org:3333
```

Pool presets exist for Monero only: the smaller coins' endpoints and fees change
too often to hard-code, so `--coin wow` without `--pool` is an error rather than
a guess. The engine follows the algorithm (`rx/*` and `panthera` → the Zig
engine), and the address is checked for the shape this repository can be
sure of — the pool verifies the checksum. Which coin pays best for your
hashrate: **[other coins](https://molik-labs.github.io/ZMRIG/docs/pools/coins)**,
where the ranking comes from numbers you paste, and prices are fetched only when
you ask.

See every automatic decision and its reason without touching the machine:

```bash
./oneclick.sh plan
```

## Bootable image

A machine you only mine on should not be a general-purpose computer. Write this
image to a USB stick, boot the rig, paste your wallet:

```bash
sudo dd if=zmrig-os-<version>-x86-64-v3.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

It is a live image, not an installer: nothing is written to any disk, the stick
is never modified, and pulling it out leaves the machine exactly as it was.

- **Tuned by construction.** 2 MiB pages are reserved by the initramfs before any
  userspace program has fragmented memory (+4–6 % over transparent huge pages),
  THP stays on, the governor is `performance`, `swappiness=1`, write-back
  throttled, NMI watchdog off — and nothing else runs on the box.
- **Four modes**, changeable without a reboot: `max`, `balanced`, `eco`, `light`.
  Each one also has its own GRUB entry, so a machine with no keyboard and no
  network can still be switched.
- **Stable on purpose:** the miner exits on a stall, the supervisor restarts it,
  five failed starts reboot the box, logs rotate, chrony keeps the clock.
- **Updates are verified:** `zmrig-os update --apply` swaps in a sha256-checked
  static binary inside the running image; reboot and you are back on the version
  burned into the stick, which is the entire rollback story.
- **Two builds** — `x86-64-v3` (AVX2) and `x86-64-v2` (everything since Nehalem) —
  rebuilt by CI whenever `os/`, `zmrig/` or the tuner changes, with every past
  version kept. The workflow is `.github/workflows/os.yml` and it also runs on a
  pull request that touches `os/`, so the image is built before it is merged.
  `os/smoke-qemu.sh` boots the finished ISO in QEMU and fails
  unless it reaches userspace, so the claim is "it boots", not "it builds".

`zmrig-os status`, `mode`, `logs`, `bench 30`, `doctor`, `update`, `ssh-key` and
`autotune`, `persist` are the whole interface; `doc/OS.md` is the operator manual and
[docs/appliance/iso](https://molik-labs.github.io/ZMRIG/docs/appliance/iso) is the
guide.

---

## Check the fee

```bash
sudo ./oneclick.sh verify
```

```
==> verifying zmrig
    OK  PASS rx/0 reference vector
    OK  PASS pipelined hashing
    OK  PASS full-memory dataset matches the cache
    OK  PASS rx/0 reference vector
    OK  fee audit: one wallet, Monero only, switchable off
    OK  verified
```

The audit reads the rate out of the source and the binary, confirms `--check`
prints the address and the cadence, confirms `--donate-level=0` prints `off`,
and fails if a second wallet or an upstream donation endpoint appears. The hash
self-tests run too, so "it found nothing" cannot mean "it looked at the wrong
file". [`doc/FEE.md`](doc/FEE.md) has the full policy in one page.

## Everyday commands

```bash
sudo ./oneclick.sh status            # service, hashrate, shares, health
sudo ./oneclick.sh bench             # 180 s RandomX measurement
sudo ./oneclick.sh report --power 95 # ZMRIG1. code for the fleet calculator
sudo ./oneclick.sh update            # git pull, rebuild, restart
sudo ./oneclick.sh tune              # re-run host tuning + thread search
sudo ./oneclick.sh logs              # journalctl, last 200 lines
```

From the miner itself:

```bash
zmrig --self-test                    # hash vectors, benchmark, memory pre-flight
zmrig --bench=20000                  # fixed hash count, same seed every time
zmrig --report --power 95            # prints ZMRIG1.<base64url> in ~15 s
zmrig --autotune=8                   # measure thread counts; no pool needed
zmrig -o gulf.moneroocean.stream:10001 -u 4YourAddress.rig1 -a auto
```

## Pools, and not getting banned

Fees are a percentage; an IP that cannot connect is 100 % of the income. Both
are handled, in that order.

| Pool | Fee | Min payout | Endpoint | Why |
| --- | ---: | ---: | --- | --- |
| **MoneroOcean** | 0 % | 0.003 XMR | `gulf.moneroocean.stream:10001` | pays the best RandomX coin per hash, pays out in XMR |
| SupportXMR | 0.6 % | 0.1 XMR | `pool.supportxmr.com:3333` | largest pool, lowest variance |
| C3Pool | 0 % | 0.003 XMR | `c3pool.com:3333` | 0 %, no switching, different infrastructure |
| HeroMiners | 0.9 % | 0.01 XMR | `monero.herominers.com:10191` | smallest payout threshold |
| xmrpool.eu | 0.9 % | 0.07 XMR | `xmrpool.eu:3333` · `:443` TLS | 443-only networks; strictest ban policy |
| P2Pool mini / nano | 0 % | ~0.0004 XMR | `pool.xmr.pub:3333` · `:3334` | no pool owner, block-by-block payouts |

```bash
sudo ./oneclick.sh install --wallet 4YourAddress... \
  --pool=moneroocean --failover=supportxmr,c3pool
```

Short names resolve to the right host, port and TLS mode; `--failover` writes
backup pools into `config.json`, used only when the first is unreachable or
refuses this IP. What the miner refuses to do, because each of these is how an
IP gets banned:

* retry a **wrong wallet** every five seconds — it identifies the refusal, leaves
  that pool alone for 30 minutes and prints the fix;
* reconnect immediately after `your IP is banned` — 15 minutes per pool
  (`--ban-cooldown`), then the next one;
* keep submitting once the pool has called three shares **invalid** — a
  10-minute pause instead of the hour-long ban `xmrpool.eu` hands out;
* let twenty rebooting rigs reconnect in the same millisecond — every retry is
  jittered ±20 %.

The usual reason a rig stops is not a pool ban but DNS filtering: Quad9 returns
NXDOMAIN for `gulf.moneroocean.stream`, Cloudflare's malware resolver does the
same for `pool.supportxmr.com`. A backup pool on another domain, a regional
hostname, TLS on 443 or `--connect-to` gets past it. Sources and the full
table: [`doc/POOLS.md`](doc/POOLS.md).

### Networks that only allow 443

```bash
# WebSocket + TLS on 443, the shape that survives HTTPS-only egress and CDNs
sudo ./oneclick.sh install --wallet 4YourAddress... \
  --pool pool.example.com --cloudflare --ws-path /stratum

# or a proxy the host already has
zmrig -o gulf.moneroocean.stream:10001 -u 4YourAddress.rig1 \
  --proxy socks5://127.0.0.1:9050
```

`--connect-to` dials an IP while keeping the hostname for SNI and `Host`, for
the case where DNS is poisoned but the route works. Details:
[`doc/NETWORK.md`](doc/NETWORK.md).

## Farms: one connection

A farm loses money in three ways that never appear in a miner log: two rigs
computing the same nonce, one difficulty that starves the smallest machine, and
a login storm that gets the public IP rate-limited.

```bash
sudo ./proxy/install.sh --user=<wallet> --pool=gulf.moneroocean.stream:10001
```

* **one upstream connection**, one login at the pool, for up to 255 rigs;
* **one nonce byte per rig**, so no two machines can find the same share — the
  byte order is unit-tested because getting it wrong looks healthy from outside;
* **per-rig difficulty**, ~15 s between shares whether the rig does 500 H/s or
  20 kH/s;
* **rigs survive the pool dying**: sockets stay open, the last job is replayed,
  a pool that refuses the login is left behind immediately;
* **one flag for the network**: `--tunnel=wireguard` (fixed `10.66.66.x`, UDP, no
  third party), `tailscale`, `cf`, `cf-quick`;
* **H/s and XMR/day per rig** in `/status`, measured from accepted shares, and
  `null` when the network difficulty is unknown rather than guessed.

60 tests, including real sockets and a WebSocket rig. Tunnel comparison and the
WireGuard recipe: [`doc/PROXY.md`](doc/PROXY.md).

## Self-hosted pool

* **Stratum over TCP and WebSocket** — the second one is what makes a miner work
  on a host that only allows outbound 443.
* **Every share verified** — the pool re-hashes each submitted blob with
  `zmrig --verify-share`; a hash that does not match closes the connection
  instead of being paid.
* **PPLNS in BigInt piconero** — no floating point near money, fee rounded down,
  dust listed instead of absorbed.
* **Auditable** — `/api/audit` and `audit.jsonl` carry the reward, the fee and
  every miner payment for every block.
* **No dependencies** — `node pool/src/index.js`, no `npm install`, no database.
* **Free to host** — one process, one port; Render for WSS, Fly.io for raw TCP,
  a Cloudflare Worker in front when rigs are behind a restrictive network.

```bash
cd pool
node src/index.js --check --config config.json   # validate and exit
node src/index.js --config config.json           # stratum + HTTP
npm test                                         # 29 tests, includes a real miner
```

Fees from a reference deployment go to the wallet in
[`doc/DONATE.md`](doc/DONATE.md); your own instance pays your own wallet.

## Performance

Measured on a 2 vCPU Xeon at 2.6 GHz, 3.9 GiB RAM, `rx/0`, mode `fast`. Absolute
hashrate on shared vCPU moves with the host (20–25 % between sessions on the
same box), so the ratios are the useful part.

| Configuration | Hashrate | Ratio |
| --- | ---: | ---: |
| tuned install (huge pages reserved by the miner, affinity) | **800–841 H/s** | 100 % |
| stock defaults, nothing reserved (a fresh VPS: THP backs the mapping) | 786 H/s | 95 % |
| no huge pages at all, THP off (4 KiB) | 615–626 H/s | 76 % |
| `-t 1` (one thread on two vCPUs) | 553 H/s | 52 % |
| `--mode light` (256 MiB cache, for tiny VPS) | 82 H/s | 10 % |
| `--no-jit` (interpreter only) | ~180 H/s | never for mining |

Everything else that was tried — scratchpad prefetch modes, `--no-affinity`,
`--no-optimized-init`, VAES-512 — landed inside noise or worse, and is
documented as such instead of being sold as a speed-up. The full table, the
method and the commands: [`doc/BENCHMARKS.md`](doc/BENCHMARKS.md) and
[`doc/PERFORMANCE.md`](doc/PERFORMANCE.md).

**Worth more than any rewrite:** huge pages (the miner reserves them itself),
MSR on bare metal, one thread per physical core, and a governor that does not
downclock. `./oneclick.sh install` does all four.

## Repository layout

```
oneclick.sh            installer: build, tune, config, service, verify, purge
zmrig/                 the Zig miner (build.sh, src/, tests/, capi/ bindings)
os/                    the bootable image (initramfs init, Alpine chroot, zmrig-os, CI)
src/                   the C++ miner (XMRig 6.26.0, donation code removed)
proxy/                 one pool connection for a farm (node, no dependencies)
pool/                  self-hosted Monero pool (node, no dependencies)
  worker/              Cloudflare Worker: WebSocket -> TCP bridge
site/                  documentation site (Docusaurus, en + vi) — the only site now
web/ docs/ assets/ vi/ the published site, generated by scripts/publish-site.sh
legacy/                the previous hand-written site, archived and not deployed
doc/                   everything written down (see Documentation)
scripts/               build, tune, benchmark, audit helpers
tests/                 installer and hash-conformance suites
CHANGELOG.md           one entry per release, newest first
NOTICE                 attribution and upstream lineage
```

## Tests

Twelve suites, no mocks where a socket will do. Run them all:

```bash
sudo apt install -y build-essential cmake nodejs python3   # once
./zmrig/build.sh --jobs 2
cd site && npm install && cd ..          # once, for the docs site tests
npm install --no-save jsdom                # once, for the archived site's tests
./os/tests/control.sh                      # the appliance tool (no root)
npm run test:web && npm run test:pool && npm run test:oneclick
npm run test:site && npm run test:docs && npm run test:pages
cd proxy && npm test
cd .. && ./zmrig/tests/unit.sh && ./zmrig/tests/cli.sh && ./zmrig/tests/health.sh
./zmrig/tests/net.sh --soak
```

Each suite prints its own count when it runs, and the count in this table is
that output — not a total maintained by hand, which is how a badge can claim 538
checks while two of the rows are wrong.

| Suite | Assertions | What it proves |
| --- | ---: | --- |
| `web` `node --test legacy/tests/` | 57 | the archived site: wizard and builder produced the same command, pool table matched `oneclick.sh`, branch names, donation address |
| `proxy` `npm test` | 60 | extranonce allocation, vardiff, real sockets, WebSocket rig, banned pool left alone |
| `pool` `npm test` | 29 | PPLNS in BigInt, share verification, payouts, audit log, end-to-end with a real miner |
| `zmrig/tests/unit.sh` | 18 modules | options, hashing, health, report codes, stratum parsing, proxy handshakes, and the per-algorithm memory rule |
| `zmrig/tests/cli.sh` | 49 | flags, exit codes, `--help` covers the parser, `--check` reports the memory of the coin it was asked about and which huge-page mechanism backs it |
| `zmrig/tests/net.sh` | 29 | TCP/TLS/WS/WSS against a fake pool, ban and refusal handling, failover, seed change |
| `zmrig/tests/health.sh` | 7 | the watchdog, both directions: an honest pool is not a fault, an all-reject pool is |
| `tests/oneclick/*.sh` | 63 | plan, config, governor, purge (removes only its own paths), branch switching, `--coin` mapping and the algorithm-name guard |
| `tests/docs/links.sh` | 90 | every relative link and every `#anchor` in the documentation resolves, including `/docs/…` site routes |
| `site` `npm test` | 67 | command builder and its blocked states, calculator arithmetic against hand-computed numbers including break-even, pool table vs `oneclick.sh` and `doc/POOLS.md`, coin matrix and ranking (a missing number is never a zero, no invented pool or price), en/vi key parity and no dead or duplicated message |
| `tests/docs/pages.sh` | 22 | the published site as Pages serves it: Docusaurus entry point, 23 sidebar pages in both locales, all 2494 local `href`/`src`, both sitemaps, language and theme controls, one localised social card per page, a title/description/lang on every page with no leaked placeholder, old-URL redirects, committed build not stale |
| `os/tests/control.sh` | 66 | the appliance tool: wallet validation (length, base58 alphabet, prefix), a command line per mode, kernel-command-line overrides, the supervisor waiting for a wallet, and an updater that refuses a checksum mismatch — all with no root, no miner and no network |

## Documentation

* [`doc/INSTALL.md`](doc/INSTALL.md) — installer, every option, service layout,
  unattended fleet install, troubleshooting.
* [`doc/SETUP.md`](doc/SETUP.md) — the things only a repository owner can do:
  settings, workflows, publishing the site, deploying the pool.
* [`doc/DOCS-SITE.md`](doc/DOCS-SITE.md) — how the documentation site is built,
  published, searched (Algolia DocSearch) and translated.
* **[The site itself](https://molik-labs.github.io/ZMRIG/docs/intro)** —
  [English](https://molik-labs.github.io/ZMRIG/docs/intro) ·
  [Tiếng Việt](https://molik-labs.github.io/ZMRIG/vi/docs/intro): install guide,
  command builder, [profitability calculator](https://molik-labs.github.io/ZMRIG/docs/economics/profitability),
  pools, fleet, benchmarks, architecture, testing.
* [`doc/OS.md`](doc/OS.md) — the bootable image: boot sequence, modes, the
  sysctl lines and why each one is there, persistence, updates, CI, and the
  troubleshooting table.
* [`doc/PERFORMANCE.md`](doc/PERFORMANCE.md) · [`doc/BENCHMARKS.md`](doc/BENCHMARKS.md)
  — every lever that affects hashrate, with the measurements.
* [`doc/POOLS.md`](doc/POOLS.md) — pool fees and policies, and how to keep
  mining when DNS or a firewall says no.
* [`doc/NETWORK.md`](doc/NETWORK.md) — 443-only VPS, proxies, edge dialling.
* [`doc/PROXY.md`](doc/PROXY.md) — farms: extranonce, vardiff, tunnels.
* [`doc/ARCHITECTURE.md`](doc/ARCHITECTURE.md) — the code base, thread by thread.
* [`doc/ZERO_FEE.md`](doc/ZERO_FEE.md) — what was removed and how to verify it.
* [`doc/DONATE.md`](doc/DONATE.md) — the one address, how to check it, and what
  a donation does and does not buy.
* [`doc/ALTERNATIVES.md`](doc/ALTERNATIVES.md) — measured comparison with Rust
  and Go miners, and why the C++ RandomX JIT stays.
* [`zmrig/README.md`](zmrig/README.md) · [`pool/README.md`](pool/README.md) ·
  [`proxy/README.md`](proxy/README.md) · [`legacy/README.md`](legacy/README.md)
* [`site/docs/`](site/docs/) — the source of the documentation site, and
  [`site/i18n/vi/`](site/i18n/vi/) for the Vietnamese translation.

## Branches and releases

```
ALPHA  ──►  BETA  ──►  master
newest      default      history + tags
work        (install)
```

| Branch | What it is | How to use it |
| --- | --- | --- |
| **`BETA`** | default branch, the released state | every command in this README already uses it |
| `ALPHA` | the next release, may break | `MINER_BRANCH=ALPHA sudo -E ./oneclick.sh install --wallet …` |
| `master` | upstream history plus merge commits, tagged per release | reference only |

`oneclick.sh` is the only place that hard-codes a branch, and
`legacy/tests/branches.test.js` fails if any link, one-liner or default points
somewhere else — the installer once pointed at a short-lived branch and `update`
failed silently, which is exactly the class of bug a test should own.

## Credits

ZMRIG is built by **[@nggkhaiz](https://github.com/NggKhaiz)** and stands on
work that is not mine. Nothing here would exist without it, and every
copyright header is intact — see [`NOTICE`](NOTICE).

| Project | What it contributes | Licence |
| --- | --- | --- |
| [XMRig](https://github.com/xmrig/xmrig) (xmrig.com, SChernykh) | the C++ miner, the RandomX engine, the config format, the CLI | GPL-3.0 |
| [RandomX](https://github.com/tevador/RandomX) (tevador) | the proof-of-work algorithm and its JIT | BSD-3-Clause |
| [MoneroOcean](https://github.com/MoneroOcean/xmrig) | the algorithm-switching pool model and the `-mo` lineage | GPL-3.0 |
| [Monero](https://github.com/monero-project/monero) (The Monero Project) | the coin, the daemon, wallet-rpc | BSD-3-Clause |
| [libuv](https://libuv.org), [hwloc](https://www.open-mpi.org/projects/hwloc/), [rapidjson](https://rapidjson.org), [{fmt}](https://fmt.dev) | networking, topology, config, formatting | MIT / BSD / ICU |

**Where the numbers come from.** Every hashrate in this repository was measured
with `zmrig/tests/ab.sh` or `zmrig --bench` on the same 2 vCPU Xeon host, one
configuration per run, dataset built before the timer starts; the raw tables and
the exact commands are in [`doc/BENCHMARKS.md`](doc/BENCHMARKS.md). Where a
measurement landed inside noise, it says so instead of becoming a selling point.

**Where the pool data comes from.** Fees, minimum payouts and port lists were
read from each pool's own pages and public stats (`cryptunit`, `xmr.pub`, the
`xmrpool.eu` FAQ) in **October 2026**, and are dated in
[`doc/POOLS.md`](doc/POOLS.md). DNS-blocking reports come from the resolvers'
own blocklists. These numbers change; the file says when it was checked so you
can tell how stale it is.

## Licence

GPL-3.0. The C++ miner is XMRig, Copyright (C) 2016-2026 xmrig.com and
Copyright (C) 2018-2026 SChernykh; RandomX is Copyright (C) tevador and
contributors; the MoneroOcean work is Copyright (C) MoneroOcean. This fork adds
the Zig engine, the installer, the proxy, the pool and the site, all under the
same licence, Copyright (C) 2026 @nggkhaiz. Full text in [`LICENSE`](LICENSE),
attribution in [`NOTICE`](NOTICE).

## Support

The Zig engine already pays 1 % of its Monero time, so the honest answer to
"how do I support this?" is: you already are, and `--donate-level=0` ends it. If
you want to give more than the fee, there is exactly one address:

<p align="center">
  <img src="doc/donate/monero.png" width="190" alt="QR code for the Monero address 46SQLW7D…n6ysb5tJ">
</p>

```text
46SQLW7DXaq6GJaQbHUFMAhd1VYpfQFJQ2gfZo9TCB8bf9vnf1MUwAD2Fwj6KMsY4RU3oKA3x6hByg8BKg7FfMWn6ysb5tJ
```

Monero (XMR), mainnet, 95 characters, network byte `18`, base58 checksum valid.
It is the same wallet the miner's 1 % time fee and the pool's 1 % block fee are
paid to, so a thank-you and a fee payment land in one place with one audit trail;
the verification recipe is in [`doc/DONATE.md`](doc/DONATE.md). No flag, config
key or service reads the address in this paragraph — it is text, and
`./scripts/verify-fee.sh` shows the one address the binary itself uses.

**Worth more than money:** mine through the pool, send a before/after
measurement, or open an issue with the command, the full output and the
hardware. Addresses in forks, issues, videos or direct messages are not mine;
only the one above is.

<div align="center">

[![Star History Chart](https://api.star-history.com/svg?repos=NggKhaiz/ZMRIG&type=Date)](https://star-history.com/#NggKhaiz/ZMRIG&Date)

<sub>ZMRIG · made by <a href="https://github.com/NggKhaiz">@nggkhaiz</a> · GPL-3.0 · no tracking, no accounts · 1 % developer fee on Monero time, switchable off</sub>

</div>

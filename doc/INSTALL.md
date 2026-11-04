# One-click install

`oneclick.sh` turns a bare Linux machine into a tuned, supervised RandomX miner.
One command, no manual steps, safe to re-run.

```bash
# on a fresh machine (clones the repository for you)
curl -fsSL https://raw.githubusercontent.com/MoLik-Labs/ZMRIG/BETA/oneclick.sh \
  | sudo bash -s -- --wallet 4YourMoneroAddress...

# or inside a checkout
sudo ./oneclick.sh --wallet 4YourMoneroAddress...
```

That single command:

1. detects the distribution and installs the build dependencies (cmake, C++,
   libuv, OpenSSL) with `apt`/`dnf`/`pacman`/`zypper`/`apk`/`brew`;
2. builds a Release binary tuned for the exact CPU it runs on;
3. **measures the machine** and picks the thread count (`--autotune`, ~1 minute,
   skip with `--no-autotune`);
4. reserves huge pages for the RandomX dataset, sets THP to `madvise`, sets the
   governor the profile asks for and enables the MSR module;
5. writes a validated config with your wallet, the pool, the profile and the
   measured thread count;
6. installs the binary and a `systemd` service that restarts on failure and a
   oneshot unit that re-applies the tuning on every boot;
7. starts it, waits for the first real hashrate, audits the developer fee and
   prints a summary card.

Only the wallet is required. The engine is `zmrig` unless the hardware cannot
run it or `--algo` names a non-RandomX algorithm: on a pool that switches coins
(MoneroOcean and its clones) the config advertises the whole RandomX family
(`"algo": "auto"`), so the pool can still move the rig to whichever coin pays
best while the rig keeps the Zig engine. A non-RandomX `--algo` (cn/2, …)
or `--engine=xmrig` selects the C++ engine, which speaks all 34 algorithms. The
profile comes from the battery state. `./oneclick.sh plan` prints every decision
with its reason and touches nothing.

End state:

| Path | What |
|---|---|
| `/usr/local/bin/zmrig` | the miner (the C++ engine installs as `xmrig`) |
| `/usr/local/bin/zmrig-tune` | host tuning (`--status`, `--hugepages 1G`, `--algo panthera` sizes the reservation for that coin, …) |
| `/usr/local/bin/zmrig-bench` | reproducible hashrate measurement |
| `/usr/local/bin/zmrig-verify` | audits the developer fee: rate, address, off switch |
| `/etc/zmrig/config.json` | configuration (rewritten by autosave) |
| `zmrig.service` | supervised miner, `Restart=always`, `Nice=-10` |
| `zmrig-tune.service` | oneshot tuner, runs before the miner at boot |
| `http://127.0.0.1:18080/2/summary` | live read-only monitoring API (XMRig JSON; `"http"` in the config) |

```bash
sudo ./oneclick.sh status     # service state, hashrate, accepted shares
sudo ./oneclick.sh logs       # last 40 log lines (journal)
sudo ./oneclick.sh bench      # 180 s RandomX measurement
sudo ./oneclick.sh report     # machine report code for the web dashboard
sudo ./oneclick.sh verify     # fee audit
sudo ./oneclick.sh update     # git pull + rebuild + restart
sudo ./oneclick.sh plan       # what the installer would do here, and why
sudo ./oneclick.sh tune       # host tuning + thread search again
sudo ./oneclick.sh uninstall  # stop, disable, remove binaries (config kept)
sudo ./oneclick.sh purge      # remove everything, config included (asks first)
```

---

## Options

| Option | Meaning |
|---|---|
| `--wallet ADDR` | Monero address (95 chars) or pool login. Asked interactively when omitted. |
| `--pool HOST:PORT` | pool endpoint, default `gulf.moneroocean.stream:10001`. A short name also works: `moneroocean`, `supportxmr`, `c3pool`, `xmrpool`, `herominers`, `p2pool`, `p2pool-nano`. |
| `--failover LIST` | comma-separated backup pools, written into `config.json` and used only when the first is unreachable or refuses this IP. See [POOLS.md](POOLS.md). |
| `--pass VALUE` | pool password, default `x` |
| `--rig-id NAME` | name shown on the pool dashboard |
| `--algo NAME` | pin one algorithm (`rx/0`, `cn/r`, …). Also **skips the 2-minute calibration**, see below. |
| `--engine NAME` | `auto` (default), `xmrig` (every algorithm) or `zmrig` (the Zig miner, RandomX family). `auto` picks `zmrig` and advertises the RandomX family at login, which is what a switching pool needs to move this rig between coins; a non-RandomX `--algo` picks the C++ engine. See [The Zig engine](#the-zig-engine). |
| `--profile NAME` | `auto` (default), `free` (maximum hashrate, watts ignored) or `watt` (maximum hashrate per watt). `auto` is `free`, except on a laptop on battery. See [profiles](#profiles-free-vs-watt). |
| `--autotune[=SEC]` | search for the best thread count after the build, `SEC` seconds per candidate (default 8). On by default for `zmrig`. |
| `--no-autotune` | keep the built-in `L3 / 2 MiB` heuristic |
| `--dry-run` | with `purge`: print what would be removed, delete nothing |
| `--no-health-restart` | never exit to recover from a stalled miner (default: exit after 15 min of `stalled`/`rejected` so systemd restarts it) |
| `--ban-cooldown N` | seconds a pool is left alone after it bans this IP (default `900`). A wrong wallet is clamped to at least 30 minutes, because waiting does not fix it. |
| `--tls` | TLS stratum |
| `--cloudflare[=HOST[:PORT]]` | WebSocket inside TLS on 443 and the `zmrig` engine: the one shape that passes HTTPS-only egress and CDNs. See [doc/NETWORK.md](NETWORK.md). |
| `--transport KIND` | `tcp`, `tls`, `ws` or `wss`, overriding the scheme in `--pool` |
| `--ws-path PATH` | WebSocket path used by `--cloudflare` |
| `--ws-origin URL` | `Origin` header for the WebSocket upgrade |
| `--proxy URL` | `http://user:pass@host:port` or `socks5://user:pass@host:port` |
| `--connect-to HOST:PORT` | dial this address, keep the pool name for SNI/`Host` |
| `--tls-ca FILE` | trust a private CA / pin a relay certificate |
| `--idle-timeout N` | reconnect when the pool is silent for `N` s (`0` = never) |
| `--no-http` | do not enable the local monitoring API (default: on, port 18080) |
| `--cpu-hint N` | `max-threads-hint`, default `100` |
| `--all-backends` | also build OpenCL/CUDA support |
| `--no-tune` | do not touch huge pages / MSR / governor |
| `--no-service` | configure only, do not install a service |
| `--no-build` | reuse an existing build directory |
| `--build-dir DIR` | where to compile (default `/usr/local/src/zmrig-build`) |
| `--prefix DIR` | install prefix (default `/usr/local`) |
| `--force` | regenerate the config even if it exists |
| `--yes` | never prompt |

`zmrig` also takes `--health-restart=SEC`, `--health-warmup=SEC`, and reads
`"health": {"restart": false, "warmup": 180}` from the config.

Do not want to remember any of these? The published site has a four-step
[wizard](https://molik-labs.github.io/ZMRIG/wizard.html) that produces the same
command, plus a `plan`-only variant that changes nothing on the host. Every
short pool name above is a clickable card there.

Environment variables for unusual setups: `UV_INCLUDE_DIR`, `UV_LIBRARY`
(locally built libuv), `MINER_REPO_URL`, `MINER_BRANCH`, `MINER_POOL`,
`MINER_PASS`, `MINER_PREFIX`, `MINER_CONFIG_DIR`, `MINER_STATE_DIR`,
`MINER_SERVICE_DIR` (default `/etc/systemd/system`), `MINER_ENGINE` (same as
`--engine`), `MINER_PROFILE` (same as `--profile`), `MINER_AUTOTUNE`,
`MINER_AUTOTUNE_SECONDS`, `MINER_AUTOTUNE_THREADS` (skip the search and pin this
count), `MINER_ZIG_VERSION` (default `0.13.0`).

---

## Profiles: free vs watt

```bash
sudo ./oneclick.sh install --wallet 4YourAddress... --profile free
sudo ./oneclick.sh install --wallet 4YourAddress... --profile watt
```

`free` — the machine's electricity costs you nothing (a coffee shop, a lab, an
office PC that is on anyway). Every logical CPU, `--mode fast`, huge pages,
`--priority 5`, `performance` governor. This is the default everywhere except a
laptop on battery.

`watt` — every watt is on the bill (a metered VPS, a laptop, expensive power).
One thread per physical core, no governor forcing, mining paused on battery, and
hashes per watt in the report code. The full reasoning, including what could not
be measured here, is in [doc/PERFORMANCE.md](PERFORMANCE.md) §2c.

Both profiles take the same 3 % developer fee on Monero time, both are
auditable with `sudo ./oneclick.sh verify`, and `--donate-level=0` removes it.

### Health

`sudo ./oneclick.sh status` ends with a `health:` line, because "the service is
active" is not the same question as "this machine is earning":

| State | Meaning | Response |
| --- | --- | --- |
| `ok` | hashrate near the session peak, shares accepted | none |
| `warming` | dataset building, or the user paused it | none |
| `degraded` | under 80 % of peak for ten minutes | look at cooling and neighbours |
| `stalled` | process alive, zero hashes | restarts itself after 15 min |
| `rejected` | shares sent, none accepted | restarts itself after 15 min; if it repeats, the wallet/algorithm is wrong |

A restart costs 16–30 s of hashrate and clears a state that would otherwise cost
hours, which is why it is on by default under systemd. Turn it off with
`--no-health-restart` on a machine that must stay up regardless.

### Purging

`uninstall` keeps the config (re-installing is common) and the build cache.
`purge` removes everything the tool created — units, binaries, config, state,
build directory, logs — after printing the list with sizes and asking you to type
`purge`. `--dry-run` shows the list and deletes nothing; `--yes` skips the
prompt. It also returns `vm.nr_hugepages` to the kernel. Nothing outside that
list is touched, which is what `tests/oneclick/purge.sh` checks on every run.

---

## The Zig engine

`--engine zmrig` builds and installs `zmrig`, the Zig miner from `zmrig/`
instead of the C++ frontend. It is the same RandomX engine, the same config
file, the same service and the same helpers — only the process in front of the
hash loop changes.

```bash
sudo ./oneclick.sh install --yes --wallet 4YourAddress... --engine zmrig --algo rx/0
sudo ./oneclick.sh status      # identical output, hashrate comes from the zmrig log
sudo ./oneclick.sh bench       # runs zmrig --bench=N (default 20000 hashes)
sudo ./oneclick.sh report      # zmrig --report: pauses the unit, prints ZMRIG1.<code>
sudo ./oneclick.sh verify      # --self-test + strings|grep -c donat
```

Differences worth knowing:

| | `xmrig` (default) | `zmrig` |
|---|---|---|
| algorithms | all backends/algorithms in this fork | RandomX family only (`rx/0`, `rx/2`, `rx/wow`, `rx/arq`, `rx/graft`, `rx/sfx`, `rx/yada`, `panthera`) |
| build deps | cmake, libuv, OpenSSL, hwloc | `g++`, `ar`, zig 0.13 (installed automatically) |
| binary | `/usr/local/bin/xmrig` (service: `zmrig.service`) | `/usr/local/bin/zmrig` |
| measured | 1075.7 H/s (`scripts/bench.sh`) | 1084–1089 H/s installed, 1.08–1.10 kH/s `--bench` |
| TLS | full (including `--tls-insecure`) | full verification, private CA via `--tls-ca` (Zig 0.13 has no "skip verify") |
| transports | TCP, TLS | TCP, TLS, WebSocket, WebSocket+TLS, HTTP CONNECT, SOCKS5 |
| self-test | — | `zmrig --self-test` (vectors + 2 GiB dataset) |

The chosen engine is recorded in `/etc/zmrig/engine`, so the subcommands
that run later (`status`, `logs`, `bench`, `verify`, `start`, …) pick the same
binary without repeating `--engine`. Passing `--engine` again overrides it.

Host tuning still applies: without huge pages the Zig miner falls back to
`mmap`'d pages and loses ~10%, exactly like the C++ one.

On a host that only allows 443/tcp, or behind a CDN, use
`--engine zmrig --cloudflare`; the complete guide (including a Cloudflare
Worker that turns any pool into a `wss` endpoint) is in
[doc/NETWORK.md](NETWORK.md).

---

## Calibration on first start

MoneroOcean pools choose the most profitable algorithm using the `algo-perf`
table the miner reports at login. On the very first start (and after
`--rebench-algo`) the miner measures every algorithm for ~10 s each, which takes
about two minutes before the first share. The installer detects this and keeps
waiting instead of reporting a failure.

If you pinned an algorithm with `--algo`, that table is never used, so this fork
**skips the calibration** and connects immediately.

The result is stored in `config.json` under `algo-perf`, so later starts are
instant. Re-calibrate only after a hardware change:

```bash
sudo systemctl stop zmrig
sudo /usr/local/bin/zmrig -c /etc/zmrig/config.json --rebench-algo
```

---

## Unattended fleet install

```bash
for host in rig01 rig02 rig03; do
  ssh "$host" "curl -fsSL https://raw.githubusercontent.com/MoLik-Labs/ZMRIG/BETA/oneclick.sh \
    | sudo bash -s -- --yes --wallet 4... --rig-id $host"
done
```

The rig id defaults to the hostname, and the config is never overwritten on a
second run, so re-running the same command is a cheap idempotent "ensure it is
installed and running".

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `libuv headers were not found` | no `libuv1-dev` and no network for the package manager | install it, or build libuv and pass `UV_INCLUDE_DIR`/`UV_LIBRARY` |
| `the miner rejected the generated config` | wallet contains an unescaped character | re-run with a clean wallet, or edit `/etc/zmrig/config.json` and `systemctl restart zmrig` |
| `no hashrate after …s` and the log shows `connect error` | pool unreachable / firewall | `sudo ./oneclick.sh config --force --pool another.pool:port ...` |
| `huge pages are not fully allocated` in the log | tuning did not run (non-root, container) | `sudo /usr/local/bin/zmrig-tune` then restart the service |
| `FAILED TO APPLY MSR MOD` | kernel module missing or a hypervisor that blocks MSR writes | run `modprobe msr`; inside VMs this is expected and harmless |
| service restarts in a loop | config or binary replaced while running | `sudo ./oneclick.sh logs` then `systemctl status zmrig` |
| systemd is not available (container) | — | the installer falls back to a background process with a pidfile in `/var/lib/zmrig/` |

`./oneclick.sh status` prints service state, live hashrate, accepted shares, huge
page count and the log tail, which covers most of the table above.

### Benchmarking while the service runs

`./oneclick.sh bench` stops the service, runs the benchmark with the full huge
page reservation, and restarts it. Doing that by hand
(`xmrig --bench=1M` next to a running miner) shares the reservation between two
processes, and XMRig reacts by grabbing *more* pages, which on a small machine
is both slower and risky. Use `oneclick.sh bench` or stop the unit first.

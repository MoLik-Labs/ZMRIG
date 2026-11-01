---
title: Troubleshooting
description: A symptom-to-cause table for the failures that actually happen, the bugs that were fixed so they cannot happen again, and what to include in a bug report.
image: https://nggkhaiz.github.io/ZMRIG/img/og-en.png
---

# Troubleshooting

## Symptom → cause

| Symptom | Usual cause | What to do |
| --- | --- | --- |
| `dataset ready` takes 20–30 s | normal: building 2 GiB | not a fault; `--mode light` takes 0.6 s but keeps 9 % of the hashrate. `panthera` builds 64 MB and is ready in about 0.4 s |
| 20–30 % below expected hashrate | the mapping is on 4 KiB pages | `zmrig --check` prints the `thp` policy; the log must show 2 MiB pages, either `huge pages … (explicit)` or `huge pages: … MB via THP (…, measured by the kernel)` |
| the process is killed, exit 137 | out of RAM while building the dataset (huge pages already hold the rest) | fix the huge-page reservation, or use `--mode light` |
| `cannot read …: check the path or run as root` | the config is root-only | run with `sudo` |
| `config ok` but nothing mines | no `-c`, or no pool given | `--check` only inspects the file it was given |
| `login failed: …` repeats | wrong wallet or pool, banned IP, wrong TLS mode | read the line after it; try `--transport tcp` to rule TLS out |
| `connection lost` repeatedly | a CDN or NAT dropping a silent socket | `--keepalive-interval 60`, `--idle-timeout 120` |
| `share rejected: …` | stale job or difficulty, or the machine clock drifting | check `timedatectl`; read the pool's own message |
| API returns 401 | an access token is configured | send `Authorization: Bearer TOKEN` |
| API unreachable from another machine | it binds `127.0.0.1` by design | do not expose it; use an SSH tunnel |
| `--tls-ca` has no effect | the file is in `/tmp` and the unit uses `PrivateTmp` | put it at `/etc/zmrig/tls-ca.pem` |

## Bugs that were fixed, so you do not have to meet them

- **Light mode crashed on Panthera/Scala.** The JIT snippet that reads the
  dataset masked the block number with Monero's 2 GiB mask, so a coin with a
  32 MB dataset addressed memory it did not own, up to 2 GiB past the end of its
  128 MB cache: `SIGSEGV` a fraction of a second after `--check` said the config
  was fine. The snippet is now patched with the mask of the algorithm at hand,
  the way the dataset-read path already was. Every algorithm has a reference
  vector in `--self-test` now, so this cannot come back quietly.
- **Every algorithm was sized as Monero.** The miner reserved 2416 MB of huge
  pages and refused to start without them, whatever the coin. Panthera needs
  192 MB; a 512 MB VPS can mine it in fast mode. The reservation, the
  `--mode=auto` decision, the memory gate in front of `--bench` and
  `zmrig-tune --algo` all read the compiled configuration of the algorithm now.
- **A bigger dataset was refused on a machine that had the memory.** The
  pre-flight in front of `--bench` and `--report` compared the requirement
  against the huge-page pool and against `MemAvailable` separately, so a host
  that had followed the miner's own advice (`echo 1168 > nr_hugepages`) had
  2336 MB in the pool and 1.2 GB of RAM, and the 2404 MB requirement matched
  neither number. The two are added now — the allocator falls back per mapping,
  so both are usable — and the message says which two figures it summed.
- **Switching algorithm leaked 2.3 GiB.** The cache was allocated with
  `posix_memalign` and freed with `munmap`, so the pages stayed mapped. A pool
  that rotates coins (MoneroOcean does) would run the machine out of memory
  after a handful of switches. Allocation and release now use the same path —
  `mmap`, so the memory is also never written twice before the dataset
  initialiser fills it.

- **`--background` was ignored** and the miner stayed in the foreground. It now
  forks, calls `setsid` and closes stdio.
- **Reconnects were slow and then a storm.** It waited the full `--retry-pause`
  after every drop and reset its counter on pool rotation, so a dead pool was
  hammered. Now: reconnect immediately after a session that had logged in, then
  200 ms → 500 ms → 1 s → `--retry-pause`, with a counter that does not reset.
- **Log files contained ANSI colour escapes.** Files are plain text; stdout keeps
  colour.
- **Command-line flags used to overwrite config values with defaults.**
  `zmrig -c config.json --verbose` reset `mode`, `huge-pages`, `retries`. Only
  flags you actually type override now.
- **`report.enabled` in the config started `--report`** (measure, print, exit)
  instead of only writing the report file. The two are separate now.
- **`--tls` used to imply "do not verify the certificate".** It only selects the
  transport; verification stays on.
- **One very long line from a pool killed the session.** The line is dropped and
  warned about once when the session ends.
- **`--http-port` never reached the config.** Fixed; the installer writes the
  `enabled` boolean correctly.
- **Ctrl-C hung while waiting for a login.** The monitor closes the socket so the
  main thread can exit.
- **A client that opened the API socket and went silent blocked the API thread.**
  Every connection now has a 5-second timeout.

## Questions that come up

**Is `--mode light` usable on a 1 GB VPS?**
It runs, at about 9 % of the hashrate (76 H/s against 814 H/s). Fine for keeping
a connection or testing a config; for real mining, pick a VPS with at least
2.5 GB.

**How many threads?**
`L3 cache / 2 MiB` is right most of the time. If the VPS is throttled, drop one
thread and measure again.

**Should a local pool use TLS?**
On the same machine or a private network, TLS costs CPU and adds no real
security. Use it over the internet or through a CDN.

**Can it mine to several pools at once?**
Yes: several `-o` flags, or several entries in `pools[]`. It tries them in order
and fails over after `--retries` failures.

**Does the API slow the miner down?**
No. It reads atomics that are updated once a second and never locks a worker.

**How long until the first share?**
Depends on pool difficulty: seconds on a test pool, minutes to hours on a real
one with a small machine. A slow share is not a fault — check the hashrate and
look for `pool has been silent`.

**How do I know the miner is mining to the right wallet?**
`zmrig --check` prints `user=…`, the API returns `connection.pool`, and the
startup log prints `wallet: …`. Compare with the dashboard of the pool.

## Reporting a bug

```bash
zmrig --version
sudo ./oneclick.sh status
sudo ./oneclick.sh logs 80
sed 's/"user": *"[^"]*"/"user": "REDACTED"/' /etc/zmrig/config.json
```

Redact the wallet and any token before pasting. The log alone usually shows
whether the failure is transport, TLS or the pool itself.

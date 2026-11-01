---
title: Testing
description: The suites in this repository, what each one proves, how long they take, and the failures that are usually the machine rather than the code.
image: https://nggkhaiz.github.io/ZMRIG/img/og-en.png
---

# Testing

Every suite here runs without a real pool, and no suite needs a wallet.

## Hash engine

```bash
./zmrig/out/zmrig --self-test          # full: needs 2 GiB of RAM
./zmrig/out/zmrig --self-test=light    # skips the dataset checks
./zmrig/tests/run.sh                   # self-test plus the API checks
```

`--self-test` checks the reference `rx/0` vectors, pipelined hashing, and that a
dataset built from the cache produces the same result as a full-memory build.
`oneclick.sh verify` calls it before it checks the fee.

## Watchdog, two real-pool cases

`zmrig/tests/health.sh` runs the miner against a fake pool twice, to prove both
directions:

| Case | Expected |
| --- | --- |
| A well-behaved pool | health stays `ok`, nothing is logged as an error, no restart |
| A pool rejecting every share | health becomes `rejected`, the process exits **code 3** so systemd restarts it, and the log says how to disable that |

Plus seven unit tests for the state machine (`health.zig`): a pause is not an
error, one or two stale shares are normal, and a dip has to last before it counts
as `degraded`.

## Network suite — 29 cases

It starts a fake pool, a TLS shim, HTTP and SOCKS5 proxies and a WebSocket
server on the local machine, then makes the miner talk to all of them:

```bash
./zmrig/tests/net.sh --quick      # 10 s per case
./zmrig/tests/net.sh              # 18 s per case
./zmrig/tests/net.sh --soak       # adds a 4-minute soak
./zmrig/tests/net.sh --only api,tcp
```

| Group | Case | What it proves |
| --- | --- | --- |
| Transport | `tcp`, `tls`, `ws`, `wss` | login, job, share submission |
| | `ws path` | the server receives `/miner` |
| | `wss via socks5` | WebSocket over TLS through SOCKS5 |
| CDN | `cloudflare` | `wss` on 443 with the right `Host` header |
| Proxy | `http proxy`, `socks5 proxy` | `CONNECT` and auth reach the right target |
| API | `http api`, `http api token`, `http api 404` | summaries, token enforcement, unknown paths |
| Failure | `login rejected`, `idle watchdog`, `pool failover` | the error is visible; reconnect and failover work |
| | `hostile pool` | garbage input does not stop shares from being submitted |
| Seed | `seed change` | four dataset rebuilds, mining continues |
| Soak | `soak` | 4 minutes of seed changes, algorithm changes and a dropped link |

A full run takes 12–15 minutes on 2 vCPU, because each case has to produce a
share and the suite runs in `--mode light` (50–70 H/s). A last run on that
machine:

```text
29 passed, 0 failed, 0 skipped
```

Per-case logs land in `/tmp/zmrig-net.XXXXXX/`, printed at the end. When a case
fails, read that case's log first (`cloudflare.log`, `shim-cf.log`, `pool.log`).

### Traps

- **Ports.** The suite uses 4800 for the pool and 4801–4813 for shims. A leftover
  process holding 4800 makes the `cloudflare` case fail with `accepted=0` while
  the miner log says `login ok`. The script kills strays and refuses to start if
  something else owns the port.
- **CPU load.** Do not run benchmarks in parallel — you get either an OOM kill or
  a corrupted measurement.
- **Huge pages.** `light` mode means no 2 GiB reservation is needed; 50–70 H/s is
  expected, not a regression.

## Fee check

```bash
sudo ./oneclick.sh verify
```

With the Zig engine it runs the self-test and then `scripts/verify-fee.sh`,
which reads the rate, the wallet and the `--donate-level=0` off switch out of
the binary and fails if a second address or an upstream donation endpoint
appears. With the C++ engine it runs `scripts/verify-fee-free.sh`, which
additionally checks that the binary prints `DONATE 0%` when handed
`--donate-level=9`.

The check greps for **endpoints and addresses**, not for the word `donate`: the
monitoring API legitimately returns `"donate_level": 0`, and a naive grep raises
a false alarm. That has happened here, and it was fixed.

## API, CLI and configuration suites

```bash
./zmrig/tests/cli.sh      # flag parsing, help text, exit codes
./zmrig/tests/unit.sh     # unit tests across the Zig modules
node --test pool/tests/*.test.js
bash tests/oneclick/plan.sh && bash tests/oneclick/config.sh && bash tests/oneclick/governor.sh
```

`plan.sh` is the one that matters most after a change to the installer: it
asserts the exact command a user would copy for a dozen flag combinations.

## The site

```bash
cd site && npm test      # unit tests for the calculators and the command builder
cd site && npm run build # fails on a broken internal link or a bad component
```

The link check is the point of `npm run build`: `onBrokenLinks` and
`onBrokenMarkdownLinks` are both set to `throw`, so a renamed page cannot ship as
a 404.

## Running tests on a mining machine

The network suite uses its own ports and a fake pool, so it does not touch the
real miner. But if the real miner holds the huge pages, the full `--self-test`
may not have enough RAM for its dataset — use `--self-test=light`, or
`sudo ./oneclick.sh stop` first.

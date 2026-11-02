---
title: Command reference
description: Every zmrig flag, grouped by what it touches, plus config validation, self-test and autotune.
image: https://molik-labs.github.io/ZMRIG/img/og-en.png
---

# Command reference

`zmrig --help` prints the same list, grouped the same way. Flags with a default
show it in brackets.

## Pool

```text
-o, --url=URL              tcp|tls|ws|wss, e.g. wss://pool.example.com/monero
-u, --user=USER            wallet address or pool login
-p, --pass=PASS            password [x]
-a, --algo=ALGO            rx/0, rx/2, rx/wow, rx/arq, rx/graft, rx/sfx,
                           rx/yada, panthera — or auto, which advertises the
                           whole RandomX family
    --rig-id=ID            worker name sent to the pool
    --keepalive, --no-keepalive
    --transport=NAME       tcp | tls | ws | wss
    --cloudflare[=HOST]    wss://HOST:443/ preset for 443-only networks
    --ws-path=PATH         WebSocket path
    --ws-origin=URL        Origin header for the upgrade
    --tls                  TLS for the current pool
    --tls-ca=FILE          trust the CA in FILE
    --tls-insecure         accepted for compatibility; verification is on
    --connect-to=H:P       dial another address, keep SNI and Host
    --proxy=URL            http://user:pass@host:port or socks5://host:port
    --retries=N            attempts per pool [5]
    --retry-pause=N        seconds between attempts [5]
    --ban-cooldown=N       seconds to skip a pool after a ban, a rejected
                           wallet or a full-pool message [900]
                           a rejected wallet is floored at 30 minutes
    --idle-timeout=N       drop a silent connection after N s [300, 0 = off]
    --keepalive-interval=N [60, 0 = off]
```

## Mining

```text
-t, --threads=N            thread count [L3 cache / 2 MiB]
    --mode=auto|fast|light
    --no-huge-pages
    --no-huge-pages-jit
    --no-jit
    --no-affinity
    --priority=N           1..5 (XMRig scale) or a raw nice value, e.g. -10
    --scratchpad-prefetch=N 0 nop, 1 prefetcht0 [default], 2 prefetchnta, 3 load
    --no-optimized-init    portable dataset initialiser
    --autotune[=SECONDS]   measure candidate thread counts, no pool needed
```

## Logging and lifecycle

```text
    --no-color
    --verbose
    --print-time=N         seconds between hashrate lines [60, 0 = off]
    --log-file=FILE        also write the log here
    --background           fork into the background
-c, --config=FILE
    --check                validate the configuration and exit
    --self-test[=light]    hash engine checks
    --bench[=HASHES]       benchmark; stops at HASHES or 180 s
    --report               measure for --report-time and print a ZMRIG1. code
    --report-time=N        [15]
    --report-file=FILE     keep updating FILE while mining
    --report-interval=N    [60]
    --report-id=NAME       machine name in the report
    --power=W              wall power, included in the report code
    --http-port=N          monitoring API port
    --http-host=ADDR       bind address [127.0.0.1]
    --http-access-token=TOKEN
-h, --help
-V, --version
```

## Profile: `free` and `watt`

```bash
sudo ./oneclick.sh install --wallet 4YourMoneroAddress --profile free  # maximum hashrate
sudo ./oneclick.sh install --wallet 4YourMoneroAddress --profile watt  # maximum H/W
sudo ./oneclick.sh install --wallet 4YourMoneroAddress                 # = auto
```

`auto` reads the battery: a laptop on battery becomes `watt`, everything else
becomes `free`. The miner re-reads the profile at startup, so unplugging and
restarting the service is enough to switch.

## Threads, measured rather than guessed

The default is `L3 cache / 2 MiB`, capped at the logical CPU count. On a 2 vCPU
VPS with 54 MB of L3 that is two threads, which is also the best measured value:
814 H/s with two, 408 H/s with one.

```bash
zmrig --autotune=8        # no pool required, 8 s per candidate
```

```text
   threads     hashrate  verdict
         1   499.625 H/s  best so far
         2   999.750 H/s  best so far
best: 2 thread(s) at 999.750 H/s
autotune-best-threads=2
```

A difference under 2 % counts as noise, so it does not change the thread count
because of one lucky run.

## Validate before you run

```bash
sudo zmrig -c /etc/zmrig/config.json --check
```

```text
config ok
  pool    wss://my-relay.example.com:443/pool user=4Ad algo=auto (all RandomX variants)
  route   connect 10.0.0.7:443, Host: my-relay.example.com
  proxy   socks5 127.0.0.1:1080
  threads 2 (default would be 2)
  cpus    [0,1] on 2 cpu(s), 2 physical core(s)
  mode    auto, huge pages on, jit on
  memory  rx/0 maps 2336 MB, 1168 pages of 2 MiB: no pages reserved; transparent huge pages collapse the mapping instead
  thp     madvise (default): the hint this miner sets is honoured, so no root step is needed
  msr     intel preset; reading /dev/cpu/0/msr needs root (off: --msr is worth 5-15% on Zen 3/4 …)
```

The `memory` line is the coin's own size — `panthera maps 192 MB, 96 pages` —
and the `thp` line answers the question it raises: `madvise` and `always` mean
the kernel backs the mapping with 2 MiB pages without any root step, `never`
means it does not and the miner will be ~28 % slower until pages are reserved.

`--check` reads the file and prints; it opens no socket and allocates no
dataset. If the file is root-only, run it with `sudo` or you get
`cannot read …: check the path or run as root`.

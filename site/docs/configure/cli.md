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
    --check-wallet=ADDR    decode a Monero address - length, base58 alphabet,
                           network byte, Keccak-256 checksum - print the kind,
                           the network and the keys, and exit 1 if a mainnet
                           pool could not pay it
    --allow-bad-wallet     start anyway when the address fails its checksum.
                           Under rx/0 a bad checksum is otherwise a refusal:
                           the rig would mine and never be paid
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
    --max-temp=C           keep the hottest CPU sensor at or below C degrees
    --thermal-file=PATH    read the temperature from PATH instead of sysfs
    --no-thermal           turn the governor off
```

## The wallet address

`-u/--user` takes the address the pool pays. For Monero it is decoded before the
first share: 95 characters (106 with a payment id), base58, a network byte, and a
four-byte Keccak-256 checksum. One wrong character is the failure that a
character count cannot see — the rig hashes perfectly and the payout goes to an
address whose spend key nobody holds — so under `rx/0` it is a refusal:

```console
$ zmrig -o gulf.moneroocean.stream:10001 -u 4AdUndXH...684Rgf
error 4AdUndXH...684Rgf is not a valid Monero address: checksum does not match: at least one character is wrong
error this rig would mine and never be paid; check it with `zmrig --check-wallet 4AdUndXH...684Rgf`
error if that login is not a Monero address, pass --allow-bad-wallet
```

`--check-wallet ADDR` is the same check without a pool, and `--check` prints the
verdict next to the rest of the configuration:

```console
$ zmrig -o gulf.moneroocean.stream:10001 -u 4... --check
  wallet  standard mainnet checksum verified
```

Every other algorithm keeps the check advisory: this repository only claims to
know Monero's format, and a login that is address-shaped but is another
CryptoNote coin's address must not stop a rig from starting. `--allow-bad-wallet`
turns the refusal into the old warning when that is what you have.

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

## Safe mode: mine without cooking the machine

`--max-temp` is the one number this mode is built around. It arms a governor
that runs once a second, reads the hottest CPU sensor and gives back threads as
the box warms:

```bash
sudo zmrig -o gulf.moneroocean.stream:10001 -u 4YourMoneroAddress \
    --max-temp=72 --profile watt
```

| what happens | when |
| --- | --- |
| nothing | below 72 °C |
| one thread is parked | at 72 °C, at most once every 30 s |
| a thread is parked immediately | at 80 °C (target + 8), at most once every 5 s |
| hashing stops | at 87 °C (target + 15) even on one thread |
| hashing resumes at one thread | once the sensor is back under 65 °C |
| a thread comes back | after two minutes below 67 °C (target − 5) |

The two speeds matter. At the target a spike is normal — a boost bin, one burst
of shares — so it waits. At the hard cap the hardware is already protecting
itself, so it acts at once. Stepping back up is deliberately slow: cooling for
two minutes and heating up in ten seconds is how a fan bearing dies, and it also
makes the measured average worse than holding one thread less.

Nothing is rebuilt while this happens. A parked thread keeps its VM and the
dataset stays in RAM, so a pause costs the shares it did not compute and nothing
else — the pool connection stays open.

```text
thermal: holding 72 C max - k10temp/Tctl reads 61.5 C now; 8 thread(s), step down at 72 C, pause above 87 C
thermal: 73.4 C on k10temp/Tctl -> 7 of 8 threads (target 72 C; 1 step-down(s), 0 step-up(s) so far)
thermal: 81.2 C on k10temp/Tctl -> 6 of 8 threads (target 72 C; 2 step-down(s), 0 step-up(s) so far)
```

`zmrig --check` prints whether a governor is armed and what it can see, which is
the difference between "it throttled" and "it has no sensor and never could":

```text
  thermal hold 72 C: k10temp/Tctl 61.5 C now, step down at 72 C, pause above 87 C (--no-thermal turns it off)
  thermal off (no --max-temp: nothing throttles, however hot the box gets)
```

The sensors are the CPU ones only — `coretemp`, `k10temp`, `zenpower`,
`cpu_thermal`, `acpitz` and the Super I/O chips — so a warm NVMe or a warm GPU
never costs a thread. A machine with no sensor at all says so once and keeps
mining at the thread count it was given: an unreadable thermometer is not a
reason to stop earning. `--thermal-file=PATH` points the governor at a file
instead, for a board whose sensor is exposed by the BMC.

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
  memory  rx/0 maps 2336 MB, 1168 pages of 2 MiB (or 3 of 1 GiB): no pages reserved; transparent huge pages collapse the mapping instead
  1g      no pool: this mode would need 3 page(s) of 1 GiB, and the mapping uses 2 MiB pages instead (doc/PERFORMANCE.md has the one-line reservation)
  thp     madvise (default): the hint this miner sets is honoured, so no root step is needed
  msr     intel preset; reading /dev/cpu/0/msr needs root (auto: the preset is skipped here; --msr tries anyway)
```

The `msr` line is the answer, not a nag: the prefetcher-off preset is worth
**5–15 %** on bare metal, and since 6.48 it is applied **by itself** when the
machine can take it (`auto`). What the parentheses say is which of three states
this run is in — `auto: …` (decided by the probe), `on: --msr` (asked for),
`off: --no-msr` (refused, which a config with `"msr": false` also does).

The `1g` line is the pool that cannot be made at runtime: it says whether the
1 GiB pages the mapper would rather use exist, and `zmrig-os hugepages 1g 3`
reserves them at the next boot. Empty is the normal answer on a virtual machine
and costs nothing — 2 MiB pages are where almost all of the gain is.

The `memory` line is the coin's own size — `panthera maps 192 MB, 96 pages` —
and the `thp` line answers the question it raises: `madvise` and `always` mean
the kernel backs the mapping with 2 MiB pages without any root step, `never`
means it does not and the miner will be ~20 % slower until pages are reserved.

`--check` reads the file and prints; it opens no socket and allocates no
dataset. If the file is root-only, run it with `sudo` or you get
`cannot read …: check the path or run as root`.

---
title: Benchmarks and tuning
description: How measurements are taken, the numbers from a 2 vCPU VM, which settings actually move hashrate, and the ten-minute procedure to tune a machine.
image: https://nggkhaiz.github.io/ZMRIG/img/og-en.png
---

# Benchmarks and tuning

## How to measure

```bash
# a full run: 20 000 hashes, including the dataset build
./zmrig/out/zmrig --bench=20000

# a quick check after a configuration change
./zmrig/out/zmrig --bench=15000

# the numbers for a dashboard (10 s warm-up + 15 s window)
./zmrig/out/zmrig --report --power 45
```

`--bench` uses the fixed seed `00112233…`, a 76-byte blob and the lowest target,
so every run hashes identical data and results are comparable. The dataset build
(15–25 s) is outside the measured window.

Rules that make a number mean something:

- **Stop the miner before benchmarking.** A running miner holds the huge pages;
  the bench then builds its dataset in ordinary memory and reports a figure that
  is too low. `oneclick.sh bench` stops and restarts the service to avoid this.
- **Measure on the machine in question.** Absolute hashrate depends on the host;
  do not compare to the table below.
- **Run each configuration twice.** Under 2 % is noise.

## A 2 vCPU VM (Xeon 2.6 GHz, 1234 huge pages of 2 MiB)

| Configuration | Hashrate | vs default | Comment |
| --- | ---: | ---: | --- |
| Default: 2 threads, 1168 pages reserved, prefetch 1 | 800–841 H/s | 100 % | baseline, five runs |
| No pages reserved, THP on (stock Ubuntu) | 786 H/s | 95 % | what an unprivileged user gets |
| No pages reserved, THP off | 615–626 H/s | 76 % | the only case worth a root step |
| `--mode light` | 82 H/s | 10 % | only when RAM is short |
| `-t 1` | 408 H/s | 50 % | scales linearly |
| `-t 4` on two cores | 798–801 H/s | 98 % | oversubscribing buys nothing |
| `--scratchpad-prefetch=0/2/3` | 1208–1302 kH/s (`panthera`) | — | inside the noise |
| `--no-affinity` | 814 H/s | 100 % | 2 vCPU, no difference |

The same machine and binary in a quieter session: **1008–1103 H/s**. That spread
is the reason comparisons have to be relative.

C++ engine on the same machine, same session: **1075.7 H/s** — the gap to the Zig
engine is within run-to-run variance, not a performance claim.

## The three settings that matter

### 1. Huge pages

The largest and least ambiguous effect. RandomX reads a 2 GiB dataset in a random
pattern, and 4 KiB pages mean constant TLB misses.

```bash
# reserve 1168 pages of 2 MiB (≈2.3 GiB) — the size of rx/0, not of every coin
echo 1168 | sudo tee /proc/sys/vm/nr_hugepages
grep HugePages_ /proc/meminfo
```

The installer does this and writes it into the systemd unit
(`LimitMEMLOCK=infinity`). The count follows the coin: `panthera` needs 96 pages
(192 MB), not 1168. `sudo zmrig-tune --algo panthera` writes the right one, and
`zmrig` sizes its own reservation the same way. To check the miner got them:
startup logs `huge pages … MB (explicit)`, and the API reports
`"hugepages": [granted, needed]` — `[1168, 1168]` for `rx/0`, `[96, 96]` for
`panthera`.

### The three page-size states, measured

`--no-huge-pages` is not the same experiment as "the pages were never reserved".
This miner passes `MADV_HUGEPAGE` on every mapping it makes, so on a kernel with
`transparent_hugepage=madvise` (Ubuntu's default) an unprivileged run still gets
2 MiB pages, just not from the pool. The three states, `rx/0`, two runs each, same
session:

| Pages | Backing | Hashrate |
| --- | --- | ---: |
| 1168 reserved | `MAP_HUGETLB` | 814.5 / 832.2 H/s |
| none reserved | THP collapsed 99 % of the mapping | 785.9 / 786.1 H/s |
| none reserved, THP off | 4 KiB | 614.8 / 626.3 H/s |

So the step that matters is 4 KiB → 2 MiB (≈ +28 %), and the reserved pool is
worth another 4–6 % on top. That is why the miner only asks for root when THP is
off, and why startup prints the kernel's own count of collapsed pages
(`huge pages: 2332 MB via THP (99 % of the 2336 MB mapping, measured by the
kernel)`) instead of claiming the hint worked.

A practical warning: with the full reservation in place, ordinary RAM is down to about
1.2 GB. Running `--no-huge-pages` at that point gets OOM-killed (exit 137),
because the 2 GiB dataset has nowhere to live. Lower `nr_hugepages` to 0 first.

### Building the dataset

The 2 GiB dataset is a memory-bandwidth job, and it is the longest wait a rig
has. Measured on this host, seed `00112233…`:

| Initialiser threads | `dataset ready in` |
| --- | ---: |
| 1 | 42.9 s |
| 2 | 21.1 s |

`--randomx-init=1` is therefore a way to make a seed change take twice as long;
it is not a way to leave a core free for something else, because every core is
waiting for the dataset anyway. The default is every hardware thread, even when
mining is told to use fewer (`-t 1` still builds with all of them).

### 2. Fast or light mode

`fast` builds one 2 GiB dataset shared by all threads → 849 H/s on this 2 vCPU
machine. `light` keeps only the 256 MiB cache and recomputes the dataset per hash
→ 82 H/s.

Nearly 10×. `light` is defensible when the VPS does not have the RAM, or to test a
configuration quickly (0.6 s startup instead of 20 s).

### 3. Thread count

Linear on this machine: 2 threads = 808–817 H/s, 1 thread = 408 H/s, 4 threads on
two cores = 798–801 H/s. There is no hidden sweet spot and nothing above the core
count. On a throttled shared vCPU, extra threads can lower per-thread
hashrate while still raising the total; measuring is the only way to know.

## Settings that made no measurable difference

- `--scratchpad-prefetch` 0/1/2/3: under 1.5 %, i.e. noise. Leave the default.
- `--no-affinity` on 2 vCPU: nothing.
- `--no-optimized-init`: affects dataset build time, not hashrate.

Ignore advice to raise `priority` for hashrate: priority changes how the OS shares
CPU, it does not make arithmetic faster. It helps when the machine does other
work.

## The ten-minute tuning procedure

```bash
# 1. background state
sudo ./oneclick.sh stop
grep -E "HugePages_Total|HugePages_Free" /proc/meminfo

# 2. measure the default
./zmrig/out/zmrig --bench=15000

# 3. variants, each twice
./zmrig/out/zmrig --bench=15000 -t 1
./zmrig/out/zmrig --bench=15000 --no-huge-pages   # only after lowering nr_hugepages
./zmrig/out/zmrig --bench=15000 --mode light

# 4. keep the winner in the config, then start
sudo ./oneclick.sh start
```

Write the numbers down with the date and host name. Six months later you will
want them.

## Heat and power

Hashrate is not the whole story. A machine doing 814 H/s at 95 W beats one doing
900 H/s at 130 W. Measure at the wall, or read package power from RAPL:

```bash
cat /sys/class/powercap/intel-rapl:0/energy_uj   # twice, one second apart
```

`zmrig --report` reads it for you and records the source in the report code
(`pwsrc`: `rapl`, `hwmon`, `user` or `none`), along with `hw` — hashes per watt
(the 60-second hashrate divided by power). That is the number `--profile watt`
optimises, so the code carries it instead of leaving everyone to divide.

| | hashrate | power | H/W |
| --- | --- | --- | --- |
| `--profile free` | the most the machine can do | highest | lower |
| `--profile watt` | a few percent lower (SMT threads dropped) | 30–40 % lower on the SMT part | higher |

Those rows describe a direction, not your machine: **power cannot be measured
inside this repository's container** (RAPL is blocked), so the watt figures are
inferred from P ∝ V²·f and published SMT data. The hashrate side is measured. On a
machine with RAPL, run `zmrig --report` under both profiles and compare `hw` — then
the conclusion is yours, at your electricity price.

The [profitability calculator](/docs/economics/profitability) turns those watts
into money.

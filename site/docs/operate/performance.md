---
title: Performance
description: What actually changes hashrate on a CPU, what does not, and how to measure it without fooling yourself.
image: https://molik-labs.github.io/ZMRIG/img/og-en.png
---

# Performance

RandomX is a memory-bound proof of work: the hash loop reads a dataset in a
random order. Almost everything that matters follows from that one sentence.

## The four levers that matter

**Huge pages.** The largest and most obvious gain. A 4 KiB page size makes the
dataset walk a TLB miss every few accesses. There are two ways to get 2 MiB
pages and the miner reports which one it got: `huge pages … MB (explicit)` means
the reserved pool, and `huge pages: … MB via THP (…, measured by the kernel)`
means transparent huge pages collapsed the mapping — read from
`/proc/self/smaps_rollup`, not assumed. The second is what an unprivileged user
gets on a stock Ubuntu kernel, and it is worth most of the gain: 786 H/s against
615 H/s for 4 KiB pages on the test host, where the reserved pool gives 800–841.

```bash
echo 1168 | sudo tee /proc/sys/vm/nr_hugepages    # ~2.3 GiB of 2 MiB pages, for Monero
grep HugePages_ /proc/meminfo
```

The installer does this and sets `LimitMEMLOCK=infinity` in the unit. The number
is not a constant: it is the cache plus the dataset of the coin being mined —
1168 pages for Monero, 96 for Panthera/Scala (see the table below). `zmrig`
sizes its own reservation per algorithm and `zmrig-tune --algo=` writes the same
number, so `sudo zmrig-tune --algo panthera` reserves 192 MB and not 2.3 GB.

To check the miner got them: the startup log prints how many bytes really came
from explicit huge pages (`huge pages 2336 MB (explicit, 2 MiB pages)`), and the
API reports `"hugepages": [granted, needed]` — `[1168, 1168]` for `rx/0`,
`[96, 96]` for `panthera`.

**If a 1 GiB pool exists, it is used first.** A 2080 MB dataset is 1 040 TLB
entries at 2 MiB and two at 1 GiB, so the mapper asks for gigantic pages, then
the 2 MiB pool, then anonymous memory with the THP hint — and the log says which
one answered (`explicit, 1 GiB pages` against `explicit, 2 MiB pages`). It cannot
be a runtime setting: the pool is contiguous physical memory and has to be
carved out early in boot, so it is a kernel parameter.

```bash
sudo zmrig-os hugepages            # what is reserved, and what this run needs
sudo zmrig-os hugepages 1g 3       # a Monero dataset is 3 pages; next boot
sudo zmrig-os hugepages off        # stop reserving it
```

Reserving a gigantic pool **replaces** the 2 MiB reservation rather than adding
to it — three 1 GiB pages have already taken 3 GB of contiguous memory, and the
miner maps whichever pool exists. The boot log and `zmrig-os tune` both say which
one is in force.

On most virtual machines the pool cannot be made at all — writing
`nr_hugepages` under `hugepages-1048576kB` reports success and leaves it at 0 —
and that is not a fault: the fallback to 2 MiB pages is automatic and the gain
that matters (4 KiB to 2 MiB) is already there — measured on the test host on
2026-11-05, `--bench=2000`, **678.1 H/s on 4 KiB pages against 913.2 H/s with a
reserved 2 MiB pool (+34.7 %)**. The extra 1-3 % has not been measured in that
environment: the write to `nr_hugepages` reports success and the pool stays at 0.

:::warning Measuring without huge pages
Once 1234 pages are reserved, only about 1.2 GB of ordinary RAM is left. Running
`--no-huge-pages` then gets the process OOM-killed (exit 137), because a second
2 GiB dataset does not fit. Set `nr_hugepages` to 0 before measuring that case,
and remember to put it back.
:::

**Fast or light mode.** `fast` builds one dataset shared by every thread. `light`
keeps the cache and rebuilds every dataset line per hash: 82 H/s against 849 H/s
on the same machine, same minute, `rx/0` — a factor of ten, not a power-saving
option. A rig that falls back to light mode is not mining, it is idling at 10 %.
The startup log says which one it chose and why, and `--check` prints the
decision before you start.

Which one you get in `--mode=auto` depends on the **coin**, because the coins are
not the same size. This is measured, not estimated from a constant:

| Algorithm | Coin | Cache | Dataset | Total | Fits in 1 GiB VPS? |
| --- | --- | ---: | ---: | ---: | --- |
| `rx/0` | Monero | 256 MB | 2080 MB | 2336 MB | light only |
| `rx/wow` | Wownero | 256 MB | 2080 MB | 2336 MB | light only |
| `rx/arq` | ArQmA | 256 MB | 2080 MB | 2336 MB | light only |
| `rx/graft` | Graft | 256 MB | 2080 MB | 2336 MB | light only |
| `rx/sfx` | Safex Cash | 256 MB | 2080 MB | 2336 MB | light only |
| `rx/yada` | YadaCoin | 256 MB | 2080 MB | 2336 MB | light only |
| `panthera` | Scala (XLA) | 128 MB | 64 MB | **192 MB** | yes |

The dataset size is the same for the six RandomX forks because they only change
the program configuration, the argon salt and the iteration count; Panthera is a
different configuration (`ArgonMemory` 128 MB, `DatasetBaseSize` 32 MB).

`zmrig --check` prints the number for the algorithm you asked about, and the
datasets are sized from the compiled configuration rather than from
`RANDOMX_DATASET_MAX_SIZE` — that constant is 2 GiB and using it for a 64 MB
dataset is how a 512 MB VPS ends up refusing to start on a coin it can mine.

**Threads.** One per physical core, two per core only when SMT helps: on the test
host, two threads on two vCPUs gave 808–817 H/s, one thread 408 H/s, and four
threads on two cores 798–801 H/s — oversubscribing buys nothing. SMT usually adds
5–15 % hashrate for 30–40 % more power, which is why the `watt` profile drops it.

**The MSR preset.** Disabling the CPU's hardware prefetchers costs one register
write and is the one lever that is not free: it needs root and the `msr` module.
RandomX walks its dataset at random, so the prefetchers guess wrong and burn
memory bandwidth on lines nobody asked for. The published gain is **5–15 %** on
Zen and a smaller number on Intel; it was not measured on this host, and the
4-core VM this documentation was built on has no MSR passthrough at all.

Since 6.48 it is **on by default** (`auto`): the miner probes, applies the preset
when the machine can take it, and prints one line either way — in the log and in
`--check`. `--no-msr` is the way to keep `/dev/cpu/*` untouched, `safe` mode does
it regardless, and an appliance has root already, so on an installed rig the
preset is simply applied. Original values are saved and restored on exit.

## The two that do not

- **Scratchpad prefetch mode** (0/1/2/3): 823, 814, 823, 814 H/s — inside noise.
  The default (1) stays.
- **Affinity** on a 2 vCPU machine: identical. It matters on a many-core box with
  an uneven L3, which is a different measurement.

Anything advertised as a large speed-up that is not huge pages, dataset mode or
thread count should be measured before it is believed.

## Measured

2 vCPU Xeon at 2.60 GHz, 3.9 GiB RAM, 1234 × 2 MiB huge pages, algorithm `rx/0`,
one run per configuration.

| Configuration | Hashrate | Ratio |
| --- | ---: | ---: |
| default: 2 threads, 1168 pages reserved, prefetch 1 | 800–841 H/s | 100 % |
| same, no pages reserved (THP backs the mapping) | 786 H/s | 95 % |
| same, no pages reserved and THP off (4 KiB) | 615–626 H/s | 76 % |
| `--mode light` | 82 H/s | 10 % |
| `-t 1` | 408 H/s | 50 % |
| `-t 4` on two cores | 798–801 H/s | 98 % (noise) |
| `--scratchpad-prefetch=0/2/3` | 1208–1302 kH/s on `panthera` | noise |
| `--no-affinity` | 814 H/s | 100 % (noise) |

Re-checked for 6.33.0 on 2026-11-01 (three `--bench=3000` runs, THP, two
threads): **889 / 956 / 886 H/s** — the same configuration as the 786 H/s row,
different day. Treat the ratios, not the absolute numbers.

The same binary on the same host in a quieter session measured **1008–1103 H/s**.
That 20–25 % spread is why absolute numbers in documentation are close to
useless, and why the ratios above are the useful part.

C++ engine on the same host, for reference: **1075.7 H/s**. The gap to the Zig
engine is smaller than the gap between two runs.

## Measuring it yourself

```bash
zmrig --bench=20000      # fixed seed, fixed blob, dataset build excluded
zmrig --report --power 45   # 10 s warm-up + 15 s window, prints a code
sudo ./oneclick.sh bench    # stops the service first, then measures
```

Rules that make a measurement mean something:

1. **Stop the miner first.** A running miner holds the huge pages; the benchmark
   then allocates in ordinary memory and reports about 20 % low.
2. **Measure the machine you care about.** Absolute hashrate is a property of the
   host, not of the binary.
3. **Run each configuration twice.** Under 2 % is noise.

The full table, with the dates and the caveats, is in
[Benchmarks](/docs/reference/benchmarks).

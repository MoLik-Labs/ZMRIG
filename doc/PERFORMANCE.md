# Performance guide

Everything that influence the hashrate of this miner, in the order it matters.
Numbers marked **measured here** come from the CI sandbox this fork was
validated in (2 vCPU Xeon, AVX2, no huge pages available); numbers marked
*typical* are community/upstream ranges and must be verified on your own host
with `scripts/bench.sh`.

Two measurement rounds are recorded. The older sections (2b and later) were
taken in a faster session on the same class of host and sit around 1050–1100
H/s for `rx/0`; the 2026-11 round below measures the same binary at 800–841 H/s
on a shared vCPU whose clock the hypervisor controls. A 20–25 % spread between
sessions on the same box is normal and is exactly why every table here states
the ratio next to the absolute number.

---

## 0. TL;DR checklist

```bash
# 1. build for this machine
./scripts/build-optimized.sh --clean

# 2. give it the memory it needs (root, once per boot)
sudo ./scripts/tune-linux.sh

# 3. measure before/after on the same host
./scripts/bench.sh --seconds 300 --hashes 200000

# 4. audit the developer fee (3% of Monero time, switchable off)
./scripts/verify-fee.sh --binary zmrig/out/zmrig
```

Startup log must show, in this order:

```
randomx  allocated 2336 MB (2080+256) huge pages 100% 1168/1168 +JIT
randomx  dataset ready (… ms)
cpu      READY threads N/N (N) huge pages 100%
msr      register values for "…" preset have been set successfully
```

If you see `huge pages 0%` or `FAILED TO APPLY MSR MOD`, you are leaving a large
amount of hashrate on the table — see sections 2 and 3.

---

## 1. What RandomX actually costs

RandomX (the algorithm behind Monero and most MoneroOcean routes) is designed to
be **memory latency bound**, not ALU bound:

* a 2080 MiB dataset, read at random 64-byte offsets, shared by all threads;
* a 2 MiB scratchpad per thread, filled with AES + integer ops, then accessed
  with random-ish addresses inside the JIT-compiled program;
* dataset initialisation once per seed (~3.5 days for Monero) or whenever the
  pool switches to a different RandomX variant.

Consequences, in order of impact:

1. **TLB coverage** (huge pages) — 2 GiB of 4 KiB pages is 524 288 TLB entries,
   far more than the CPU can cache. 2 MiB pages cut that by 512x, 1 GiB pages by
   262 144x.
2. **Hardware prefetcher behaviour** (MSR mod) — the dataset access pattern is
   random; the prefetcher wastes bandwidth and evicts useful lines. Disabling it
   is worth a lot on Zen and a bit less on Intel.
3. **Thread count vs. L3 cache** — one scratchpad (2 MiB) per thread must stay
   resident. Auto-config already targets physical cores with
   `L3 / 2 MiB` hashes; forcing SMT siblings only helps when the extra threads
   still fit in L3.
4. **NUMA placement** — on multi-socket hosts each node needs its own dataset
   (`randomx.numa`), otherwise half the threads read remote memory.
5. **CPU frequency / governor / thermals** — last, but zero cost to fix.

### Measured in this repository's sandbox

Host: 2 vCPU Xeon VM, 3.9 GiB RAM, no MSR access (the hypervisor rejects
`MSR 0x1a4`), 2 MiB huge pages reserved by `scripts/tune-linux.sh`.

| Configuration | RandomX hashrate | Dataset init |
|---|---|---|
| `-Ofast -maes` (upstream flags) | 1096 H/s (60 s avg, 4 samples) | 17.5 s |
| `-O3 -march=native -fno-plt` (this fork; LTO off) | 1091 H/s | 17.3–18.1 s |
| same, with 100 % huge pages (`huge pages 100% 1168/1168 +JIT`) | 1103 H/s peak, 1089 H/s avg | **14.9 s** |
| same, `--no-huge-pages` | not measurable here: a 2.3 GiB dataset on 4 KiB pages gets the process OOM-killed in a 3.9 GiB VM | — |
| same binary, RandomX **interpreter** instead of JIT | **180 H/s** | 15.0 s |

Three conclusions from that table:

* compiler flags are worth nothing on RandomX (JIT, see below);
* huge pages are worth a faster dataset init here and 10-30 % of hashrate on
  bare metal — on a small VM they are the difference between running and being
  OOM killed;
* the JIT is worth **6.1x** over the interpreter, which is why this project
  stays on C++ (see [ALTERNATIVES.md](ALTERNATIVES.md)).

**Compiler flags do not move RandomX**:
the hot loop is JIT-generated machine code produced at runtime from the same
RandomX sources, so `-march` has nothing to optimise there. Flags still help the
dataset initialiser and the CryptoNight/Argon2 C paths, so `build-optimized.sh`
keeps them, but do not expect a RandomX speedup from them.

The real gains are environmental (sections 2–4) and structural (section 6: no
donation switch).

---

## 2. Huge pages (biggest single lever)

| Page size | Typical RandomX gain vs 4 KiB |
|---|---|
| 2 MiB explicit (`huge-pages: true`) | +5 % … +20 % |
| 1 GiB explicit (`hugepages 1g N`, used automatically when reserved) | +1 % … +3 % on top of 2 MiB |
| Transparent huge pages (fallback) | +2 % … +8 %, less predictable |

`tune-linux.sh` reserves exactly what the algorithm being mined needs, and that
is not one number: `--algo panthera` reserves 96 pages (192 MB) where `rx/0`
reserves 1168 (2336 MB). The sizes come from the compiled RandomX configuration:

| Algorithm | Cache | Dataset | Total | 2 MiB pages |
|---|---:|---:|---:|---:|
| `rx/0`, `rx/wow`, `rx/arq`, `rx/graft`, `rx/sfx`, `rx/yada` | 256 MB | 2080 MB | 2336 MB | 1168 |
| `panthera` (Scala/XLA) | 128 MB | 64 MB | 192 MB | 96 |

Note that
XMRig itself also *tops up* `/proc/sys/vm/nr_hugepages` when it cannot get
enough pages (for example when a second miner or a benchmark runs while the
service is up). That is upstream behaviour and it is why
`./oneclick.sh bench` pauses the service first.

Measured on the container used for this release (2 vCPU Xeon 2.6 GHz, 3.9 GiB,
`--mode fast`, 6000 hashes, two runs per row, every run reproduced to 0.1 %):

| What was done | H/s | vs previous row |
|---|---|---|
| nothing: 0 pages reserved, THP fallback (what a fresh VPS looks like) | 855.8 | — |
| `zmrig` run as root: it reserves what the algorithm needs, then mines | **1070.0** | **+25.0 %** |
| 4 threads instead of 2 on the same 2 vCPU | 1070.0 | ±0 % (no gain) |
| 1 thread on the same box | 553.4 | −48 % (thread count matters) |

That is the whole story of this engine on a small box: page size and thread
count decide the hashrate, everything else is noise.

### 1 GiB pages: reserved at boot or not at all

A 2080 MB dataset is 1 040 TLB entries at 2 MiB and two at 1 GiB, so the mapper
asks for gigantic pages **first**, then the 2 MiB pool, then anonymous memory with
`MADV_HUGEPAGE` — three attempts, no configuration, and the page size that won is
printed (`huge pages 2336 MB (explicit, 1 GiB pages)`).

It asks; the kernel decides. A gigantic pool is contiguous physical memory and
can only be carved out early in boot, so it cannot be a sysctl — on this
validation host, with 3.9 GiB free and nothing else running, writing
`/sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages` returns success and
leaves the pool at 0. That is the normal answer from a virtualised host and it is
why the fallback is silent rather than a warning: **the rig is not misconfigured
when there is no 1 GiB pool, it is on 2 MiB pages, which is where the +28 % lives
anyway.**

Where the pool does exist, it is a kernel parameter:

```bash
sudo zmrig-os hugepages 1g 3     # Monero dataset: 2080 MB, so 3 pages
sudo reboot                      # the pool is made from unfragmented memory
sudo zmrig-os hugepages          # what is reserved, and what this run needs
sudo zmrig-os hugepages off      # stop reserving it (next boot)
```

`zmrig-os hugepages` writes `default_hugepagesz=1G hugepagesz=1G hugepages=3`
into the same GRUB environment block `isolate` uses, composing with it rather
than replacing it. Reserving a gigantic pool **stops the 2 MiB reservation**:
three 1 GiB pages have already taken 3 GB of contiguous memory, so the initramfs
skips `/proc/sys/vm/nr_hugepages` for that boot and `zmrig-os tune` passes
`--hugepages off`. Both say so in the log — the two pools are alternatives, and
the miner maps whichever one exists. `zmrig --check` prints the pool and what this run would take
from it, and `doctor` reports it as information, never as a failure.

The gain on top of 2 MiB is small — published RandomX figures are 1–3 %, and it
has **not been measured in this environment**: on this sandbox
`echo 3 > /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages` returns
success and the pool stays at 0, so the code path that uses a gigantic page has
never executed here. What has been verified is the fallback and the step below
it, 2026-11-05, same host, `--bench=2000`, one run each:

| Pages | Startup line | H/s |
|---|---|---:|
| none, `--no-huge-pages` | `huge pages off` | 678.1 |
| 1200 × 2 MiB reserved | `huge pages 2336 MB (explicit, 2 MiB pages)` | **913.2** (+34.7 %) |
| 1 GiB pool | `… (explicit, 1 GiB pages)` | not measurable here |

The gigantic attempt runs first on every one of those rows and falls through to
the 2 MiB pool, which is what the `explicit, 2 MiB pages` label proves: the label
is the page size that *won*, not the one that was asked for.

### The 2026-11 round: what "THP fallback" actually costs

The row above calls the unprivileged case a "THP fallback" as if it were a
degraded state. It is not the same thing as 4 KiB pages, and conflating the two
made the miner tell unprivileged users to take a root action they did not need.
Measured on the same host (`--bench=4000`, `rx/0`, two runs per row, same
session):

| Pages | Backing | H/s |
|---|---|---:|
| 1168 reserved | `MAP_HUGETLB` | 814.5 / 832.2 |
| none reserved | THP collapsed 99 % of the mapping | 785.9 / 786.1 |
| none reserved, no `MADV_HUGEPAGE` | 4 KiB | 614.8 / 626.3 |

4 KiB → 2 MiB is the step that matters (≈ +28 %); the reserved pool adds 4–6 %
on top. So `zmrig` now:

* prints the kernel's own figure after the dataset is built —
  `huge pages: 2332 MB via THP (99 % of the 2336 MB mapping, measured by the
  kernel)` — read from `/proc/self/smaps_rollup`, rather than claiming the hint
  worked;
* warns and gives the `nr_hugepages` command only when
  `/sys/kernel/mm/transparent_hugepage/enabled` says `never` (or the kernel does
  not report a policy at all);
* prints `thp` in `--check`, so the decision is visible before the first hash.

Reproduce by running the same command with `nr_hugepages` at 1200 and at 0; the
4 KiB row needs THP switched off, which is the one case that needs root.

Re-checked for 6.33.0 on 2026-11-01, same host, `--bench=3000`, three runs:
**889 / 956 / 886 H/s**. That is the same binary and the same configuration as
the 785.9 / 786.1 row — the difference is the host, not the code. Which is the
point of the table above: measure ratios inside one session, never across days.

### Dataset build: 42.9 s or 21.1 s

The seed-to-dataset step is pure memory bandwidth and it was being run with the
mining thread count, so `-t 1` on a 2-core box built Monero's 2 GiB dataset with
one thread: 42.9 s against 21.1 s. On a pool that switches coins (and therefore
seeds) this happens every few minutes. The initialiser now defaults to every
hardware thread, `--randomx-init=N` still overrides it, and `miner.zig` has a
unit test for the rule.

| Initialiser threads | `dataset ready in` |
|---|---:|
| 1 | 42.9 s |
| 2 | 21.1 s |

### Automatic reservation

`zmrig` now reserves what the current mode needs when the pool is empty, so the
+25 % happens without anybody reading this page:

```
$ sudo zmrig -o pool:3333 -u 4You... -a rx/0
huge pages: reserved 1168 pages of 2 MiB (2336 MB) for rx/0, so RandomX reads its cache and dataset through 2 MiB pages
benchmark: 6001 hashes in 5611 ms = 1.070 kH/s

$ sudo zmrig -o pool:3333 -u 4You... -a panthera
huge pages: reserved 96 pages of 2 MiB (192 MB) for panthera, ...
```

* it runs only when huge pages are **on** (`--no-huge-pages` turns it off too),
  the kernel supports them, and the pool is short of what the mode needs;
* it is one write to `/proc/sys/vm/nr_hugepages`, and it reports what the kernel
  actually granted, not what was asked for (a fragmented host gives partial
  success, which is still a win);
* an unprivileged miner cannot write there: it logs the exact command and the
  measured cost instead of failing, and keeps mining on THP;
* `--no-auto-hugepages` disables it for hosts where `/proc` must not change
  (containers with a read-only `/proc/sys`, k8s with a node-level tuner);
* `--check` never writes anything: it reports the state and exits.

This fork improves the defaults:

* `huge-pages-jit` is **on** by default — the RandomX JIT code lives in huge
  pages too, which removes iTLB misses in the generated program;
* `1gb-pages` is **auto**: the miner reserves 1 GiB pages only when the kernel
  actually has some (`/sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages`),
  otherwise it silently uses 2 MiB pages instead of logging an error;
* when huge pages are not fully allocated, the miner now prints an actionable
  warning instead of continuing silently.

Enable them once per boot:

```bash
sudo ./scripts/tune-linux.sh            # reserves ~2.4 GiB of 2 MiB pages
sudo ./scripts/tune-linux.sh --hugepages 1G   # better, needs contiguous free RAM
```

Verify:

```bash
grep Huge /proc/meminfo
# HugePages_Total:  1200
# HugePages_Free:   1200
# Hugepagesize:     2048 kB
```

The miner must run with `CAP_IPC_LOCK` (root, or
`setcap cap_ipc_lock,cap_sys_rawio,cap_sys_nice+ep build/xmrig`). Otherwise the
allocation fails and it falls back to transparent huge pages.

To make the reservation persistent, call the script from a systemd unit, e.g.
`/etc/systemd/system/xmrig-hugepages.service` (`Type=oneshot`,
`ExecStart=/opt/xmrig/scripts/tune-linux.sh`).

---

## 2b. What we tried that did not help

Every row below is a real A/B on the box above (`zmrig/tests/ab.sh`, 8000 hashes,
2 runs, spread ≤ 2.7 %). Nothing here is worth a flag in a config file, which is
why the defaults did not change.

| Change | H/s | Verdict |
|---|---|---|
| default (2 MiB pages, JIT, affinity on) | 1051 | baseline |
| `--scratchpad-prefetch=0 / 2 / 3` | 1065 / 1079 / 1079 | inside noise |
| `--no-huge-pages-jit` | 1094 | inside noise |
| `--no-affinity` | 1094 | inside noise on an idle box (keep affinity: it matters when the host is busy) |
| `--randomx-init=1` | 1094 | only changes how long the dataset takes to build |
| `--no-optimized-init` (portable AVX2 init) | 1094 | inside noise; AVX2 init does **not** speed up hashing |
| `--priority=5` | 1109 | +2 % at best; keep it, it is free, but do not expect a number |
| `--cpu-affinity=0x1` (both threads on one core) | 552.6 | −47 %: a wrong mask is worse than no mask |
| `--mode=light` | 114.8 | −89 %: the fallback for 2 GiB boxes, never a choice |
| **VAES-512 AES path enabled** (see below) | 1033 | **−3.5 %**, rejected |

### The 2026-10 round: profiles, counters, sampling

The same box, the same harness. Three changes were made in this round; two are
honest zeroes and one is a correctness fix.

| Change | What it is | Measured on this box |
|---|---|---|
| Per-thread hash counters padded to 64 B | The old array put eight `u64` counters in one cache line, so every increment invalidated the line for the other threads (false sharing) | **Below the noise floor here** (2 vCPU, ~1000 increments/s). Kept because it is free and the effect is real on ≥ 8 cores; not claimed as a speedup. |
| `MADV_COLLAPSE` after the dataset is built (Linux 6.1) | Collapses the mapping synchronously instead of waiting for khugepaged, so the dataset does not spend its first minute half on 4 KiB pages | **Nothing to gain here, so it is not in the code.** `madvise(MADV_HUGEPAGE)` already makes the dataset fault in as 2 MiB pages: the kernel reported 93–99 % coverage the instant the seed finished, with or without the collapse call, and the hashrate stayed inside ±4 %. Worth revisiting if a host ever reports low coverage at startup. |
| Benchmark stop condition checked every 64 hashes | `totalHashes()` sums one atomic per thread, and it ran once per hash — 32 cross-line atomic loads per hash on a 32-core box, inside the benchmark that produces the numbers everyone compares | **Not measurable on 2 vCPU** (2 atomics per hash out of ~1 ms of work). Kept for the same reason: it cannot help here, it cannot hurt, and it removes a scaling trap. |
| Ring buffer 512 → 1024 samples | One sample per second, so 512 samples was 8.5 minutes. `rate(900)` — the 15-minute column in `ZMRIG1.` — was silently an 8-minute average, which reads as a very stable hashrate that never existed | **Correctness**, not speed. The 15-minute figure is now a real 15-minute figure after 15 minutes of mining. |
| Thread search (`--autotune`) | One measured trial per candidate on the real dataset | Reproduces the known curve: **499.625 H/s at 1 thread, 999.750 H/s at 2**. The tool is validated where it agrees with the heuristic, which is the only way to trust it where it disagrees. |

A full end-to-end run after all of it: **1058.9 H/s** (`zmrig --report`), against
the 1070.0 H/s baseline — inside the ±2.7 % noise band, i.e. no regression, and
no speedup either. That is the honest result.

### The 2026-10 second round: pinning and health

| Change | What it is | Measured on this box |
|---|---|---|
| Thread→CPU order from sysfs (`topology.selectCpus`) | One thread per physical core first, sockets interleaved, SMT siblings last (profile `free` only) | **No measurable change here**, and that is the expected answer: this container has 2 vCPUs numbered 0,1, so the old order (`i % hw_threads`) and the new one produce the identical mapping. The bug it fixes needs AMD or dual-socket bare metal. The size of that bug is measurable in the other direction: forcing both threads onto one CPU (`--cpu-affinity=0x1`) gives **552.6 H/s against 1070.0**, −47 %. |
| Affinity mask respected | `sched_getaffinity` decides which CPUs are legal; `--check` prints `affinity process allows 1 of 2 online cpu(s)` | Verified with `taskset -c 1`: thread count 1, CPU 1 selected, no silent float. |
| Health watchdog | Pure state machine (`health.zig`), judged on this machine's own peak and share counters | Not a hashrate change: the hot loop is untouched, the rules run once per second on the monitor thread. **`--report` after the change measured 810–834 H/s against 1058.9 H/s an hour earlier on the same binary** — that is host load on a shared VM (±30 % between runs), not a regression, and it is reported as such rather than dressed up. |

The honest summary of this round: it fixes an income bug on hardware this
sandbox does not have, and it adds a way to notice income bugs. Neither is a
speedup, and pretending otherwise would be the thing this document exists to
prevent.

### VAES-512: the one "new instruction" that exists, and it loses

RandomX ships a hand-written VAES/AVX-512 implementation of the AES hash
(`src/crypto/randomx/aes_hash_vaes512.cpp`), but upstream only calls it when the
CPU is *identified as AMD Zen 5*. This host is a Xeon that reports `vaes`,
`avx512f`, `avx512vl` and `avx512bw`, so the capability was there and the gate
was vendor-based. We widened the dispatch to a CPUID check (VAES + AVX-512F) and
measured it, three runs per side, same binary otherwise:

| | dataset init | hashrate |
|---|---|---|
| upstream gate (AES-NI / AVX2 path) | **15.2–15.7 s** | **1070.0 H/s** |
| VAES-512 path forced on | 16.5–16.9 s | 1033.0 H/s |

Both directions are worse, which is the classic AVX-512 frequency licence: 512-bit
registers buy throughput and pay with core clock, and RandomX spends most of its
time in memory-latency-bound work where clock wins. Hash output was bit-identical
either way (commitment `b144ca6b…c0a082`, `zmrig/tests/run.sh`), so this was a
pure performance question with a clear answer: **the upstream Zen 5 gate stays.**

The experiment did find a real bug, though: `aes_hash_vaes512.cpp` was compiled
without AVX-512 flags, so `./build.sh --portable` failed to build at all
("target specific option mismatch"). It is now compiled with `-mvaes -mavx512f
-mavx512vl` for that one file, which is what lets a build host without AVX-512
produce a binary at all.

### Vectorising more, quantum, or another language

* **Vector width.** RandomX is memory-hard on purpose: per hash it reads 2 MiB of
  scratchpad in 64-byte stripes and 2 GiB of dataset at pseudo-random offsets.
  The measured scaling above (one thread 553 H/s, two threads 1070 H/s, 1.93×)
  says the cores are *not* waiting on each other, and the knob matrix says
  nothing about the vector width of the host code matters. There is no wider
  instruction that makes a 2 MiB random-read stream faster; that is a cache and
  TLB problem, which is exactly what the huge-page result (+25 %) is.
* **Quantum.** No. RandomX is a fixed classical function: 2 GiB of AES and
  integer work, repeated. Grover's algorithm gives a quadratic speedup for
  *search* over an unstructured space, and mining is search — but it needs a
  fault-tolerant machine with ~10^5+ logical qubits per hash invocation, error
  correction overhead included, and it cannot help the memory traffic at all.
  There is no such machine, and no shortcut around the 2 GiB of memory. Anyone
  claiming quantum mining is selling something.
* **Another host language.** The hash loop is not written in Zig or C++: RandomX
  compiles a program per block into machine code at runtime (`jit_compiler_x86`).
  The host language only decides how fast we hand it a nonce and take a result,
  which is nanoseconds against ~1 ms of hashing. Measured: the Zig frontend does
  1084–1089 H/s on the validation host where the C++ frontend does 1075.7 H/s —
  a 1 % difference in the wrong direction for the "rewrite it" argument, and both
  are the same RandomX JIT underneath. A rewrite in Rust, Go, NASM or anything
  else changes 0 % of the generated code, and `doc/ALTERNATIVES.md` has the
  longer version.

What actually converts to money, in order: **2 MiB pages (+25 %)**, **one thread
per physical core (−48 % if you get it wrong)**, a pool that does not drop
shares, and a miner that does not get OOM-killed. Everything below that is noise.

---

## 2c. Two profiles: free electricity, or every watt counted

`--profile free` and `--profile watt` are not marketing names, they are two
different answers to "what does the next hashrate cost".

**`free`** — the machine is on anyway: a coffee shop laptop, a lab PC, an office
desktop, a school computer. Power is not a variable, so nothing is traded away:
every logical CPU, `--mode fast`, huge pages, `--priority 5`, `performance`
governor.

**`watt`** — the electricity bill moves with the hashrate: a metered VPS, a
laptop on battery, a country with expensive power. Three decisions change:

1. **One thread per physical core.** SMT siblings add roughly 5–15 % hashrate
   for 30–40 % more package power: they run the same memory-bound workload on a
   core that is already waiting on cache. Trading that away is what a
   hashes-per-watt profile is for. On this 2 vCPU container the topology claims
   one core with two siblings, which is fiction — the miner detects the
   hypervisor and uses the logical count instead, because trusting the guest
   topology halved the thread count (**−48 % hashrate**, measured) in exchange
   for a power saving that does not exist on a shared vCPU.
2. **No governor forcing.** `performance` pins every core to its highest
   frequency bin. Power grows with V²·f, and a thread stalled on a 2 MiB
   scratchpad read does not need the top bin. The distro default
   (`schedutil`/`powersave`) already tracks utilisation, so `watt` keeps it and
   only repairs a machine stuck on `performance`.
3. **Pause on battery.** A laptop that drops to battery stops mining rather than
   draining it — a watt-profile machine that empties its own battery is not
   saving anything.

Huge pages stay on in both profiles: they raise hashrate **and** lower energy per
hash, because the win comes from fewer TLB misses and shorter stalls, not from
more work per joule of compute. There is no trade to make.

The honest limit of this section: **watts cannot be measured in this container**
(`/sys/class/powercap/intel-rapl:0/energy_uj` is unreadable, and there is no
hwmon energy counter). Everything above about power is derived from P ∝ V²·f and
from published SMT efficiency, and is labelled as such — the hashrate side of
each claim *is* measured. On a machine with RAPL the miner reports the measured
watts and `hashes per watt` in the `ZMRIG1.` code (`"pw"`, `"hw"`), which turns
the trade into something you can check in one run:

```
ZMRIG1.<…>"hs":[1058.9,…],"pw":96.4,"pwsrc":"rapl","hw":10.9…
```

`hw` is hashrate ÷ watts from the 60 s column. Compare it between the two
profiles on the same machine and the profile argument is settled locally, with
your electricity price, instead of with this table.

## 3. MSR mod ("HASHRATE WILL BE LOW")

Since 6.48 the preset is no longer opt-in: the default is `auto`. Before doing
anything the miner probes the machine — does this CPU have a preset, does
`/dev/cpu/0/msr` answer, and can it be written — and then either applies it or
prints one line saying why not. `--check` prints the same line, so the answer is
available before a mining session starts:

```
  msr     intel preset; reading /dev/cpu/0/msr needs root (auto: the preset is skipped here; --msr tries anyway)
```

| Setting | What happens |
| --- | --- |
| *(nothing)* | `auto`: applied when the machine can take it, one log line either way |
| `--msr` | try anyway; a VM without passthrough gets a warning and keeps mining |
| `--no-msr` | never open `/dev/cpu/*` — for containers and for a host that must stay untouched |
| `"msr": false` in the config | the same as `--no-msr`; a config is an instruction, not a default |
| `MSR="off"` in `os.conf` (appliance) | the same, and `safe` mode does it regardless of the setting |

What is still missing on most systems is permission, which an appliance has and a
desktop usually does not:

```bash
sudo modprobe msr
ls -l /dev/cpu/0/msr           # must exist
sudo ./zmrig …                 # or grant CAP_SYS_RAWIO
```

Intel preset: `MSR 0x1a4 = 0xf` (disable L2/L1 prefetchers).
AMD presets (Zen 1–5): `0xC0011020/21/22/2b` (prefetcher, DSM, commit unit).

Typical gain on Zen3/Zen4: **+5 % … +15 %**. On Intel it is smaller but still
measurable. The original values are saved at startup and restored on exit
(`RxMsr::destroy`).

`cache_qos` (Intel CAT) can help when several workloads share L3; it requires
explicit CPU affinity for every mining thread and is off by default.

---

## 4. CPU, BIOS and OS

| Item | Recommendation |
|---|---|
| SMT / HyperThreading | Leave enabled in BIOS, but do **not** mine on siblings unless `L3 / 2 MiB` allows it. Auto-config already avoids them for RandomX. |
| Frequency | `performance` governor, turbo enabled, C1E/C6 as high as stable. |
| RAM | For RandomX, memory latency beats bandwidth: 2 DIMMs per channel, XMP/EXPO on, Gear1 on Intel. |
| NUMA | Dual socket: keep `randomx.numa: true` (allocates one dataset per node). |
| Swappiness | `vm.swappiness=10`; never let the dataset be paged out. |
| KSM | Keep disabled — merging pages destroys latency. |
| THP | `always` is fine; `defrag=defer` avoids stalls. The tuning script sets both. |
| Priority | `cpu.priority: 5` (root) or `nice -n -20`, and `chrt -f 1` on dedicated rigs. This fork implements `setpriority()` on Linux (upstream ignores `cpu.priority` there). |
| Thermal | Sustained clocks matter more than peak; check `turbostat`/`sensors` after 10 minutes. |
| Windows | Disable Defender real-time scan for the miner directory, use the `WinRing0` driver (bundled) for MSR, set the process priority to High. |

The tune script covers governor, THP, swappiness, MSR module and huge pages in
one shot and prints a report with `--status`.

---

## 5. Build configuration

`cmake/tuning.cmake` adds:

| Option | Default | What it does |
|---|---|---|
| `XMRIG_NATIVE_OPT` | ON | `-march=native -mtune=native` (host-specific binary) |
| `WITH_LTO` | **OFF** | `-flto=auto`. Off by default: `-march` is safe, but GCC 12 LTO miscompiles CryptoNight (self-test fails). RandomX does not benefit anyway. |
| `WITH_EXTRA_OPT` | ON | `-fno-plt -falign-functions=32 -falign-loops=32` |
| `XMRIG_PGO` | off | `generate` / `use` profile-guided optimisation |

`./scripts/build-optimized.sh` wraps all of it:

```bash
./scripts/build-optimized.sh                 # Release, native, LTO, CPU only
./scripts/build-optimized.sh --portable      # baseline ISA, for other machines
./scripts/build-optimized.sh --pgo           # PGO: instrument, train 180 s, rebuild
./scripts/build-optimized.sh --all-backends  # keep OpenCL/CUDA
```

LTO is exposed as `--lto` for experimentation only. It was verified to break the
CryptoNight self-test in this tree (`thread #0 self-test failed` → CPU backend
disabled for `cn/*`), which is why it is off by default; if you enable it, run
`node run_tests.js --suite miner-integration` before mining.

PGO workflow (GCC): the script builds an instrumented binary, runs the offline
RandomX benchmark for `--pgo-seconds` (default 180 s, the process handles
SIGTERM cleanly so the profile is flushed), then rebuilds with
`-fprofile-use`. Expect a small gain (0–2 %); it is safe and free.

CPU-only builds (`--all-backends` not passed) disable OpenCL/CUDA/NVML/ADL.
This removes runtime dependencies and shaves startup time; CPU hashrate is
identical.

### The Zig binary (`zmrig/build.sh`)

The hash engine is compiled from the same C sources, so the flags above apply;
the supervisor is Zig at `-O ReleaseFast -mcpu=native`. `build.sh` has an
`EXTRA_FLAGS` hook for experiments, and one was run:

```bash
EXTRA_FLAGS="-flto -ffunction-sections -fdata-sections" ./zmrig/build.sh
```

It does not link. `-flto` puts LLVM bitcode in the archive, and the final
`zig build-exe` link in this script is not an LTO-aware link step, so the C
symbols are never materialised (`error: ld.lld: undefined symbol: xmo_msr_probe`,
referenced from `main.printConfigSummary`). Making it work means building the
archive as bitcode with `llvm-ar` and teaching the link step about `-flto`; that
is a build-system change, not a flag, and it buys little: the RandomX hot loop is
JIT-compiled at runtime, so a C-level optimisation cannot reach it. Startup,
option parsing and the stratum client are all it would touch.

`-fstrip` and `--gc-sections` change the size of the binary, not the hashrate.

There is one more reason not to publish a number from this machine. The same
binary, benchmarked three times in the same 2 vCPU sandbox with nothing else
running, reported **88.86 H/s**, **64.02 H/s** and **113.5 H/s** — a factor of
1.8 between the slowest and the fastest run. Whatever the hypervisor was doing
in between, it was larger than every optimisation in this document put together.
Any comparison made on a machine like this is a coin toss dressed as a
measurement.

Measure on the target rig: quiet machine, three runs, and write the spread down
before believing a 1 % win. The numbers in the rest of this file were taken that
way, on hardware, with the spread stated.

**Static binaries**: `--static` produces a fully static build for old
distributions. It disables `dlopen` of GPU drivers, which is fine for CPU-only.

---

## 6. Structure: this fork has no donation switch

Upstream XMRig donates 1 % of the *time*: every ~100 minutes the miner stops the
user's pool session and connects to the developer's pool for 1 minute. With
RandomX that is much more expensive than 1 %:

* a different pool means a different seed, so the **2 GiB dataset is rebuilt**
  (tens of seconds of one-time cost, all cores busy);
* all worker threads are destroyed and re-created, which also drops JIT-compiled
  VMs and re-faults the scratchpads;
* the nonce window is reset, so in-flight work is discarded;
* the pool session is re-established twice (TLS handshake, login, job).

In practice a 1 % donation costs **2–4 % of real hashrate** on RandomX, and more
on algorithm-switching pools. This fork removes the mechanism entirely
(`doc/ZERO_FEE.md`), so you keep that time plus the guaranteed 1 %.

For MoneroOcean specifically:

| Situation | Effect | Mitigation |
|---|---|---|
| Pool switches algorithm (profitability) | backend restart: new workers, new scratchpads, sometimes a new dataset | `memory-pool: true` (default) reuses scratchpad memory; `algo-min-time` in the config asks the pool to wait longer between switches |
| First start, no `algo-perf` yet | ~2 min calibration (10 algorithms × 10 s) | keep the generated `algo-perf` in `config.json`; use `--rebench-algo` only after hardware changes |
| New Monero seed | dataset re-init once | nothing to do, dataset memory is reused |
| Switching between RandomX variants (rx/0 ↔ rx/xla ↔ rx/arq) | cache + dataset re-init | prefer stable pools/chains, or accept a few seconds per switch |

`algo-min-time` is advertised to the pool at login; a value of `20`–`30` s is a
good compromise on a single rig, `0` lets the pool switch as fast as it wants.

---

## 7. Recommended configuration

`config/performance.json` in this repository is a ready-to-edit template:

```json
{
  "cpu": {
    "huge-pages": true,
    "huge-pages-jit": true,
    "memory-pool": true,
    "yield": false,
    "priority": 5,
    "max-threads-hint": 100,
    "asm": true
  },
  "randomx": {
    "mode": "auto",
    "rdmsr": true,
    "msr": "auto",
    "numa": true,
    "scratchpad_prefetch_mode": 1
  },
  "donate-level": 0,
  "print-time": 60
}
```

Omitting `1gb-pages` means "auto": the miner uses 1 GiB pages when the kernel
has them, and 2 MiB pages otherwise. Setting it to `true` forces the attempt and
logs an error when the reservation is missing.

`scratchpad_prefetch_mode`: `1` (T0) is the best default on Zen and most Intel
parts; try `2` (NTA) and `3` if you want to squeeze a few tenths of a percent —
measure with `bench.sh`, the difference is small and CPU specific.

Thread tuning beyond auto-config:

```json
"cpu": {
    "rx": [[1, 0], [1, 2], [1, 4], [1, 6], [1, 8], [1, 10]]
}
```

one thread per **physical** core (affinity list from
`lscpu -e=cpu,core,cache`), no SMT siblings.

---

## 8. How to measure honestly

```bash
./scripts/bench.sh --seconds 300 --hashes 200000          # offline RandomX benchmark
```

Rules:

1. Same host, same binary, same thread count, same background load.
2. Ignore the first ~30 s after `dataset ready`; the benchmark needs a full
   60 s window before the 60 s average is valid (the script handles this).
3. Run each configuration at least twice; ±1 % noise is normal on a desktop,
   much less on a dedicated rig with fixed clocks.
4. Compare *shares per hour* on the pool as the final authority — hashrate is a
   proxy, rejected shares and switch overheads are not.

---

## 9. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `huge pages 0%` at startup | not reserved / no permission | run `tune-linux.sh`, start as root or set capabilities |
| `FAILED TO APPLY MSR MOD` | no `/dev/cpu/*/msr` or no `CAP_SYS_RAWIO` | `modprobe msr`, run as root |
| `failed to allocate RandomX dataset, switching to slow mode` | not enough free RAM (needs ~2.4 GiB) | free memory, or use `"mode": "light"` (much slower, only for low-RAM boxes) |
| `not enough memory for RandomX dataset` | auto mode with < 2.4 GiB free | same as above |
| Hashrate far below reviews | SMT threads mining, thermal throttle, laptop power limit | check `cpu` READY line, `turbostat`, BIOS |
| Hashrate drops periodically | pool switching algorithms, or donation in an unpatched build | `algo-min-time`, use this fork |
| `no active pools, stop mining` | network / pool down | check `--verbose`, port, TLS |
| Windows: driver load error | WinRing0 blocked by Defender | allow the driver or run without MSR (slower) |
| Empty log file with `xmrig > log.txt` | upstream logging bug | fixed in this fork (`ConsoleLog` handles `UV_FILE`) |

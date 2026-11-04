# Architecture

This document maps the whole tree: what each directory does, how a job travels
from a pool to the CPU and back, which threads exist at runtime, and where the
hot paths are. It describes **this** tree (XMRig `6.26.0-mo5`, MoneroOcean
flavour, hardened and tuned by this fork), not upstream XMRig in general.

---

## 1. What this project is

A CPU/GPU proof-of-work miner. Three layers matter:

| Layer | Responsibility |
|---|---|
| **base** | Transport agnostic infrastructure: config parsing, logging, HTTP API, DNS, event loop helpers, stratum protocol client, job object. |
| **core** | Application logic: `App`, `Controller`, `Miner`, `Network`, `Summary`, config aggregation, MoneroOcean algo-perf calibration. |
| **crypto / backend** | Hashing and hardware interaction: RandomX (JIT), CryptoNight family, Argon2, GhostRider, KawPow, MSR access, huge pages, NUMA, CPU/OpenCL/CUDA workers. |

Supported algorithm families (`src/base/crypto/Algorithm.cpp`): RandomX
(`rx/*`), CryptoNight (`cn/*`, `cn-lite/*`, `cn-heavy/*`, `cn-pico/*`,
`cn/upx2`, `cn/gpu`) plus the MoneroOcean additions Panthera (`rx/xla`),
Flex/KCN (`flex`), Argon2 (`argon2/*`), GhostRider (`ghostrider`) and KawPow
(GPU only).

---

## 2. Directory map

```
src/
├── xmrig.cpp                 entry point: Process(argv) -> App::exec()
├── App.cpp / App_unix.cpp    lifecycle, signals, console command reader, background fork
├── Summary.cpp               startup banner (CPU, memory, huge pages, DONATE, pools)
├── donate.h                  C++ engine fee policy (0% here, compile-time constant)
├── version.h                 APP_VERSION / APP_OS / APP_ARCH
│
├── base/                     infrastructure, no mining logic
│   ├── crypto/               Algorithm, Coin, keccak, base58 helpers
│   ├── io/                   Log (+ backends: ConsoleLog, FileLog, SysLog), Console,
│   │                         Signals, Async (uv helpers)
│   ├── kernel/               Base (event loop owner), Process, Platform_* (priority,
│   │   │                     huge pages, affinity, idle detection), config/BaseConfig
│   │   └── interfaces/       IConfig, IJsonReader, ITimerListener, IStrategy, ...
│   ├── net/                  DNS, stratum client, HTTP client, Pool/Pools/Job,
│   │   └── stratum/          strategies/{SinglePoolStrategy, FailoverStrategy}
│   ├── api/                  HTTP JSON API (Api, Httpd, requests)
│   └── tools/                String, Buffer, Cvt, Chrono, Timer, Alignment, Object
│
├── core/                     orchestration
│   ├── Controller.{h,cpp}    owns Base + Miner + Network, config reload, start/stop
│   ├── Miner.{h,cpp}         job fan-out to backends, hashrate reporting, pause/resume
│   ├── MoBenchmark.{h,cpp}   MoneroOcean algo-perf calibration + algo-perf in login
│   ├── Network.{h,cpp}       pool strategies, job routing, submit routing, API glue
│   ├── config/               Config, ConfigTransform, Config_platform (CLI table),
│   │                         Config_default (embedded JSON), usage.h
│   └── Taskbar.cpp           Windows taskbar progress
│
├── backend/                  mining backends
│   ├── common/               Worker/Workers/Thread/Threads, Hashrate(+Interpolator),
│   │                         Nonce plumbing, benchmark/BenchState (RandomX bench)
│   ├── cpu/                  Cpu (info), CpuConfig(+_gen), CpuLaunchData, CpuWorker
│   │   └── platform/         BasicCpuInfo (no hwloc), HwlocCpuInfo (hwloc topology)
│   ├── opencl/               AMD/NVIDIA via OpenCL (kernels in cl/)
│   └── cuda/                 NVIDIA via external xmrig-cuda plugin
│
├── crypto/
│   ├── randomx/              vendored RandomX + MoneroOcean fork variants, JIT,
│   │                         dataset/cache, AVX2/AVX-512 init, VAES-512 AES hash
│   ├── cn/                   CryptoNight: C reference + per-arch ASM + VAES/AVX2
│   ├── rx/                   XMRig glue: Rx (dataset lifecycle), RxQueue (init
│   │                         thread), RxBasicStorage / RxNUMAStorage, RxVm,
│   │                         RxMsr (MSR mod), RxFix (Ryzen fix), Profiler
│   ├── argon2/, flex/, ghostrider/, kawpow/
│   └── common/               VirtualMemory (huge/1GB pages), MemoryPool,
│                             NUMAMemoryPool, Nonce, LinuxMemory (sysfs)
│
├── hw/
│   ├── msr/                  /dev/cpu/*/msr (Linux) and WinRing0 (Windows) access
│   ├── dmi/                  SMBIOS reader for the startup banner
│   └── api/                  CPUID + topology helpers
│
├── net/                      JobResults (share queue) and Network (see core/)
├── 3rdparty/                 fmt, rapidjson, hwloc, libuv shim headers, argon2,
│                             base32, getopt, epee span
├── cmake/                    cpu/os/flags/randomx/argon2/kawpow/ghostrider/
│                             OpenSSL/asm/cn-gpu + tuning.cmake (this fork)
└── tests/hash/               standalone known-answer test binary (no network)
```

Build entry points: `CMakeLists.txt` (+ `cmake/*.cmake`). Test entry point:
`run_tests.js` → `tests/hash` (hash vectors) and `tests/common/miner_harness.js`
(miner integration).

---

## 3. Startup sequence

1. `xmrig.cpp` — `Process` parses CLI + JSON config (`ConfigTransform`,
   `BaseTransform`, `Config_platform.h` option table).
2. `App` constructs `Controller` (owns `Base`, `Api`, `Miner`, `Network`).
3. `Controller::init()` → `Base::init()`:
   - `Platform::init()` (user agent, title),
   - log backends: `ConsoleLog` (`ConsoleLog` fix in this fork also handles
     redirection to a regular file), optional `FileLog`, optional `SysLog`,
   - `VirtualMemory::init(cpu.memPoolSize(), hugePageSize)` — the scratchpad
     pool used by CryptoNight and RandomX workers,
   - `Miner` is constructed: `Rx::init(this)` starts the `RxQueue` thread,
     CPU/OpenCL/CUDA backends are created and `Miner::rebuild()` enumerates the
     algorithms the backends can run.
4. `Network` constructs the pool strategy (`SinglePoolStrategy` when only one
   pool is enabled, `FailoverStrategy` otherwise) and a 1 s tick timer. There is
   no second strategy anymore: the donation strategy was removed from this fork.
5. `Summary::print()` prints the banner and the effective configuration.
6. `Controller::start()` → `Network::connect()` → stratum login. On success the
   `Client` receives a job, which enters the pipeline described below.

---

## 4. Threads at runtime

| Thread | Created by | Work |
|---|---|---|
| main | process | `uv_run()`: DNS, TCP/TLS, stratum parsing, HTTP API, timers (1 s network tick, 500 ms miner tick), hashrate sampling. Never hashes. |
| `RxQueue` init thread | `Rx::init()` | Builds the RandomX cache and the 2 GiB dataset when a new seed arrives; blocks nobody but reports readiness asynchronously. |
| `Workers` creator thread | `Workers<CpuLaunchData>::start()` | Instantiates `CpuWorker`s (heavy: `VirtualMemory` + RandomX VM), reports readiness. |
| CPU workers | `CpuWorker<N>` | The hash loop (`CpuWorker::start()`), one thread per configured `CpuThread`; GhostRider adds a helper thread. |
| dataset init threads | `RxDataset::init()` | N short-lived threads, one per `randomx.init` thread, then joined. |
| dataset update watchdog | `Rx` / `RxQueue` | `Async` posts `onDatasetReady()` back to the main loop. |
| console reader | `Console` (stdin TTY) | Single byte commands: `h` hashrate, `p` pause, `r` resume, `s` results, `c` connection. |
| OpenCL/CUDA | per GPU | Kernel execution; hashrate collected by the main loop. |

Nonce ownership: `Nonce::sequence(backend)` is a monotonically increasing job
sequence; `Nonce::isOutdated()` stops workers immediately on a job change.
Each worker reserves `kReserveCount = 32768` nonces per round
(`CpuWorker::nextRound`), which keeps atomic traffic at ~1 op per 32 k hashes.

---

## 5. Job → hash → share data flow

```
pool (JSON line)
   │  Client::parseJob
   ▼
Network::onJob(strategy, client, job)                 [main thread]
   │  Network::setJob()  (logs diff / algo / height)
   ▼
Miner::setJob(job)                                    [main thread]
   │  ├─ backend->prepare(job)             (argon2 impl selection, ...)
   │  ├─ RandomX?  Rx::init(job, rxConfig, cpuConfig)
   │  │      ├─ dataset ready      → continue
   │  │      └─ not ready          → Nonce::pause(true), return;
   │  │                              RxQueue finishes → Miner::onDatasetReady()
   │  ├─ d_ptr->job = job; job.setIndex(0); reset nonce unless same blob
   │  └─ handleJobChange(): Nonce::reset(0) → backend->setJob(job)
   ▼
CpuBackend::setJob(job)                               [main thread]
   │  threads = cpu.get(miner, job.algorithm())       (config profile or auto)
   │  unchanged layout? keep running : stop() + start()
   ▼
CpuWorker<N>::consumeJob()                            [worker thread]
   │  copies the job into WorkerJob<N> (blob, target, nonce window)
   ▼
CpuWorker<N>::start()  ── inner loop ──┐
   │  RandomX: randomx_calculate_hash_first / _next
   │  CN/etc.: CnHash::fn(algo)(blob, size, hash, ctx, height)
   │  compare hash[24..31] < job.target()
   └──────────────────────────────────► JobResults::submit(job, nonce, hash, extra)
                                          │ uv_queue_work (main thread)
                                          ▼
                              Network::onJobResult()
                                          │ strategy->submit(result)
                                          ▼
                              Client::submit() → pool
```

Share validation happens **in the worker** (the last 8 bytes of the hash are
compared with the target) so only real shares cross the thread boundary.

Batch/benchmark note: `JobResults` is also the listener used by the built-in
RandomX benchmark (`--bench`) and by `MoBenchmark` calibration; both swap the
listener temporarily and restore `Network` afterwards.

---

## 6. RandomX pipeline (the hot path on CPU)

```
seed (32 bytes from the pool)
   │
   ├─ RxCache (256 MiB, Argon2-based, JIT-compiled when possible)
   │     built once per seed; light-mode VMs read from it
   │
   └─ RxDataset (2080 MiB, "fast mode")
         ├─ allocated by VirtualMemory: 1 GiB pages if reserved, else 2 MiB huge
         │  pages, else plain mmap + MADV_HUGEPAGE (transparent huge pages)
         ├─ initialised by RxDataset::init() on `randomx.init` threads
         │  (optimised AVX2/JIT initialiser, `randomx.init-avx2`)
         └─ shared read-only by every CpuWorker

CpuWorker
   └─ RxVm::create(dataset, scratchpad, softAes, asm, numaNode)
         ├─ RANDOMX_FLAG_FULL_MEM | JIT (| LARGE_PAGES for the JIT code)
         ├─ program JIT-compiled per VM (superscalar interpreter)
         └─ 2 MiB scratchpad per thread, taken from the huge-page pool when
            available, otherwise from the dataset's 1 GiB mapping
```

Key knobs (`randomx` object, `src/crypto/rx/RxConfig.h`):

| Key | Meaning | Default in this fork |
|---|---|---|
| `mode` | `auto`/`fast`/`light` (fast = 2 GiB dataset) | `auto` |
| `init` | threads used for dataset init (`-1` = auto) | `-1` |
| `init-avx2` | AVX2/JIT optimised dataset init (`-1` = auto) | `-1` |
| `1gb-pages` | use 1 GiB pages (**auto-detected** here) | `auto` |
| `rdmsr` / `wrmsr` | MSR mod (fix prefetcher/commit unit) | `true` / `true` |
| `cache_qos` | Intel CAT: isolate L3 per thread | `false` |
| `numa` | one dataset per NUMA node | `true` |
| `scratchpad_prefetch_mode` | `0`off `1`T0 `2`NTA `3`movntdqa | `1` |

Why the MSR mod matters: RandomX is memory-latency bound. Setting
`MSR 0x1a4 = 0xf` (Intel) or the `0xC00110xx` preset (AMD) disables the hardware
prefetcher/streamer behaviour that thrashes the 2 MiB scratchpad and adds
DSM/commit-unit tweaks on Zen. Without it the miner prints
`FAILED TO APPLY MSR MOD, HASHRATE WILL BE LOW` at startup.

Dataset reuse: `RxBasicStorage` keeps one dataset allocation and re-initialises
it when the seed changes, so a new Monero block only costs the init time, not a
new 2 GiB mapping. `RxNUMAStorage` keeps one dataset *per node*.

---

## 7. CryptoNight / Argon2 / GhostRider paths

* `CnHash::fn(algorithm, AlgoVariant, Assembly)` selects an implementation at
  runtime: `CnHash.cpp` (portable C), `gpu/cn_gpu_*.cpp`, `Cryptonight_x86_vaes.cpp`
  (VAES, Zen3+ / Alder Lake+), plus the `.S`/`.asm` variants in `crypto/cn/asm/`
  (`intel`, `ryzen`, `zen3`, `win64`, …). Selection order: explicit `cpu.asm`
  → `Assembly::AUTO` detection → `Cpu::info()->assembly()`.
* `--cpu-max-threads-hint` scales the auto-generated profiles; the generator
  (`CpuConfig_gen.h`) fills one profile per algorithm family and aliases
  identical ones (e.g. `rx/arq` → `rx/wow`).
* `cn/gpu` (`cn-gpu.cmake`) is a MoneroOcean addition: a CPU implementation of
  the GPU-oriented variant, intensity 1 per thread.
* GhostRider (`ghostrider.cpp`) runs 8 hashes at a time (`intensity = 8`) and
  may spawn a helper thread; Flex/KCN reuses the family but hashes singly.
* Argon2 uses its own implementation selector (`crypto/argon2/Impl.cpp`,
  `cpu.argon2-impl`).

---

## 8. Configuration system

```
CLI (Config_platform.h option table)
   └─ BaseTransform / ConfigTransform  → rapidjson::Document
          └─ Config::read()            → BaseConfig (pools, http, tls, ...)
                 ├─ Pools::load()      → std::vector<Pool>
                 ├─ CpuConfig::read()  → profiles + generate() auto profiles
                 ├─ RxConfig::read()   → RandomX knobs (MSR preset resolution)
                 └─ OclConfig / CudaConfig
```

* `Config_default.h` is only compiled with `-DWITH_EMBEDDED_CONFIG=ON`; it is the
  fallback when no `config.json` exists.
* `autosave` + `watch` add newly generated profiles to the file and reload it on
  change (hot config reload without restart).
* The HTTP API (`base/api`) exposes `/1/summary`, `/2/summary`, `/2/backends`,
  JSON-RPC (`pause`, `resume`, `stop`) and can update the config at runtime.

MoneroOcean specific keys (compiled with `WITH_MO_BENCHMARK`, default ON):
`algo-perf` (measured H/s per algorithm, persisted), `bench-algo-time`
(seconds per calibration round, default 10), `algo-min-time` (minimum seconds
between pool-triggered algo switches, sent at login), `rebench-algo` (force a new
calibration on next start, `--rebench-algo`).

At login the miner advertises the enabled algorithm list, the measured
`algo-perf` map and `algo-min-time`; the pool uses them to pick the most
profitable algorithm for the hardware.

---

## 9. This fork's changes

| Area | Change | Where |
|---|---|---|
| Fee | C++ engine: donation strategy deleted, levels forced to 0, no dev wallet/host in the tree. Zig engine: 3 % of Monero time, printed and switchable off | `donate.h`, `net/Network.*`, `base/net/stratum/Pools.*`, `CMakeLists.txt`, `zmrig/src/fee.zig` |
| Build | `-march=native`, `-fno-plt`, alignment, optional LTO/PGO (LTO off by default: it breaks CryptoNight) | `cmake/tuning.cmake`, `CMakeLists.txt` |
| Defaults | huge pages keep JIT code, no `yield`, scratchpad memory pool, 1 GiB page auto-detection | `backend/cpu/CpuConfig.h`, `crypto/rx/RxConfig.*`, `crypto/common/VirtualMemory_unix.cpp` |
| Linux | `--cpu-priority` actually applies `setpriority()` for the process | `base/kernel/Platform_unix.cpp` |
| Logging | stdout redirected to a file no longer produces an empty log | `base/io/log/backends/ConsoleLog.*` |
| Ops | `tune-linux.sh`, `build-optimized.sh`, `bench.sh`, `verify-fee.sh`, `verify-fee-free.sh` | `scripts/` |

---

## 10. Where to look for X

| Question | File |
|---|---|
| Why is my hashrate low? | `doc/PERFORMANCE.md`, `crypto/rx/RxMsr.cpp`, `crypto/common/VirtualMemory*` |
| How are threads chosen? | `backend/cpu/platform/HwlocCpuInfo.cpp`, `BasicCpuInfo.cpp`, `backend/cpu/CpuConfig_gen.h` |
| How is a job parsed? | `base/net/stratum/Job.cpp`, `Client::parseJob` |
| Why did the miner pause on a new seed? | `Miner::setJob` → `Rx::init` → `Miner::onDatasetReady` |
| How are shares submitted? | `net/JobResults.cpp`, `base/net/stratum/Client::submit` |
| How does the pool switch algorithms? | `Network::onJob` → `CpuBackend::setJob` → `CpuConfig::get` |
| What does the algo-perf calibration do? | `core/MoBenchmark.cpp` |
| How do I add an algorithm? | `base/crypto/Algorithm.cpp`, `Algorithm.h`, `cn-gpu.cmake` as an example |

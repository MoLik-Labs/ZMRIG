**:warning: Recent version of this page https://xmrig.com/docs/miner/config/cpu.**

# CPU backend

All CPU related settings contains in one `cpu` object in config file, CPU backend allow specify multiple profiles and allow switch between them without restrictions by pool request or config change. Default auto-configuration create reasonable minimum of profiles which cover all supported algorithms.

### Example

Example below demonstrate all primary ideas of flexible profiles configuration:

* `"rx/wow"` Exact match to algorithm `rx/wow`, defined 4 threads without CPU affinity.
* `"cn"` Default failback profile for all `cn/*` algorithms, defined 2 threads with CPU affinity, another failback profiles is `cn-lite`, `cn-heavy` and `rx`.
* `"cn-lite"` Default failback profile for all `cn-lite/*` algorithms, defined 2 double threads with CPU affinity.
* `"cn-pico"` Alternative short object format.
* `"custom-profile"` Custom user defined profile.
* `"*"` Failback profile for all unhandled by other profiles algorithms.
* `"cn/r"` Exact match, alias to profile `custom-profile`.
* `"cn/0"` Exact match, disabled algorithm.

```json
{
    "cpu": {
        "enabled": true,
        "huge-pages": true,
        "hw-aes": null,
        "priority": null,
        "asm": true,
        "rx/wow": [-1, -1, -1, -1],
        "cn": [
            [1, 0],
            [1, 2]
        ],
        "cn-lite": [
            [2, 0],
            [2, 2]
        ],
        "cn-pico": {
            "intensity": 2,
            "threads": 8,
            "affinity": -1
        },
        "custom-profile": [0, 2],
        "*": [-1],
        "cn/r": "custom-profile",
        "cn/0": false
    }
}
```

## Threads definition
Threads can be defined in 3 formats.

#### Array format
```json
[
    [1, 0],
    [1, 2],
    [1, -1],
    [2, -1]
]
```
Each line represent one thread, first element is intensity, this option was known as `low_power_mode`, possible values is range from 1 to 5, second element is CPU affinity, special value `-1` means no affinity.

#### Short array format
```json
[-1, -1, -1, -1]
```
Each number represent one thread and means CPU affinity, this is default format for algorithm with maximum intensity 1, currently it all RandomX variants and cryptonight-gpu.

#### Short object format
```json
{
    "intensity": 2,
    "threads": 8,
    "affinity": -1
}
```
Internal format, but can be user defined.

## RandomX options

#### `init`
Thread count to initialize RandomX dataset. Auto-detect (`-1`) or any number greater than 0 to use that many threads.

#### `init-avx2`
Use AVX2 for dataset initialization. Faster on some CPUs. Auto-detect (`-1`), disabled (`0`), always enabled on CPUs that support AVX2 (`1`).

#### `mode`
RandomX mining mode: `auto`, `fast` (2 GB memory), `light` (256 MB memory).

#### `1gb-pages`
Kept for config compatibility with XMRig, and there is nothing to set: this miner
asks for a 1 GiB mapping **first** whenever huge pages are in use, then the 2 MiB
pool, then anonymous memory with `MADV_HUGEPAGE`, and prints which one won
(`huge pages 2336 MB (explicit, 1 GiB pages)`). It cannot be a flag because it
cannot be granted at runtime: a gigantic pool has to be reserved before the
machine fragments, so it is a kernel parameter and the tool that writes it is
`zmrig-os hugepages 1g N` (`zmrig-os hugepages` shows what is reserved). On a
host with no 1 GiB pool — most virtual machines, including the one this release
was tested on — the fallback to 2 MiB pages is automatic. The published gain on
top of 2 MiB is 1-3 %; it is not measured here for that reason.

#### `msr` (XMRig spelling: `wrmsr`)
[MSR mod](https://xmrig.com/docs/miner/randomx-optimization-guide/msr). `"auto"`
(the default), `true` or `false`; `wrmsr` with a bool still works and means
`true`/`false`. It gives up to 15% speedup depending on your system. `"auto"`
probes the machine first — does this CPU have a preset, does `/dev/cpu/0/msr`
answer — and applies it only when the answer is yes, which is why a config file
can be copied between a laptop and a VPS without lying to either. _(**Note**:
Userspace MSR writes are no longer enabled by default; the flag
`msr.allow_writes=on` must be set for Linux Kernels 5.9 and after.)_

#### `rdmsr`
Restore MSR register values to their original values on exit. Used together with `wrmsr`. Enabled (`true`) or disabled (`false`).

#### `cache_qos`
[Cache QoS](https://xmrig.com/docs/miner/randomx-optimization-guide/qos). Enabled (`true`) or disabled (`false`). It's useful when you can't or don't want to mine on all CPU cores to make mining hashrate more stable.

#### `numa`
NUMA support (better hashrate on multi-CPU servers and Ryzen Threadripper 1xxx/2xxx). Enabled (`true`) or disabled (`false`).

#### `scratchpad_prefetch_mode`
Which instruction to use in RandomX loop to prefetch data from scratchpad. `1` is default and fastest in most cases. Can be off (`0`), `prefetcht0` instruction (`1`), `prefetchnta` instruction (`2`, a bit faster on Coffee Lake and a few other CPUs), `mov` instruction (`3`).

## Shared options

#### `enabled`
Enable (`true`) or disable (`false`) CPU backend, by default `true`.

#### `huge-pages`
Enable (`true`) or disable (`false`) huge pages support, by default `true`.

#### `huge-pages-jit`
Enable (`true`) or disable (`false`) huge pages support for RandomX JIT code, by default `false`. It gives a very small boost on Ryzen CPUs, but hashrate is unstable between launches. Use with caution.

#### `hw-aes`
Force enable (`true`) or disable (`false`) hardware AES support. Default value `null` means miner autodetect this feature. Usually don't need change this option, this option useful for some rare cases when miner can't detect hardware AES, but it available. If you force enable this option, but your hardware not support it, miner will crash.

#### `priority`
Mining threads priority, value from `1` (lowest priority) to `5` (highest possible priority). Default value `null` means miner don't change threads priority at all. Setting priority higher than 2 can make your PC unresponsive.

#### `memory-pool` (since v4.3.0)
Use continuous, persistent memory block for mining threads, useful for preserve huge pages allocation while algorithm switching. Possible values `false` (feature disabled, by default) or `true` or specific count of 2 MB huge pages. It helps to avoid losing huge pages for scratchpads when RandomX dataset is updated and mining threads restart after a 2-3 days of mining.

#### `yield` (since v5.1.1)
Prefer system better system response/stability `true` (default value) or maximum hashrate `false`.

#### `asm`
Enable/configure or disable ASM optimizations. Possible values: `true`, `false`, `"intel"`, `"ryzen"`, `"bulldozer"`.

#### `argon2-impl` (since v3.1.0)
Allow override automatically detected Argon2 implementation, this option added mostly for debug purposes, default value `null` means autodetect. This is used in RandomX dataset initialization and also in some other mining algorithms. Other possible values: `"x86_64"`, `"SSE2"`, `"SSSE3"`, `"XOP"`, `"AVX2"`, `"AVX-512F"`. Manual selection has no safe guards - if your CPU doesn't support required instructions, miner will crash.

#### `astrobwt-max-size`
AstroBWT algorithm: skip hashes with large stage 2 size, default: `550`, min: `400`, max: `1200`. Optimal value depends on your CPU/GPU

#### `astrobwt-avx2`
AstroBWT algorithm: use AVX2 code. It's faster on some CPUs and slower on other

#### `max-threads-hint` (since v4.2.0)
Maximum CPU threads count (in percentage) hint for autoconfig. [CPU_MAX_USAGE.md](CPU_MAX_USAGE.md)

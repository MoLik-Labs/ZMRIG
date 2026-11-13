# zmrig — the Zig miner

`zmrig` is the second frontend of this repository: a complete RandomX miner
written in Zig that statically links the RandomX engine that ships in
`src/crypto/randomx` (the same JIT that the C++ XMRig frontend uses).

It is not a toy port. It does everything a miner has to do on a pool:

* stratum (`stratum+tcp://` and `stratum+ssl://`), login, job/seed rotation,
  keepalive, share submission, failover between pools;
* huge pages for the cache, the dataset and the JIT code;
* one mining thread per VM, CPU pinning, thread priority;
* pipelined hashing (`hash_first`/`hash_next`), the same order XMRig uses;
* XMRig-compatible CLI flags and JSON config;
* live hashrate windows (10 s / 60 s / 15 min), session maximum, share
  counters, dataset and huge-page telemetry;
* `--version`, `--check`, `--self-test[=light]`, `--bench=N`;
* 3% developer fee on the Zig engine — one wallet, printed in `--check`, `--donate-level=0`
  removes it, and `scripts/verify-fee.sh` fails the build if any document disagrees.

## Why Zig and not Rust/Go

RandomX is a memory-hard, JIT-compiled proof of work. 95% of the runtime is
inside the JIT-generated code and the 2 GiB dataset; the frontend only has to
feed it blobs without getting in the way. That was measured, not assumed:

| implementation | hashrate on the validation host (2 vCPU, AVX2/VAES) |
| --- | --- |
| RandomX **JIT** (this engine, both frontends) | **≈ 1090 H/s** |
| RandomX portable interpreter (`RX_ARCH=native -Drandomx_interpreter`) | 178 H/s |
| pure-Rust (`mithril`, interpreter only) | interpreter class |
| pure-Go (`opd-ai/go-randomx`) | interpreter class, and not consensus-correct yet |
| `go-randomx` / `GxMiner` | CGo around libRandomX — i.e. this engine, plus cgo overhead |

A rewrite of RandomX in Rust or Go therefore cannot beat the JIT: it *is* the
interpreter. Reaching JIT speed means shipping the same C++ JIT anyway, so the
interesting question is which language makes the best *host* around it. Zig
wins because it compiles to a static binary with no runtime, has no GC, can
`extern` the C ABI directly, and its `comptime` covers the protocol/constant
work at build time.

See `doc/ALTERNATIVES.md` for the full comparison and the sources.

## Build

```sh
./zmrig/build.sh                 # release build into zmrig/out/zmrig
./zmrig/build.sh --jobs 8        # parallel C++ compile
./zmrig/build.sh --portable      # no -march=native (binary runs anywhere x86-64)
./zmrig/build.sh --no-zig        # only rebuild libxmorx.a (the hash engine)
./zmrig/build.sh --output DIR    # write zmrig + obj/ into DIR
```

Requirements: `g++`, `ar`, and Zig 0.13 (`ZIG=/path/to/zig` or on `PATH`).
`oneclick.sh --engine zmrig` installs Zig automatically from the PyPI wheel
(`pip3 install ziglang==0.13.0`) because it is usually missing on servers.

The C++ side is compiled with the same flags the project uses everywhere
(`-std=c++11 -O3 -DNDEBUG -DXMRIG_FEATURE_ASM -fno-rtti -maes -march=native
-fno-plt`), object files are cached per flag signature, and the Zig frontend is
linked against `libxmorx.a` plus the system `libstdc++`/`libgcc_s` — Zig 0.13
does not resolve `-lstdc++` on a bare Debian install, so the build resolves the
real archive paths with `c++ -print-file-name=`.

## Test

```sh
./zmrig/tests/run.sh             # C API conformance (reference vectors, dataset)
./zmrig/out/zmrig --self-test    # full: vectors + pipelining + 2 GiB dataset match
./zmrig/out/zmrig --self-test=light   # vectors + pipelining only (runs beside a miner)
./zmrig/out/zmrig --bench=100000 -t 2 # offline hashrate, no pool
./zmrig/tests/profile.sh         # where the cycles in a hash go, and what a
                                 # random dataset read costs on this machine
```

`--self-test` prints `PASS`/`FAIL` per check and exits 0 on success; it is what
`oneclick.sh verify` runs.

### Network test suite

Every transport and every failure mode has a test that runs locally, without a
real pool and without a real CDN:

```sh
./zmrig/tests/net.sh                 # the whole matrix, ~10 minutes
./zmrig/tests/net.sh --quick         # short runs, for iterating
./zmrig/tests/net.sh --only ws,wss   # a subset
./zmrig/tests/net.sh --soak          # also the 4 minute soak
```

It starts a fake Stratum pool (`tests/net/pool.py`) and protocol shims
(`tests/net/relay.py`: TLS, WebSocket, WebSocket+TLS, HTTP CONNECT, SOCKS5) and
checks that the miner logs in, mines and submits over each one. Then it plays
the awkward cases: a pool that rejects the login, a pool that goes silent (idle
watchdog), a dead pool with a backup (failover), a hostile pool that floods
malformed JSON and 100 KB lines, a seed change, an algorithm switch to `rx/wow`,
an abrupt TCP reset, and the HTTP API. 19 checks, `PASS`/`FAIL` per line, exit
code 1 on any failure.

The Cloudflare case is tested as it is deployed: the pool URL keeps the public
name (TLS SNI and `Host` header), the edge address is pinned with
`--connect-to`, and the shim asserts that the request really arrived with the
right `Host` and path. `tests/net/cert.sh` makes the throwaway CA the `tls` and
`wss` shims need.

## Run

```sh
zmrig -o pool.example.org:10001 -u <wallet> --rig-id rig1
zmrig -c /etc/zmrig/config.json --no-color
zmrig --check -c /etc/zmrig/config.json   # validate config, do not mine
```

Supported flags mirror XMRig (`-o/-u/-p/-a/-t/-k/--cpu-affinity/--huge-pages/
--no-huge-pages/--huge-pages-jit/--no-jit/--mode=auto|fast|light/--print-time/
--retries/--retry-pause/--priority/--no-color/--verbose/--log-file/--tls/
--background/--http-port`), so an existing `config.json` can be used unchanged.
Flags are order independent: `-u WALLET -o pool` is the same as
`-o pool -u WALLET`, and a wallet given once is used by every pool that does
not carry its own.

A dropped connection is retried in 200 ms; repeated failures back off to
`--retry-pause` so a dead pool is not hammered. `--log-file` receives plain
text (no colour escapes), and `--background` detaches from the terminal.

## Restrictive networks

`zmrig` speaks four transports and can tunnel through two kinds of proxy, which
is what makes it usable on a VPS that only allows 443/tcp or sits behind a CDN:

```sh
zmrig --url wss://relay.example.com/monero/TOKEN -u <wallet>   # WebSocket+TLS
zmrig --url tls://pool.example.org:443 -u <wallet> --tls-ca ca.pem
zmrig -o pool:3333 -u <wallet> --proxy socks5://user:pass@10.0.0.5:1080
zmrig -o pool:3333 -u <wallet> --proxy http://user:pass@10.0.0.5:3128
zmrig --cloudflare=relay.example.com --ws-path /monero/TOKEN -u <wallet>
```

`--connect-to HOST:PORT` keeps the pool name for TLS SNI and the HTTP `Host`
header while dialling another address, `--tls-ca FILE` pins a private CA,
`--idle-timeout` and `--keepalive-interval` control how a silent socket is
treated. See [`doc/NETWORK.md`](../doc/NETWORK.md) for the whole picture,
including a Cloudflare Worker that turns any pool into a `wss` endpoint.

## Monitoring API

```sh
zmrig -c /etc/zmrig/config.json --http-port 18080 --http-access-token SECRET
curl -H "Authorization: Bearer SECRET" http://127.0.0.1:18080/1/summary
```

`/1/summary` returns the XMRig-shaped summary every dashboard already parses;
`/2/summary` returns the same data pretty printed (that is what
`oneclick.sh status` reads, so a zmrig install reports live hashrate, huge
pages and accepted shares from the API instead of scraping the log). The API is
read only, binds to `127.0.0.1` by default, and every number it serves comes
from atomics the monitor already publishes — polling it costs nothing.

The installer writes `"http": {"enabled": true, "port": 18080}` into the
config, so `zmrig status` works out of the box.

## Machine report (`--report`)

A report is a one-line code that describes the machine: CPU, threads, algorithm,
hashrate (10 s / 60 s / 15 min / peak), huge pages, shares, uptime, power and the
source of that power reading. It is `ZMRIG1.` + base64url(JSON), roughly 400–500
characters, and it carries no wallet address and no pool token.

```sh
zmrig --report --power 95            # 10 s warm-up + 15 s measurement, print the code
zmrig --report --report-time 30      # measure longer on a noisy host
zmrig ... --report-file /run/zmrig.report --report-interval 60   # keep a file fresh
```

`--power W` is wall power. Without it the miner samples RAPL
(`/sys/class/powercap/intel-rapl:0/energy_uj`) or an hwmon energy counter once,
30 s into the session — sampling at startup would report idle power — and
records the source in the payload (`pwsrc`: `rapl`, `hwmon`, `user` or `none`).

The installer enables the report file for the `zmrig` engine, so after an
install `cat /var/lib/zmrig/report.txt` gives a code to paste into the
dashboard in `web/` (`zmrig --report` also works with no pool configured).

Power sampling is what makes the code useful: the web calculator turns
hashrate + watts + electricity price into cost per day, profit per day and
break-even price per kWh, for one machine or a whole fleet.

## Measured performance

Validation host: 2 vCPU Xeon VM (AES, AVX2, AVX-512, VAES, SHA-NI), 3.9 GiB RAM,
1234 reserved 2 MiB huge pages, `-march=native`.

| run | result |
| --- | --- |
| `--bench=100000 -t 2` | 100001 hashes in 91–94 s = **1.083–1.098 kH/s** (3 runs, ~2% spread) |
| C++ frontend, `scripts/bench.sh --hashes 250K --seconds 45` | 1075.7 H/s |
| installed service (`oneclick.sh install --engine zmrig`) | 1084–1089 H/s steady state |
| dataset init | 15.2 s (huge pages, 2 threads) |
| memory | cache 256 MB + dataset 2080 MB, 2336 MB of it in huge pages |

The frontend adds nothing measurable over the C++ one: the hash loop and the
dataset are the same code, so the remaining difference between runs is noise.

## Known limits

* RandomX family only (`rx/0`, `rx/2`, `rx/wow`, `rx/arq`, `rx/graft`, `rx/sfx`,
  `rx/yada`, `panthera`); the engine has an `rx/xla` code path but the miner
  does not implement the MoneroOcean v2 commitment yet.
* `--tls-insecure` is not implemented: Zig 0.13's TLS client has no
  "do not verify" switch. TLS with a valid chain works, and `--tls-ca` covers
  private CAs and pinned relays.
* `--nicehash` is accepted so an existing command line keeps working, but the
  NiceHash nonce convention is not implemented: every job is hashed with the
  blob the pool sent and the nonce at its standard offset.
* The CPU backend is the only backend. GPU mining of RandomX is not a thing
  (RandomX was designed to be CPU-only), and CUDA/PTX work would be dead code.
* Linux/x86-64 is the tested platform; the engine itself also builds for ARM64.

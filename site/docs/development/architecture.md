---
title: Architecture
description: The three engines, the Zig miner's module map, how a job travels from a pool to the CPU and back, and which threads exist at runtime.
image: https://molik-labs.github.io/ZMRIG/img/og-en.png
---

# Architecture

This tree ships three interchangeable mining engines behind one installer, one
config file and one HTTP API:

| Engine | Path | Language | Why it exists |
| --- | --- | --- | --- |
| `zmrig` | `zmrig/` | Zig | the default: single binary, no runtime dependencies, same RandomX code |
| `xmrig` | `src/` | C++ | the reference build, GPL-3.0, the widest algorithm and hardware coverage |
| `proxy` | `proxy/` | Node.js | the farm front end; no hashing, only routing |

`/etc/zmrig/engine` records which one the installer chose, so every later
`oneclick.sh` command acts on the same engine without being told again.

## The Zig engine

```text
zmrig/src/
├── main.zig        startup, signals, the mining loop, report writing
├── options.zig     the CLI surface, config-file parsing and validation
├── stratum.zig     login, job parsing, share submission, refusals, cooldown
├── transport.zig   TCP, TLS, WebSocket, SOCKS5/HTTP proxies, DNS
├── job.zig         blob assembly, extranonce handling, target comparison
├── miner.zig       thread pool, nonce spacing, hashrate windows, share accounting
├── api.zig         JSON documents for the HTTP API
├── api_http.zig    the HTTP server itself
├── report.zig      ZMRIG1. report codes
├── health.zig      the watchdog state machine
├── hugepages.zig   reservation and verification of 2 MiB pages
├── topology.zig    core detection, cache sharing, thread placement
├── autotune.zig    picks thread count and affinity for the host
├── verify.zig      share re-hashing for pool operators
├── log.zig         the log format, levels and timestamps
└── util.zig        base64, hex, time, small helpers
```

Nothing is linked beyond libc. There is no allocator in the hash loop, no
background GC, and no dependency that could change behaviour between builds.

## What happens at startup

1. Parse flags, then `config.json`, then the engine marker — in that order, so a
   flag on the command line always wins.
2. Detect the CPU: cores, SMT siblings, L3 size, NUMA nodes.
3. Reserve huge pages; if the reservation fails, log the exact command that would
   fix it and continue rather than refusing to start.
4. Build the RandomX cache (256 MiB) and, in fast mode, the dataset (2 GiB). This
   is the 15–25 s startup cost; `light` mode skips the dataset.
5. Start the worker threads with the affinity chosen by `autotune.zig`.
6. Open the stratum connection: DNS, transport, login, first job.
7. Start the HTTP API (default `127.0.0.1:18080`) and, if requested, the report
   file writer.

## The hot path

A job arrives as a 76-byte blob with a target. The miner writes the nonce into
bytes 39–43, hashes, compares the result against the target, and on a hit sends
`submit` upstream. Nothing on that path allocates, and nothing takes a lock: each
thread owns a contiguous slice of the 32-bit nonce space, and its position is
advanced by a stride chosen so two threads never collide.

The scratchpad lives in huge pages for the whole run. That is the difference
between 814 H/s and 634 H/s on the reference machine — see
[Benchmarks](/docs/reference/benchmarks).

## The proxy

`proxy/src/` is a small pipeline: `server.js` accepts rig connections,
`downstream.js` models each rig, `extranonce.js` assigns prefixes,
`vardiff.js` sets difficulty per rig, `target.js` compares hashes, `upstream.js`
holds the single pool connection, `tunnel.js` handles WireGuard/Tailscale/
Cloudflare, and `access.js` enforces CIDR and token rules. `blob.js` is the only
place that knows the layout of a Monero job — read that first.

## The pool

`pool/src/` accepts shares, re-hashes each one with `zmrig --verify-share`, keeps
PPLNS weights as difficulty × time, and writes every block to `audit.jsonl`.
Payouts go out through `monero-wallet-rpc`. `pool/worker/` is a Cloudflare Worker
that bridges WebSocket to TCP so the pool can run on a platform that only speaks
HTTP.

## Where to look for X

| Question | File |
| --- | --- |
| Why did a connection fail? | `zmrig/src/stratum.zig`, `zmrig/src/transport.zig` |
| Why this thread count? | `zmrig/src/autotune.zig`, `zmrig/src/topology.zig` |
| Why is hashrate low? | `zmrig/src/miner.zig`, `zmrig/src/hugepages.zig` |
| What does this API field mean? | `zmrig/src/api.zig` |
| Why did the service restart? | `zmrig/src/health.zig` |
| Why is a rig not being paid? | `pool/src/`, then `audit.jsonl` |
| Why is a rig not submitting? | `proxy/src/vardiff.js`, `proxy/src/target.js` |

The longer C++ map — every directory in `src/`, the thread inventory and the
RandomX pipeline — is in
[`doc/ARCHITECTURE.md`](https://github.com/MoLik-Labs/ZMRIG/blob/master/doc/ARCHITECTURE.md).

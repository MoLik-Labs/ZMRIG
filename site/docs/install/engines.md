---
title: Choosing an engine
description: zmrig (Zig) and xmrig (C++) share the same RandomX engine. The difference is transports, algorithms and what each one can tell you about itself.
image: https://nggkhaiz.github.io/ZMRIG/img/og-en.png
---

# Choosing an engine

Both engines compile to the same hash loop: `zmrig/capi` binds the C++ RandomX
implementation into the Zig binary, so the numbers are the same within noise. The
difference is everything around the loop.

| | `xmrig` (C++) | `zmrig` (Zig) |
| --- | --- | --- |
| Algorithms | all of them (34+) | the RandomX family: `rx/0`, `rx/wow`, `rx/arq`, `rx/graft`, `rx/sfx`, `rx/yada`, `panthera` (`rx/2` parses but no coin uses it and it is not tested) |
| Transports | TCP, TLS | TCP, TLS, `ws`, `wss` |
| Proxy | partial SOCKS5 | HTTP CONNECT and SOCKS5, with auth and remote DNS |
| Monitoring API | yes, complete | yes, read-only, XMRig-compatible shape |
| Report code for the calculator | no | yes (`--report`) |
| Health watchdog | no | yes, restarts when earnings stop |
| Measured `rx/0` | 832 H/s | 800–841 H/s, same host, same config |

Both are measured on the same 2 vCPU machine, `--bench`, 2 MiB pages; the spread
is the host, not the engine. [Benchmarks](/docs/reference/benchmarks) has the
method. Every algorithm above has a reference vector in `zmrig --self-test`, so
the Zig engine's coverage is checked rather than claimed.

## Which one

- **RandomX on a normal VPS:** either. `zmrig` is smaller, has the transport
  options and prints a report code, so it is what the installer picks.
- **A switching pool (MoneroOcean and clones):** `zmrig` still works — it
  advertises the whole RandomX family and the pool moves the rig between coins.
  It cannot mine the non-RandomX algorithms those pools also pay for, so a
  pool that values breadth more than depth is better served by `xmrig`. The
  installer's `auto` setting chooses `xmrig` for a switching pool for this
  reason; `zmrig` remains the 0 %-fee option either way.
- **Any other algorithm (cn/heavy, ghostrider, KawPow):** `xmrig`. `zmrig`
  refuses at argument-parse time rather than starting and failing to connect.
- **A network that only allows 443, or a proxy:** `zmrig`. See
  [Networks that only allow 443](/docs/operate/networks).

## Switching engines

The engine is recorded in `/etc/zmrig/engine`, so later subcommands (`status`,
`logs`, `bench`, …) use the same binary without repeating `--engine`.

```bash
sudo ./oneclick.sh install --wallet 4YourMoneroAddress --engine zmrig --force
sudo ./oneclick.sh install --wallet 4YourMoneroAddress --engine xmrig --force
```

Both binaries can stay installed side by side; the service runs whichever the
marker names.

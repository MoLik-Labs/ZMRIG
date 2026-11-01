# The C++ engine has no fee — what was removed and how to verify it

This page is about `src/`, the XMRig tree: it mines **100 % for the configured
pool and wallet**, with no developer fee, no time slicing, no second stratum
session and no hidden wallet.

The Zig miner (`zmrig/`, the default engine) is a different program and does
take **1 % of Monero mining time** for the developer. That policy, its log
lines, its clock and its off switch are documented in `doc/FEE.md`. The two are
not in conflict: the fee belongs to the Zig front end, and the C++ engine the
installer keeps for non-RandomX algorithms has no donation code at all.

## How the upstream fee works

Upstream XMRig implements the dev donation in `src/net/strategies/DonateStrategy.cpp`:

* `Pools::donateLevel()` returns `donate-level` (default **1**, minimum 1);
* `Network` creates a second strategy, `DonateStrategy`, which every ~100 minutes
  pauses the user's pool and connects to the developer pool for one minute
  (`m_idleTime = (100 - level) * 60 s`, `m_donateTime = level * 60 s`);
* the donation pool receives the hashes; the miner switches back afterwards.

In this MoneroOcean flavoured tree the donation endpoint was
`xmrig.moneroocean.stream:10001/20001` with a hardcoded wallet, and the fee was
silently disabled only when the first configured pool host contained
`moneroocean.stream`. In other words: the fee was paid by everyone who mined
somewhere else.

## What this fork changed

| File | Change |
|---|---|
| `src/donate.h` | `kDefaultDonateLevel = 0`, `kMinimumDonateLevel = 0`; no wallet address in the tree |
| `src/net/strategies/DonateStrategy.{h,cpp}` | **deleted** |
| `CMakeLists.txt` | donation sources removed from the target |
| `src/net/Network.{h,cpp}` | `m_donate` removed; no second strategy, no `dev donate started/finished`, no donation submit path, no donation tick |
| `src/core/Miner.{h,cpp}` | `setJob(job, donate)` → `setJob(job)`; job index is always 0; no "switch back from donation" nonce special case |
| `src/base/net/stratum/Pools.{h,cpp}` | `donateLevel()` is a `constexpr` returning 0; `proxyDonate` plumbing removed; the MoneroOcean "disable fee if pool matches" hack removed |
| `src/base/kernel/config/BaseTransform.cpp` | `--donate-level` / `--donate-over-proxy` are parsed and intentionally ignored |
| `src/core/config/Config_default.h` | `"donate-level": 0`, placeholder pool instead of the donation pool |
| `src/Summary.cpp` | prints `DONATE 0% (fee-free build)` |

`donate-level` and `donate-over-proxy` are still **accepted** so existing
scripts, configs and dashboards keep working. Their values have no effect.

## Why this is also a performance change

With RandomX, a donation round is not just 1 % of the time:

* the developer pool has a different seed → 2 GiB dataset re-initialisation;
* every worker thread is stopped and restarted → VMs and JIT code rebuilt,
  2 MiB scratchpads re-faulted;
* the nonce window is reset and in-flight hashes are lost;
* two extra pool sessions per round (connect, login, job).

That is why removing the fee in this fork returns more than 1 % — typically
2–4 % of real hashrate on RandomX, plus the full 1 % time slice.

## Verify it yourself

```bash
./scripts/verify-fee-free.sh                 # source + binary audit
./scripts/verify-fee-free.sh --source-only   # no binary needed
```

The script checks that:

1. both donation constants are `0`;
2. `DonateStrategy` is gone from the tree and from `CMakeLists.txt`;
3. no wallet address and no donation hostname exists in `src/` (the one address
   the project publishes lives in `doc/DONATE.md` and no code path reads it);
4. `Network` has no donation plumbing;
5. the built binary contains no developer wallet and no donation endpoint;
6. the binary reports `DONATE 0%` even when started with `--donate-level=9`.

Manual checks:

```bash
strings build/xmrig | grep -Ei 'donate\.|moneroocean\.stream|^[48][1-9A-HJ-NP-Za-km-z]{95}$'
# -> nothing

./build/xmrig --dry-run --url pool.example.com:3333 --user TEST --donate-level=9 | grep DONATE
# -> DONATE       0% (fee-free build)

curl -s http://127.0.0.1:PORT/2/summary | jq .miner.donate_level
# -> 0
```

At runtime the log never prints `dev donate started` and the API reports
`"donate_level": 0`.

The distinction that matters: a *published* address that a human may copy is not
a *fee*. The address in [`DONATE.md`](DONATE.md) is documentation — it is absent
from `src/`, `zmrig/`, `pool/` and `oneclick.sh`, so the audit above passes with
it in the tree, and a donation can never be mistaken for a charge.

## Licensing note

XMRig is GPL-3.0. Removing the donation code is an explicit, permitted
modification of the source you received; the copyright headers and the license
stay untouched. Upstream XMRig and this fork are funded differently: upstream
takes a 1 % dev donation inside the miner unless removed, and it publishes its
own address in its README. This fork takes nothing, and publishes one optional
address in [`DONATE.md`](DONATE.md) for people who insist. Neither address is
wired to any code path in this tree.

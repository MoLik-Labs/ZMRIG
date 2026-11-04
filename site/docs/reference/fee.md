---
title: The 3 % fee, in full
description: What the developer fee costs, which coin it applies to, where it is printed, how to change it, and the commands that show it is the only one.
image: https://molik-labs.github.io/ZMRIG/img/og-en.png
---

# The 3 % fee, in full

`zmrig` mines **3 % of its Monero time** for the developer. The other 97 % goes
to the pool and wallet you configured. That is the whole policy:

| | |
| --- | --- |
| Rate | 3 % of Monero (`rx/0`) mining time, `--donate-level=0` to 10 |
| Cadence | 60 s of Monero mining to the developer wallet after every 33 minutes of yours |
| Coin | Monero only. The wallet is a Monero address, so ArQmA, Wownero, Graft, Safex, Yada and Scala time accrues nothing |
| Destination | the pool you already use, with the developer wallet in the login. No second pool, no relay, no hidden endpoint |
| Switch | `--donate-level=0` or `--no-donate` turns it off completely |

Nothing is taken from a share you solved: a pool pays whoever logs in, so the
only way a miner can pay a fee without sitting in the middle of your traffic is
to log in with the other wallet for a while. The clock is debt-based, so a
reconnect does not lose or double the fee:

- every second of Monero hashing adds 30 ms of debt at 3 % (100 ms at 10 %),
- once 60 s is owed, the miner ends the current connection and reconnects on the
  same pool with the developer wallet,
- to avoid a reconnect loop the cadence never exceeds one fee session per
  ~33 minutes at the default rate, and a pool that refuses the developer wallet
  postpones the fee by 2 minutes, then by 30 after three refusals, instead of
  interrupting your mining again.

## Where it is printed

It is not a silently applied setting. Every one of these says the rate and the
address:

```text
ZMRIG 6.36.0 - RandomX miner by @nggkhaiz
3% of Monero mining time goes to the developer (--donate-level=0 turns it off), GPL-3.0, https://github.com/MoLik-Labs/ZMRIG
```

```bash
zmrig ... --check | grep donate
#   donate  3% of Monero (rx/0) mining time to 46SQLW7DXaq6GJaQbHUFMAhd1VYpfQFJQ2gfZo9TCB8bf9vnf1MUwAD2Fwj6KMsY4RU3oKA3x6hByg8BKg7FfMWn6ysb5tJ, 60 s every 33 min (--donate-level=0 turns it off)
```

At runtime, once per session:

```text
developer fee: 60 s owed, reconnecting to pay it
developer fee: login ok, mining job 7f3a… for the developer wallet
developer fee: session paid, back to your wallet
```

And the HTTP API reports `"donate_level": 3` in `/1/summary` and `/2/summary`,
so a dashboard cannot show zero while the miner is paying.

## What the fee is not

- **Not a cut of your shares.** Nothing is submitted twice, nothing is
  re-weighted, the pool never sees a share for a wallet you did not choose
  outside the fee window.
- **Not payable in another coin.** Mining ArQmA to a Monero address would burn
  the coins in a hole nobody can spend; the fee simply does not accrue there.
- **Not a hardcoded pool.** A fee session uses the pool, port, TLS and proxy
  settings of the pool you configured. If that pool does not accept the
  developer wallet, the fee is postponed and your mining is untouched.

## Check it yourself

```bash
./scripts/verify-fee.sh --binary zmrig/out/zmrig
```

The script reads the fee constants, confirms `--check` prints the rate and the
address, confirms `--donate-level=0` prints `off`, and fails if a second
donation host or a second wallet appears in the binary. Each check prints the
line it read, so "it passed" is not the only output.

```bash
zmrig ... --check | grep donate           # the rate and the address
zmrig ... --donate-level=0                # nothing is mined for anyone but you
strings zmrig/out/zmrig | grep -c 46SQLW7D  # exactly one address
```

## The C++ engine in this repo

`src/` is the upstream XMRig tree with every donation line removed, and it still
has no fee at all (`doc/ZERO_FEE.md`, `./scripts/verify-fee-free.sh`). It is kept
for algorithms the Zig engine does not speak and can be selected with
`--engine=xmrig`; the default engine, `zmrig`, is the one that pays the fee. If
you want to support the work, staying on the default engine is what does it.

## Why 3 %

That is what the work costs, and a number that is stated can be argued with.

The fee pays for the parts that do not mine: CI builds and signs every image, the
fleet and this site need a host and somebody to watch it, and the benchmarks
behind these pages take a machine and a day each. At 1 % that is funded by the
author's evenings; at 3 % a rig at 1 kH/s pays about a dollar a month, roughly
the electricity of eight hours — small enough to leave a profitability
calculation intact, large enough to keep the releases rolling.

It is not a corridor. `--donate-level` takes 0 through 10, the installer writes
the value into `config.json` where you can read it, and `scripts/verify-fee.sh`
fails the build if this page and the binary disagree.

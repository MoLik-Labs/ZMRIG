---
title: The 1 % fee, in full
description: What the developer fee costs, which coin it applies to, where it is printed, how to change it, and the commands that show it is the only one.
image: https://nggkhaiz.github.io/ZMRIG/img/og-en.png
---

# The 1 % fee, in full

`zmrig` mines **1 % of its Monero time** for the developer. The other 99 % goes
to the pool and wallet you configured. That is the whole policy:

| | |
| --- | --- |
| Rate | 1 % of Monero (`rx/0`) mining time, `--donate-level=0` to 10 |
| Cadence | 60 s of Monero mining to the developer wallet after every 100 minutes of yours |
| Coin | Monero only. The wallet is a Monero address, so ArQmA, Wownero, Graft, Safex, Yada and Scala time accrues nothing |
| Destination | the pool you already use, with the developer wallet in the login. No second pool, no relay, no hidden endpoint |
| Switch | `--donate-level=0` or `--no-donate` turns it off completely |

Nothing is taken from a share you solved: a pool pays whoever logs in, so the
only way a miner can pay a fee without sitting in the middle of your traffic is
to log in with the other wallet for a while. The clock is debt-based, so a
reconnect does not lose or double the fee:

- every second of Monero hashing adds 10 ms of debt at 1 % (100 ms at 10 %),
- once 60 s is owed, the miner ends the current connection and reconnects on the
  same pool with the developer wallet,
- to avoid a reconnect loop the cadence never exceeds one fee session per
  ~100 minutes at the default rate, and a pool that refuses the developer wallet
  postpones the fee by 2 minutes, then by 30 after three refusals, instead of
  interrupting your mining again.

## Where it is printed

It is not a silently applied setting. Every one of these says the rate and the
address:

```text
ZMRIG 6.34.0 - RandomX miner by @nggkhaiz
1% of Monero mining time goes to the developer (--donate-level=0 turns it off), GPL-3.0, https://github.com/NggKhaiz/ZMRIG
```

```bash
zmrig ... --check | grep donate
#   donate  1% of Monero (rx/0) mining time to 46SQLW7DXaq6GJaQbHUFMAhd1VYpfQFJQ2gfZo9TCB8bf9vnf1MUwAD2Fwj6KMsY4RU3oKA3x6hByg8BKg7FfMWn6ysb5tJ, 60 s every 100 min (--donate-level=0 turns it off)
```

At runtime, once per session:

```text
developer fee: 60 s owed, reconnecting to pay it
developer fee: login ok, mining job 7f3a… for the developer wallet
developer fee: session paid, back to your wallet
```

And the HTTP API reports `"donate_level": 1` in `/1/summary` and `/2/summary`,
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

## Why 1 %

The same rate XMRig charges, for the same reason: it is small enough to be
invisible in a profitability calculation (at 1 kH/s and any 2026 Monero price,
1 % of a month is worth less than the electricity of a single day) and large
enough to fund the pool, the site and the testing that produced the numbers on
these pages. It is time, not money: no invoice, no account, no tracking.

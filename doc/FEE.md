# The developer fee

`zmrig` mines **3 % of its Monero time** for the developer. This page is the whole
policy: what it costs, where it goes, how it is shown, how to change it, and how
to check that the binary does what this page says.

Nothing about it is hidden, and the mechanism that keeps it that way is not a
promise: the rate is one constant in `zmrig/src/fee.zig`, the banner prints it
from that constant, `--check` prints it with the destination address, the amount
is the same in the log, and `scripts/verify-fee.sh` fails CI when the code, the
binary and this page disagree. A fee that cannot be read before the first hash is
not a fee, it is a tax, and this repository does not ship one.

The C++ engine in `src/` is a separate story and still has no fee at all — see
`doc/ZERO_FEE.md`.

## The numbers

| | |
| --- | --- |
| Rate | 3 % of Monero (`rx/0`) mining time; `--donate-level=0` … `10` |
| Cadence | 60 s of Monero mining for the developer after every 33 minutes of yours |
| Coin | Monero only |
| Destination | the pool, port, TLS and proxy you configured, with the developer wallet in the login |
| Switch | `--donate-level=0`, `--no-donate` |
| Default in the appliance | 3 %, in `os.conf` as `DONATE`, printed by `zmrig-os doctor` |

At 1 kH/s that is 108 seconds an hour. It is charged in time because a pool pays
whoever logs in: a miner cannot take a cut out of a share it already solved
without standing in the middle of the connection, which is exactly what this
project avoids.

### What each rate is worth

For a single rig at 1 kH/s earning roughly 0.003 XMR a day at a *$200 XMR price
— an illustration of the arithmetic, not a price forecast:

| `--donate-level` | Time per month | Roughly, per month |
| ---: | ---: | ---: |
| 0 | none | — |
| 1 % | 7 h 12 m | ≈ $0.36 |
| 3 % (default) | 21 h 36 m | ≈ $1.08 |
| 5 % | 36 h | ≈ $1.80 |
| 10 % | 72 h | ≈ $3.60 |

Those are the real costs, stated so nobody has to discover them from a payout
that came up short. A rig owner with a hundred machines can divide by a hundred
and see that the default is either trivial or worth changing — both answers are
in `Changing it` below.

## How it works

`zmrig/src/fee.zig` is the whole implementation, and it is a clock:

- every second of Monero hashing adds `percent / 100` seconds of debt
  (30 ms at 3 %),
- when 60 s is owed the monitor closes the pool socket, the mining loop
  reconnects **on the same pool** with `fee.wallet` in the login and `algo=rx/0`,
- the monitor spends the debt down and ends the session when it reaches zero,
- the mining loop reconnects with your wallet, immediately, with no retry pause.

Failure handling is deliberately quiet: a pool that refuses the developer wallet
postpones the fee by 2 minutes, and after three refusals by 30 minutes. Your own
connection is never marked bad because of a fee attempt, and the debt is capped
at one hour so a week of refusals cannot turn into a two-hour session later.

A fee session costs slightly more than its share of the clock, because the
session itself pays for a reconnect: the hashrate is the same, the shares are the
same, and what is lost is the handful of seconds a job takes to arrive. It is
part of the rate, not on top of it — nothing else in this program talks to a
third party.

## Where it is printed

- the banner (`--help`, a bad option), from the same constant the code uses,
- `--check`, one line: `donate  3% of Monero (rx/0) mining time to 46SQLW7DXaq6GJaQbHUFMAhd1VYpfQFJQ2gfZo9TCB8bf9vnf1MUwAD2Fwj6KMsY4RU3oKA3x6hByg8BKg7FfMWn6ysb5tJ, 60 s every 33 min (--donate-level=0 turns it off)`,
- the log at startup: `developer fee: 3% of Monero (rx/0) mining time, <address>`,
- the log at every session: `developer fee: 60 s owed, reconnecting to pay it`,
  `login ok … for the developer wallet`, `session paid, back to your wallet`,
- the HTTP API: `"donate_level": 3` in `/1/summary` and `/2/summary`,
- `zmrig-os doctor`: the rate the appliance will run with, read from `os.conf`,
- the fleet dashboard and the bot: the rate each rig reports, per rig.

## Changing it

```bash
zmrig ... --donate-level=1      # 1 %
zmrig ... --donate-level=5      # 5 %
zmrig ... --donate-level=0      # off; nothing is mined for anyone but you
zmrig ... --no-donate           # same
```

In a config file: `"donate-level": 3`. On an appliance, one key:

```bash
zmrig-os setup --donate 1       # or 0, or 5, or anything up to 10
```

The installer writes the value explicitly, so it is visible in `config.json`
rather than implied, and `zmrig-os doctor` prints what the rig will actually run.

## Checking it

```bash
./scripts/verify-fee.sh --binary zmrig/out/zmrig
```

Seven checks, each printing the line it read:

1. `default_percent` in the source is the documented 3.
2. The wallet string appears in exactly one source file, `fee.zig`.
3. The clock only accrues on `rx/0` jobs.
4. The binary contains exactly one Monero address, and it is the documented one.
5. No upstream donation host (`donate.v2.xmrig.com`, `xmrig.com/donate`,
   `donate.moneroocean`, `44tLjm…`) in the binary.
6. `--check` prints the rate, the coin, the address and the cadence.
7. `--donate-level=0` and `--no-donate` print `off`, and `--donate-level=11` is
   rejected.

CI runs it on every push (`doc/CI.md`), and `oneclick.sh verify` runs it on the
installed binary.

## Why 3 %

Because that is what the work costs, and because a number that is stated can be
argued with.

The fee pays for the parts that do not mine: every image is built and published
by CI, the fleet and the site run on a free instance that still needs somebody to
maintain it, and the benchmarks in `doc/PERFORMANCE.md` take a machine and a day
each. At 1 % that work is funded by the author's evenings; at 3 % a rig earning
$1.20 a day pays about $1.08 a month, which is roughly the price of the
electricity of eight hours — visible, small, and enough to keep the images signed
and the releases rolling.

The rate is not a corridor: `--donate-level` takes 0 through 10, the appliance
writes it into `os.conf`, and the audit script fails the build if any of these
numbers drift away from each other.

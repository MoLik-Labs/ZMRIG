# The developer fee

`zmrig` mines 1 % of its Monero time for the developer. This page is the whole
policy: what it costs, where it goes, how it is shown, how to change it, and how
to check that the binary does what this page says.

The C++ engine in `src/` is a separate story and still has no fee at all — see
`doc/ZERO_FEE.md`.

## The numbers

| | |
| --- | --- |
| Rate | 1 % of Monero (`rx/0`) mining time; `--donate-level=0` … `10` |
| Cadence | 60 s of Monero mining for the developer after every 100 minutes of yours |
| Coin | Monero only |
| Destination | the pool, port, TLS and proxy you configured, with the developer wallet in the login |
| Switch | `--donate-level=0`, `--no-donate` |

At 1 kH/s that is 36 seconds an hour. It is charged in time because a pool pays
whoever logs in: a miner cannot take 1 % out of a share it already solved without
standing in the middle of the connection, which is exactly what this project
avoids.

## How it works

`zmrig/src/fee.zig` is the whole implementation, and it is a clock:

- every second of Monero hashing adds `percent / 100` seconds of debt
  (10 ms at 1 %),
- when 60 s is owed the monitor closes the pool socket, the mining loop
  reconnects **on the same pool** with `fee.wallet` in the login and `algo=rx/0`,
- the monitor spends the debt down and ends the session when it reaches zero,
- the mining loop reconnects with your wallet, immediately, with no retry pause.

Failure handling is deliberately quiet: a pool that refuses the developer wallet
postpones the fee by 2 minutes, and after three refusals by 30 minutes. Your own
connection is never marked bad because of a fee attempt, and the debt is capped
at one hour so a week of refusals cannot turn into a two-hour session later.

## Where it is printed

- the banner (`--help`, a bad option, `--version` is silent about it),
- `--check`, one line: `donate  1% of Monero (rx/0) mining time to 46SQLW7DXaq6GJaQbHUFMAhd1VYpfQFJQ2gfZo9TCB8bf9vnf1MUwAD2Fwj6KMsY4RU3oKA3x6hByg8BKg7FfMWn6ysb5tJ, 60 s every 100 min (--donate-level=0 turns it off)`,
- the log at startup: `developer fee: 1% of Monero (rx/0) mining time, <address>`,
- the log at every session: `developer fee: 60 s owed, reconnecting to pay it`,
  `login ok … for the developer wallet`, `session paid, back to your wallet`,
- the HTTP API: `"donate_level": 1` in `/1/summary` and `/2/summary`.

## Changing it

```bash
zmrig ... --donate-level=2      # 2 %
zmrig ... --donate-level=0      # off; nothing is mined for anyone but you
zmrig ... --no-donate           # same
```

In a config file: `"donate-level": 1`. The installer writes `1` explicitly, so
the value is visible in `config.json` rather than implied.

## Checking it

```bash
./scripts/verify-fee.sh --binary zmrig/out/zmrig
```

Seven checks, each printing the line it read:

1. `default_percent` in the source is the documented 1.
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

## Why 1 %

The same rate XMRig charges, for the same reason: small enough to disappear in a
profitability calculation, large enough to fund the pool, the site and the
benchmarks that produced the numbers in `doc/PERFORMANCE.md`. It is time, not
money — no account, no invoice, no tracking.

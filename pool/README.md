# zmrig-pool

A Monero (RandomX) mining pool in about 5 000 lines of dependency-free
JavaScript, part of [ZMRIG](https://github.com/MoLik-Labs/ZMRIG) by
[@nggkhaiz](https://github.com/NggKhaiz).

It speaks classic stratum over TCP and stratum over WebSocket, which
is what makes it usable from the many VPS providers that only allow outbound
443. Every share is re-hashed by the pool before it is paid, and every block is
written to an append-only audit log.

It is small enough to read in an afternoon and it runs on a 1 vCPU box next to
`monerod`.

```
miner ──stratum/tcp:3333──────────────┐
      ──wss://…/stratum ─→ pool ──────┼── monerod (JSON-RPC)
                          │           └── monero-wallet-rpc (payouts)
                          ├── ledger  (PPLNS, BigInt piconero)
                          ├── verifier (zmrig --verify-share)
                          └── http:8080 (status page, JSON API, /metrics)
```

## The fee, in one table

| What                 | Value                                                  |
| -------------------- | ------------------------------------------------------ |
| Pool fee             | **1.0 %**, taken from each block reward, rounded *down* |
| Hidden fees          | none                                                   |
| Where it goes        | published at `/api/config` and on the status page       |
| Miner-side dev fee   | 3 % of Monero time on `zmrig` (`--donate-level=0` turns it off) |
| Payout threshold     | 0.01 XMR, paid in the network fee                       |

The fee is deducted from the block reward before the PPLNS split, never from a
miner's balance afterwards. If a block reward does not divide evenly, the
leftover piconero is listed as `dust` in the audit record instead of being
quietly added to the fee.

Why 1 %: it is in line with the established Monero pools (0.6 – 1 %), and it has
to cover the one thing those pools do not do — re-hashing every submitted share
on the operator's CPU. A pool that skips verification can afford 0.6 %; a pool
that pays for work nobody did is not cheaper, it is just subsidised by its
honest miners.

## Requirements

* **Node.js ≥ 18.17** — no `npm install`, there are no dependencies.
* **A Monero node** (`monerod`) with JSON-RPC reachable, ideally on the same
  machine or the same private network.
* **`zmrig` on `PATH`** for share verification (`verify_shares: true`). Build it
  from this repository:

  ```bash
  ZIG=/path/to/zig ./zmrig/build.sh --jobs 2
  sudo install -m 0755 zmrig/out/zmrig /usr/local/bin/zmrig
  ```

  Without it, the pool logs `cannot start the verifier` and drops shares rather
  than trusting them. Set `"verify_shares": false` only on a private test pool.

## Five-minute start

```bash
# 1. a node you own (testnet is fine while you set things up)
monerod --data-dir ~/.bitmonero --rpc-bind-ip 127.0.0.1 --confirm-external-bind

# 2. the pool
cd pool
node src/index.js --check --config config.json     # validates and exits
node src/index.js --config config.json            # serves stratum + HTTP

# 3. a miner, in another terminal
zmrig -o 127.0.0.1:3333 -u YOUR_MONERO_ADDRESS.rig1 -t 4
```

Open `http://127.0.0.1:8080/` for the status page. `curl -s
127.0.0.1:8080/api/stats | jq` gives the same numbers as JSON.

## Configuration

`config.json` is read first; environment variables win over it, which is how you
inject settings on a host that only gives you a dashboard. `config.example.json`
is the annotated starting point.

| Key | Default | Meaning |
| --- | --- | --- |
| `fee_percent` | `1.0` | Published fee, 0 – 10. |
| `operator_address` | built-in | Where the fee goes. Empty means the built-in address in `src/operator.js`. |
| `port` | `3333` | Stratum over TCP. Set equal to `http_port` to disable TCP entirely. |
| `http_port` | `8080` | Status page, JSON API, `/metrics`, WebSocket stratum. |
| `ws_path` | `/stratum` | WebSocket endpoint, e.g. `wss://pool.example/stratum`. |
| `daemon` | `http://127.0.0.1:18081` | `monerod` JSON-RPC. |
| `mode` | `monerod` | `synthetic` generates deterministic test jobs with no daemon. |
| `initial_difficulty` | `2000` | First difficulty a new miner gets. |
| `target_share_seconds` | `15` | Vardiff target. |
| `min_difficulty` / `max_difficulty` | `100` / `4e6` | Vardiff clamp. |
| `verify_shares` | `true` | Re-hash every share with `zmrig --verify-share`. |
| `pplns_window` | `3600` | Seconds of shares that split a block. |
| `payout_min` | `0.010000000000` | Minimum balance before a payout. |
| `payout_mode` | `ledger` | `ledger` records balances, `wallet` really pays. |
| `wallet_rpc` | `http://127.0.0.1:18083` | `monero-wallet-rpc` for `wallet` mode. |
| `reserve` | `0.05` | XMR kept in the hot wallet for network fees. |
| `state_file` / `audit_file` | `./data/…` | Ledger state and append-only audit log. |

Environment names are the upper-case equivalents: `POOL_FEE_PERCENT`,
`OPERATOR_ADDRESS`, `PORT`, `HTTP_PORT`, `DAEMON`, `POOL_MODE`,
`VERIFY_SHARES`, `PPLNS_WINDOW`, `PAYOUT_MODE`, `WALLET_RPC`,
`INITIAL_DIFFICULTY`, `VARDIFF`, `STATE_FILE`, `AUDIT_FILE`, `LOG_LEVEL`, and
the rest of the table above.

`--check` prints the effective configuration and exits non-zero on anything that
would let the pool take a fee it cannot justify (fee out of range, unknown mode,
a PPLNS window so short that payouts are a lottery, a non-Monero operator
address in `wallet` mode).

## Shares, PPLNS and the audit log

* A share is accepted only if the pool's own `zmrig --verify-share` produces the
  same hash the miner submitted. A wrong hash is not just rejected: the
  connection is closed, because there is no legitimate reason to send one.
* Share weight is *difficulty × time*, not share count, so a miner on a slow
  connection is not punished and a miner splitting work across rigs is not
  rewarded twice.
* When a block is found, the reward is split over the last `pplns_window`
  seconds of shares. The fee is taken first, rounded down; every miner payment
  and the dust are written to `audit.jsonl`:

  ```json
  {"event":"block","height":3456789,"hash":"…","reward":"600000000000",
   "fee":"6000000000","dust":"0","distributed":[{"address":"4…","atomic":"…","weight":"…"}]}
  ```

`GET /api/audit?limit=20` returns the same records, newest first.

### Verifying shares

`zmrig --verify-share` is a line protocol: one JSON object in, one out, and
**its log goes to stderr** — `stdout` belongs to the protocol. The pool keeps one
verifier per core alive and re-uses it, so the 256 MB RandomX cache is built
once per round rather than once per share. Measured on 2 vCPU with two
verifiers: the first share costs 530 ms (cache build) and the next 200 run at
**103 shares per second**. A rig at 1 kH/s on difficulty 300 submits about one
share every 0.3 s, so the verifier is idle at the scale this pool is for.

Shares queued behind a busy verifier are dispatched as each one frees, not when
the next share happens to arrive; a share that cannot be verified within
`verify_timeout` is dropped with `verification unavailable` rather than accepted
on trust.

### What the WebSocket transport refuses

The pool's `/stratum` endpoint is the one that faces the internet through a
CDN, so its framing is bounded on purpose:

* a frame over 1 MiB closes the connection, before anything is allocated for it;
* a *message* over 256 KiB closes it too, and that is the bound that matters.
  RFC 6455 lets a client open a 1 MiB frame with FIN clear and then send
  continuation frames for ever; a per-frame limit alone leaves the assembler
  growing by a megabyte per frame from a single socket;
* a second data frame arriving while a message is still open is a protocol
  error. Half a login parsed as a message is worse than a closed connection.

Stratum messages are under a kilobyte, plus a few for a job list; the caps are
two orders of magnitude above anything a miner sends.

### Forty rigs, one wallet

A miner logs in as `wallet.rig` or `wallet/rig`, and the wallet is the account:
the rig is a label on it, never a second bucket. Every machine pointed at the same
address shares one PPLNS weight and one balance, and a block pays that address
once. Two buckets for one wallet would be paid twice out of the same window, and
neither would reach the payout minimum on its own.

```bash
curl -s localhost:8080/api/worker/4... | jq '{pending, hashrate, rigCount, rigs}'
```

```json
{"pending":"125000000000","hashrate":4821.5,"rigCount":3,
 "rigs":[{"name":"rack-1","shares":41,"hashrate":3120.2,"lastSeen":1762300000},
         {"name":"rack-2","shares":18,"hashrate":1201.3,"lastSeen":1762300000},
         {"name":"rack-3","shares":0,"hashrate":0,"lastSeen":1762200000}]}
```

The wallet's rate is the sum of its rigs, and each rig's rate comes from the same
share records the payout does, so the two numbers cannot disagree. A rig that
went quiet is still listed with a zero rate: that is the machine to look at. The
per-wallet rig map is capped (64 names by default, least recently seen evicted
first), because a rig name is free text from a public connection.

## Payouts

`ledger` mode (default) computes what everyone is owed and sends nothing — the
right choice while you test, and still auditable. Switch to `wallet` mode once
`monero-wallet-rpc` holds the block rewards:

```bash
monero-wallet-rpc --rpc-bind-port 18083 --disable-rpc-login \
  --wallet-file pool-wallet --password-file wallet.pass
```

Safety rules in `src/wallet.js`: one transfer per address per round, largest
first; never more than the ledger says is pending; stop the round on the first
RPC error instead of leaving a half-paid state; keep `reserve` in the hot wallet
so the pool can always pay the network fee.

## Running it for free

The pool is a single process with no database and no build step, so every free
tier that can hold a long-lived connection works. Check the terms of the host you
pick; free tiers change.

### Render (free web service, WebSocket only)

Render gives you HTTPS/WSS on one port and no raw TCP. That is exactly the case
the WebSocket stratum exists for.

1. Push this repository to your own GitHub account.
2. New → Web Service → Docker, or "Node" with
   * Build command: *(empty)*
   * Start command: `node pool/src/index.js --config pool/config.json`
3. Environment:

   ```
   PORT=8080            # Render's port must be used for both listeners
   HTTP_PORT=8080
   DAEMON=https://your-monerod:18081
   POOL_FEE_PERCENT=1
   ```
4. Miners connect with `zmrig -o wss://your-service.onrender.com/stratum …`.

`render.yaml` in the repository root is a ready blueprint.

Caveat worth knowing: the free instance sleeps after 15 minutes without
traffic, and a sleeping pool earns nothing. For a pool that is meant to be a
business, the $7 instance (or a Fly.io machine) pays for itself with one block.

### Fly.io (raw TCP and WS)

```bash
fly launch --no-deploy --dockerfile deploy/Dockerfile
fly volumes create pool_data --size 1
fly secrets set DAEMON=https://node.example:18081
fly deploy
```

`fly.toml` in the repository root maps `3333/tcp` (stratum), `8080/tcp` (HTTP/WS) and mounts the
volume at `/data` so the ledger survives restarts. `monerod` does not fit in the
free 256 MB machines — point `DAEMON` at a node you run elsewhere.

### Cloudflare Workers (for miners behind a restrictive network)

`pool/worker/` is a stateless WebSocket ⇄ TCP bridge. A miner that can only make
outbound HTTPS connects to `wss://<worker>/stratum`; the Worker opens a TCP
socket from Cloudflare's edge to your pool and copies bytes both ways. No Durable
Object, no storage, so it fits the free Workers plan.

```bash
cd pool/worker
npx wrangler deploy --var POOL_HOST:pool.example.com --var POOL_PORT:3333
```

Then: `zmrig -o wss://zmrig-pool.<account>.workers.dev/stratum -u …`.

### Vercel

Vercel cannot hold a stratum connection: functions are request/response and are
reaped, and there is no raw TCP listener. Host the *status site* there if you
like, and run the pool where a socket can stay open (Render, Fly, a VPS). The
pool's HTTP API is ordinary JSON, so a static page on Vercel can render it.

## HTTP API

| Route | Purpose |
| --- | --- |
| `GET /` | Status page (HTML, no JS required). |
| `GET /healthz` | `{ok, height}`; 503 until a template exists. |
| `GET /api/stats` | Pool counters, ledger totals, published config. |
| `GET /api/config` | Fee, operator address, PPLNS window, payout minimum. |
| `GET /api/audit?limit=20` | Block records: reward, fee, per-miner split, dust. |
| `GET /api/worker/:address` | Balance, hashrate and every rig behind one wallet (`wallet.rig` also works). |
| `GET /metrics` | Prometheus text format. |
| `WS /stratum` | Stratum over WebSocket (`login`, `submit`, `keepalived`, `getjob`). |

Everything is read-only; `POST` and friends get `405`.

## Deployment files

| File | What it does |
| --- | --- |
| `deploy/Dockerfile` | Builds `zmrig`, then a slim runtime: non-root, healthcheck. |
| `../render.yaml` | Render blueprint: Docker, one port, ledger on disk. |
| `../fly.toml` | Fly.io: TCP 3333 + HTTP 8080, volume at `/data`. |
| `worker/` | Cloudflare Worker WS ⇄ TCP bridge (`wrangler deploy`). |

## Tests

```bash
cd pool
npm test          # 28 tests: unit, protocol, and end-to-end with a real miner
```

The end-to-end file starts a real pool, mines with `zmrig` over TCP **and** over
WebSocket, and then submits a forged all-zero hash over TCP to prove it is
rejected and nothing is credited. It skips itself if `zmrig` is not built.

## Operating notes

* **One operator, one address.** There is no account system and no database.
  The ledger is a JSON file plus a BigInt map.
* **Keep `state_file` on a volume.** On Render/Fly that means a disk mount;
  without it a restart forgets who is owed what.
* **`/metrics` is cheap.** Point Prometheus at it, or a 30-second cron and a
  spreadsheet.
* **The audit log is append-only.** Rotate it with `logrotate`, never rewrite it;
  miners check their own numbers against it.
* **A pool with zero miners makes zero money.** The fee is only as good as the
  hashrate behind it, and the miner side of this repository (`zmrig`) is where
  the users come from. That miner takes 3 % of Monero mining time for the
  developer — stated in its banner, in `--check`, and switchable off with
  `--donate-level=0` — and none of that reaches the pool: the pool fee below is
  the operator's, from the block, and the two are unrelated.

## License

GPL-3.0, same as the miner.

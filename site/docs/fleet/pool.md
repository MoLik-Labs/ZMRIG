---
title: Run your own pool
description: A Monero pool in Node.js with no dependencies — the 1 % fee and what it buys, a five-minute local run, free hosting options, and the operating rules.
image: https://molik-labs.github.io/ZMRIG/img/og-en.png
---

# Run your own pool

This repository contains both sides: the miner (`zmrig`, `xmrig`) and a Monero
pool written in Node.js with no dependencies, under `pool/`. Running your own
pool means the pool fee stays with you instead of going to a stranger — and your
miners point at it exactly as they would at any other pool.

## The 1 % fee, and what it buys

| Item | Value |
| --- | --- |
| Pool fee | **1.0 %** of each block, taken before splitting, rounded **down** |
| Hidden fees | none |
| Miner developer fee | 1 % of Monero mining time on the Zig engine (`--donate-level=0` turns it off); the C++ engine takes nothing |
| Payout threshold | 0.01 XMR, plus the network fee |

The fee appears in the `login` reply the miner prints, in `/api/config`, and on
the status page. Why 1 %: large Monero pools sit at 0.6–1 %, and this one does
something most do not — it **re-hashes every share** with
`zmrig --verify-share` before paying for it. That costs the operator real CPU,
and it is the only thing that lets a miner know nobody is being paid for work
they did not do.

## A five-minute local run

```bash
# 1. a Monero node (testnet is fine while setting up)
monerod --data-dir ~/.bitmonero --rpc-bind-ip 127.0.0.1 --confirm-external-bind

# 2. the pool
cd pool
node src/index.js --check --config config.json   # validate the config, then exit
node src/index.js --config config.json           # stratum + HTTP

# 3. a miner, in another terminal
zmrig -o 127.0.0.1:3333 -u 4YourMoneroAddress.rig1 -t 4
```

`http://127.0.0.1:8080/` is the status page; `curl -s 127.0.0.1:8080/api/stats`
returns the same numbers as JSON.

## Requirements

- **Node.js ≥ 18.17** — no `npm install`, no database.
- **`monerod`** with JSON-RPC reachable.
- **`zmrig` in `PATH`** so shares can be re-hashed. Without it the pool refuses
  shares rather than trusting them blindly:

  ```bash
  ./zmrig/build.sh --jobs 2
  sudo install -m 0755 zmrig/out/zmrig /usr/local/bin/zmrig
  ```

## Payouts and evidence

- A share is accepted only when the pool's own hash of the blob matches the hash
  the miner sent. A wrong hash is not merely rejected: the connection is closed.
- Share weight is **difficulty × time**, not share count — a slow machine is not
  punished and splitting one rig into three does not pay twice.
- Every block is written to `audit.jsonl`: reward, fee, each miner's payout, and
  the dust remainder listed on its own line instead of quietly folded into the
  fee.

```bash
curl -s 127.0.0.1:8080/api/audit?limit=5 | python3 -m json.tool
curl -s 127.0.0.1:8080/api/worker/4YourMoneroAddress
```

## Free hosting

The blueprint at the root of the repository deploys the fleet — bot, dashboard and
Discord — and not this. A free workspace is allowed **750 instance hours a month**
for all of its services together, and one always-on service already spends about
744 of them; a second one puts the workspace over the limit and Render suspends
the free services until the next month. The pool blueprint therefore lives at
`deploy/render-pool.yaml`: apply it in a different workspace, or in this one if
the bot is not hosted here.

| Where | How | Notes |
| --- | --- | --- |
| Render | `deploy/render-pool.yaml` (Docker) | single port, WebSocket only; a free instance sleeps after 15 minutes idle |
| Fly.io | `fly.toml` + a 1 GB volume | real TCP on 3333; `monerod` does not fit in 256 MB |
| Cloudflare Workers | `pool/worker/` | WebSocket ⇄ TCP bridge, no Durable Object needed |
| Vercel | static page only | a function cannot hold a stratum connection |

```bash
fly launch --no-deploy --copy-config --dockerfile deploy/Dockerfile
fly volumes create pool_data --size 1
fly secrets set DAEMON=https://node.example:18081
fly deploy
```

Point a miner at it over WebSocket (requires the `zmrig` engine), or over TCP when
the host exposes port 3333:

```bash
zmrig -o wss://pool.example.com/stratum -u 4YourMoneroAddress.rig1 -t 4
zmrig -o pool.example.com:3333 -u 4YourMoneroAddress.rig1 -t 4
```

## Operating it

- Keep `state_file` on a volume. Without it, a restart loses every miner's
  balance.
- `/metrics` exports Prometheus; `/healthz` returns 503 until a job template
  arrives from `monerod`.
- The audit log is append-only — rotate it with `logrotate`, never edit it.
- Change the fee wallet with `OPERATOR_ADDRESS`; the default lives in
  `pool/src/operator.js`.
- `--check` refuses configurations that cannot pay correctly: a fee outside
  0–10 %, an unknown mode, a PPLNS window that is too short.

Payouts via `monero-wallet-rpc`, the API and the security notes are in
`pool/README.md`, and the deployment steps you must run yourself are in
[`doc/SETUP.md`](https://github.com/MoLik-Labs/ZMRIG/blob/master/doc/SETUP.md).

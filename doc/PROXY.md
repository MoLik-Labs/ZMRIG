# zmrig-proxy: one address for every rig

Ten rigs in two buildings, one wallet, one pool connection. This is the piece
that makes that sentence work, and it is in `proxy/` — no dependencies, no
binary to build, Node 18+ and 1,900 lines.

```bash
sudo ./proxy/install.sh --user=<wallet> --pool=<host:port>     # service, starts now
```

or, with nothing installed at all:

```bash
sudo apt install -y nodejs                    # 18.17 or newer
node proxy/src/main.js start --user=<wallet> --pool=<host:port>
```

That is the whole install. `install.sh --dry-run` prints the systemd unit and
writes nothing. The rest of this page is what it does, what it
deliberately does not do, and the numbers behind both.

- [1. Why a proxy earns more](#1-why-a-proxy-earns-more)
- [2. Quickstart](#2-quickstart)
- [3. Reaching rigs in another building: one flag](#3-reaching-rigs-in-another-building-one-flag)
- [4. The honest verdict on Cloudflare](#4-the-honest-verdict-on-cloudflare)
- [5. Flags](#5-flags)
- [6. Security model](#6-security-model)
- [7. How difficulty is decided](#7-how-difficulty-is-decided)
- [8. What happens when the pool dies](#8-what-happens-when-the-pool-dies)
- [9. Which pool to point it at](#9-which-pool-to-point-it-at)
- [10. Measured, and not measured](#10-measured-and-not-measured)
- [11. Troubleshooting](#11-troubleshooting)

---

## 1. Why a proxy earns more

There are three ways a farm loses money that have nothing to do with the miner,
and all three are the same bug seen from different angles.

**Duplicate work.** A Monero nonce is 32 bits: a block template plus a nonce
range. If two rigs search the same range, they find the same shares and the pool
credits it once. `xmrig-proxy` solves this by giving each rig its own top nonce
byte (an *extranonce*) and keeping the low 24 bits for the rig. This proxy does
the same, and the reason it is the first module in the directory is
`proxy/src/blob.js`: get the byte order wrong and the failure is invisible —
rigs connected, shares accepted, income down 30 %.

The trap: **prefix 0 is not a prefix.** A blob whose nonce is 0 is exactly the
signal that switches extranonce support *off* in the miner
(`zmrig/src/job.zig:130`, `detectNicehash`). Hand 0 to a rig and it silently goes
back to the shared space. `FIRST_PREFIX = 1` in `proxy/src/blob.js` is that
lesson as code, and `proxy/tests/core.test.js` pins it.

**One difficulty cannot fit every rig.** A 500 H/s box and a 20 kH/s box on the
same target produce one share per hour and one per minute. The pool's vardiff
then chases the average, and the small rig starves: no shares, no credit, full
power draw. The proxy gives each rig its own difficulty (`proxy/src/vardiff.js`)
and each rig reports a share every ~15 s whatever its size.

**Login storms.** A pool sees one login per rig, and a pool behind Cloudflare —
or the free tier of anything — rate-limits logins and bans IPs. One connection
from the proxy replaces all of them, and every rig keeps its own name as a worker
(`--user=wallet.rig3`), so per-rig income is still visible on the pool dashboard.

What the proxy does **not** do: hash. It re-verifies the *target* of every share
(a BigInt comparison, microseconds) and forwards. The pool verifies the hash. A
proxy cannot fake work, and this one does not try.

---

## 2. Quickstart

Local machine, or a LAN where the rigs can see this host:

```bash
node proxy/src/main.js start \
  --user=46SQLW7DXaq6GJaQbHUFMAhd1VYpfQFJQ2gfZo9TCB8bf9vnf1MUwAD2Fwj6KMsY4RU3oKA3x6hByg8BKg7FfMWn6ysb5tJ \
  --pool=gulf.moneroocean.stream:10001
```

The banner prints the exact line to type on a rig:

```
Rigs on this machine or LAN:
  zmrig --pool=stratum+tcp://192.168.1.20:3333 --user=<wallet>.rig1
  xmrig -o 192.168.1.20:3333 -u <wallet>.rig1 -p x
Status: http://127.0.0.1:3334/status
```

Check the pool and the wallet *before* pointing rigs at anything:

```bash
node proxy/src/main.js doctor --user=<wallet> --pool=gulf.moneroocean.stream:10001
```

```
ok   node 18+ -- v22.22.3
ok   wallet given -- 46SQLW7DXa…n6ysb5tJ
ok   pool gulf.moneroocean.stream:10001 answered -- 168 ms
ok   job difficulty -- 60011.2
ok   block height -- 3500123
ok   seed hash present -- 6f1c0a2b9d41…
ok   a 5 kH/s rig would find -- 0.30 shares/hour at this difficulty
```

That last line is the arithmetic an operator usually gets wrong: shares per hour
= `hashrate × 3600 / difficulty`. 0.30/hour is a farm that will wait three hours
per share — fine for a pool with PPLNS and a long window, fatal for one with a
short window or a high minimum payout.

---

## 3. Reaching rigs in another building: one flag

Four options, and they are not interchangeable. Pick one flag; the rest is
handled.

| Flag | What carries the traffic | Fixed address | Third party | Verdict |
|---|---|---|---|---|
| `--tunnel=wireguard` | WireGuard UDP, kernel space | `10.66.66.1` | none | **recommended** |
| `--tunnel=tailscale` | WireGuard via a coordination server | `*.ts.net` | Tailscale | good when no port can be opened |
| `--tunnel=cf` | named Cloudflare tunnel, WebSocket | your hostname | Cloudflare | works; adds an edge hop |
| `--tunnel=cf-quick` | `*.trycloudflare.com`, WebSocket | random, changes | Cloudflare | **demo only** |

### WireGuard: the one to use

```bash
# once, on the proxy host
node proxy/src/main.js tunnel wireguard --rigs=10 --dir=wg
sudo cp wg/ocean-proxy.conf /etc/wireguard/ocean-proxy.conf
sudo systemctl enable --now wg-quick@ocean-proxy

# then normal operation
node proxy/src/main.js start --user=<wallet> --pool=<host:port> --tunnel=wireguard
```

It writes one file per rig (`wg/rig-1.conf` … `wg/rig-10.conf`), each with its own
key and its own address `10.66.66.2 … 10.66.66.11`. Copy one file to one rig —
never the same file to two rigs, which is the WireGuard version of the duplicate
nonce problem.

Why this is the default recommendation:

- **fixed private address**: rigs point at `10.66.66.1:3333` forever, including
  after the ISP changes the public IP;
- **UDP, kernel-space**: adds no measurable latency and no throughput ceiling;
- **no third party**: no account, no terms of service about commercial use, no
  vendor that can rate-limit a farm;
- **one open port**: UDP 51820 on the router. Nothing else needs to be exposed.
  The stratum port itself stays bound to localhost.

Costs, honestly: it is a VPN, so a rig in the wrong peer config can route all its
traffic through the proxy host. The generated configs set
`AllowedIPs = 10.66.66.0/24` (only the proxy network), which avoids that; do not
change it to `0.0.0.0/0` unless you mean it.

### Tailscale: when no port can be opened

```bash
node proxy/src/main.js start --user=<wallet> --pool=<host:port> \
  --tunnel=tailscale --tunnel-token=tskey-auth-...
```

With `--ws` it also runs `tailscale funnel`, which serves TLS on **443, 8443 or
10000 only**, with a bandwidth ceiling Tailscale does not publish. That is fine
for a stratum JSON stream (a few kB/s per rig) and wrong for polling a dashboard
every second. Two further limits worth knowing before committing:

- **Funnel is TLS/HTTP only.** Raw stratum TCP goes over the tailnet, not the
  funnel: rigs must be logged into the same tailnet.
- **The free Personal plan is licensed for non-commercial use.** A farm that
  earns money is outside it; the paid plan is the honest answer.

Without a port to open and without funnel, the plain tailnet path is genuinely
good: rigs reach `<host>.<tailnet>.ts.net:3333` directly, and nothing is exposed
to the internet at all.

---

## 4. The honest verdict on Cloudflare

You asked directly, so: **quick tunnels are not good for a farm.** They are good
for one thing — proving in two minutes that a path through your network works.
Here is why, from Cloudflare's own documentation and from what the thing does:

| Property of `--tunnel=cf-quick` | Consequence for mining |
|---|---|
| Hostname `*.trycloudflare.com` is random and **changes every restart** | every restart means editing the pool line on every rig |
| Tunnel **dies with the process** | no systemd restart, no reboot survival |
| **200 concurrent requests**, then 429 | a farm of 10 rigs is fine, a dashboard refreshing per second is not |
| **No authentication by default** | an open stratum endpoint that pays *your* wallet: anyone can mine on your electricity |
| Indexed tunnels have appeared in search results | your endpoint can be found by strangers |
| Cloudflare states it is **not for production** | there is no SLA to hold anyone to |
| WebSocket only | raw stratum TCP is impossible; it needs `--ws` |

That last row is why `--tunnel=cf-quick` **refuses to start without `--ws`**
(`proxy/src/config.js`) instead of silently serving nothing. And the startup log
prints the warning list above rather than a cheerful URL.

If you want Cloudflare specifically — a stable hostname, an access policy, one
edge — use the named tunnel:

```bash
node proxy/src/main.js start --user=<wallet> --pool=<host:port> \
  --ws --tunnel=cf --tunnel-token=<tunnel-token> --tunnel-host=proxy.example.com
```

Rigs then connect to `wss://proxy.example.com/stratum` via `--pool=wss://...` in
`zmrig` (or `-o wss://...` in xmrig), and the proxy still validates every share
exactly as it does over TCP: the WebSocket path is the same protocol code
(`proxy/src/conn.js` adapts the transport, nothing else changes).

What Cloudflare never gives you: a fixed private IP, a latency advantage, or a
bandwidth guarantee. For a farm, WireGuard wins on all three.

---

## 4b. Which coins the pool may switch the farm to

A pool that pays whatever coin is worth most per hash (MoneroOcean and clones)
can only do that if the miner tells it what it can hash. The proxy is the one
holding the pool connection, so it is the one that has to announce the list —
a rig behind a silent proxy never gets switched, no matter what the rig itself
supports.

Default: `auto`, i.e. the seven RandomX variants the engine has named
configurations for (`src/crypto/rx/RxAlgo.cpp`): `rx/0`, `rx/wow`, `rx/arq`,
`rx/graft`, `rx/sfx`, `rx/yada`, `panthera`.

```bash
--algo=auto          # the whole family (default)
--algo=none          # announce nothing: the pool keeps its own default
--algo=rx/0          # pin the farm to Monero
--algo=rx/0,rx/wow   # an explicit subset
```

Two details that are not cosmetic:

* **the nonce offset moves.** Panthera blobs carry the nonce at byte 147, not 39
  (`zmrig/src/job.zig:88`). Writing the extranonce at 39 for a panthera job
  corrupts the header and every share comes back rejected while the log looks
  fine. `proxy/src/blob.js` (`nonceOffsetFor`) follows the algorithm, and a test
  switches a live fake pool to panthera to prove it.
* **the share carries its coin.** A forwarded share is submitted with the algo of
  the job it was found for; a pool that is mid-switch rejects anything else.

`rx/2` is not advertised: its parameters differ between pool forks, and the cost
of guessing wrong is 100 % rejects. `--algo` is validated at startup, so a typo
is an error rather than a farm that silently mines Monero.

## 5. Flags

Every feature is one flag.

| Flag | Default | What it does |
|---|---|---|
| `--user=<wallet[.worker]>` | first rig's address | wallet the pool pays |
| `--pool=<h:p[,h:p]>` | required | upstream pool; comma-separated list is failover; `tls://` prefix |
| `--bind=<ip>` | `127.0.0.1` | where rigs connect |
| `--port=<n>` | `3333` | stratum port |
| `--tls` `--tls-port=<n>` `--tls-cert=` `--tls-key=` | off / port+2 | `stratum+ssl` listener |
| `--ws` `--ws-port=<n>` `--ws-path=<path>` | off / port+1 / `/stratum` | WebSocket listener |
| `--wss` | off | WebSocket over TLS (same port) |
| `--allow=<cidr,...>` | loopback + RFC1918 | who may connect |
| `--token=<secret>` | none | the stratum *password* every rig must send |
| `--max-rigs=<n>` | 255 | one per extranonce byte |
| `--local-difficulty=<f>` | `1` | local difficulty as a multiple of the pool's |
| `--target-share=<sec>` | `15` | seconds between a rig's shares |
| `--algo=auto\|none\|<name>` | `auto` | which coins the pool may switch the farm to (the RandomX family) |
| `--network-difficulty=<n>` | none | the coin's network difficulty; switches the **XMR/day** column on |
| `--network-url=<url>` | none | fetch that difficulty instead, every `--network-interval` |
| `--network-interval=<sec>` | `600` | how often the URL is re-read (60–21600) |
| `--block-reward=<xmr>` | `0.6` | reward per block (Monero tail emission) |
| `--no-workers` | off | do not report each rig as its own pool worker |
| `--tunnel=<none\|wireguard\|tailscale\|cf\|cf-quick>` | `none` | the public path |
| `--tunnel-token=` `--tunnel-host=` | none | auth key / tunnel token, public hostname |
| `--status-port=<n>` `--status-bind=<ip>` | 3334 / 127.0.0.1 | JSON status |
| `--log-level=<level>` | `info` | `debug`, `info`, `warn`, `error`, `silent` |

Commands: `start` (default), `doctor`, `status`, `tunnel wireguard`.

Environment fallbacks exist for secrets so a unit file need not contain them:
`OCEAN_PROXY_USER`, `OCEAN_PROXY_POOL`, `OCEAN_PROXY_TOKEN`,
`OCEAN_PROXY_TUNNEL_TOKEN`.

---

## 6. Security model

A proxy that pays *your* wallet and listens on the internet is a donation to
whoever finds the port first. Three layers, and the defaults already include the
first:

1. **Bind to localhost.** `127.0.0.1` by default. `--bind=0.0.0.0` is refused
   unless there is a `--token` or an `--allow` list — the check is in
   `proxy/src/config.js` and it prints the reason.
2. **`--allow=<cidr,...>`** — a connection from outside the list is closed before
   a byte of stratum is parsed. Default list: loopback and RFC1918 (10/8,
   172.16/12, 192.168/16, fc00::/7, fe80::/10). Dual-stack sockets report IPv4 as
   `::ffff:a.b.c.d`; that is normalised before matching, not after.
3. **`--token=<secret>`** — the stratum *password*. Every miner already has a
   password field, so this needs no client change and no header a tunnel provider
   might strip. A wrong password is a refusal, one log line, and a closed socket.

Plus a rate limiter (60 connections/minute per IP, burst 20) so a rig stuck in a
reconnect loop cannot become a login storm — the proxy absorbs the storm, fails
over quietly, and the pool never sees it.

The status endpoint is separate, bound to localhost, and requires
`Authorization: Bearer <token>` whenever a token is set. Without a token it
answers only on the loopback interface.

---

## 7. How difficulty is decided

Two numbers, and confusing them is the second invisible bug in this area:

- **upstream difficulty** — what the *pool* asks of the proxy. A share that does
  not clear it cannot be forwarded, whatever the rig believes.
- **local difficulty** — what the proxy asks of *this rig*.

The default keeps them **equal**. Every share the proxy accepts is therefore
forwarded, and the pool's hashrate estimate for the rig is exact. `--local-difficulty`
can move it, bounded to `[upstream/8, upstream×4]`:

- `< 1` accepts more shares locally than the pool will take. Useful on a metered
  3G link, where the point is to notice a dead rig fast and not to fill the
  uplink. The proxy reports those as `absorbed` — accepted, not forwarded, not
  hidden.
- `> 1` forwards a sample instead of everything. Unbiased, but noisier for the
  pool's estimator.

`/status` publishes `forwardRatio`. `0.25` means three of every four shares the
rigs produced were never seen by the pool; that is a number an operator should be
able to see without reading code.

**A bug this found.** While writing `proxy/src/vardiff.js` the pool's
`nextDifficulty()` turned out to have the ratio inverted
(`observed/desired` instead of `desired/observed`), which is the one direction
error that is invisible in a log: a slow rig got *harder* targets until it
submitted nothing at all, and a fast rig drifted to the floor. Measured before
and after, same inputs:

| Input | Old result | New result | Which is right |
|---|---|---|---|
| `nextDifficulty(1000, 60 s, 15 s)` — slow rig | 2000 | **500** | easier for the slow rig |
| `nextDifficulty(1000, 1 s, 15 s)` — fast rig | 500 | **2000** | harder for the fast rig |

The two columns are exactly swapped, which is what an inverted ratio looks like.
`pool/tests/unit.test.js` now pins the direction (`slow < 1000`, `fast > 1000`)
instead of only checking that a number came back.

---

## 7b. What each rig actually earns

`/status` is where a farm's money is visible, so it answers the question an
operator asks next: *how much is this rig producing, and what is that worth?*

A rig never reports a hashrate over stratum, and inventing one from the CPU model
would be a guess. The proxy measures instead. Every accepted share at the
difficulty *this proxy handed out* is proof of `difficulty × 2³²` hashes on
average, so

```
H/s ≈ accepted × difficulty × 2³² / seconds
```

Because the difficulty divisor is the rig's **local** difficulty, a rig on a
lowered `--local-difficulty` (more shares, each worth less) comes out at the same
hashrate as an identical rig on the pool's difficulty. That is the property that
makes the column comparable across a mixed farm.

Money needs two numbers the proxy cannot measure — the network difficulty and the
block reward — so both are inputs, never guesses:

```bash
# exact: the operator supplies the network figure (updated by hand or by a cron)
zmrig-proxy start --user=<wallet> --pool=supportxmr.com:3333 --network-difficulty=3.01e11

# automatic: re-read it every 10 minutes from any JSON endpoint that carries it
zmrig-proxy start --user=<wallet> --pool=supportxmr.com:3333 \
    --network-url=https://xmrchain.net/api/networkinfo
```

```
XMR/day = (H/s / network_difficulty) × (86400 / 120) × block_reward
```

With neither flag set, `/status` still reports `hashrate` and `sharesPerHour` for
every rig and for the fleet, and reports `xmrPerDay: null` — a `null` an operator
can trust, which is worth more than a number they cannot. `estimate` publishes
where any figure came from:

```json
"estimate": { "difficulty": 301000000000, "blockReward": 0.6, "source": "flag", "fetchedAt": null, "error": null }
"hashrate": 814, "sharesPerHour": 1.9, "xmrPerDay": 0.00042,
"connections": [ { "worker": "rig1", "hashrate": 814, "sharesPerHour": 1.9, "xmrPerDay": 0.00042, "accepted": 12 } ]
```

A failed fetch keeps the last good value and logs one line: the network
difficulty moves by fractions of a percent per hour, and a monitoring feature
must never be able to take the pool connection down (`proxy/src/network.js`,
7 tests).

## 8. What happens when the pool dies

The rigs do not notice.

- The upstream connection drops. The **rig sockets stay open** — no reconnect, no
  dataset re-initialisation, no 16-30 s of lost hashrate per rig.
- A rig that logs in during the outage receives the **last job**, which is still
  valid work until the block changes. That is hashrate kept, not politeness.
- Shares that clear the target are acknowledged (the rig did real work) and
  counted as `absorbed` because the pool cannot be reached. The log says so at
  `debug`; `/status` shows the number.
- The pool list rotates. A refused login — bad password, IP ban, wrong pool —
  rotates **immediately** (`Upstream.onLoginError`), because waiting for a socket
  that will never close means standing on a dead pool while every rig idles.
  A dropped connection retries with exponential backoff (5 s doubling to 60 s),
  and a pool that accepted a login and then died is retried at once.

`proxy/tests/plane.test.js` exercises both paths with real sockets: the pool is
killed mid-session and the rig must still be connected, still able to log in, and
still able to submit; then a pool that refuses the login must be left behind for
the next one in the list.

---

## 9. Which pool to point it at

Fees are the smallest part of this decision, and the one people spend the most
time on. At 3 kH/s and roughly \$0.17/XMR-day (~\$62/yr), a 1 % fee is **\$0.62 a
year**. A pool that doubles your variance costs more than that in a month.

For a *proxied* farm — several rigs, one wallet, one connection — the practical
ranking:

| Pool | Fee | Paying for it with | When it is the right choice |
|---|---|---|---|
| **MoneroOcean** `gulf.moneroocean.stream:10001` | 0 % | algo-switching: it points your rigs at whatever pays most at that moment | multi-algo hardware (GPU, mixed fleet); 0.003 XMR minimum payout |
| **SupportXMR** `pool.supportxmr.com:3333` | 0.6 % | the lowest variance in the business, long PPLNS, stable for years | small farm, RandomX only, you want a share every hour, not every three |
| **C3Pool** `c3pool.com:3333` | 0 % | tolerates low hashrate, pays small balances | a rig or two, or a test |
| **P2Pool** via your own `monerod` | 0 % | a 100+ GB node, synced, ~6.7 % of network hashrate, min payout ~0.00027 XMR | you already run a node and can accept the variance of a small pool |

Recommended default in this repo: **MoneroOcean** for a CPU farm that wants the
best expected return, **SupportXMR** when a steady share cadence matters more
than the last percent of expected value. Both work through the proxy unchanged —
the proxy speaks plain stratum, so switching pool is one flag:

```bash
node proxy/src/main.js start --user=<wallet> \
  --pool=pool.supportxmr.com:3333,gulf.moneroocean.stream:10001
```

That list is also the failover: if the first stops answering, the second takes
over without touching a rig.

Do not read the fee column in isolation: the miner's developer fee is 1 % of
Monero time (`doc/FEE.md`) and this proxy takes nothing, which is where the
comparison to `xmrig` + `xmrig-proxy` actually starts — that combination pays
1 % to the miner author and 2 % to the proxy author, and `xmrig-proxy` only
avoids the 2 % if you recompile it with `-DDUST_XMRIG_PROXY_DONATE=0`.

---

## 10. Measured, and not measured

Measured, in this repository, with `node --test proxy/tests/`:

| Suite | Tests | What it proves |
|---|---|---|
| `core.test.js` | 16 | blob nonce byte order, per-algorithm nonce offset, extranonce allocation, vardiff bounds, target parity with the pool |
| `plane.test.js` | 14 | two rigs on one upstream connection, share forwarded with the *pool's* job id, absorbed shares counted, pool death survived, failover, extranonce misuse reported once, a banned pool left alone, a wrong wallet not retried |
| `config.test.js` | 16 | flag parsing and aliases, refused dangerous combinations, CIDR matching, rate limiting, WireGuard config generation, the money flags |
| `network.test.js` | 7 | difficulty shapes from public APIs, H/s from shares, XMR/day maths, a failed fetch keeping the last value, "unknown" staying `null` |
| `e2e.test.js` | 4 | the real binary: TCP rig, WebSocket rig, token gate, status endpoint, `doctor`, SIGTERM leaves no listener behind |
| `layout.test.js` | 3 | every relative `require` resolves, and the *copied* install layout (`/opt/zmrig-proxy/{proxy,pool}`) still runs |
| **total** | **60 passing** | |

Timings from the end-to-end run on a 2 vCPU VM: full start → TCP rig job →
WebSocket rig job → authenticated status read = **213 ms** wall; `doctor`
against a local pool = **83 ms**.

Not measured, and stated so nobody quotes it as if it were: throughput at
10,000 shares/second. The per-share work is a BigInt comparison and a string
write, and the pool's round trip dominates by two orders of magnitude, but this
has not been load-tested. One proxy instance serves 255 rigs by construction
(255 usable extranonce prefixes); more than that is a second instance, which is a
better answer than a longer allocation table.

---

## 11. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `--pool=... is required` | flag typo | the pool flag is mandatory; `--pool=<host>:<port>` |
| rig logs `no job yet` | proxy has not reached a pool | `zmrig-proxy doctor` first; the proxy holds the login 3 s, then says so |
| rig logs `wrong token` | `--token` set, rig password is not it | rig needs `-p <token>` |
| `--bind=0.0.0.0 exposes the proxy` | safety check | add `--token` or `--allow=<cidr>` |
| `--tunnel=cf needs --ws` | Cloudflare carries WebSocket, not raw TCP | add `--ws` |
| pool bans the IP | too many logins from one address | it should not — one login for the whole farm; check `--no-workers` and the failover log |
| rigs connected, income down | duplicate work | look for `overwrote its extranonce` in the log; that rig needs extranonce support (zmrig has it on by default) |
| `forwardRatio` below 1 | `--local-difficulty < 1` | expected in that mode; the `absorbed` counter is the cost |
| status page 401 | token set | `curl -H 'Authorization: Bearer <token>' 127.0.0.1:3334/status` |

Logs are one line per event, no spinner, no colour: `journalctl -u zmrig-proxy -f`
is the intended reader.

# Mining from a restrictive VPS

Some hosts only let outbound traffic to `443/tcp`, terminate long-lived
connections quickly, or sit behind a CDN that refuses arbitrary ports. This
document covers the transport options that make `zmrig` work there, and how to
reach a pool through Cloudflare if you cannot reach it directly.

Everything here is a `zmrig` feature. The C++ engine (`xmrig`) speaks plain TCP
and TLS only, so asking for a WebSocket transport switches the installer to the
Zig engine automatically.

## Quick table

| Your host allows | Use | Flag |
| --- | --- | --- |
| 3333/tcp | plain stratum | `--pool host:3333` |
| 443/tcp only, pool has TLS | TLS stratum | `--pool stratum+ssl://host:443` |
| 443/tcp only, pool has a WebSocket endpoint | `wss` | `--cloudflare=host:443` |
| nothing but an HTTP proxy | `http CONNECT` | `--proxy http://user:pass@proxy:3128` |
| nothing but a SOCKS5 proxy | SOCKS5 (with auth) | `--proxy socks5://user:pass@proxy:1080` |
| only a specific CDN IP is allowed | dial the IP, keep the name | `--connect-to 1.2.3.4:443` |
| a private CA / self-signed pool | pin the CA | `--tls-ca /etc/zmrig/tls-ca.pem` |

## One flag: `--cloudflare`

```sh
sudo ./oneclick.sh install --wallet YOUR_WALLET \
     --pool pool.example.com:443 \
     --cloudflare --ws-path /monero/YOUR_TOKEN \
     --yes
```

`--cloudflare` means:

* the pool URL becomes `wss://<host>:<port>/<ws-path>` (port 443 unless the URL
  in `--pool`, or `--cloudflare=host:port`, says otherwise),
* the connection is a WebSocket inside TLS on 443 - the same shape as normal
  HTTPS traffic, which is what restrictive firewalls and CDNs expect,
* the installer selects `zmrig` (the C++ engine has no WebSocket client),
* `keepalived` is sent every 60 s so middleboxes do not drop an idle socket,
* the config is written with the transport in the pool section, so
  `restart`, `status`, `logs` and `bench` keep working exactly as before.

Run it without installing to see what would be written:

```sh
sudo ./oneclick.sh config --force --wallet ... --pool host:443 --cloudflare --ws-path /monero/TOKEN
sudo ./zmrig/out/zmrig -c /etc/zmrig/config.json --check
```

## How to get a `wss` endpoint

A pool only answers on a WebSocket if it offers one. When it does not, put a
relay in front of it. Two common setups:

### 1. Cloudflare Worker relay (no server of your own)

Cloudflare Workers can open raw TCP sockets and speak WebSocket, which is
exactly the bridge needed: the miner talks `wss://your-worker.workers.dev/relay/<token>`
and the Worker forwards the stratum lines to `pool.example.com:3333`.

```js
import { connect } from "cloudflare:sockets";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const token = url.pathname.split("/").pop();
    if (!env.TOKEN || token !== env.TOKEN) {
      return new Response("forbidden", { status: 403 });
    }
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("websocket only", { status: 426 });
    }

    const [host, port] = (env.POOL || "pool.example.com:3333").split(":");
    const socket = connect({ hostname: host, port: Number(port) });

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    server.accept();

    const writer = socket.writable.getWriter();
    const reader = socket.readable.getReader();
    const encoder = new TextEncoder();
    const decoder = new TextDecoder();

    server.addEventListener("message", (event) => {
      writer.write(encoder.encode(String(event.data).replace(/\r?\n$/, "") + "\n"));
    });
    server.addEventListener("close", () => {
      try { socket.close(); } catch (e) {}
    });

    (async () => {
      let buffer = "";
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        let index;
        while ((index = buffer.indexOf("\n")) >= 0) {
          const line = buffer.slice(0, index).replace(/\r$/, "");
          buffer = buffer.slice(index + 1);
          if (line) server.send(line);
        }
      }
      try { server.close(1000, "pool closed"); } catch (e) {}
    })().catch(() => {});

    return new Response(null, { status: 101, webSocket: client });
  },
};
```

Deploy it, set `POOL` and a long random `TOKEN` in the Worker settings, then:

```sh
sudo ./oneclick.sh install --wallet YOUR_WALLET \
     --pool <your-worker>.workers.dev:443 \
     --cloudflare --ws-path /relay/YOUR_TOKEN --yes
```

Notes:

* Workers have CPU-time and connection limits, and free plans sleep. For a rig
  that mines 24/7 a paid plan or your own relay is more predictable.
* Check the CDN's terms of service for your traffic profile before routing
  mining through it.
* The Worker is a dumb byte relay: it never sees your wallet, and the pool sees
  the Worker's IP, not your VPS's.

### 2. Your own relay (`socat` + `stunnel`, nginx, ...)

Any box that can reach the pool on 3333 and serve TLS on 443 works too. With
`stunnel` the miner connects to `wss://relay.example.com/monero`, and the relay
speaks plain stratum to the pool. On the miner side nothing changes: the same
`--cloudflare` flag.

## Proxies

```sh
# HTTP CONNECT, with basic auth (the installer stores the URL in the config)
sudo ./oneclick.sh install ... --proxy 'http://user:pass@10.0.0.5:3128'

# SOCKS5, including username/password authentication and remote DNS
sudo ./oneclick.sh install ... --proxy 'socks5://user:pass@10.0.0.5:1080'
```

The proxy can also be combined with `--cloudflare`: the tunnel is opened
through the proxy first, then TLS and the WebSocket upgrade run inside it.

## Pinning the TLS certificate source

`zmrig` verifies the server certificate against the system bundle. For a
private CA, or to pin a relay's own certificate:

```sh
sudo ./oneclick.sh install ... --tls-ca /path/to/ca.pem
```

The installer copies the file to `/etc/zmrig/tls-ca.pem` (the unit runs
with a private `/tmp`, so keeping it next to the config matters) and records
that path in the pool section.

## Choosing the exit IP: `--connect-to`

Allowed egress ranges are common. Keep the pool name (for TLS SNI and the HTTP
`Host` header) but dial a specific address:

```sh
sudo ./oneclick.sh install ... --pool pool.example.com:443 \
     --cloudflare --connect-to 203.0.113.10:443
```

## Tuning the socket

```sh
--idle-timeout N        # reconnect when the pool is silent for N seconds (0 = never)
--keepalive-interval N  # keepalived every N seconds of silence (0 = off, default 60)
```

CDNs commonly cut idle WebSockets after ~100 s, so the default keepalive of
60 s is deliberate. `--idle-timeout 0` disables the watchdog for pools that
legitimately go quiet for long stretches.

## Verifying

```sh
sudo ./oneclick.sh verify     # engine conformance + the fee audit
sudo ./oneclick.sh status     # transport, hashrate, shares
sudo journalctl -u zmrig -f
```

A healthy `wss` session logs `connecting to wss://...`, `login ok`, and then
shares. A stale hashrate is never reported: `status` ignores log lines older
than 90 s, so a reconnect loop shows `no data yet` instead of an old number,
and a live one is read from the local API (`127.0.0.1:18080/2/summary`).

### Test the exact path from the machine that has to mine

```sh
./zmrig/tests/net.sh                        # every transport, ~10 minutes
./zmrig/tests/net.sh --only cloudflare,ws   # just the interesting ones
./zmrig/tests/net.sh --soak                 # + 4 min of seed/algo/disconnect
```

The suite starts a fake pool and local shims for `tls`, `ws`, `wss`, HTTP
`CONNECT` and SOCKS5, then asserts that shares are accepted over each of them.
It is the fastest way to tell "this VPS blocks the pool" from "the miner is
broken": if `tcp` passes and `wss` fails, the firewall or the CDN is the
problem, not the engine.

For a real endpoint, the same three commands work with your own pool and a
`--connect-to` edge:

```sh
./zmrig/out/zmrig -o wss://pool.example.com:443/relay/TOKEN -u WALLET \
    --connect-to 203.0.113.10:443 --tls-ca /etc/zmrig/tls-ca.pem \
    --idle-timeout 120 --verbose
```

## Limits

* `zmrig` verifies certificates and does not implement `--tls-insecure`; use
  `--tls-ca` with the pool's CA instead.
* WebSocket framing is client-side only (masked frames, ping/pong, close). The
  relay must speak standard RFC 6455.
* One job per connection: pools that require a fresh login per submit are not
  supported (none of the Monero pools do).

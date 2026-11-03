#!/usr/bin/env node
// zmrig-proxy: one address for every rig, one connection to the pool.
//
//   zmrig-proxy start --user=<wallet> --pool=<host:port>
//   zmrig-proxy start --user=<wallet> --pool=<host:port> --tunnel=wireguard
//   zmrig-proxy doctor --pool=<host:port> --user=<wallet>
//   zmrig-proxy status
//
// The design goal is that the interesting commands fit on one line each and the
// output tells the operator exactly what to type on a rig.

'use strict';

const http = require('node:http');
const path = require('node:path');

const { ConfigError, VERSION, build, lanAddress, missingBinaries } = require('./config');
const { Downstream } = require('./downstream');
const { NetworkFeed } = require('./network');
const { Upstream } = require('./upstream');
const { startServers } = require('./server');
const { generateKeys, publicEndpoint, startTunnel, writeWireguard } = require('./tunnel');
const { parsePool } = require('./upstream');

const LEVELS = { debug: 10, info: 20, warn: 30, error: 40, silent: 100 };

function makeLogger(level = 'info', stream = process.stdout) {
  const threshold = LEVELS[level] ?? LEVELS.info;

  return (severity, message) => {
    if ((LEVELS[severity] ?? LEVELS.info) < threshold) return;

    const stamp = new Date().toISOString().slice(11, 19);
    stream.write(`${stamp} ${severity.toUpperCase().padEnd(5)} ${message}\n`);
  };
}

const HELP = `zmrig-proxy ${VERSION} - ZMRIG proxy by @nggkhaiz
one connection to the pool for every rig

https://github.com/MoLik-Labs/ZMRIG

  zmrig-proxy start [flags]          run the proxy (default command)
  zmrig-proxy doctor [flags]         test the pool, the wallet and the network
  zmrig-proxy status [flags]         read a running proxy's counters
  zmrig-proxy tunnel wireguard [flags]  generate WireGuard configs for the rigs

Required for start:
  --user=<wallet[.worker]>   wallet the pool pays (or let the first rig supply it)
  --pool=<host:port[,host:port]>  upstream pool, comma-separated for failover
                                  tls://host:port for stratum+ssl

Where rigs connect:
  --bind=<ip>                default 127.0.0.1; use 0.0.0.0 or the LAN address
  --port=<n>                 default 3333
  --tls                      also listen with stratum+ssl, on --tls-port (default port+2)
  --tls-cert=<file> --tls-key=<file>   certificate for --tls and --wss
  --ws                       also listen with WebSocket on --ws-port (default port+1)
  --wss                      WebSocket over TLS (same port)
  --ws-path=<path>           default /stratum

Security (off by default because the default bind is localhost):
  --allow=<cidr,...>         addresses allowed to connect; default private ranges
  --token=<secret>           the stratum password every rig must send
  --max-rigs=<n>             default 255 (the extranonce space)

Pool-side income:
  --algo=auto|none|<name[,name]>  which coins the pool may switch this farm to
                                  (default auto: the RandomX family). A pool that
                                  pays the best coin per hash needs this list.

Tuning:
  --local-difficulty=<f>     local difficulty as a multiple of the pool's (default 1:
                             every accepted share is forwarded)
  --target-share=<sec>       seconds between a rig's shares (default 15)
  --no-workers               do not report each rig as its own pool worker
  --log-level=<level>        debug|info|warn|error|silent

What the rigs earn (optional; /status reports hashrate and shares/hour either way):
  --network-difficulty=<n>   the coin's network difficulty; enables XMR/day
  --network-url=<url>        ...or fetch it every --network-interval (default 600 s)
  --block-reward=<xmr>       default 0.6 (Monero tail emission)

Reaching rigs in another building (one flag):
  --tunnel=none              default
  --tunnel=wireguard         fixed 10.66.66.x addresses, UDP, no third party
  --tunnel=tailscale         zero port forwarding; --tunnel-token=<authkey>
  --tunnel=cf                named Cloudflare tunnel; --tunnel-token=<token>
  --tunnel=cf-quick          demo only: random hostname, dies with the process

  --tunnel-token=<secret>    auth key / tunnel token (or OCEAN_PROXY_TUNNEL_TOKEN)
  --tunnel-host=<hostname>   public hostname for --tunnel=cf
  --tunnel-port=<n>          proxy port to expose through the tunnel

Examples:
  sudo zmrig-proxy start --user=46SQLW7D...n6ysb5tJ --pool=gulf.moneroocean.stream:10001 --bind=0.0.0.0
  zmrig-proxy start --user=... --pool=... --tunnel=wireguard
  zmrig-proxy doctor --pool=gulf.moneroocean.stream:10001 --user=...
`;

async function main(argv = process.argv.slice(2)) {
  let parsed;
  try {
    parsed = build(argv);
  } catch (error) {
    if (error instanceof ConfigError) {
      process.stderr.write(`zmrig-proxy: ${error.message}\n\nTry: zmrig-proxy --help\n`);

      return 2;
    }

    throw error;
  }

  const { config, positional } = parsed;
  const command = positional[0] || 'start';

  if (parsed.help) {
    process.stdout.write(HELP);

    return 0;
  }

  if (parsed.version) {
    process.stdout.write(`zmrig-proxy ${VERSION} - ZMRIG by @nggkhaiz\n`);

    return 0;
  }

  const log = makeLogger(config.logLevel);

  switch (command) {
    case 'start':
      return start(config, log);
    case 'doctor':
      return doctor(config, log);
    case 'status':
      return status(config, log);
    case 'tunnel':
      return tunnelCommand(config, positional[1], log);
    default:
      process.stderr.write(`zmrig-proxy: unknown command "${command}"\n\nTry: zmrig-proxy --help\n`);

      return 2;
  }
}

// --- start -----------------------------------------------------------------

async function start(config, log) {
  // A signal that arrives while the listeners are still being created used to
  // kill the process outright: the handlers were installed after
  // `startServers()`, so `systemctl restart` in the first few milliseconds looked
  // like a crash (exit by signal instead of 0). The handler exists first and
  // calls whatever the shutdown step happens to be at the time.
  let stop = async () => {
    process.exit(0);
  };
  const shutdown = () => stop();
  process.once('SIGINT', shutdown);
  process.once('SIGTERM', shutdown);

  const missing = missingBinaries(config);
  if (missing.length) {
    for (const item of missing) process.stderr.write(`--tunnel=${item.tunnel} needs ${item.binary}: ${item.hint}\n`);

    return 1;
  }

  if (!config.user) {
    log('warn', 'no --user: the first rig to connect will set the payout wallet');
  }

  const upstream = new Upstream({
    pools: config.pool,
    user: config.user,
    password: config.password,
    agent: config.agent,
    algos: config.algos,
    keepaliveMs: config.keepAliveMs,
    retryPauseMs: config.retryPauseMs,
    logger: log,
  });

  // Priced only when asked: a proxy that fetches a URL nobody configured is a
  // proxy that fails on an air-gapped network for no reason.
  const network = new NetworkFeed({
    difficulty: config.networkDifficulty,
    url: config.networkUrl,
    intervalMs: config.networkIntervalMs,
    reward: config.blockReward,
    logger: log,
  });
  network.start();

  const downstream = new Downstream({
    upstream,
    user: config.user,
    forwardWorkers: config.forwardWorkers,
    targetShareSeconds: config.targetShare,
    localFactor: config.localFactor,
    token: config.token,
    network,
    logger: log,
  });

  const tunnel = await startTunnel(config, { log });

  const server = await startServers(config, { downstream, logger: log, log });

  for (const line of tunnel.info) log('info', line);

  // The rig commands come before the upstream connection is opened: they are
  // what a person waiting at the terminal needs first, and they do not depend on
  // the pool being reachable.
  banner(config, server.ports, log);

  upstream.start();

  // Difficulty is re-checked on a timer, not on every share: a rig that keeps
  // its target for 30 s produces a stable hashrate reading on the pool.
  const vardiffTimer = setInterval(() => downstream.tick(), 5000);
  vardiffTimer.unref?.();

  const interval = setInterval(() => {
    const snapshot = downstream.status();
    const money = snapshot.xmrPerDay === null ? '' : `, ~${snapshot.xmrPerDay} XMR/day`;
    log('info', `${snapshot.rigs} rigs, ${Math.round(snapshot.hashrate)} H/s${money}, ${snapshot.forwarded} forwarded, ${snapshot.absorbed} absorbed, ${snapshot.rejected} rejected, pool ${snapshot.upstream?.pool || '?'}`);
  }, 60_000);
  interval.unref?.();

  stop = async () => {
    log('info', 'shutting down');
    clearInterval(vardiffTimer);
    clearInterval(interval);
    network.stop();
    downstream.close();
    upstream.close();
    await tunnel.stop();
    await server.close();
    process.exit(0);
  };

  return new Promise(() => {}); // runs until a signal
}

function banner(config, ports, log) {
  const wallet = config.user || '<your-wallet>';
  const token = config.token ? ` --pass=${config.token}` : '';
  const host = config.bind === '0.0.0.0' || config.bind === '::' ? (lanAddress() || '<this-machine-ip>') : config.bind;

  log('info', '');
  log('info', 'Rigs on this machine or LAN:');
  log('info', `  zmrig --pool=stratum+tcp://${host}:${ports.stratum} --user=${wallet}.rig1${token}`);
  log('info', `  xmrig -o ${host}:${ports.stratum} -u ${wallet}.rig1 -p ${config.token || 'x'}`);

  if (ports.stratumTls) {
    log('info', '');
    log('info', 'Miners that want TLS:');
    log('info', `  zmrig --pool=stratum+ssl://${host}:${ports.stratumTls} --user=${wallet}.rig1${token}`);
  }

  if (ports.ws) {
    log('info', '');
    log('info', `${config.wss ? 'WSS' : 'WS'} (Cloudflare, browser, or a reverse proxy):`);
    log('info', `  url: ${config.wss ? 'wss' : 'ws'}://${host}:${ports.ws}${config.wsPath}`);
  }

  if (config.algos.length > 1) {
    log('info', '');
    log('info', `The pool may switch these rigs between ${config.algos.join(', ')}.`);
    log('info', '  A pool that pays the best coin per hash (MoneroOcean) needs that list to do it;');
    log('info', '  pin one coin with --algo=rx/0 if a rig behind this proxy is older than that list.');
  }

  if (config.tunnel === 'wireguard') {
    log('info', '');
    log('info', 'Rigs on WireGuard connect to 10.66.66.1:' + ports.stratum);
  }

  if (ports.status) {
    log('info', '');
    log('info', `Status: http://${config.statusBind}:${ports.status}/status${config.token ? ' (Authorization: Bearer <token>)' : ''}`);
  }

  log('info', '');
}

// --- doctor ----------------------------------------------------------------

async function doctor(config, log) {
  const results = [];
  const add = (ok, label, detail = '') => {
    results.push({ ok, label, detail });
    log(ok ? 'info' : 'warn', `${ok ? 'ok  ' : 'FAIL'} ${label}${detail ? ` -- ${detail}` : ''}`);
  };

  add(Number(process.versions.node.split('.')[0]) >= 18, 'node 18+', process.versions.node);
  add(Boolean(config.user), 'wallet given', config.user ? `${config.user.slice(0, 10)}…${config.user.slice(-6)}` : 'none (the first rig would set it)');

  const first = config.pool[0] || '';
  const { host, port: targetPort } = parsePool(first);

  const started = Date.now();
  const sample = new Upstream({
    pools: [first],
    user: config.user || 'doctor',
    password: config.password,
    agent: `zmrig-proxy-doctor/${VERSION}`,
    retryPauseMs: 60_000,
    logger: () => {},
  });

  const job = await new Promise((resolve) => {
    const timer = setTimeout(() => resolve(null), 15_000);
    sample.once('job', (received) => {
      clearTimeout(timer);
      resolve(received);
    });
    sample.once('fatal', () => {
      clearTimeout(timer);
      resolve(null);
    });
    sample.start();
  });

  const latency = Date.now() - started;
  const { difficultyFromTarget } = require('../../pool/src/target');

  add(Boolean(job), `pool ${host}:${targetPort} answered`, job ? `${latency} ms` : 'no job within 15 s');

  if (job) {
    const difficulty = difficultyFromTarget(job.target);
    add(Number.isFinite(difficulty) && difficulty > 0, 'job difficulty', `${Number(difficulty.toFixed(2))}`);
    add(Boolean(job.height), 'block height', String(job.height ?? '?'));
    add(typeof job.seed_hash === 'string' && job.seed_hash.length === 64, 'seed hash present', `${String(job.seed_hash || '').slice(0, 12)}…`);

    // Share rate arithmetic: a rig produces `hashrate / difficulty` shares per
    // second on average. If that is below one per minute at a plausible
    // hashrate, the pool's difficulty is wrong for the farm size.
    const perHourAt5k = (5000 * 3600) / difficulty;
    add(perHourAt5k > 1, 'a 5 kH/s rig would find', `${perHourAt5k.toFixed(2)} shares/hour at this difficulty`);
  }

  const tunnelBinaries = { wireguard: 'wg', tailscale: 'tailscale', cf: 'cloudflared', 'cf-quick': 'cloudflared' };
  for (const [tunnel, binary] of Object.entries(tunnelBinaries)) {
    const found = hasBinary(binary);
    if (tunnel === 'wireguard' || config.tunnel === tunnel) add(found, `--tunnel=${tunnel} needs ${binary}`, found ? 'installed' : 'not installed');
  }

  sample.close();

  const failed = results.filter((result) => !result.ok).length;
  log(failed ? 'warn' : 'info', `${results.length - failed}/${results.length} checks passed`);

  return failed ? 1 : 0;
}

function hasBinary(name) {
  const { execFileSync } = require('node:child_process');

  try {
    execFileSync(name, name === 'wg' ? ['--version'] : ['version'], { stdio: 'ignore', timeout: 3000 });

    return true;
  } catch (_) {
    return false;
  }
}

// --- status ----------------------------------------------------------------

async function status(config, log) {
  const url = `http://${config.statusBind}:${config.statusPort}/status`;
  const body = await new Promise((resolve) => {
    const request = http.get(url, { headers: config.token ? { authorization: `Bearer ${config.token}` } : {} }, (response) => {
      let text = '';
      response.on('data', (chunk) => { text += chunk; });
      response.on('end', () => resolve(text));
    });
    request.on('error', (error) => resolve(`error: ${error.message}`));
    request.setTimeout(4000, () => { request.destroy(); resolve('error: timeout'); });
  });

  if (body.startsWith('error:')) {
    process.stderr.write(`cannot reach the proxy at ${url} (${body.slice(7).trim()}). Is it running, and is --status-port right?\n`);

    return 1;
  }

  process.stdout.write(`${body.endsWith('\n') ? body : `${body}\n`}`);

  return 0;
}

// --- tunnel wireguard ------------------------------------------------------

async function tunnelCommand(config, kind, log) {
  if (kind !== 'wireguard') {
    process.stderr.write('usage: zmrig-proxy tunnel wireguard --rigs=<n> [--dir=<path>] [--tunnel-port=<endpoint port>]\n');

    return 2;
  }

  if (!hasBinary('wg')) {
    process.stderr.write('WireGuard tools are missing: apt install wireguard-tools\n');

    return 1;
  }

  const count = config.rigs;
  const endpoint = publicEndpoint() || '<this-machine-public-ip>';
  const directory = config.dir ? path.resolve(config.dir) : path.join(process.cwd(), 'wg');
  const keys = generateKeys(count + 1);

  const state = writeWireguard(directory, {
    rigs: count,
    endpoint,
    port: config.tunnelPort || 51820,
    serverKeys: keys[0],
    peerKeys: keys.slice(1),
  });

  log('info', `wrote ${state.serverPath} and ${state.peers.length} rig configs to ${directory}`);
  log('info', 'server address: 10.66.66.1  --  rigs: 10.66.66.2 .. 10.66.66.' + (count + 1));
  log('info', '');
  log('info', 'On this machine:');
  log('info', `  sudo cp ${state.serverPath} /etc/wireguard/ocean-proxy.conf && sudo systemctl enable --now wg-quick@ocean-proxy`);
  log('info', '');
  log('info', 'On each rig (its own file -- never share one):');
  log('info', `  sudo cp rig-1.conf /etc/wireguard/ocean.conf && sudo systemctl enable --now wg-quick@ocean`);
  log('info', '');
  log('info', `Rigs then mine at stratum+tcp://10.66.66.1:${config.tunnelPort || config.port}`);
  log('info', 'Open UDP 51820 on the router/firewall once; nothing else needs a port.');

  return 0;
}

if (require.main === module) {
  main().then((code) => {
    if (typeof code === 'number' && code !== 0) process.exitCode = code;
  }).catch((error) => {
    process.stderr.write(`zmrig-proxy: ${error.stack || error.message}\n`);
    process.exitCode = 1;
  });
}

module.exports = { main, makeLogger };

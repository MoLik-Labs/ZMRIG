// Protocol-level tests: config validation, the WebSocket frame codec, and the
// HTTP surface. No miner needed, so these run everywhere.

'use strict';

const test = require('node:test');
const assert = require('node:assert');
const crypto = require('node:crypto');
const http = require('node:http');
const net = require('node:net');
const path = require('node:path');
const { spawn } = require('node:child_process');

const { loadConfig, validateConfig, DEFAULTS } = require('../src/config');
const ws = require('../src/ws');
const { JobStore } = require('../src/jobs');

const OPERATOR = '46SQLW7DXaq6GJaQbHUFMAhd1VYpfQFJQ2gfZo9TCB8bf9vnf1MUwAD2Fwj6KMsY4RU3oKA3x6hByg8BKg7FfMWn6ysb5tJ';

// --- config ---------------------------------------------------------------

test('a default configuration starts and passes validation', () => {
  const config = loadConfig(null, { payout_mode: 'ledger' });

  assert.deepStrictEqual(validateConfig(config), []);
  assert.strictEqual(config.fee_percent, DEFAULTS.fee_percent);
  assert.strictEqual(config.operator_address, OPERATOR);
  assert.strictEqual(config.tcp_enabled, true);
});

test('a single port means WebSocket only, which is what free hosts give you', () => {
  const config = loadConfig(null, { port: 8080, http_port: 8080 });
  assert.strictEqual(config.tcp_enabled, false);
});

test('config validation refuses settings that would take money for nothing', () => {
  const bad = (overrides) => validateConfig(loadConfig(null, { payout_mode: 'ledger', ...overrides }));

  assert.match(bad({ fee_percent: 11 }).join(), /fee_percent/);
  assert.match(bad({ fee_percent: -1 }).join(), /fee_percent/);
  assert.match(bad({ mode: 'solo' }).join(), /mode must be/);
  assert.match(bad({ payout_mode: 'bank' }).join(), /payout_mode/);
  assert.match(bad({ pplns_window: 10 }).join(), /pplns_window/);
  assert.match(bad({ payout_mode: 'wallet', operator_address: 'not-an-address' }).join(), /operator_address/);
  // With ledger payouts nothing leaves the box, so a placeholder is tolerated.
  assert.deepStrictEqual(bad({ operator_address: 'not-an-address' }), []);
});

test('the pool refuses a fee address no wallet can spend', () => {
  const bad = (overrides) => validateConfig(loadConfig(null, { payout_mode: 'ledger', ...overrides }));
  // One character off, same length, same alphabet: the case a shape check calls
  // valid and a wallet calls "not mine". The fee address never logs in, so
  // nothing else in the pool would ever have noticed.
  const typo = `${OPERATOR.slice(0, -1)}f`;
  assert.notStrictEqual(typo, OPERATOR);

  const ledger = bad({ operator_address: typo }).join();
  assert.match(ledger, /operator_address cannot be paid/);
  assert.match(ledger, /checksum does not match/);
  // Real money moving or not, a typo is a typo: the address is published and
  // people send to it by hand.
  assert.match(bad({ payout_mode: 'wallet', operator_address: typo }).join(), /cannot be paid/);

  // A real address on another chain has a valid checksum and a different
  // network byte, so it is not address-shaped here and stays a shape problem.
  const mainnet = loadConfig(null, { payout_mode: 'ledger' });
  assert.deepStrictEqual(validateConfig(mainnet), []);
});

test('the environment overrides the file, the way a PaaS injects secrets', () => {
  const before = { ...process.env };
  process.env.OPERATOR_ADDRESS = OPERATOR;
  process.env.POOL_FEE_PERCENT = '0.5';
  process.env.PORT = '4444';
  process.env.HTTP_PORT = '8444';
  process.env.VARDIFF = 'false';

  try {
    const config = loadConfig(null);
    assert.strictEqual(config.fee_percent, 0.5);
    assert.strictEqual(config.port, 4444);
    assert.strictEqual(config.http_port, 8444);
    assert.strictEqual(config.vardiff, false);
  } finally {
    for (const key of ['OPERATOR_ADDRESS', 'POOL_FEE_PERCENT', 'PORT', 'HTTP_PORT', 'VARDIFF']) {
      if (before[key] === undefined) delete process.env[key];
      else process.env[key] = before[key];
    }
  }
});

// --- websocket codec ------------------------------------------------------

function maskedFrame(opcode, payload, { fin = true, mask = crypto.randomBytes(4) } = {}) {
  const body = Buffer.from(payload);
  const length = body.length;
  let header;

  if (length < 126) {
    header = Buffer.from([(fin ? 0x80 : 0) | opcode, 0x80 | length]);
  } else if (length < 65536) {
    header = Buffer.alloc(4);
    header[0] = (fin ? 0x80 : 0) | opcode;
    header[1] = 0x80 | 126;
    header.writeUInt16BE(length, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = (fin ? 0x80 : 0) | opcode;
    header[1] = 0x80 | 127;
    header.writeBigUInt64BE(BigInt(length), 2);
  }

  const masked = Buffer.from(body);
  for (let i = 0; i < masked.length; i++) masked[i] ^= mask[i & 3];

  return Buffer.concat([header, mask, masked]);
}

function fakeSocket() {
  const listeners = {};
  return {
    written: [],
    setNoDelay() {},
    on(event, handler) { (listeners[event] ||= []).push(handler); },
    emit(event, value) { for (const handler of listeners[event] || []) handler(value); },
    write(chunk) { this.written.push(Buffer.from(chunk)); },
    end() { this.emit('close'); },
  };
}

test('websocket frames round trip, including a length that needs 16 bits', () => {
  const socket = fakeSocket();
  const connection = new ws.WebSocketConnection(socket, () => {});
  const seen = [];
  connection.on('message', (text) => seen.push(text));

  const short = '{"id":1,"method":"login"}';
  const long = JSON.stringify({ id: 2, pad: 'x'.repeat(400) });

  connection.feed(maskedFrame(0x1, short));
  connection.feed(maskedFrame(0x1, long));

  assert.deepStrictEqual(seen, [short, long]);

  connection.send('hello');
  const out = Buffer.concat(socket.written);
  assert.strictEqual(out[0], 0x81, 'server frames are FIN + text and unmasked');
  assert.strictEqual(out[1], 5);
  assert.strictEqual(out.subarray(2).toString(), 'hello');
});

test('a fragmented message is assembled before it is handed over', () => {
  const connection = new ws.WebSocketConnection(fakeSocket(), () => {});
  const seen = [];
  connection.on('message', (text) => seen.push(text));

  connection.feed(maskedFrame(0x1, '{"id":', { fin: false }));
  connection.feed(maskedFrame(0x0, '3}', { fin: true }));

  assert.deepStrictEqual(seen, ['{"id":3}']);
});

test('a ping is answered with a pong carrying the same payload', () => {
  const socket = fakeSocket();
  const connection = new ws.WebSocketConnection(socket, () => {});

  connection.feed(maskedFrame(0x9, 'keepalive'));

  const reply = Buffer.concat(socket.written);
  assert.strictEqual(reply[0], 0x8a, 'FIN + pong');
  assert.strictEqual(reply.subarray(2).toString(), 'keepalive');
});

test('unmasked frames, oversized frames and close are handled without crashing', () => {
  const closed = [];
  const socket = fakeSocket();
  const connection = new ws.WebSocketConnection(socket, () => {});
  connection.on('close', () => closed.push(true));

  // A client must mask; this is also a cheap way to block tunnelled traffic.
  const unmasked = Buffer.concat([Buffer.from([0x81, 0x02]), Buffer.from('hi')]);
  connection.feed(unmasked);
  assert.strictEqual(closed.length, 1);

  const huge = Buffer.alloc(12);
  huge[0] = 0x81;
  huge[1] = 0x80 | 127;
  huge.writeBigUInt64BE(4n * 1024n * 1024n, 2);
  const second = new ws.WebSocketConnection(fakeSocket(), () => {});
  let secondClosed = false;
  second.on('close', () => { secondClosed = true; });
  second.feed(huge);
  assert.strictEqual(secondClosed, true);
});

test('the accept key matches RFC 6455 for the published example', () => {
  assert.strictEqual(ws.acceptKey('dGhlIHNhbXBsZSBub25jZQ=='), 's3pPLMBiTxaQ9kYGzzhZRbK+xOo=');
});

// --- jobs -----------------------------------------------------------------

test('a job blob carries the height and keeps the nonce field where miners expect it', () => {
  const store = new JobStore({ ttl: 600 });
  const job = store.setTemplate(JobStore.synthetic(1200));

  assert.strictEqual(job.height, 1200);
  assert.strictEqual(job.blob.length, 152);
  assert.strictEqual(job.nonceOffset, 39);
  assert.strictEqual(job.seed.length, 64);
  assert.strictEqual(store.isFresh(job), true);

  // Verified against a real miner: an 8-byte little-endian target and the
  // nonce at byte 39 of the blob.
  const minerJob = store.forMiner(job, 2000);
  assert.strictEqual(Buffer.from(minerJob.target, 'hex').length, 8);
  assert.strictEqual(minerJob.job_id, job.id);
  assert.strictEqual(minerJob.blob, job.blob);
  assert.strictEqual(Buffer.from(minerJob.blob, 'hex').readUInt32LE(39), 0);

  // A job older than its TTL is stale, not a payout.
  assert.strictEqual(store.isFresh(job, job.announcedAt + 601), false);
});

// --- http surface ---------------------------------------------------------

function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.on('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

function request(port, route, options = {}, body = null) {
  return new Promise((resolve, reject) => {
    const req = http.request({
      host: '127.0.0.1',
      port,
      path: route,
      method: options.method || 'GET',
      headers: options.headers || {},
    }, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('end', () => resolve({
        status: response.statusCode,
        headers: response.headers,
        body: Buffer.concat(chunks).toString(),
      }));
    });

    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

test('HTTP endpoints answer and never leak the payout destination by accident', { timeout: 30000 }, async () => {
  const port = await freePort();
  const httpPort = await freePort();

  const child = spawn(process.execPath, [path.join(__dirname, '..', 'src', 'index.js')], {
    env: {
      ...process.env,
      POOL_MODE: 'synthetic',
      PORT: String(port),
      HTTP_PORT: String(httpPort),
      BIND: '127.0.0.1',
      VERIFY_SHARES: 'false',
      VARDIFF: 'false',
      STATE_FILE: path.join(require('node:os').tmpdir(), `pool-http-${process.pid}.json`),
      AUDIT_FILE: path.join(require('node:os').tmpdir(), `pool-http-${process.pid}.jsonl`),
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  let output = '';
  child.stdout.on('data', (chunk) => { output += chunk; });
  child.stderr.on('data', (chunk) => { output += chunk; });

  try {
    const deadline = Date.now() + 10000;
    while (!/pool ready/.test(output) && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    assert.match(output, /pool ready/, `pool did not start:\n${output}`);

    const health = await request(httpPort, '/healthz');
    assert.strictEqual(health.status, 200);
    const healthBody = JSON.parse(health.body);
    assert.strictEqual(healthBody.ok, true);
    assert.ok(Number(healthBody.height) > 0, 'healthz reports the template height');

    const stats = await request(httpPort, '/api/stats');
    assert.strictEqual(stats.status, 200);
    const parsed = JSON.parse(stats.body);
    assert.ok(parsed.pool && parsed.ledger && parsed.config, 'stats carries all three sections');
    assert.strictEqual(parsed.config.mode, 'synthetic');
    assert.strictEqual(parsed.config.fee_percent, 1);
    assert.strictEqual(parsed.pool.feePercent, 1);

    // The status page is a page, not a JSON error.
    const page = await request(httpPort, '/');
    assert.strictEqual(page.status, 200);
    assert.match(page.headers['content-type'], /text\/html/);
    assert.match(page.body, /Ocean Pool/);

    const metrics = await request(httpPort, '/metrics');
    assert.strictEqual(metrics.status, 200);
    assert.match(metrics.headers['content-type'], /text\/plain/);
    assert.match(metrics.body, /^pool_shares_accepted \d+$/m);
    assert.match(metrics.body, /^pool_hashrate [\d.]+$/m);
    assert.match(metrics.body, /^pool_fee_percent /m);

    const audit = await request(httpPort, '/api/audit?limit=5');
    assert.strictEqual(audit.status, 200);
    assert.ok(Array.isArray(JSON.parse(audit.body).blocks));

    // Nobody has mined under this address yet, so it is unknown rather than a
    // zero balance pretending to be a real worker.
    const worker = await request(httpPort, `/api/worker/${OPERATOR}`);
    assert.strictEqual(worker.status, 404);
    assert.match(JSON.parse(worker.body).error, /unknown/);

    const missing = await request(httpPort, '/api/nope');
    assert.strictEqual(missing.status, 404);

    const wrongMethod = await request(httpPort, '/api/stats', { method: 'POST', headers: { 'content-length': 2 } }, '{}');
    assert.strictEqual(wrongMethod.status, 405);
  } finally {
    child.kill('SIGTERM');
    await new Promise((resolve) => {
      child.once('exit', resolve);
      setTimeout(() => { child.kill('SIGKILL'); resolve(); }, 3000).unref();
    });
  }
});

test('a fragmented message cannot grow past the message cap', () => {
  // The frame cap is not a memory bound: RFC 6455 allows one 1 MB frame with
  // FIN clear followed by continuation frames for ever, and before this cap
  // every one of them was kept. One socket, a few seconds, no pool.
  const closed = [];
  const connection = new ws.WebSocketConnection(fakeSocket(), () => {});
  connection.on('close', () => closed.push(true));

  const megabyte = Buffer.alloc(1024 * 1024, 0x41);
  connection.feed(maskedFrame(0x1, megabyte, { fin: false }));
  assert.strictEqual(closed.length, 1, 'the first fragment is already over the cap');

  const second = new ws.WebSocketConnection(fakeSocket(), () => {});
  let secondClosed = false;
  second.on('close', () => { secondClosed = true; });

  // Small fragments, but enough of them: 300 KB in a 100 KB opening frame
  // followed by four 50 KB continuations.
  second.feed(maskedFrame(0x1, Buffer.alloc(100 * 1024, 0x42), { fin: false }));
  for (let i = 0; i < 4 && !secondClosed; i++) {
    second.feed(maskedFrame(0x0, Buffer.alloc(50 * 1024, 0x42), { fin: false }));
  }
  assert.strictEqual(secondClosed, true, 'continuations stop at the cap');
});

test('a second data frame inside an open message is a protocol error', () => {
  const closed = [];
  const connection = new ws.WebSocketConnection(fakeSocket(), () => {});
  connection.on('close', () => closed.push(true));
  connection.on('message', () => { throw new Error('half a message was handed over'); });

  connection.feed(maskedFrame(0x1, '{"id":', { fin: false }));
  connection.feed(maskedFrame(0x1, '3}', { fin: false }));

  assert.strictEqual(closed.length, 1);
});

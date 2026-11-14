// Line framing on the pool side.
//
//   node --test pool/tests/framing.test.js
//
// The pool frames TCP bytes the same way the proxy does, and the same two
// properties matter: any chunking gives the same lines, and the splitter does
// not copy the buffer once per line (it used to, which is quadratic in the
// number of messages in one read - a pool at a hundred rigs sees that every
// time a seed change makes every rig reconnect at once).
//
// Everything here is offline: the pool object is built with stubs, and only the
// byte-to-line path is exercised.

'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { EventEmitter } = require('node:events');

const { StratumPool } = require('../src/stratum');

function makePool() {
  const pool = new StratumPool({
    config: {},
    ledger: {},
    jobs: {},
    verifier: {},
    daemon: {},
    logger: () => {},
  });

  // Record instead of parsing: the framing is what is under test.
  pool.onLine = (conn, line) => {
    if (!conn.seen) conn.seen = [];
    conn.seen.push(line);
  };

  return pool;
}

function conn() {
  return { lineBuffer: '', closed: false, dropped: false, remote: 'rig' };
}

// `drop` is the pool's own, and the real one closes the socket; here it only
// records that it was called.
function watchDrop(pool) {
  const reasons = [];
  pool.drop = (c, reason) => {
    reasons.push(reason);
    c.closed = true;
    c.dropped = true;
  };
  return reasons;
}

test('a message split at every possible byte is reassembled exactly once', () => {
  const pool = makePool();
  const c = conn();
  const message = '{"id":7,"method":"submit","params":{"id":"aa","nonce":"00000001"}}';

  for (let cut = 1; cut < message.length; cut++) {
    c.lineBuffer = '';
    delete c.seen;
    pool.onData(c, Buffer.from(message.slice(0, cut)));
    pool.onData(c, Buffer.from(`${message.slice(cut)}\n`));
    assert.deepEqual(c.seen, [message], `split at ${cut}`);
  }
});

test('several messages in one read keep their order and lose no byte', () => {
  const pool = makePool();
  const c = conn();

  pool.onData(c, Buffer.from('{"a":1}\n{"a":2}\r\n\n{"a":3}\n'));
  assert.deepEqual(c.seen, ['{"a":1}', '{"a":2}', '{"a":3}']);
  assert.equal(c.lineBuffer, '');
});

test('a partial tail survives the read and joins the next one', () => {
  const pool = makePool();
  const c = conn();

  pool.onData(c, Buffer.from('{"a":1}\n{"a":'));
  assert.deepEqual(c.seen, ['{"a":1}']);
  assert.equal(c.lineBuffer, '{"a":');

  pool.onData(c, Buffer.from('2}\n'));
  assert.deepEqual(c.seen, ['{"a":1}', '{"a":2}']);
  assert.equal(c.lineBuffer, '');
});

test('a line over the limit drops the connection instead of parsing it', () => {
  const pool = makePool();
  const c = conn();
  const reasons = watchDrop(pool);

  // MAX_LINE is 16 KiB on the pool; the splitter checks the line, not the read.
  pool.onData(c, Buffer.from(`${'x'.repeat(16 * 1024 + 1)}\n{"a":1}\n`));
  assert.deepEqual(reasons, ['line too long']);
  assert.equal(c.closed, true);
  assert.equal(c.seen, undefined, 'the rest of the read is not delivered');
  assert.equal(c.lineBuffer, '', 'and a dropped connection keeps no buffer');
});

test('a read that is all partial line is buffered, not parsed', () => {
  const pool = makePool();
  const c = conn();

  pool.onData(c, Buffer.from('{"id":1,"method":"lo'));
  assert.equal(c.seen, undefined);
  assert.equal(c.lineBuffer, '{"id":1,"method":"lo');
});

test('a flood without a newline is dropped by the read cap', () => {
  const pool = makePool();
  const c = conn();
  const reasons = watchDrop(pool);

  pool.onData(c, Buffer.alloc(16 * 1024 * 4 + 1, 0x41));
  assert.deepEqual(reasons, ['flood']);
});

test('one read carrying 1000 messages is not quadratic', () => {
  // This is the assertion with teeth. The old loop re-sliced the buffer for
  // every line, so cost grew with lines x buffer size; with a 1000-line read of
  // ~40 KB that is 20 MB of copying per read instead of 40 KB. A budget of
  // 50 ms is generous for 1000 short lines and impossible for the quadratic
  // version on a slow runner.
  const pool = makePool();
  const c = conn();
  const messages = Array.from({ length: 1000 }, (_, i) => `{"id":${i},"method":"keepalived"}`).join('\n') + '\n';

  const started = process.hrtime.bigint();
  pool.onData(c, Buffer.from(messages));
  const ms = Number(process.hrtime.bigint() - started) / 1e6;

  assert.equal(c.seen.length, 1000);
  assert.equal(c.seen[999], '{"id":999,"method":"keepalived"}');
  assert.ok(ms < 50, `1000 messages took ${ms.toFixed(1)} ms`);
});

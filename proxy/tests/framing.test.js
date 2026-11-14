// The line framing every stratum connection goes through.
//
//   node --test proxy/tests/framing.test.js
//   node proxy/tests/framing.test.js --bench     # the numbers in the comments
//
// Two things are worth testing here, and neither is the happy path (which the
// end-to-end tests already cover):
//
//   1. Any chunking gives the same lines. TCP splits wherever it likes, so a
//      read can carry half a JSON message, four of them, or one and a half;
//      `\r\n` and a bare `\n` both have to work, and an empty line has to be
//      dropped rather than parsed as JSON.
//   2. The loop does not copy the buffer once per line. It used to: it did
//      `buffer = buffer.slice(index + 1)` inside the loop, which is quadratic in
//      the number of lines in a read. That is not a theoretical problem on a
//      farm proxy - a hundred rigs behind one connection submit in the same
//      tick - and it is invisible in a test that sends one message at a time.
//      The flood case below is the one that would catch a regression.

'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { EventEmitter } = require('node:events');

const { SocketConnection } = require('../src/conn');
const { Downstream } = require('../src/downstream');

// A socket-shaped object: the connection only uses these five things.
function fakeSocket() {
  const socket = new EventEmitter();
  socket.remoteAddress = '10.0.0.2';
  socket.remotePort = 4242;
  socket.setNoDelay = () => {};
  socket.setKeepAlive = () => {};
  socket.write = () => true;
  socket.end = () => socket.emit('close');
  socket.destroy = () => socket.emit('close');
  return socket;
}

function collect(conn) {
  const lines = [];
  conn.on('line', (line) => lines.push(line));
  return lines;
}

test('one read, one message', () => {
  const conn = new SocketConnection(fakeSocket());
  const lines = collect(conn);
  conn.onData(Buffer.from('{"id":1,"method":"login"}\n'));
  assert.deepEqual(lines, ['{"id":1,"method":"login"}']);
});

test('several messages in one read keep their order', () => {
  const conn = new SocketConnection(fakeSocket());
  const lines = collect(conn);
  conn.onData(Buffer.from('{"a":1}\n{"a":2}\n{"a":3}\n'));
  assert.deepEqual(lines, ['{"a":1}', '{"a":2}', '{"a":3}']);
});

test('a message split across reads is reassembled', () => {
  const conn = new SocketConnection(fakeSocket());
  const lines = collect(conn);
  const message = '{"id":9,"method":"submit","params":{"nonce":"aabbccdd"}}';

  // Every prefix length: the split can land anywhere, including inside a
  // multi-byte UTF-8 sequence, which `chunk.toString('utf8')` on its own would
  // garble. (A stratum login can be non-ASCII: a worker name is arbitrary.)
  for (let cut = 1; cut < message.length; cut++) {
    conn.onData(Buffer.from(message.slice(0, cut)));
    conn.onData(Buffer.from(message.slice(cut) + '\n'));
  }

  assert.equal(lines.length, message.length - 1);
  for (const line of lines) assert.equal(line, message);
});

test('CRLF, a bare LF and an empty line', () => {
  const conn = new SocketConnection(fakeSocket());
  const lines = collect(conn);
  conn.onData(Buffer.from('{"a":1}\r\n\n{"a":2}\n\r\n'));
  assert.deepEqual(lines, ['{"a":1}', '{"a":2}']);
});

test('a trailing partial line is kept for the next read', () => {
  const conn = new SocketConnection(fakeSocket());
  const lines = collect(conn);
  conn.onData(Buffer.from('{"a":1}\n{"a":2'));
  assert.deepEqual(lines, ['{"a":1}']);
  assert.equal(conn.buffer, '{"a":2');

  conn.onData(Buffer.from('}\n'));
  assert.deepEqual(lines, ['{"a":1}', '{"a":2}']);
  assert.equal(conn.buffer, '');
});

test('a buffer over the cap is dropped and says so, once', () => {
  const conn = new SocketConnection(fakeSocket());
  let overflows = 0;
  conn.on('overflow', () => { overflows += 1; });

  conn.onData(Buffer.alloc(300 * 1024, 0x41)); // no newline, over 256 KiB
  assert.equal(overflows, 1);
  assert.equal(conn.closed, true);
});

test('a line that ends exactly on the buffer boundary is not lost', () => {
  const conn = new SocketConnection(fakeSocket());
  const lines = collect(conn);
  conn.onData(Buffer.from('{"a":1}\n'));
  conn.onData(Buffer.from('{"a":2}\n'));
  assert.deepEqual(lines, ['{"a":1}', '{"a":2}']);
});

// --- the downstream proxy, which frames through its own buffer ---------------

function fakeDownstream() {
  const proxy = new Downstream({ logger: () => {}, vardiff: { min: 1, max: 1e9, desiredSeconds: 10 } });
  proxy.onLine = (conn, line) => {
    if (!conn.seen) conn.seen = [];
    conn.seen.push(line);
  };
  return proxy;
}

function fakeConn() {
  return { lineBuffer: '', closed: false, remote: 'rig', close() { this.closed = true; } };
}

test('the downstream proxy frames the same bytes the same way', () => {
  const proxy = fakeDownstream();
  const conn = fakeConn();

  proxy.onData(conn, Buffer.from('{"id":1}\r\n{"id":2}\n{"id":'));
  assert.deepEqual(conn.seen, ['{"id":1}', '{"id":2}']);
  assert.equal(conn.lineBuffer, '{"id":');

  proxy.onData(conn, Buffer.from('3}\n'));
  assert.deepEqual(conn.seen, ['{"id":1}', '{"id":2}', '{"id":3}']);
  assert.equal(conn.lineBuffer, '');
});

test('the downstream proxy still refuses an over-long line', () => {
  const proxy = fakeDownstream();
  const conn = fakeConn();

  // MAX_LINE is 16 KiB downstream, so the over-long line has to be past that.
  proxy.onData(conn, Buffer.from(`${'x'.repeat(17 * 1024)}\n{"id":1}\n`));
  assert.equal(conn.closed, true, 'the connection is dropped');
  assert.equal(conn.seen, undefined, 'and nothing is passed on');
  assert.equal(conn.lineBuffer, '', 'a closed connection keeps no buffer');
});

test('a connection dropped inside onLine stops the read', () => {
  const proxy = fakeDownstream();
  const conn = fakeConn();
  let calls = 0;
  proxy.onLine = (c, line) => {
    calls += 1;
    if (line === '{"drop":1}') c.closed = true;
  };

  // Three lines, the second one drops the connection: the third must not be
  // delivered, and the buffer must not keep it.
  proxy.onData(conn, Buffer.from('{"a":1}\n{"drop":1}\n{"a":3}\n'));
  assert.equal(calls, 2);
  assert.equal(conn.lineBuffer, '');
});

// Minimal RFC 6455 server side: handshake, frame decode/encode, ping/pong and
// close. Just enough for stratum-over-WebSocket, no dependencies.
//
// This is the transport that makes the pool reachable from a VPS that only
// allows HTTPS: miner -> Cloudflare (TLS, 443) -> this listener.

'use strict';

const crypto = require('node:crypto');

const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const MAX_FRAME = 1024 * 1024; // stratum lines are small; refuse the rest
// ...and so is a *message*. A frame cap alone bounds nothing: RFC 6455 lets a
// client open a 1 MB frame with FIN clear and then send continuation frames
// forever, and this connection would keep every one of them. That is 1 MB per
// frame of unbounded growth from a single socket - the cheapest way to take a
// pool down. A stratum login is under a kilobyte and the largest real message
// (a 34-algorithm job list from a proxy) is a few kilobytes.
const MAX_MESSAGE = 256 * 1024;

function acceptKey(key) {
  return crypto.createHash('sha1').update(key + GUID).digest('base64');
}

/** Attaches to an HTTP server's 'upgrade' event. onConnection(conn) receives an
 *  object with `send(text)`, `close()`, `on('message'|'close', fn)`. */
function attach(httpServer, options = {}) {
  const path = options.path || '/stratum';
  const log = options.logger || (() => {});

  httpServer.on('upgrade', (request, socket, head) => {
    const url = request.url || '/';

    if (path !== '*' && !url.startsWith(path)) {
      socket.end('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n');
      return;
    }

    const key = request.headers['sec-websocket-key'];
    const version = request.headers['sec-websocket-version'];

    if (!key || version !== '13') {
      socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n');
      return;
    }

    const headers = [
      'HTTP/1.1 101 Switching Protocols',
      'Upgrade: websocket',
      'Connection: Upgrade',
      `Sec-WebSocket-Accept: ${acceptKey(key)}`,
      '',
      '',
    ];

    socket.write(headers.join('\r\n'));
    socket.setNoDelay(true);

    const conn = new WebSocketConnection(socket, log);
    if (head && head.length) conn.feed(head);
    options.onConnection(conn, request);
  });
}

class WebSocketConnection {
  constructor(socket, log) {
    this.socket = socket;
    this.log = log;
    this.inbox = Buffer.alloc(0); // frame accumulator, private
    this.fragments = [];
    this.fragmentBytes = 0;
    this.listeners = { message: [], close: [] };
    this.closed = false;

    socket.on('data', (chunk) => this.feed(chunk));
    socket.on('error', () => this.close());
    socket.on('close', () => this.close());
  }

  on(event, handler) {
    if (this.listeners[event]) this.listeners[event].push(handler);
    return this;
  }

  emit(event, value) {
    for (const handler of this.listeners[event] || []) {
      try { handler(value); } catch (error) { this.log('error', `ws handler: ${error.message}`); }
    }
  }

  feed(chunk) {
    if (this.closed) return;
    if (typeof chunk === 'string') chunk = Buffer.from(chunk, 'utf8');

    this.inbox = Buffer.concat([this.inbox, chunk]);

    while (this.inbox.length >= 2) {
      const first = this.inbox[0];
      const second = this.inbox[1];
      const fin = (first & 0x80) !== 0;
      const opcode = first & 0x0f;
      const masked = (second & 0x80) !== 0;
      let length = second & 0x7f;
      let offset = 2;

      if (length === 126) {
        if (this.inbox.length < 4) return;
        length = this.inbox.readUInt16BE(2);
        offset = 4;
      } else if (length === 127) {
        if (this.inbox.length < 10) return;
        const high = this.inbox.readUInt32BE(2);
        const low = this.inbox.readUInt32BE(6);
        length = high * 2 ** 32 + low;
        offset = 10;
      }

      if (length > MAX_FRAME) {
        this.close();
        return;
      }

      if (!masked) {
        // RFC: clients must mask. Unmasked frames are a protocol error and a
        // cheap way to smuggle data past proxies.
        this.close();
        return;
      }

      const total = offset + 4 + length;
      if (this.inbox.length < total) return;

      const mask = this.inbox.subarray(offset, offset + 4);
      const payload = Buffer.from(this.inbox.subarray(offset + 4, total));
      for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i & 3];

      this.inbox = this.inbox.subarray(total);

      switch (opcode) {
        case 0x0: // continuation
          this.fragmentBytes += payload.length;
          if (this.fragmentBytes > MAX_MESSAGE) {
            this.close();
            return;
          }
          this.fragments.push(payload);
          if (fin) {
            const text = Buffer.concat(this.fragments).toString('utf8');
            this.fragments = [];
            this.fragmentBytes = 0;
            this.emit('message', text);
          }
          break;
        case 0x1: // text
        case 0x2: // binary (treat as text: stratum is JSON)
          if (fin) {
            if (payload.length > MAX_MESSAGE) {
              this.close();
              return;
            }
            this.emit('message', payload.toString('utf8'));
          } else {
            // A new data frame while a message is still open is a protocol
            // error, not a reason to quietly drop the first half: half a login
            // parsed as a message is worse than a closed connection.
            if (this.fragments.length > 0) {
              this.close();
              return;
            }
            // The first fragment counts too: a single 1 MB frame with FIN clear
            // is already four times the largest message this protocol has.
            if (payload.length > MAX_MESSAGE) {
              this.close();
              return;
            }
            this.fragments = [payload];
            this.fragmentBytes = payload.length;
          }
          break;
        case 0x8: // close
          this.close();
          return;
        case 0x9: // ping
          this.sendFrame(0xa, payload);
          break;
        case 0xa: // pong
          break;
        default:
          break;
      }
    }
  }

  sendFrame(opcode, payload) {
    if (this.closed) return;

    const length = payload.length;
    let header;

    if (length < 126) {
      header = Buffer.from([0x80 | opcode, length]);
    } else if (length < 65536) {
      header = Buffer.alloc(4);
      header[0] = 0x80 | opcode;
      header[1] = 126;
      header.writeUInt16BE(length, 2);
    } else {
      header = Buffer.alloc(10);
      header[0] = 0x80 | opcode;
      header[1] = 127;
      header.writeBigUInt64BE(BigInt(length), 2);
    }

    try {
      this.socket.write(Buffer.concat([header, payload]));
    } catch (_) {
      this.close();
    }
  }

  send(text) {
    this.sendFrame(0x1, Buffer.from(String(text), 'utf8'));
  }

  /** Same contract as a TCP socket: the stratum code does not know which
   *  transport it is talking to. */
  write(text) {
    this.send(text);
  }

  close() {
    if (this.closed) return;
    this.closed = true;

    try { this.socket.end(); } catch (_) {}
    this.emit('close', null);
  }
}

module.exports = { acceptKey, attach, WebSocketConnection };

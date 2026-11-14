#!/usr/bin/env node
// Test harness for `zmrig-os sync`: the real control plane from fleet/ (real
// store, real /v1/hello, real alerts), plus a second port that only the test can
// reach, standing in for the bot. Nothing here is part of the product; it exists
// so the agent can be tested end to end without a Telegram token.
//
//   node fleet-stub.js <state.json> <ports.json>
//
// <ports.json> is written once both sockets are listening:
//   {"device": 34567, "control": 34568}

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');

const root = path.resolve(__dirname, '../..');
const { Store } = require(path.join(root, 'fleet/src/store'));
const { createServer } = require(path.join(root, 'fleet/src/http'));

const stateFile = process.argv[2];
const portsFile = process.argv[3];
if (!stateFile || !portsFile) {
  process.stderr.write('usage: fleet-stub.js <state.json> <ports.json>\n');
  process.exit(2);
}

const store = new Store(stateFile).load();
const config = {
  interval: 60,
  offline_after: 300,
  queue_limit: 10,
  alert_temp: 95,
  alert_cooldown: 0,
  alert_hashrate_drop: 0.1,
};

const events = [];
// The server bounds how often one rig may check in. A test that runs six
// check-ins in a second is not a rig, so the harness clock moves 3 s per call
// instead of making the suite sleep through the limit.
let clock = Date.now();
const { server } = createServer({
  config,
  store,
  now: () => (clock += 3000),
  log: () => {},
  onEvent: (event) => events.push({ kind: event.kind, text: event.text }),
});

function body(response, status, payload) {
  const text = JSON.stringify(payload);
  response.writeHead(status, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(text) });
  response.end(text);
}

const control = http.createServer((request, response) => {
  const url = new URL(request.url, 'http://localhost');
  const query = url.searchParams;

  switch (url.pathname) {
    case '/enrol': {
      const result = store.enrol(query.get('id'), query.get('owner') || 'tg:1', query.get('label') || null);
      return body(response, result.ok ? 200 : 409, { ok: result.ok, error: result.error || null });
    }
    case '/queue': {
      const args = {};
      for (const key of ['wallet', 'pool', 'coin', 'mode', 'maxtemp', 'threads', 'worker']) {
        if (query.has(key)) args[key] = query.get(key);
      }
      const entry = store.push(
        query.get('id'),
        { cmd: query.get('cmd') || 'setup', args: Object.keys(args).length ? args : undefined },
        10,
      );
      return body(response, entry ? 200 : 429, { ok: Boolean(entry), id: entry && entry.id });
    }
    case '/state': {
      const device = store.get(query.get('id'));
      return body(response, device ? 200 : 404, {
        device: device
          ? {
            id: device.id,
            owner: device.owner,
            label: device.label,
            status: device.status,
            log: device.log,
            queue: device.queue.length,
            version: device.config_version,
          }
          : null,
        events,
      });
    }
    case '/reset-events':
      events.length = 0;
      return body(response, 200, { ok: true });
    default:
      return body(response, 404, { ok: false });
  }
});

server.listen(0, '127.0.0.1', () => {
  control.listen(0, '127.0.0.1', () => {
    fs.writeFileSync(
      portsFile,
      JSON.stringify({ device: server.address().port, control: control.address().port }),
    );
  });
});

const stop = () => {
  store.flush();
  server.close();
  control.close();
  process.exit(0);
};
process.on('SIGTERM', stop);
process.on('SIGINT', stop);

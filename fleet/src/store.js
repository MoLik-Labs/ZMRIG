// The fleet's memory: one JSON file, written atomically.
//
// A control plane for a dozen rigs does not need a database, and a database on a
// free host is a disk that is empty after the next deploy anyway. What it does
// need is that a crash mid-write cannot leave a truncated file, so writes go to
// a temporary name and are renamed - which is atomic on every filesystem worth
// using - and a corrupt file is set aside rather than silently starting empty.

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const SCHEMA = 1;
const AUDIT_LIMIT = 500;

function blank() {
  return { schema: SCHEMA, devices: {}, audit: [] };
}

class Store {
  constructor(file, options = {}) {
    this.file = path.resolve(file);
    this.now = options.now || (() => Date.now());
    this.state = blank();
    this.dirty = false;
    this.timer = null;
    this.writes = 0;
    // Bumped by every mutation. The dashboard caches rendered pages against it,
    // which is how a refresh with nothing changed costs a string compare.
    this.revision = 0;
  }

  load() {
    fs.mkdirSync(path.dirname(this.file), { recursive: true });
    let raw = '';
    try {
      raw = fs.readFileSync(this.file, 'utf8');
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      return this;
    }

    try {
      const parsed = JSON.parse(raw);
      if (!parsed || typeof parsed !== 'object' || parsed.schema !== SCHEMA) {
        throw new Error(`unexpected schema ${parsed && parsed.schema}`);
      }
      this.state = { ...blank(), ...parsed };
    } catch (error) {
      // Keep the evidence: a file that failed to parse is the only copy of the
      // fleet's history, and somebody may want to repair it by hand.
      const backup = `${this.file}.corrupt-${this.now()}`;
      fs.writeFileSync(backup, raw);
      this.state = blank();
      this.log(`state file was unreadable (${error.message}); kept a copy at ${backup}`);
    }
    return this;
  }

  log(message) {
    if (this.now) process.stderr.write(`[store] ${message}\n`);
  }

  /** Debounced: a heartbeat storm must not become a disk write storm. */
  touch() {
    this.dirty = true;
    this.revision += 1;
    if (this.timer) return;
    this.timer = setTimeout(() => {
      this.timer = null;
      this.flush();
    }, 400);
    if (this.timer.unref) this.timer.unref();
  }

  flush() {
    if (!this.dirty) return;
    const tmp = `${this.file}.tmp`;
    const body = JSON.stringify(this.state, null, 2);
    fs.mkdirSync(path.dirname(this.file), { recursive: true });
    fs.writeFileSync(tmp, body);
    fs.renameSync(tmp, this.file);
    this.dirty = false;
    this.writes += 1;
  }

  // ------------------------------------------------------------- devices

  devices() {
    return Object.values(this.state.devices);
  }

  get(id) {
    return this.state.devices[String(id || '').toUpperCase()] || null;
  }

  /** The unclaimed record created by a device that has checked in but nobody
   *  has enrolled yet. It exists so `/enroll` can verify the code. */
  pending(secret) {
    const ids = require('./ids');
    const id = ids.deviceId(secret);
    return this.get(id);
  }

  claim(secret, meta = {}) {
    const ids = require('./ids');
    const id = ids.deviceId(secret);
    const existing = this.get(id);
    const stamp = this.now();

    if (existing) return existing;

    const record = {
      id,
      label: '',
      owner: null,
      secret_hash: ids.sha256(secret),
      code: ids.enrolCode(secret),
      created_at: stamp,
      claimed_at: null,
      last_seen: null,
      first_seen: stamp,
      status: {},
      config: {},
      config_version: 0,
      queue: [],
      acks: [],
      log: '',
      want_log: false,
      alerts: {},
      enrol_address: meta.address || null,
    };

    this.state.devices[id] = record;
    this.touch();
    return record;
  }

  enrol(id, owner, label) {
    const record = this.get(id);
    if (!record) return { ok: false, error: 'unknown' };
    if (record.owner && record.owner !== owner) return { ok: false, error: 'taken', record };
    record.owner = owner;
    record.claimed_at = record.claimed_at || this.now();
    if (label) record.label = label;
    this.touch();
    return { ok: true, record };
  }

  remove(id) {
    const record = this.get(id);
    if (!record) return false;
    delete this.state.devices[record.id];
    this.touch();
    return true;
  }

  // -------------------------------------------------------------- queue

  push(id, command, limit = 10) {
    const record = this.get(id);
    if (!record) return null;
    if (record.queue.length >= limit) return null;
    const entry = { ...command, id: `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 5)}`, at: this.now() };
    record.queue.push(entry);
    // Ask for the log with the *next* check-in: the rig has to receive this
    // command, read its own log and send it in a later request, so the flag and
    // the delivery cannot be the same message.
    if (command.cmd === 'log') record.want_log = true;
    this.touch();
    return entry;
  }

  take(id) {
    const record = this.get(id);
    if (!record || record.queue.length === 0) return [];
    const commands = record.queue.splice(0, record.queue.length);
    this.touch();
    return commands;
  }

  ack(id, entries) {
    const record = this.get(id);
    if (!record) return;
    record.acks.push(...entries);
    record.acks = record.acks.slice(-20);
    this.touch();
  }

  // -------------------------------------------------------------- audit

  audit(entry) {
    this.state.audit.push({ at: this.now(), ...entry });
    if (this.state.audit.length > AUDIT_LIMIT) {
      this.state.audit = this.state.audit.slice(-AUDIT_LIMIT);
    }
    this.touch();
  }

  recent(limit = 10) {
    return this.state.audit.slice(-limit).reverse();
  }
}

/** A device is offline when it has missed three check-ins; before the first one
 *  it is "waiting", which is a different thing from broken. */
function presence(record, config, now = Date.now()) {
  if (!record.last_seen) return 'waiting';
  const silence = now - record.last_seen;
  if (silence > config.offline_after * 1000) return 'offline';
  return 'online';
}

module.exports = { Store, presence };

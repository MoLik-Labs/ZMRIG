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

  /**
   * Devices nobody has enrolled, and how much room they are allowed to take.
   *
   * Any 64-hex Bearer token produces a record: the ID is a hash of the key, so a
   * machine that has never been enrolled still gets somewhere for its first
   * check-in to land. That is the design, and it is also an open door — a
   * stranger can post random keys, and each one is a record in memory plus a
   * rewrite of the whole state file (which on Render lives in /tmp, so it is
   * RAM). A free instance has 512 MB; a loop with curl has that for breakfast.
   *
   * So unenrolled records are capped and they expire. Nothing is lost: an
   * unenrolled rig cannot be sent commands anyway, and an enrolled one is never
   * touched. The rig that was pruned re-creates its record on its next check-in,
   * one minute later, and the only thing that changes is `first_seen`.
   */
  unowned() {
    return Object.values(this.state.devices).filter((device) => !device.owner).length;
  }

  /** Drop unenrolled records that have been silent for `ttlMs`. Returns how many. */
  pruneUnowned(ttlMs, now = this.now()) {
    if (!ttlMs || ttlMs <= 0) return 0;
    let dropped = 0;
    for (const [id, device] of Object.entries(this.state.devices)) {
      if (device.owner) continue;
      const seen = device.last_seen || device.first_seen || 0;
      if (now - seen < ttlMs) continue;
      delete this.state.devices[id];
      dropped += 1;
    }
    if (dropped) this.touch();
    return dropped;
  }

  /**
   * Evict the least recently seen unenrolled record until there is room.
   *
   * A cap alone would be a way to deny enrolment to a real rig: the operator
   * cannot enrol a machine whose first check-in was refused, because the
   * enrolment code is checked against the record the check-in would have made.
   * Evicting instead keeps the table bounded without ever locking anybody out —
   * and the rigs that are unprotected are exactly the ones nobody has seen for
   * the longest, while a rig waiting to be enrolled is checking in every minute
   * and therefore never the oldest.
   */
  makeRoom(limit, now = this.now()) {
    if (!limit || limit <= 0) return 0;
    let dropped = 0;
    for (;;) {
      const unowned = Object.values(this.state.devices).filter((device) => !device.owner);
      if (unowned.length < limit) break;
      unowned.sort((a, b) => (a.last_seen || a.first_seen || 0) - (b.last_seen || b.first_seen || 0));
      delete this.state.devices[unowned[0].id];
      dropped += 1;
    }
    if (dropped) this.touch();
    return dropped;
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

  /** Create or refresh the record for a rig named in the roster. This is the
   *  only place a record exists without a secret: the roster knows the ID, not
   *  the key, so `secret_hash` stays null until the machine itself checks in -
   *  which it can only do with the key it never sends anywhere. */
  define(id, entry = {}, stamp = this.now()) {
    const key = String(id || '').toUpperCase();
    let record = this.state.devices[key];
    if (!record) {
      record = {
        id: key,
        label: '',
        owner: null,
        secret_hash: null,
        code: null,
        created_at: stamp,
        claimed_at: null,
        last_seen: null,
        first_seen: null,
        status: {},
        config: {},
        config_version: 0,
        queue: [],
        acks: [],
        log: '',
        want_log: false,
        alerts: {},
        enrol_address: null,
      };
      this.state.devices[key] = record;
    }

    record.roster = true;
    if (entry.label) record.label = entry.label;
    if (entry.owner && record.owner !== entry.owner) {
      record.owner = entry.owner;
      record.claimed_at = record.claimed_at || stamp;
    }
    if (entry.desired) record.desired = entry.desired;
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

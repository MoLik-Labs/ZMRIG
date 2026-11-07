// Share verification: a thin, pooled wrapper around `zmrig --verify-share`.
//
// Why a child process instead of a library: RandomX *is* a 256 MiB cache plus a
// JIT, and the miner already ships a correct, tested implementation of it. The
// pool spawns one verifier per CPU core, keeps it alive across shares, and
// speaks the line protocol in zmrig/src/verify.zig.
//
// A verifier that dies is restarted on the next share; a share that cannot be
// verified within `timeout` is rejected (never accepted on trust).

'use strict';

const { spawn } = require('node:child_process');

class Verifier {
  constructor(options = {}) {
    this.binary = options.binary || 'zmrig';
    this.concurrency = Math.max(1, Number(options.concurrency || 2));
    this.timeout = Number(options.timeout || 10000);
    this.log = options.logger || (() => {});
    this.slots = [];
    this.queue = [];
    this.closed = false;
    this.stats = { verified: 0, failed: 0, restarts: 0 };
  }

  start() {
    for (let i = 0; i < this.concurrency; i++) this.spawnSlot(i);
  }

  spawnSlot(index) {
    const child = spawn(this.binary, ['--verify-share', '--no-color'], {
      stdio: ['pipe', 'pipe', 'pipe'],
      env: { ...process.env },
    });

    const slot = {
      index,
      child,
      buffer: '',
      pending: null,
      alive: true,
      stderr: '',
    };

    // A verifier that dies while a share is queued must not take the pool down
    // with an unhandled EPIPE on stdin.
    child.stdin.on('error', () => { slot.alive = false; });

    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      slot.buffer += chunk;

      // One line in, one line out is the contract. A binary that writes without
      // ever emitting a newline - a wrong build, a `cat` where the miner should
      // be, a corrupted file - would otherwise grow this string for as long as
      // the process lives. Resetting the slot is the honest response: the share
      // in flight fails, the process is left to its timeout, and the restart
      // path already exists for exactly this.
      if (slot.buffer.length > 64 * 1024) {
        slot.buffer = '';
        const stuck = slot.pending;
        slot.pending = null;
        if (stuck) {
          clearTimeout(stuck.timer);
          stuck.reject(new Error('verifier wrote 64 KB without a newline'));
        }
        return;
      }

      let newline;
      while ((newline = slot.buffer.indexOf('\n')) >= 0) {
        const line = slot.buffer.slice(0, newline).trim();
        slot.buffer = slot.buffer.slice(newline + 1);

        // A log line is not a share reply. There is exactly one writer on this
        // pipe and it is `zmrig --verify-share`, which puts its log on stderr -
        // but a build that predates that, or a binary that is not this miner at
        // all, would otherwise turn its banner into a rejected share. Skipping
        // it *before* taking the waiter is the whole point: taking the waiter
        // and then discarding it leaves the caller's promise unsettled for ever,
        // because its timeout has been cleared.
        if (line.startsWith('[')) continue;

        const waiters = slot.pending;
        if (!waiters) continue;

        slot.pending = null;
        clearTimeout(waiters.timer);

        try {
          const parsed = JSON.parse(line);
          if (parsed.error) waiters.reject(new Error(parsed.error));
          else waiters.resolve(parsed.hash || '');
        } catch (_) {
          waiters.reject(new Error(`unreadable verifier output: ${line.slice(0, 80)}`));
        }

        // The slot is free again. Without this, `drain` only ran when a caller
        // arrived, so anything queued behind a busy slot sat there until the
        // next share did the work of sending the last one - which is a share
        // that times out instead of being verified.
        this.drain();
      }
    });

    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (chunk) => {
      slot.stderr = (slot.stderr + chunk).slice(-2000);
    });

    child.on('exit', (code, signal) => {
      slot.alive = false;
      if (this.closed) return;

      this.stats.restarts += 1;
      this.log('warn', `verifier ${index} exited (${signal || code})${slot.stderr ? `: ${slot.stderr.trim().slice(-200)}` : ''}`);

      if (slot.pending) {
        clearTimeout(slot.pending.timer);
        slot.pending.reject(new Error('verifier exited'));
        slot.pending = null;
      }

      // Restart lazily so a missing binary does not spin.
      setTimeout(() => {
        if (!this.closed && this.slots[index] === slot) {
          this.spawnSlot(index);
          this.drain();
        }
      }, 1000);
    });

    child.on('error', (error) => {
      slot.alive = false;
      this.log('error', `cannot start the verifier (${this.binary}): ${error.message}`);
    });

    this.slots[index] = slot;
  }

  pick() {
    let best = null;
    for (const slot of this.slots) {
      if (!slot || !slot.alive) continue;
      if (slot.pending) continue;
      if (!best) best = slot;
    }

    return best;
  }

  /** Resolves with the hash hex string (lowercase) computed by the engine. */
  verify({ seed, blob, nonce, nonceOffset = 39 }) {
    if (this.closed) return Promise.reject(new Error('verifier closed'));

    return new Promise((resolve, reject) => {
      const task = { seed, blob, nonce, nonceOffset, resolve, reject };
      this.queue.push(task);
      this.drain();
    });
  }

  drain() {
    while (this.queue.length) {
      const slot = this.pick();
      if (!slot) return;

      const task = this.queue.shift();
      const timer = setTimeout(() => {
        if (slot.pending && slot.pending.task === task) {
          slot.pending = null;
          this.stats.failed += 1;
          task.reject(new Error('verification timed out'));
          this.drain();
        }
      }, this.timeout);

      slot.pending = { task, resolve: task.resolve, reject: task.reject, timer };

      const line = JSON.stringify({
        seed: task.seed,
        blob: task.blob,
        nonce: task.nonce,
        nonce_offset: task.nonceOffset,
      });

      try {
        if (!slot.child.stdin.writable) throw new Error('verifier input is closed');
        slot.child.stdin.write(`${line}\n`);
        this.stats.verified += 1;
      } catch (error) {
        clearTimeout(timer);
        slot.pending = null;
        this.stats.failed += 1;
        task.reject(error);
      }
    }
  }

  close() {
    this.closed = true;

    for (const slot of this.slots) {
      if (slot && slot.alive) {
        // A polite quit lets zmrig free its cache; the kill is the fallback.
        try {
          if (slot.child.stdin.writable && !slot.child.stdin.destroyed) slot.child.stdin.write('quit\n');
        } catch (_) {}
        try { slot.child.kill('SIGTERM'); } catch (_) {}
      }
    }

    this.slots = [];
  }
}

module.exports = { Verifier };

// Share verification: a thin, pooled wrapper around `zmrig --verify-share`.
//
// Why a child process instead of a library: RandomX *is* a 256 MiB cache plus a
// JIT, and the miner already ships a correct, tested implementation of it. The
// pool spawns one verifier per CPU core, keeps it alive across shares, and
// speaks the line protocol in zmrig/src/verify.zig.
//
// A verifier that dies is restarted on the next share; a share that cannot be
// verified within `timeout` is rejected (never accepted on trust).
//
// Two ways to use more than one core, and they cost very different amounts of
// RAM:
//
//   concurrency = 2        two processes, 2 x 2336 MB with `fast`
//   threads = 2           one process, 2336 MB, `-t 2` inside it
//
// The second only works if more than one share is in flight per process -
// `zmrig --verify-share` hashes what it has been given - so a slot keeps up to
// `pipeline` shares outstanding and matches the replies first in, first out,
// which is the order the child answers in.

'use strict';

const { spawn } = require('node:child_process');

class Verifier {
  constructor(options = {}) {
    this.binary = options.binary || 'zmrig';
    this.concurrency = Math.max(1, Number(options.concurrency || 2));
    this.timeout = Number(options.timeout || 10000);
    // `light` or `fast`: the miner's own `--mode`, passed through. A verifier
    // that rebuilds the 2 GiB dataset per share (light) does 22 ms a share on
    // the test host; with the dataset it is 2.9 ms, for 2.3 GiB of RAM each.
    this.mode = String(options.mode || 'light').trim().toLowerCase() === 'fast' ? 'fast' : 'light';
    // Hashing threads inside each child (`-t`). One dataset for all of them.
    this.threads = Math.min(Math.max(1, Math.floor(Number(options.threads || 1)) || 1), 64);
    // Shares in flight per child: twice the thread count by default. One per
    // thread leaves a worker idle for the round trip between a reply and the
    // next share; measured warm and in `fast` mode, 2 threads did 453 shares/s
    // at depth 2, 662 at depth 4 and 610-651 at depth 8 - so four, and nothing
    // deeper. In light mode the hash is long enough that the depth stops
    // mattering (88 shares/s at 2, 4 and 8).
    this.pipeline = Math.min(Math.max(1, Math.floor(Number(options.pipeline || this.threads * 2)) || 1), 32);
    this.log = options.logger || (() => {});
    this.slots = [];
    this.queue = [];
    this.cursor = 0;
    this.closed = false;
    this.stats = { verified: 0, failed: 0, restarts: 0 };
  }

  start() {
    for (let i = 0; i < this.concurrency; i++) this.spawnSlot(i);
  }

  spawnSlot(index) {
    const args = ['--verify-share', '--no-color'];
    if (this.mode === 'fast') args.push('--mode', 'fast');
    if (this.threads > 1) args.push('-t', String(this.threads));

    const child = spawn(this.binary, args, {
      stdio: ['pipe', 'pipe', 'pipe'],
      env: { ...process.env },
    });

    const slot = {
      index,
      child,
      buffer: '',
      pending: [],          // shares written and not yet answered, oldest first
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
        // The replies cannot be matched to the shares any more, so every share
        // in this slot fails and the child is replaced rather than trusted.
        this.failSlot(slot, new Error('verifier wrote 64 KB without a newline'));
        try { slot.child.kill('SIGKILL'); } catch (_) {}
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

        // First in, first out: `zmrig --verify-share` answers in the order it
        // was asked, and with more than one share in flight that is the only
        // thing tying a hash to a share.
        const waiters = slot.pending.shift();
        if (!waiters) continue;

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

      this.failSlot(slot, new Error('verifier exited'));

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

  /** Every share this child has been given fails, and the child is forgotten:
   *  after a desync its next reply would be matched to the wrong share. */
  failSlot(slot, error) {
    const waiting = slot.pending;
    slot.pending = [];

    for (const task of waiting) {
      clearTimeout(task.timer);
      this.stats.failed += 1;
      task.reject(error);
    }
  }

  /** A slot with room for one more share. A round-robin cursor, not the first
   *  one that fits: with the pipeline shallow this spreads the work instead of
   *  filling slot 0 before touching slot 1. */
  pick() {
    const count = this.slots.length;
    for (let i = 0; i < count; i++) {
      const slot = this.slots[this.cursor % count];
      this.cursor += 1;
      if (slot && slot.alive && slot.pending.length < this.pipeline) return slot;
    }

    return null;
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
      const entry = { task, resolve: task.resolve, reject: task.reject, timer: null };

      // A timeout means replies are out of step with shares: with a pipeline,
      // the share after this one would be answered by this one's hash. So the
      // child is killed and every share in it fails, rather than one share
      // failing and the rest being quietly wrong.
      entry.timer = setTimeout(() => {
        // `failSlot` counts each share it rejects; counting this one here too
        // made a three-share timeout report four failures.
        this.failSlot(slot, new Error('verification timed out'));
        this.log('warn', `verifier ${slot.index} timed out after ${this.timeout} ms, restarting it`);
        try { slot.child.kill('SIGKILL'); } catch (_) {}
      }, this.timeout);

      slot.pending.push(entry);

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
        clearTimeout(entry.timer);
        // Remove exactly this entry: the shares already in flight stay.
        const at = slot.pending.indexOf(entry);
        if (at >= 0) slot.pending.splice(at, 1);
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

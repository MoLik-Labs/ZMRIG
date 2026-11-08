//! Share verification mode for pool operators.
//!
//!   zmrig --verify-share  < requests.jsonl  > replies.jsonl
//!
//! One JSON object per line in:
//!   {"seed":"<64 hex>","blob":"<hex>","nonce":"<8 hex>","nonce_offset":39}
//! One per line out:
//!   {"hash":"<64 hex>"}      or     {"error":"..."}
//!
//! A pool needs this to accept a share without trusting the miner: it hashes
//! the blob itself and compares the result. The seed cache is built once and
//! reused for every share of the same round, and by default it is a *light*
//! cache (256 MiB), which is what makes the mode usable on a 1 GB VPS.
//!
//! `--mode fast` builds the 2 GiB dataset instead, once, and then reads it for
//! every share: measured on the 2 vCPU test host, 2000 shares of one seed cost
//! 25.5 ms each in light mode and 2.3 ms of hashing in fast mode, which a pool
//! sees as 22 ms and 2.9 ms per share (46 and 349 shares/s) once the line
//! protocol is included - after 0.6 s and 21 s of setup.
//!
//! `-t N` hashes N shares at once: each thread has its own VM and they share
//! one dataset, so two threads in one process are faster than two processes and
//! cost one dataset instead of two (measured through the pool: 87 shares/s in
//! light mode and 626 in fast, against 74 for two processes). It costs 2336 MB
//! of RAM *per verifier process*, so it is opt-in rather than automatic: a pool
//! that runs four of them has to know what it is asking for, and
//! `pool/src/verifier.js` starts `VERIFIER_CONCURRENCY` of them. `pool/src/fit.js`
//! is the arithmetic that warns when the number does not fit the host.

const std = @import("std");
const api = @import("api.zig");
const log = @import("log.zig");
const util = @import("util.zig");

/// What the caller decided, in one place: three positional booleans on a
/// function that already takes two arguments is how a call site ends up passing
/// the mode where the thread count goes.
pub const Settings = struct {
    /// Build the dataset instead of hashing from the cache alone. `--mode`
    /// `auto` is `false` here, on purpose: a verifier is usually one of several
    /// on a small VPS, and silently taking 2.3 GiB per process is how a pool
    /// that used to run gets OOM-killed.
    full_memory: bool = false,
    /// `--randomx-init`, or 0 to use every CPU (capped at 16).
    init_threads: usize = 0,
    /// `--no-huge-pages` inverted. The mapper falls back on its own, so this
    /// only decides whether the reserved page pool may be used at all.
    huge_pages: bool = true,
    /// `-t/--threads`: how many shares to hash at once. Each thread has its own
    /// VM and they share one dataset, so N threads cost one dataset, not N.
    /// Default 1: a verifier is a guest on someone's pool and taking every core
    /// without being asked is not its decision.
    threads: usize = 1,
};

/// One share in flight: the blob with its nonce already patched in, and where
/// the hash goes. Owned by the main thread, which allocates it and frees it
/// after the reply is written; a worker only writes `hash` and `ready`.
const Job = struct {
    blob: []u8,
    nonce: u32,
    nonce_offset: usize,
    hash: [32]u8 align(64) = undefined,
    /// Released by the worker, acquired by the main thread. `hash` is written
    /// before this store, so the release/acquire pair is what makes it visible.
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// The queue between the main thread and the hashing threads.
///
/// Every worker has its own VM and they all read one dataset, which is exactly
/// how the miner runs: the dataset is read-only after `seed`, and a VM is the
/// per-thread scratch state. That is the whole reason this is worth doing -
/// `-t 4 --mode fast` is 2336 MB and four times the hashes, where four
/// processes would be 9344 MB for the same work.
const Queue = struct {
    mutex: std.Thread.Mutex = .{},
    on_work: std.Thread.Condition = .{},
    on_done: std.Thread.Condition = .{},
    jobs: std.fifo.LinearFifo(*Job, .Dynamic),
    stopping: bool = false,
    engine: *api.Wrapped = undefined,
    huge_pages: bool = true,
    logger: *log.Logger = undefined,

    fn worker(self: *Queue) void {
        // Concurrent creation is safe (RandomX only needs the dataset, which is
        // read-only by now); concurrent *hashing* over a dataset that is being
        // rebuilt is not, which is why `run` drains the queue before it changes
        // the seed.
        const vm = self.engine.createVm(self.huge_pages) catch |e| {
            self.logger.err("verify: cannot create a VM for a hashing thread: {s}", .{@errorName(e)});
            return;
        };
        defer api.xmo_vm_free(vm);

        while (true) {
            self.mutex.lock();
            while (self.jobs.readableLength() == 0 and !self.stopping) self.on_work.wait(&self.mutex);
            if (self.jobs.readableLength() == 0) {
                self.mutex.unlock();

                return; // stopping, and there is nothing left
            }
            const job = self.jobs.readItem().?;
            self.mutex.unlock();

            // RandomX writes the digest with SIMD stores and reads the blob as
            // it was handed to it, so the nonce goes into this job's own buffer
            // before the hash - no worker touches another's.
            util.writeLe(u32, job.blob, job.nonce_offset, job.nonce);
            api.xmo_hash(vm, job.blob.ptr, job.blob.len, &job.hash);

            job.ready.store(true, .release);

            self.mutex.lock();
            self.on_done.signal();
            self.mutex.unlock();
        }
    }
};

/// The replies, in the order the requests arrived.
///
/// Order is part of the protocol: the pool matches replies to shares first in,
/// first out (`pool/src/verifier.js` writes several before reading any). A
/// thread pool that answered as each hash finished would hand one rig another
/// rig's hash, and the pool would reject both.
const Driver = struct {
    allocator: std.mem.Allocator,
    queue: ?*Queue,
    pending: std.ArrayList(*Job),
    next_out: usize = 0,
    in_flight: usize = 0,
    /// How many shares may be in flight at once. Bigger than the thread count
    /// so the workers always find work; small enough that a stalled pool cannot
    /// make this grow without bound.
    max_in_flight: usize,

    /// Write the replies that are ready, oldest first. With `block`, wait for
    /// the oldest one first - which is what an error reply needs, because an
    /// error that overtook a share would be read as that share's answer.
    fn flush(self: *Driver, out: anytype, block: bool) !void {
        if (self.next_out >= self.pending.items.len) return;

        if (block) {
            if (self.queue) |queue| {
                queue.mutex.lock();
                defer queue.mutex.unlock();
                while (!self.pending.items[self.next_out].ready.load(.acquire)) queue.on_done.wait(&queue.mutex);
            }
        }

        var wrote = false;
        while (self.next_out < self.pending.items.len) {
            const job = self.pending.items[self.next_out];
            if (!job.ready.load(.acquire)) break;

            var hex: [64]u8 = undefined;
            writeHex(&hex, &job.hash);
            try out.writer().print("{{\"hash\":\"{s}\"}}\n", .{hex});

            self.allocator.free(job.blob);
            self.allocator.destroy(job);
            self.next_out += 1;
            self.in_flight -= 1;
            wrote = true;
        }

        if (!wrote) return;

        // One flush per batch, not per share: with the pool pipelining four
        // shares into this process, that is one write per four replies.
        try out.flush();

        if (self.next_out == self.pending.items.len) {
            self.pending.clearRetainingCapacity();
            self.next_out = 0;
        }
    }

    /// Wait up to `ms` for a worker to finish a share. `true` when one did.
    ///
    /// The point is not to wait *for a particular* share: it is to get back to
    /// reading input quickly. A pool that pipelines two shares writes them as
    /// two separate writes, and the second one may not be in the pipe by the
    /// time the first line has been read - blocking on the first hash right
    /// there leaves the second thread with nothing to do, and two threads then
    /// ran no faster than one (measured: 51 shares/s against 165 at depth 4).
    /// Waking every millisecond to check for input costs nothing next to a 20 ms
    /// hash.
    fn awaitCompletion(self: *Driver, ms: u64) bool {
        const queue = self.queue orelse return false;
        if (self.in_flight == 0) return false;

        queue.mutex.lock();
        defer queue.mutex.unlock();
        queue.on_done.timedWait(&queue.mutex, ms * std.time.ns_per_ms) catch return false;

        return true;
    }

    /// Wait until every queued share has been answered. Used at the end of the
    /// stream and before an error line: a reply that overtook an unhashed share
    /// would be read as that share's answer.
    ///
    /// Waiting for the oldest one and then writing everything that happens to
    /// be ready is not enough - the first version did that and dropped the last
    /// seven replies of a 2000-share run - so this keeps going until the queue
    /// is empty.
    fn flushAll(self: *Driver, out: anytype) !void {
        while (self.next_out < self.pending.items.len) {
            try self.flush(out, true);
            try self.flush(out, false);
        }
    }

    /// Hand a share to a worker, or hash it here when no thread could be
    /// started. Returns with at least one slot free.
    fn submit(self: *Driver, blob: []u8, nonce: u32, nonce_offset: usize, vm: ?*api.Vm) !void {
        const job = try self.allocator.create(Job);
        job.* = .{ .blob = blob, .nonce = nonce, .nonce_offset = nonce_offset };

        if (self.queue) |queue| {
            queue.mutex.lock();
            queue.jobs.writeItem(job) catch {
                queue.mutex.unlock();
                self.allocator.free(blob);
                self.allocator.destroy(job);

                return error.OutOfMemory;
            };
            queue.on_work.signal();
            queue.mutex.unlock();
        } else if (vm) |engine_vm| {
            // No threads: the single-threaded path, same code as before.
            util.writeLe(u32, blob, nonce_offset, nonce);
            api.xmo_hash(engine_vm, blob.ptr, blob.len, &job.hash);
            job.ready.store(true, .release);
        }

        try self.pending.append(job);
        self.in_flight += 1;
    }

    fn stop(self: *Driver) void {
        for (self.pending.items[self.next_out..]) |job| {
            self.allocator.free(job.blob);
            self.allocator.destroy(job);
        }
        self.pending.deinit();
    }
};

pub fn run(allocator: std.mem.Allocator, logger: *log.Logger, settings: Settings) !void {
    const full_memory = settings.full_memory;
    var wrapped: ?api.Wrapped = null;
    defer if (wrapped) |*w| w.destroy();

    var current_seed: [32]u8 = [_]u8{0} ** 32;
    var have_seed = false;

    var stdout_buf = std.io.bufferedWriter(std.io.getStdOut().writer());

    // Input is read with `poll` rather than "block until the next line": with
    // more than one share in flight, a reply can be ready while the pool is
    // still deciding what to send next, and a read that waited for the next
    // line would hold that reply until then - which, with a pool that writes one
    // share and waits for its hash, is for ever.
    var in_buf: [64 * 1024]u8 = undefined;
    var in_len: usize = 0;
    var in_start: usize = 0;
    // A line longer than the buffer is answered with an error and then thrown
    // away up to its newline, instead of being hashed as a dozen nonsense
    // fragments.
    var discarding = false;

    // Dataset initialisation is very close to linear in threads - measured
    // 21.5 s at 2 threads and 42.5 s at 1 on the test host - and happens once
    // per seed change, which is once per block.
    // Capped at 16: past that the cache becomes the bottleneck and the rest of
    // the pool's work suffers for a build that is already a few seconds.
    const init_threads: usize = if (settings.init_threads > 0)
        @min(settings.init_threads, 64)
    else
        @min(std.Thread.getCpuCount() catch 1, 16);

    const threads = @min(@max(settings.threads, 1), 64);

    var queue_ptr: ?*Queue = null;
    var threads_spawned: usize = 0;
    var spawn_handles: [64]std.Thread = undefined;

    // A single-threaded verifier that also owns a VM for the case where the
    // operating system refuses the threads: it then does exactly what it did
    // before, rather than refusing to work.
    var inline_vm: ?*api.Vm = null;
    defer if (inline_vm) |v| api.xmo_vm_free(v);

    var driver = Driver{
        .allocator = allocator,
        .queue = null,
        .pending = std.ArrayList(*Job).init(allocator),
        .max_in_flight = @max(threads * 4, 4),
    };
    defer {
        // Stop the workers *before* the jobs they may still be holding are
        // freed: this order was a segfault at exit the first time it was
        // written the other way round.
        if (queue_ptr) |queue| {
            queue.mutex.lock();
            queue.stopping = true;
            queue.on_work.broadcast();
            queue.mutex.unlock();
            for (spawn_handles[0..threads_spawned]) |handle| handle.join();
        }
        driver.stop();
        if (queue_ptr) |queue| {
            queue.jobs.deinit();
            allocator.destroy(queue);
        }
    }

    if (full_memory) {
        logger.info("verify mode: hashing submitted shares (fast mode, {d} MB cache + {d} MB dataset, {d} thread(s))", .{
            api.Algo.rx_0.cacheBytes() / (1024 * 1024), api.Algo.rx_0.datasetBytes() / (1024 * 1024), threads,
        });
    } else {
        logger.info("verify mode: hashing submitted shares (light mode, 256 MB cache, {d} thread(s))", .{threads});
    }

    while (true) {
        // One line, or `null` when the timeout expired with nothing to read -
        // in which case the replies that are ready get written below and the
        // loop comes back here.
        const next = try readLine(&in_buf, &in_len, &in_start, &discarding, driver.in_flight);
        if (next == .eof) break;

        if (next == .timeout) {
            // Nothing to read and something is being hashed: write whatever is
            // ready, then come straight back to check for more input.
            // The flush is unconditional: `awaitCompletion` only reports a
            // signal that arrived *during* its window, and a hash that finished
            // a moment ago has already signalled. Waiting without flushing was
            // a verifier that stopped answering entirely - a 120 s timeout on
            // the pool side with a finished reply sitting in `pending`.
            if (driver.in_flight > 0) _ = driver.awaitCompletion(1);
            try driver.flush(&stdout_buf, false);

            continue;
        }

        if (next == .too_long) {
            try driver.flushAll(&stdout_buf);
            try stdout_buf.writer().writeAll("{\"error\":\"line too long\"}\n");
            try stdout_buf.flush();

            continue;
        }

        const line: []const u8 = next.line;
        const text = std.mem.trim(u8, line, " \t\r");
        if (text.len == 0) continue;
        if (std.mem.eql(u8, text, "quit")) break;

        // Keep the pipeline fed but bounded: this waits for the oldest share
        // only when the queue is already full.
        if (driver.in_flight >= driver.max_in_flight) try driver.flushAll(&stdout_buf);
        try driver.flush(&stdout_buf, false);

        var request = parseRequest(allocator, text) catch |e| {
            try driver.flushAll(&stdout_buf);
            const message = switch (e) {
                error.UnsupportedAlgo => "{\"error\":\"this verifier only computes rx/0\"}\n",
                error.InvalidNonce => "{\"error\":\"nonce must be a hex string\"}\n",
                else => "{\"error\":\"invalid request\"}\n",
            };

            try stdout_buf.writer().writeAll(message);
            try stdout_buf.flush();

            continue;
        };
        // `defer` in a loop body runs at the end of the iteration, so the
        // request is freed after the share has been queued - `blob` is copied
        // into the job, and `seed`/`nonce` are not needed by the worker.
        defer request.deinit(allocator);

        if (request.seed.len != 64) {
            try driver.flushAll(&stdout_buf);
            try stdout_buf.writer().writeAll("{\"error\":\"seed must be 64 hex characters\"}\n");
            try stdout_buf.flush();

            continue;
        }

        var seed_bytes: [32]u8 = undefined;
        _ = util.hexToBytes(&seed_bytes, request.seed) catch {
            try driver.flushAll(&stdout_buf);
            try stdout_buf.writer().writeAll("{\"error\":\"seed is not hex\"}\n");
            try stdout_buf.flush();

            continue;
        };

        if (wrapped == null) {
            wrapped = api.Wrapped.create(.rx_0, .{
                // Huge pages, unless `--no-huge-pages` said otherwise: a pool
                // is often also the host that reserved them (`zmrig-os
                // hugepages`), and a fast verifier that ignored the pool would
                // map its dataset from ordinary RAM *next to* 2.3 GiB of pages
                // nothing is using - which is how this process got OOM-killed
                // the first time it was asked for the dataset.
                .huge_pages = settings.huge_pages,
                .huge_pages_jit = true,
                .full_memory = full_memory,
                .jit = true,
            }) catch {
                try driver.flushAll(&stdout_buf);
                try stdout_buf.writer().writeAll("{\"error\":\"cannot create the hash engine\"}\n");
                try stdout_buf.flush();

                continue;
            };
        }

        if (!have_seed or !std.mem.eql(u8, &current_seed, &seed_bytes)) {
            // Every share still in flight belongs to the *old* seed, and
            // `seed` rebuilds the cache those hashes are reading. Answering
            // them first is the difference between a pool that verifies and a
            // pool that rejects twelve honest shares at every block: this was
            // measured, with two threads and a pipelined client, as every hash
            // of the first round coming back wrong.
            try driver.flushAll(&stdout_buf);

            // Building the dataset is the one place a verifier can use more
            // than one core before the threads exist: every share afterwards is
            // a hash, and those are spread over the workers.
            if (wrapped.?.seed(&seed_bytes, init_threads)) |_| {
                // A new seed means every VM in flight is hashing against the
                // wrong dataset. Nothing is in flight here (the pool waits for
                // each round's replies), so it is enough to start the workers
                // on the first seed and let them keep their VMs.
                current_seed = seed_bytes;
                have_seed = true;

                if (queue_ptr == null and threads > 1) {
                    const queue = try allocator.create(Queue);
                    queue.* = .{
                        .jobs = std.fifo.LinearFifo(*Job, .Dynamic).init(allocator),
                        .engine = &wrapped.?,
                        .huge_pages = settings.huge_pages,
                        .logger = logger,
                    };

                    while (threads_spawned < threads) {
                        const handle = std.Thread.spawn(.{}, Queue.worker, .{queue}) catch break;
                        spawn_handles[threads_spawned] = handle;
                        threads_spawned += 1;
                    }

                    if (threads_spawned == 0) {
                        logger.warn("verify: cannot start a hashing thread, hashing on this one instead", .{});
                        queue.jobs.deinit();
                        allocator.destroy(queue);
                    } else {
                        queue_ptr = queue;
                        driver.queue = queue;
                    }
                }
            } else |_| {
                try driver.flushAll(&stdout_buf);
                try stdout_buf.writer().writeAll("{\"error\":\"cannot build the cache for this seed\"}\n");
                try stdout_buf.flush();

                continue;
            }
        }

        if (queue_ptr == null and inline_vm == null) {
            inline_vm = wrapped.?.createVm(settings.huge_pages) catch null;
            if (inline_vm == null) {
                try driver.flushAll(&stdout_buf);
                try stdout_buf.writer().writeAll("{\"error\":\"cannot create the VM\"}\n");
                try stdout_buf.flush();

                continue;
            }
        }

        const blob_len = request.blob.len / 2;
        if (blob_len == 0) {
            try driver.flushAll(&stdout_buf);
            try stdout_buf.writer().writeAll("{\"error\":\"empty blob\"}\n");
            try stdout_buf.flush();

            continue;
        }

        var nonce_value: u32 = 0;

        // Pools send the nonce as its own field; patching it here means the
        // blob the pool stores never has to be rewritten per share.
        if (request.nonce.len > 0) {
            if (request.nonce.len != 8) {
                try driver.flushAll(&stdout_buf);
                try stdout_buf.writer().writeAll("{\"error\":\"nonce must be 8 hex characters\"}\n");
                try stdout_buf.flush();

                continue;
            }

            // The miner sends the nonce as the *number* it used, in hex. It
            // wrote it to the blob little-endian, so patch it the same way.
            nonce_value = std.fmt.parseInt(u32, request.nonce, 16) catch {
                try driver.flushAll(&stdout_buf);
                try stdout_buf.writer().writeAll("{\"error\":\"nonce is not hex\"}\n");
                try stdout_buf.flush();

                continue;
            };

            if (request.nonce_offset + 4 > blob_len) {
                try driver.flushAll(&stdout_buf);
                try stdout_buf.writer().writeAll("{\"error\":\"nonce offset outside the blob\"}\n");
                try stdout_buf.flush();

                continue;
            }
        }

        // 64 bytes: RandomX reads the blob with SIMD loads in the JIT'd code.
        const blob = allocator.alignedAlloc(u8, 64, blob_len) catch {
            try driver.flushAll(&stdout_buf);
            try stdout_buf.writer().writeAll("{\"error\":\"out of memory\"}\n");
            try stdout_buf.flush();

            continue;
        };
        _ = util.hexToBytes(blob, request.blob) catch {
            allocator.free(blob);
            try driver.flushAll(&stdout_buf);
            try stdout_buf.writer().writeAll("{\"error\":\"blob is not hex\"}\n");
            try stdout_buf.flush();

            continue;
        };

        driver.submit(blob, nonce_value, request.nonce_offset, inline_vm) catch {
            try driver.flushAll(&stdout_buf);
            try stdout_buf.writer().writeAll("{\"error\":\"out of memory\"}\n");
            try stdout_buf.flush();

            continue;
        };
    }

    // Everything that was queued before EOF or `quit` still gets an answer.
    try driver.flushAll(&stdout_buf);
}

const Next = union(enum) {
    line: []const u8,
    timeout,
    too_long,
    eof,
};

/// One line from stdin, waiting at most until there is something to report.
///
/// `in_flight` decides whether the wait is bounded: with shares being hashed,
/// the caller has replies to write, so it must come back to do that; with
/// nothing in flight there is nothing to write and the wait may be indefinite.
fn readLine(buf: []u8, len: *usize, start: *usize, discarding: *bool, in_flight: usize) !Next {
    while (true) {
        // Everything was consumed: an empty buffer is not a full one.
        if (start.* == len.*) {
            start.* = 0;
            len.* = 0;
        }

        // A complete line already in the buffer?
        if (std.mem.indexOfScalar(u8, buf[start.*..len.*], '\n')) |offset| {
            const end = start.* + offset;
            const line = buf[start.*..end];
            start.* = end + 1;

            if (discarding.*) {
                discarding.* = false;

                continue;
            }

            return .{ .line = line };
        }

        // No newline. Move the unconsumed tail to the front *before* deciding
        // the line is too long: without this, a full buffer of short lines with
        // a partial line at the end announced `line too long` once per 64 KiB
        // of input. That is the bug this order exists for.
        if (start.* > 0) {
            std.mem.copyForwards(u8, buf[0..], buf[start.*..len.*]);
            len.* -= start.*;
            start.* = 0;

            if (std.mem.indexOfScalar(u8, buf[0..len.*], '\n')) |offset| {
                const line = buf[0..offset];
                start.* = offset + 1;

                if (discarding.*) {
                    discarding.* = false;

                    continue;
                }

                return .{ .line = line };
            }
        }

        // No newline, nothing to compact away, buffer full: this is not a line.
        if (len.* == buf.len) {
            len.* = 0;
            start.* = 0;
            discarding.* = true;

            return .too_long;
        }

        // With shares in flight the caller has replies to write, so it must
        // come back: `0` is "is there anything to read right now" and the
        // caller then waits for a hash instead of sleeping here. That wait used
        // to be a 2 ms poll timeout, which added 2 ms to every reply of a pool
        // that sends one share and waits for it - measured as 5 ms per share
        // against 2.3 ms of actual hashing.
        var fds = [_]std.posix.pollfd{.{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 }};
        const wait_ms: i32 = if (in_flight > 0) 0 else -1;
        const ready = std.posix.poll(&fds, wait_ms) catch 0;
        if (ready == 0) return .timeout;

        const read = std.posix.read(std.posix.STDIN_FILENO, buf[len.*..]) catch |e| switch (e) {
            error.WouldBlock => return .timeout,
            else => return e,
        };
        if (read == 0) return .eof;

        len.* += read;
    }
}

pub const ParsedRequest = struct {
    seed: []u8,
    blob: []u8,
    nonce: []u8,
    nonce_offset: usize = 39,

    pub fn deinit(self: *ParsedRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.seed);
        allocator.free(self.blob);
        allocator.free(self.nonce);
    }
};

pub fn parseRequest(allocator: std.mem.Allocator, text: []const u8) !ParsedRequest {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.NotAnObject,
    };

    var result = ParsedRequest{
        .seed = try allocator.dupe(u8, ""),
        .blob = try allocator.dupe(u8, ""),
        .nonce = try allocator.dupe(u8, ""),
    };
    errdefer result.deinit(allocator);

    if (root.get("seed")) |value| {
        if (value == .string) {
            allocator.free(result.seed);
            result.seed = try allocator.dupe(u8, value.string);
        }
    }
    if (root.get("blob")) |value| {
        if (value == .string) {
            allocator.free(result.blob);
            result.blob = try allocator.dupe(u8, value.string);
        }
    }
    if (root.get("nonce")) |value| {
        switch (value) {
            .string => |material| {
                allocator.free(result.nonce);
                result.nonce = try allocator.dupe(u8, material);
            },
            // Hashing "the blob with nonce 0" for `"nonce": 123` would return
            // a hash for a share that was never mined.
            .null => {},
            else => return error.InvalidNonce,
        }
    }
    if (root.get("algo")) |value| {
        if (value == .string) {
            const algo = api.Algo.fromName(value.string) orelse return error.UnsupportedAlgo;
            if (algo != .rx_0) return error.UnsupportedAlgo;
        }
    }
    if (root.get("nonce_offset")) |value| {
        if (value == .integer) result.nonce_offset = @intCast(@max(value.integer, 0));
    }

    return result;
}

fn writeHex(out: *[64]u8, bytes: *const [32]u8) void {
    const table = "0123456789abcdef";

    for (bytes, 0..) |byte, i| {
        out[i * 2] = table[byte >> 4];
        out[i * 2 + 1] = table[byte & 0x0f];
    }
}

test "writeHex is lowercase and 64 characters" {
    var hash = [_]u8{0} ** 32;
    hash[0] = 0xab;
    hash[31] = 0x0f;

    var hex: [64]u8 = undefined;
    writeHex(&hex, &hash);

    try std.testing.expect(std.mem.startsWith(u8, &hex, "ab"));
    try std.testing.expect(std.mem.endsWith(u8, &hex, "0f"));
    try std.testing.expectEqual(@as(usize, 64), hex.len);
}

test "parseRequest reads the fields it needs" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var request = try parseRequest(allocator, "{\"seed\":\"aa\",\"blob\":\"bb\",\"nonce\":\"cc\",\"nonce_offset\":147}");
    defer request.deinit(allocator);

    try testing.expectEqualStrings("aa", request.seed);
    try testing.expectEqualStrings("bb", request.blob);
    try testing.expectEqualStrings("cc", request.nonce);
    try testing.expectEqual(@as(usize, 147), request.nonce_offset);
}

test "a malformed nonce or a foreign algorithm is refused" {
    const testing = std.testing;
    const allocator = testing.allocator;

    try testing.expectError(error.InvalidNonce, parseRequest(allocator, "{\"blob\":\"00\",\"nonce\":123}"));
    try testing.expectError(error.UnsupportedAlgo, parseRequest(allocator, "{\"blob\":\"00\",\"algo\":\"cn/1\"}"));
    // Explicit null means "not given", which is allowed: the blob's own nonce
    // is used.
    var request = try parseRequest(allocator, "{\"blob\":\"00\",\"nonce\":null}");
    defer request.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), request.nonce.len);
}

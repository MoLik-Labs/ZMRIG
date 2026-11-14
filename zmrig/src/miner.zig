//! Mining core: hash engine lifetime, seed handling, worker threads, share
//! detection and hashrate accounting.
//!
//! Threading model (same as XMRig):
//!   * one engine owns the RandomX cache and (fast mode) the 2 GiB dataset,
//!   * every worker thread owns one VM and hashes on its own,
//!   * a job switch is a generation counter, workers pick it up between hashes,
//!   * a seed change pauses the workers and re-initialises cache + dataset.

const std = @import("std");
const api = @import("api.zig");
const job_mod = @import("job.zig");
const topology = @import("topology.zig");
const log = @import("log.zig");
const options = @import("options.zig");
const memory_mod = @import("memory.zig");
const hugepages_mod = @import("hugepages.zig");
const stratum = @import("stratum.zig");

/// One number, in the module that has to police it (`-t`) and the one that has
/// to allocate for it (this one).
pub const max_threads = options.max_threads;

/// XMRig reserves nonce windows of 32768 per thread, we do the same.
const nonce_chunk: u32 = 32768;

fn nowMs() i64 {
    return std.time.milliTimestamp();
}

pub const Share = struct {
    job_id: [96]u8 = undefined,
    job_id_len: usize = 0,
    nonce: u32 = 0,
    hash: [32]u8 = undefined,
    height: u64 = 0,
    /// Algorithm of the job the share belongs to: pools validate the name, and
    /// a hardcoded "rx/0" is wrong the moment the pool switches algo.
    algo: api.Algo = .rx_0,
};

/// Hands shares to the pool connection from worker threads.
/// A pool that validates every share bans the IP for it (xmrpool.eu: 10
/// minutes, an hour if it keeps happening). Three in a row is enough to know
/// the rig, not the pool, is wrong -- so stop sending before the ban lands.
pub const INVALID_SHARE_LIMIT: u64 = 3;
pub const INVALID_QUARANTINE_MS: i64 = 600_000;

pub const Submitter = struct {
    mutex: std.Thread.Mutex = .{},
    session: ?*stratum.Session = null,
    /// Timestamp of the last byte we sent, used to decide when a keepalive is
    /// due. Shares count as traffic, so a busy rig never sends one.
    last_write: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    last_drop_warn: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    accepted: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rejected: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    failed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Shares handed to the pool, accepted or not. `accepted + rejected`
    /// counts answers, this counts questions, so "sent 500, answered 0" is
    /// visible -- which is what a pool that goes silent looks like.
    submitted: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Shares the pool called invalid since the last accepted one, and the
    /// moment submissions may resume. See INVALID_SHARE_LIMIT.
    invalid: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    quarantine_until: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    last_quarantine_warn: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

    pub fn attach(self: *Submitter, session: *stratum.Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.session = session;
        self.last_write.store(std.time.milliTimestamp(), .monotonic);
    }

    /// Sends `keepalived` when nothing has gone out for `interval_ms`.
    /// Runs on the monitor thread: the same mutex keeps it from interleaving
    /// with a share submission, and `session == null` after detach makes it a
    /// no-op while the connection is being replaced.
    pub fn keepaliveIfIdle(self: *Submitter, interval_ms: i64, logger: *log.Logger) void {
        const now = std.time.milliTimestamp();
        if (now - self.last_write.load(.monotonic) < interval_ms) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.session orelse return;
        if (now - self.last_write.load(.monotonic) < interval_ms) return;

        self.last_write.store(now, .monotonic);

        session.keepalive() catch |e| {
            logger.debug("cannot send keepalive: {s}", .{@errorName(e)});
        };
    }

    pub fn detach(self: *Submitter) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.session = null;
    }

    /// Counts a rejected share and quarantines submissions when the pool keeps
    /// calling them invalid. Silence here costs the whole IP: pools that
    /// validate every share escalate a stream of bad ones to an hour-long ban.
    pub fn noteRejection(self: *Submitter, refusal: stratum.Refusal, logger: *log.Logger) void {
        if (refusal != .invalid_share) return;

        const count = self.invalid.fetchAdd(1, .monotonic) + 1;
        if (count < INVALID_SHARE_LIMIT) return;

        self.invalid.store(0, .monotonic);
        self.quarantine_until.store(std.time.milliTimestamp() + INVALID_QUARANTINE_MS, .monotonic);

        logger.err("the pool called {d} shares invalid in a row; pausing submissions for {d} s, because a stream of bad shares is what gets an IP banned. Check overclocking, huge pages and `zmrig --self-test`; mining resumes on its own", .{ count, INVALID_QUARANTINE_MS / 1000 });
    }

    pub fn quarantined(self: *const Submitter) bool {
        return std.time.milliTimestamp() < self.quarantine_until.load(.monotonic);
    }

    pub fn submit(self: *Submitter, share: *const Share, logger: *log.Logger) void {
        _ = self.submitted.fetchAdd(1, .monotonic);

        if (self.quarantined()) {
            _ = self.failed.fetchAdd(1, .monotonic);

            // One line per minute is enough to see it in a log.
            const now = std.time.milliTimestamp();
            if (now - self.last_quarantine_warn.load(.monotonic) > 60_000) {
                self.last_quarantine_warn.store(now, .monotonic);
                logger.warn("not submitting: still in the invalid-share quarantine ({d} s left)", .{@divTrunc(self.quarantine_until.load(.monotonic) - now, 1000)});
            }

            return;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.session orelse {
            _ = self.failed.fetchAdd(1, .monotonic);

            // A disconnect can last minutes and a 1 kH/s rig finds a share
            // every few seconds; log the first one and then at most every
            // 30 s so the log stays readable.
            const now = std.time.milliTimestamp();
            if (now - self.last_drop_warn.load(.monotonic) > 30_000) {
                self.last_drop_warn.store(now, .monotonic);
                logger.warn("share found while disconnected, dropped (nonce {x}, {d} dropped so far)", .{ share.nonce, self.failed.load(.monotonic) });
            }

            return;
        };

        self.last_write.store(std.time.milliTimestamp(), .monotonic);

        _ = session.submit(share.job_id[0..share.job_id_len], share.nonce, &share.hash, share.height, share.algo) catch |e| {
            _ = self.failed.fetchAdd(1, .monotonic);
            logger.warn("cannot send share ({s}); dropping the connection so it can be replaced", .{@errorName(e)});

            // A half-written line has already corrupted the stream, and a pool
            // that cannot take 300 bytes is not mining for us anyway. Shut the
            // socket down: the read loop wakes up, this mutex is released, and
            // the reconnect path takes over. Without this every worker blocked
            // on the same socket until the send timeout expired.
            std.posix.shutdown(session.conn.handle(), .both) catch {};

            return;
        };

        logger.debug("share submitted (nonce {x})", .{share.nonce});
    }
};

/// One cache line per thread counter.
///
/// The hot loop increments this counter once per hash. Left as a bare
/// `std.atomic.Value(u64)` array, eight neighbours share a cache line, so every
/// increment invalidates the line for the other seven threads (false sharing).
/// At mining rates this is a rounding error on a small box -- and it is not
/// measurable on this 2-vCPU test machine -- but it is free to pad, and on a
/// 32-core server the line ping-pong is real.
pub const Counter = struct {
    value: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    _pad: [56]u8 = [_]u8{0} ** 56,
};

comptime {
    // The whole point of the padding: one counter per 64-byte line.
    if (@sizeOf(Counter) != 64) @compileError("Counter must stay one 64-byte cache line");
}

pub const Shared = struct {
    job_mutex: std.Thread.Mutex = .{},
    job: job_mod.Job = .{},
    generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    next_nonce: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    paused: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// How many workers may hash right now; 0 means "all of them".
    ///
    /// This is the thermal governor's handle. Pausing every worker and
    /// resuming later would be simpler, but a paused miner produces nothing at
    /// all while a three-thread miner on a hot box still produces most of what
    /// a four-thread one would - the fourth thread is what costs the degrees.
    /// A parked worker keeps its VM and its place in the dataset, so it costs
    /// nothing to park it for a minute and wake it up.
    active_threads: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    bench_limit: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    hashes: [max_threads]Counter = [_]Counter{.{}} ** max_threads,
    thread_count: usize = 0,
    /// Hardware threads, for the dataset initialiser's default.
    hw_threads: usize = 0,
    /// Threads used to build the dataset (`--randomx-init`), 0 = every CPU.
    init_threads: usize = 0,
    priority: i32 = -1,

    pub fn publish(self: *Shared, new_job: *const job_mod.Job) void {
        self.job_mutex.lock();
        defer self.job_mutex.unlock();

        self.job = new_job.*;
        self.next_nonce.store(randomNonceBase(), .release);
        _ = self.generation.fetchAdd(1, .monotonic);
    }

    /// Threads to hand to the dataset initialiser.
    ///
    /// Default: every hardware thread, not just the mining threads. Building
    /// Monero's 2 GiB dataset is a pure memory-bandwidth job, and it is the
    /// longest wait a rig has: 42.9 s with one thread against 21.1 s with two
    /// on a 2 vCPU box. A rig told to mine with one thread was paying that
    /// difference on every start - and on every seed change, which on a
    /// multi-algorithm pool is every few minutes.
    pub fn initThreads(self: *const Shared) usize {
        if (self.init_threads > 0) return self.init_threads;

        const hw = if (self.hw_threads > 0) self.hw_threads else self.thread_count;

        return @max(self.thread_count, @min(hw, max_threads));
    }

    /// Threads allowed to hash right now, resolved against the thread count.
    pub fn activeCount(self: *const Shared) usize {
        const limit = self.active_threads.load(.acquire);

        return if (limit == 0 or limit > self.thread_count) self.thread_count else limit;
    }

    pub fn setActiveThreads(self: *Shared, n: usize) void {
        self.active_threads.store(n, .release);
    }

    pub fn pause(self: *Shared) void {
        self.paused.store(true, .release);
    }

    pub fn unpause(self: *Shared) void {
        self.paused.store(false, .release);
    }

    pub fn totalHashes(self: *Shared) u64 {
        var total: u64 = 0;
        for (self.hashes[0..self.thread_count]) |*counter| {
            total += counter.value.load(.monotonic);
        }

        return total;
    }
};

fn randomNonceBase() u32 {
    var bytes: [4]u8 = undefined;
    std.crypto.random.bytes(&bytes);

    return std.mem.readInt(u32, &bytes, .little);
}

/// How many retired engines may stay mapped. Two covers the shape a
/// multi-algorithm pool actually produces - the coin it is on and the one it
/// came from - and a third would only be paid for in RAM.
pub const max_retained = 2;

/// An engine that is not hashing but is still mapped, with the seed it holds.
pub const Retained = struct {
    wrapped: api.Wrapped,
    seed: [32]u8 = [_]u8{0} ** 32,
    has_seed: bool = false,
    at_ms: i64 = 0,
    /// What this engine's own dataset cost to build, in ms. Kept per engine
    /// rather than read from `last_seed_ms` at adopt time: on a pool that
    /// rotates, the last build is usually the *other* algorithm's (374 ms for
    /// panthera beside 16 491 ms for rx/0), and quoting the wrong one turns a
    /// measurement into a boast.
    build_ms: u64 = 0,
};

pub const Engine = struct {
    logger: *log.Logger,
    wrapped: ?api.Wrapped = null,
    algo: ?api.Algo = null,
    flags: api.EngineFlags = .{},
    seed: [32]u8 = [_]u8{0} ** 32,
    has_seed: bool = false,
    /// Suppress the "no huge pages" advisory when whoever reserved them has
    /// already said it. Two warnings and two different page counts about the
    /// same problem is how a reader stops trusting the log.
    advise_hugepages: bool = true,

    /// Engines kept mapped after an algorithm switch.
    ///
    /// A pool that moves a rig between RandomX forks - MoneroOcean picks the
    /// coin per job - used to pay a full dataset rebuild every time it moved
    /// back: 20.0 s of zero hashrate on two threads, measured end to end
    /// through a fake pool (rx/0 -> panthera -> rx/0), for a dataset that had
    /// been in memory a minute earlier. Keeping the old engine mapped makes
    /// the return cost nothing.
    ///
    /// It is not free - a retained engine is memory the next one cannot use -
    /// so nothing is retained unless the kernel can hand out the new mapping
    /// on top of it, with the usual 512 MB of slack. A 4 GB box therefore
    /// keeps Panthera's 192 MB and not Monero's 2336 MB, and a 2 GB container
    /// keeps nothing at all: exactly the old behaviour, decided per switch
    /// rather than by a constant.
    retained: [max_retained]?Retained = [_]?Retained{null} ** max_retained,
    retained_bytes: u64 = 0,
    /// `false` for `--no-dataset-cache`, which is also what `--mode=light`
    /// effectively gets: an engine without a dataset is cheap to rebuild.
    cache_enabled: bool = true,
    /// Cap on retained bytes; 0 means "whatever the kernel allows".
    cache_limit_bytes: u64 = 0,
    cache_hits: u64 = 0,
    /// Measured cost of the initialisations this session avoided, in ms, so
    /// the log can say what the cache was worth instead of claiming a win.
    cache_saved_ms: u64 = 0,
    last_seed_ms: u64 = 0,
    /// Every initialisation this process has done, in ms. The monitor reads it
    /// once a second to tell "the rig is idle" from "the rig is building a
    /// dataset", which is the difference between a fault and the cost of a
    /// seed change.
    total_init_ms: u64 = 0,
    /// True while `seedNow` is inside the engine. Written from the mining
    /// thread and read from the monitor thread, so it is atomic; the value in
    /// between is a whole second of attribution either way.
    building: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    const Self = @This();

    pub fn init(logger: *log.Logger, flags: api.EngineFlags) Self {
        return .{ .logger = logger, .flags = flags };
    }

    pub fn deinit(self: *Self) void {
        self.dropRetained();

        if (self.wrapped) |*wrapped| wrapped.destroy();
        self.wrapped = null;
        self.algo = null;
        self.has_seed = false;
    }

    /// Destroys every retained engine. Called on shutdown and when a new
    /// engine needs the room more than the cache does.
    pub fn dropRetained(self: *Self) void {
        for (&self.retained) |*slot| {
            if (slot.*) |*r| {
                r.wrapped.destroy();
                slot.* = null;
            }
        }

        self.retained_bytes = 0;
    }

    fn freeSlot(self: *Self) ?usize {
        for (self.retained, 0..) |slot, i| {
            if (slot == null) return i;
        }

        return null;
    }

    /// May `bytes` stay mapped while another `extra_live` bytes are mapped?
    ///
    /// `bytes` is *already* mapped - it is the engine being retired - so it is
    /// not part of what the kernel has to find: only `extra_live` is. Getting
    /// this backwards is how the first version of this cache refused to keep a
    /// 2336 MB dataset that was in memory at that moment (the check subtracted
    /// it twice and asked for 3 GB of free RAM on a 3.9 GB box).
    /// `extra_live` is 0 when the engine that replaces it is already mapped
    /// too, which is the adopt path: nothing new is allocated at all.
    fn mayRetain(self: *Self, bytes: u64, extra_live: u64) bool {
        return retentionFits(bytes, extra_live, availableMemory(self.flags.huge_pages),
            memory_mod.slack_bytes, self.cache_enabled, self.cache_limit_bytes, self.retained_bytes);
    }

    /// Keeps `wrapped` for a later switch back, or destroys it when it cannot
    /// be afforded. `live_bytes` is the size of the engine that will hash next.
    fn keep(self: *Self, wrapped: api.Wrapped, live_bytes: u64) void {
        var w = wrapped;

        // An engine with no dataset built is a malloc, not 20 seconds: keeping
        // it would spend memory to save nothing.
        if (!self.has_seed or !self.cache_enabled) {
            w.destroy();

            return;
        }

        const bytes = w.totalMemory();

        if (!self.mayRetain(bytes, live_bytes)) {
            self.logger.debug("not keeping the {s} dataset for reuse: {d} MB would not fit beside the next one ({d} MB free)", .{
                w.algo.label(), bytes / (1024 * 1024), availableMemory(self.flags.huge_pages) / (1024 * 1024),
            });
            w.destroy();

            return;
        }

        const slot = self.freeSlot() orelse blk: {
            // Full: the oldest entry is the one least likely to be asked for.
            var oldest: usize = 0;
            for (self.retained, 0..) |r, i| {
                const other = r orelse continue;
                if (other.at_ms < (self.retained[oldest] orelse other).at_ms) oldest = i;
            }

            break :blk oldest;
        };

        if (self.retained[slot]) |*old| {
            self.retained_bytes -= old.wrapped.totalMemory();
            old.wrapped.destroy();
            self.retained[slot] = null;
        }

        self.retained[slot] = .{
            .wrapped = w,
            .seed = self.seed,
            .has_seed = self.has_seed,
            .at_ms = nowMs(),
            .build_ms = self.last_seed_ms,
        };
        self.retained_bytes += bytes;

        self.logger.info("keeping the {s} dataset mapped ({d} MB) so a switch back costs nothing", .{ w.algo.label(), bytes / (1024 * 1024) });
    }

    /// Takes a retained engine that already holds this algorithm and seed.
    /// Returns true when the switch needed no initialisation at all.
    fn adopt(self: *Self, algo: api.Algo, seed_value: [32]u8, has_seed: bool) bool {
        for (self.retained, 0..) |slot, i| {
            const r = slot orelse continue;
            if (r.wrapped.algo != algo) continue;
            if (has_seed and (!r.has_seed or !std.mem.eql(u8, &r.seed, &seed_value))) continue;

            const age_ms = nowMs() - r.at_ms;

            self.retained[i] = null;
            self.retained_bytes -= r.wrapped.totalMemory();

            // The engine being replaced goes into the cache slot it just
            // vacated, subject to the same budget check: on a small box this
            // is where the swap is refused and the old engine is freed.
            // Nothing new is mapped by an adoption, so the displaced engine
            // costs the cache nothing but its own bytes (checked against the
            // cap, not against free memory).
            if (self.wrapped) |current| self.keep(current, 0);

            self.wrapped = r.wrapped;
            self.algo = algo;
            self.seed = r.seed;
            self.has_seed = r.has_seed;
            self.cache_hits += 1;
            self.cache_saved_ms += r.build_ms;

            self.logger.info("switched to {s} without re-initialising: its dataset was still mapped ({d} s old, built in {d} ms, {d} initialisation(s) saved), hash engine ready immediately", .{
                algo.label(), @divTrunc(age_ms, 1000), r.build_ms, self.cache_hits,
            });

            return true;
        }

        return false;
    }

    /// Switches to `algo`, reusing a retained engine when one matches, and
    /// otherwise building a new one. Callers have already stopped the workers:
    /// a worker's VM points into the engine that is about to be replaced.
    pub fn switchTo(self: *Self, algo: api.Algo, seed_value: [32]u8, has_seed: bool, threads: usize) !void {
        if (self.adopt(algo, seed_value, has_seed)) return;

        // A retained engine that cannot be reused is memory the new one needs:
        // dropping it here is what keeps a rig out of light mode when the pool
        // hands it a second Monero-sized variant.
        const need = algo.memoryBytes(self.flags.full_memory);
        if (self.retained_bytes != 0 and availableMemory(self.flags.huge_pages) < need + memory_mod.slack_bytes) {
            self.logger.debug("dropping {d} MB of retained datasets to make room for {s}", .{ self.retained_bytes / (1024 * 1024), algo.label() });
            self.dropRetained();
        }

        if (self.wrapped) |current| {
            self.logger.info("switching algorithm to {s}, re-initialising the dataset", .{algo.label()});
            self.wrapped = null;
            self.algo = null;
            self.keep(current, need);
        }

        try self.create(algo);

        if (has_seed) try self.seedNow(seed_value, threads);
    }

    /// What a job needs from the engine, so the caller knows whether anything
    /// has to happen at all - and whether the threads have to be restarted.
    pub const Change = enum {
        /// Same algorithm, same seed: publish the job and keep hashing.
        none,
        /// Same algorithm, new seed: rebuild the cache in place.
        seed,
        /// Different algorithm: switch engines (possibly for free).
        engine,
    };

    pub fn plan(self: *const Self, algo_value: api.Algo, seed_value: [32]u8, has_seed: bool) Change {
        if (self.wrapped == null or self.algo == null) return .engine;
        if (self.algo.? != algo_value) return .engine;

        return if (self.needsSeed(seed_value, has_seed)) .seed else .none;
    }

    /// Creates the engine for `algo`. A pool can switch us between RandomX
    /// forks at any time and each fork has its own cache/dataset
    /// configuration; `switchTo` is what decides whether an existing engine
    /// can be reused first.
    pub fn create(self: *Self, algo: api.Algo) !void {
        var flags = self.flags;
        const wrapped = api.Wrapped.create(algo, flags) catch |e| blk: {
            if (flags.full_memory) {
                self.logger.warn("cannot allocate the {s} dataset ({s}), falling back to light mode", .{ algo.label(), @errorName(e) });
                flags.full_memory = false;

                break :blk api.Wrapped.create(algo, flags) catch |e2| {
                    self.logger.err("cannot create the {s} hash engine: {s}", .{ algo.label(), @errorName(e2) });

                    return error.EngineInitFailed;
                };
            }

            self.logger.err("cannot create the {s} hash engine: {s}", .{ algo.label(), @errorName(e) });

            return error.EngineInitFailed;
        };

        var cache_buf: [24]u8 = undefined;
        var dataset_buf: [24]u8 = undefined;
        var huge_buf: [32]u8 = undefined;

        const huge_explicit = wrapped.hugePageBytes();
        const huge_total = wrapped.hugePageBytesTotal();

        // Say what the kernel actually gave us. "huge pages 2336 MB" while
        // running on 4 KiB pages is worse than no report at all: it hides a
        // measured 24% hashrate loss on the validation host.
        // A 1 GiB mapping and a 2 MiB mapping both report "explicit", and they
        // are not the same thing: 2080 MB of dataset is 1 040 TLB entries at
        // 2 MiB and one at 1 GiB. The page size is the useful half of the line.
        const page_kb = wrapped.hugePageKb();
        const huge_kind = if (page_kb >= 1024 * 1024)
            "explicit, 1 GiB pages"
        else if (page_kb != 0)
            "explicit, 2 MiB pages"
        else
            "explicit";

        const huge_text = if (huge_total == 0)
            std.fmt.bufPrint(&huge_buf, "off", .{}) catch "off"
        else if (huge_explicit == huge_total)
            std.fmt.bufPrint(&huge_buf, "{d} MB ({s})", .{ huge_explicit / (1024 * 1024), huge_kind }) catch "?"
        else if (huge_explicit == 0)
            std.fmt.bufPrint(&huge_buf, "0 MB (THP fallback)", .{}) catch "?"
        else
            std.fmt.bufPrint(&huge_buf, "{d}/{d} MB (partial)", .{ huge_explicit / (1024 * 1024), huge_total / (1024 * 1024) }) catch "?";

        self.logger.info("hash engine ready: {s}, cache {s}, dataset {s}, huge pages {s}", .{
            algo.label(),
            std.fmt.bufPrint(&cache_buf, "{d} MB", .{wrapped.cacheSize() / (1024 * 1024)}) catch "?",
            std.fmt.bufPrint(&dataset_buf, "{d} MB", .{wrapped.datasetSize() / (1024 * 1024)}) catch "?",
            huge_text,
        });

        if (self.advise_hugepages and huge_total != 0 and huge_explicit != huge_total) {
            // Not having *reserved* pages is only a problem when transparent
            // huge pages are off as well. With THP in `madvise` (or `always`)
            // the mapping still comes back in 2 MiB pages, and the difference
            // between that and the reserved pool is small; the difference
            // between a 2 MiB page and a 4 KiB page is not - 1088-1095 H/s
            // against 892-900 H/s on the validation host, measured 2026-11-07
            // by alternating THP on and off in one session, because that box
            // moves by 20 % between hours and a back-to-back pair is worth
            // nothing. An earlier back-to-back pair read 800.6 against 614.8
            // and put this warning at 28 %.
            switch (hugepages_mod.thp()) {
                .never, .unknown => {
                    const need_pages = (huge_total + (2 * 1024 * 1024) - 1) / (2 * 1024 * 1024);

                    self.logger.warn("transparent huge pages are {s} and no huge pages are reserved: RandomX will read 4 KiB pages, ~18% slower (measured 892-900 H/s against 1088-1095 H/s, alternating, on 2 vCPU; and 771 against 936 on the CI sandbox)", .{hugepages_mod.thp().label()});
                    self.logger.warn("fix it once as root: echo {d} > /proc/sys/vm/nr_hugepages, or boot with transparent_hugepage=madvise (sudo zmrig-tune does both)", .{need_pages});
                },
                .always, .madvise => {},
            }
        }

        self.wrapped = wrapped;
        self.algo = algo;
        self.has_seed = false;
    }

    /// Creates the engine if there is none. Used at startup, before any job.
    pub fn ensure(self: *Self, algo: api.Algo) !void {
        if (self.wrapped != null and self.algo != null and self.algo.? == algo) return;

        try self.switchTo(algo, [_]u8{0} ** 32, false, 1);
    }

    /// True when `algo` would need a different engine (not created yet, or a
    /// different RandomX variant). Rebuilding while workers hold VMs from the
    /// old engine is a use-after-free, so callers stop the threads first.
    pub fn needsAlgo(self: *const Self, algo_value: api.Algo) bool {
        if (self.wrapped == null or self.algo == null) return true;

        return self.algo.? != algo_value;
    }

    pub fn needsSeed(self: *const Self, seed_value: [32]u8, has_seed: bool) bool {
        if (!has_seed) return false;
        if (!self.has_seed) return true;

        return !std.mem.eql(u8, &self.seed, &seed_value);
    }

    pub fn seedNow(self: *Self, seed_value: [32]u8, threads: usize) !void {
        if (self.wrapped) |*wrapped| {
            const started = nowMs();

            self.logger.info("initialising the dataset ({d} threads)", .{threads});
            self.building.store(true, .release);
            defer self.building.store(false, .release);

            try wrapped.seed(&seed_value, threads);

            self.seed = seed_value;
            self.has_seed = true;
            self.last_seed_ms = @intCast(@max(nowMs() - started, 0));
            self.total_init_ms += self.last_seed_ms;

            self.logger.info("dataset ready in {d} ms", .{nowMs() - started});

            // "huge pages 0 MB (THP fallback)" is a claim about intent. Once
            // the dataset has been written, the kernel's own count of pages it
            // actually collapsed is available, and it is the only number that
            // describes how the next hour of hashing will go.
            self.reportHugePages(wrapped);
        }
    }

    /// One line, after the dataset exists, saying how much of this process's
    /// memory really is on 2 MiB pages - from the kernel, not from us.
    fn reportHugePages(self: *Self, wrapped: *api.Wrapped) void {
        const explicit = wrapped.hugePageBytes();
        const total = wrapped.hugePageBytesTotal();
        if (total == 0) return;

        // The reserved pool is exact; THP is a process-wide figure that also
        // counts the scratchpads, so it is compared as a share and never
        // presented as the mapping size.
        if (explicit == total) {
            self.logger.info("huge pages: {d} MB of {d} MB came from the reserved pool", .{ explicit / (1024 * 1024), total / (1024 * 1024) });

            return;
        }

        const thp_bytes = hugepages_mod.anonymousHugeBytes();
        if (thp_bytes == 0) {
            self.logger.warn("huge pages: the kernel has collapsed none of the {d} MB mapping; every dataset read is a TLB miss (see the note above)", .{total / (1024 * 1024)});

            return;
        }

        const share = @min(thp_bytes, total) * 100 / total;

        self.logger.info("huge pages: {d} MB via THP ({d}% of the {d} MB mapping, measured by the kernel)", .{
            (@min(thp_bytes, total)) / (1024 * 1024),
            share,
            total / (1024 * 1024),
        });
    }

    /// Re-asserts this engine's algorithm as the process-wide RandomX
    /// configuration. Required before the workers start, because an engine that
    /// was retained across a switch is not the one that was created last - and
    /// the configuration is global, not per engine.
    pub fn activate(self: *Self) void {
        if (self.wrapped) |*wrapped| wrapped.activate();
    }

    pub fn createVm(self: *Self) !*api.Vm {
        const wrapped = if (self.wrapped) |*w| w else return error.EngineNotReady;

        return wrapped.createVm(self.flags.huge_pages);
    }
};

/// Samples the cumulative hash counter and reports 10s/60s/15m averages.
pub const Stats = struct {
    /// One sample per second, and enough of them to cover the longest window
    /// plus a margin: 1024 samples is 17 minutes, so `rate(900)` is a real
    /// 15-minute average instead of "whatever history happens to exist".
    /// 512 samples (8.5 min) meant the 15-minute column was silently an
    /// 8-minute number, which looks like a stable hashrate that never was.
    samples: [1024]Sample = undefined,
    count: usize = 0,
    head: usize = 0,
    max_rate: f64 = 0,

    pub const Sample = struct {
        time_ms: i64 = 0,
        hashes: u64 = 0,
    };

    pub fn add(self: *Stats, hashes: u64) void {
        const sample = Sample{ .time_ms = nowMs(), .hashes = hashes };

        if (self.count < self.samples.len) {
            self.samples[self.count] = sample;
            self.count += 1;
        } else {
            self.samples[self.head % self.samples.len] = sample;
        }

        self.head += 1;
    }

    /// Average rate over the last `window_seconds`, using the closest sample
    /// that is at least that old (or the oldest one we have).
    /// Records the current 60 s rate as the session maximum.
    pub fn updateMax(self: *Stats) void {
        const current = self.rate(60);
        if (current > self.max_rate) self.max_rate = current;
    }

    pub fn rate(self: *Stats, window_seconds: u64) f64 {
        if (self.head < 2) return 0;

        const newest_index = (self.head - 1) % self.samples.len;
        const newest = self.samples[newest_index];
        const target_ms = newest.time_ms - @as(i64, @intCast(window_seconds)) * 1000;

        var best: Sample = newest;
        var i: usize = 2;
        const available = @min(self.head, self.samples.len);

        while (i <= available) : (i += 1) {
            const index = (self.head - i) % self.samples.len;
            const sample = self.samples[index];

            best = sample;
            if (sample.time_ms <= target_ms) break;
        }

        const elapsed_ms = newest.time_ms - best.time_ms;
        if (elapsed_ms <= 0) return 0;

        const delta = newest.hashes -| best.hashes;

        return @as(f64, @floatFromInt(delta)) * 1000.0 / @as(f64, @floatFromInt(elapsed_ms));
    }
};

/// Where the wall clock went.
///
/// The hashrate line answers "how fast am I hashing" and says nothing about
/// "how much of the last hour was I hashing at all". Those are different
/// numbers, and the second one decides the payout: a rig that hashes at
/// 1 000 H/s for 60 % of the day earns 60 % of what the same rig earns at
/// 100 %, and a healthy-looking speed line hides it perfectly.
///
/// The monitor thread already samples the hash counter once a second. This adds
/// one question to that sample - did the number move, and if not, why not - and
/// keeps the answer for both the exit summary and the "this rig is only hashing
/// half the time" warning.
pub const Duty = struct {
    /// One sample per second, most recent last. 120 s covers the minute a
    /// person looks at, with enough margin to survive a couple of missed ticks.
    const window = 120;

    pub const Sample = enum(u2) {
        /// Nothing was hashing and nothing explains it: no job yet, the pool is
        /// gone, a reconnect is in flight.
        idle = 0,
        hashing = 1,
        /// The engine was building a dataset: 16.5 s for Monero, measured, and
        /// unavoidable on a seed change.
        building = 2,
        /// The thermal governor had parked a thread on purpose.
        throttled = 3,
    };

    flags: [window]Sample = [_]Sample{.idle} ** window,
    next: usize = 0,

    last_ms: i64 = 0,
    last_hashes: u64 = 0,

    /// Wall clock since the first tick, and the part of it that produced hashes.
    total_ms: i64 = 0,
    hashing_ms: i64 = 0,
    /// Parked by the governor. A decision, not a fault, and reported as its own
    /// thing rather than as time the rig was idle.
    throttled_ms: i64 = 0,

    pub fn init(now_ms: i64) Duty {
        return .{ .last_ms = now_ms };
    }

    /// One second of evidence. `elapsed` is real time, not the nominal second:
    /// a monitor thread starved for 3 s (a fork, a stall) must not turn into
    /// three seconds of hashing it did not do.
    ///
    /// `building` and `parked` come from the sampler, which knows what the
    /// engine and the governor were doing at that instant. They only matter
    /// when nothing hashed.
    pub fn tick(self: *Duty, now_ms: i64, hashes: u64, building: bool, parked: bool) void {
        if (self.last_ms == 0) {
            self.last_ms = now_ms;
            self.last_hashes = hashes;

            return;
        }

        const elapsed = now_ms - self.last_ms;
        if (elapsed <= 0) return;

        const sample: Sample = if (hashes > self.last_hashes)
            .hashing
        else if (building)
            .building
        else if (parked)
            .throttled
        else
            .idle;

        self.total_ms += elapsed;
        switch (sample) {
            .hashing => self.hashing_ms += elapsed,
            .throttled => self.throttled_ms += elapsed,
            else => {},
        }

        self.flags[self.next % window] = sample;
        self.next += 1;

        self.last_ms = now_ms;
        self.last_hashes = hashes;
    }

    fn countRecent(self: *const Duty, seconds: usize, sample: Sample) usize {
        const have = @min(@min(seconds, window), self.next);
        if (have == 0) return 0;

        var n: usize = 0;
        var i: usize = 0;
        while (i < have) : (i += 1) {
            const index = (self.next + window - 1 - i) % window;
            if (self.flags[index] == sample) n += 1;
        }

        return n;
    }

    /// Fraction of the last `seconds` that was hashing, 0..1. The denominator
    /// is how many samples exist, not `seconds`: at startup there are none, and
    /// "0 % of the last minute" for a process that is 4 s old would be a lie in
    /// the direction that makes people worry.
    pub fn recent(self: *const Duty, seconds: usize) f64 {
        const have = @min(@min(seconds, window), self.next);
        if (have == 0) return 0;

        return @as(f64, @floatFromInt(self.countRecent(seconds, .hashing))) / @as(f64, @floatFromInt(have));
    }

    pub fn recentBuilding(self: *const Duty, seconds: usize) usize {
        return self.countRecent(seconds, .building);
    }

    pub fn recentIdle(self: *const Duty, seconds: usize) usize {
        return self.countRecent(seconds, .idle);
    }

    pub fn recentThrottled(self: *const Duty, seconds: usize) usize {
        return self.countRecent(seconds, .throttled);
    }

    pub fn overall(self: *const Duty) f64 {
        if (self.total_ms <= 0) return 0;

        return @as(f64, @floatFromInt(self.hashing_ms)) / @as(f64, @floatFromInt(self.total_ms));
    }
};

pub const Worker = struct {
    shared: *Shared,
    engine: *Engine,
    submitter: *Submitter,
    logger: *log.Logger,
    index: usize,
    cpu: ?usize = null,
    thread: ?std.Thread = null,
};

pub const Miner = struct {
    logger: *log.Logger,
    shared: Shared = .{},
    engine: Engine,
    submitter: Submitter = .{},
    stats: Stats = .{},
    /// Where the session's wall clock went. Sampled by the monitor thread.
    duty: Duty = .{},
    workers: [max_threads]Worker = undefined,
    hw_threads: usize = 1,
    affinity: bool = true,
    /// `--cpu-affinity` bitmask: thread i is pinned to the i-th set bit.
    affinity_mask: ?u64 = null,
    /// The CPUs this run should use, best first, from the topology map: one
    /// per physical core, sockets interleaved, SMT siblings last. Thread i
    /// takes `cpu_order[i]`. Empty means "fall back to i % hw_threads".
    cpu_order: [max_threads]usize = undefined,
    cpu_order_len: usize = 0,
    started: bool = false,

    const Self = @This();

    pub fn init(logger: *log.Logger, opts: *const options.Options) !Self {
        const hw_threads = cpuCount();

        // These are process-wide engine settings and must be in place before
        // the first cache is built (the JIT bakes them into the program).
        api.xmo_set_scratchpad_prefetch(opts.scratchpad_prefetch);
        api.xmo_set_huge_pages_jit(@intFromBool(opts.huge_pages_jit));
        api.xmo_set_optimized_dataset_init(@intFromBool(opts.optimized_init));

        var flags = api.EngineFlags{
            .huge_pages = opts.huge_pages,
            .huge_pages_jit = opts.huge_pages_jit,
            .full_memory = opts.mode != .light,
            .jit = opts.jit,
        };

        if (opts.mode == .auto) {
            // Fast mode is chosen per algorithm, because the algorithms are not
            // the same size: Monero needs 2336 MiB, Panthera 192 MiB. A 1 GiB
            // VPS can hash Scala through a 2 MiB-page dataset and cannot hash
            // Monero that way at all, and the old fixed 3 GiB threshold sent
            // both of them into light mode.
            const algo = opts.algo orelse .rx_0;
            const sizes = memory_mod.Sizes{ .cache = algo.cacheBytes(), .dataset = algo.datasetBytes() };
            const need = sizes.total() + memory_mod.slack_bytes;
            // MemTotal is what the machine has, not what this process can get.
            // A 4 GB box already running a database has 4 GB of MemTotal and
            // maybe 1.5 GB left; deciding from MemTotal mapped the 2 GiB
            // dataset anyway, which is how a rig ends up OOM-killed (or in the
            // 10x slower light mode after the allocation is refused) instead
            // of being told, at startup, that it does not fit.
            const usable = usableMemory();
            flags.full_memory = memory_mod.fullMemory(sizes, .auto, usable);
            if (!flags.full_memory) {
                if (memoryBudget()) |budget| {
                    // Naming the limit is the difference between "my rig is
                    // broken" and "someone gave this container 1 GB".
                    logger.warn("this container is limited to {d} MB of memory by its cgroup ({d} MB left), which is less than the dataset needs", .{
                        budget.limit / (1024 * 1024), budget.available / (1024 * 1024),
                    });
                }
                logger.warn("{s} needs {d} MB and this machine has {d} MB usable, starting in light mode: {d} MB cache, no dataset", .{
                    algo.label(),
                    need / (1024 * 1024),
                    usable / (1024 * 1024),
                    algo.cacheBytes() / (1024 * 1024),
                });
                logger.warn("light mode rebuilds every dataset line on demand - about 10x slower than fast mode (82 H/s against 857 H/s on 2 cores) - close what is using the RAM and restart", .{});
            }
        }

        const threads = opts.threads orelse defaultThreads(hw_threads);
        if (threads == 0 or threads > max_threads) {
            logger.err("invalid thread count {d} (1..{d})", .{ threads, max_threads });

            return error.InvalidThreads;
        }

        var miner = Self{
            .logger = logger,
            .engine = blk: {
                var engine = Engine.init(logger, flags);
                // `--dataset-cache=0` disables it; anything else is the cap in
                // MB; unset is "whatever the kernel allows at the moment the
                // switch happens", which is the only number that is still true
                // by then. Light mode keeps nothing: there is no dataset to keep.
                engine.cache_enabled = (opts.dataset_cache_mb orelse 1) != 0 and flags.full_memory;
                engine.cache_limit_bytes = (opts.dataset_cache_mb orelse 0) * 1024 * 1024;
                // The reservation itself happens in main.zig, before the engine
                // exists (autoReserveHugePages). This flag only gates the
                // warning the engine prints when the mapping came back small,
                // and it is on by default: the measurement after seeding is the
                // line that explains a slow rig.
                engine.advise_hugepages = opts.huge_pages;
                break :blk engine;
            },
            .hw_threads = hw_threads,
            .affinity = opts.affinity,
            .affinity_mask = opts.affinity_mask,
        };

        // Order the CPUs before the threads start: thread i must land on a
        // distinct physical core before it lands on an SMT sibling, and on a
        // dual socket machine it must spread before it doubles up. Pinning
        // `i % hw_threads` is wrong on AMD, where siblings are adjacent.
        var cpus_buf: [256]topology.Cpu = undefined;
        const cpus = topology.cpuMap(&cpus_buf);
        const profile: topology.Profile = switch (opts.profile) {
            .watt => .watt,
            .free, .auto => .free,
        };
        const order = topology.selectCpus(profile, cpus, &miner.cpu_order);
        miner.cpu_order_len = @min(order.len, miner.cpu_order.len);

        miner.shared.thread_count = threads;
        miner.shared.hw_threads = hw_threads;
        miner.shared.init_threads = opts.init_threads;
        miner.shared.priority = opts.priority;

        return miner;
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.engine.deinit();
    }

    pub fn threadCount(self: *const Self) usize {
        return self.shared.thread_count;
    }

    /// Threads the governor is letting hash right now. Equal to `threadCount`
    /// unless a thermal policy parked some of them, which is why the report
    /// carries both: "8 threads, 5 allowed" is a different machine from
    /// "8 threads".
    pub fn activeCount(self: *const Self) usize {
        return self.shared.activeCount();
    }

    /// Huge page usage as [allocated, total] in 2 MiB pages, for the API.
    /// `allocated` counts only pages the kernel really gave us.
    pub fn hugePages(self: *const Self) [2]usize {
        const page = 2 * 1024 * 1024;

        if (self.engine.wrapped) |wrapped| {
            return .{ wrapped.hugePageBytes() / page, wrapped.totalMemory() / page };
        }

        return .{ 0, 0 };
    }

    /// Which core a worker should be pinned to: the i-th bit of
    /// `--cpu-affinity`, else the topology order, else thread i modulo the
    /// core count.
    fn cpuFor(self: *const Self, index: usize) ?usize {
        if (!self.affinity) return null;

        if (self.affinity_mask) |mask| {
            var seen: usize = 0;
            for (0..64) |bit| {
                if (mask & (@as(u64, 1) << @intCast(bit)) == 0) continue;
                if (seen == index) return bit;
                seen += 1;
            }
            // More threads than bits: wrap around the allowed cores.
            return if (seen == 0) null else self.cpuFor(index % seen);
        }

        // The topology order handles SMT and sockets; the modulo is only the
        // fallback for a machine that reported no topology at all.
        if (self.cpu_order_len > 0) return self.cpu_order[index % self.cpu_order_len];

        return if (self.hw_threads > 0) index % self.hw_threads else null;
    }

    /// The CPUs this run will actually hash on, for `--check` and the log.
    pub fn cpuList(self: *const Self, out: []usize) []usize {
        const n = @min(self.thread_count(), out.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            out[i] = self.cpuFor(i) orelse i;
        }

        return out[0..n];
    }

    /// CPUs listed in an affinity mask, for logging and `--check`.
    pub fn affinityCpus(mask: u64) usize {
        return @popCount(mask);
    }

    pub fn start(self: *Self) !void {
        if (self.started) return;

        // Nothing is hashing right now (threads are joined by the caller), so
        // this is the one place where the process-wide RandomX configuration
        // can be pointed at the engine that is about to run.
        self.engine.activate();

        self.shared.running.store(true, .release);
        self.started = true;

        for (0..self.shared.thread_count) |i| {
            self.workers[i] = .{
                .shared = &self.shared,
                .engine = &self.engine,
                .submitter = &self.submitter,
                .logger = self.logger,
                .index = i,
                .cpu = self.cpuFor(i),
            };

            self.workers[i].thread = std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, workerMain, .{&self.workers[i]}) catch |e| {
                self.logger.err("cannot spawn thread {d}: {s}", .{ i, @errorName(e) });

                return error.ThreadSpawnFailed;
            };
        }

        self.logger.info("mining with {d} thread(s) out of {d} hardware threads", .{ self.shared.thread_count, self.hw_threads });
    }

    pub fn stop(self: *Self) void {
        if (!self.started) return;

        self.shared.running.store(false, .release);

        for (self.workers[0..self.shared.thread_count]) |*worker| {
            if (worker.thread) |thread| {
                thread.join();
                worker.thread = null;
            }
        }

        self.started = false;
    }

    /// Applies a job from the pool: rebuilds the engine when the algorithm or
    /// the seed changed, (re)starts the workers and publishes the job.
    ///
    /// Threads are *joined*, not paused, before the cache or the dataset is
    /// touched: a worker holds a VM that points into that memory, so pausing it
    /// and re-initialising underneath is a use-after-free (it segfaulted on the
    /// first rx/0 -> rx/wow switch during the soak test).
    pub fn applyJob(self: *Self, new_job: *job_mod.Job) !void {
        switch (self.engine.plan(new_job.algo, new_job.seed, new_job.has_seed)) {
            .none => {},
            .seed => {
                self.stop();
                try self.engine.seedNow(new_job.seed, self.shared.initThreads());
                try self.start();
            },
            .engine => {
                self.stop();
                // `switchTo` may find a retained engine that already holds this
                // algorithm and seed, in which case this costs a pointer swap
                // instead of the 20 s a Monero dataset takes to build.
                try self.engine.switchTo(new_job.algo, new_job.seed, new_job.has_seed, self.shared.initThreads());
                try self.start();
            },
        }

        if (!self.started) try self.start();

        return self.publishJob(new_job);
    }

    fn publishJob(self: *Self, new_job: *job_mod.Job) void {
        // Always unpause: a previous applyJob may have left the workers paused,
        // and a job whose seed did not change would never wake them up (the rig
        // used to sit at 0 H/s after a reconnect because of exactly that).
        self.shared.unpause();
        self.shared.publish(new_job);
    }

    /// One sample of `Duty`. Called from the monitor thread once a second, next
    /// to the hash-counter sample it already takes.
    pub fn tickDuty(self: *Self, now_ms: i64) void {
        if (self.duty.last_ms == 0) {
            self.duty = Duty.init(now_ms);

            return;
        }

        // `active_threads == 0` means "all of them"; anything smaller is the
        // thermal governor holding threads back on purpose.
        const active = self.shared.active_threads.load(.acquire);
        const parked = active != 0 and active < self.shared.thread_count;

        self.duty.tick(now_ms, self.shared.totalHashes(), self.engine.building.load(.acquire), parked);
    }

    pub fn hashrate(self: *Self, window_seconds: u64) f64 {
        return self.stats.rate(window_seconds);
    }

    /// What the session's clock was spent on, in one line. Writes into `buf`
    /// and returns the slice: the caller owns the storage, this owns the words.
    ///
    /// "hashing 282 s of 300 s (94.0 %): 16 s building a dataset, 2 s without a
    /// job" - the breakdown is only as long as it has something to say, so a
    /// perfect run reads "100.0 %: nothing was lost".
    pub fn describeDuty(self: *const Self, buf: []u8) []const u8 {
        var tail: [192]u8 = undefined;
        var tail_stream = std.io.fixedBufferStream(&tail);
        const tw = tail_stream.writer();

        const total_ms = self.duty.total_ms;
        const hashing_s = @divTrunc(self.duty.hashing_ms, 1000);
        const building_s = @divTrunc(@as(i64, @intCast(self.engine.total_init_ms)), 1000);
        const throttled_s = @divTrunc(self.duty.throttled_ms, 1000);
        // Everything that was neither hashing, nor a dataset build, nor the
        // governor: no job, a lost pool, a reconnect in flight. Floored, because
        // the two sources are sampled at different moments.
        const quiet_s = @max(@divTrunc(total_ms, 1000) - hashing_s - building_s - throttled_s, 0);

        var any = false;
        if (building_s > 0) {
            tw.print("{d} s building a dataset", .{building_s}) catch {};
            any = true;
        }
        if (throttled_s > 0) {
            if (any) tw.writeAll(", ") catch {};
            tw.print("{d} s throttled (--max-temp)", .{throttled_s}) catch {};
            any = true;
        }
        if (quiet_s > 0) {
            if (any) tw.writeAll(", ") catch {};
            tw.print("{d} s without a job or reconnecting", .{quiet_s}) catch {};
            any = true;
        }

        var stream = std.io.fixedBufferStream(buf);
        const w = stream.writer();

        if (!any) {
            w.print("hashing {d} s of {d} s ({d:.1} %): nothing was lost", .{
                hashing_s, @divTrunc(total_ms, 1000), self.duty.overall() * 100.0,
            }) catch {};
        } else {
            w.print("hashing {d} s of {d} s ({d:.1} %): {s}", .{
                hashing_s, @divTrunc(total_ms, 1000), self.duty.overall() * 100.0, tail_stream.getWritten(),
            }) catch {};
        }

        return stream.getWritten();
    }

    /// Prints the periodic hashrate line and, when verbose, per-thread rates.
    pub fn report(self: *Self) void {
        const total = self.shared.totalHashes();
        self.stats.add(total);
        self.stats.updateMax();

        var buf_10: [32]u8 = undefined;
        var buf_60: [32]u8 = undefined;
        var buf_15m: [32]u8 = undefined;
        var buf_max: [32]u8 = undefined;

        // Same shape as XMRig's line so existing log parsers keep working:
        // speed 10s/60s/15m <a> <b> <c> H/s max <d> H/s
        self.logger.info("speed 10s/60s/15m {s} {s} {s} H/s max {s} H/s", .{
            formatRate(&buf_10, self.stats.rate(10)),
            formatRate(&buf_60, self.stats.rate(60)),
            formatRate(&buf_15m, self.stats.rate(900)),
            formatRate(&buf_max, self.stats.max_rate),
        });
    }
};

fn formatRate(buf: []u8, rate: f64) []const u8 {
    return std.fmt.bufPrint(buf, "{d:.1}", .{rate}) catch "?";
}

fn workerMain(worker: *Worker) void {
    const shared = worker.shared;

    // nice is per-thread on Linux, so the worker sets it for itself.
    applyPriority(shared.priority);

    if (worker.cpu) |cpu| pinToCpu(cpu);

    const vm = worker.engine.createVm() catch |e| {
        worker.logger.err("thread {d}: cannot create a VM: {s}", .{ worker.index, @errorName(e) });

        return;
    };
    defer api.xmo_vm_free(vm);

    var local_job = job_mod.Job{};
    var last_generation: u64 = 0;
    var nonce: u32 = 0;
    var prev_nonce: u32 = 0;
    var rounds: u32 = 0;
    var temp: [8]u64 align(64) = undefined;
    // RandomX writes the final digest with SIMD stores; keep the destination
    // aligned so that never becomes an unaligned-access fault.
    var hash: [32]u8 align(64) = undefined;

    while (shared.running.load(.acquire)) {
        const generation = shared.generation.load(.acquire);

        if (shared.paused.load(.acquire)) {
            std.time.sleep(5 * std.time.ns_per_ms);
            continue;
        }

        // Thermal gate. Checked once per hash: a RandomX hash is measured in
        // milliseconds, so this costs nothing measurable and the reaction to a
        // hot sensor is one hash, not one job.
        if (shared.activeCount() <= worker.index) {
            std.time.sleep(20 * std.time.ns_per_ms);
            continue;
        }

        if (generation != last_generation) {
            shared.job_mutex.lock();
            local_job = shared.job;
            shared.job_mutex.unlock();

            last_generation = generation;
            rounds = 0;
            nonce = shared.next_nonce.fetchAdd(nonce_chunk, .monotonic);
            prev_nonce = nonce;

            local_job.setNonce(nonce);
            api.xmo_hash_first(vm, local_job.blobSlice().ptr, local_job.blob_len, &temp);
            continue;
        }

        rounds +%= 1;

        if ((rounds & (nonce_chunk - 1)) == 0) {
            nonce = shared.next_nonce.fetchAdd(nonce_chunk, .monotonic);
        } else {
            nonce +%= 1;
        }

        local_job.setNonce(nonce);
        api.xmo_hash_next(vm, &temp, local_job.blobSlice().ptr, local_job.blob_len, &hash);

        _ = shared.hashes[worker.index].value.fetchAdd(1, .monotonic);

        // The benchmark stop condition is checked once per 64 hashes, not once
        // per hash: `totalHashes()` sums one atomic per thread, and a 32-core
        // box was doing 32 cross-line atomic loads for every hash it produced
        // -- in the benchmark, which is where numbers get compared. Overshoot
        // is bounded by 63 hashes out of billions.
        if ((rounds & 63) == 0 and shared.bench_limit.load(.monotonic) != 0) {
            const limit = shared.bench_limit.load(.monotonic);
            if (shared.totalHashes() >= limit) {
                shared.running.store(false, .release);

                return;
            }
        }

        // RandomX's pipelined API: `hash_next` returns the digest of the input
        // given to the *previous* call (the nonce patched into the blob before
        // it) and starts hashing the new one into `temp`. So the digest in
        // `hash` belongs to `prev_nonce`, not to `nonce`; submitting `nonce`
        // here would hand the pool a hash that does not match its nonce.
        if (local_job.hashMeetsTarget(&hash)) {
            var share = Share{ .nonce = prev_nonce, .hash = hash, .height = local_job.height, .algo = local_job.algo };
            const id = local_job.idSlice();
            share.job_id_len = id.len;
            @memcpy(share.job_id[0..id.len], id);

            worker.submitter.submit(&share, worker.logger);
        }

        prev_nonce = nonce;
    }
}

pub fn cpuCount() usize {
    const count = std.Thread.getCpuCount() catch 1;

    return @max(count, 1);
}

/// XMRig's RandomX default: one thread per 2 MiB of L3 cache, capped by the
/// number of hardware threads.
pub fn defaultThreads(hw_threads: usize) usize {
    const l3 = l3CacheSize() orelse return hw_threads;
    const by_cache = l3 / (2 * 1024 * 1024);

    if (by_cache == 0) return 1;

    return @max(@min(by_cache, hw_threads), 1);
}

pub fn l3CacheSize() ?usize {
    const path = "/sys/devices/system/cpu/cpu0/cache/index3/size";
    var buf: [32]u8 = undefined;

    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    const n = file.readAll(&buf) catch return null;
    const text = std.mem.trim(u8, buf[0..n], " \n\r");

    if (text.len == 0) return null;

    var multiplier: usize = 1;
    var digits = text;

    switch (text[text.len - 1]) {
        'K', 'k' => {
            multiplier = 1024;
            digits = text[0 .. text.len - 1];
        },
        'M', 'm' => {
            multiplier = 1024 * 1024;
            digits = text[0 .. text.len - 1];
        },
        'G', 'g' => {
            multiplier = 1024 * 1024 * 1024;
            digits = text[0 .. text.len - 1];
        },
        else => {},
    }

    const value = std.fmt.parseInt(usize, digits, 10) catch return null;

    return value * multiplier;
}

/// Total RAM in bytes, read from /proc/meminfo (no libc dependency).
pub fn totalMemory() u64 {
    return meminfoBytes("MemTotal:");
}

/// What a new 2 GiB dataset can actually use right now: MemAvailable plus the
/// huge pages that are reserved but not yet handed out (the kernel does not
/// count those as available for ordinary allocations, and the dataset is
/// allocated from exactly those pages).
///
/// In a container this is the *host's* number, so it is capped by the cgroup
/// memory limit when there is one: `/proc/meminfo` is not namespaced, and
/// `docker run --memory=1g` on a 32 GB host used to look like 30 GB of headroom
/// right up to the OOM kill. `usableMemory` is the function to ask.
pub fn memoryForDataset() u64 {
    const available = meminfoBytes("MemAvailable:");
    const free_pages = meminfoValue("HugePages_Free:");
    const page_size = meminfoValue("Hugepagesize:");   // kB per huge page

    return available + free_pages * page_size * 1024;
}

/// The bytes this process can realistically hand to a dataset: the smaller of
/// what the machine reports and what its cgroup limit leaves. The limit is
/// checked first because it is the only one that is still true inside a
/// container, and a dataset that does not fit is an OOM kill during startup,
/// not a warning.
pub fn usableMemory() u64 {
    const machine = @min(totalMemory(), memoryForDataset());
    const budget = topology.cgroupMemory() orelse return machine;

    return @min(machine, budget.available);
}

/// The same question in the other direction: what can be handed out *right
/// now*. `usableMemory` is capped by the machine's size, which is the right
/// number for "will this fit", but it counts the reserved huge page pool as
/// part of the machine - and an ordinary `mmap` cannot use it. A verifier that
/// asked for 2336 MB of anonymous memory on a host where 2336 MB is reserved as
/// huge pages was OOM-killed with every check having said yes.
///
/// This is `MemAvailable` plus the free huge pages, which is what a mapping can
/// actually be given, capped by the cgroup's remainder. `use_huge_pages` is
/// `--no-huge-pages` inverted: a process that has been told not to touch the
/// page pool cannot count it, or the arithmetic says yes and the kernel says
/// no.
pub fn availableMemory(use_huge_pages: bool) u64 {
    const machine = if (use_huge_pages) memoryForDataset() else meminfoBytes("MemAvailable:");
    const budget = topology.cgroupMemory() orelse return machine;

    return @min(machine, budget.available);
}

/// The cgroup limit and what is left of it, for the messages that have to
/// explain the difference between "this machine has 32 GB" and "this container
/// may use 1".
pub fn memoryBudget() ?topology.MemoryBudget {
    return topology.cgroupMemory();
}

fn meminfoValue(comptime field: []const u8) u64 {
    var buf: [4096]u8 = undefined;

    const file = std.fs.openFileAbsolute("/proc/meminfo", .{}) catch return 0;
    defer file.close();

    const n = file.readAll(&buf) catch return 0;
    var lines = std.mem.splitScalar(u8, buf[0..n], '\n');

    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, field)) continue;

        var fields = std.mem.tokenizeAny(u8, line[field.len..], " \t");
        const value = fields.next() orelse return 0;

        return std.fmt.parseInt(u64, value, 10) catch 0;
    }

    return 0;
}

fn meminfoBytes(comptime field: []const u8) u64 {
    var buf: [4096]u8 = undefined;

    const file = std.fs.openFileAbsolute("/proc/meminfo", .{}) catch return 0;
    defer file.close();

    const n = file.readAll(&buf) catch return 0;
    var lines = std.mem.splitScalar(u8, buf[0..n], '\n');

    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, field)) continue;

        var fields = std.mem.tokenizeAny(u8, line[field.len..], " \t");
        const value = fields.next() orelse return 0;

        const kb = std.fmt.parseInt(u64, value, 10) catch return 0;

        return kb * 1024;
    }

    return 0;
}

/// Same mapping oneclick/exmrig use: -1 leaves the thread alone, 0..5 follow
/// XMRig's scale, anything else is a raw nice value.
pub fn applyPriority(priority: i32) void {
    if (priority == -1) return;

    const nice_value: i32 = if (priority >= 0 and priority <= 5) switch (priority) {
        1 => 5,
        2 => 0,
        3 => -5,
        4 => -10,
        5 => -15,
        else => 19,
    } else priority;

    _ = std.os.linux.syscall3(.setpriority, 0, 0, @bitCast(@as(isize, nice_value)));
}

fn pinToCpu(cpu: usize) void {
    var set: std.os.linux.cpu_set_t = std.mem.zeroes(std.os.linux.cpu_set_t);
    const index = cpu / @bitSizeOf(usize);
    const bit = cpu % @bitSizeOf(usize);

    if (index >= set.len) return;

    set[index] |= @as(usize, 1) << @intCast(bit);

    const rc = std.os.linux.syscall3(.sched_setaffinity, 0, @sizeOf(std.os.linux.cpu_set_t), @intFromPtr(&set));
    _ = rc;
}

test "the dataset is built with every CPU, not just the mining threads" {
    const testing = std.testing;

    var shared = Shared{};

    // A rig told to mine with one thread on a 4-CPU box still builds the
    // dataset with all four: 42.9 s against 21.1 s for Monero's 2 GiB on the
    // two-core validation host, and a seed change on a multi-algorithm pool
    // pays that again.
    shared.thread_count = 1;
    shared.hw_threads = 4;
    try testing.expectEqual(@as(usize, 4), shared.initThreads());

    // Mining with more threads than the heuristic chose is not a reason to
    // build with fewer.
    shared.thread_count = 4;
    shared.hw_threads = 4;
    try testing.expectEqual(@as(usize, 4), shared.initThreads());

    // --randomx-init is an explicit instruction and is never second-guessed.
    shared.init_threads = 2;
    try testing.expectEqual(@as(usize, 2), shared.initThreads());

    // No hardware count (a container that cannot read /proc): fall back to the
    // hashing threads rather than dividing by zero.
    shared.init_threads = 0;
    shared.hw_threads = 0;
    shared.thread_count = 3;
    try testing.expectEqual(@as(usize, 3), shared.initThreads());

    // And the ceiling still holds: more CPUs than the worker array can hold
    // must not produce an initialiser that writes past it.
    shared.hw_threads = 4096;
    shared.thread_count = 1;
    try testing.expectEqual(@as(usize, max_threads), shared.initThreads());
}

test "a job decides what the engine has to do, and it is the smallest thing" {
    const testing = std.testing;

    var logger = log.Logger.init(false, false);
    var engine = Engine.init(&logger, .{});

    const seedA = [_]u8{1} ** 32;
    const seedB = [_]u8{2} ** 32;

    // No engine at all: something has to be created.
    try testing.expectEqual(Engine.Change.engine, engine.plan(.rx_0, seedA, true));

    // A fake engine, because what `plan` reads is the algorithm and the seed,
    // not the dataset behind them. Creating a real one is what the network
    // tests do, with a real 2 GiB mapping.
    engine.wrapped = api.Wrapped{ .handle = undefined, .algo = .rx_0, .full_memory = true, .huge_pages = true };
    engine.algo = .rx_0;
    engine.seed = seedA;
    engine.has_seed = true;

    // The common case on a busy pool: a new block, same seed, same coin. It
    // must not stop the workers - a job every 60 s that rebuilt a dataset for
    // nothing would be a 20 % tax on hashrate.
    try testing.expectEqual(Engine.Change.none, engine.plan(.rx_0, seedA, true));

    // Same coin, new seed: the dataset is rebuilt in place, and the mapping is
    // reused rather than freed and allocated again.
    try testing.expectEqual(Engine.Change.seed, engine.plan(.rx_0, seedB, true));

    // A different coin: a different engine, which may or may not be a rebuild
    // (`adopt` decides that, at switch time, from what is still mapped).
    try testing.expectEqual(Engine.Change.engine, engine.plan(.rx_xla, seedA, true));

    // A job with no seed at all - some pools send one - must not be read as
    // "the seed changed" and trigger a rebuild.
    try testing.expectEqual(Engine.Change.none, engine.plan(.rx_0, [_]u8{9} ** 32, false));
}

test "a retained engine is only kept when the kernel can still hand out the next one" {
    const testing = std.testing;

    // The arithmetic, without any memory: `bytes` is already mapped and is not
    // part of what has to be found; `extra_live` is.
    const slack = memory_mod.slack_bytes;

    // Nothing to keep, or caching turned off.
    try testing.expect(!retentionFits(0, 0, 8 * 1024 * 1024 * 1024, slack, true, 0, 0));
    try testing.expect(!retentionFits(1024, 0, 8 * 1024 * 1024 * 1024, slack, false, 0, 0));

    // A 3.9 GB box holding Monero's 2336 MB engine, switching to Panthera's
    // 192 MB one: 1.4 GB free is plenty for 192 MB + slack. This is the case
    // that was rejected by the first version of the check, which subtracted
    // the retained bytes twice and asked for 3 GB of RAM that was already
    // mapped.
    try testing.expect(retentionFits(2336 * 1024 * 1024, 192 * 1024 * 1024,
        1400 * 1024 * 1024, slack, true, 0, 0));

    // The same box switching to Wownero's 2336 MB dataset has nowhere to put
    // it: the two would not both be mapped, so the retained one goes.
    try testing.expect(!retentionFits(2336 * 1024 * 1024, 2336 * 1024 * 1024,
        1400 * 1024 * 1024, slack, true, 0, 0));

    // Adoption maps nothing new, so the only memory question is whether the
    // process is under pressure at all: below the slack the displaced engine is
    // dropped, above it, kept.
    try testing.expect(retentionFits(192 * 1024 * 1024, 0, slack, slack, true, 0, 0));
    try testing.expect(!retentionFits(192 * 1024 * 1024, 0, 0, slack, true, 0, 0));
    // 200 MB already retained against a 300 MB cap: another 192 does not fit,
    // however much RAM the machine has.
    try testing.expect(!retentionFits(192 * 1024 * 1024, 0, 4 * 1024 * 1024 * 1024,
        slack, true, 300 * 1024 * 1024, 200 * 1024 * 1024));

    // An explicit cap is an instruction, not a suggestion.
    try testing.expect(!retentionFits(2336 * 1024 * 1024, 0, 8 * 1024 * 1024 * 1024,
        slack, true, 1024 * 1024 * 1024, 0));
}

/// The decision `Engine.mayRetain` makes, as a pure function so it can be
/// tested on a machine with any amount of RAM and no dataset at all.
pub fn retentionFits(bytes: u64, extra_live: u64, room: u64, slack: u64, enabled: bool, limit: u64, already: u64) bool {
    if (!enabled) return false;
    if (bytes == 0) return false;
    if (limit != 0 and already + bytes > limit) return false;

    return room >= extra_live + slack;
}

test "the duty cycle separates a dataset build from a rig with nothing to do" {
    const testing = std.testing;

    var duty = Duty.init(1000);

    // Six seconds of the dataset being built at startup: the counter has not
    // moved once, and this is not a fault - it is the price of the first job.
    var t: i64 = 1000;
    for (0..6) |_| {
        t += 1000;
        duty.tick(t, 0, true, false);
    }
    try testing.expectEqual(@as(f64, 0), duty.recent(60));
    try testing.expectEqual(@as(usize, 6), duty.recentBuilding(60));
    try testing.expectEqual(@as(usize, 0), duty.recentIdle(60));

    // Then forty seconds of hashing.
    var hashes: u64 = 0;
    for (0..40) |_| {
        t += 1000;
        hashes += 900;
        duty.tick(t, hashes, false, false);
    }
    try testing.expectEqual(@as(f64, 1), duty.recent(40));
    try testing.expectEqual(@as(usize, 0), duty.recentBuilding(40));
    // Over the whole session including the build: 40 of 46 seconds.
    try testing.expect(duty.overall() > 0.86 and duty.overall() < 0.88);

    // The pool goes away: four seconds where nothing moved and nothing
    // explains it. That is the number the warning is about.
    for (0..4) |_| {
        t += 1000;
        duty.tick(t, hashes, false, false);
    }
    try testing.expectEqual(@as(usize, 4), duty.recentIdle(60));
    try testing.expectEqual(@as(f64, 0.8), duty.recent(50));
}

test "a parked worker is throttling, not idling" {
    const testing = std.testing;

    var duty = Duty.init(0);
    var t: i64 = 0;
    var hashes: u64 = 0;

    for (0..10) |_| {
        t += 1000;
        hashes += 900;
        duty.tick(t, hashes, false, false);
    }
    for (0..5) |_| {
        t += 1000;
        duty.tick(t, hashes, false, true);
    }

    try testing.expectEqual(@as(usize, 5), duty.recentThrottled(60));
    try testing.expectEqual(@as(usize, 0), duty.recentIdle(60));
    // The governor did what it was told, so this is not time "without a job".
    try testing.expectEqual(@as(i64, 5000), duty.throttled_ms);
}

test "the duty clock measures the second it was given, not a nominal one" {
    const testing = std.testing;

    var duty = Duty.init(0);

    // A monitor thread that was starved for 3.5 s must not be credited with
    // 3.5 s of hashing from a single sample.
    duty.tick(3500, 0, false, false);
    try testing.expectEqual(@as(i64, 0), duty.total_ms);

    duty.tick(7000, 4000, false, false);
    try testing.expectEqual(@as(i64, 3500), duty.total_ms);
    try testing.expectEqual(@as(i64, 3500), duty.hashing_ms);
    try testing.expectEqual(@as(f64, 1), duty.overall());
}

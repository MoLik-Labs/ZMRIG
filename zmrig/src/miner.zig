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

pub const max_threads = 128;

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

    const Self = @This();

    pub fn init(logger: *log.Logger, flags: api.EngineFlags) Self {
        return .{ .logger = logger, .flags = flags };
    }

    pub fn deinit(self: *Self) void {
        if (self.wrapped) |*wrapped| wrapped.destroy();
        self.wrapped = null;
        self.algo = null;
        self.has_seed = false;
    }

    /// Creates (or recreates) the engine when the algorithm changes. A pool can
    /// switch us between RandomX forks at any time and each fork has its own
    /// cache/dataset configuration.
    pub fn ensure(self: *Self, algo: api.Algo) !void {
        if (self.wrapped != null and self.algo != null and self.algo.? == algo) return;

        if (self.wrapped != null) {
            self.logger.info("switching algorithm to {s}, re-initialising the dataset", .{algo.label()});
            self.deinit();
        }

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

    /// True when `algo` would need a different engine (not created yet, or a
    /// different RandomX variant). Rebuilding while workers hold VMs from the
    /// old engine is a use-after-free, so callers stop the threads first.
    pub fn needsAlgo(self: *const Self, algo_value: api.Algo) bool {
        if (self.wrapped == null or self.algo == null) return true;

        return self.algo.? != algo_value;
    }

    pub fn needsSeed(self: *Self, seed_value: [32]u8, has_seed: bool) bool {
        if (!has_seed) return false;
        if (!self.has_seed) return true;

        return !std.mem.eql(u8, &self.seed, &seed_value);
    }

    pub fn seedNow(self: *Self, seed_value: [32]u8, threads: usize) !void {
        if (self.wrapped) |*wrapped| {
            const started = nowMs();

            self.logger.info("initialising the dataset ({d} threads)", .{threads});
            try wrapped.seed(&seed_value, threads);

            self.seed = seed_value;
            self.has_seed = true;

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
        const needs_algo = self.engine.needsAlgo(new_job.algo);
        const needs_seed = new_job.has_seed and self.engine.needsSeed(new_job.seed, new_job.has_seed);

        if (needs_algo or needs_seed) {
            self.stop();

            if (needs_algo) try self.engine.ensure(new_job.algo);
            if (needs_seed) try self.engine.seedNow(new_job.seed, self.shared.initThreads());

            try self.start();

            return self.publishJob(new_job);
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

    pub fn hashrate(self: *Self, window_seconds: u64) f64 {
        return self.stats.rate(window_seconds);
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

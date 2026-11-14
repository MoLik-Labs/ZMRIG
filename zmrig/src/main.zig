//! zmrig - a RandomX miner written in Zig on top of the RandomX engine shipped
//! in this repository. 3% of Monero mining time goes to the developer wallet
//! (`zmrig/src/fee.zig`), stated in the banner, in `--check` and in the log
//! whenever a fee session opens; `--donate-level=0` turns it off.

const std = @import("std");
const api = @import("api.zig");
const autotune = @import("autotune.zig");
const fee = @import("fee.zig");
const hugepages_mod = @import("hugepages.zig");
const memory_mod = @import("memory.zig");
const job_mod = @import("job.zig");
const log = @import("log.zig");
const miner_mod = @import("miner.zig");
const api_http = @import("api_http.zig");
const options = @import("options.zig");
const report = @import("report.zig");
const stratum = @import("stratum.zig");
const topology = @import("topology.zig");
const health = @import("health.zig");
const thermal = @import("thermal.zig");
const verify = @import("verify.zig");
const wallet = @import("wallet.zig");
const util = @import("util.zig");

pub const version = "6.48.0";

var running = std.atomic.Value(bool).init(true);

fn onSignal(_: c_int) callconv(.C) void {
    running.store(false, .release);
    // Also wake any thread parked in a socket read (login, keepalive reply,
    // a pool that never answers) so shutdown is immediate.
    @import("transport.zig").stop_requested.store(true, .release);
}

/// Printed above the usage text everywhere it appears: `--help`, a bad option
/// and a rejected config. One string, so the author line cannot go stale.
pub const banner =
    "ZMRIG " ++ version ++ " - RandomX miner by @nggkhaiz\n" ++
    // The rate comes from the constant, so a banner that disagrees with the
    // code cannot be compiled. The number this prints is the number
    // `scripts/verify-fee.sh` audits and the number the documentation states.
    std.fmt.comptimePrint("{d}% of Monero mining time goes to the developer (--donate-level=0 turns it off), GPL-3.0, https://github.com/MoLik-Labs/ZMRIG\n", .{@import("fee.zig").default_percent});

fn installSignalHandlers() void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };

    std.posix.sigaction(std.posix.SIG.INT, &act, null) catch {};
    std.posix.sigaction(std.posix.SIG.TERM, &act, null) catch {};
    std.posix.sigaction(std.posix.SIG.HUP, &act, null) catch {};
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var opts = options.parseArgs(allocator, args[1..]) catch |e| {
        var stderr = std.io.getStdErr().writer();
        try stderr.print("zmrig: {s}\n\n", .{@errorName(e)});
        try stderr.writeAll(banner);
        try stderr.print("\n", .{});
        try stderr.writeAll(options.usage);

        // XMRig exits 1 on a bad command line; scripts (and oneclick.sh's
        // config validation) rely on that.
        std.process.exit(1);
    };
    defer opts.deinit(allocator);

    // A config file is loaded first, command line flags are applied on top.
    if (opts.config_path) |path| {
        var file_opts = options.Options{};
        options.parseConfigFile(allocator, &file_opts, path) catch |e| {
            var stderr = std.io.getStdErr().writer();

            // Say what is wrong instead of leaking an error name: an
            // unreadable config is by far the most common failure (the
            // installer writes it root-only, so a plain user cannot read it).
            switch (e) {
                error.ConfigUnreadable => stderr.print("zmrig: cannot read {s}: check the path or run as root\n", .{path}) catch {},
                error.ConfigInvalidJson => stderr.print("zmrig: {s} is not valid JSON\n", .{path}) catch {},
                else => stderr.print("zmrig: cannot load {s}: {s}\n", .{ path, @errorName(e) }) catch {},
            }

            std.process.exit(1);
        };

        var cli = try options.parseArgs(allocator, args[1..]);
        options.mergeInto(allocator, &file_opts, &cli);
        cli.deinit(allocator); // moved strings/pools were cleared; free what was not merged
        opts.deinit(allocator);
        opts = file_opts;
    }

    options.applyTransportDefaults(allocator, &opts) catch |e| {
        var stderr = std.io.getStdErr().writer();
        try stderr.print("zmrig: {s}\n", .{@errorName(e)});

        std.process.exit(1);
    };

    if (opts.help) {
        // `zmrig --help | head` closes the pipe early: that is not an error.
        const out = std.io.getStdOut();
        out.writeAll(banner) catch {};
        out.writeAll("\n") catch {};
        out.writeAll(options.usage) catch {};

        return;
    }

    // Before anything reads a value, and before `--check` can bless it: these
    // are the settings that used to be accepted here and then refused - or
    // ignored - by the code that used them. `--version` describes the binary,
    // not this configuration, so it is the one action that skips the check.
    if (!opts.version) options.validateValues(&opts) catch |e| {
        var stderr = std.io.getStdErr().writer();

        switch (e) {
            error.InvalidThreads => stderr.print(
                "zmrig: {d} is not a thread count this miner can run: -t takes 1..{d}\n",
                .{ opts.threads orelse 0, options.max_threads },
            ) catch {},
            error.InvalidPrefetch => stderr.print(
                "zmrig: --scratchpad-prefetch={d} is not a mode: 0 = no prefetch, 1 = prefetcht0 (default), 2 = prefetchnta, 3 = a plain load\n",
                .{opts.scratchpad_prefetch},
            ) catch {},
            error.InvalidPriority => stderr.print(
                "zmrig: --priority={d} is not a priority: 1..5 on XMRig's scale, -20..19 as a raw nice value, or -1 to leave the scheduler alone\n",
                .{opts.priority},
            ) catch {},
            error.InvalidPoolPort => stderr.print(
                "zmrig: a pool port of 0 is not a port: write host:3333\n",
                .{},
            ) catch {},
            error.InvalidPath => stderr.print(
                "zmrig: a path in the configuration contains a NUL byte, which no file system can open; fix log-file / tls-ca\n",
                .{},
            ) catch {},
            error.UnreadableTlsCa => stderr.print(
                "zmrig: --tls-ca {s} cannot be read, so the pool's certificate cannot be verified\n",
                .{opts.tls_ca orelse (blk: {
                    for (opts.pools.items) |pool| {
                        if (pool.tls_ca) |path| break :blk path;
                    }
                    break :blk "";
                })},
            ) catch {},
            else => stderr.print("zmrig: {s}\n", .{@errorName(e)}) catch {},
        }

        std.process.exit(1);
    };

    log.global = log.Logger.init(opts.colors, opts.verbose);
    // `--verify-share` writes a protocol on stdout: one JSON line per share,
    // nothing else. The sink has to be set here rather than just before
    // `verify.run`, because the fee banner below is printed first - and a pool
    // that reads that banner as a share reply drops the share that was in
    // flight. Everything from this point on belongs on stderr.
    if (opts.verify_share) log.global.stderr_sink = true;
    // `--check-wallet` prints one verdict on stdout and exits; its log has no
    // business in the middle of that.
    if (opts.check_wallet != null) log.global.stderr_sink = true;
    stratum.user_agent = opts.user_agent;
    for (opts.pools.items) |pool| {
        if (!pool.tls_insecure) continue;

        // The bundled TLS client always verifies the chain, and there is no
        // hook to skip it. Saying so is better than a handshake error that
        // looks like the pool's fault.
        log.global.warn("--tls-insecure is accepted for XMRig compatibility but cannot disable verification; use --tls-ca FILE for a private certificate", .{});
        break;
    }

    // A wallet with one wrong character mines perfectly and is never paid. The
    // pool refuses it too, but a rig that keeps reconnecting against a refusal
    // that reads like a network problem can spend a week doing it, and nothing
    // on the machine ever says why. So the address is decoded here, before the
    // first share: a Monero rig whose address fails its checksum does not start.
    //
    // `--allow-bad-wallet` exists because a login can be address shaped without
    // being a Monero address (another CryptoNote coin, a pool account name that
    // happens to be 95 characters). For every algorithm except rx/0 the check is
    // advisory, because this repository only claims to know Monero's format.
    const wallet_fatal = firstAlgo(&opts) == .rx_0 and !opts.allow_bad_wallet;
    for (opts.pools.items) |pool| {
        const login = pool.user;
        const cut = std.mem.indexOfAny(u8, login, "./") orelse login.len;
        const address = login[0..cut];
        if (address.len != 95 and address.len != 106) continue;

        const verdict = wallet.check(address);
        if (!verdict.ok) {
            if (wallet_fatal) {
                log.global.err("{s} is not a valid Monero address: {s}", .{ address, verdict.reason });
                log.global.err("this rig would mine and never be paid; check it with `zmrig --check-wallet {s}`", .{address});
                log.global.err("if that login is not a Monero address, pass --allow-bad-wallet", .{});
                std.process.exit(1);
            }
            log.global.warn("{s} is not a valid Monero address: {s}", .{ address, verdict.reason });
            log.global.warn("check it with: zmrig --check-wallet {s}", .{address});
        } else if (verdict.net != .mainnet) {
            log.global.warn("{s} is a {s} address: a mainnet pool cannot pay it", .{ address, wallet.netLabel(verdict.net) });
        }
    }

    // The fee is a policy decision, so it is stated before anything else runs:
    // what it costs, which coin it applies to, where it goes, how to stop it.
    if (opts.donate_percent == 0) {
        log.global.info("developer fee: off (--donate-level=0); nothing is mined for anyone but your wallet", .{});
    } else if (opts.version or opts.benchmark or opts.report or opts.self_test or opts.check or opts.verify_share or opts.check_wallet != null) {
        // These paths never mine to a pool, and main prints the fee line in
        // --check. Saying it twice in a 3-second benchmark is noise.
    } else {
        log.global.info("developer fee: {d}% of Monero (rx/0) mining time, {s}", .{
            opts.donate_percent,
            fee.wallet,
        });
        log.global.info("             at {d}% that is {d} s every {d} min; --donate-level=0 turns it off", .{
            opts.donate_percent,
            @divTrunc(@as(i64, fee.start_ms), 1000),
            @divTrunc(@as(i64, fee.start_ms) * 100, @as(i64, opts.donate_percent) * 60 * 1000),
        });
    }
    if (opts.log_file) |path| {
        log.global.openFile(path) catch |e| {
            log.global.warn("cannot open log file {s}: {s}", .{ path, @errorName(e) });
        };
    }
    defer log.global.deinit();

    if (opts.version) {
        var buf: [128]u8 = undefined;
        const cpu = std.fmt.bufPrint(&buf, "{d} threads, L3 {d} MB", .{
            miner_mod.cpuCount(),
            (miner_mod.l3CacheSize() orelse 0) / (1024 * 1024),
        }) catch "?";

        std.io.getStdOut().writer().print("zmrig {s} - ZMRIG by @nggkhaiz ({s}, {s})\n", .{ version, api.xmo_engine_name(), cpu }) catch {};

        return;
    }

    if (opts.check_wallet) |address| {
        // Prints and exits: this is what `zmrig-os doctor`, the fleet and a
        // person pasting an address into a shell all need.
        const verdict = wallet.check(address);
        const out = std.io.getStdOut().writer();

        if (verdict.ok) {
            out.print("valid   {s}\n", .{address}) catch {};
            // The property that was actually checked, said out loud: "valid" is
            // the shape, "checksum verified" is why a pool can pay it.
            out.print("  check checksum verified (Keccak-256)\n", .{}) catch {};
            out.print("  kind  {s}\n", .{wallet.kindLabel(verdict.kind)}) catch {};
            out.print("  net   {s}\n", .{wallet.netLabel(verdict.net)}) catch {};
            out.print("  spend {s}\n  view  {s}\n", .{ verdict.spend, verdict.view }) catch {};
            if (verdict.kind == .integrated or verdict.kind == .integrated_subaddress) {
                out.print("  payment id {s}\n", .{verdict.payment_id}) catch {};
            }
            if (verdict.net != .mainnet) {
                out.print("warning: a mainnet pool cannot pay this address\n", .{}) catch {};
                std.process.exit(1);
            }
        } else {
            out.print("invalid {s}\n  {s}\n", .{ address, verdict.reason }) catch {};
            std.process.exit(1);
        }

        return;
    }

    if (opts.self_test) {
        const ok = try selfTest(allocator, firstAlgo(&opts), opts.self_test_light);
        std.process.exit(if (ok) 0 else 1);
    }

    // Both of these build their own dataset. If the machine cannot hold it
    // (another miner owns the huge pages), say so instead of being OOM-killed.
    // The number follows the algorithm: asking for Monero's 2400 MB before a
    // Panthera run that needs 192 MB refused to start on exactly the small
    // hosts Scala is supposed to make usable.
    const dataset_mb: u64 = blk: {
        const algo = firstAlgo(&opts);
        const mode: options.Mode = if (opts.mode == .auto) .fast else opts.mode;
        const scratch_mb: u64 = 2 * @as(u64, opts.threads orelse 2);

        break :blk memoryMb(algo, mode, miner_mod.totalMemory()) + scratch_mb + 64;
    };

    // `--profile` decides the thread count, so it is resolved before anything
    // reads `opts.threads` (`--check` included: the summary must not lie).
    //
    // Before the benchmark, too: `--bench` used to fall through to the L3
    // heuristic, so on a rig with a cgroup quota it measured a machine that was
    // throttled and reported the result as this machine's best. A benchmark is
    // the number somebody writes down in doc/BENCHMARKS.md.
    const profile = resolveProfile(&opts, &log.global);

    if (opts.benchmark) {
        try requireMemory(dataset_mb);
        _ = try benchmark(allocator, &opts, 180, 0);
        return;
    }

    if (opts.report) {
        // stdout carries one line: the code. Everything else goes to stderr so
        // `zmrig --report > rig.txt` produces a file the dashboard accepts.
        log.global.stderr_sink = true;

        try requireMemory(dataset_mb);

        // A report is a steady state number: the first seconds after the
        // dataset is built are slower (JIT warm-up, page faults), so measure a
        // 10 s window after a 10 s warm-up instead of averaging the ramp in.
        const measure = try benchmark(allocator, &opts, @max(opts.report_seconds, 5), 10);
        const power = report.measurePower(opts.power_watts);

        var cpu_buf: [256]u8 = undefined;
        var code_buf: [1400]u8 = undefined;

        const threads = if (opts.threads) |t| @max(t, 1) else miner_mod.defaultThreads(miner_mod.cpuCount());
        // `--report` also works without a pool: it measures the machine, not a
        // session, so there is nothing to validate against.
        const rig_id: ?[]const u8 = if (opts.pools.items.len > 0) opts.pools.items[0].rig_id else null;

        const code = report.encode(&code_buf, .{
            .id = opts.report_id orelse (rig_id orelse "zmrig"),
            .version = version,
            .cpu = report.cpuModel(&cpu_buf),
            .threads = threads,
            .cores = report.physicalCores(miner_mod.cpuCount()),
            .algo = if (opts.algo) |a| a.label() else "rx/0",
            .mode = @tagName(opts.mode),
            .rates = .{ measure.steady_rate, measure.steady_rate, measure.steady_rate, measure.steady_rate },
            .huge_pages = .{ measure.huge_pages, measure.huge_pages },
            .shares = .{ 0, 0, 0 },
            .hashes = measure.hashes,
            .uptime_s = 0,
            .power_watts = power.watts,
            .power_source = power.source,
            .pool = "benchmark",
            .temp_limit_c = opts.max_temp,
            .timestamp = std.time.timestamp(),
        }) catch |e| {
            log.global.err("cannot build the report: {s}", .{@errorName(e)});

            return;
        };

        log.global.info("measured {d} hashes in {d} ms, power source {s}", .{
            measure.hashes,
            measure.elapsed_ms,
            power.source,
        });
        try std.io.getStdOut().writer().print("{s}\n", .{code});

        return;
    }

    options.validate(&opts) catch |e| {
        var stderr = std.io.getStdErr().writer();
        try stderr.print("zmrig: {s}\n\n", .{@errorName(e)});
        try stderr.writeAll(banner);
        try stderr.print("\n", .{});
        try stderr.writeAll(options.usage);

        // A rejected configuration must not look like a successful `--check`:
        // oneclick.sh installs the config only when this exits 0. `return`
        // here used to leave the exit status at 0, so a config with no wallet
        // was written and then failed under systemd.
        std.process.exit(1);
    };


    if (opts.autotune) {
        try runAutotune(allocator, &opts, profile, &log.global);

        return;
    }

    if (opts.check) {
        // A closed pipe (`--check | head`) is not a failure.
        printConfigSummary(&opts) catch {};
        return;
    }

    if (opts.verify_share) {
        // stdout is a protocol here: one JSON line per share, nothing else.
        log.global.stderr_sink = true;
        // `--mode fast` asks for the 2 GiB dataset, which turns a share from a
        // dataset rebuild into a single hash. See verify.zig for the numbers and
        // for why `auto` stays on the light cache.
        const need_mb = memoryMb(firstAlgo(&opts), .fast, miner_mod.totalMemory());
        // `availableMemory`, not `usableMemory`: the dataset is mapped from the
        // free huge pages when there are any (the verifier asks for them and
        // falls back), and from ordinary RAM when there are not. Both numbers
        // are in `availableMemory`, neither is in the machine's size.
        const room_mb = miner_mod.availableMemory(opts.huge_pages) / (1024 * 1024);
        const wants_fast = opts.mode == .fast;
        const full = wants_fast and room_mb >= need_mb;

        if (wants_fast and !full) {
            log.global.warn("--mode fast needs {d} MB for the dataset and only {d} MB can be allocated here: using the light cache (about 9x slower per share)", .{ need_mb, room_mb });
        }
        try verify.run(allocator, &log.global, .{
            .full_memory = full,
            .init_threads = opts.init_threads,
            .huge_pages = opts.huge_pages,
            // `-t` in this mode is hashing threads, not mining threads, and it
            // is the only place it means that - so it is read from the command
            // line rather than from the profile's heuristic, which is about
            // mining and would have quietly given a verifier every core.
            .threads = if (opts.seen.threads) (opts.threads orelse 1) else 1,
        });

        return;
    }

    if (opts.background) {
        // XMRig's --background: detach from the terminal, keep mining. The log
        // file (if any) was opened before this point, so it survives.
        daemonise() catch |e| {
            log.global.err("cannot go to the background: {s}", .{@errorName(e)});

            return;
        };
    }

    installSignalHandlers();

    const logger = &log.global;
    if (opts.donate_percent == 0) {
        logger.info("ZMRIG {s} by @nggkhaiz - developer fee off", .{version});
    } else {
        logger.info("ZMRIG {s} by @nggkhaiz - {d}% developer fee (Monero time only)", .{ version, opts.donate_percent });
    }
    logger.info("engine: {s}", .{api.xmo_engine_name()});

    // The workers set their own nice value; this covers the main thread.
    miner_mod.applyPriority(opts.priority);

    var miner = try startMiner(logger, &opts);
    defer miner.deinit();

    // The RandomX memory-latency fix, applied before the dataset is built.
    // It is opt-in because it writes hardware registers, and it is allowed to
    // fail: a VM without MSR passthrough is a normal place to run a miner.
    const msr_applied = applyMsr(&opts, logger);
    defer if (msr_applied and opts.msr_restore) {
        var report_buf: [192]u8 = undefined;
        @memset(&report_buf, 0);
        _ = api.xmo_msr_restore(&report_buf, report_buf.len);
        logger.debug("msr: {s}", .{report_buf[0..std.mem.indexOfScalar(u8, &report_buf, 0) orelse report_buf.len]});
    };

    // "host:port" for the report, owned by main for the whole run.
    var pool_label_buf: [256]u8 = undefined;
    const pool_label = std.fmt.bufPrint(&pool_label_buf, "{s}:{d}", .{
        opts.pools.items[0].host,
        opts.pools.items[0].port,
    }) catch opts.pools.items[0].host;

    // Developer fee clock. Declared outside the monitor because the mining loop
    // below reads `due()` before every connection.
    var fee_clock = fee.Clock.init(opts.donate_percent);

    // The thermal policy, when one was asked for. `--max-temp` with no sensor
    // to read is not a policy, so say that now instead of at 4 a.m.
    var governor: ?thermal.Governor = null;
    if (opts.max_temp) |target| {
        governor = thermal.Governor.init(thermal.Config.fromTarget(target), miner.threadCount());

        if (readTemperature(&opts)) |reading| {
            logger.info("thermal: holding {d:.0} C max - {s} reads {d:.1} C now; {d} thread(s), step down at {d:.0} C, pause at {d:.0} C", .{
                governor.?.config.target_c,
                reading.label(),
                reading.celsius,
                miner.threadCount(),
                governor.?.config.target_c,
                governor.?.config.critical_c,
            });
        } else {
            logger.warn("thermal: --max-temp={d:.0} was asked for but no CPU sensor was found in /sys/class/{{hwmon,thermal}}; the governor cannot act without one (pass --thermal-file=PATH to read it elsewhere)", .{target});
        }
    }

    var monitor = Monitor{
        .miner = &miner,
        .fee_clock = &fee_clock,
        .logger = logger,
        .report_file = opts.report_file,
        .report_interval_ms = @as(i64, @intCast(@max(opts.report_interval, 1))) * 1000,
        .report_id = opts.report_id orelse (opts.pools.items[0].rig_id orelse "zmrig"),
        .report_pool = pool_label,
        .report_user_power = opts.power_watts,
        .report_mode = @tagName(opts.mode),
        .report_started_ms = std.time.milliTimestamp(),
        .print_interval = @as(i64, @intCast(opts.print_time)) * 1000,
        .idle_timeout_ms = @as(i64, @intCast(opts.idle_timeout)) * 1000,
        .keepalive_ms = @as(i64, @intCast(opts.keepalive_interval)) * 1000,
        .keepalive_enabled = opts.keepalive_interval > 0,
        .health_restart = opts.health_restart,
        .health_restart_seconds = @intCast(opts.health_restart_seconds),
        .health_tracker = .{ .config = .{ .warmup_seconds = opts.health_warmup_seconds } },
        .governor = if (governor) |*g| g else null,
        .thermal_file = opts.thermal_file,
    };
    monitor.thread = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, Monitor.run, .{&monitor});
    defer {
        monitor.stop.store(true, .release);
        if (monitor.thread) |thread| thread.join();
    }

    logger.info("wallet: {s}", .{opts.pools.items[0].user});

    // Optional read-only monitoring API (--http-port). It reads atomics only,
    // so an open dashboard cannot slow the miner down.
    var http_api: ?api_http.Server = null;
    if (opts.api_port != 0) {
        const first_pool = opts.pools.items[0];
        var url_buf: [256]u8 = undefined;
        const pool_url = std.fmt.bufPrint(&url_buf, "{s}://{s}:{d}", .{
            first_pool.transport.label(),
            first_pool.host,
            first_pool.port,
        }) catch first_pool.host;

        http_api = api_http.Server{
            .allocator = allocator,
            .logger = logger,
            .host = opts.http_host,
            .port = opts.api_port,
            .token = opts.api_token,
            .info = .{
                .version = version,
                .pool_url = pool_url,
                .worker_id = first_pool.rig_id orelse "zmrig",
                .miner = &miner,
                .threads = miner.threadCount(),
                .donate_percent = opts.donate_percent,
                .started_ms = std.time.milliTimestamp(),
                .accepted = &miner.submitter.accepted,
                .rejected = &miner.submitter.rejected,
                .failed = &miner.submitter.failed,
                .view = &monitor.view,
            },
        };

        http_api.?.start() catch |e| {
            logger.warn("http api disabled: {s}", .{@errorName(e)});
            http_api = null;
        };
    }
    defer if (http_api) |*server| server.stopServer();

    var pool_index: usize = 0;
    var failures: u32 = 0;
    // Per-pool cooldown after a refusal. A pool that banned this IP, or that
    // does not know the wallet, is not retried every few seconds: repeated
    // logins are what turns one refusal into a ban on every pool at once.
    const cooldown = try allocator.alloc(i64, opts.pools.items.len);
    defer allocator.free(cooldown);
    @memset(cooldown, 0);
    // Consecutive failures since the last successful login, used only to
    // shape the retry delay. It is not reset when the pool list wraps around,
    // otherwise a dead pool would be hammered every few seconds forever.
    var attempts: u32 = 0;

    while (running.load(.acquire)) {
        const now_ms = std.time.milliTimestamp();
        var chosen: ?usize = null;
        var earliest: i64 = std.math.maxInt(i64);
        var earliest_index: usize = 0;

        var probe: usize = 0;
        while (probe < opts.pools.items.len) : (probe += 1) {
            const candidate = (pool_index + probe) % opts.pools.items.len;
            if (cooldown[candidate] <= now_ms) {
                chosen = candidate;
                break;
            }
            if (cooldown[candidate] < earliest) {
                earliest = cooldown[candidate];
                earliest_index = candidate;
            }
        }

        if (chosen == null) {
            // Every pool refused recently: wait for the first one to come back
            // instead of knocking on all of them.
            const wait_ms = @min(@max(earliest - now_ms, 250), 60_000);
            logger.info("all pools are cooling down ({s} next), waiting {d} s", .{
                opts.pools.items[earliest_index].host,
                @divTrunc(wait_ms, 1000),
            });
            sleepInterruptibleMs(@intCast(wait_ms));
            continue;
        }

        pool_index = chosen.?;
        const pool = opts.pools.items[pool_index];

        const donating = fee_clock.due(std.time.milliTimestamp());
        const session_pool = feeSessionPool(pool, donating);
        const active_pool = if (donating) &session_pool else &pool;

        if (donating) {
            logger.info("developer fee: {d} s owed, mining for the developer wallet for a moment", .{
                @divTrunc(fee_clock.owed(), 1000),
            });
        } else {
            logger.info("connecting to {s}://{s}:{d}{s}", .{
                pool.transport.label(),
                pool.host,
                pool.port,
                if (pool.transport.usesWs()) (pool.ws_path orelse "/") else "",
            });
        }

        // What this rig tells the pool it can hash: one pinned algorithm, the
        // whole RandomX family with `--algo=auto`, or nothing at all.
        var algo_buf: [api.auto_algos.len]api.Algo = undefined;
        const algos = opts.loginAlgos(active_pool, &algo_buf);
        var session = stratum.Session.open(allocator, active_pool.*, logger) catch |e| {
            if (donating) {
                // A socket that will not open is not the user's problem: keep
                // their mining going and owe the fee for later.
                logger.warn("developer fee: cannot reach {s} ({s}); fee deferred", .{ pool.host, @errorName(e) });
                fee_clock.fail(std.time.milliTimestamp());
                continue;
            }
            failures += 1;
            if (failures >= opts.retries) {
                failures = 0;
                pool_index += 1;
            }
            attempts +|= 1;
            sleepInterruptibleMs(jittered(retryDelayMs(opts.retry_pause, attempts), @as(u64, @bitCast(std.time.microTimestamp()))));
            continue;
        };
        defer session.close();

        // From here on the monitor owns a kick handle: a Ctrl-C while waiting
        // for the login reply must not wait for the pool to answer. The handle
        // is cleared as soon as this session ends, so a stale descriptor can
        // never be shut down after it was closed (and possibly reused).
        monitor.kick_reason.store(.none, .release);
        monitor.socket.store(@intCast(session.conn.handle()), .release);
        defer monitor.socket.store(-1, .release);

        var first_job = job_mod.Job.init();
        session.login(algos, &first_job) catch |e| {
            if (donating) {
                // The developer wallet can be refused where the user's is not:
                // unknown address on that pool, a different network, a ban on
                // that login. None of it may cost the user their mining, so no
                // cooldown is written and no pool is marked bad.
                logger.warn("developer fee: {s} refused it ({s}); fee deferred, your mining continues", .{
                    pool.host,
                    session.last_failure.label(),
                });
                fee_clock.fail(std.time.milliTimestamp());
                continue;
            }

            logger.err("login failed: {s}", .{describeLoginError(e)});

            const base_ms: i64 = @as(i64, opts.ban_cooldown) * 1000;
            switch (session.last_failure) {
                .credentials => {
                    const wait = @max(base_ms * 2, 1_800_000);
                    cooldown[pool_index] = std.time.milliTimestamp() + wait;
                    logger.err("{s} does not accept this wallet or password; it will not be retried for {d} min. Check the address (95 characters, starts with 4) and the port (TLS pools need tls:// or --tls), because repeating a bad login is what gets an IP banned", .{
                        pool.host,
                        @divTrunc(wait, 60_000),
                    });
                    pool_index = (pool_index + 1) % opts.pools.items.len;
                },
                .banned => {
                    cooldown[pool_index] = std.time.milliTimestamp() + base_ms;
                    logger.err("{s} banned this IP; cooling down for {d} min before trying it again", .{
                        pool.host,
                        @divTrunc(base_ms, 60_000),
                    });
                    pool_index = (pool_index + 1) % opts.pools.items.len;
                },
                .throttled, .full => {
                    const wait = @max(@divTrunc(base_ms, 8), 1000);
                    cooldown[pool_index] = std.time.milliTimestamp() + wait;
                    logger.warn("{s} is not taking connections right now ({s}); pausing it for {d} s", .{
                        pool.host,
                        session.last_failure.label(),
                        @divTrunc(wait, 1000),
                    });
                    pool_index = (pool_index + 1) % opts.pools.items.len;
                },
                else => {
                    failures += 1;
                    if (failures >= opts.retries) {
                        failures = 0;
                        pool_index = (pool_index + 1) % opts.pools.items.len;
                    }
                },
            }

            attempts +|= 1;
            sleepInterruptibleMs(jittered(retryDelayMs(opts.retry_pause, attempts), @as(u64, @bitCast(std.time.microTimestamp()))));
            continue;
        };

        failures = 0;
        attempts = 0;

        if (donating) {
            fee_clock.begin(std.time.milliTimestamp());
            logger.info("developer fee: login ok, mining job {s} for the developer wallet", .{first_job.idSlice()});
        } else {
            logger.info("login ok, job {s}, difficulty {d:.3}", .{
                first_job.idSlice(),
                first_job.diff(),
            });
        }

        miner.submitter.attach(&session);
        monitor.last_message.store(std.time.milliTimestamp(), .release);
        monitor.view.markConnected(std.time.milliTimestamp());

        miner.applyJob(&first_job) catch |e| {
            logger.err("cannot start mining: {s}", .{@errorName(e)});
            miner.submitter.detach();
            attempts +|= 1;
            sleepInterruptibleMs(jittered(retryDelayMs(opts.retry_pause, attempts), @as(u64, @bitCast(std.time.microTimestamp()))));
            continue;
        };

        // `opts.poolAlgo` -- not the advertised list: this is the default used
        // for a job that names no algorithm, and `--algo=auto` deliberately pins
        // nothing so the pool stays free to switch.
        fee_clock.noteMonero(first_job.algo == .rx_0);

        const result = runSession(allocator, &session, &miner, &opts, &monitor, opts.poolAlgo(active_pool), &fee_clock, logger);
        monitor.view.markDisconnected();

        if (session.conn.skipped > 0) {
            logger.warn("ignored {d} over-long line(s) from the pool", .{session.conn.skipped});
        }

        miner.submitter.detach();
        // Keep the workers running on the last job while we reconnect: a pool
        // that drops a socket for a second must not cost a minute of hashing.
        // Shares found in the gap are dropped by the submitter with a warning.

        if (donating) {
            // The debt was paid down by the monitor (which kicked the socket)
            // or the pool dropped us. Either way the next connection is the
            // user's wallet again, with no retry pause: the fee must never
            // cost the user a minute of hashing.
            const started_ms = fee_clock.session_start_ms;
            const spent_s = if (started_ms == 0) 0 else @divTrunc(std.time.milliTimestamp() - started_ms, 1000);

            fee_clock.finish();

            switch (result) {
                .banned => {
                    logger.warn("developer fee: {s} banned the developer login; fee paused for a while", .{pool.host});
                    fee_clock.fail(std.time.milliTimestamp());
                },
                .disconnected => |e| if (monitor.kick_reason.load(.acquire) == .fee)
                    logger.info("developer fee: session finished after {d} s; {d} s left owed", .{
                        spent_s,
                        @divTrunc(fee_clock.owed(), 1000),
                    })
                else
                    logger.warn("developer fee: session ended after {d} s ({s}); {d} s left owed", .{
                        spent_s,
                        @errorName(e),
                        @divTrunc(fee_clock.owed(), 1000),
                    }),
                else => logger.info("developer fee: session ended after {d} s; {d} s left owed", .{
                    spent_s,
                    @divTrunc(fee_clock.owed(), 1000),
                }),
            }

            if (!running.load(.acquire)) break;
            continue;
        }

        switch (result) {
            // A SIGTERM or a fee hand-over wakes the blocking read, which looks
            // exactly like the pool closing the socket. Neither is: the monitor
            // records why it shut the socket down, and this reads it. A warning
            // about a lost connection during a clean shutdown or a wallet swap
            // is the kind of thing that trains somebody to ignore warnings.
            .disconnected => |e| switch (monitor.kick_reason.load(.acquire)) {
                // Both of these were said already, by whoever closed the
                // socket: the monitor prints "60 s owed, reconnecting to pay
                // it" before it kicks, and a shutdown prints "shutting down"
                // two lines later. Repeating it here is how one event becomes
                // three log lines.
                .shutdown, .fee => {},
                .none => logger.warn("connection lost: {s}", .{@errorName(e)}),
            },
            .shutdown => {},
            .failed => {},
            .banned => {
                const wait: i64 = @as(i64, opts.ban_cooldown) * 1000;
                cooldown[pool_index] = std.time.milliTimestamp() + wait;
                logger.err("{s} banned this IP; cooling down for {d} min and moving on", .{
                    pool.host,
                    @divTrunc(wait, 60_000),
                });
                pool_index = (pool_index + 1) % opts.pools.items.len;
            },
        }

        if (!running.load(.acquire)) break;

        // A session that worked and then dropped is retried almost at once --
        // still with jitter, because a pool restart drops every rig at once.
        sleepInterruptibleMs(jittered(retryDelayMs(opts.retry_pause, 0), @as(u64, @bitCast(std.time.microTimestamp()))));
    }

    logger.info("shutting down", .{});
    miner.stop();

    var buf: [32]u8 = undefined;
    logger.info("total hashes {d}, shares accepted {d}, rejected {d}, failed {d}", .{
        miner.shared.totalHashes(),
        miner.submitter.accepted.load(.monotonic),
        miner.submitter.rejected.load(.monotonic),
        miner.submitter.failed.load(.monotonic),
    });

    // "hashing 0 s of 0 s" is a line about nothing: a run that lasted less than
    // five seconds (a `--check`, a bad option, a crash) has no duty cycle worth
    // reporting and the totals above already say everything.
    if (miner.duty.total_ms >= 5000) {
        var duty_buf: [256]u8 = undefined;
        logger.info("{s}", .{miner.describeDuty(&duty_buf)});
    }
    _ = &buf;
}

/// Who closed the socket. `.none` means nobody here did, so a closed read is a
/// real disconnect.
const KickReason = enum(u8) { none, shutdown, fee };

const SessionEnd = union(enum) {
    disconnected: anyerror,
    shutdown,
    failed,
    /// The pool refused the work itself and named a ban. Retrying it at once
    /// is how a 10-minute ban becomes an hour.
    banned,
};

/// What a failed login says in the log.
///
/// `@errorName` is a name for a programmer; a rig owner reads the log at 2 a.m.
/// from a phone. The four that have a cause worth naming are spelled out; the
/// rest keep their name so a bug report still carries it.
fn describeLoginError(e: anyerror) []const u8 {
    return switch (e) {
        error.ConnectionClosed => "the pool closed the connection (check the port and the scheme: TLS pools need tls:// or wss://)",
        error.WsProtocol => "the endpoint is not speaking WebSocket correctly (check the path and any proxy in front of it)",
        error.BadResponse => "the endpoint answered the WebSocket upgrade with something that is not HTTP",
        error.TlsHandshake, error.HandshakeFailed => "the TLS handshake failed (wrong port, a self-signed certificate, or a proxy rewriting the stream)",
        else => @errorName(e),
    };
}

fn runSession(
    allocator: std.mem.Allocator,
    session: *stratum.Session,
    miner: *miner_mod.Miner,
    opts: *const options.Options,
    monitor: *Monitor,
    algo: ?api.Algo,
    clock: *fee.Clock,
    logger: *log.Logger,
) SessionEnd {
    _ = opts;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    while (running.load(.acquire)) {
        _ = arena.reset(.retain_capacity);

        const message = session.next(arena.allocator(), algo orelse .rx_0) catch |e| {
            return .{ .disconnected = e };
        };

        monitor.last_message.store(std.time.milliTimestamp(), .release);

        switch (message) {
            .job => |pool_job| {
                var next_job = pool_job;

                logger.info("new job {s} from pool, height {d}, difficulty {d:.3}", .{
                    next_job.idSlice(),
                    next_job.height,
                    next_job.diff(),
                });

                miner.applyJob(&next_job) catch |e| {
                    logger.err("cannot apply job: {s}", .{@errorName(e)});
                };

                // The fee accrues on Monero only, so the clock has to know
                // what is actually in the engine, not what the config said.
                clock.noteMonero(next_job.algo == .rx_0);
            },
            .reply => |reply| {
                if (reply.ok) {
                    if (reply.job != null) continue;

                    _ = miner.submitter.accepted.fetchAdd(1, .monotonic);
                    logger.info("share accepted ({d} total)", .{miner.submitter.accepted.load(.monotonic)});
                } else {
                    const reason = reply.message orelse "unknown reason";
                    const refusal = stratum.classify(reason);

                    if (refusal == .banned) {
                        logger.err("the pool banned this IP: {s}", .{reason});

                        return .banned;
                    }

                    _ = miner.submitter.rejected.fetchAdd(1, .monotonic);
                    logger.warn("share rejected: {s}", .{reason});
                    miner.submitter.noteRejection(refusal, logger);
                }
            },
            .keepalive => {},
            .other => |method| {
                logger.debug("pool method {s}", .{method});
            },
        }
    }

    return .shutdown;
}

/// Samples the hash counter once a second, prints the periodic hashrate line and
/// drops a connection that has been silent for too long. Runs in its own thread
/// so the pool read loop can stay a simple blocking reader (which keeps TLS
/// record framing correct).
const Monitor = struct {
    miner: *miner_mod.Miner,
    logger: *log.Logger,
    /// Live report file (`--report-file`), written from this thread so the
    /// pool loop stays untouched.
    report_file: ?[]const u8 = null,
    report_interval_ms: i64 = 60_000,
    report_id: []const u8 = "zmrig",
    report_pool: []const u8 = "",
    report_mode: []const u8 = "auto",
    report_power: ?f64 = null,
    report_power_source: []const u8 = "none",
    /// Measurement is deferred until the CPU has been hashing for a while: a
    /// RAPL reading taken at startup would be idle power, not mining power.
    report_power_measured: bool = false,
    report_user_power: ?f64 = null,
    report_started_ms: i64 = 0,
    last_report_write: i64 = 0,
    report_error_logged: bool = false,
    /// `warnIfIdle` is a warning, not a heartbeat: once a minute is enough.
    last_idle_warn: i64 = 0,
    print_interval: i64,
    idle_timeout_ms: i64 = 300_000,
    keepalive_ms: i64 = 60_000,
    keepalive_enabled: bool = true,
    last_message: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    /// Restart the process when a fault (stall or all-rejected) has held for
    /// this long: under systemd `Restart=always`, exiting *is* the recovery.
    health_restart: bool = true,
    health_restart_seconds: i64 = 900,
    health_tracker: health.Tracker = .{},
    health_state: health.State = .warming,
    health_logged: bool = false,
    /// Armed by `--max-temp`. Null means no governor: this is the only place
    /// the thermal policy is applied, so nothing else can throttle a machine
    /// that did not ask to be throttled.
    governor: ?*thermal.Governor = null,
    /// `--thermal-file`, owned by Options for the whole run.
    thermal_file: ?[]const u8 = null,
    thermal_reading: ?thermal.Reading = null,
    thermal_missing_logged: bool = false,
    /// Hashrates published to the HTTP API once a second.
    view: api_http.View = .{},
    /// The developer-fee clock, ticked once a second from this thread because
    /// this is the only place that knows how much wall clock actually passed.
    fee_clock: ?*fee.Clock = null,
    /// Why this thread last shut the socket down, if it did. The mining loop is
    /// parked in a blocking read when it happens, and from there a deliberate
    /// close is indistinguishable from the pool dropping the connection - so
    /// the loop asks instead of guessing, and a hand-over to the developer
    /// wallet stops looking like a network fault in the log.
    kick_reason: std.atomic.Value(KickReason) = std.atomic.Value(KickReason).init(.none),
    socket: std.atomic.Value(i32) = std.atomic.Value(i32).init(-1),
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    /// Closes the active socket so a blocking read returns and the main thread
    /// can notice `running == false`. Called from the monitor thread, which is
    /// the only one allowed to touch the descriptor besides the main loop.
    pub fn kick(self: *Monitor) void {
        const fd = self.socket.load(.acquire);
        if (fd >= 0) std.posix.shutdown(@intCast(fd), .both) catch {};
    }

    fn run(self: *Monitor) void {
        var last_report = std.time.milliTimestamp();
        var first_hash_ms: i64 = 0;
        var first_report = true;

        while (!self.stop.load(.acquire)) {
            std.time.sleep(1000 * std.time.ns_per_ms);

            const total = self.miner.shared.totalHashes();
            self.miner.stats.add(total);
            self.miner.tickDuty(std.time.milliTimestamp());

            const now = std.time.milliTimestamp();
            if (first_hash_ms == 0 and total > 0) first_hash_ms = now;

            // One early report, 10 s after the *first hash* (not after start:
            // the dataset init takes 15 s and would produce a meaningless
            // average), so status/logs show a real number quickly.
            if (first_report and first_hash_ms != 0 and now - first_hash_ms >= 10_000) {
                first_report = false;
                last_report = now;
                self.miner.report();
                continue;
            }

            if (self.print_interval > 0 and now - last_report >= self.print_interval) {
                first_report = false;
                last_report = now;
                self.miner.report();
            }

            self.view.store(
                self.miner.hashrate(10),
                self.miner.hashrate(60),
                self.miner.hashrate(900),
                self.miner.stats.max_rate,
                self.miner.shared.totalHashes(),
            );

            self.warnIfIdle(now);
            self.checkHealth(now);
            self.checkThermal(now);

            if (self.report_file) |path| {
                if (now - self.last_report_write >= self.report_interval_ms) {
                    self.last_report_write = now;
                    self.writeReport(path, now);
                }
            }

            // A SIGTERM must not wait for the pool to say something: the main
            // thread is parked in a blocking read, so nudge it here.
            if (!running.load(.acquire)) {
                self.kick_reason.store(.shutdown, .release);
                self.kick();
            }

            // Developer fee. The debt is accrued here, and a session that has
            // paid it off is ended from here too -- the main thread is parked
            // in a socket read and would not notice until the next job.
            if (self.fee_clock) |clock| {
                // Only time that is actually hashing counts: the 21 s dataset
                // build at startup is not mining.
                clock.tick(1000, total > 0 and clock.moneroNow());

                if (clock.expired(now)) {
                    self.logger.info("developer fee: session paid, back to your wallet", .{});
                    self.kick_reason.store(.fee, .release);
                    self.kick();
                } else if (!clock.isDonating() and clock.due(now)) {
                    // A pool connection lives for hours; the only way to hand
                    // the wallet over is to end it. The mining loop sees a
                    // closed socket, reconnects, and finds `due()` true.
                    self.logger.info("developer fee: {d} s owed, reconnecting to pay it", .{
                        @divTrunc(clock.owed(), 1000),
                    });
                    self.kick_reason.store(.fee, .release);
                    self.kick();
                }
            }

            // A Cloudflare-fronted WebSocket (and any NAT/firewall in between)
            // drops a connection that carries no traffic. Sending keepalived
            // from this thread keeps the same socket alive for hours.
            if (self.keepalive_enabled) self.miner.submitter.keepaliveIfIdle(self.keepalive_ms, self.logger);

            const last = self.last_message.load(.acquire);
            const fd = self.socket.load(.acquire);
            if (self.idle_timeout_ms > 0 and last != 0 and fd >= 0 and now - last > self.idle_timeout_ms) {
                self.logger.warn("pool has been silent for {d} s, dropping the connection", .{@divTrunc(now - last, 1000)});
                std.posix.shutdown(@intCast(fd), .both) catch {};
            }
        }
    }

    /// One second of thermal policy: read the hottest sensor, ask the governor
    /// what to do, apply it, and say so once per change.
    ///
    /// Nothing here runs unless `--max-temp` armed a governor, so a machine
    /// without the flag behaves exactly as it did before this file existed.
    fn checkThermal(self: *Monitor, now_ms: i64) void {
        const gov = self.governor orelse return;

        const reading = if (self.thermal_file) |path| blk: {
            const celsius = thermal.readPlainFile(path) orelse break :blk null;
            var r = thermal.Reading{ .celsius = celsius };
            @memcpy(r.name_buf[0..4], "file");
            r.name_len = 4;
            break :blk r;
        } else thermal.readSys("/sys");

        self.thermal_reading = reading;

        if (reading == null and !self.thermal_missing_logged and now_ms - self.report_started_ms > 30_000) {
            self.thermal_missing_logged = true;
            self.logger.warn("thermal: no CPU sensor on this machine, so --max-temp cannot act; point --thermal-file at a file that holds the temperature", .{});
        }

        const celsius: ?f32 = if (reading) |r| r.celsius else null;
        const sensor = if (reading) |r| r.label() else "no sensor";

        switch (gov.step(now_ms, celsius)) {
            .none => {},
            .set_threads => |threads| {
                self.miner.shared.setActiveThreads(threads);
                self.logger.info("thermal: {d:.1} C on {s} -> {d} of {d} threads (target {d:.0} C; {d} step-down(s), {d} step-up(s) so far)", .{
                    celsius orelse 0,
                    sensor,
                    threads,
                    self.miner.threadCount(),
                    gov.config.target_c,
                    gov.step_downs,
                    gov.step_ups,
                });
            },
            .pause => {
                self.miner.shared.pause();
                self.miner.shared.setActiveThreads(0);
                self.logger.warn("thermal: {d:.1} C on {s} and one thread is not enough to stay under {d:.0} C - mining stops until it falls to {d:.0} C. Nothing is lost: the dataset stays in RAM and the pool connection stays up", .{
                    celsius orelse 0,
                    sensor,
                    gov.config.max_c,
                    gov.config.resume_c,
                });
            },
            .unpause => {
                self.miner.shared.unpause();
                self.miner.shared.setActiveThreads(gov.threads);
                self.logger.info("thermal: back to {d:.1} C on {s}, mining resumes on {d} thread(s) and climbs while it stays under {d:.0} C", .{
                    celsius orelse 0,
                    sensor,
                    gov.threads,
                    gov.config.target_c - gov.config.hysteresis_c,
                });
            },
        }
    }

    /// The numbers the health rules judge, taken from the same counters the
    /// report uses so the log, the API and the dashboard cannot disagree.
    fn healthSnapshot(self: *Monitor, now_ms: i64) health.Snapshot {
        const submitter = &self.miner.submitter;

        return .{
            .uptime_s = @intCast(@max(@divTrunc(now_ms - self.report_started_ms, 1000), 0)),
            .rate_10s = self.miner.hashrate(10),
            .rate_60s = self.miner.hashrate(60),
            .peak = self.miner.stats.max_rate,
            .hashes = self.miner.shared.totalHashes(),
            .accepted = submitter.accepted.load(.monotonic),
            .rejected = submitter.rejected.load(.monotonic),
            .submitted = submitter.submitted.load(.monotonic),
            .quarantined = submitter.quarantined(),
            .paused = self.miner.shared.paused.load(.acquire),
        };
    }

    /// Runs the rules, logs every change of state once, and -- only for a
    /// fault that has held for `health_restart_seconds` -- exits so the
    /// supervisor can start a clean process.
    ///
    /// Exiting is the only remedy that actually works for the failures this
    /// detects: a stuck engine or a pool that has decided to reject us will not
    /// fix itself, and a restart costs 16-30 s of hashrate against hours of
    /// zero. It is on by default, and off with `--no-health-restart`.
    fn checkHealth(self: *Monitor, now_ms: i64) void {
        const snapshot = self.healthSnapshot(now_ms);
        const state = self.health_tracker.update(snapshot, now_ms);

        if (state != self.health_state) {
            var buf: [256]u8 = undefined;
            const line = health.describe(&buf, state, snapshot);

            switch (state) {
                .ok => self.logger.info("{s}", .{line}),
                .warming => self.logger.debug("{s}", .{line}),
                .degraded => self.logger.warn("{s}", .{line}),
                .stalled, .rejected => self.logger.err("{s}", .{line}),
            }

            self.health_state = state;
        }

        if (!state.isFault() or !self.health_restart) return;

        const held = self.health_tracker.faultDurationSeconds(state, now_ms);
        if (held < self.health_restart_seconds) return;

        self.logger.err("health: {s} for {d} s, restarting so the supervisor can start clean (--no-health-restart disables this)", .{
            state.label(), held,
        });

        // Flush the log before dying: a buffered "why" that never reaches the
        // journal is the same as no message at all.
        std.time.sleep(50 * std.time.ns_per_ms);
        std.process.exit(3);
    }

    /// Writes `ZMRIG1.<...>` to the report file. A failure is logged once and
    /// never stops the miner: a read-only /run must not kill a good session.
    /// A rig that hashes at 1 000 H/s for 60 % of the hour earns 60 % of what
    /// the speed line suggests, and nothing in that line says so. Once a minute
    /// at most, when the last minute was mostly not hashing, say how much and
    /// where it went - naming the reason only when this thread knows it.
    fn warnIfIdle(self: *Monitor, now_ms: i64) void {
        // Ten samples is the shortest window where a percentage means anything,
        // and a rig that has not hashed at all yet is warming up: the first
        // dataset build is expected, already logged, and not this warning.
        if (self.miner.duty.next < 30) return;
        if (self.miner.duty.hashing_ms == 0) return;
        if (self.miner.duty.recent(60) >= 0.85) return;
        if (now_ms - self.last_idle_warn < 60_000) return;

        self.last_idle_warn = now_ms;

        const percent = self.miner.duty.recent(60) * 100.0;
        const idle_s = self.miner.duty.recentIdle(60);
        const throttled_s = self.miner.duty.recentThrottled(60);

        // A dataset build is not a fault and it is already logged, with its
        // own duration ("dataset ready in 14564 ms"). The warning exists for
        // time nobody chose: a pool that is gone, or a governor holding
        // threads back.
        if (idle_s == 0 and throttled_s == 0) return;

        if (idle_s > 0) {
            self.logger.warn("hashing {d:.0} % of the last minute: {d} s with no job (the pool is gone, or a reconnect is in flight)", .{ percent, idle_s });
        } else if (throttled_s > 0) {
            self.logger.info("hashing {d:.0} % of the last minute: {d} s throttled at --max-temp", .{ percent, throttled_s });
        } else {
            self.logger.warn("hashing {d:.0} % of the last minute", .{percent});
        }
    }

    fn writeReport(self: *Monitor, path: []const u8, now_ms: i64) void {
        if (self.report_file == null) return;

        const uptime_ms = now_ms - self.report_started_ms;

        if (!self.report_power_measured) {
            // Give the workers time to reach full load first; a 250 ms sample
            // of an idle package would understate the electricity badly.
            if (uptime_ms < 30_000) return;

            self.report_power_measured = true;
            const power = report.measurePower(self.report_user_power);
            self.report_power = power.watts;
            self.report_power_source = power.source;
        }

        var cpu_buf: [256]u8 = undefined;
        var code_buf: [1400]u8 = undefined;

        const huge_pages = self.miner.hugePages();
        const power = self.report_power;

        const code = report.encode(&code_buf, .{
            .id = self.report_id,
            .version = version,
            .cpu = report.cpuModel(&cpu_buf),
            .threads = self.miner.threadCount(),
            .cores = report.physicalCores(miner_mod.cpuCount()),
            .algo = if (self.miner.engine.algo) |algo| algo.label() else "auto",
            .mode = self.report_mode,
            .rates = .{
                self.miner.hashrate(10),
                self.miner.hashrate(60),
                self.miner.hashrate(900),
                self.miner.stats.max_rate,
            },
            .huge_pages = huge_pages,
            .shares = .{
                self.miner.submitter.accepted.load(.monotonic),
                self.miner.submitter.rejected.load(.monotonic),
                self.miner.submitter.failed.load(.monotonic),
            },
            .hashes = self.miner.shared.totalHashes(),
            .uptime_s = @divTrunc(uptime_ms, 1000),
            .power_watts = power,
            .power_source = self.report_power_source,
            .pool = self.report_pool,
            .health = self.health_state.label(),
            .temp_limit_c = if (self.governor) |g| g.config.target_c else null,
            .temp_c = if (self.thermal_reading) |r| r.celsius else null,
            .active_threads = self.miner.activeCount(),
            .timestamp = std.time.timestamp(),
        }) catch return;

        // The directory may not exist yet (a fresh unit, a custom --report-file):
        // create it instead of skipping the report for the whole run.
        if (std.fs.path.dirname(path)) |dir| std.fs.cwd().makePath(dir) catch {};

        // Write a sibling file and rename it over the target. The dashboard
        // polls this file; truncating it in place would hand out an empty read
        // every time, and a rename is atomic on POSIX.
        var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path}) catch path;

        var file = std.fs.cwd().createFile(tmp, .{ .truncate = true }) catch |e| {
            if (!self.report_error_logged) {
                self.report_error_logged = true;
                self.logger.warn("cannot write the report file {s}: {s}", .{ path, @errorName(e) });
            }

            return;
        };

        var written = true;
        file.writeAll(code) catch {
            written = false;
        };
        file.writeAll("\n") catch {
            written = false;
        };
        file.close();

        if (written) {
            std.fs.cwd().rename(tmp, path) catch |e| {
                if (!self.report_error_logged) {
                    self.report_error_logged = true;
                    self.logger.warn("cannot replace the report file {s}: {s}", .{ path, @errorName(e) });
                }
                std.fs.cwd().deleteFile(tmp) catch {};
            };
        } else {
            std.fs.cwd().deleteFile(tmp) catch {};
        }
    }
};


/// --check: print what the miner would do, without touching the network.
/// Applies the RandomX MSR preset when the user asked for it. Returns true when
/// the values were written (so the caller knows there is something to restore).
fn applyMsr(opts: *const options.Options, logger: *log.Logger) bool {
    switch (opts.msr) {
        .off => return false,
        .on => {},
        .auto => {
            // Nothing to decide unless the machine can actually take it. The
            // probe reads one register and reports why not, which is the same
            // sentence a user needs when they ask `--check`; doing it here
            // means `auto` never logs a scary warning on a container host.
            var probe_buf: [192]u8 = undefined;
            @memset(&probe_buf, 0);
            const probe_rc = api.xmo_msr_probe(&probe_buf, probe_buf.len);
            const probe_text = probe_buf[0..std.mem.indexOfScalar(u8, &probe_buf, 0) orelse probe_buf.len];
            if (probe_rc != 0) {
                logger.info("msr: not applying the preset by itself ({s}); --msr tries anyway", .{probe_text});
                return false;
            }
            logger.info("msr: {s}", .{probe_text});
        },
    }

    var report_buf: [192]u8 = undefined;
    @memset(&report_buf, 0);
    const rc = api.xmo_msr_apply(@intFromBool(opts.msr_restore), &report_buf, report_buf.len);
    const text = report_buf[0..std.mem.indexOfScalar(u8, &report_buf, 0) orelse report_buf.len];

    switch (rc) {
        0 => {
            logger.info("msr: {s}", .{text});

            return true;
        },
        2 => {
            logger.warn("msr: {s}", .{text});

            return true;
        },
        else => {
            logger.warn("msr not applied: {s}", .{text});

            return false;
        },
    }
}

test "a fee session mines to the developer wallet on the user's own pool" {
    const pool = options.Pool{
        .host = "pool.example.com",
        .port = 3333,
        .user = "user-wallet",
        .rig_id = "rig-1",
    };

    // The user's own session is left exactly as configured.
    const mine = feeSessionPool(pool, false);
    try std.testing.expectEqualStrings("user-wallet", mine.user);
    try std.testing.expectEqualStrings("rig-1", mine.rig_id.?);
    try std.testing.expectEqual(@as(?api.Algo, null), mine.algo);

    // The fee session keeps host, port and transport, swaps the wallet, and
    // pins Monero: the developer address is a Monero address.
    const dev = feeSessionPool(pool, true);
    try std.testing.expectEqualStrings(fee.wallet, dev.user);
    try std.testing.expectEqualStrings("pool.example.com", dev.host);
    try std.testing.expectEqual(@as(u16, 3333), dev.port);
    try std.testing.expectEqualStrings("zmrig-fee", dev.rig_id.?);
    try std.testing.expectEqual(@as(?api.Algo, .rx_0), dev.algo);

    // And the user's copy is untouched by the swap.
    try std.testing.expectEqualStrings("user-wallet", pool.user);
}

/// The connection a fee session uses: the same pool and the same transport as
/// the user's, with the developer's Monero address in the login. A second
/// hardcoded pool would be one more thing that can be down when the fee is due,
/// and the coin has to be Monero -- that address cannot be paid on the ArQmA,
/// Wownero, Graft, Safex, Yada or Scala networks, so the login is pinned.
fn feeSessionPool(pool: options.Pool, donating: bool) options.Pool {
    if (!donating) return pool;

    var dev = pool;
    dev.user = fee.wallet;
    dev.rig_id = "zmrig-fee";
    dev.algo = .rx_0;

    return dev;
}

fn printConfigSummary(opts: *const options.Options) !void {
    var out = std.io.getStdOut().writer();

    try out.print("config ok\n", .{});

    for (opts.pools.items) |pool| {
        try out.print("  pool    {s}://{s}:{d}{s} user={s} algo={s}\n", .{
            pool.transport.label(),
            pool.host,
            pool.port,
            if (pool.transport.usesWs()) (pool.ws_path orelse "/") else "",
            pool.user,
            if (opts.poolAlgo(&pool)) |algo| algo.label() else if (opts.algo_all or pool.algo_all) "auto (all RandomX variants)" else "pool decides",
        });

        if (pool.connect_host) |host| {
            try out.print("  route   connect {s}:{d}, Host: {s}\n", .{
                host,
                pool.connect_port orelse pool.port,
                pool.host_header orelse pool.host,
            });
        }
        if (pool.proxy_spec.kind != .none) {
            try out.print("  proxy   {s} {s}:{d}\n", .{ @tagName(pool.proxy_spec.kind), pool.proxy_spec.host, pool.proxy_spec.port });
        }

        // The address is the one field a `--check` can prove wrong without a
        // network, so it is stated as a fact rather than left to the first
        // rejected login.
        const cut = std.mem.indexOfAny(u8, pool.user, "./") orelse pool.user.len;
        const address = pool.user[0..cut];
        if (address.len == 95 or address.len == 106) {
            const verdict = wallet.check(address);
            if (verdict.ok) {
                try out.print("  wallet  {s} {s} {s}\n", .{
                    wallet.kindLabel(verdict.kind),
                    wallet.netLabel(verdict.net),
                    if (verdict.net == .mainnet) "checksum verified" else "not payable on mainnet",
                });
            } else {
                try out.print("  wallet  INVALID: {s}\n", .{verdict.reason});
                // What it means depends on the algorithm, and saying the wrong
                // one is worse than saying nothing: under rx/0 this rig mines
                // for nobody and will not start; under another coin's algorithm
                // the login may simply be that coin's address, which this
                // repository does not claim to know.
                if (firstAlgo(opts) == .rx_0) {
                    try out.print("          this rig would mine and never be paid, so it will not start; zmrig --check-wallet {s}\n", .{address});
                } else {
                    try out.print("          not a Monero address: if this is another coin's address, mining is unaffected (--allow-bad-wallet silences the check)\n", .{});
                }
            }
        }
    }

    try out.print("  threads {d} (default would be {d})\n", .{ opts.threads orelse miner_mod.defaultThreads(miner_mod.cpuCount()), miner_mod.defaultThreads(miner_mod.cpuCount()) });
    if (opts.priority != -1) {
        try out.print("  priority {d}\n", .{opts.priority});
    }
    if (opts.affinity_mask) |mask| {
        const cpus = miner_mod.Miner.affinityCpus(mask);
        if (cpus == 0) {
            // An empty mask silently means "no pinning" otherwise.
            try out.print("  affinity 0x{x} selects no CPU; it will be ignored\n", .{mask});
        } else {
            try out.print("  affinity 0x{x} ({d} cpu(s))\n", .{ mask, cpus });
        }
    }
    // Which CPU each thread will actually run on. This is the line that would
    // have caught the AMD pinning bug: it turns "8 threads" into "8 threads on
    // 8 distinct cores" or, when something is wrong, into a visible duplicate.
    if (opts.affinity and opts.affinity_mask == null) {
        var cpus_buf: [256]topology.Cpu = undefined;
        const cpus = topology.cpuMap(&cpus_buf);

        // A unit with CPUAffinity= (or a taskset wrapper) can hand us a subset
        // of the machine. Saying so turns "why is it only using 2 of 16 cores"
        // from a mystery into one line.
        var all_buf: [256]topology.Cpu = undefined;
        const all = topology.cpuMapAll(&all_buf);
        if (all.len > cpus.len) {
            try out.print("  affinity process allows {d} of {d} online cpu(s)\n", .{ cpus.len, all.len });
        }

        var order_buf: [miner_mod.max_threads]usize = undefined;
        const profile: topology.Profile = switch (opts.profile) {
            .watt => .watt,
            .free, .auto => .free,
        };
        const threads = @min(opts.threads orelse miner_mod.defaultThreads(miner_mod.cpuCount()), order_buf.len);
        const order = topology.selectCpus(profile, cpus, &order_buf);

        var line_buf: [256]u8 = undefined;
        var stream = std.io.fixedBufferStream(&line_buf);
        const w = stream.writer();

        var i: usize = 0;
        while (i < threads) : (i += 1) {
            w.print("{s}{d}", .{ if (i == 0) "" else ",", order[i % @max(order.len, 1)] }) catch break;
        }

        const cores = if (cpus.len > 0) topology.physicalCores(cpus.len) else cpus.len;
        try out.print("  cpus    [{s}] on {d} cpu(s), {d} physical core(s)\n", .{ stream.getWritten(), cpus.len, cores });
    }
    if (opts.init_threads > 0) {
        try out.print("  dataset  built with {d} thread(s)\n", .{opts.init_threads});
    }
    if (opts.user_agent) |ua| {
        try out.print("  agent   {s}\n", .{ua});
    }

    try out.print("  mode    {s}, huge pages {s}, jit {s}\n", .{
        @tagName(opts.mode),
        if (opts.huge_pages) "on" else "off",
        if (opts.jit) "on" else "off",
    });

    // What the process can actually allocate, and *why* when the two numbers
    // differ. `/proc/meminfo` is not namespaced, so `docker run --memory=1g` on a
    // 32 GB host reports the host: `--check` said "32 GB" and the container was
    // OOM-killed during startup. The cgroup limit is the number that decides
    // whether fast mode fits, so it is printed next to it.
    {
        const budget = miner_mod.usableMemory();
        var budget_buf: [192]u8 = undefined;
        if (miner_mod.memoryBudget()) |cgroup| {
            try out.print("  budget  {s}\n", .{
                std.fmt.bufPrint(&budget_buf, "{d} MB usable of {d} MB total: the cgroup limit is {d} MB, {d} MB of it already in use", .{
                    budget / (1024 * 1024), miner_mod.totalMemory() / (1024 * 1024),
                    cgroup.limit / (1024 * 1024), (cgroup.limit - cgroup.available) / (1024 * 1024),
                }) catch "cannot describe the memory budget",
            });
        } else {
            try out.print("  budget  {s}\n", .{
                std.fmt.bufPrint(&budget_buf, "{d} MB usable of {d} MB total (no cgroup limit)", .{
                    budget / (1024 * 1024), miner_mod.totalMemory() / (1024 * 1024),
                }) catch "cannot describe the memory budget",
            });
        }

        // And the verdict that follows from it, because "mode auto" is not an
        // answer: what an operator wants to know is whether this box will run
        // the 2 GiB dataset or rebuild it line by line at a tenth of the speed.
        {
            const algo = firstAlgo(opts);
            const fit_sizes = sizesFor(algo);
            const fits = memory_mod.fullMemory(fit_sizes, opts.mode, budget);
            var fit_buf: [192]u8 = undefined;
            if (fits) {
                try out.print("  fit     {s}\n", .{
                    std.fmt.bufPrint(&fit_buf, "fast mode fits: {d} MB needed, {d} MB usable", .{
                        (fit_sizes.total() + memory_mod.slack_bytes) / (1024 * 1024), budget / (1024 * 1024),
                    }) catch "cannot describe the fit",
                });
            } else {
                try out.print("  fit     {s}\n", .{
                    std.fmt.bufPrint(&fit_buf, "light mode: {d} MB needed, {d} MB usable -> no dataset, about 10x slower", .{
                        (fit_sizes.total() + memory_mod.slack_bytes) / (1024 * 1024), budget / (1024 * 1024),
                    }) catch "cannot describe the fit",
                });
            }
        }
    }

    // The single most common reason a VPS mines 18% slower than it should is
    // that nobody reserved huge pages. Say it during --check, before the user
    // spends a night comparing screenshots of hashrate.
    if (opts.huge_pages) {
        // Say how much this coin needs, not just whether the pool is empty: on a
        // host sized for Panthera (192 MB) a Monero run needs 2336 MB and the
        // number is the only way to find that out before starting.
        const algo = firstAlgo(opts);
        // Decision-aware: under `mode auto` in a memory-limited container this
        // is the cache alone, which is what the miner will map.
        const need_mb = plannedMemoryMb(opts);
        var mem_buf: [160]u8 = undefined;

        try out.print("  memory  {s}\n", .{
            std.fmt.bufPrint(&mem_buf, "{s} maps {d} MB, {d} pages of 2 MiB (or {d} of 1 GiB): {s}", .{
                algo.label(), need_mb, (need_mb + 1) / 2, (need_mb + 1023) / 1024, hugePageStatus(opts),
            }) catch "cannot describe the memory this mode needs",
        });

        // 1 GiB pages cannot be reserved after the machine has fragmented, so
        // the pool either exists at boot or never will. Saying whether the
        // mapper's first choice is available turns a silent fallback into a
        // decision the operator can take.
        try out.print("  1g      {s}\n", .{giganticStatus(need_mb)});

        // Reserved pages are one way to get 2 MiB pages; transparent huge pages
        // are the other, and on most hosts it is the only one an unprivileged
        // user has. Saying which one is in play turns "huge pages: 0" from a
        // scare into an answer.
        try out.print("  thp     {s}\n", .{thpStatus()});
    }

    // The fee belongs in the summary: it is the one line of config that costs
    // money if the operator did not read it.
    if (opts.donate_percent == 0) {
        try out.print("  donate  off: 0% of mining time, nothing mined for the developer\n", .{});
    } else {
        try out.print("  donate  {d}% of Monero (rx/0) mining time to {s}, {d} s every {d} min (--donate-level=0 turns it off)\n", .{
            opts.donate_percent,
            fee.wallet,
            @divTrunc(@as(i64, fee.start_ms), 1000),
            @divTrunc(@as(i64, fee.start_ms) * 100, @as(i64, opts.donate_percent) * 60 * 1000),
        });
    }

    // The thermal policy. Printed even when it is off, because "why did my rig
    // slow down at night" has two answers and only one of them is the pool.
    try out.print("  thermal {s}\n", .{thermalSummary(opts)});

    // MSR is read-only here: probe the first CPU, never write during --check.
    var msr_buf: [192]u8 = undefined;
    const msr_rc = api.xmo_msr_probe(&msr_buf, msr_buf.len);
    try out.print("  msr     {s} ({s})\n", .{
        msr_buf[0..std.mem.indexOfScalar(u8, &msr_buf, 0) orelse msr_buf.len],
        switch (opts.msr) {
            .off => "off: --no-msr, or 'msr: false' in the config",
            .on => "on: --msr",
            .auto => if (msr_rc == 0)
                "auto: this machine can take it, so the preset is applied"
            else
                "auto: the preset is skipped here; --msr tries anyway",
        },
    });
}

/// Every path that allocates RandomX memory goes through here, so the huge page
/// reservation is never skipped because a caller forgot it (the benchmark path
/// did exactly that: it mined for 26 s at 855 H/s while the pages sat unused).
fn startMiner(logger: *@import("log.zig").Logger, opts: *const options.Options) !miner_mod.Miner {
    autoReserveHugePages(opts, logger);

    return miner_mod.Miner.init(logger, opts);
}


/// Turns `--profile` into one of the two concrete modes and applies the thread
/// count it implies. Explicit `-t` always wins: a user who measured their own
/// machine should not have it second-guessed.
fn resolveProfile(opts: *options.Options, logger: *@import("log.zig").Logger) topology.Profile {
    const logical = miner_mod.cpuCount();
    const physical = topology.physicalCores(logical);
    // A cgroup CPU quota is not an affinity mask: under `docker --cpus=2`,
    // `systemd CPUQuota=200%` or a Kubernetes limit the process still sees every
    // CPU, so the heuristic below would ask for one thread per physical core and
    // the whole group would then be throttled together - slower than the same
    // work in fewer threads. Only the default is capped; `-t` is never changed.
    const quota = topology.quotaCpus();

    const profile: topology.Profile = switch (opts.profile) {
        .free => .free,
        .watt => .watt,
        // `auto` is throughput-first too. Battery state is not consent to
        // sacrifice hashrate; watt mode is opt-in via `--profile=watt`.
        .auto => .free,
    };

    // A profile that asks for threads the machine does not have is a profile
    // that cannot be honoured. The case is real: `--profile=watt` written into
    // a config on a 32-core server, then the same config carried to a 4-core
    // laptop, where `physical` is 4 but the saved `cpu.threads` is 16. Say it
    // and lower the number instead of failing at startup.
    if (opts.threads) |wanted| {
        const usable = topology.threadsFor(.free, logical, physical);
        if (wanted > usable) {
            logger.warn("config asks for {d} thread(s) but this machine has {d}; using {d}", .{ wanted, usable, usable });
            opts.threads = usable;
        }
    }

    if (opts.profile == .auto) {
        logger.debug("profile auto -> {s} (throughput-first, {d} physical of {d} logical cpu)", .{
            topology.profileName(profile), physical, logical,
        });
    }

    if (opts.threads == null) {
        var wanted = topology.threadsFor(profile, logical, physical);

        if (quota) |cpus| {
            if (cpus < wanted) {
                logger.info("cpu quota: {d} cpu(s) available of {d} visible, using {d} thread(s)", .{ cpus, logical, @max(cpus, 1) });
                wanted = @max(cpus, 1);
            }
        }

        if (wanted != miner_mod.defaultThreads(logical)) {
            // Say it once: the difference between the L3 heuristic and the
            // profile is exactly the thing an autotune run is meant to settle.
            logger.info("profile {s}: {d} thread(s) of {d} logical cpu ({d} physical cores)", .{
                topology.profileName(profile),
                wanted,
                logical,
                physical,
            });
        }
        opts.threads = wanted;
    }

    return profile;
}

/// `--autotune`: measure a handful of thread counts on this machine and print
/// the winner. Runs the same code path as `--bench`, so the numbers are directly
/// comparable with the ones in doc/PERFORMANCE.md.
fn runAutotune(
    allocator: std.mem.Allocator,
    opts: *options.Options,
    profile: topology.Profile,
    logger: *@import("log.zig").Logger,
) !void {
    // Measuring more threads than the cgroup allows would report the throttled
    // number as if it were this machine's best, so the search space is capped
    // for the same reason the default is.
    const quota = topology.quotaCpus();
    const logical = miner_mod.cpuCount();
    const physical = topology.physicalCores(logical);
    const searchable = if (quota) |cpus| @max(@min(logical, cpus), 1) else logical;

    var list_buf: [8]usize = undefined;
    const list = autotune.candidates(profile, searchable, physical, &list_buf);

    var out = std.io.getStdOut().writer();
    try out.print("autotune: profile {s}, {d} logical cpu, {d} physical cores\n", .{
        topology.profileName(profile), logical, physical,
    });
    try out.print("autotune: {d} candidate(s), {d} s of hashing each, dataset builds once per candidate\n\n", .{
        list.len, opts.autotune_seconds,
    });
    try out.print("{s:>8}  {s:>12}  {s}\n", .{ "threads", "hashrate", "verdict" });

    var best = autotune.Trial{ .threads = 0, .rate = 0 };
    const margin = 0.02;

    for (list) |threads| {
        // One fixed-duration trial per candidate. `benchmark` builds its own
        // dataset, so the wall clock per candidate is dataset init (~16 s) plus
        // the requested sample window. A zero hash limit disables early stop:
        // using `threads * 2000` here made fast CPUs finish well before the
        // advertised autotune duration and gave candidates unequal samples.
        var trial_opts = opts.*;
        trial_opts.threads = threads;
        trial_opts.bench_hashes = 0;

        const measure = benchmark(allocator, &trial_opts, opts.autotune_seconds, 0) catch |e| {
            try out.print("{d:>8}  {s:>12}  {s}\n", .{ threads, "-", @errorName(e) });
            continue;
        };

        // The short autotune window is intentionally measured as a single
        // equal-length average. `steady_rate` is a rolling window and can be
        // based on only a few samples here; taking its maximum over the average
        // biases the winner upward on whichever candidate got lucky.
        const trial = autotune.Trial{ .threads = threads, .rate = measure.rate };
        const better = autotune.isBetter(trial, best, margin);

        var rate_buf: [32]u8 = undefined;
        const scaled = util.scaleHashrate(trial.rate);

        try out.print("{d:>8}  {s:>12}  {s}\n", .{
            threads,
            std.fmt.bufPrint(&rate_buf, "{d:.3} {s}", .{ scaled.value, scaled.unit }) catch "?",
            if (better) "best so far" else if (best.threads == 0) "-" else "no gain (noise)",
        });

        if (better) best = trial;
    }

    if (best.threads == 0) {
        try out.print("\nautotune: no candidate ran; nothing to recommend\n", .{});
        std.process.exit(1);
    }

    var rate_buf: [32]u8 = undefined;
    const scaled = util.scaleHashrate(best.rate);
    const candidate_threads = miner_mod.defaultThreads(logical);

    try out.print("\nbest: {d} thread(s) at {s} {s}\n", .{
        best.threads,
        std.fmt.bufPrint(&rate_buf, "{d:.3}", .{scaled.value}) catch "?",
        scaled.unit,
    });

    // One machine-readable line, last in the block above it: the installer
    // parses this instead of the prose, so re-wording the table cannot break
    // `oneclick.sh tune`. Values are plain integers/decimals, no units.
    try out.print("autotune-best-threads={d}\nautotune-best-rate={d:.3}\nautotune-rate-unit={s}\n", .{
        best.threads, best.rate, scaled.unit,
    });

    // The heuristic is reported next to the winner, because the difference is
    // the reason this command exists: it is the gap the user was mining with.
    if (best.threads == candidate_threads) {
        try out.print("the default heuristic already picks {d} thread(s) on this machine\n", .{candidate_threads});
    } else {
        try out.print("the default heuristic picks {d} thread(s): this machine was leaving hashrate on the table\n", .{candidate_threads});
    }

    // The config file reads `cpu.threads` (XMRig's schema) and nothing else, so
    // that is the spelling to print: `"threads": 2` at the top of a config is
    // not read, and a recommendation that does nothing is worse than none.
    try out.print("\nkeep it:\n  \"cpu\": {{\"threads\": {d}}}\n  or on the command line: -t {d}\n", .{ best.threads, best.threads });
    logger.debug("autotune finished", .{});
}

/// Reserve huge pages when the kernel has none, we are root and the user did
/// not opt out. Never fatal: an unprivileged miner keeps mining on THP.
fn autoReserveHugePages(opts: *const options.Options, logger: *@import("log.zig").Logger) void {
    if (!opts.huge_pages or !opts.auto_hugepages) return;

    const algo = firstAlgo(opts);
    // Reserving pages for a dataset the miner is about to decline would take
    // RAM away from the machine for nothing: ask the same question it asks.
    const need_mb = plannedMemoryMb(opts);
    const before = hugepages_mod.read();

    switch (hugepages_mod.shouldReserve(need_mb, true, before)) {
        .enough => return,
        .unsupported => return,
        .reserve => {},
    }

    const want = hugepages_mod.pagesFor(need_mb, before.page_kb);
    const after = hugepages_mod.reserve(want) orelse {
        // Not root is the normal case here. Whether that matters depends on
        // transparent huge pages: with THP in `madvise` the kernel collapses
        // this mapping to 2 MiB pages anyway (measured: 99% of a 2336 MB
        // rx/0 mapping), and the miner verifies that figure after the dataset
        // is built. With THP off, the warning is real and worth acting on.
        switch (hugepages_mod.thp()) {
            .never, .unknown => logger.warn("huge pages: {d} reserved, {d} needed for {d} MB, and transparent huge pages are {s}: RandomX is ~18% slower on 4 KiB pages. Run as root or set vm.nr_hugepages={d}", .{
                before.reserved, want, need_mb, hugepages_mod.thp().label(), want,
            }),
            .always, .madvise => logger.info("huge pages: {d} of {d} reserved; transparent huge pages ({s}) will back the {d} MB mapping instead", .{
                before.reserved, want, hugepages_mod.thp().label(), need_mb,
            }),
        }

        return;
    };

    if (after >= want) {
        logger.info("huge pages: reserved {d} pages of 2 MiB ({d} MB) for {s}, so RandomX reads its cache and dataset through 2 MiB pages", .{
            after, after * before.page_kb / 1024, algo.label(),
        });

        return;
    }

    // Partial success is still a win, but say what is still missing.
    logger.warn("huge pages: only {d} of {d} pages could be reserved (fragmented memory?); mining continues on a mix of page sizes", .{ after, want });
}

/// The algorithm this run will hash first. `--algo` pins one; without it the
/// pool decides, and the honest assumption before the first job is Monero —
/// the largest configuration in the tree, so a reservation made for it covers
/// the others too.
fn firstAlgo(opts: *const options.Options) api.Algo {
    return opts.algo orelse .rx_0;
}

/// Bytes of RandomX memory a mode needs for one algorithm. `auto` resolves
/// exactly the way `Miner.init` does, so `--check` cannot promise 2 MiB pages
/// for a dataset the miner will not build on a small box.
///
/// The number is per algorithm because the configurations are not the same
/// size: RandomX/Scala (Panthera) needs 128 MiB of cache and a 64 MiB dataset,
/// where Monero wants 256 MiB and 2080. Assuming Monero's 2.4 GiB is what made
/// a 512 MiB VPS fall back to light mode on a coin it could have mined in fast
/// mode with 2 MiB pages.
fn sizesFor(algo: api.Algo) memory_mod.Sizes {
    return .{ .cache = algo.cacheBytes(), .dataset = algo.datasetBytes() };
}

fn memoryFor(algo: api.Algo, mode: options.Mode, total_ram: u64) u64 {
    return memory_mod.bytesFor(sizesFor(algo), mode, total_ram);
}

/// The same figure in MiB, rounded up, for the messages and the huge-page plan.
fn memoryMb(algo: api.Algo, mode: options.Mode, total_ram: u64) u64 {
    return memory_mod.mibFor(sizesFor(algo), mode, total_ram);
}

/// The MiB the run will actually map, decided the way `Miner.init` decides it:
/// `usableMemory()` (host RAM and cgroup limit, whichever is smaller), not
/// `totalMemory()`. Passing the host number made `--check` and the huge-page
/// reserve plan a 1 GB container for a 2336 MB dataset under `mode auto`, i.e.
/// it planned for a mapping the miner was about to decline.
fn plannedMemoryMb(opts: *const options.Options) u64 {
    return memoryMb(firstAlgo(opts), opts.mode, miner_mod.usableMemory());
}

/// Reads the kernel's huge page pool and turns it into one sentence a human can
/// act on. Kept separate so --check and the warning in miner.zig agree.
fn hugePageStatus(opts: *const options.Options) []const u8 {
    const needed_mb = plannedMemoryMb(opts);
    const pages_needed = (needed_mb + 1) / 2;

    var buf: [32]u8 = undefined;
    const file = std.fs.openFileAbsolute("/proc/sys/vm/nr_hugepages", .{}) catch return "huge pages: not supported by this kernel";
    defer file.close();

    const n = file.readAll(&buf) catch return "huge pages: cannot read /proc/sys/vm/nr_hugepages";
    const total = std.fmt.parseInt(u64, std.mem.trim(u8, buf[0..n], " \n\r"), 10) catch 0;

    if (total >= pages_needed) return "huge pages reserved, RandomX will use 2 MiB pages";

    // Returning a slice of a thread-local buffer is not possible here, so the
    // caller gets one of a few static messages and the command in the usage
    // text. "0 reserved" on its own is not a verdict: with transparent huge
    // pages on, the mapping is collapsed anyway.
    const thp_ok = switch (hugepages_mod.thp()) {
        .always, .madvise => true,
        .never, .unknown => false,
    };

    if (total == 0) {
        return if (thp_ok)
            "no pages reserved; transparent huge pages collapse the mapping instead"
        else
            "no huge pages and THP off -> 4 KiB pages, ~18% slower; see --help";
    }

    return "fewer pages reserved than this mode needs; see --help";
}

/// Static buffer for `giganticStatus`, which has to return a slice.
var gigantic_summary_buf: [224]u8 = undefined;

/// One line for `--check`: does the mapper's first choice exist?
///
/// RandomX asks for 1 GiB pages before 2 MiB ones, and the pool for them can
/// only be created early in boot — `echo 3 > /sys/kernel/mm/hugepages/\
/// hugepages-1048576kB/nr_hugepages` on a machine that has been up for days
/// either fails or compacts memory for minutes and then fails. So this is
/// information, not a warning: on a fresh install it says which of the two the
/// mapping will use, and how many of them the current mode needs.
fn giganticStatus(need_mb: u64) []const u8 {
    const buf = &gigantic_summary_buf;
    const pages = (need_mb + 1023) / 1024;
    const have = hugepages_mod.giganticMb();

    if (have == 0) {
        return std.fmt.bufPrint(buf, "no pool: this mode would need {d} page(s) of 1 GiB, and the mapping uses 2 MiB pages instead (doc/PERFORMANCE.md has the one-line reservation)", .{pages}) catch "no 1 GiB pool";
    }

    if (have < need_mb) {
        return std.fmt.bufPrint(buf, "{d} MB reserved in 1 GiB pages, {d} MB needed: short by {d} page(s), so the mapping uses 2 MiB pages", .{ have, need_mb, pages - have / 1024 }) catch "1 GiB pool too small";
    }

    return std.fmt.bufPrint(buf, "{d} MB reserved in 1 GiB pages: this mode takes {d} of them and RandomX reads its dataset through 1 GiB pages", .{ have, pages }) catch "1 GiB pool present";
}

/// One line for `--check`: whether the governor is armed, and the number it
/// would act on right now.
fn thermalSummary(opts: *const options.Options) []const u8 {
    const buf = &thermal_summary_buf;
    buf.* = [_]u8{0} ** thermal_summary_buf.len;

    const target = opts.max_temp orelse return std.fmt.bufPrint(buf, "off (--no-thermal: explicitly disabled)", .{}) catch "off";

    const config = thermal.Config.fromTarget(target);
    const reading = readTemperature(opts) orelse
        return std.fmt.bufPrint(buf, "target {d:.0} C, pause at {d:.0} C - but no CPU sensor found: the governor would never act (--thermal-file=PATH overrides the sensor)", .{
            config.target_c, config.critical_c,
        }) catch "on, no sensor";

    return std.fmt.bufPrint(buf, "hold {d:.0} C: {s} {d:.1} C now, step down at {d:.0} C, pause at {d:.0} C (--no-thermal turns it off)", .{
        config.target_c, reading.label(), reading.celsius, config.target_c, config.critical_c,
    }) catch "on";
}

var thermal_summary_buf: [320]u8 = undefined;

/// The temperature the governor should act on: the file if one was given
/// (`--thermal-file`), else the hottest CPU sensor in /sys.
fn readTemperature(opts: *const options.Options) ?thermal.Reading {
    if (opts.thermal_file) |path| {
        const celsius = thermal.readPlainFile(path) orelse return null;
        var reading = thermal.Reading{ .celsius = celsius };
        const name = "file";
        @memcpy(reading.name_buf[0..name.len], name);
        reading.name_len = name.len;

        return reading;
    }

    return thermal.readSys("/sys");
}

/// One line for `--check`: which huge-page mechanism this host has, and what it
/// means. Reserved pages only matter when THP is off, so this is the line that
/// decides whether the number above is a problem.
fn thpStatus() []const u8 {
    return switch (hugepages_mod.thp()) {
        .always => "always: the kernel collapses anonymous memory into 2 MiB pages without being asked",
        .madvise => "madvise (default): the hint this miner sets is honoured, so no root step is needed",
        .never => "never: nothing backs the mapping with 2 MiB pages; reserve pages as root or boot with transparent_hugepage=madvise (~18% hashrate)",
        .unknown => "unknown: this kernel does not report a THP policy; reserve pages as root",
    };
}

/// Detaches from the controlling terminal: the parent returns and the child
/// keeps running with stdin/stdout/stderr on /dev/null.
fn daemonise() !void {
    const pid = try std.posix.fork();
    if (pid != 0) std.process.exit(0);

    _ = std.os.linux.setsid();

    const devnull = try std.posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0);
    defer std.posix.close(devnull);

    try std.posix.dup2(devnull, std.posix.STDIN_FILENO);
    try std.posix.dup2(devnull, std.posix.STDOUT_FILENO);
    try std.posix.dup2(devnull, std.posix.STDERR_FILENO);
}

/// How long to wait before the next connection attempt. A dropped connection
/// comes back in 200 ms instead of `--retry-pause` seconds, and repeated
/// failures back off to the configured pause instead of hammering a dead pool.
/// ±20 % on every retry. A farm that restarts together must not arrive at the
/// pool in the same millisecond: from the other side that is a login flood, and
/// a login flood is exactly what gets an IP banned. Returns `delay_ms` unchanged
/// when the window is too small to matter, so short pauses stay short.
fn jittered(delay_ms: u64, entropy: u64) u64 {
    if (delay_ms < 100) return delay_ms;

    const spread = delay_ms / 5;

    return delay_ms - spread + (entropy % (spread * 2 + 1));
}

fn retryDelayMs(configured_seconds: u32, failures: u32) u64 {
    const configured: u64 = @as(u64, configured_seconds) * 1000;

    if (configured == 0) return 0;

    const backoff: u64 = switch (failures) {
        0, 1 => 200,
        2 => 500,
        3 => 1000,
        else => configured,
    };

    return @min(configured, backoff);
}

fn sleepInterruptibleMs(ms: u64) void {
    var slept: u64 = 0;

    while (slept < ms) : (slept += 100) {
        if (!running.load(.acquire)) return;
        std.time.sleep(100 * std.time.ns_per_ms);
    }
}

fn sleepInterruptible(seconds: u32) void {
    var i: u32 = 0;

    while (i < seconds * 10) : (i += 1) {
        if (!running.load(.acquire)) return;
        std.time.sleep(100 * std.time.ns_per_ms);
    }
}

// --- self test -----------------------------------------------------------------

const vectors = struct {
    const seed = "xmrig-mo-check-hashes seed";
    const input_a = "xmrig-mo-check-hashes input A";
    const input_b = "xmrig-mo-check-hashes input B";
    const input_c = "xmrig-mo-check-hashes input C";

    /// One known answer per configuration, taken from `tests/hash/main.cpp` -
    /// the vectors this repository already trusts. Before this existed the self
    /// test only knew how to hash Monero, so `--self-test --algo=panthera`
    /// happily verified rx/0 and reported success for a coin it never touched.
    /// rx/2 is absent because no coin uses it and upstream v6.26's interpreter
    /// and JIT disagree on it - there is no answer to check against.
    const Known = struct {
        algo: api.Algo,
        hex: []const u8,
    };

    const known = [_]Known{
        .{ .algo = .rx_0, .hex = "1833ff322e60dad7d6885bcd5e0844ec8e4808a47d8d354806668f0c241a6af5" },
        .{ .algo = .rx_wow, .hex = "45896210539d9ba37377b9c186b7343304cd6bf797c75f3d1087ee63f22a73e4" },
        .{ .algo = .rx_arq, .hex = "ca2b7afe5c50ab45296c5457337ff7cf27624139f05ec5d44c1e4ae8bfe95bb6" },
        .{ .algo = .rx_graft, .hex = "c4a9cfd2f0a9359c78f089902b44b42623fbf18a1a01786879bfed3f0be255f7" },
        .{ .algo = .rx_sfx, .hex = "3b88936e289ff3240dc074b289fe6464194bdfe31a80c9dc10c9c1eaa1975513" },
        .{ .algo = .rx_yada, .hex = "04d68fb9c445f4437dfce6ebb8028367b060140066ebaa416a4cd2ca63cdb723" },
        .{ .algo = .rx_xla, .hex = "1805aa4fd26f5686dada26d9e16ccb290811b2a79404fdd1064f1ca092902212" },
    };
};

fn selfTest(allocator: std.mem.Allocator, primary: api.Algo, light_only: bool) !bool {
    _ = allocator;

    var failures: usize = 0;
    const out = std.io.getStdOut().writer();

    try out.print("hash engine: {s}\n", .{api.xmo_engine_name()});

    // Light mode proves the cache, the JIT and every algorithm's program: the
    // cache is what defines the hash, and it fits in a few hundred MiB, so all
    // seven configurations can be checked in one run on any machine.
    for (vectors.known) |known| {
        const checked = lightCheck(known.algo, known.hex, out) catch |e| {
            try out.print("FAIL {s} light mode: {s}\n", .{ known.algo.label(), @errorName(e) });
            failures += 1;

            continue;
        };

        if (!checked) failures += 1;
    }

    // Full memory mode must produce the same hashes. It needs this
    // algorithm's dataset, so it only runs when the machine can hold it right
    // now - a running miner that already owns the pages would be OOM-killed.
    const known = knownFor(primary) orelse vectors.known[0];
    const sizes = memory_mod.Sizes{ .cache = primary.cacheBytes(), .dataset = primary.datasetBytes() };
    const need = sizes.total() + memory_mod.slack_bytes;

    if (light_only) {
        try out.writeAll("SKIP full-memory test (light mode requested)\n");
    } else if (miner_mod.totalMemory() < need or miner_mod.memoryForDataset() < sizes.total()) {
        try out.writeAll("SKIP full-memory test (not enough free RAM while the miner is running)\n");
    } else {
        var engine_full = api.Wrapped.create(primary, .{ .full_memory = true }) catch null;
        if (engine_full) |*full| {
            defer full.destroy();

            full.seed(vectors.seed, miner_mod.cpuCount()) catch {
                try out.writeAll("FAIL cannot initialise the dataset\n");

                return false;
            };

            const full_vm = full.createVm(true) catch {
                try out.writeAll("FAIL cannot create a full-memory VM\n");

                return false;
            };
            defer api.xmo_vm_free(full_vm);

            var hash_full: [32]u8 = undefined;
            api.xmo_hash(full_vm, vectors.input_a.ptr, vectors.input_a.len, &hash_full);

            var expected: [32]u8 = undefined;
            _ = try util.hexToBytes(&expected, known.hex);

            if (std.mem.eql(u8, &hash_full, &expected)) {
                try out.print("PASS {s} full-memory dataset matches the cache\n", .{primary.label()});
            } else {
                try out.print("FAIL {s} full-memory hash differs from the reference\n", .{primary.label()});
                failures += 1;
            }
        } else {
            try out.writeAll("SKIP full-memory test (not enough memory for the dataset)\n");
        }
    }

    if (failures == 0) {
        try out.writeAll("\nself test passed\n");
    } else {
        try out.print("\n{d} check(s) failed\n", .{failures});
    }

    return failures == 0;
}

fn knownFor(algo: api.Algo) ?vectors.Known {
    for (vectors.known) |known| {
        if (known.algo == algo) return known;
    }

    return null;
}

/// One light-mode engine, one reference hash, plus the pipelined path. Returns
/// false when the hash is wrong; errors mean the engine could not start.
fn lightCheck(algo: api.Algo, hex: []const u8, out: anytype) !bool {
    var engine = try api.Wrapped.create(algo, .{ .full_memory = false });
    defer engine.destroy();

    try engine.seed(vectors.seed, 1);

    const vm = try engine.createVm(false);
    defer api.xmo_vm_free(vm);

    var expected: [32]u8 = undefined;
    _ = try util.hexToBytes(&expected, hex);

    var hash_a: [32]u8 = undefined;
    var hash_b: [32]u8 = undefined;
    api.xmo_hash(vm, vectors.input_a.ptr, vectors.input_a.len, &hash_a);
    api.xmo_hash(vm, vectors.input_b.ptr, vectors.input_b.len, &hash_b);

    if (!std.mem.eql(u8, &hash_a, &expected)) {
        const got = try util.bytesToHex(std.heap.page_allocator, &hash_a);
        defer std.heap.page_allocator.free(got);

        try out.print("FAIL {s} reference vector\n  got  {s}\n  want {s}\n", .{ algo.label(), got, hex });

        return false;
    }

    try out.print("PASS {s} reference vector\n", .{algo.label()});

    var temp: [8]u64 align(64) = undefined;
    var next_a: [32]u8 = undefined;
    var next_b: [32]u8 = undefined;

    api.xmo_hash_first(vm, vectors.input_a.ptr, vectors.input_a.len, &temp);
    api.xmo_hash_next(vm, &temp, vectors.input_b.ptr, vectors.input_b.len, &next_a);
    api.xmo_hash_next(vm, &temp, vectors.input_c.ptr, vectors.input_c.len, &next_b);

    if (!std.mem.eql(u8, &next_a, &hash_a) or !std.mem.eql(u8, &next_b, &hash_b)) {
        try out.print("FAIL {s} pipelined hashing does not match one-shot hashing\n", .{algo.label()});

        return false;
    }

    return true;
}

fn requireMemory(needed_mb: u64) !void {
    const memory = report.checkMemory(needed_mb);
    // `/proc/meminfo` is the host's, and a container's cgroup limit is not in
    // it: `docker run --memory=1g` on a 32 GB host passed this check and was
    // then OOM-killed halfway through building the dataset. Both have to say
    // yes before the 2 GiB allocation is worth starting.
    const usable_mb = miner_mod.usableMemory() / (1024 * 1024);
    if (memory.ok and usable_mb >= needed_mb) return;

    var stderr = std.io.getStdErr().writer();
    if (memory.ok) {
        var why_buf: [128]u8 = undefined;
        const why = if (miner_mod.memoryBudget()) |budget|
            std.fmt.bufPrint(&why_buf, "its cgroup allows {d} MB ({d} MB of it already in use)", .{
                budget.limit / (1024 * 1024), (budget.limit - budget.available) / (1024 * 1024),
            }) catch "its cgroup allows less"
        else
            "other processes are using it";

        try stderr.print(
            "zmrig: this machine can give the dataset {d} MB of the {d} MB it needs: {s}\n" ++
                "       raise the limit, free some memory, or use --mode light\n",
            .{ usable_mb, needed_mb, why },
        );

        std.process.exit(2);
    }

    try stderr.print(
        "zmrig: not enough memory for the {d} MB dataset: {d} MB free in huge pages plus {d} MB available\n" ++
            "       stop other miners (or lower vm.nr_hugepages) and try again, or use --mode light\n",
        .{ needed_mb, memory.huge_free_mb, memory.available_mb },
    );

    std.process.exit(2);
}

// --- benchmark -------------------------------------------------------------------

const Measure = struct {
    hashes: u64 = 0,
    elapsed_ms: i64 = 0,
    /// Hashes / wall time, the number XMRig prints for `--bench`.
    rate: f64 = 0,
    /// The last 10 s window: excludes the ramp after the dataset is built, so
    /// it is the number a dashboard should use for profit estimates.
    steady_rate: f64 = 0,
    huge_pages: usize = 0,
};

fn benchmark(allocator: std.mem.Allocator, opts: *const options.Options, cap_seconds: u64, warmup_seconds: u64) !Measure {
    const logger = &log.global;
    // A benchmark is where the MSR preset matters most: it is the number the
    // user compares against another miner.
    const msr_applied = applyMsr(opts, logger);
    defer if (msr_applied and opts.msr_restore) {
        var buf: [192]u8 = undefined;
        @memset(&buf, 0);
        _ = api.xmo_msr_restore(&buf, buf.len);
    };

    // Deterministic seed so repeated runs are comparable.
    const seed_text = "zmrig benchmark seed 000000000000";
    var seed_bytes: [32]u8 = undefined;
    _ = try util.hexToBytes(&seed_bytes, "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff");

    var miner = try startMiner(logger, opts);
    defer miner.deinit();

    try miner.engine.ensure(opts.algo orelse .rx_0);
    try miner.engine.seedNow(seed_bytes, miner.shared.initThreads());

    var bench_job = job_mod.Job.init();
    @memset(bench_job.blob[0..76], 0);
    bench_job.blob[0] = 0x99;
    bench_job.blob_len = 76;
    bench_job.setId("bench");
    bench_job.setAlgo(opts.algo orelse .rx_0);
    bench_job.target = 1;
    bench_job.has_seed = true;
    bench_job.seed = seed_bytes;

    _ = allocator;
    _ = seed_text;

    try miner.start();
    miner.shared.bench_limit.store(opts.bench_hashes, .release);
    miner.shared.publish(&bench_job);

    // Benchmarks and autotune are still sustained CPU load. Run the same
    // thermal policy as normal mining so a long measurement cannot cook a rig
    // before the service's monitor thread exists.
    var bench_governor: ?thermal.Governor = null;
    if (opts.max_temp) |target| {
        bench_governor = thermal.Governor.init(thermal.Config.fromTarget(target), miner.threadCount());
        if (readTemperature(opts)) |reading| {
            logger.info("benchmark thermal: target {d:.0} C, {s} reads {d:.1} C now; pause at {d:.0} C", .{
                target, reading.label(), reading.celsius, bench_governor.?.config.critical_c,
            });
        } else {
            logger.warn("benchmark thermal: no CPU sensor found; --max-temp cannot act (use --thermal-file=PATH)", .{});
        }
    }

    const started = std.time.milliTimestamp();
    var last_report = started;
    var last_sample = started;

    while (running.load(.acquire) and miner.shared.running.load(.acquire)) {
        std.time.sleep(200 * std.time.ns_per_ms);

        const now = std.time.milliTimestamp();
        const limit_s = @max(cap_seconds, 1) + warmup_seconds;
        if (now - started >= @as(i64, @intCast(limit_s)) * 1000) break;

        // report() reads the samples, so the benchmark has to feed them too
        // (the Monitor thread only runs while mining against a pool).
        if (now - last_sample >= 1000) {
            last_sample = now;
            miner.stats.add(miner.shared.totalHashes());

            if (bench_governor) |*gov| {
                const reading = readTemperature(opts);
                switch (gov.step(now, if (reading) |r| r.celsius else null)) {
                    .none => {},
                    .set_threads => |threads| {
                        miner.shared.setActiveThreads(threads);
                        logger.warn("benchmark thermal: {d:.1} C -> {d} of {d} threads", .{
                            reading.?.celsius, threads, miner.threadCount(),
                        });
                    },
                    .pause => {
                        miner.shared.pause();
                        miner.shared.setActiveThreads(0);
                        logger.warn("benchmark thermal: {d:.1} C; pausing until below {d:.0} C", .{
                            reading.?.celsius, gov.config.resume_c,
                        });
                    },
                    .unpause => {
                        miner.shared.unpause();
                        miner.shared.setActiveThreads(gov.threads);
                        logger.info("benchmark thermal: resumed at {d} thread(s)", .{gov.threads});
                    },
                }
            }
        }

        if (now - last_report >= 10_000) {
            last_report = now;
            miner.report();
        }
    }

    const elapsed_ms = std.time.milliTimestamp() - started;
    const total = miner.shared.totalHashes();
    // Read the counters that live in the engine *before* stopping it: after
    // stop() the huge page bookkeeping is gone (and touching it crashed).
    const huge_pages = miner.hugePages()[0];
    const steady_rate = miner.hashrate(10);

    miner.stop();

    var buf: [32]u8 = undefined;
    const rate = @as(f64, @floatFromInt(total)) * 1000.0 / @as(f64, @floatFromInt(@max(elapsed_ms, 1)));
    const scaled = util.scaleHashrate(rate);

    logger.info("benchmark: {d} hashes in {d} ms = {s}", .{
        total,
        elapsed_ms,
        std.fmt.bufPrint(&buf, "{d:.3} {s}", .{ scaled.value, scaled.unit }) catch "?",
    });

    return .{
        .hashes = total,
        .elapsed_ms = elapsed_ms,
        .rate = rate,
        .steady_rate = steady_rate,
        .huge_pages = huge_pages,
    };
}

test "retry delays are jittered, so a farm does not arrive at once" {
    const testing = std.testing;

    // Always inside ±20 % of the nominal delay, for any entropy.
    var entropy: u64 = 0;
    while (entropy < 20_000) : (entropy += 997) {
        const delay = jittered(5000, entropy);
        try testing.expect(delay >= 4000 and delay <= 6000);
    }

    // Different entropy must actually spread the value, or it is not jitter.
    try testing.expect(jittered(5000, 0) != jittered(5000, 9999));

    // Pauses under 100 ms stay exact: spreading a 50 ms retry buys nothing.
    try testing.expectEqual(@as(u64, 50), jittered(50, 12345));
    try testing.expectEqual(@as(u64, 99), jittered(99, 12345));
}

test "reconnect backoff: quick first tries, then the configured pause" {
    const testing = std.testing;

    // A pool that refuses immediately must not be hammered every 200 ms
    // forever, and a configured pause of 0 must stay 0.
    try testing.expectEqual(@as(u64, 200), retryDelayMs(5, 1));
    try testing.expectEqual(@as(u64, 500), retryDelayMs(5, 2));
    try testing.expectEqual(@as(u64, 1000), retryDelayMs(5, 3));
    try testing.expectEqual(@as(u64, 5000), retryDelayMs(5, 4));
    try testing.expectEqual(@as(u64, 5000), retryDelayMs(5, 99));
    try testing.expectEqual(@as(u64, 0), retryDelayMs(0, 9));

    // retry-pause is in whole seconds, so the shortest non-zero pause is 1 s;
    // the backoff still starts at 200 ms under that cap.
    try testing.expectEqual(@as(u64, 200), retryDelayMs(1, 1));
}


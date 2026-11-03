//! Machine report: a short, paste-able code that describes what this machine
//! mines, how fast, how much power it draws and how many shares it has sent.
//!
//!   zmrig --report                     # 10 s benchmark, print one line
//!   zmrig ... --report-file /run/zmrig.report --report-interval 60
//!
//! The code is `ZMRIG1.` followed by base64url(JSON). It is deliberately
//! compact (a few hundred bytes) so it can be pasted into the web dashboard,
//! mailed to a colleague or written to a file by a unit every minute. The
//! dashboard decodes it locally: nothing is uploaded anywhere.
//!
//! Power is measured, not guessed: RAPL/HWMON counters when the kernel exposes
//! them, a user supplied `--power` value otherwise. The source is part of the
//! payload so a dashboard can say where the number came from.

const std = @import("std");
const builtin = @import("builtin");

pub const code_prefix = "ZMRIG1.";

/// Everything the dashboard needs. Strings are borrowed, not owned.
pub const Snapshot = struct {
    id: []const u8 = "zmrig",
    version: []const u8 = "",
    cpu: []const u8 = "unknown",
    threads: usize = 1,
    cores: usize = 1,
    algo: []const u8 = "auto",
    mode: []const u8 = "auto",
    /// 10 s, 60 s, 15 min, session maximum.
    rates: [4]f64 = .{ 0, 0, 0, 0 },
    /// [allocated, required] 2 MiB pages.
    huge_pages: [2]usize = .{ 0, 0 },
    /// accepted, rejected, failed.
    shares: [3]u64 = .{ 0, 0, 0 },
    hashes: u64 = 0,
    uptime_s: i64 = 0,
    power_watts: ?f64 = null,
    power_source: []const u8 = "none",
    /// Hashes per joule-second, i.e. hashrate / watts. Sent only when a power
    /// number exists; the dashboard reads it as `hw`. This is the number the
    /// watt profile is actually optimising, so it belongs in the payload
    /// instead of being recomputed (badly) by every consumer.
    hashes_per_watt: ?f64 = null,
    pool: []const u8 = "",
    /// "ok", "warming", "degraded", "stalled" or "rejected": what the miner
    /// thinks of its own income right now, so a fleet dashboard can sort by
    /// "machines that are running but earning nothing".
    health: []const u8 = "ok",
    /// The thermal policy, when one is armed: the target in `--max-temp`, the
    /// reading it last acted on, and how many threads it is currently allowing.
    /// A dashboard with a hundred rigs needs these to tell "cool and quiet"
    /// from "has been at its pause limit since 03:00", which a hashrate graph
    /// alone never shows - a throttled rig and a healthy rig at half load look
    /// identical from the pool side.
    temp_limit_c: ?f32 = null,
    temp_c: ?f32 = null,
    active_threads: ?usize = null,
    timestamp: i64 = 0,
};

/// Writes `ZMRIG1.<base64url json>` into `buf` and returns the slice.
/// Needs roughly 900 bytes; returns NoSpaceLeft instead of truncating.
pub fn encode(buf: []u8, snap: Snapshot) ![]const u8 {
    var json_buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&json_buf);
    const w = stream.writer();

    try w.print("{{\"v\":1,\"id\":", .{});
    try writeJsonString(w, snap.id);
    try w.print(",\"ver\":", .{});
    try writeJsonString(w, snap.version);
    try w.print(",\"cpu\":", .{});
    try writeJsonString(w, snap.cpu);
    try w.print(",\"arch\":", .{});
    try writeJsonString(w, @tagName(builtin.target.cpu.arch));
    try w.print(",\"cores\":{d},\"thr\":{d},\"algo\":", .{ snap.cores, snap.threads });
    try writeJsonString(w, snap.algo);
    try w.print(",\"mode\":", .{});
    try writeJsonString(w, snap.mode);
    try w.print(",\"hs\":[{d:.1},{d:.1},{d:.1},{d:.1}]", .{
        snap.rates[0], snap.rates[1], snap.rates[2], snap.rates[3],
    });
    try w.print(",\"hp\":[{d},{d}]", .{ snap.huge_pages[0], snap.huge_pages[1] });
    try w.print(",\"shares\":[{d},{d},{d}]", .{ snap.shares[0], snap.shares[1], snap.shares[2] });
    try w.print(",\"hash\":{d},\"up\":{d}", .{ snap.hashes, snap.uptime_s });

    if (snap.power_watts) |watts| {
        try w.print(",\"pw\":{d:.1},\"pwsrc\":", .{watts});
    } else {
        try w.print(",\"pw\":null,\"pwsrc\":", .{});
    }
    try writeJsonString(w, snap.power_source);

    // Hashes per watt, from the 60 s column (the steadiest short window). A
    // caller can pass it explicitly; otherwise it is derived here, so a report
    // can never claim a power figure and then omit the efficiency that follows
    // from it.
    const efficiency = snap.hashes_per_watt orelse blk: {
        const watts = snap.power_watts orelse break :blk null;
        if (watts <= 0) break :blk null;
        break :blk snap.rates[1] / watts;
    };
    if (efficiency) |hw| {
        try w.print(",\"hw\":{d:.1}", .{hw});
    } else {
        try w.print(",\"hw\":null", .{});
    }

    // Null, not zero, for every one of the three: a report from a miner with no
    // governor must not read as "0 C, 0 threads allowed".
    try w.print(",\"tmax\":", .{});
    if (snap.temp_limit_c) |v| try w.print("{d:.0}", .{v}) else try w.writeAll("null");
    try w.print(",\"tc\":", .{});
    if (snap.temp_c) |v| try w.print("{d:.1}", .{v}) else try w.writeAll("null");
    try w.print(",\"at\":", .{});
    if (snap.active_threads) |v| try w.print("{d}", .{v}) else try w.writeAll("null");

    try w.print(",\"health\":", .{});
    try writeJsonString(w, snap.health);
    try w.print(",\"pool\":", .{});
    try writeJsonString(w, snap.pool);
    try w.print(",\"ts\":{d}}}", .{snap.timestamp});

    const json = json_buf[0..stream.pos];
    const needed = code_prefix.len + std.base64.url_safe_no_pad.Encoder.calcSize(json.len);
    if (buf.len < needed) return error.NoSpaceLeft;

    @memcpy(buf[0..code_prefix.len], code_prefix);
    const encoded = std.base64.url_safe_no_pad.Encoder.encode(buf[code_prefix.len..needed], json);

    return buf[0 .. code_prefix.len + encoded.len];
}

fn writeJsonString(w: anytype, text: []const u8) !void {
    try w.writeByte('"');

    for (text) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }

    try w.writeByte('"');
}

/// "Intel(R) Xeon(R) ..." from /proc/cpuinfo, or "unknown" on other systems.
/// The returned slice points into `buf`.
pub fn cpuModel(buf: []u8) []const u8 {
    const text = readSmallFile("/proc/cpuinfo", buf) orelse return "unknown";

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "model name")) continue;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[colon + 1 ..], " \t\r");

        if (name.len == 0) continue;

        // The buffer is used for the file contents; hand back a copy inside it
        // only if the name does not overlap the part we still need.
        const start = @intFromPtr(name.ptr) - @intFromPtr(text.ptr);
        if (start > 0 and name.len <= buf.len - start) {
            std.mem.copyForwards(u8, buf[0..name.len], buf[start .. start + name.len]);

            return buf[0..name.len];
        }

        return name;
    }

    return "unknown";
}

/// Physical cores, from the topology files the kernel publishes. Falls back to
/// the logical CPU count when they are missing (containers, other systems).
pub fn physicalCores(threads: usize) usize {
    var dir = std.fs.openDirAbsolute("/sys/devices/system/cpu", .{ .iterate = true }) catch return threads;
    defer dir.close();

    var seen: [256]u64 = undefined;
    var seen_count: usize = 0;

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "cpu")) continue;
        if (entry.name.len <= 3) continue;
        if (!std.ascii.isDigit(entry.name[3])) continue;

        var path_buf: [160]u8 = undefined;
        var value_buf: [32]u8 = undefined;

        const package_path = std.fmt.bufPrint(&path_buf, "/sys/devices/system/cpu/{s}/topology/physical_package_id", .{entry.name}) catch continue;
        const package_id = parseFileInt(package_path, &value_buf) orelse continue;

        const core_path = std.fmt.bufPrint(&path_buf, "/sys/devices/system/cpu/{s}/topology/core_id", .{entry.name}) catch continue;
        const core_id = parseFileInt(core_path, &value_buf) orelse continue;

        const id = (@as(u64, @intCast(package_id & 0xffff)) << 32) | @as(u64, @intCast(core_id & 0xffffffff));

        var known = false;
        for (seen[0..seen_count]) |entry_id| {
            if (entry_id == id) {
                known = true;

                break;
            }
        }
        if (known) continue;

        if (seen_count == seen.len) return threads;
        seen[seen_count] = id;
        seen_count += 1;
    }

    if (seen_count == 0) return threads;

    return seen_count;
}

/// Measured package power in watts, when the kernel has a counter for it,
/// otherwise the value the user passed with `--power`.
pub const Power = struct {
    watts: ?f64 = null,
    source: []const u8 = "none",
};

pub fn measurePower(user_watts: ?f64) Power {
    if (user_watts) |watts| {
        if (watts > 0) return .{ .watts = watts, .source = "user" };
    }

    if (readPowerNow()) |watts| return .{ .watts = watts, .source = "hwmon" };

    if (readEnergyDelta("/sys/class/powercap/intel-rapl:0/energy_uj")) |watts| {
        return .{ .watts = watts, .source = "rapl" };
    }

    // AMD exposes its energy counters through hwmon as well.
    if (readHwmonEnergy()) |watts| return .{ .watts = watts, .source = "hwmon" };

    return .{};
}

fn readPowerNow() ?f64 {
    // Laptops (and some BMCs) publish an instantaneous power in microwatts.
    var dir = std.fs.openDirAbsolute("/sys/class/power_supply", .{ .iterate = true }) catch return null;
    defer dir.close();

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        var path_buf: [160]u8 = undefined;
        var value_buf: [32]u8 = undefined;

        const path = std.fmt.bufPrint(&path_buf, "/sys/class/power_supply/{s}/power_now", .{entry.name}) catch continue;
        const micro = parseFileInt(path, &value_buf) orelse continue;
        if (micro <= 0) continue;

        return @as(f64, @floatFromInt(micro)) / 1_000_000.0;
    }

    return null;
}

fn readHwmonEnergy() ?f64 {
    var dir = std.fs.openDirAbsolute("/sys/class/hwmon", .{ .iterate = true }) catch return null;
    defer dir.close();

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        var path_buf: [192]u8 = undefined;

        // zenpower, amd_energy and friends expose energy1_input (microjoules).
        const energy = std.fmt.bufPrint(&path_buf, "/sys/class/hwmon/{s}/energy1_input", .{entry.name}) catch continue;
        if (readEnergyDelta(energy)) |watts| return watts;

        const power = std.fmt.bufPrint(&path_buf, "/sys/class/hwmon/{s}/power1_input", .{entry.name}) catch continue;
        var value_buf: [32]u8 = undefined;
        if (parseFileInt(power, &value_buf)) |micro| {
            if (micro > 0) return @as(f64, @floatFromInt(micro)) / 1_000_000.0;
        }
    }

    return null;
}

/// A single powercap counter read twice. Microjoules over microseconds is
/// watts, so no unit conversion is needed beyond the division.
fn readEnergyDelta(path: []const u8) ?f64 {
    const first = readNumber(path) orelse return null;
    const t0 = std.time.microTimestamp();

    std.time.sleep(250 * std.time.ns_per_ms);

    const second = readNumber(path) orelse return null;
    const t1 = std.time.microTimestamp();

    if (second <= first) return null;

    const elapsed = t1 - t0;
    if (elapsed <= 0) return null;

    const watts = @as(f64, @floatFromInt(second - first)) / @as(f64, @floatFromInt(elapsed));
    if (watts <= 0 or watts > 2000) return null;

    return watts;
}

fn readNumber(path: []const u8) ?u64 {
    var buf: [32]u8 = undefined;
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    const n = file.readAll(&buf) catch return null;
    if (n == 0) return null;

    return std.fmt.parseInt(u64, std.mem.trim(u8, buf[0..n], " \t\r\n"), 10) catch null;
}

fn parseFileInt(path: []const u8, buf: []u8) ?i64 {
    const text = readSmallFile(path, buf) orelse return null;

    return std.fmt.parseInt(i64, std.mem.trim(u8, text, " \t\r\n"), 10) catch null;
}

fn readSmallFile(path: []const u8, buf: []u8) ?[]const u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    const n = file.readAll(buf) catch return null;
    if (n == 0) return null;

    return buf[0..n];
}

test "encode has the prefix and round trips through base64" {
    const testing = std.testing;

    var buf: [1200]u8 = undefined;
    const code = try encode(&buf, .{
        .id = "rig \"one\"",
        .version = "6.32.1",
        .cpu = "Test CPU",
        .rates = .{ 1000, 990, 980, 1010 },
        .shares = .{ 12, 1, 0 },
        .power_watts = 45.5,
        .power_source = "rapl",
        .pool = "pool.example:3333",
        .timestamp = 1700000000,
    });

    try testing.expect(std.mem.startsWith(u8, code, code_prefix));

    const payload = code[code_prefix.len..];
    var decoded: [1024]u8 = undefined;
    const decoded_len = try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload);
    try std.base64.url_safe_no_pad.Decoder.decode(decoded[0..decoded_len], payload);
    const json = decoded[0..decoded_len];

    try testing.expect(std.mem.indexOf(u8, json, "\"id\":\"rig \\\"one\\\"\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"pw\":45.5") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"shares\":[12,1,0]") != null);

    // 990 H/s over 45.5 W, derived because the caller did not pass it.
    try testing.expect(std.mem.indexOf(u8, json, "\"hw\":21.8") != null);
}

test "the thermal policy is in the payload, and absent when there is none" {
    const testing = std.testing;

    // The code is base64 of the JSON, so the assertions have to look at what a
    // decoder sees, not at the transport encoding.
    const decode = struct {
        fn into(code: []const u8, out: []u8) []const u8 {
            const payload = code[code_prefix.len..];
            const len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload) catch return "";
            std.base64.url_safe_no_pad.Decoder.decode(out[0..len], payload) catch return "";
            return out[0..len];
        }
    }.into;

    var buf: [1200]u8 = undefined;
    var json_buf: [1024]u8 = undefined;
    const hot = decode(try encode(&buf, .{
        .temp_limit_c = 72,
        .temp_c = 73.4,
        .active_threads = 7,
    }), &json_buf);
    try testing.expect(std.mem.indexOf(u8, hot, "\"tmax\":72") != null);
    try testing.expect(std.mem.indexOf(u8, hot, "\"tc\":73.4") != null);
    try testing.expect(std.mem.indexOf(u8, hot, "\"at\":7") != null);

    // A miner with no --max-temp reports nulls, never a comfortable-looking 0.
    var plain_buf: [1200]u8 = undefined;
    var plain_json: [1024]u8 = undefined;
    const plain = decode(try encode(&plain_buf, .{}), &plain_json);
    try testing.expect(std.mem.indexOf(u8, plain, "\"tmax\":null") != null);
    try testing.expect(std.mem.indexOf(u8, plain, "\"tc\":null") != null);
    try testing.expect(std.mem.indexOf(u8, plain, "\"at\":null") != null);
}

test "hashes per watt is absent, not zero, when no power is known" {
    const testing = std.testing;

    var buf: [1200]u8 = undefined;
    const code = try encode(&buf, .{
        .rates = .{ 1000, 990, 980, 1010 },
        .power_watts = null,
        .power_source = "none",
    });

    const payload = code[code_prefix.len..];
    var decoded: [1024]u8 = undefined;
    const decoded_len = try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload);
    try std.base64.url_safe_no_pad.Decoder.decode(decoded[0..decoded_len], payload);
    const json = decoded[0..decoded_len];

    // `null`, not 0: a dashboard that divides by it must see "unknown".
    try testing.expect(std.mem.indexOf(u8, json, "\"hw\":null") != null);
}

test "an explicit hashes-per-watt wins over the derived one" {
    const testing = std.testing;

    var buf: [1200]u8 = undefined;
    const code = try encode(&buf, .{
        .rates = .{ 1000, 990, 980, 1010 },
        .power_watts = 100,
        .power_source = "user",
        .hashes_per_watt = 12.5,
    });

    const payload = code[code_prefix.len..];
    var decoded: [1024]u8 = undefined;
    const decoded_len = try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload);
    try std.base64.url_safe_no_pad.Decoder.decode(decoded[0..decoded_len], payload);

    try testing.expect(std.mem.indexOf(u8, decoded[0..decoded_len], "\"hw\":12.5") != null);
}

test "cpuModel never returns an empty string" {
    var buf: [4096]u8 = undefined;
    const model = cpuModel(&buf);

    try std.testing.expect(model.len > 0);
}

/// Cheap pre-flight for `--bench`/`--report`: the RandomX dataset needs the
/// huge page pool, normal RAM, or a mixture of the two. Without this check the
/// process is killed by the OOM killer with no explanation, which is how a
/// report ends up as "Killed" in the shell.
///
/// The pool and ordinary RAM add up because the allocator falls back per
/// mapping: a host with 1200 pages free and 1.2 GB available maps the cache
/// either way. Testing them separately is what made the miner refuse to start
/// on a host that had followed its own advice - `echo 1168 > nr_hugepages`
/// leaves 2336 MB in the pool against a 2404 MB requirement (the dataset, the
/// scratchpads and a 64 MB margin), and `--bench` exited with "not enough
/// memory" on a machine with two gigabytes of it sitting unused.
pub const Memory = struct {
    ok: bool,
    huge_free_mb: u64 = 0,
    available_mb: u64 = 0,
    needed_mb: u64 = 0,
};

pub fn checkMemory(needed_mb: u64) Memory {
    var result = Memory{ .ok = false };

    var buf: [4096]u8 = undefined;
    const text = readSmallFile("/proc/meminfo", &buf) orelse {
        // No /proc: not Linux, let the allocator decide.
        result.ok = true;

        return result;
    };

    var huge_free_pages: u64 = 0;
    var huge_page_kb: u64 = 2048;
    var available_kb: u64 = 0;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const value = parseField(line) orelse continue;

        if (std.mem.startsWith(u8, line, "HugePages_Free:")) {
            huge_free_pages = value;
        } else if (std.mem.startsWith(u8, line, "Hugepagesize:")) {
            huge_page_kb = value;
        } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
            available_kb = value;
        }
    }

    result.huge_free_mb = huge_free_pages * huge_page_kb / 1024;
    result.available_mb = available_kb / 1024;
    result.needed_mb = needed_mb;
    result.ok = result.huge_free_mb + result.available_mb >= needed_mb;

    return result;
}

/// The same rule, without reading /proc: testable, and it is the only part with
/// a decision in it.
pub fn memoryFits(needed_mb: u64, huge_free_mb: u64, available_mb: u64) bool {
    return huge_free_mb + available_mb >= needed_mb;
}

fn parseField(line: []const u8) ?u64 {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const rest = std.mem.trim(u8, line[colon + 1 ..], " \t");

    var end: usize = 0;
    while (end < rest.len and std.ascii.isDigit(rest[end])) : (end += 1) {}
    if (end == 0) return null;

    return std.fmt.parseInt(u64, rest[0..end], 10) catch null;
}

test "parseField reads the first number of a meminfo line" {
    try std.testing.expectEqual(@as(?u64, 1234), parseField("HugePages_Free:     1234"));
    try std.testing.expectEqual(@as(?u64, 2048), parseField("Hugepagesize:       2048 kB"));
    try std.testing.expectEqual(@as(?u64, null), parseField("no colon here"));
}

test "the pool and ordinary RAM are added, because the allocator falls back" {
    const testing = std.testing;

    // 1200 pages free, 1215 MB available, 2404 MB needed: this exact host was
    // refused a benchmark before the rule changed.
    try testing.expect(memoryFits(2404, 2400, 1215));

    // The documented reservation on its own is enough (2336 MB of pool).
    try testing.expect(memoryFits(2404, 2336, 200));

    // A host with no huge pages but plenty of RAM still runs.
    try testing.expect(memoryFits(2404, 0, 3000));

    // And a genuinely small box is still refused: the check has to keep doing
    // its job, or the OOM killer becomes the error message again.
    try testing.expect(!memoryFits(2404, 0, 1215));
    try testing.expect(!memoryFits(2404, 512, 512));
}

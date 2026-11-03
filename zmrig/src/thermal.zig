//! Thermal governor: mine as much as the machine can take, and not one degree more.
//!
//! Every other mode in this miner answers "how fast can this box go". This one
//! answers the harder question: how fast can it go *for months*. The failure it
//! exists for is not a crash - it is a rig that hashes happily at 94 °C for a
//! year and then takes a VRM, a fan bearing or a CPU with it, usually at night,
//! usually on the machine somebody also uses for work.
//!
//! The physical limits that matter here are the ones a farmer cannot see:
//!
//!   * sustained silicon temperature: above `target_c` the failure rate climbs
//!     for every degree, and the clock is already being pulled down by the
//!     hardware, so the hashrate gained is smaller than it looks;
//!   * the thermal time constant: a CPU heats in seconds and cools in minutes,
//!     which is why every rule below has hysteresis. A governor without it
//!     oscillates between two thread counts and averages worse than either.
//!
//! So the policy is: converge on the largest thread count that keeps the
//! hottest sensor at or below the target, and treat the target as a budget
//! rather than a switch. Two levels, deliberately different in urgency:
//!
//!   target_c    - step down lazily (once per `step_ms`). A boost spike or one
//!                 burst of shares is normal and not worth reacting to.
//!   max_c       - step down now (once per `fast_ms`). The hardware is already
//!                 past the point where it protects itself; waiting 30 s here
//!                 is 30 s of heat the machine did not have to take.
//!   critical_c  - stop hashing altogether, and stay stopped until the sensor
//!                 is back under `resume_c`. At one thread over this limit
//!                 there is nothing left to shed: the radiator is the problem.
//!
//! Stepping back up is slow on purpose: `recover_ms` below `target_c -
//! hysteresis_c`. Cooling down for two minutes and heating up in ten seconds is
//! how a fan dies, and it also makes the measured average worse.
//!
//! The state machine is pure. `step` takes a timestamp and a temperature and
//! returns what to do, so every rule is tested without sysfs, a clock or a
//! CPU: see the tests at the bottom of this file.

const std = @import("std");

pub const Config = struct {
    /// The temperature the governor aims to hold. Everything below is derived
    /// from it unless set explicitly.
    target_c: f32 = 75,
    /// Hard cap: react within `fast_ms`, not `step_ms`.
    max_c: f32 = 83,
    /// Stop hashing.
    critical_c: f32 = 90,
    /// Come back from `critical_c` only below this.
    resume_c: f32 = 68,
    /// Cool side of the band: step up only below `target_c - hysteresis_c`.
    hysteresis_c: f32 = 5,
    /// Minimum spacing between two step-downs at the target.
    step_ms: i64 = 30_000,
    /// Minimum spacing between two step-downs above the hard cap. Short,
    /// because this is the band where damage happens.
    fast_ms: i64 = 5_000,
    /// How long the sensor must stay below the cool edge before a thread is
    /// given back. Minutes, not seconds: see the note on the thermal constant.
    recover_ms: i64 = 120_000,
    /// Never go below this many mining threads; pause instead of idling.
    min_threads: usize = 1,

    /// A target is the only thing a user should have to choose. The bands are
    /// placed around it so that "keep my machine under 70" is one number, and
    /// so that the numbers cannot be set into an order that makes no sense
    /// (a max below the target, a resume above the critical).
    pub fn fromTarget(target: f32) Config {
        const t = std.math.clamp(target, 45, 95);

        return .{
            .target_c = t,
            .max_c = t + 8,
            .critical_c = t + 15,
            .resume_c = t - 7,
        };
    }
};

pub const Action = union(enum) {
    none,
    /// Run this many threads from now on.
    set_threads: usize,
    /// Stop hashing but stay connected and building nothing: the dataset stays
    /// in RAM, so resuming does not pay the 20-40 s rebuild.
    pause,
    /// Opposite of `pause`. Spelled `unpause` because `resume` is a keyword.
    unpause,
};

pub const Governor = struct {
    config: Config = .{},
    /// The thread count the user asked for. The governor never goes above it.
    ceiling: usize = 1,
    /// Currently allowed threads. Workers above this index park.
    threads: usize = 1,
    paused: bool = false,

    /// Hottest reading seen since start, for the report and `--check`.
    peak_c: f32 = 0,
    last_c: f32 = 0,

    step_downs: u32 = 0,
    step_ups: u32 = 0,
    pauses: u32 = 0,
    resumes: u32 = 0,

    /// When the last step in each direction happened. Optional rather than a
    /// pair of zeroes: `now` is allowed to be 0, and "stepped down at time 0"
    /// and "never stepped down" are different states.
    last_down_ms: ?i64 = null,
    last_up_ms: ?i64 = null,
    /// Since when the sensor has been under the cool edge. A flag, not a
    /// sentinel timestamp: 0 is a perfectly ordinary `now` and treating it as
    /// "no streak" meant a governor started at epoch 0 could never climb back.
    below_since_ms: i64 = 0,
    below: bool = false,

    const Self = @This();

    /// Milliseconds since `since`; a null `since` is "so long ago that any
    /// minimum interval has passed".
    fn elapsed(now_ms: i64, since: ?i64) i64 {
        return if (since) |s| now_ms - s else std.math.maxInt(i64);
    }

    pub fn init(config: Config, threads: usize) Self {
        const n = @max(threads, 1);

        return .{
            .config = config,
            .ceiling = n,
            .threads = n,
        };
    }

    /// One decision. Called about once a second with the hottest sensor; a
    /// missing reading is passed as null and changes nothing - a machine whose
    /// sensor died must not lose its thread count because of it.
    pub fn step(self: *Self, now_ms: i64, reading: ?f32) Action {
        const t = reading orelse return .none;

        self.last_c = t;
        if (t > self.peak_c) self.peak_c = t;

        if (self.paused) {
            if (t > self.config.resume_c) return .none;

            self.paused = false;
            self.resumes += 1;
            self.below = false;

            // Come back at one thread, then climb: the point of the pause was
            // that this machine could not dissipate what it was making.
            self.threads = @max(self.config.min_threads, 1);
            self.last_up_ms = now_ms;

            return .unpause;
        }

        // Above the point where the hardware is already throttling itself.
        if (t >= self.config.max_c) {
            self.below = false;

            if (self.threads > self.config.min_threads) {
                if (elapsed(now_ms, self.last_down_ms) < self.config.fast_ms) return .none;

                self.threads -= 1;
                self.step_downs += 1;
                self.last_down_ms = now_ms;

                return .{ .set_threads = self.threads };
            }

            // One thread and still this hot: nothing left to shed.
            self.paused = true;
            self.pauses += 1;

            return .pause;
        }

        if (t >= self.config.critical_c) {
            // Unreachable while critical_c > max_c, which `fromTarget` keeps
            // true; kept so a hand-written Config cannot silently disable the
            // pause. See the ordering test below.
            self.paused = true;
            self.pauses += 1;

            return .pause;
        }

        // At the budget: shed work, but only once per `step_ms`, because the
        // next 30 s of samples say whether this was a spike or the new normal.
        if (t >= self.config.target_c) {
            self.below = false;

            if (self.threads <= self.config.min_threads) return .none;
            if (elapsed(now_ms, self.last_down_ms) < self.config.step_ms) return .none;

            self.threads -= 1;
            self.step_downs += 1;
            self.last_down_ms = now_ms;

            return .{ .set_threads = self.threads };
        }

        // Cool side of the band.
        if (t <= self.config.target_c - self.config.hysteresis_c) {
            if (!self.below) {
                self.below = true;
                self.below_since_ms = now_ms;
            }

            if (self.threads >= self.ceiling) return .none;
            if (now_ms - self.below_since_ms < self.config.recover_ms) return .none;
            if (elapsed(now_ms, self.last_up_ms) < self.config.step_ms) return .none;

            self.threads += 1;
            self.step_ups += 1;
            self.last_up_ms = now_ms;
            self.below = false;

            return .{ .set_threads = self.threads };
        }

        // Inside the hysteresis band: remembering a cool streak across a spike
        // would let the thread count climb on an average that never existed.
        self.below = false;

        return .none;
    }

    /// True when the governor has anything to say about this machine at all.
    pub fn throttled(self: *const Self) bool {
        return self.paused or self.threads < self.ceiling;
    }
};

// --------------------------------------------------------------------------
// Reading the sensors
// --------------------------------------------------------------------------

/// A temperature and where it came from, for the log line that has to be
/// believable six months later ("which sensor was at 84 °C?").
pub const Reading = struct {
    celsius: f32 = 0,
    name_buf: [32]u8 = [_]u8{0} ** 32,
    name_len: usize = 0,

    pub fn label(self: *const Reading) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    fn set(self: *Reading, name: []const u8) void {
        self.name_len = @min(name.len, self.name_buf.len);
        @memcpy(self.name_buf[0..self.name_len], name[0..self.name_len]);
    }
};

/// hwmon chips that carry a CPU or board temperature. Anything else in
/// /sys/class/hwmon is a disk, a battery or a GPU, and throttling the CPU
/// because the NVMe is warm would be a bug that looks like a feature.
const cpu_chips = [_][]const u8{
    "coretemp", // Intel per-core DTS
    "k10temp", // AMD family 10h+
    "zenpower", // AMD, out of tree
    "k8temp", // ancient AMD
    "cpu_thermal", // ARM SoCs (Raspberry Pi and friends)
    "cpu-thermal", // ... spelled the other way by some vendor kernels
    "soc_thermal",
    "acpitz", // firmware-provided, last resort but better than nothing
    "it87", // Super I/O, common on desktop boards
};

fn isCpuChip(name: []const u8) bool {
    for (cpu_chips) |chip| {
        if (std.mem.eql(u8, name, chip)) return true;
    }

    return false;
}

/// Plausible for a CPU: below 1 °C the sensor is not populated, above 150 °C
/// it is a bogus register (or a Fahrenheit value somebody wrote to sysfs).
fn plausible(milli: i64) bool {
    return milli >= 1_000 and milli <= 150_000;
}

fn readIntFile(path: []const u8) ?i64 {
    var buf: [32]u8 = undefined;
    const text = std.fs.cwd().readFile(path, &buf) catch return null;
    const trimmed = std.mem.trim(u8, text, " \t\r\n");

    return std.fmt.parseInt(i64, trimmed, 10) catch null;
}

fn readTextFile(path: []const u8, buf: []u8) ?[]const u8 {
    const text = std.fs.cwd().readFile(path, buf) catch return null;

    return std.mem.trim(u8, text, " \t\r\n");
}

/// A file with a temperature in it, for `--thermal-file`. Degrees or
/// millidegrees, whichever the number looks like: 71 is a temperature, 71000 is
/// the same temperature as sysfs writes it.
pub fn readPlainFile(path: []const u8) ?f32 {
    const value = readIntFile(path) orelse return null;
    const milli = if (value < 200) value * 1000 else value;

    if (!plausible(milli)) return null;

    return @as(f32, @floatFromInt(milli)) / 1000;
}

fn offer(best: *?Reading, celsius: f32, name: []const u8) void {
    if (best.*) |current| {
        if (celsius <= current.celsius) return;
    }

    var reading = Reading{ .celsius = celsius };
    reading.set(name);
    best.* = reading;
}

/// The hottest CPU sensor on this machine, or null when there is none.
///
/// Both scan orders matter: hwmon is preferred because `coretemp`/`k10temp`
/// report the die, while `thermal_zone` is whatever the firmware decided to
/// expose - on some laptops that is a skin sensor near the hinge, which reads
/// 20 °C lower than the silicon. The maximum across both is used, because the
/// rule the governor enforces is about the hottest thing in the box.
pub fn readSys(sys_root: []const u8) ?Reading {
    var best: ?Reading = null;

    scanHwmon(sys_root, &best);
    scanThermal(sys_root, &best);

    return best;
}

fn scanHwmon(sys_root: []const u8, best: *?Reading) void {
    var path_buf: [256]u8 = undefined;
    const root = std.fmt.bufPrint(&path_buf, "{s}/class/hwmon", .{sys_root}) catch return;

    var dir = std.fs.openDirAbsolute(root, .{ .iterate = true }) catch return;
    defer dir.close();

    var it = dir.iterate();

    while (it.next() catch null) |entry| {
        // Deliberately not filtering on `entry.kind`: sysfs reports directories
        // as symlinks, and a directory on a filesystem without d_type reports
        // `.unknown`. Opening the name file is the check that cannot be wrong.
        // A path, not a name: 64 bytes was one long sysfs root short of
        // working, and a bufPrint that does not fit returns an error, which
        // the caller here would read as "this chip has no name".
        var name_buf: [256]u8 = undefined;
        var chip_buf: [32]u8 = undefined;
        const name_path = std.fmt.bufPrint(&name_buf, "{s}/{s}/name", .{ root, entry.name }) catch continue;
        const chip = readTextFile(name_path, &chip_buf) orelse continue;

        if (!isCpuChip(chip)) continue;

        var temp_buf: [256]u8 = undefined;
        var channel: usize = 1;

        while (channel <= 16) : (channel += 1) {
            const input_path = std.fmt.bufPrint(&temp_buf, "{s}/{s}/temp{d}_input", .{ root, entry.name, channel }) catch break;
            const milli = readIntFile(input_path) orelse {
                // Channels are not contiguous on every driver; 16 is a cheap
                // upper bound and a miss is one failed open().
                continue;
            };

            if (!plausible(milli)) continue;

            var label_buf: [256]u8 = undefined;
            var label_storage: [40]u8 = undefined;
            const label_path = std.fmt.bufPrint(&label_buf, "{s}/{s}/temp{d}_label", .{ root, entry.name, channel }) catch {
                offer(best, @as(f32, @floatFromInt(milli)) / 1000, chip);
                continue;
            };

            const label = readTextFile(label_path, &label_storage) orelse {
                offer(best, @as(f32, @floatFromInt(milli)) / 1000, chip);
                continue;
            };

            var name_buf2: [64]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf2, "{s}/{s}", .{ chip, label }) catch chip;
            offer(best, @as(f32, @floatFromInt(milli)) / 1000, name);
        }
    }
}

fn scanThermal(sys_root: []const u8, best: *?Reading) void {
    var path_buf: [256]u8 = undefined;
    const root = std.fmt.bufPrint(&path_buf, "{s}/class/thermal", .{sys_root}) catch return;

    var dir = std.fs.openDirAbsolute(root, .{ .iterate = true }) catch return;
    defer dir.close();

    var it = dir.iterate();

    while (it.next() catch null) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "thermal_zone")) continue;

        var temp_buf: [256]u8 = undefined;
        const temp_path = std.fmt.bufPrint(&temp_buf, "{s}/{s}/temp", .{ root, entry.name }) catch continue;
        const milli = readIntFile(temp_path) orelse continue;

        if (!plausible(milli)) continue;

        var type_buf: [256]u8 = undefined;
        var zone_buf: [32]u8 = undefined;
        const type_path = std.fmt.bufPrint(&type_buf, "{s}/{s}/type", .{ root, entry.name }) catch {
            offer(best, @as(f32, @floatFromInt(milli)) / 1000, entry.name);
            continue;
        };

        const zone = readTextFile(type_path, &zone_buf) orelse {
            offer(best, @as(f32, @floatFromInt(milli)) / 1000, entry.name);
            continue;
        };

        offer(best, @as(f32, @floatFromInt(milli)) / 1000, zone);
    }
}

// --------------------------------------------------------------------------
// Tests
// --------------------------------------------------------------------------

const testing = std.testing;

fn gov(threads: usize) Governor {
    return Governor.init(Config.fromTarget(75), threads);
}

test "fromTarget keeps the bands in a usable order" {
    for ([_]f32{ 40, 45, 60, 75, 90, 99 }) |target| {
        const c = Config.fromTarget(target);

        try testing.expect(c.target_c >= 45 and c.target_c <= 95);
        try testing.expect(c.max_c > c.target_c);
        try testing.expect(c.critical_c > c.max_c);
        try testing.expect(c.resume_c < c.target_c);
    }
}

test "a cool machine is left alone" {
    var g = gov(4);

    try testing.expect(g.step(0, 50) == .none);
    try testing.expect(g.step(1000, 60) == .none);
    try testing.expect(g.step(2000, 74.9) == .none);
    try testing.expectEqual(@as(usize, 4), g.threads);
    try testing.expectEqual(@as(f32, 74.9), g.peak_c);
}

test "no sensor means no decision" {
    var g = gov(4);

    try testing.expect(g.step(0, null) == .none);
    try testing.expect(g.step(1_000_000, null) == .none);
    try testing.expectEqual(@as(usize, 4), g.threads);
    try testing.expect(!g.throttled());
}

test "at the target it sheds one thread per step window, not per sample" {
    var g = gov(4);

    // Nothing has been shed yet, so the first sample acts immediately: the
    // interval guards two *steps*, not the first one.
    switch (g.step(0, 80)) {
        .set_threads => |n| try testing.expectEqual(@as(usize, 3), n),
        else => return error.TestUnexpectedResult,
    }

    var now: i64 = 30_000;
    switch (g.step(now, 80)) {
        .set_threads => |n| try testing.expectEqual(@as(usize, 2), n),
        else => return error.TestUnexpectedResult,
    }

    // Ten more samples inside the window change nothing.
    for (1..11) |i| {
        try testing.expect(g.step(now + @as(i64, @intCast(i)) * 1000, 80) == .none);
    }

    now += 30_000;
    switch (g.step(now, 80)) {
        .set_threads => |n| try testing.expectEqual(@as(usize, 1), n),
        else => return error.TestUnexpectedResult,
    }
}

test "above the hard cap the reaction is immediate" {
    var g = gov(8);
    var now: i64 = 0;

    // The first sample starts the clock: nothing has been shed before, so the
    // fast_ms floor has nothing to measure against and 0 - 0 passes it.
    switch (g.step(now, 84)) {
        .set_threads => |n| try testing.expectEqual(@as(usize, 7), n),
        else => return error.TestUnexpectedResult,
    }

    // A second sample in the same millisecond would be a second thread gone
    // for one reading; the floor stops that.
    try testing.expect(g.step(now, 84) == .none);

    now += 5_000;
    switch (g.step(now, 84)) {
        .set_threads => |n| try testing.expectEqual(@as(usize, 6), n),
        else => return error.TestUnexpectedResult,
    }

    try testing.expectEqual(@as(usize, 6), g.threads);
    try testing.expect(g.throttled());
}

test "at one thread and still critical it pauses, and comes back cold" {
    var g = Governor.init(Config.fromTarget(75), 1);
    g.config.min_threads = 1;

    try testing.expect(g.step(0, 91) == .pause);
    try testing.expect(g.paused);
    try testing.expect(g.throttled());

    // Staying hot keeps it paused; a small dip is not enough.
    try testing.expect(g.step(60_000, 90) == .none);
    try testing.expect(g.step(120_000, 70) == .none);

    // Below resume_c, one thread, and the climb starts over.
    try testing.expect(g.step(180_000, 67) == .unpause);
    try testing.expect(!g.paused);
    try testing.expectEqual(@as(usize, 1), g.threads);
}

test "an eight thread box that overheats ends up paused, thread by thread" {
    var g = gov(8);
    var now: i64 = 0;

    // 84 °C is the hard cap for a 75 target: steps every fast_ms.
    var guard: usize = 0;
    while (!g.paused and guard < 100) : (guard += 1) {
        now += 5_000;
        _ = g.step(now, 84);
    }

    try testing.expect(g.paused);
    try testing.expectEqual(@as(usize, 1), g.threads);
    // 7 steps down from 8 to 1, then one pause.
    try testing.expectEqual(@as(u32, 7), g.step_downs);
    try testing.expectEqual(@as(u32, 1), g.pauses);
}

test "coming back up needs a sustained cool streak" {
    var g = Governor.init(Config.fromTarget(75), 1);
    g.ceiling = 4;

    // Cool, so the clock starts.
    try testing.expect(g.step(0, 60) == .none);
    // 119 s later it is still not enough.
    try testing.expect(g.step(119_000, 60) == .none);
    // 120 s of cool: one thread back.
    switch (g.step(120_000, 60)) {
        .set_threads => |n| try testing.expectEqual(@as(usize, 2), n),
        else => return error.TestUnexpectedResult,
    }
}

test "one warm sample in the middle of a cool streak restarts the clock" {
    var g = Governor.init(Config.fromTarget(75), 1);
    g.ceiling = 4;

    try testing.expect(g.step(0, 60) == .none);
    try testing.expect(g.step(60_000, 73) == .none); // inside the hysteresis band
    try testing.expect(g.step(61_000, 60) == .none);
    // The streak restarted at 61 s, so 120 s later is the earliest step up.
    try testing.expect(g.step(180_000, 60) == .none);

    switch (g.step(181_000, 60)) {
        .set_threads => |n| try testing.expectEqual(@as(usize, 2), n),
        else => return error.TestUnexpectedResult,
    }
}

test "it never gives back more threads than the user asked for" {
    var g = Governor.init(Config.fromTarget(75), 2);

    var now: i64 = 0;
    var guard: usize = 0;
    while (guard < 200) : (guard += 1) {
        now += 30_000;
        _ = g.step(now, 50);
    }

    try testing.expectEqual(@as(usize, 2), g.threads);
    try testing.expectEqual(@as(u32, 0), g.step_ups);
}

test "a flapping sensor inside the band does not move the thread count" {
    var g = gov(4);
    var now: i64 = 0;

    for (0..100) |i| {
        now += 7_000;
        _ = g.step(now, if (i % 2 == 0) 74.5 else 68.0);
    }

    try testing.expectEqual(@as(usize, 4), g.threads);
    try testing.expectEqual(@as(u32, 0), g.step_downs);
}

test "plausibility rejects the values a broken sensor produces" {
    try testing.expect(!plausible(0));
    try testing.expect(!plausible(-54_000));
    try testing.expect(!plausible(999));
    try testing.expect(plausible(30_000));
    try testing.expect(plausible(149_000));
    try testing.expect(!plausible(151_000));
}

test "the --thermal-file reader accepts degrees and millidegrees" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "deg", .data = "71\n" });
    try tmp.dir.writeFile(.{ .sub_path = "milli", .data = "71000\n" });
    try tmp.dir.writeFile(.{ .sub_path = "junk", .data = "hot\n" });
    try tmp.dir.writeFile(.{ .sub_path = "zero", .data = "0\n" });

    const dir_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);

    var buf: [512]u8 = undefined;

    try testing.expectEqual(@as(f32, 71), readPlainFile(try std.fmt.bufPrint(&buf, "{s}/deg", .{dir_path})).?);
    try testing.expectEqual(@as(f32, 71), readPlainFile(try std.fmt.bufPrint(&buf, "{s}/milli", .{dir_path})).?);
    try testing.expect(readPlainFile(try std.fmt.bufPrint(&buf, "{s}/junk", .{dir_path})) == null);
    try testing.expect(readPlainFile(try std.fmt.bufPrint(&buf, "{s}/zero", .{dir_path})) == null);
    try testing.expect(readPlainFile(try std.fmt.bufPrint(&buf, "{s}/missing", .{dir_path})) == null);
}

test "readSys walks a fake sysfs and picks the hottest CPU sensor" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A GPU that is hotter than the CPU must not be what throttles the CPU.
    try tmp.dir.makePath("class/hwmon/hwmon0");
    try tmp.dir.writeFile(.{ .sub_path = "class/hwmon/hwmon0/name", .data = "amdgpu\n" });
    try tmp.dir.writeFile(.{ .sub_path = "class/hwmon/hwmon0/temp1_input", .data = "95000\n" });

    try tmp.dir.makePath("class/hwmon/hwmon1");
    try tmp.dir.writeFile(.{ .sub_path = "class/hwmon/hwmon1/name", .data = "k10temp\n" });
    try tmp.dir.writeFile(.{ .sub_path = "class/hwmon/hwmon1/temp1_input", .data = "61500\n" });
    try tmp.dir.writeFile(.{ .sub_path = "class/hwmon/hwmon1/temp1_label", .data = "Tctl\n" });

    // A thermal zone lower than the die: the maximum wins.
    try tmp.dir.makePath("class/thermal/thermal_zone0");
    try tmp.dir.writeFile(.{ .sub_path = "class/thermal/thermal_zone0/temp", .data = "48000\n" });
    try tmp.dir.writeFile(.{ .sub_path = "class/thermal/thermal_zone0/type", .data = "acpitz\n" });

    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);

    const reading = readSys(root).?;

    try testing.expectEqual(@as(f32, 61.5), reading.celsius);
    try testing.expect(std.mem.eql(u8, reading.label(), "k10temp/Tctl"));
}

test "readSys returns null on a machine with no sensors at all" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);

    try testing.expect(readSys(root) == null);
}

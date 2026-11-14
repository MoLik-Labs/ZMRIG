//! Picking the thread count by measurement instead of by heuristic.
//!
//! The default throughput profile starts with every logical CPU, but the fastest
//! sustained count can be lower when a memory bus, shared vCPU quota or thermal
//! limit saturates. This module supplies a bounded candidate set so install-time
//! autotune can measure those machine-specific tradeoffs instead of guessing.
//!
//! This module holds the part that is not I/O: which candidates to try, and
//! whether a result is a real win. The measuring itself lives in `main.zig`,
//! because only it owns the engine. Keeping the decision rules here means they
//! can be tested without hashing anything.

const std = @import("std");
const topology = @import("topology.zig");

/// One measured configuration.
pub const Trial = struct {
    threads: usize,
    rate: f64,
};

/// Search space for the thread count.
///
/// Every candidate is a number of threads a real machine can run: one (the
/// floor), one per physical core (the per-watt choice), and every logical
/// thread (the maximum-throughput choice). A handful of points in between are
/// added when the machine is big enough for them to differ.
pub fn candidates(profile: topology.Profile, logical: usize, physical: usize, out: []usize) []usize {
    // `out.len` limits how many candidates we can store, not the thread-count
    // limit. Clamping thread counts to the buffer capacity made every machine
    // with more than eight logical CPUs benchmark only 1 and 8 threads -
    // exactly the rigs where a measured search is most valuable.
    if (logical == 0 or out.len == 0) return out[0..0];

    const max = logical;
    const phys = @max(@min(physical, logical), 1);
    const logical_n = logical;

    var count: usize = 0;

    const add = struct {
        fn one(list: []usize, n: *usize, value: usize, limit: usize) void {
            const clamped = @max(@min(value, limit), 1);

            for (list[0..n.*]) |existing| {
                if (existing == clamped) return;
            }
            if (n.* < list.len) {
                list[n.*] = clamped;
                n.* += 1;
            }
        }
    }.one;

    switch (profile) {
        // Watts do not matter: try everything up to every logical CPU.
        .free => {
            // Add low/intermediate points even when `physical` reaches the
            // searchable ceiling (common with a CPU quota). One measurement at
            // the maximum alone cannot tell whether oversubscription helps.
            add(out, &count, 1, max);
            if (phys > 2) add(out, &count, phys / 2, max);
            add(out, &count, phys, max);
            if (phys * 3 / 2 < logical_n) add(out, &count, phys * 3 / 2, max);
            add(out, &count, (phys + logical_n) / 2, max);
            add(out, &count, logical_n, max);
        },
        // Watts are the constraint: SMT siblings are the first thing to drop,
        // but a machine with no SMT should still check whether fewer threads
        // per core is better (it sometimes is when the memory bus saturates).
        .watt => {
            add(out, &count, 1, max);
            if (phys > 2) add(out, &count, phys / 2, max);
            add(out, &count, phys, max);
        },
    }

    // Start with the maximum count permitted by the profile. `isBetter` ignores
    // sub-noise gains, so this tie-break makes free mode retain maximum gross
    // throughput unless a lower count wins by a clear, repeatable margin.
    const preferred = if (profile == .free) logical_n else phys;
    for (out[0..count], 0..) |value, index| {
        if (value == preferred) {
            std.mem.swap(usize, &out[0], &out[index]);
            break;
        }
    }

    return out[0..count];
}

/// Is `candidate` a real improvement over `best`?
///
/// Hashrate samples on a quiet machine land within about 1 % of each other; a
/// difference smaller than that is noise and must not be written into a config
/// that then runs for months. 2 % is the margin used here, which is above the
/// measured noise floor of every A/B in doc/PERFORMANCE.md.
pub fn isBetter(candidate: Trial, best: Trial, margin: f64) bool {
    if (best.rate <= 0) return candidate.rate > 0;

    return candidate.rate > best.rate * (1.0 + margin);
}

/// Median of a slice, used instead of a mean so one stalled sample (a dataset
/// rebuild, a GC pause, the scheduler) cannot decide the winner.
pub fn median(samples: []f64) f64 {
    if (samples.len == 0) return 0;
    if (samples.len == 1) return samples[0];

    std.mem.sort(f64, samples, {}, struct {
        fn lessThan(_: void, a: f64, b: f64) bool {
            return a < b;
        }
    }.lessThan);

    const mid = samples.len / 2;
    if (samples.len % 2 == 1) return samples[mid];

    return (samples[mid - 1] + samples[mid]) / 2.0;
}

test "the candidate list is deduplicated, bounded and never empty" {
    const testing = std.testing;

    var buf: [8]usize = undefined;

    // 4 cores / 8 threads, profile free: cover low, per-core, SMT and maximum.
    const free_list = candidates(.free, 8, 4, &buf);
    try testing.expect(free_list.len >= 4);
    try testing.expectEqual(@as(usize, 8), free_list[0]);

    for (free_list) |n| {
        try testing.expect(n >= 1);
        try testing.expect(n <= 8);
    }

    // Both the conservative floor and maximum-throughput candidate must be
    // present, even when SMT makes physical < logical.
    var seen_floor = false;
    var seen_max = false;
    for (free_list) |n| {
        if (n == 1) seen_floor = true;
        if (n == 8) seen_max = true;
    }
    try testing.expect(seen_floor);
    try testing.expect(seen_max);

    // Candidate storage is deliberately small, but it must not cap the thread
    // count on a larger rig. The old clamp silently skipped every count above 8.
    var large_buf: [8]usize = undefined;
    const large_list = candidates(.free, 128, 64, &large_buf);
    try testing.expectEqual(@as(usize, 128), large_list[0]);
    try testing.expect(large_list.len <= large_buf.len);
    var seen_large_max = false;
    for (large_list) |n| {
        try testing.expect(n <= 128);
        if (n == 128) seen_large_max = true;
    }
    try testing.expect(seen_large_max);

    // With a CPU quota below physical cores, still explore more than one
    // nontrivial point before concluding the whole quota is best.
    var quota_buf: [8]usize = undefined;
    const quota_list = candidates(.free, 8, 32, &quota_buf);
    var seen_quota_mid = false;
    for (quota_list) |n| {
        if (n == 4) seen_quota_mid = true;
    }
    try testing.expect(seen_quota_mid);

    // profile watt: never above the physical core count.
    var watt_buf: [8]usize = undefined;
    const watt_list = candidates(.watt, 8, 4, &watt_buf);
    try testing.expectEqual(@as(usize, 4), watt_list[0]);
    for (watt_list) |n| {
        try testing.expect(n >= 1);
        try testing.expect(n <= 4);
    }
}

test "no duplicates in any candidate list" {
    const testing = std.testing;

    const cases = [_]struct { logical: usize, physical: usize }{
        .{ .logical = 1, .physical = 1 },
        .{ .logical = 2, .physical = 1 }, // a 1-core VM with SMT
        .{ .logical = 4, .physical = 4 },
        .{ .logical = 16, .physical = 8 },
        .{ .logical = 128, .physical = 64 },
    };

    for (cases) |case| {
        for ([_]topology.Profile{ .free, .watt }) |profile| {
            var buf: [8]usize = undefined;
            const list = candidates(profile, case.logical, case.physical, &buf);

            for (list, 0..) |value, i| {
                for (list[i + 1 ..]) |other| {
                    try testing.expect(value != other);
                }
            }
        }
    }
}

test "a 2 percent win is required before a config is replaced" {
    const testing = std.testing;

    const margin = 0.02;
    const best = Trial{ .threads = 2, .rate = 1000 };

    // Inside noise: keep what works.
    try testing.expect(!isBetter(Trial{ .threads = 4, .rate = 1010 }, best, margin));
    try testing.expect(!isBetter(Trial{ .threads = 4, .rate = 1000 }, best, margin));
    try testing.expect(!isBetter(Trial{ .threads = 1, .rate = 900 }, best, margin));

    // Outside noise: replace it.
    try testing.expect(isBetter(Trial{ .threads = 4, .rate = 1030 }, best, margin));

    // The first trial always wins over "nothing measured yet".
    const empty = Trial{ .threads = 1, .rate = 0 };
    try testing.expect(isBetter(Trial{ .threads = 1, .rate = 1 }, empty, margin));
    try testing.expect(!isBetter(Trial{ .threads = 1, .rate = 0 }, empty, margin));
}

test "the median ignores a single stalled sample" {
    const testing = std.testing;

    var samples = [_]f64{ 1070, 1068, 1072, 1071, 20 };
    try testing.expectApproxEqAbs(@as(f64, 1070), median(&samples), 0.001);

    var even = [_]f64{ 1000, 1002 };
    try testing.expectApproxEqAbs(@as(f64, 1001), median(&even), 0.001);

    var one = [_]f64{42};
    try testing.expectEqual(@as(f64, 42), median(&one));

    var none: [0]f64 = .{};
    try testing.expectEqual(@as(f64, 0), median(&none));
}

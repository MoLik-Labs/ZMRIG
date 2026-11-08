//! What the machine actually is: physical cores, SMT siblings, and whether it
//! is running on battery.
//!
//! These answers decide the two profiles:
//!
//!   free  - electricity is free (a cafe, a school lab, a flat-rate VPS): use
//!           every logical CPU, because more threads never hurt when watts do
//!           not matter.
//!   watt  - the bill is yours: one thread per *physical* core. A second SMT
//!           thread on the same core shares its execution units, so it adds
//!           ~5-15 % hashrate for ~30-40 % more power. Per watt that is a loss.
//!
//! Everything here is best effort and read-only: a container may hide the
//! topology, a VM may report one core, and a desktop has no battery file.
//! Every function has a defined answer for "unknown".

const std = @import("std");

pub const Profile = enum { free, watt };

/// Where sysfs lives. Overridable so the AMD/dual-socket layouts can be tested
/// on a machine that is neither (this repository's CI is a 2 vCPU container).
/// Only `ZMRIG_CPU_ROOT` is honoured, and only for tests: a typo there means
/// "no topology", which falls back to the numbering the miner used for years.
pub fn cpuRoot() []const u8 {
    const override = std.process.getEnvVarOwned(std.heap.page_allocator, "ZMRIG_CPU_ROOT") catch return "/sys/devices/system/cpu";
    // Deliberately leaked-free: one read per process start, and freeing it
    // would need every caller to care. The process is a miner, not a daemon.
    return override;
}

pub fn profileName(profile: Profile) []const u8 {
    return switch (profile) {
        .free => "free",
        .watt => "watt",
    };
}

/// Physical cores, from `topology/core_id` + `physical_package_id` pairs.
/// Falls back to the logical count when the kernel does not expose topology
/// (containers, some VMs), which is the safe answer: it means "profile watt
/// cannot do better than profile free here".
pub fn physicalCores(logical: usize) usize {
    // In a VM the guest topology is fiction: this container reports cpu0 and
    // cpu1 as siblings of one core, but the host schedules them on anything.
    // Halving the thread count there would cost ~48 % hashrate for no saving,
    // so a hypervisor turns "physical cores" into "the vCPUs we were given".
    if (inVirtualMachine()) return logical;

    var buf: [4096]u8 = undefined;
    var present_buf: [192]u8 = undefined;
    const present_path = std.fmt.bufPrint(&present_buf, "{s}/present", .{cpuRoot()}) catch "/sys/devices/system/cpu/present";
    const text = readFile(&buf, present_path) orelse return logical;

    // "present" is a range list like "0-3" or "0-1,4-5"; count the CPUs in it.
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \n\r\t");
        if (trimmed.len == 0) continue;

        if (std.mem.indexOfScalar(u8, trimmed, '-')) |dash| {
            const lo = std.fmt.parseInt(usize, trimmed[0..dash], 10) catch continue;
            const hi = std.fmt.parseInt(usize, trimmed[dash + 1 ..], 10) catch continue;
            count += hi -| lo + 1;
        } else {
            count += 1;
        }
    }

    if (count == 0 or count > 4096) return logical;

    // One CPU per distinct (package, core) pair.
    var seen: [256]u64 = undefined;
    var seen_len: usize = 0;
    var cores: usize = 0;

    var cpu: usize = 0;
    while (cpu < count and cpu < 4096) : (cpu += 1) {
        var path_buf: [128]u8 = undefined;
        const base = std.fmt.bufPrint(&path_buf, "{s}/cpu{d}/topology", .{ cpuRoot(), cpu }) catch continue;

        var id_buf: [256]u8 = undefined;
        const package = readNumberIn(&id_buf, base, "physical_package_id") orelse 0;
        const core = readNumberIn(&id_buf, base, "core_id") orelse continue;

        // 8 bits of package is plenty (a machine with 256 sockets is not mining).
        const key = (package << 8) | (core & 0xff);

        var dup = false;
        for (seen[0..seen_len]) |known| {
            if (known == key) {
                dup = true;
                break;
            }
        }
        if (dup) continue;

        if (seen_len < seen.len) {
            seen[seen_len] = key;
            seen_len += 1;
        }
        cores += 1;
    }

    if (cores == 0) return logical;

    return @min(cores, logical);
}

/// Where cgroup v2 lives, overridable so a quota can be tested without one.
/// Same contract as `cpuRoot`: an override that does not exist means "no quota",
/// which is the behaviour every machine had before this function existed.
pub fn cgroupRoot() []const u8 {
    const override = std.process.getEnvVarOwned(std.heap.page_allocator, "ZMRIG_CGROUP_ROOT") catch return "/sys/fs/cgroup";
    return override;
}

/// The CPUs this process is actually allowed to spend, from a cgroup CPU quota,
/// or null when there is none.
///
/// A quota is not an affinity mask: with `--cpus=2`, `systemd CPUQuota=200%` or a
/// Kubernetes limit, the process still sees every CPU on the host, so the
/// heuristic below asks for one thread per physical core and the whole group is
/// then throttled. That is *slower* than the same work in fewer threads - when
/// the quota is spent the group is stopped together, so a thread with a scratchpad
/// in L3 sits idle for the rest of the period instead of finishing its share.
/// Capping to the quota is the only thing that makes the heuristic right there.
///
/// cgroup v2 is one line in `cpu.max` ("200000 100000", or "max 100000"); v1 is
/// two files. The path comes from `/proc/self/cgroup`, because on a host with
/// systemd the quota is on a slice, not on the root - and inside a container
/// namespace the same file reads as "/", which is why both are tried.
/// An explicit `-t` is never overridden here; this only informs the default.
pub fn quotaCpus() ?usize {
    return quotaFrom(cgroupRoot(), readSelfCgroup() orelse "");
}

/// Pure apart from the files under `root`: `self_cgroup` is the text of
/// /proc/self/cgroup, so every layout can be tested against a fixture.
pub fn quotaFrom(root: []const u8, self_cgroup: []const u8) ?usize {
    var path_buf: [256]u8 = undefined;
    var text_buf: [128]u8 = undefined;

    // --- cgroup v2: "0::/user.slice/session-3.scope" for the process's own
    // group, and the quota for that group in cpu.max.
    var v2_path: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, self_cgroup, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "0::")) v2_path = std.mem.trim(u8, line[3..], " \r\t");
    }

    if (v2_path) |rel| {
        if (quotaFromMax(root, rel, &path_buf, &text_buf)) |quota| return quota;
    }
    if (quotaFromMax(root, "", &path_buf, &text_buf)) |quota| return quota;

    // --- cgroup v1: the cpu controller's own directory ("5:cpu,cpuacct:/docker/ab"),
    // quota and period in microseconds. The period is 100000 by default, and
    // 150000/100000 is one CPU, not one and a half: a quota buys whole CPUs'
    // worth of time, and a thread per fraction has nothing to run on.
    var v1_path: ?[]const u8 = null;
    it = std.mem.splitScalar(u8, self_cgroup, '\n');
    while (it.next()) |line| {
        const first_colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const second_colon = std.mem.indexOfScalarPos(u8, line, first_colon + 1, ':') orelse continue;
        const controllers = line[first_colon + 1 .. second_colon];
        if (std.mem.indexOf(u8, controllers, "cpu") == null) continue;
        v1_path = std.mem.trim(u8, line[second_colon + 1 ..], " \r\t");
    }

    var candidates: [2][]const u8 = undefined;
    var count: usize = 0;
    if (v1_path) |rel| {
        if (!std.mem.eql(u8, rel, "/") and rel.len > 0) {
            candidates[count] = std.fmt.bufPrint(path_buf[0..], "{s}/cpu{s}", .{ root, rel }) catch "";
            if (candidates[count].len > 0) count += 1;
        }
    }

    var fallback_buf: [256]u8 = undefined;
    const plain = std.fmt.bufPrint(&fallback_buf, "{s}/cpu", .{root}) catch "";
    if (plain.len > 0) {
        candidates[count] = plain;
        count += 1;
    }

    for (candidates[0..count]) |dir| {
        const quota = readNumberIn(&text_buf, dir, "cpu.cfs_quota_us") orelse continue;
        const period = readNumberIn(&text_buf, dir, "cpu.cfs_period_us") orelse 100000;
        if (quota == 0 or period == 0) continue;
        return @intCast(@max(quota / period, 1));
    }

    // A quota of -1 means "no limit" in v1, and parseInt on u64 has already
    // rejected it, which is the right answer: no quota.
    return null;
}

fn quotaFromMax(root: []const u8, rel: []const u8, path_buf: []u8, text_buf: []u8) ?usize {
    const joined = if (rel.len == 0 or std.mem.eql(u8, rel, "/"))
        std.fmt.bufPrint(path_buf, "{s}/cpu.max", .{root}) catch return null
    else
        std.fmt.bufPrint(path_buf, "{s}{s}/cpu.max", .{ root, rel }) catch return null;

    const text = readFile(text_buf, joined) orelse return null;
    var fields = std.mem.tokenizeAny(u8, text, " \t\n\r");

    const quota_text = fields.next() orelse return null;
    if (std.mem.eql(u8, quota_text, "max")) return null;

    const quota = std.fmt.parseInt(u64, quota_text, 10) catch return null;
    const period = std.fmt.parseInt(u64, fields.next() orelse "100000", 10) catch 100000;
    if (quota == 0 or period == 0) return null;

    return @intCast(@max(quota / period, 1));
}

/// Bytes this process may still allocate before its cgroup memory limit is
/// reached, or null when there is no limit (bare metal, and every container
/// started without `--memory`).
///
/// `/proc/meminfo` is not namespaced: inside `docker run --memory=1g` on a 32 GB
/// host it reports the host, so the miner picked fast mode, mapped a 2336 MB
/// dataset and was OOM-killed a second later. The limit is the only number that
/// describes the machine the process actually runs on, and the difference
/// between a rig that starts and one that dies during startup.
///
/// What is subtracted is memory the kernel cannot take back: `anon` in
/// memory.stat (v2) or memory.usage_in_bytes minus the reclaimable page cache -
/// page cache is *not* subtracted, because a container that has read 500 MB of
/// files has not lost that memory, it has merely borrowed it.
pub fn cgroupMemory() ?MemoryBudget {
    return memoryBudgetFrom(cgroupRoot(), readSelfCgroup() orelse "");
}

/// A cgroup memory limit and what is left of it. Two numbers, because they
/// answer different questions: the limit is "what was this container given",
/// and the remainder is "can the dataset fit right now". Reporting the
/// remainder as the limit said "limited to 824 MB" about a 1 GiB container.
pub const MemoryBudget = struct {
    limit: u64,
    available: u64,
};

/// Pure apart from the files under `root`: `self_cgroup` is the text of
/// /proc/self/cgroup, so every layout can be tested against a fixture.
pub fn memoryBudgetFrom(root: []const u8, self_cgroup: []const u8) ?MemoryBudget {
    var path_buf: [256]u8 = undefined;
    var text_buf: [128]u8 = undefined;

    // --- cgroup v2: memory.max and memory.current next to each other.
    var v2_path: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, self_cgroup, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "0::")) v2_path = std.mem.trim(u8, line[3..], " \r\t");
    }

    if (v2_path) |rel| {
        if (memoryFromDir(root, rel, &path_buf, &text_buf)) |budget| return budget;
    }
    if (memoryFromDir(root, "", &path_buf, &text_buf)) |budget| return budget;

    // --- cgroup v1: the memory controller's own directory.
    var v1_path: ?[]const u8 = null;
    it = std.mem.splitScalar(u8, self_cgroup, '\n');
    while (it.next()) |line| {
        const first_colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const second_colon = std.mem.indexOfScalarPos(u8, line, first_colon + 1, ':') orelse continue;
        const controllers = line[first_colon + 1 .. second_colon];
        if (std.mem.indexOf(u8, controllers, "memory") == null) continue;
        v1_path = std.mem.trim(u8, line[second_colon + 1 ..], " \r\t");
    }

    if (v1_path) |rel| {
        if (!std.mem.eql(u8, rel, "/") and rel.len > 0) {
            if (memoryFromDir(root, rel, &path_buf, &text_buf)) |budget| return budget;
        }
        // A daemon that is not containerised lives at "/" with the controller
        // mounted at <root>/memory, not at the root itself.
        if (memoryFromDir(root, "/memory", &path_buf, &text_buf)) |budget| return budget;
    }

    return null;
}

/// The limit of one cgroup directory, or null when it has none. Tries v2 first
/// and falls back to v1, because the same call has to work on the host and in
/// an image built on an older base.
fn memoryFromDir(root: []const u8, rel: []const u8, path_buf: []u8, text_buf: []u8) ?MemoryBudget {
    const dir = if (rel.len == 0 or std.mem.eql(u8, rel, "/"))
        root
    else
        std.fmt.bufPrint(path_buf, "{s}{s}", .{ root, rel }) catch return null;

    const limit = readNumberIn(text_buf, dir, "memory.max") orelse
        readNumberIn(text_buf, dir, "memory.limit_in_bytes") orelse return null;

    // v1 spells "no limit" as a number just under 2^63, and a limit larger than
    // the machine is not a limit either: clamping to either would invent a
    // budget and send a bare-metal rig into light mode.
    if (limit >= (1 << 62)) return null;

    const held = nonReclaimable(text_buf, dir) orelse
        readNumberIn(text_buf, dir, "memory.current") orelse
        readNumberIn(text_buf, dir, "memory.usage_in_bytes") orelse 0;

    return .{ .limit = limit, .available = limit - @min(held, limit) };
}

/// `anon` from memory.stat: the pages that cannot be reclaimed. A cgroup at its
/// limit but full of file cache has room, and treating the cache as a resident
/// allocation is how a working container gets told it cannot mine.
fn nonReclaimable(text_buf: []u8, dir: []const u8) ?u64 {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/memory.stat", .{dir}) catch return null;
    const text = readFile(text_buf, path) orelse return null;

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const key_end = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        if (!std.mem.eql(u8, line[0..key_end], "anon")) continue;
        return std.fmt.parseInt(u64, std.mem.trim(u8, line[key_end + 1 ..], " \r\t"), 10) catch null;
    }

    return null;
}

fn readSelfCgroup() ?[]const u8 {
    const text = readFile(&read_self_buf, "/proc/self/cgroup") orelse return null;
    return text;
}

var read_self_buf: [1024]u8 = undefined;

/// Threads to use for a profile. `free` takes everything; `watt` leaves the SMT
/// siblings idle.
pub fn threadsFor(profile: Profile, logical: usize, physical: usize) usize {
    return switch (profile) {
        .free => @max(logical, 1),
        .watt => @max(@min(physical, logical), 1),
    };
}


/// One CPU as the kernel describes it: which socket it is in, and which core of
/// that socket it is. Two CPUs with the same (package, core) are SMT siblings.
pub const Cpu = struct {
    id: u32,
    package: u32,
    core: u32,
};

/// Pure ordering rule, separated from sysfs so it can be tested against the
/// layouts real machines have (and this one does not).
///
/// The problem it solves: Linux numbers SMT siblings *adjacently* on AMD
/// (cpu0/cpu1 = core 0, cpu2/cpu3 = core 1) and on ARM big.LITTLE, but far
/// apart on most Intel parts. A miner that pins thread `i` to cpu `i` therefore
/// lands on two halves of the same core on AMD. That is invisible on a VM, and
/// on bare metal it meant profile `watt` (one thread per physical core) pinned
/// 8 threads onto 4 cores: half the machine idle, ~50 % of the hashrate gone,
/// for a power "saving" that was really just idling.
///
/// The order this produces is: one CPU per physical core first, sockets
/// interleaved so a small thread count still spreads across memory channels,
/// and only then the SMT siblings.
pub fn selectCpus(profile: Profile, cpus: []const Cpu, out: []usize) []usize {
    var written: usize = 0;

    // Primary: the first CPU seen for each (package, core) pair, grouped by
    // package so iteration can interleave them.
    var packages: [64]u32 = undefined;
    var package_count: usize = 0;
    var primary: [256]Cpu = undefined;
    var primary_count: usize = 0;
    var sibling: [256]Cpu = undefined;
    var sibling_count: usize = 0;

    for (cpus) |cpu| {
        var found = false;
        for (packages[0..package_count]) |known| {
            if (known == cpu.package) {
                found = true;
                break;
            }
        }
        if (!found and package_count < packages.len) {
            packages[package_count] = cpu.package;
            package_count += 1;
        }

        // Same core as an earlier CPU? Then it is a sibling, not a new core.
        var is_sibling = false;
        for (primary[0..primary_count]) |known| {
            if (known.package == cpu.package and known.core == cpu.core) {
                is_sibling = true;
                break;
            }
        }

        if (is_sibling) {
            if (sibling_count < sibling.len) {
                sibling[sibling_count] = cpu;
                sibling_count += 1;
            }
        } else if (primary_count < primary.len) {
            primary[primary_count] = cpu;
            primary_count += 1;
        }
    }

    // Round-robin over the sockets: with 4 cores on socket 0 and 4 on socket 1,
    // a 2-thread run takes one core from each socket instead of two from the
    // same one, which halves the memory traffic crossing the interconnect.
    var round: usize = 0;
    var take_primary = true;
    while (take_primary and round < 64) : (round += 1) {
        var progressed = false;
        for (packages[0..package_count]) |package| {
            for (primary[0..primary_count]) |cpu| {
                if (cpu.package != package) continue;
                // The k-th round takes the k-th core of this package.
                var index: usize = 0;
                for (primary[0..primary_count]) |earlier| {
                    if (earlier.package != package) continue;
                    if (earlier.id == cpu.id) break;
                    index += 1;
                }
                if (index != round) continue;

                if (written < out.len) {
                    out[written] = cpu.id;
                    written += 1;
                    progressed = true;
                }
                break;
            }
        }
        take_primary = progressed;
    }

    // Profile `watt` stops here: the siblings are exactly what it is trying to
    // avoid. Profile `free` appends them, because on free electricity a thread
    // that adds 10 % hashrate for 35 % more power is still more money.
    if (profile == .free) {
        for (sibling[0..sibling_count]) |cpu| {
            if (written < out.len) {
                out[written] = cpu.id;
                written += 1;
            }
        }
    }

    return out[0..written];
}


/// CPU ids the kernel says are online, from `cpu/online` ("0-3,8-11"), else
/// `0..getCpuCount()`. Parsing the file instead of trusting the count matters
/// in two cases that are common on rented metal: a cgroup that exposes only
/// CPUs 4-7 (count 4, ids not 0-3) and a machine with offline cores.
pub fn onlineCpuIds(buf: []u32) []u32 {
    var path_buf: [192]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/online", .{cpuRoot()}) catch return defaultCpuIds(buf);

    var text_buf: [512]u8 = undefined;
    const text = readFile(&text_buf, path) orelse return defaultCpuIds(buf);

    const parsed = parseCpuList(text, buf);
    if (parsed.len == 0) return defaultCpuIds(buf);

    return parsed;
}

/// "0-3,8,10-11" -> {0,1,2,3,8,10,11}. Junk is skipped rather than fatal: a
/// kernel that writes something unexpected must not stop a miner.
pub fn parseCpuList(text: []const u8, buf: []u32) []u32 {
    var written: usize = 0;
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \n\r\t");
        if (trimmed.len == 0) continue;

        if (std.mem.indexOfScalar(u8, trimmed, '-')) |dash| {
            const lo = std.fmt.parseInt(u32, trimmed[0..dash], 10) catch continue;
            const hi = std.fmt.parseInt(u32, trimmed[dash + 1 ..], 10) catch continue;
            if (hi < lo) continue;
            // A malformed range must not spin: cap at the buffer.
            var id = lo;
            while (id <= hi and written < buf.len) : (id += 1) {
                buf[written] = id;
                written += 1;
            }
        } else {
            const id = std.fmt.parseInt(u32, trimmed, 10) catch continue;
            if (written < buf.len) {
                buf[written] = id;
                written += 1;
            }
        }
    }

    return buf[0..written];
}

fn defaultCpuIds(buf: []u32) []u32 {
    const count = std.Thread.getCpuCount() catch 1;
    const n = @min(count, buf.len);
    for (0..n) |i| buf[i] = @intCast(i);

    return buf[0..n];
}

/// Is this CPU in the process's own affinity mask? A systemd unit with
/// `CPUAffinity=` or a `taskset` wrapper limits us to a subset; pinning a
/// thread to a CPU outside it makes `sched_setaffinity` fail and the thread
/// float, which looks like a pinning bug when it is really a permission.
pub fn isAllowed(cpu: u32) bool {
    var set: std.os.linux.cpu_set_t = std.mem.zeroes(std.os.linux.cpu_set_t);
    const rc = std.os.linux.sched_getaffinity(0, @sizeOf(std.os.linux.cpu_set_t), &set);
    if (std.os.linux.E.init(rc) != .SUCCESS) return true; // unknown: do not filter
    if (cpu >= @sizeOf(std.os.linux.cpu_set_t) * 8) return false;

    const words = @as([*]const usize, @ptrCast(&set));
    const word = cpu / @bitSizeOf(usize);
    const bit = cpu % @bitSizeOf(usize);

    return (words[word] >> @intCast(bit)) & 1 == 1;
}

/// Reads the topology of every online CPU. In a VM every CPU is treated as its
/// own core: the guest's (package, core) numbers describe the host's idea of
/// the topology, and the hypervisor schedules us anywhere. Believing that
/// fiction is what halved the thread count on the validation container.
pub fn cpuMap(buf: []Cpu) []Cpu {
    // Only CPUs this process may actually use: a unit with CPUAffinity= or a
    // taskset wrapper would otherwise be "pinned" to CPUs the kernel refuses,
    // and every thread would silently float.
    const all = cpuMapAll(buf);

    var written: usize = 0;
    for (all) |cpu| {
        if (!isAllowed(cpu.id)) continue;
        buf[written] = cpu;
        written += 1;
    }

    return buf[0..written];
}

/// The topology of every online CPU, ignoring this process's affinity mask.
/// Exists so `--check` can say "16 CPUs, but your unit only allows 2".
pub fn cpuMapAll(buf: []Cpu) []Cpu {
    var ids_buf: [256]u32 = undefined;
    const ids = onlineCpuIds(&ids_buf);

    const vm = inVirtualMachine();

    var written: usize = 0;
    for (ids) |id| {
        if (written >= buf.len) break;

        if (vm) {
            // The guest's (package, core) describes the host's topology; the
            // hypervisor schedules us on vCPUs, so each is its own core.
            buf[written] = .{ .id = id, .package = 0, .core = id };
            written += 1;
            continue;
        }

        var path_buf: [192]u8 = undefined;
        const base = std.fmt.bufPrint(&path_buf, "{s}/cpu{d}/topology", .{ cpuRoot(), id }) catch continue;

        var id_buffer: [256]u8 = undefined;
        const package = readNumberIn(&id_buffer, base, "physical_package_id");
        const core = readNumberIn(&id_buffer, base, "core_id");

        buf[written] = if (core) |core_id|
            .{ .id = id, .package = @intCast(package orelse 0), .core = @intCast(core_id) }
        else
            // No topology files at all: trust the numbering, which is what the
            // miner did before this existed.
            .{ .id = id, .package = 0, .core = id };
        written += 1;
    }

    return buf[0..written];
}

/// CPUs a run should use for `profile`, in the order threads should take them.
pub fn threadCpus(profile: Profile, cpus: []const Cpu, out: []usize) []usize {
    return selectCpus(profile, cpus, out);
}

pub const Battery = enum { unknown, charging, discharging, full };

/// Reads every `BAT*/status`. A machine with none (every VPS, every desktop)
/// answers `unknown`, which never pauses anything.
pub fn batteryState() Battery {
    var saw_battery = false;
    var discharging = false;
    var charging = false;
    var full = false;

    var index: usize = 0;
    while (index < 8) : (index += 1) {
        var path_buf: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/sys/class/power_supply/BAT{d}/status", .{index}) catch return .unknown;

        var buf: [64]u8 = undefined;
        const text = readFile(&buf, path) orelse continue;
        const value = std.mem.trim(u8, text, " \n\r\t");

        if (value.len == 0) continue;

        saw_battery = true;
        if (std.ascii.eqlIgnoreCase(value, "Discharging")) discharging = true;
        if (std.ascii.eqlIgnoreCase(value, "Charging")) charging = true;
        if (std.ascii.eqlIgnoreCase(value, "Full")) full = true;
    }

    if (!saw_battery) return .unknown;
    // Discharging wins: a machine can report one pack charging and another
    // draining, and the safe answer is "we are on battery".
    if (discharging) return .discharging;
    if (charging) return .charging;
    if (full) return .full;

    return .unknown;
}

/// Should the miner stop hashing right now, given the profile and the battery?
/// Only profile `watt` ever pauses, and only on a real battery reading: an
/// unknown state (VPS, desktop) must never stop a miner.
pub fn shouldPause(profile: Profile, state: Battery, pause_on_battery: bool) bool {
    if (profile != .watt or !pause_on_battery) return false;

    return state == .discharging;
}

/// True when /proc/cpuinfo advertises the `hypervisor` flag (every KVM, Xen,
/// VMware and Hyper-V guest does). Kept public for `--check`.
pub fn inVirtualMachine() bool {
    var buf: [64 * 1024]u8 = undefined;
    const text = readFile(&buf, "/proc/cpuinfo") orelse return false;

    // The flag appears as its own token in the `flags`/`Features` line.
    var it = std.mem.tokenizeAny(u8, text, " \n\t:");
    while (it.next()) |token| {
        if (std.mem.eql(u8, token, "hypervisor")) return true;
    }

    return false;
}

fn readFile(buf: []u8, path: []const u8) ?[]const u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    const n = file.readAll(buf) catch return null;

    return buf[0..n];
}

fn readNumberIn(buf: []u8, dir: []const u8, name: []const u8) ?u64 {
    var path_buf: [192]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch return null;

    const text = readFile(buf, path) orelse return null;

    return std.fmt.parseInt(u64, std.mem.trim(u8, text, " \n\r\t"), 10) catch null;
}

test "profile free takes every thread, profile watt leaves SMT siblings idle" {
    const testing = std.testing;

    // A 4-core / 8-thread laptop, the case the two profiles disagree on.
    try testing.expectEqual(@as(usize, 8), threadsFor(.free, 8, 4));
    try testing.expectEqual(@as(usize, 4), threadsFor(.watt, 8, 4));

    // No SMT: the profiles are identical and neither may produce 0.
    try testing.expectEqual(@as(usize, 2), threadsFor(.free, 2, 2));
    try testing.expectEqual(@as(usize, 2), threadsFor(.watt, 2, 2));

    // Unknown topology (a container reporting one core) must not break.
    try testing.expectEqual(@as(usize, 1), threadsFor(.watt, 1, 1));
    try testing.expectEqual(@as(usize, 1), threadsFor(.free, 0, 0));
}

test "physical cores is never more than the logical count and never zero" {
    const testing = std.testing;
    const logical = std.Thread.getCpuCount() catch 1;

    const physical = physicalCores(logical);

    try testing.expect(physical >= 1);
    try testing.expect(physical <= logical);
}

test "a hypervisor makes every vCPU its own core" {
    const testing = std.testing;
    const logical = std.Thread.getCpuCount() catch 1;

    // On a VM the answer must be "all of them": the guest topology is a lie and
    // halving threads on a VPS is a 48 % hashrate loss for no power saving.
    if (inVirtualMachine()) {
        try testing.expectEqual(logical, physicalCores(logical));
        try testing.expectEqual(logical, threadsFor(.watt, logical, physicalCores(logical)));
    } else {
        // Bare metal: never more cores than threads, never zero.
        const physical = physicalCores(logical);
        try testing.expect(physical >= 1);
        try testing.expect(physical <= logical);
    }
}

test "the battery never pauses a miner on a host without one" {
    const testing = std.testing;

    // profile free never pauses, whatever the battery says.
    try testing.expect(!shouldPause(.free, .discharging, true));
    // profile watt pauses only on a real discharging reading.
    try testing.expect(shouldPause(.watt, .discharging, true));
    try testing.expect(!shouldPause(.watt, .charging, true));
    try testing.expect(!shouldPause(.watt, .full, true));
    // ...and an unknown state is never a reason to stop hashing.
    try testing.expect(!shouldPause(.watt, .unknown, true));
    // the opt-out wins over everything.
    try testing.expect(!shouldPause(.watt, .discharging, false));
}

test "battery parsing accepts the words the kernel actually uses" {
    const testing = std.testing;

    // This host has no battery; the point of the test is that the answer is a
    // defined one and not a crash or a paused miner.
    const state = batteryState();
    try testing.expect(state == .unknown or state == .charging or state == .discharging or state == .full);

    if (state == .unknown) {
        try testing.expect(!shouldPause(.watt, state, true));
    }
}

test "SMT siblings are interleaved on AMD layouts, not adjacent" {
    const testing = std.testing;

    // AMD Zen, 4 cores / 8 threads: cpu0/cpu1 are the two halves of core 0.
    // Pinning thread i to cpu i would put 4 threads on 2 cores.
    const amd = [_]Cpu{
        .{ .id = 0, .package = 0, .core = 0 }, .{ .id = 1, .package = 0, .core = 0 },
        .{ .id = 2, .package = 0, .core = 1 }, .{ .id = 3, .package = 0, .core = 1 },
        .{ .id = 4, .package = 0, .core = 2 }, .{ .id = 5, .package = 0, .core = 2 },
        .{ .id = 6, .package = 0, .core = 3 }, .{ .id = 7, .package = 0, .core = 3 },
    };

    var out: [16]usize = undefined;

    // watt: 4 threads, all on distinct cores.
    const watt = selectCpus(.watt, &amd, &out);
    try testing.expectEqual(@as(usize, 4), watt.len);
    try testing.expectEqualSlices(usize, &.{ 0, 2, 4, 6 }, watt);

    // free: all 8, core before sibling.
    const free = selectCpus(.free, &amd, &out);
    try testing.expectEqual(@as(usize, 8), free.len);
    try testing.expectEqual(@as(usize, 0), free[0]);
    try testing.expectEqual(@as(usize, 1), free[4]);
}

test "a dual socket machine spreads threads across sockets first" {
    const testing = std.testing;

    // Two sockets, two cores each, no SMT: 0,1 on package 0 and 8,9 on 1.
    const dual = [_]Cpu{
        .{ .id = 0, .package = 0, .core = 0 }, .{ .id = 1, .package = 0, .core = 1 },
        .{ .id = 8, .package = 1, .core = 0 }, .{ .id = 9, .package = 1, .core = 1 },
    };

    var out: [8]usize = undefined;
    const picked = selectCpus(.watt, &dual, &out);

    try testing.expectEqual(@as(usize, 4), picked.len);
    // The first two threads must not both sit on socket 0.
    try testing.expectEqual(@as(usize, 0), picked[0]);
    try testing.expectEqual(@as(usize, 8), picked[1]);
}

test "an Intel layout (siblings far apart) keeps working" {
    const testing = std.testing;

    // 2 cores / 4 threads where cpu0 and cpu2 are the siblings of core 0.
    const intel = [_]Cpu{
        .{ .id = 0, .package = 0, .core = 0 }, .{ .id = 1, .package = 0, .core = 1 },
        .{ .id = 2, .package = 0, .core = 0 }, .{ .id = 3, .package = 0, .core = 1 },
    };

    var out: [8]usize = undefined;
    try testing.expectEqualSlices(usize, &.{ 0, 1 }, selectCpus(.watt, &intel, &out));
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3 }, selectCpus(.free, &intel, &out));
}

test "no topology files: every CPU is its own core, nothing is dropped" {
    const testing = std.testing;

    // What a container without topology/ looks like after cpuMap's fallback.
    const flat = [_]Cpu{
        .{ .id = 0, .package = 0, .core = 0 },
        .{ .id = 1, .package = 0, .core = 1 },
        .{ .id = 2, .package = 0, .core = 2 },
    };

    var out: [8]usize = undefined;
    try testing.expectEqual(@as(usize, 3), selectCpus(.watt, &flat, &out).len);
    try testing.expectEqual(@as(usize, 3), selectCpus(.free, &flat, &out).len);
}

test "a cgroup CPU quota is read from v2, v1 and a slice" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("cpu");
    try tmp.dir.makePath("user.slice");

    // v2 on a systemd host: the quota is on the slice, not on the root, and the
    // process's own cgroup path says which one.
    try tmp.dir.writeFile(.{ .sub_path = "user.slice/cpu.max", .data = "200000 100000\n" });
    // The root is unlimited, which is what a host looks like: reading only the
    // root would miss every quota the operator set.
    try tmp.dir.writeFile(.{ .sub_path = "cpu.max", .data = "max 100000\n" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &root_buf);

    try testing.expectEqual(@as(?usize, 2), quotaFrom(root, "0::/user.slice\n"));
    // A namespace where the process is at the root: 3 CPUs of quota.
    try tmp.dir.writeFile(.{ .sub_path = "cpu.max", .data = "300000 100000\n" });
    try testing.expectEqual(@as(?usize, 3), quotaFrom(root, "0::/\n"));
    // No /proc/self/cgroup at all is the fallback to the root.
    try testing.expectEqual(@as(?usize, 3), quotaFrom(root, ""));

    // v1: two files, and a fraction of a CPU is one CPU, not zero. A host runs
    // one hierarchy or the other, so the v2 file goes back to unlimited first -
    // a fixture with both would be testing a machine that does not exist.
    try tmp.dir.writeFile(.{ .sub_path = "cpu.max", .data = "max 100000\n" });
    try tmp.dir.writeFile(.{ .sub_path = "cpu/cpu.cfs_quota_us", .data = "150000\n" });
    try tmp.dir.writeFile(.{ .sub_path = "cpu/cpu.cfs_period_us", .data = "100000\n" });
    try testing.expectEqual(@as(?usize, 1), quotaFrom(root, "5:cpu,cpuacct:/\n"));

    // v1 with no limit written as -1: no quota, and no arithmetic on a negative.
    try tmp.dir.writeFile(.{ .sub_path = "cpu/cpu.cfs_quota_us", .data = "-1\n" });
    try testing.expect(quotaFrom(root, "5:cpu,cpuacct:/\n") == null);

    // Nothing at all: a bare-metal machine answers null, not one.
    var empty = testing.tmpDir(.{});
    defer empty.cleanup();
    var empty_buf: [std.fs.max_path_bytes]u8 = undefined;
    const empty_root = try empty.dir.realpath(".", &empty_buf);
    try testing.expect(quotaFrom(empty_root, "0::/\n") == null);
}

test "the quota only lowers the default, and never to zero" {
    const testing = std.testing;

    // What resolveProfile does with the answer: the smaller of the heuristic and
    // the quota, floored at one. A 16-thread machine with 2 CPUs of quota asks
    // for 2 threads; it does not ask for 16 and let the kernel throttle them.
    const logical: usize = 16;
    const physical = physicalCores(logical);
    const free = threadsFor(.free, logical, physical);

    try testing.expectEqual(@as(usize, 2), @min(free, @as(usize, 2)));
    try testing.expectEqual(@as(usize, 1), @max(@min(free, @as(usize, 1)), 1));
    // A quota larger than the machine changes nothing at all.
    try testing.expectEqual(free, @min(free, @as(usize, 64)));
}

test "a container memory limit is read from v2 and v1" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("memory");
    try tmp.dir.makePath("docker/abc");

    // v2, a container with 1 GiB and a page cache: 600 MB of anon is resident,
    // the rest is reclaimable, so 424 MB is still available. Not the 32 GB
    // /proc/meminfo reports inside it, which is the bug this exists for.
    try tmp.dir.writeFile(.{ .sub_path = "docker/abc/memory.max", .data = "1073741824\n" });
    try tmp.dir.writeFile(.{ .sub_path = "docker/abc/memory.stat", .data = "anon 629145600\nfile 0\n" });
    try tmp.dir.writeFile(.{ .sub_path = "memory.max", .data = "max\n" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &root_buf);

    const container = memoryBudgetFrom(root, "0::/docker/abc\n").?;
    try testing.expectEqual(@as(u64, 1073741824), container.limit);
    try testing.expectEqual(@as(u64, 444596224), container.available);
    // A namespace where the process sits at the root: the container's own limit.
    try tmp.dir.writeFile(.{ .sub_path = "memory.max", .data = "536870912\n" });
    try tmp.dir.writeFile(.{ .sub_path = "memory.stat", .data = "anon 268435456\n" });
    const at_root = memoryBudgetFrom(root, "0::/\n").?;
    try testing.expectEqual(@as(u64, 536870912), at_root.limit);
    try testing.expectEqual(@as(u64, 268435456), at_root.available);

    // v1: limit and usage, with a limit just under 2^63 meaning "unlimited".
    // A host runs one hierarchy or the other, so the v2 files go back to
    // unlimited first - a fixture with both would be testing a machine that
    // does not exist (and would let a v2 answer mask a broken v1 read).
    try tmp.dir.writeFile(.{ .sub_path = "memory.max", .data = "max\n" });
    try testing.expect(memoryBudgetFrom(root, "7:memory:/x\n") == null);
    try tmp.dir.writeFile(.{ .sub_path = "memory/memory.limit_in_bytes", .data = "2147483648\n" });
    try tmp.dir.writeFile(.{ .sub_path = "memory/memory.usage_in_bytes", .data = "1073741824\n" });
    const v1 = memoryBudgetFrom(root, "7:memory:/\n").?;
    try testing.expectEqual(@as(u64, 2147483648), v1.limit);
    try testing.expectEqual(@as(u64, 1073741824), v1.available);

    // v1 unlimited is a number, not the word: it must read as no limit at all.
    try tmp.dir.writeFile(.{ .sub_path = "memory/memory.limit_in_bytes", .data = "9223372036854771712\n" });
    try testing.expect(memoryBudgetFrom(root, "7:memory:/\n") == null);

    // A bare-metal machine has neither file: null, and no arithmetic on junk.
    var empty = testing.tmpDir(.{});
    defer empty.cleanup();
    var empty_buf: [std.fs.max_path_bytes]u8 = undefined;
    const empty_root = try empty.dir.realpath(".", &empty_buf);
    try testing.expect(memoryBudgetFrom(empty_root, "0::/\n") == null);
}

test "an empty CPU list produces no threads instead of crashing" {
    const testing = std.testing;

    var out: [4]usize = undefined;
    try testing.expectEqual(@as(usize, 0), selectCpus(.free, &.{}, &out).len);
    try testing.expectEqual(@as(usize, 0), selectCpus(.watt, &.{}, &out).len);
}

test "cpu list parsing handles ranges, singletons and junk" {
    const testing = std.testing;

    var buf: [32]u32 = undefined;

    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 8, 10, 11 }, parseCpuList("0-3,8,10-11\n", &buf));
    try testing.expectEqualSlices(u32, &.{5}, parseCpuList("5", &buf));
    try testing.expectEqual(@as(usize, 0), parseCpuList("", &buf).len);
    // Junk between valid ranges must not stop the parse.
    try testing.expectEqualSlices(u32, &.{ 0, 2 }, parseCpuList("0,oops,2", &buf));
    // A backwards range is dropped, not spun on.
    try testing.expectEqual(@as(usize, 0), parseCpuList("9-3", &buf).len);

    // The buffer is a hard limit, never an overrun.
    var small: [3]u32 = undefined;
    try testing.expectEqual(@as(usize, 3), parseCpuList("0-15", &small).len);
}

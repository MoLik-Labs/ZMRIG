//! Bindings for the RandomX hash engine (zmrig/capi/xmo_randomx.h).
//!
//! The engine is the RandomX implementation from this repository, compiled into
//! libxmorx.a. Everything here is a thin, allocation-explicit wrapper: the Zig
//! miner owns the threads and the pool connection, the C++ side owns the cache,
//! the dataset and one VM per thread.

const std = @import("std");

pub const Engine = opaque {};
pub const Vm = opaque {};

pub const Algo = enum(c_int) {
    rx_0 = 0,
    rx_2 = 1,
    rx_wow = 2,
    rx_arq = 3,
    rx_graft = 4,
    rx_sfx = 5,
    rx_yada = 6,
    rx_xla = 7,

    pub fn fromName(text: []const u8) ?Algo {
        const table = .{
            .{ "rx/0", Algo.rx_0 },
            .{ "rx", Algo.rx_0 },
            .{ "randomx", Algo.rx_0 },
            .{ "rx/2", Algo.rx_2 },
            .{ "rx/wow", Algo.rx_wow },
            .{ "rx/arq", Algo.rx_arq },
            .{ "rx/graft", Algo.rx_graft },
            .{ "rx/sfx", Algo.rx_sfx },
            .{ "rx/yada", Algo.rx_yada },
            .{ "panthera", Algo.rx_xla },
            .{ "rx/xla", Algo.rx_xla },
        };

        inline for (table) |entry| {
            if (std.ascii.eqlIgnoreCase(text, entry[0])) return entry[1];
        }

        return null;
    }

    /// Bytes the dataset for this variant occupies, straight from the
    /// configuration compiled into RandomX. Wownero is not Monero-sized and
    /// Panthera is 64 MiB, not 2080: anything that reserves memory has to ask.
    pub fn datasetBytes(self: Algo) usize {
        return xmo_algo_dataset_memory(@intFromEnum(self));
    }

    /// Cache only. `--mode=light` never builds a dataset, so this is all it
    /// needs.
    pub fn cacheBytes(self: Algo) usize {
        return xmo_algo_cache_memory(@intFromEnum(self));
    }

    /// Cache plus dataset — what a full-memory engine maps.
    pub fn memoryBytes(self: Algo, full_memory: bool) usize {
        return self.cacheBytes() + if (full_memory) self.datasetBytes() else 0;
    }

    pub fn label(self: Algo) []const u8 {
        return switch (self) {
            .rx_0 => "rx/0",
            .rx_2 => "rx/2",
            .rx_wow => "rx/wow",
            .rx_arq => "rx/arq",
            .rx_graft => "rx/graft",
            .rx_sfx => "rx/sfx",
            .rx_yada => "rx/yada",
            .rx_xla => "panthera",
        };
    }
};

/// Every RandomX variant this engine can hash *correctly*, i.e. the list a
/// pool may switch a rig between. `--algo=auto` advertises exactly this, and
/// the order is what the operator reads in `--check`.
///
/// The C++ side has a named configuration for each of these
/// (`src/crypto/rx/RxAlgo.cpp`: Monero, Wownero, Arqma, Graft, Safex, Yada,
/// Scala), which is what makes advertising them honest rather than
/// optimistic: a variant without its own configuration would hash with
/// Monero parameters and every share would be rejected.
///
/// `rx/2` is deliberately absent. What it means depends on which fork
/// compiled the pool (MoneroOcean's V2 tuning), so a rig advertising it can
/// be handed a job it cannot reproduce; the cost of that guess is a night of
/// 100 % rejects, and the gain is a fraction of one algorithm among seven.
pub const auto_algos = [_]Algo{ .rx_0, .rx_wow, .rx_arq, .rx_graft, .rx_sfx, .rx_yada, .rx_xla };

/// xmo_engine_new() flags.
pub const EngineFlags = struct {
    huge_pages: bool = true,
    huge_pages_jit: bool = true,
    full_memory: bool = true,
    jit: bool = true,

    pub fn bits(self: EngineFlags) c_int {
        var flags: c_int = 0;
        if (self.huge_pages) flags |= 1;
        if (self.huge_pages_jit) flags |= 2;
        if (self.full_memory) flags |= 4;
        if (self.jit) flags |= 8;

        return flags;
    }
};

pub extern fn xmo_engine_new(algo: c_int, flags: c_int, err: [*]u8, errlen: usize) ?*Engine;
pub extern fn xmo_engine_free(engine: ?*Engine) void;
/// Makes this engine's algorithm the process-wide RandomX configuration. The
/// configuration is global (dataset sizes, JIT program parameters, AES keys),
/// so an engine that was created earlier and is being switched back to has to
/// re-assert it. Call with the workers stopped.
pub extern fn xmo_engine_activate(engine: *Engine) void;
pub extern fn xmo_engine_dataset_size(engine: *const Engine) usize;
pub extern fn xmo_engine_cache_size(engine: *const Engine) usize;
pub extern fn xmo_engine_seed(engine: *Engine, seed: [*]const u8, seed_len: usize, threads: c_int, err: [*]u8, errlen: usize) c_int;
pub extern fn xmo_engine_huge_pages(engine: *const Engine) usize;
pub extern fn xmo_engine_huge_pages_total(engine: *const Engine) usize;

pub extern fn xmo_engine_huge_page_kb(engine: *const Engine) usize;
pub extern fn xmo_engine_total_memory(engine: *const Engine) usize;
pub extern fn xmo_vm_new(engine: *Engine, flags: c_int, numa_node: u32, err: [*]u8, errlen: usize) ?*Vm;
pub extern fn xmo_vm_free(vm: ?*Vm) void;
pub extern fn xmo_hash(vm: *Vm, blob: [*]const u8, len: usize, out: *[32]u8) void;
pub extern fn xmo_hash_first(vm: *Vm, blob: [*]const u8, len: usize, temp: *align(64) [8]u64) void;
pub extern fn xmo_hash_next(vm: *Vm, temp: *align(64) [8]u64, blob: [*]const u8, len: usize, out: *[32]u8) void;
pub extern fn xmo_commitment(blob: [*]const u8, len: usize, hash_in: *const [32]u8, out: *[32]u8) void;
pub extern fn xmo_set_scratchpad_prefetch(mode: c_int) void;
pub extern fn xmo_set_huge_pages_jit(enabled: c_int) void;
pub extern fn xmo_msr_apply(save: c_int, report: [*]u8, report_len: usize) c_int;
pub extern fn xmo_msr_restore(report: [*]u8, report_len: usize) c_int;
pub extern fn xmo_msr_probe(report: [*]u8, report_len: usize) c_int;
pub extern fn xmo_set_optimized_dataset_init(value: c_int) void;
pub extern fn xmo_engine_name() [*:0]const u8;

/// Pure queries: they read the configuration table without creating an engine
/// or touching the global RandomX state.
pub extern fn xmo_algo_memory(algo: c_int, full_memory: c_int) usize;
pub extern fn xmo_algo_dataset_memory(algo: c_int) usize;
pub extern fn xmo_algo_cache_memory(algo: c_int) usize;

/// Zig-side wrapper that keeps the "did it work" bookkeeping out of the miner.
pub const Wrapped = struct {
    handle: *Engine,
    algo: Algo,
    full_memory: bool,
    huge_pages: bool,

    pub fn create(algo: Algo, flags: EngineFlags) !Wrapped {
        var buf: [256]u8 = undefined;

        const handle = xmo_engine_new(@intFromEnum(algo), flags.bits(), &buf, buf.len) orelse {
            return error.EngineInitFailed;
        };

        return .{
            .handle = handle,
            .algo = algo,
            .full_memory = flags.full_memory,
            .huge_pages = flags.huge_pages,
        };
    }

    pub fn destroy(self: *Wrapped) void {
        xmo_engine_free(self.handle);
        self.handle = undefined;
    }

    pub fn activate(self: *const Wrapped) void {
        xmo_engine_activate(self.handle);
    }

    pub fn seed(self: *Wrapped, seed_bytes: []const u8, threads: usize) !void {
        var buf: [256]u8 = undefined;

        if (xmo_engine_seed(self.handle, seed_bytes.ptr, seed_bytes.len, @intCast(@max(threads, 1)), &buf, buf.len) != 0) {
            return error.SeedFailed;
        }
    }

    pub fn datasetSize(self: *const Wrapped) usize {
        return xmo_engine_dataset_size(self.handle);
    }

    pub fn cacheSize(self: *const Wrapped) usize {
        return xmo_engine_cache_size(self.handle);
    }

    /// Bytes really backed by explicit huge pages (0 when the kernel had none
    /// reserved and the engine fell back to ordinary pages).
    pub fn hugePageBytes(self: *const Wrapped) usize {
        return xmo_engine_huge_pages(self.handle);
    }

    /// Bytes that asked for huge pages, granted or not.
    pub fn hugePageBytesTotal(self: *const Wrapped) usize {
        return xmo_engine_huge_pages_total(self.handle);
    }

    /// The page size behind the mapping in KiB: 0 for ordinary 4 KiB pages,
    /// 2048 for 2 MiB pages, 1048576 when the mapping came out of a reserved
    /// 1 GiB pool. Two mappings of the same size do not perform the same, so
    /// this is the number worth printing next to the byte count.
    pub fn hugePageKb(self: *const Wrapped) usize {
        return xmo_engine_huge_page_kb(self.handle);
    }

    pub fn totalMemory(self: *const Wrapped) usize {
        return xmo_engine_total_memory(self.handle);
    }

    pub fn createVm(self: *Wrapped, huge_pages: bool) !*Vm {
        var buf: [256]u8 = undefined;
        var flags: c_int = 0;
        if (huge_pages) flags |= 1;

        return xmo_vm_new(self.handle, flags, 0, &buf, buf.len) orelse error.VmInitFailed;
    }
};

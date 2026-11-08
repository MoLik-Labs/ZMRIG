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
//! 25.5 ms each in light mode and 2.9 ms each in fast mode - 39 shares/s
//! against 350 - after 0.6 s and 21 s of setup respectively. It costs 2336 MB
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
};

pub fn run(allocator: std.mem.Allocator, logger: *log.Logger, settings: Settings) !void {
    const full_memory = settings.full_memory;
    var wrapped: ?api.Wrapped = null;
    defer if (wrapped) |*w| w.destroy();

    var vm: ?*api.Vm = null;
    defer if (vm) |v| api.xmo_vm_free(v);

    var current_seed: [32]u8 = [_]u8{0} ** 32;
    var have_seed = false;

    var stdin_buf = std.io.bufferedReader(std.io.getStdIn().reader());
    const reader = stdin_buf.reader();

    var stdout_buf = std.io.bufferedWriter(std.io.getStdOut().writer());
    const writer = stdout_buf.writer();

    var line_buf: [64 * 1024]u8 = undefined;
    var blob_buf: [4096]u8 = undefined;

    // Dataset initialisation is very close to linear in threads - measured
    // 21.5 s at 2 threads and 42.5 s at 1 on the test host - and happens once
    // per seed change, which is once per block.
    // Capped at 16: past that the cache becomes the bottleneck and the rest of
    // the pool's work suffers for a build that is already a few seconds.
    const init_threads: usize = if (settings.init_threads > 0)
        @min(settings.init_threads, 64)
    else
        @min(std.Thread.getCpuCount() catch 1, 16);

    if (full_memory) {
        logger.info("verify mode: hashing submitted shares (fast mode, {d} MB cache + {d} MB dataset)", .{
            api.Algo.rx_0.cacheBytes() / (1024 * 1024), api.Algo.rx_0.datasetBytes() / (1024 * 1024),
        });
    } else {
        logger.info("verify mode: hashing submitted shares (light mode, 256 MB cache)", .{});
    }

    while (true) {
        const line = reader.readUntilDelimiterOrEof(&line_buf, '\n') catch |e| switch (e) {
            error.StreamTooLong => {
                try writer.writeAll("{\"error\":\"line too long\"}\n");
                try stdout_buf.flush();

                continue;
            },
            else => return,
        } orelse break;

        const text = std.mem.trim(u8, line, " \t\r");
        if (text.len == 0) continue;
        if (std.mem.eql(u8, text, "quit")) break;

        var request = parseRequest(allocator, text) catch |e| {
            const message = switch (e) {
                error.UnsupportedAlgo => "{\"error\":\"this verifier only computes rx/0\"}\n",
                error.InvalidNonce => "{\"error\":\"nonce must be a hex string\"}\n",
                else => "{\"error\":\"invalid request\"}\n",
            };

            try writer.writeAll(message);
            try stdout_buf.flush();

            continue;
        };
        defer request.deinit(allocator);

        if (request.seed.len != 64) {
            try writer.writeAll("{\"error\":\"seed must be 64 hex characters\"}\n");
            try stdout_buf.flush();

            continue;
        }

        var seed_bytes: [32]u8 = undefined;
        _ = util.hexToBytes(&seed_bytes, request.seed) catch {
            try writer.writeAll("{\"error\":\"seed is not hex\"}\n");
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
                try writer.writeAll("{\"error\":\"cannot create the hash engine\"}\n");
                try stdout_buf.flush();

                continue;
            };
        }

        if (!have_seed or !std.mem.eql(u8, &current_seed, &seed_bytes)) {
            // Building the dataset is the one place a verifier can use more
            // than one core: every share afterwards is a single hash on this
            // thread. A light verifier ignores the number.
            if (wrapped.?.seed(&seed_bytes, init_threads)) |_| {
                current_seed = seed_bytes;
                have_seed = true;
            } else |_| {
                try writer.writeAll("{\"error\":\"cannot build the cache for this seed\"}\n");
                try stdout_buf.flush();

                continue;
            }
        }

        if (vm == null) {
            vm = wrapped.?.createVm(false) catch {
                try writer.writeAll("{\"error\":\"cannot create the VM\"}\n");
                try stdout_buf.flush();

                continue;
            };
        }

        const blob = util.hexToBytes(&blob_buf, request.blob) catch {
            try writer.writeAll("{\"error\":\"blob is not hex\"}\n");
            try stdout_buf.flush();

            continue;
        };

        if (blob.len == 0) {
            try writer.writeAll("{\"error\":\"empty blob\"}\n");
            try stdout_buf.flush();

            continue;
        }

        // Pools send the nonce as its own field; patching it here means the
        // blob the pool stores never has to be rewritten per share.
        if (request.nonce.len > 0) {
            if (request.nonce.len != 8) {
                try writer.writeAll("{\"error\":\"nonce must be 8 hex characters\"}\n");
                try stdout_buf.flush();

                continue;
            }

            // The miner sends the nonce as the *number* it used, in hex. It
            // wrote it to the blob little-endian, so patch it the same way.
            const nonce_value = std.fmt.parseInt(u32, request.nonce, 16) catch {
                try writer.writeAll("{\"error\":\"nonce is not hex\"}\n");
                try stdout_buf.flush();

                continue;
            };

            if (request.nonce_offset + 4 > blob.len) {
                try writer.writeAll("{\"error\":\"nonce offset outside the blob\"}\n");
                try stdout_buf.flush();

                continue;
            }

            util.writeLe(u32, blob[0..], request.nonce_offset, nonce_value);
        }

        var hash: [32]u8 align(64) = undefined;
        api.xmo_hash(vm.?, blob.ptr, blob.len, &hash);

        var hex: [64]u8 = undefined;
        writeHex(&hex, &hash);

        try writer.print("{{\"hash\":\"{s}\"}}\n", .{hex});
        try stdout_buf.flush();
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

//! Minimal read-only HTTP API for monitoring.
//!
//! `--http-port 18080` (and optionally `--http-host 0.0.0.0`,
//! `--http-access-token SECRET`) exposes the same view XMRig's API does, so
//! existing dashboards and scrapers keep working:
//!
//!   GET /1/summary      XMRig shaped summary (the one every dashboard polls)
//!   GET /1/status       alias, for the older clients
//!   GET /json_rpc       {"jsonrpc":"2.0","id":1,"method":"summary"} also works
//!
//! The API is read only: no pause/resume, no config reload. That keeps the
//! attack surface of a miner exposed on a LAN small, which matters more than
//! convenience for a rig that sits in a rack for months.
//!
//! Everything the API reports is read from atomics that the mining threads and
//! the monitor already publish, so serving a request never disturbs hashing.

const std = @import("std");
const api = @import("api.zig");
const log = @import("log.zig");
const miner_mod = @import("miner.zig");

/// Values the monitor samples once a second. Written only by the monitor
/// thread, read by the API thread.
pub const View = struct {
    rate_10s: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rate_60s: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rate_15m: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    highest: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    hashes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// When the current pool connection was established, 0 when offline.
    connected_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

    pub fn store(self: *View, rate_10s: f64, rate_60s: f64, rate_15m: f64, peak_rate: f64, hashes: u64) void {
        self.rate_10s.store(@bitCast(rate_10s), .release);
        self.rate_60s.store(@bitCast(rate_60s), .release);
        self.rate_15m.store(@bitCast(rate_15m), .release);
        self.highest.store(@bitCast(peak_rate), .release);
        self.hashes.store(hashes, .release);
    }

    pub fn hashesTotal(self: *const View) u64 {
        return self.hashes.load(.acquire);
    }

    pub fn markConnected(self: *View, when_ms: i64) void {
        self.connected_ms.store(when_ms, .release);
    }

    pub fn markDisconnected(self: *View) void {
        self.connected_ms.store(0, .release);
    }

    /// Seconds the current pool connection has been up, 0 while offline.
    pub fn connectionUptime(self: *const View) i64 {
        const since = self.connected_ms.load(.acquire);
        if (since <= 0) return 0;

        const delta = @divTrunc(std.time.milliTimestamp() - since, 1000);

        return if (delta > 0) delta else 0;
    }

    pub fn rate10s(self: *const View) f64 {
        return @bitCast(self.rate_10s.load(.acquire));
    }

    pub fn rate60s(self: *const View) f64 {
        return @bitCast(self.rate_60s.load(.acquire));
    }

    pub fn rate15m(self: *const View) f64 {
        return @bitCast(self.rate_15m.load(.acquire));
    }

    /// The session peak (the field is called `highest`, so the accessor needs
    /// a different name: a field shadows a method with the same name).
    pub fn peak(self: *const View) f64 {
        return @bitCast(self.highest.load(.acquire));
    }
};

/// Everything the responses need, filled in once at startup plus the live
/// atomics behind it.
pub const Info = struct {
    version: []const u8,
    pool_url: []const u8,
    worker_id: []const u8,
    /// Live view of the engine, so the reported algorithm is the one actually
    /// in use (a pool can switch it at any time).
    miner: *const miner_mod.Miner,
    threads: usize,
    /// Developer fee in percent, so a dashboard shows what the binary is
    /// actually configured to take rather than a hardcoded zero.
    donate_percent: u32,
    started_ms: i64,
    /// Result counters, owned by the submitter.
    accepted: *const std.atomic.Value(u64),
    rejected: *const std.atomic.Value(u64),
    failed: *const std.atomic.Value(u64),
    view: *const View,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    logger: *log.Logger,
    host: []const u8,
    port: u16,
    token: ?[]const u8,
    info: Info,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Socket of the listener, so stop() can wake the accept loop.
    listener_fd: std.atomic.Value(i32) = std.atomic.Value(i32).init(-1),
    /// The listening socket itself, kept here so the accept loop can own it.
    listener: ?std.net.Server = null,
    thread: ?std.Thread = null,

    const Self = @This();

    pub fn start(self: *Self) !void {
        const address = std.net.Address.parseIp(self.host, self.port) catch blk: {
            // Not an IP literal: let the resolver deal with it (usually a name
            // that resolves to a single local interface).
            const list = std.net.getAddressList(self.allocator, self.host, self.port) catch {
                self.logger.err("cannot resolve --http-host {s}", .{self.host});

                return error.InvalidHttpHost;
            };
            defer list.deinit();

            if (list.addrs.len == 0) return error.InvalidHttpHost;

            break :blk list.addrs[0];
        };

        // Bind by hand instead of std's address.listen(): on POSIX that sets
        // SO_REUSEPORT as well as SO_REUSEADDR, so two miners (or a miner and a
        // leftover test process) silently share the port and /1/summary answers
        // with whichever instance the kernel picks. Only SO_REUSEADDR is wanted
        // here: it lets us restart immediately after a crash, nothing more.
        const fd = std.posix.socket(address.any.family, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, std.posix.IPPROTO.TCP) catch |e| {
            self.logger.err("cannot create the api socket: {s}", .{@errorName(e)});

            return error.HttpListenFailed;
        };

        var close_fd = true;
        defer if (close_fd) std.posix.close(fd);

        const on: c_int = 1;
        std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(&on)) catch {};
        std.posix.bind(fd, &address.any, address.getOsSockLen()) catch |e| {
            self.logger.err("cannot listen on {s}:{d}: {s}", .{ self.host, self.port, @errorName(e) });

            return error.HttpListenFailed;
        };
        std.posix.listen(fd, 128) catch |e| {
            self.logger.err("cannot listen on {s}:{d}: {s}", .{ self.host, self.port, @errorName(e) });

            return error.HttpListenFailed;
        };

        close_fd = false;
        self.listener = .{ .listen_address = address, .stream = .{ .handle = fd } };

        self.listener_fd.store(self.listener.?.stream.handle, .release);
        // The accept loop must not park forever, otherwise stop() would wait a
        // second at most, which is fine, but a shutdown should be instant.
        const tv = std.posix.timeval{ .tv_sec = 1, .tv_usec = 0 };
        std.posix.setsockopt(self.listener.?.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};

        self.thread = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, run, .{self});
        self.logger.info("http api listening on http://{s}:{d}{s}", .{
            self.host,
            self.port,
            if (self.token != null) " (token required)" else "",
        });
    }

    /// Stops the loop and closes the listener. Idempotent.
    pub fn stopServer(self: *Self) void {
        if (self.thread == null) return;

        self.stop.store(true, .release);

        const fd = self.listener_fd.load(.acquire);
        if (fd >= 0) std.posix.shutdown(fd, .both) catch {};

        if (self.thread) |thread| thread.join();
        self.thread = null;

        if (self.listener) |*listener| listener.deinit();
        self.listener = null;
        self.listener_fd.store(-1, .release);
    }
};

fn run(server: *Server) void {
    const listener = &server.listener.?;

    while (!server.stop.load(.acquire)) {
        const connection = listener.accept() catch continue;

        // A client that connects and then says nothing must not wedge the
        // single API thread: every socket gets a short timeout.
        const tv = std.posix.timeval{ .tv_sec = 5, .tv_usec = 0 };
        std.posix.setsockopt(connection.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
        std.posix.setsockopt(connection.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch {};

        // Connections are handled inline: a monitoring request is a single
        // small round trip, and a miner has no spare thread to hand out.
        handle(server, connection.stream);

        connection.stream.close();
    }
}

fn handle(server: *Server, stream: std.net.Stream) void {
    var buffer: [16 * 1024]u8 = undefined;
    var filled: usize = 0;
    var deadline: usize = 0;

    // Read the request head. A client that never sends a full header is cut
    // off after a few reads instead of pinning this thread forever.
    while (std.mem.indexOf(u8, buffer[0..filled], "\r\n\r\n") == null) {
        if (filled == buffer.len or deadline >= 8) break;

        const n = stream.read(buffer[filled..]) catch return;
        if (n == 0) return;

        filled += n;
        deadline += 1;
    }

    const head = buffer[0..filled];

    var lines = std.mem.splitSequence(u8, head, "\r\n");
    const request_line = lines.next() orelse return;

    var parts = std.mem.tokenizeScalar(u8, request_line, ' ');
    const method = parts.next() orelse return;
    const target = parts.next() orelse return;

    const path = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;

    if (server.token) |token| {
        if (!authorised(head, token)) {
            respond(stream, "401 Unauthorized", "application/json", "{\"status\":\"error\",\"error\":\"unauthorized\"}\n");

            return;
        }
    }

    const head_only = std.mem.eql(u8, method, "HEAD");
    const is_get = std.mem.eql(u8, method, "GET") or head_only;
    const is_post = std.mem.eql(u8, method, "POST");

    if (is_get and (std.mem.eql(u8, path, "/2/summary") or std.mem.eql(u8, path, "/2/status"))) {
        // API v2: same data, pretty printed with one field per line, which is
        // what XMRig emits and what the installer's status parser reads.
        respondV2(server, stream, !head_only);

        return;
    }

    if (is_get and (std.mem.eql(u8, path, "/1/summary") or std.mem.eql(u8, path, "/1/status") or std.mem.eql(u8, path, "/summary"))) {
        respondJson(server, stream, !head_only);

        return;
    }

    if (path.len == 0 or std.mem.eql(u8, path, "/")) {
        respond(stream, "200 OK", "text/plain; charset=utf-8", "zmrig http api\n/1/summary\n/json_rpc\n");

        return;
    }

    if (is_post and std.mem.eql(u8, path, "/json_rpc") or is_get and std.mem.eql(u8, path, "/json_rpc")) {
        respondJson(server, stream, !head_only);

        return;
    }

    // Anything else is a 404 with a JSON body, so a dashboard shows a readable
    // error instead of HTML.
    respond(stream, "404 Not Found", "application/json", "{\"status\":\"error\",\"error\":\"not found\"}\n");
}

/// Compare token bytes without returning on the first mismatch. Token length is
/// configuration and already known to the caller, but matching content should
/// not leak through a byte-by-byte timing oracle on a LAN-exposed API.
fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;

    var difference: u8 = 0;
    for (a, b) |left, right| difference |= left ^ right;

    return difference == 0;
}

test "API token comparison checks all same-length bytes" {
    try std.testing.expect(constantTimeEql("correct horse", "correct horse"));
    try std.testing.expect(!constantTimeEql("xorrect horse", "correct horse"));
    try std.testing.expect(!constantTimeEql("correct horsf", "correct horse"));
    try std.testing.expect(!constantTimeEql("short", "correct horse"));
}

fn authorised(head: []const u8, token: []const u8) bool {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next(); // request line

    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;

        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "authorization")) continue;

        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");

        // `Bearer <token>` is what XMRig and every dashboard sends; a bare
        // token is accepted too because that is what curl users type.
        const candidate = if (std.ascii.startsWithIgnoreCase(value, "bearer "))
            std.mem.trim(u8, value["bearer ".len..], " \t")
        else
            value;

        return constantTimeEql(candidate, token);
    }

    return false;
}

fn respondJson(server: *Server, stream: std.net.Stream, with_body: bool) void {
    var buffer: [2048]u8 = undefined;
    const body = summary(server, &buffer) catch {
        respondBody(stream, "500 Internal Server Error", "application/json", "{\"status\":\"error\",\"error\":\"out of memory\"}\n", with_body);

        return;
    };

    respondBody(stream, "200 OK", "application/json", body, with_body);
}

fn respondV2(server: *Server, stream: std.net.Stream, with_body: bool) void {
    var buffer: [4096]u8 = undefined;
    const body = summaryV2(server, &buffer) catch {
        respondBody(stream, "500 Internal Server Error", "application/json", "{\"status\":\"error\",\"error\":\"out of memory\"}\n", with_body);

        return;
    };

    respondBody(stream, "200 OK", "application/json", body, with_body);
}

/// Return one complete JSON string literal. Pool labels and rig identifiers are
/// user-controlled config; interpolating them between quotes makes a valid
/// worker name such as `rig"1` corrupt the whole monitoring response (and can
/// inject fields into dashboards that consume it).
fn escapedJsonString(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    return std.json.stringifyAlloc(allocator, value, .{});
}

test "API JSON string encoding cannot escape its field" {
    const input = "rig\"\\name\n\t\x01雪";
    const encoded = try escapedJsonString(std.testing.allocator, input);
    defer std.testing.allocator.free(encoded);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, encoded, .{});
    defer parsed.deinit();

    switch (parsed.value) {
        .string => |decoded| try std.testing.expectEqualStrings(input, decoded),
        else => return error.ExpectedJsonString,
    }
}

fn summaryV2(server: *Server, buffer: []u8) ![]const u8 {
    const info = server.info;
    const worker_id_json = try escapedJsonString(server.allocator, info.worker_id);
    defer server.allocator.free(worker_id_json);
    const version_json = try escapedJsonString(server.allocator, info.version);
    defer server.allocator.free(version_json);
    const algo = if (info.miner.engine.algo) |current| current.label() else "auto";
    const algo_json = try escapedJsonString(server.allocator, algo);
    defer server.allocator.free(algo_json);
    const pool_json = try escapedJsonString(server.allocator, info.pool_url);
    defer server.allocator.free(pool_json);
    const uptime = @divTrunc(std.time.milliTimestamp() - info.started_ms, 1000);
    const huge_pages = info.miner.hugePages();
    const paused = info.miner.shared.paused.load(.acquire);
    const highest = @max(info.view.peak(), info.view.rate60s());
    const accepted = info.accepted.load(.monotonic);
    const rejected = info.rejected.load(.monotonic);
    const failed = info.failed.load(.monotonic);
    const total_shares = accepted + rejected;

    return std.fmt.bufPrint(buffer,
        \\{{
        \\  "id": "zmrig",
        \\  "worker_id": {s},
        \\  "uptime": {d},
        \\  "version": {s},
        \\  "kind": "miner",
        \\  "ua": "zmrig/{s}",
        \\  "algo": {s},
        \\  "paused": {s},
        \\  "donate_level": {d},
        \\  "connection": {{
        \\    "pool": {s},
        \\    "uptime": {d},
        \\    "failures": {d},
        \\    "tls": {s}
        \\  }},
        \\  "cpu": {{
        \\    "threads": {d}
        \\  }},
        \\  "hugepages": [
        \\    {d},
        \\    {d}
        \\  ],
        \\  "hashrate": {{
        \\    "total": [{d:.1},{d:.1},{d:.1}],
        \\    "highest": {d:.1}
        \\  }},
        \\  "results": {{
        \\    "shares_good": {d},
        \\    "shares_total": {d},
        \\    "hashes_total": {d},
        \\    "error_log": []
        \\  }}
        \\}}
        \\
    , .{
        worker_id_json,
        uptime,
        version_json,
        info.version,
        algo_json,
        if (paused) "true" else "false",
        info.donate_percent,
        pool_json,
        info.view.connectionUptime(),
        failed,
        if (std.mem.indexOf(u8, info.pool_url, "wss://") != null or std.mem.indexOf(u8, info.pool_url, "tls://") != null) "true" else "false",
        info.threads,
        huge_pages[0],
        huge_pages[1],
        info.view.rate10s(),
        info.view.rate60s(),
        info.view.rate15m(),
        highest,
        accepted,
        total_shares,
        info.view.hashesTotal(),
    });
}

fn summary(server: *Server, buffer: []u8) ![]const u8 {
    const info = server.info;
    const worker_id_json = try escapedJsonString(server.allocator, info.worker_id);
    defer server.allocator.free(worker_id_json);
    const version_json = try escapedJsonString(server.allocator, info.version);
    defer server.allocator.free(version_json);
    const algo = if (info.miner.engine.algo) |current| current.label() else "auto";
    const algo_json = try escapedJsonString(server.allocator, algo);
    defer server.allocator.free(algo_json);
    const pool_json = try escapedJsonString(server.allocator, info.pool_url);
    defer server.allocator.free(pool_json);
    const uptime = @divTrunc(std.time.milliTimestamp() - info.started_ms, 1000);
    const huge_pages = info.miner.hugePages();
    const paused = info.miner.shared.paused.load(.acquire);
    const highest = @max(info.view.peak(), info.view.rate60s());
    const accepted = info.accepted.load(.monotonic);
    const rejected = info.rejected.load(.monotonic);
    const failed = info.failed.load(.monotonic);

    return std.fmt.bufPrint(buffer,
        \\{{"id":"zmrig","worker_id":{s},"uptime":{d},"version":{s},"kind":"miner","ua":"zmrig/{s}",
        \\"algo":{s},"paused":{s},"donate_level":{d},
        \\"connection":{{"pool":{s},"uptime":{d},"failures":{d},"tls":{s}}},
        \\"hashrate":{{"total":[{d:.1},{d:.1},{d:.1}],"highest":{d:.1}}},
        \\"hugepages":[{d},{d}],
        \\"cpu":{{"threads":{d}}},
        \\"results":{{"shares_good":{d},"shares_total":{d},"hashes_total":{d},"error_log":[]}}}}
        \\
    , .{
        worker_id_json,
        uptime,
        version_json,
        info.version,
        algo_json,
        if (paused) "true" else "false",
        info.donate_percent,
        pool_json,
        info.view.connectionUptime(),
        failed,
        if (std.mem.indexOf(u8, info.pool_url, "wss://") != null or std.mem.indexOf(u8, info.pool_url, "tls://") != null) "true" else "false",
        info.view.rate10s(),
        info.view.rate60s(),
        info.view.rate15m(),
        highest,
        huge_pages[0],
        huge_pages[1],
        info.threads,
        accepted,
        accepted + rejected,
        info.view.hashesTotal(),
    });
}

fn respond(stream: std.net.Stream, status: []const u8, content_type: []const u8, body: []const u8) void {
    respondBody(stream, status, content_type, body, true);
}

fn respondBody(stream: std.net.Stream, status: []const u8, content_type: []const u8, body: []const u8, with_body: bool) void {
    var header: [512]u8 = undefined;
    const head = std.fmt.bufPrint(&header, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n" ++
        "Cache-Control: no-store\r\nConnection: close\r\n\r\n", .{ status, content_type, body.len }) catch return;

    stream.writeAll(head) catch return;
    if (with_body) stream.writeAll(body) catch {};
}

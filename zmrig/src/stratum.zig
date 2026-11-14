//! Stratum client: pool connection, login, job parsing, share submission.
//!
//! Speaks the same dialect XMRig uses (line delimited JSON, `login` / `job` /
//! `submit` / `keepalived`), including the MoneroOcean `algo` extension that
//! lets a pool switch the miner between RandomX forks.

const std = @import("std");
const api = @import("api.zig");
const job = @import("job.zig");
const log = @import("log.zig");
const options = @import("options.zig");
const transport = @import("transport.zig");
const util = @import("util.zig");

pub const agent = "zmrig/6.32.1";

/// `--user-agent`: some pools and relays only accept a known miner string, and
/// Cloudflare Workers can route on it. Null keeps the default.
pub var user_agent: ?[]const u8 = null;

/// Why a pool said no. The difference is money: a wrong wallet retried every
/// few seconds is how an IP ends up banned on several pools at once, while
/// "low difficulty share" is the pool telling us the hardware is producing
/// garbage -- repeating it is what turns a 10-minute ban into an hour.
pub const Refusal = enum {
    none,
    banned,
    credentials,
    invalid_share,
    throttled,
    full,

    pub fn label(self: Refusal) []const u8 {
        return switch (self) {
            .none => "none",
            .banned => "banned",
            .credentials => "credentials",
            .invalid_share => "invalid share",
            .throttled => "throttled",
            .full => "pool full",
        };
    }
};

/// Substring match that ignores case: pools write "your IP is banned",
/// "BANNED", "Invalid address" and everything in between.
fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }

    return false;
}

/// Turns a pool's error text into a decision. Order matters: "invalid share"
/// also contains "invalid", so it is matched before the credential phrases.
pub fn classify(text: []const u8) Refusal {
    if (text.len == 0) return .none;

    const ban_phrases = [_][]const u8{ "ban", "blocked", "blacklist", "not allowed", "denied" };
    for (ban_phrases) |phrase| {
        if (contains(text, phrase)) return .banned;
    }

    const share_phrases = [_][]const u8{
        "invalid share", "low difficulty", "bad share", "invalid result", "invalid nonce", "invalid hash",
    };
    for (share_phrases) |phrase| {
        if (contains(text, phrase)) return .invalid_share;
    }

    const throttle_phrases = [_][]const u8{ "too many", "rate limit", "ratelimit", "slow down", "throttl", "retry later" };
    for (throttle_phrases) |phrase| {
        if (contains(text, phrase)) return .throttled;
    }

    const full_phrases = [_][]const u8{ "full", "no slots", "busy" };
    for (full_phrases) |phrase| {
        if (contains(text, phrase)) return .full;
    }

    const credential_phrases = [_][]const u8{
        "invalid login", "invalid address", "invalid user", "invalid wallet", "unauthenticated",
        "unauthorized", "unauthorised", "wrong password", "bad login",
    };
    for (credential_phrases) |phrase| {
        if (contains(text, phrase)) return .credentials;
    }

    return .none;
}

pub const ConnectError = error{
    ConnectFailed,
    TlsInitFailed,
    NoCertificateBundle,
    OutOfMemory,
};

pub const Connection = struct {
    allocator: std.mem.Allocator,
    conn: *transport.Conn,
    buf: [64 * 1024]u8 = undefined,
    start: usize = 0,
    end: usize = 0,
    /// Lines thrown away because they were longer than the buffer. A pool (or
    /// a proxy that injects HTML into the stream) can emit one; dropping the
    /// connection over it would lose a good session.
    skipped: usize = 0,

    const Self = @This();

    pub fn open(allocator: std.mem.Allocator, pool: *const options.Pool, logger: *log.Logger) ConnectError!*Self {
        const target = transport.Target{
            .kind = pool.transport,
            .host = pool.host,
            .port = pool.port,
            .path = pool.ws_path orelse "/",
            .host_header = pool.host_header,
            .origin = pool.ws_origin,
            .connect_host = pool.connect_host,
            .connect_port = pool.connect_port,
            .tls_ca = pool.tls_ca,
            .proxy = pool.proxy(),
            .user_agent = user_agent orelse agent,
        };

        const conn = transport.Conn.open(allocator, target, logger) catch |e| {
            logger.warn("connect to {s}://{s}:{d} failed: {s}", .{ pool.transport.label(), pool.host, pool.port, @errorName(e) });

            return error.ConnectFailed;
        };

        const self = allocator.create(Self) catch return error.OutOfMemory;
        errdefer allocator.destroy(self);

        self.* = .{ .allocator = allocator, .conn = conn };

        return self;
    }

    pub fn close(self: *Self) void {
        self.conn.destroy();
    }

    pub fn destroy(self: *Self) void {
        self.close();
        self.allocator.destroy(self);
    }

    /// A read can fail for more reasons than "the pool hung up", and reporting
    /// all of them as `ConnectionClosed` is how a rig spends an afternoon on a
    /// WebSocket endpoint that is speaking nonsense: the log said the pool
    /// closed the connection, which is what a healthy pool does at shutdown.
    /// The transports that mean "closed" stay `ConnectionClosed`; the rest keep
    /// their name (and the readable message in main.zig) so the log says
    /// `WsProtocol`, `BadResponse` or `TlsHandshake` instead.
    fn readError(e: transport.Error) anyerror {
        return switch (e) {
            error.EndOfStream, error.WsClosed => error.ConnectionClosed,
            // Everything else is passed through unchanged: OutOfMemory,
            // WsProtocol, BadResponse, HandshakeFailed, TlsHandshake.
            else => e,
        };
    }

    fn fill(self: *Self) !void {
        if (self.start > 0 and self.start < self.end) {
            std.mem.copyForwards(u8, self.buf[0..], self.buf[self.start..self.end]);
            self.end -= self.start;
            self.start = 0;
        } else if (self.start >= self.end) {
            self.start = 0;
            self.end = 0;
        }

        const n = self.conn.read(self.buf[self.end..]) catch |e| return readError(e);

        if (n == 0) return error.ConnectionClosed;

        self.end += n;
    }

    /// Throws away the rest of a line that does not fit in the buffer.
    fn discardOverlong(self: *Self) !void {
        self.start = 0;
        self.end = 0;

        while (true) {
            const n = self.conn.read(self.buf[0..]) catch |e| return readError(e);

            if (n == 0) return error.ConnectionClosed;

            if (std.mem.indexOfScalar(u8, self.buf[0..n], '\n')) |offset| {
                self.start = offset + 1;
                self.end = n;

                return;
            }
        }
    }

    /// Returns one line without the trailing newline. The slice stays valid
    /// until the next call. Over-long lines are skipped instead of killing the
    /// session (see `skipped`).
    pub fn readLine(self: *Self, max_len: usize) ![]const u8 {
        while (true) {
            // Always search from `start`: fill() compacts the buffer and shifts
            // every index, so a cached scan offset would look past the data and
            // hand out the wrong bytes (that is how replies got lost before).
            if (std.mem.indexOfScalar(u8, self.buf[self.start..self.end], '\n')) |offset| {
                const pos = self.start + offset;
                var line = self.buf[self.start..pos];
                self.start = pos + 1;

                if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

                return line;
            }

            if (self.end - self.start >= max_len or self.end == self.buf.len) {
                try self.discardOverlong();
                self.skipped += 1;

                continue;
            }

            try self.fill();
        }
    }

    pub fn writeLine(self: *Self, line: []const u8) !void {
        self.conn.writeMessage(line) catch return error.ConnectionClosed;
    }

    /// File descriptor of the underlying socket, used by the silence watchdog.
    pub fn handle(self: *Self) std.posix.socket_t {
        return self.conn.stream.handle;
    }
};

fn setKeepAlive(fd: std.posix.socket_t) void {
    const on: c_int = 1;

    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.KEEPALIVE, std.mem.asBytes(&on)) catch {};
}

/// The login `params` object, built the same way every time.
///
/// Split out of `Session.login` so it can be tested without a socket: the
/// `algo` array is the difference between a rig a pool leaves on rx/0 and a rig
/// it mines the most profitable coin with, and a typo there is silent -- the pool
/// simply ignores an extension it does not understand.
pub const LoginParams = struct {
    user: []const u8,
    password: []const u8,
    agent: []const u8,
    rig_id: ?[]const u8 = null,
    algos: []const api.Algo = &.{},
};

pub fn writeLoginParams(w: anytype, params: LoginParams) !void {
    // The wallet, password and rig id are user input: escape them, or a quote in
    // a password turns the login into malformed JSON.
    try w.writeAll("{\"login\":\"");
    try util.writeJsonString(w, params.user);
    try w.writeAll("\",\"pass\":\"");
    try util.writeJsonString(w, params.password);
    try w.writeAll("\",\"agent\":\"");
    try util.writeJsonString(w, params.agent);
    try w.writeByte('"');
    if (params.rig_id) |rig| {
        try w.writeAll(",\"rigid\":\"");
        try util.writeJsonString(w, rig);
        try w.writeByte('"');
    }
    if (params.algos.len > 0) {
        try w.writeAll(",\"algo\":[");
        for (params.algos, 0..) |algo, index| {
            if (index > 0) try w.writeByte(',');
            try w.print("\"{s}\"", .{algo.label()});
        }
        try w.writeByte(']');
    }
    try w.writeAll(",\"extensions\":[\"algo\",\"keepalive\"]}");
}

/// `{"id":N,"jsonrpc":"2.0","method":"submit","params":{...}}`
pub const Session = struct {
    allocator: std.mem.Allocator,
    conn: *Connection,
    pool: options.Pool,
    next_id: u64 = 1,
    logger: *log.Logger,
    supports_algo_extension: bool = false,
    /// Why the last login attempt was refused, so the connect loop can stop
    /// retrying a bad wallet and can cool down a pool that banned us.
    last_failure: Refusal = .none,

    /// Timestamp of the last "unsupported algorithm" warning, so a pool that
    /// keeps offering a coin we do not mine cannot flood the log.
    last_algo_warn: i64 = 0,

    const Self = @This();

    pub fn open(allocator: std.mem.Allocator, pool: options.Pool, logger: *log.Logger) !Self {
        const conn = try Connection.open(allocator, &pool, logger);

        return .{ .allocator = allocator, .conn = conn, .pool = pool, .logger = logger };
    }

    pub fn close(self: *Self) void {
        self.conn.destroy();
    }

    fn allocId(self: *Self) u64 {
        const id = self.next_id;
        self.next_id += 1;

        return id;
    }

    /// Sends the login request and waits for the first job.
    ///
    /// `algos` is what the pool is told this rig can hash. Empty means "no
    /// preference" and is what a rig without `--algo` has always sent; more than
    /// one entry is `--algo=auto`, and it is the only way a pool that pays for
    /// the most profitable coin per hash can move this rig off rx/0.
    pub fn login(self: *Self, algos: []const api.Algo, out_job: *job.Job) !void {
        var params: std.ArrayListUnmanaged(u8) = .{};
        defer params.deinit(self.allocator);

        try writeLoginParams(params.writer(self.allocator), .{
            .user = self.pool.user,
            .password = self.pool.password,
            .agent = user_agent orelse agent,
            .rig_id = self.pool.rig_id,
            .algos = algos,
        });

        const line = try std.fmt.allocPrint(self.allocator, "{{\"id\":{d},\"jsonrpc\":\"2.0\",\"method\":\"login\",\"params\":{s}}}", .{ self.allocId(), params.items });
        defer self.allocator.free(line);

        try self.conn.writeLine(line);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        // The pool may push a keepalived before the login result, so loop.
        var attempts: usize = 0;
        while (attempts < 10) : (attempts += 1) {
            const text = try self.conn.readLine(64 * 1024);
            if (text.len == 0) continue;

            const message = parseMessage(arena.allocator(), text, self.logger, self.pool.nicehash) catch |e| {
                if (e == error.UnsupportedAlgo) {
                    self.logger.err("the pool wants {s}; this miner only computes RandomX (rx/*)", .{unsupportedAlgoName(text)});
                    return error.UnsupportedAlgo;
                }

                self.logger.debug("unparsable login reply ({s}): {s}", .{ @errorName(e), text });
                continue;
            };

            switch (message) {
                .reply => |reply| {
                    if (!reply.ok) {
                        const reason = reply.message orelse "unknown error";
                        self.last_failure = classify(reason);
                        self.logger.err("login rejected: {s} ({s})", .{ reason, self.last_failure.label() });
                        return error.LoginRejected;
                    }
                    if (reply.job) |pool_job| {
                        out_job.* = pool_job;
                        return;
                    }
                },
                .job => |pool_job| {
                    out_job.* = pool_job;
                    return;
                },
                .keepalive, .other => continue,
            }
        }

        return error.LoginRejected;
    }

    pub const Message = union(enum) {
        job: job.Job,
        reply: Reply,
        keepalive,
        other: []const u8,
    };

    pub const Reply = struct {
        id: u64,
        ok: bool,
        message: ?[]const u8 = null,
        job: ?job.Job = null,
    };

    pub fn next(self: *Self, arena: std.mem.Allocator, default_algo: api.Algo) !Message {
        while (true) {
            const text = try self.conn.readLine(64 * 1024);
            if (text.len == 0) continue;

            const message = parseMessage(arena, text, self.logger, self.pool.nicehash) catch |e| {
                if (e == error.UnsupportedAlgo) {
                    const now = std.time.milliTimestamp();
                    if (now - self.last_algo_warn > 60_000) {
                        self.last_algo_warn = now;
                        self.logger.warn("pool switched to {s}, which this miner cannot compute; keeping the previous job", .{unsupportedAlgoName(text)});
                    }
                    continue;
                }

                self.logger.debug("ignoring unparsable message ({s}): {s}", .{ @errorName(e), text });
                continue;
            };

            switch (message) {
                .reply => |reply| {
                    if (reply.job) |_| {
                        // A login-style reply that also carries a job.
                        return message;
                    }
                    if (reply.ok and reply.message == null) return message;
                },
                else => {},
            }

            _ = default_algo;

            return message;
        }
    }

    pub fn submit(self: *Self, job_id: []const u8, nonce: u32, hash: *const [32]u8, height: u64, algo: api.Algo) !u64 {
        const nonce_hex = try std.fmt.allocPrint(self.allocator, "{x:0>8}", .{nonce});
        defer self.allocator.free(nonce_hex);

        const hash_hex = try util.bytesToHex(self.allocator, hash);
        defer self.allocator.free(hash_hex);

        const id = self.allocId();

        var payload: std.ArrayListUnmanaged(u8) = .{};
        defer payload.deinit(self.allocator);
        const w = payload.writer(self.allocator);

        try w.print("{{\"id\":{d},\"jsonrpc\":\"2.0\",\"method\":\"submit\",\"params\":{{\"id\":\"", .{id});
        try util.writeJsonString(w, self.pool.rig_id orelse self.pool.user);
        try w.writeAll("\",\"job_id\":\"");
        try util.writeJsonString(w, job_id);
        try w.print("\",\"nonce\":\"{s}\",\"result\":\"{s}\",\"algo\":\"{s}\",\"height\":{d}}}}}", .{ nonce_hex, hash_hex, algo.label(), height });

        try self.conn.writeLine(payload.items);

        return id;
    }

    pub fn keepalive(self: *Self) !void {
        var payload: std.ArrayListUnmanaged(u8) = .{};
        defer payload.deinit(self.allocator);
        const w = payload.writer(self.allocator);

        try w.print("{{\"id\":{d},\"jsonrpc\":\"2.0\",\"method\":\"keepalived\",\"params\":{{\"id\":\"", .{self.allocId()});
        try util.writeJsonString(w, self.pool.rig_id orelse self.pool.user);
        try w.writeAll("\"}}");

        try self.conn.writeLine(payload.items);
    }
};

/// Pulls the algorithm name out of a job message for the log line. Returns
/// "that algorithm" when the message is shaped differently than expected.
fn unsupportedAlgoName(text: []const u8) []const u8 {
    const key = "\"algo\"";
    const at = std.mem.indexOf(u8, text, key) orelse return "that algorithm";
    const after = text[at + key.len ..];

    // Pools emit both `"algo":"cn/1"` and `"algo": "cn/1"`.
    const colon = std.mem.indexOfScalar(u8, after, ':') orelse return "that algorithm";
    const open = std.mem.indexOfScalar(u8, after[colon + 1 ..], '"') orelse return "that algorithm";
    const rest = after[colon + 1 + open + 1 ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return "that algorithm";

    return rest[0..end];
}

fn parseJobObject(obj: std.json.ObjectMap, default_algo: api.Algo, pool_nicehash: bool) !job.Job {
    var result = job.Job.init();
    result.setAlgo(default_algo);
    result.nicehash = pool_nicehash;

    if (obj.get("algo")) |algo_value| {
        if (algo_value == .string) {
            // Never fall back to rx/0 for a job the pool labelled differently:
            // every hash of a CryptoNight blob would be rejected and the user
            // would see a wall of "rejected" with no reason.
            const algo = api.Algo.fromName(algo_value.string) orelse return error.UnsupportedAlgo;
            result.setAlgo(algo);
        }
    }

    const blob_value = obj.get("blob") orelse return error.MissingBlob;
    if (blob_value != .string) return error.MissingBlob;
    try result.setBlob(blob_value.string);
    // Same auto-detection as XMRig: a blob that already has a nonce means the
    // pool owns the top byte of it.
    result.detectNicehash();

    const target_value = obj.get("target") orelse return error.MissingTarget;
    if (target_value != .string) return error.MissingTarget;
    try result.setTarget(target_value.string);

    if (obj.get("job_id")) |id_value| {
        if (id_value == .string) result.setId(id_value.string);
    }

    if (obj.get("height")) |height_value| {
        if (height_value == .integer) result.height = @intCast(@max(height_value.integer, 0));
    }

    if (obj.get("seed_hash")) |seed_value| {
        if (seed_value == .string) {
            result.setSeed(seed_value.string) catch return error.InvalidSeed;
        }
    }

    if (obj.get("next_seed_hash")) |seed_value| {
        if (seed_value == .string) {
            result.setNextSeed(seed_value.string) catch return error.InvalidSeed;
        }
    }

    if (result.blob_len <= result.nonce_offset + result.nonce_size) return error.ShortBlob;

    return result;
}

fn parseMessage(arena: std.mem.Allocator, text: []const u8, logger: *log.Logger, pool_nicehash: bool) !Session.Message {
    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    _ = &parsed;

    const root = switch (parsed) {
        .object => |obj| obj,
        else => return error.NotAnObject,
    };

    if (root.get("method")) |method_value| {
        if (method_value == .string) {
            const method = method_value.string;

            if (std.mem.eql(u8, method, "job")) {
                const params = root.get("params") orelse return error.MissingParams;
                if (params != .object) return error.MissingParams;

                const default_algo = if (root.get("algo")) |a| blk: {
                    if (a == .string) {
                        if (api.Algo.fromName(a.string)) |algo| break :blk algo;
                    }
                    break :blk api.Algo.rx_0;
                } else api.Algo.rx_0;

                return .{ .job = try parseJobObject(params.object, default_algo, pool_nicehash) };
            }

            if (std.mem.eql(u8, method, "keepalived")) return .keepalive;

            logger.debug("pool sent method {s}", .{method});

            return .{ .other = try arena.dupe(u8, method) };
        }
    }

    // Reply to one of our requests.
    var reply = Session.Reply{ .id = 0, .ok = true };

    if (root.get("id")) |id_value| {
        reply.id = switch (id_value) {
            .integer => |v| @intCast(@max(v, 0)),
            .string => |v| std.fmt.parseInt(u64, v, 10) catch 0,
            else => 0,
        };
    }

    if (root.get("error")) |error_value| {
        if (error_value != .null) {
            reply.ok = false;
            reply.message = switch (error_value) {
                .object => |obj| blk: {
                    if (obj.get("message")) |m| {
                        if (m == .string) break :blk try arena.dupe(u8, m.string);
                    }
                    break :blk try arena.dupe(u8, "unknown pool error");
                },
                .string => |s| try arena.dupe(u8, s),
                else => try arena.dupe(u8, "unknown pool error"),
            };
        }
    }

    if (root.get("result")) |result_value| {
        if (result_value == .object) {
            const result = result_value.object;

            if (result.get("status")) |status| {
                if (status == .string and !std.mem.eql(u8, status.string, "OK") and !std.mem.eql(u8, status.string, "KEEPALIVED")) {
                    reply.ok = false;
                    if (reply.message == null) reply.message = try arena.dupe(u8, status.string);
                }
            }

            if (result.get("job")) |job_value| {
                if (job_value == .object) {
                    // A malformed job is ignored (the pool may send a partial
                    // one), but an algorithm we cannot compute is fatal: mining
                    // rx/0 over a CryptoNight blob only produces rejects.
                    reply.job = parseJobObject(job_value.object, api.Algo.rx_0, pool_nicehash) catch |e| switch (e) {
                        error.UnsupportedAlgo => return error.UnsupportedAlgo,
                        else => null,
                    };
                }
            }
        }
    }

    return .{ .reply = reply };
}

test "a login reply carries the first job, the id and the session id" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var logger = log.Logger.init(false, false);

    const text =
        \\{"id":1,"jsonrpc":"2.0","error":null,"result":{"id":"session-1","job":{
        \\ "blob":"01010101010101010101010101010101010101010101010101010101010101010101010101010100000000020202020202020202020202020202020202020202020202020202020202020202",
        \\ "job_id":"job-7","target":"3b0a0000","height":3000000,"algo":"rx/0","seed_hash":"abababababababababababababababababababababababababababababababab"}}}
    ;

    const message = try parseMessage(arena.allocator(), text, &logger, false);
    try testing.expectEqual(@as(?u64, 1), message.reply.id);
    try testing.expect(message.reply.ok);
    try testing.expectEqualStrings("job-7", message.reply.job.?.idSlice());
    try testing.expectEqual(@as(u64, 3000000), message.reply.job.?.height);
}

test "the login advertises nothing, one algorithm, or the whole family" {
    const testing = std.testing;

    // No -a: unchanged behaviour for every existing rig. The pool decides.
    {
        var buf: [512]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        try writeLoginParams(stream.writer(), .{ .user = "W", .password = "x", .agent = "zmrig/test" });
        const text = stream.getWritten();

        // No `"algo":[...]` array; the word still appears in `extensions`.
        try testing.expect(std.mem.indexOf(u8, text, "\"algo\":[") == null);
        try testing.expect(std.mem.indexOf(u8, text, "\"extensions\":[\"algo\",\"keepalive\"]") != null);
        try testing.expect(std.mem.endsWith(u8, text, "}"));
    }

    // -a rx/0: one entry, exactly as before (pools that only accept a list still work).
    {
        var buf: [512]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        try writeLoginParams(stream.writer(), .{
            .user = "W",
            .password = "x",
            .agent = "zmrig/test",
            .algos = &.{.rx_0},
        });
        const text = stream.getWritten();

        try testing.expect(std.mem.indexOf(u8, text, "\"algo\":[\"rx/0\"]") != null);
    }

    // --algo=auto: the full list, comma separated, every label a pool knows.
    {
        var buf: [512]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        try writeLoginParams(stream.writer(), .{
            .user = "W",
            .password = "x",
            .agent = "zmrig/test",
            .algos = &api.auto_algos,
        });
        const text = stream.getWritten();

        try testing.expect(std.mem.indexOf(u8, text, "\"algo\":[\"rx/0\",\"rx/wow\",\"rx/arq\",\"rx/graft\",\"rx/sfx\",\"rx/yada\",\"panthera\"]") != null);
        // No trailing comma, and the JSON still closes: a pool that rejects a
        // malformed login closes the socket and the rig mines nothing.
        try testing.expect(std.mem.indexOf(u8, text, ",]") == null);
        try testing.expect(std.mem.endsWith(u8, text, "}"));
    }
}

test "a quote in a password cannot break the login JSON" {
    const testing = std.testing;

    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeLoginParams(stream.writer(), .{ .user = "W", .password = "a\"b\\c", .agent = "zmrig/test" });

    const text = try testing.allocator.dupe(u8, stream.getWritten());
    defer testing.allocator.free(text);

    // Must still parse, and the password must come back byte for byte.
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer parsed.deinit();

    try testing.expectEqualStrings("a\"b\\c", parsed.value.object.get("pass").?.string);
}

test "pool errors are reported, not swallowed" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var logger = log.Logger.init(false, false);

    const object_error =
        \\{"id":3,"jsonrpc":"2.0","error":{"code":-1,"message":"Invalid address used for login"}}
    ;
    const m1 = try parseMessage(arena.allocator(), object_error, &logger, false);
    try testing.expect(!m1.reply.ok);
    try testing.expectEqualStrings("Invalid address used for login", m1.reply.message.?);

    // Some pools put the failure in result.status with a 200-style reply.
    const status_error = "{\"id\":4,\"error\":null,\"result\":{\"status\":\"Invalid payment ID\"}}";
    const m2 = try parseMessage(arena.allocator(), status_error, &logger, false);
    try testing.expect(!m2.reply.ok);
    try testing.expectEqualStrings("Invalid payment ID", m2.reply.message.?);

    // A null error and an OK status is a success (submit accepted).
    const ok = "{\"id\":5,\"error\":null,\"result\":{\"status\":\"OK\"}}";
    const m3 = try parseMessage(arena.allocator(), ok, &logger, false);
    try testing.expect(m3.reply.ok);
}

test "keepalived and unknown methods do not look like jobs" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var logger = log.Logger.init(false, false);

    const keepalive = try parseMessage(arena.allocator(), "{\"method\":\"keepalived\"}", &logger, false);
    try testing.expect(keepalive == .keepalive);

    const other = try parseMessage(arena.allocator(), "{\"method\":\"client.get_version\",\"params\":{}}", &logger, false);
    try testing.expectEqualStrings("client.get_version", other.other);

    try testing.expectError(error.NotAnObject, parseMessage(arena.allocator(), "[]", &logger, false));
}

test "a job with a non-zero nonce switches the nonce mask on" {
    const testing = std.testing;

    const obj_text =
        \\{"blob":"010101010101010101010101010101010101010101010101010101010101010101010101010101aabbccdd020202020202020202020202020202020202020202020202020202020202020202",
        \\ "job_id":"j","target":"3b0a0000","height":1,"seed_hash":"abababababababababababababababababababababababababababababababab"}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, obj_text, .{});
    defer parsed.deinit();

    const job_value = try parseJobObject(parsed.value.object, api.Algo.rx_0, false);
    // The blob carries extranonce bytes; mining must not overwrite them.
    try testing.expect(job_value.nicehash);
    try testing.expectEqual(@as(u32, 0x00FFFFFF), job_value.nonceMask());
}

test "a job for a coin we cannot mine is refused, not mined as rx/0" {
    const testing = std.testing;

    const obj_text =
        \\{"blob":"010101010101010101010101010101010101010101010101010101010101010101010101010101000000000202020202020202020202020202020202020202020202020202020202020202",
        \\ "job_id":"j","target":"3b0a0000","height":1,"algo":"cn/1","seed_hash":"abababababababababababababababababababababababababababababababab"}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, obj_text, .{});
    defer parsed.deinit();

    try testing.expectError(error.UnsupportedAlgo, parseJobObject(parsed.value.object, api.Algo.rx_0, false));

    // The name still reaches the log line.
    try testing.expectEqualStrings("cn/1", unsupportedAlgoName(obj_text));
    try testing.expectEqualStrings("that algorithm", unsupportedAlgoName("{\"method\":\"job\"}"));
}

test "the unsupported algorithm name is read with or without spaces" {
    const testing = std.testing;

    try testing.expectEqualStrings("cn/1", unsupportedAlgoName("{\"algo\":\"cn/1\"}"));
    try testing.expectEqualStrings("cn/1", unsupportedAlgoName("{\"height\": 1, \"algo\": \"cn/1\", \"job_id\": \"j\"}"));
    try testing.expectEqualStrings("that algorithm", unsupportedAlgoName("{\"job_id\":\"j\"}"));
}

test "a pool's refusal is classified, because retrying a ban is how it grows" {
    const testing = std.testing;

    // Bans come in many spellings; every one of them must stop the retry loop.
    try testing.expectEqual(Refusal.banned, classify("your IP is banned"));
    try testing.expectEqual(Refusal.banned, classify("BANNED: too many bad shares"));
    try testing.expectEqual(Refusal.banned, classify("IP blocked"));
    try testing.expectEqual(Refusal.banned, classify("access denied"));

    // Invalid shares are the pool warning about the hardware.
    try testing.expectEqual(Refusal.invalid_share, classify("Low difficulty share"));
    try testing.expectEqual(Refusal.invalid_share, classify("invalid share"));
    try testing.expectEqual(Refusal.invalid_share, classify("Invalid result"));

    // "invalid" alone is not a credential problem: the order matters.
    try testing.expectEqual(Refusal.credentials, classify("invalid address"));
    try testing.expectEqual(Refusal.credentials, classify("Unauthenticated"));
    try testing.expectEqual(Refusal.credentials, classify("wrong password"));

    try testing.expectEqual(Refusal.throttled, classify("too many connections"));
    try testing.expectEqual(Refusal.throttled, classify("rate limited"));
    try testing.expectEqual(Refusal.full, classify("pool is full"));

    // Anything unrecognised keeps the old exponential-backoff behaviour.
    try testing.expectEqual(Refusal.none, classify("unknown error"));
    try testing.expectEqual(Refusal.none, classify(""));
}

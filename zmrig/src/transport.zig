//! Transports for the stratum client.
//!
//! A pool is not always reachable over a plain TCP socket: many "picky" VPS
//! providers only allow outbound 443 (and sometimes only HTTP over it), and a
//! pool may hide behind Cloudflare. This module gives the stratum code one
//! byte stream regardless of how it is carried:
//!
//!   tcp   plain stratum, the classic pool port
//!   tls   stratum inside TLS (works on 443 when 3333 is filtered)
//!   ws    stratum inside WebSocket frames (HTTP/1.1 upgrade)
//!   wss   WebSocket inside TLS - what a Cloudflare-proxied endpoint speaks
//!
//! Optional layers: an HTTP CONNECT or SOCKS5 proxy in front of the TCP
//! connection, a `--connect-to` override (force an edge IP), a custom CA file
//! (pin a self-signed origin) and a custom Host header / SNI.
//!
//! Everything here is written against Zig's std only: no OpenSSL, no libuv.

const std = @import("std");

pub const Kind = enum {
    tcp,
    tls,
    ws,
    wss,

    pub fn fromName(name: []const u8) ?Kind {
        if (std.mem.eql(u8, name, "tcp") or std.mem.eql(u8, name, "plain")) return .tcp;
        if (std.mem.eql(u8, name, "tls") or std.mem.eql(u8, name, "ssl")) return .tls;
        if (std.mem.eql(u8, name, "ws") or std.mem.eql(u8, name, "websocket")) return .ws;
        if (std.mem.eql(u8, name, "wss") or std.mem.eql(u8, name, "websockets")) return .wss;

        return null;
    }

    pub fn label(self: Kind) []const u8 {
        return @tagName(self);
    }

    pub fn usesTls(self: Kind) bool {
        return self == .tls or self == .wss;
    }

    pub fn usesWs(self: Kind) bool {
        return self == .ws or self == .wss;
    }

    /// Default port when the URL does not carry one.
    pub fn defaultPort(self: Kind) u16 {
        return switch (self) {
            .tcp => 3333,
            .tls => 443,
            .ws => 80,
            .wss => 443,
        };
    }
};

pub const ProxyKind = enum { none, http, socks5 };

pub const Proxy = struct {
    kind: ProxyKind = .none,
    host: []const u8 = "",
    port: u16 = 0,
    user: ?[]const u8 = null,
    pass: ?[]const u8 = null,

    pub fn isSet(self: Proxy) bool {
        return self.kind != .none;
    }
};

pub const Error = error{
    ConnectFailed,
    ConnectTimeout,
    ProxyRefused,
    ProxyFailed,
    TlsInitFailed,
    TlsHandshake,
    NoCertificateBundle,
    HandshakeFailed,
    BadResponse,
    WsClosed,
    WsProtocol,
    OutOfMemory,
    EndOfStream,
};

/// Everything a connection needs, flattened from the pool + CLI options.
pub const Target = struct {
    kind: Kind,
    host: []const u8, // used for DNS, SNI and the Host header
    port: u16,
    path: []const u8 = "/",
    host_header: ?[]const u8 = null,
    origin: ?[]const u8 = null,
    connect_host: ?[]const u8 = null,
    connect_port: ?u16 = null,
    tls_ca: ?[]const u8 = null,
    proxy: Proxy = .{},
    connect_timeout_ms: u32 = 10_000,
    user_agent: []const u8 = "zmrig",
};

const max_http_header = 16 * 1024;
const ws_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const Conn = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    tls: ?std.crypto.tls.Client = null,
    bundle: ?std.crypto.Certificate.Bundle = null,
    kind: Kind = .tcp,
    /// Bytes read while parsing the HTTP upgrade response that belong to the
    /// WebSocket stream already.
    pre: []u8 = &.{},
    pre_pos: usize = 0,
    // --- WebSocket frame state ---
    ws_mask: [4]u8 = .{ 0, 0, 0, 0 },
    ws_masked: bool = false,
    ws_mask_pos: usize = 0,
    ws_remaining: u64 = 0, // payload bytes left in the current frame
    ws_opcode: u8 = 0,
    ws_message_last_byte: u8 = 0,
    ws_message_bytes: u64 = 0,
    ws_pending_newline: bool = false,

    const Self = @This();

    pub fn open(allocator: std.mem.Allocator, target: Target, logger: *@import("log.zig").Logger) Error!*Self {
        const self = allocator.create(Self) catch return error.OutOfMemory;
        errdefer allocator.destroy(self);

        const dial_host = target.connect_host orelse target.host;
        const dial_port = target.connect_port orelse target.port;

        self.* = .{
            .allocator = allocator,
            .stream = undefined,
            .kind = target.kind,
        };

        // 1. TCP, directly or through a proxy.
        self.stream = if (target.proxy.isSet())
            connectThroughProxy(allocator, target.proxy, dial_host, dial_port, target.connect_timeout_ms, logger) catch |e| {
                return e;
            }
        else
            connectDirect(allocator, dial_host, dial_port, target.connect_timeout_ms, logger) catch |e| {
                return e;
            };

        errdefer self.stream.close();

        setSocketOptions(self.stream.handle);

        // The TLS and WebSocket handshakes block on the socket, so give them a
        // deadline. It is removed right before `open` returns so mining reads
        // stay blocking and the silence watchdog keeps its job.
        setIoTimeout(self.stream, handshake_timeout_s);

        // 2. TLS.
        if (target.kind.usesTls()) {
            var bundle = std.crypto.Certificate.Bundle{};

            if (target.tls_ca) |path| {
                bundle.addCertsFromFilePathAbsolute(allocator, path) catch |e| {
                    logger.warn("cannot load the CA file {s}: {s}", .{ path, @errorName(e) });
                    return error.NoCertificateBundle;
                };
                logger.debug("trusting the certificates from {s}", .{path});
            } else {
                bundle.rescan(allocator) catch {
                    logger.warn("cannot load the system certificate bundle, TLS will fail", .{});
                    return error.NoCertificateBundle;
                };
            }

            self.bundle = bundle;

            // SNI and certificate verification always use the pool host name:
            // `--connect-to`/`--host-header` only change where the bytes go,
            // never which certificate is expected (that is the whole point of
            // dialling a specific Cloudflare edge IP).
            const sni = target.host;
            errdefer bundle.deinit(allocator);

            self.tls = std.crypto.tls.Client.init(self.stream, bundle, sni) catch |e| {
                logger.warn("TLS handshake with {s} failed: {s}", .{ sni, @errorName(e) });
                return error.TlsHandshake;
            };
        }

        // 3. WebSocket upgrade.
        if (target.kind.usesWs()) {
            self.websocketHandshake(target, logger) catch |e| return e;
        }

        // A write to a wedged socket must not block a worker forever: joining
        // the threads during a seed change would then never finish.
        //
        // Reads use a one second timeout so the read loop can notice a signal
        // (`stop_requested`). TLS keeps a fully blocking read: `std.crypto.tls`
        // reconstructs records across calls and must not be interrupted in the
        // middle of one; the monitor's shutdown() is what unblocks it there.
        setIoTimeout(self.stream, if (target.kind.usesTls()) 0 else 1);
        setSendTimeout(self.stream, send_timeout_s);

        return self;
    }

    pub fn close(self: *Self) void {
        if (self.tls) |*tls| tls.writeAllEnd(self.stream, "", true) catch {};
        self.stream.close();
        if (self.bundle) |*bundle| bundle.deinit(self.allocator);
    }

    pub fn destroy(self: *Self) void {
        self.close();
        if (self.pre.len != 0) self.allocator.free(self.pre);
        self.allocator.destroy(self);
    }

    /// Reads up to out.len bytes of *payload* (WebSocket aware).
    pub fn read(self: *Self, out: []u8) Error!usize {
        if (!self.kind.usesWs()) return self.readRaw(out);

        while (true) {
            if (self.ws_pending_newline) {
                self.ws_pending_newline = false;
                out[0] = '\n';

                return 1;
            }

            if (self.ws_remaining == 0) {
                self.readFrameHeader() catch |e| return e;

                continue;
            }

            const want: usize = @intCast(@min(out.len, self.ws_remaining));
            const n = try self.readRaw(out[0..want]);
            if (n == 0) return error.EndOfStream;

            if (self.ws_masked) {
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    out[i] ^= self.ws_mask[self.ws_mask_pos & 3];
                    self.ws_mask_pos += 1;
                }
            }

            self.ws_remaining -= n;
            self.ws_message_last_byte = out[n - 1];
            self.ws_message_bytes += n;

            if (self.ws_remaining == 0 and (self.ws_opcode & 0x80) != 0) {
                // Final frame of the message: make sure the stratum reader sees
                // a line terminator even though WS frames carry bare JSON.
                if (self.ws_message_last_byte != '\n' and self.ws_message_bytes != 0) {
                    self.ws_pending_newline = true;
                }
                self.ws_message_bytes = 0;
            }

            return n;
        }
    }

    /// Writes one stratum message. Over WebSocket it becomes a single text
    /// frame (without the trailing newline, which is a line protocol detail).
    pub fn writeMessage(self: *Self, payload: []const u8) Error!void {
        if (!self.kind.usesWs()) {
            try self.writeRaw(payload);
            try self.writeRaw("\n");

            return;
        }

        try self.writeFrame(0x1, payload);
    }

    pub fn writeRaw(self: *Self, data: []const u8) Error!void {
        if (self.tls) |*tls| {
            tls.writeAll(self.stream, data) catch return error.HandshakeFailed;

            return;
        }

        self.stream.writeAll(data) catch return error.EndOfStream;
    }

    fn readRaw(self: *Self, out: []u8) Error!usize {
        if (out.len == 0) return 0;

        if (self.pre_pos < self.pre.len) {
            const n = @min(out.len, self.pre.len - self.pre_pos);
            @memcpy(out[0..n], self.pre[self.pre_pos..][0..n]);
            self.pre_pos += n;

            return n;
        }

        if (self.tls) |*tls| {
            const n = tls.read(self.stream, out) catch |e| switch (e) {
                error.WouldBlock => return 0,
                else => return error.EndOfStream,
            };

            return n;
        }

        // Plain TCP (and WebSocket over it): retry on the receive timeout so a
        // `kill` is honoured even while the pool is silent.
        while (true) {
            if (stop_requested.load(.acquire)) return error.EndOfStream;

            const n = self.stream.read(out) catch |e| switch (e) {
                error.WouldBlock => continue,
                else => return error.EndOfStream,
            };

            return n;
        }
    }

    fn readExact(self: *Self, out: []u8) Error!void {
        var filled: usize = 0;

        while (filled < out.len) {
            const n = try self.readRaw(out[filled..]);
            if (n == 0) return error.EndOfStream;

            filled += n;
        }
    }

    // ------------------------------------------------------------------
    // WebSocket
    // ------------------------------------------------------------------

    fn websocketHandshake(self: *Self, target: Target, logger: *@import("log.zig").Logger) Error!void {
        var key_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&key_bytes);

        var key_b64: [std.base64.standard.Encoder.calcSize(16)]u8 = undefined;
        const key = std.base64.standard.Encoder.encode(&key_b64, &key_bytes);

        var owned_host: ?[]u8 = null;
        defer if (owned_host) |owned| self.allocator.free(owned);

        const host_header = target.host_header orelse blk: {
            if (target.port == target.kind.defaultPort()) break :blk target.host;

            const text = std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ target.host, target.port }) catch return error.OutOfMemory;
            owned_host = text;

            break :blk @as([]const u8, text);
        };

        var request_buffer: [1024]u8 = undefined;
        var stream = std.io.fixedBufferStream(&request_buffer);
        const w = stream.writer();

        w.print("GET {s} HTTP/1.1\r\n", .{target.path}) catch return error.HandshakeFailed;
        w.print("Host: {s}\r\n", .{host_header}) catch return error.HandshakeFailed;
        w.writeAll("Upgrade: websocket\r\nConnection: Upgrade\r\n") catch return error.HandshakeFailed;
        w.print("Sec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n", .{key}) catch return error.HandshakeFailed;
        w.print("User-Agent: {s}\r\n", .{target.user_agent}) catch return error.HandshakeFailed;
        if (target.origin) |origin| {
            w.print("Origin: {s}\r\n", .{origin}) catch return error.HandshakeFailed;
        }
        w.writeAll("\r\n") catch return error.HandshakeFailed;

        logger.debug("websocket upgrade: GET {s} (Host: {s})", .{ target.path, host_header });

        try self.writeRaw(stream.getWritten());

        // Read the response head. Anything after \r\n\r\n is WebSocket data.
        var head: [max_http_header]u8 = undefined;
        var head_len: usize = 0;
        var scratch: [512]u8 = undefined;

        while (std.mem.indexOf(u8, head[0..head_len], "\r\n\r\n") == null) {
            if (head_len == head.len) return error.BadResponse;

            const n = try self.readRaw(&scratch);
            if (n == 0) return error.EndOfStream;

            const copy = @min(n, head.len - head_len);
            @memcpy(head[head_len..][0..copy], scratch[0..copy]);
            head_len += copy;

            if (copy < n and self.pre.len == 0) {
                // Keep the overflow; it is already WebSocket traffic.
                self.pre = self.allocator.dupe(u8, scratch[copy..n]) catch return error.OutOfMemory;
            }
        }

        const header_text = head[0..head_len];
        const head_end = std.mem.indexOf(u8, header_text, "\r\n\r\n").? + 4;
        const rest = header_text[head_end..];

        if (rest.len != 0 and self.pre.len == 0) {
            self.pre = self.allocator.dupe(u8, rest) catch return error.OutOfMemory;
        }
        self.pre_pos = 0;

        // Status line.
        const line_end = std.mem.indexOf(u8, header_text, "\r\n") orelse return error.BadResponse;
        const status_line = header_text[0..line_end];

        const status = parseStatus(status_line) orelse return error.BadResponse;

        if (status == 101) {
            var accept_buf: [28]u8 = undefined;
            const accept_expected = computeAccept(key, &accept_buf) catch return error.HandshakeFailed;

            if (headerValue(header_text, "sec-websocket-accept")) |accept| {
                if (!std.mem.eql(u8, std.mem.trim(u8, accept, " \t"), accept_expected)) {
                    logger.warn("websocket accept mismatch, continuing anyway (some proxies rewrite it)", .{});
                }
            }

            logger.debug("websocket established", .{});

            return;
        }

        // Redirects are common when Cloudflare forces https; follow one.
        if (status == 301 or status == 302 or status == 307 or status == 308) {
            logger.warn("websocket endpoint answered {d}; check the scheme (use wss://) and the path", .{status});

            return error.HandshakeFailed;
        }

        logger.warn("websocket upgrade failed: {s}", .{std.mem.trim(u8, status_line, "\r\n")});
        if (rest.len != 0) logger.debug("endpoint body: {s}", .{std.mem.trim(u8, rest[0..@min(rest.len, 300)], "\r\n")});

        return error.HandshakeFailed;
    }

    /// RFC 6455 5.5 says a control frame is never fragmented and never carries
    /// more than 125 bytes. A peer that says otherwise is not speaking the
    /// protocol, and best-effort handling is what turns one bad frame into a
    /// dead rig: the ping branch answers with at most 125 bytes and then clears
    /// `ws_remaining`, so the rest of a long ping stays in the socket and is
    /// read as the header of the next frame. That is a desynchronised stream,
    /// a bogus length, and a connection that hangs instead of reconnecting.
    fn checkFrame(fin: bool, opcode: u8, length: u64) Error!void {
        if (opcode & 0x08 == 0) return; // data frame: any length, any fragmentation
        if (!fin or length > 125) return error.WsProtocol;
    }

    fn readFrameHeader(self: *Self) Error!void {
        var header: [2]u8 = undefined;
        try self.readExact(&header);

        const fin = (header[0] & 0x80) != 0;
        const opcode = header[0] & 0x0F;
        const masked = (header[1] & 0x80) != 0;
        var length: u64 = header[1] & 0x7F;

        if (length == 126) {
            var ext: [2]u8 = undefined;
            try self.readExact(&ext);
            length = std.mem.readInt(u16, &ext, .big);
        } else if (length == 127) {
            var ext: [8]u8 = undefined;
            try self.readExact(&ext);
            length = std.mem.readInt(u64, &ext, .big);
        }

        try checkFrame(fin, opcode, length);

        if (masked) {
            try self.readExact(&self.ws_mask);
            self.ws_mask_pos = 0;
        }
        self.ws_masked = masked;
        self.ws_remaining = length;

        switch (opcode) {
            0x0, 0x1, 0x2 => {
                // Data frame (continuation, text, binary).
                self.ws_opcode = opcode | (if (fin) @as(u8, 0x80) else 0);

                if (length == 0 and fin) {
                    // Empty final frame: nothing to hand out, keep reading.
                    self.ws_opcode = 0;
                }
            },
            0x8 => return error.WsClosed,
            0x9 => {
                // Ping: echo it back as a pong and carry on.
                var payload: [125]u8 = undefined;
                const n: usize = @intCast(@min(length, payload.len));
                try self.readExact(payload[0..n]);
                if (masked) {
                    var i: usize = 0;
                    while (i < n) : (i += 1) payload[i] ^= self.ws_mask[i & 3];
                }
                self.ws_remaining = 0;
                try self.writeFrame(0xA, payload[0..n]);
            },
            0xA => {
                // Unsolicited pong: drain and carry on.
                var payload: [125]u8 = undefined;
                const n: usize = @intCast(@min(length, payload.len));
                try self.readExact(payload[0..n]);
                self.ws_remaining = 0;
            },
            else => return error.WsProtocol,
        }
    }

    fn writeFrame(self: *Self, opcode: u8, payload: []const u8) Error!void {
        var header: [14]u8 = undefined;
        var header_len: usize = 0;

        header[0] = 0x80 | (opcode & 0x0F); // FIN + opcode
        header_len = 1;

        if (payload.len < 126) {
            header[1] = 0x80 | @as(u8, @intCast(payload.len));
            header_len = 2;
        } else if (payload.len <= 0xFFFF) {
            header[1] = 0x80 | 126;
            std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .big);
            header_len = 4;
        } else {
            header[1] = 0x80 | 127;
            std.mem.writeInt(u64, header[2..10], payload.len, .big);
            header_len = 10;
        }

        var mask: [4]u8 = undefined;
        std.crypto.random.bytes(&mask);
        @memcpy(header[header_len..][0..4], &mask);
        header_len += 4;

        try self.writeRaw(header[0..header_len]);

        if (payload.len == 0) return;

        var buffer: [2048]u8 = undefined;
        var offset: usize = 0;

        while (offset < payload.len) {
            const chunk = @min(buffer.len, payload.len - offset);
            var i: usize = 0;
            while (i < chunk) : (i += 1) {
                buffer[i] = payload[offset + i] ^ mask[(offset + i) & 3];
            }

            try self.writeRaw(buffer[0..chunk]);
            offset += chunk;
        }
    }
};

fn parseStatus(line: []const u8) ?u16 {
    var parts = std.mem.tokenizeScalar(u8, line, ' ');
    _ = parts.next() orelse return null; // HTTP/1.1

    const code = parts.next() orelse return null;

    return std.fmt.parseInt(u16, code, 10) catch null;
}

fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next();

    while (lines.next()) |line| {
        if (line.len == 0) break;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");

        if (std.ascii.eqlIgnoreCase(key, name)) {
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
    }

    return null;
}

fn computeAccept(key: []const u8, out: *[28]u8) ![]const u8 {
    var sha: [20]u8 = undefined;
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(key);
    hasher.update(ws_guid);
    hasher.final(&sha);

    return std.base64.standard.Encoder.encode(out, &sha);
}

// ----------------------------------------------------------------------
// sockets
// ----------------------------------------------------------------------

fn setSocketOptions(fd: std.posix.socket_t) void {
    const on: c_int = 1;

    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.KEEPALIVE, std.mem.asBytes(&on)) catch {};
    // Shares are latency sensitive and stratum messages are tiny; Nagle would
    // add up to 40 ms to every submit.
    std.posix.setsockopt(fd, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, std.mem.asBytes(&on)) catch {};
}

fn connectDirect(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    timeout_ms: u32,
    logger: *@import("log.zig").Logger,
) Error!std.net.Stream {
    // Literal addresses skip DNS (and let --connect-to force a Cloudflare edge).
    if (std.net.Address.parseIp(host, port)) |address| {
        return connectAddress(address, timeout_ms);
    } else |_| {}

    const list = std.net.getAddressList(allocator, host, port) catch |e| {
        logger.warn("cannot resolve {s}: {s}", .{ host, @errorName(e) });

        return error.ConnectFailed;
    };
    defer list.deinit();

    var last_error: Error = error.ConnectFailed;

    for (list.addrs) |address| {
        if (connectAddress(address, timeout_ms)) |stream| {
            return stream;
        } else |e| {
            last_error = e;
        }
    }

    return last_error;
}

fn connectAddress(address: std.net.Address, timeout_ms: u32) Error!std.net.Stream {
    const fd = std.posix.socket(address.any.family, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK, 0) catch
        return error.ConnectFailed;
    errdefer std.posix.close(fd);

    std.posix.connect(fd, &address.any, address.getOsSockLen()) catch |e| switch (e) {
        error.WouldBlock => {
            var poll_fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};

            const ready = std.posix.poll(&poll_fds, @intCast(timeout_ms)) catch return error.ConnectFailed;
            if (ready == 0) return error.ConnectTimeout;

            // SO_ERROR reports the asynchronous connect() result; a pending
            // ECONNREFUSED/ETIMEDOUT surfaces here instead of on the first read.
            std.posix.getsockoptError(fd) catch return error.ConnectFailed;
        },
        else => return error.ConnectFailed,
    };

    // Back to blocking mode for the rest of the connection (the TCP layer uses
    // its own timeout through poll(), the TLS and stratum layers block).
    // Clear O_NONBLOCK so the TLS and stratum layers can block normally. A
    // socket has no other status flag worth preserving, so 0 is the whole set.
    _ = std.posix.fcntl(fd, std.posix.F.SETFL, 0) catch return error.ConnectFailed;

    return .{ .handle = fd };
}

/// Deadline for the proxy handshake and the WebSocket upgrade. Without it a
/// half-open proxy leaves the miner parked in read() forever.
/// Set by the signal handler (see main.zig). A blocked read notices it within
/// a second instead of parking until the pool decides to speak, so Ctrl-C and
/// `systemctl stop` are always immediate.
pub var stop_requested = std.atomic.Value(bool).init(false);

const handshake_timeout_s = 20;
/// A share is a few hundred bytes. If the socket cannot take that in five
/// seconds the pool is gone (or its window is closed); waiting longer only
/// stalls the worker that holds the submit mutex.
const send_timeout_s = 5;

fn setSendTimeout(stream: std.net.Stream, seconds: usize) void {
    const tv = std.posix.timeval{ .tv_sec = @intCast(seconds), .tv_usec = 0 };

    std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch {};
}

fn setIoTimeout(stream: std.net.Stream, seconds: usize) void {
    const tv = std.posix.timeval{ .tv_sec = @intCast(seconds), .tv_usec = 0 };

    std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
    std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch {};
}

fn connectThroughProxy(
    allocator: std.mem.Allocator,
    proxy: Proxy,
    host: []const u8,
    port: u16,
    timeout_ms: u32,
    logger: *@import("log.zig").Logger,
) Error!std.net.Stream {
    const stream = try connectDirect(allocator, proxy.host, proxy.port, timeout_ms, logger);
    errdefer stream.close();

    setIoTimeout(stream, handshake_timeout_s);
    defer setIoTimeout(stream, 0);

    switch (proxy.kind) {
        .http => try httpConnect(stream, proxy, host, port, logger),
        .socks5 => try socks5Connect(stream, proxy, host, port, logger),
        .none => {},
    }

    return stream;
}

fn httpConnect(stream: std.net.Stream, proxy: Proxy, host: []const u8, port: u16, logger: *@import("log.zig").Logger) Error!void {
    var buffer: [1024]u8 = undefined;
    var stream_writer = std.io.fixedBufferStream(&buffer);
    const w = stream_writer.writer();

    w.print("CONNECT {s}:{d} HTTP/1.1\r\nHost: {s}:{d}\r\n", .{ host, port, host, port }) catch return error.ProxyFailed;

    if (proxy.user) |user| {
        var plain: [510]u8 = undefined;
        const credentials = std.fmt.bufPrint(&plain, "{s}:{s}", .{ user, proxy.pass orelse "" }) catch return error.ProxyFailed;

        var encoded: [680]u8 = undefined;
        const b64 = std.base64.standard.Encoder.encode(&encoded, credentials);

        w.print("Proxy-Authorization: Basic {s}\r\n", .{b64}) catch return error.ProxyFailed;
    }

    w.writeAll("\r\n") catch return error.ProxyFailed;
    stream.writeAll(stream_writer.getWritten()) catch return error.ProxyFailed;

    var response: [1024]u8 = undefined;
    var len: usize = 0;

    while (std.mem.indexOf(u8, response[0..len], "\r\n\r\n") == null) {
        if (len == response.len) return error.ProxyFailed;

        const n = stream.read(response[len..]) catch return error.ProxyFailed;
        if (n == 0) return error.ProxyFailed;
        len += n;
    }

    const status = parseStatus(std.mem.sliceTo(response[0..len], '\r')) orelse return error.ProxyFailed;
    if (status != 200) {
        logger.warn("the HTTP proxy refused CONNECT {s}:{d} ({d})", .{ host, port, status });

        return error.ProxyRefused;
    }

    logger.debug("HTTP CONNECT to {s}:{d} via {s}:{d}", .{ host, port, proxy.host, proxy.port });
}

fn socks5Connect(stream: std.net.Stream, proxy: Proxy, host: []const u8, port: u16, logger: *@import("log.zig").Logger) Error!void {
    // VER, NMETHODS, METHODS...  The length has to match NMETHODS, otherwise
    // the proxy waits for a method byte that never arrives and the connect
    // hangs until the OS gives up (that is exactly what used to happen here).
    var greeting: [4]u8 = undefined;
    var greeting_len: usize = 0;
    const want_userpass = proxy.user != null;

    greeting[0] = 0x05;
    if (want_userpass) {
        greeting[1] = 0x02;
        greeting[2] = 0x00; // no authentication
        greeting[3] = 0x02; // username/password
        greeting_len = 4;
    } else {
        greeting[1] = 0x01;
        greeting[2] = 0x00;
        greeting_len = 3;
    }

    stream.writeAll(greeting[0..greeting_len]) catch return error.ProxyFailed;

    var reply: [2]u8 = undefined;
    readExactFrom(stream, &reply) catch return error.ProxyFailed;

    if (reply[0] != 0x05) return error.ProxyFailed;

    if (reply[1] == 0x02) {
        if (!want_userpass) return error.ProxyFailed;

        const user = proxy.user.?;
        const pass = proxy.pass orelse "";
        if (user.len > 255 or pass.len > 255) return error.ProxyFailed;

        var auth: [513]u8 = undefined;
        auth[0] = 0x01;
        auth[1] = @intCast(user.len);
        @memcpy(auth[2..][0..user.len], user);
        auth[2 + user.len] = @intCast(pass.len);
        @memcpy(auth[3 + user.len ..][0..pass.len], pass);

        stream.writeAll(auth[0 .. 3 + user.len + pass.len]) catch return error.ProxyFailed;

        var auth_reply: [2]u8 = undefined;
        readExactFrom(stream, &auth_reply) catch return error.ProxyFailed;
        if (auth_reply[1] != 0x00) {
            logger.warn("the SOCKS5 proxy rejected the credentials", .{});

            return error.ProxyRefused;
        }
    } else if (reply[1] != 0x00) {
        // 0xFF means "none of the offered methods"; anything else is a proxy
        // that speaks a dialect we do not implement.
        return error.ProxyFailed;
    }

    // CONNECT with a domain name (socks5h behaviour, the proxy resolves it).
    var request: [300]u8 = undefined;
    if (host.len > 255) return error.ProxyFailed;

    request[0] = 0x05;
    request[1] = 0x01;
    request[2] = 0x00;
    request[3] = 0x03;
    request[4] = @intCast(host.len);
    @memcpy(request[5..][0..host.len], host);
    std.mem.writeInt(u16, request[5 + host.len ..][0..2], port, .big);

    stream.writeAll(request[0 .. 7 + host.len]) catch return error.ProxyFailed;

    var head: [4]u8 = undefined;
    readExactFrom(stream, &head) catch return error.ProxyFailed;

    if (head[1] != 0x00) {
        logger.warn("the SOCKS5 proxy refused the connection (code {d})", .{head[1]});

        return error.ProxyRefused;
    }

    const to_drain: usize = switch (head[3]) {
        0x01 => 4,
        0x04 => 16,
        0x03 => blk: {
            var len_byte: [1]u8 = undefined;
            readExactFrom(stream, &len_byte) catch return error.ProxyFailed;
            break :blk len_byte[0];
        },
        else => return error.ProxyFailed,
    };

    var drain: [18]u8 = undefined;
    readExactFrom(stream, drain[0..to_drain + 2]) catch return error.ProxyFailed; // address + port

    logger.debug("SOCKS5 to {s}:{d} via {s}:{d}", .{ host, port, proxy.host, proxy.port });
}

fn readExactFrom(stream: std.net.Stream, out: []u8) !void {
    var filled: usize = 0;

    while (filled < out.len) {
        const n = try stream.read(out[filled..]);
        if (n == 0) return error.EndOfStream;

        filled += n;
    }
}

// ----------------------------------------------------------------------
// tests: the handshake pieces that decide whether a pool connection lives
// ----------------------------------------------------------------------

test "status line parsing: HTTP/1.1, 101, and the junk a proxy can send" {
    const testing = std.testing;

    try testing.expectEqual(@as(?u16, 101), parseStatus("HTTP/1.1 101 Switching Protocols"));
    try testing.expectEqual(@as(?u16, 200), parseStatus("HTTP/1.0 200 OK"));
    try testing.expectEqual(@as(?u16, 407), parseStatus("HTTP/1.1 407 Proxy Authentication Required"));
    // A stray blank line or an HTML error page must not be read as a status.
    try testing.expectEqual(@as(?u16, null), parseStatus(""));
    try testing.expectEqual(@as(?u16, null), parseStatus("HTTP/1.1"));
    try testing.expectEqual(@as(?u16, null), parseStatus("<html>502 Bad Gateway</html>"));
}

test "header lookup is case insensitive and keeps the whole value" {
    const testing = std.testing;

    const head =
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" ++
        "Set-Cookie: a=b; c=d\r\n" ++
        "\r\n" ++
        "Sec-WebSocket-Accept: ignored\r\n";

    try testing.expectEqualStrings("websocket", headerValue(head, "upgrade").?);
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", headerValue(head, "SEC-WEBSOCKET-ACCEPT").?);
    // A colon inside the value is not a separator.
    try testing.expectEqualStrings("a=b; c=d", headerValue(head, "set-cookie").?);
    // Headers after the blank line belong to the WebSocket stream.
    try testing.expectEqual(@as(?[]const u8, null), headerValue(head, "Sec-WebSocket-Protocol"));
}

test "the WebSocket accept key matches the RFC 6455 example" {
    const testing = std.testing;

    // RFC 6455 section 1.3.
    var buf: [28]u8 = undefined;
    const accept = try computeAccept("dGhlIHNhbXBsZSBub25jZQ==", &buf);
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept);
}

test "a proxy URL keeps kind, host and credentials apart" {
    const testing = std.testing;

    var p = Proxy{};
    // This is the shape options.zig hands over after parsing.
    p.kind = .socks5;
    p.host = "proxy.example";
    p.port = 1080;
    p.user = "user";
    p.pass = "p@ss";

    try testing.expect(p.isSet());
    try testing.expectEqual(ProxyKind.socks5, p.kind);
    try testing.expectEqual(@as(u16, 1080), p.port);
    const empty = Proxy{};
    try testing.expect(!empty.isSet());
}

test "a control frame that breaks RFC 6455 is refused, not half-read" {
    const testing = std.testing;
    const check = Conn.checkFrame;

    // Ping and pong, unfragmented, carrying the most they may: fine.
    try check(true, 0x9, 0);
    try check(true, 0x9, 125);
    try check(true, 0xA, 125);
    try check(true, 0x8, 125);

    // More than 125 bytes of payload: the reader would take 125, clear
    // `ws_remaining`, and leave the tail to be parsed as the next frame header.
    try testing.expectError(error.WsProtocol, check(true, 0x9, 126));
    try testing.expectError(error.WsProtocol, check(true, 0x9, 0xFFFF));
    try testing.expectError(error.WsProtocol, check(true, 0xA, 1 << 40));

    // A fragmented control frame is not a thing either.
    try testing.expectError(error.WsProtocol, check(false, 0x9, 10));

    // Data frames are allowed to be long and fragmented; the streamed reader
    // handles them a buffer at a time.
    try check(true, 0x1, 1 << 40);
    try check(false, 0x2, 100_000);
    try check(true, 0x0, 0);
}

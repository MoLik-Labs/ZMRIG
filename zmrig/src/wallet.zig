//! Is this a Monero address anybody can be paid at?
//!
//! The miner has always accepted whatever came after `-u`: the pool validates
//! it, or nothing does. That is a bad place to find out, because the failure is
//! silent on this side - a rig whose address has one wrong character mines
//! perfectly, reports a healthy hashrate, and is credited by a pool that also
//! only looked at the alphabet. The coins are then owed to an address whose
//! spend key does not exist.
//!
//! So the check happens here, before the first share: base58 (block encoded,
//! 8 bytes to 11 characters), length, network byte and the four-byte Keccak-256
//! checksum. Keccak-256, not SHA3-256 - they pad differently and only Keccak is
//! what Monero signs with.
//!
//!   standard            95 characters, 69 bytes, 1 + 32 + 32 + 4
//!   integrated         106 characters, 77 bytes, 1 + 32 + 32 + 8 + 4
//!
//! Nothing here allocates, so it costs the same nothing whether it is called
//! from `--check-wallet`, from `zmrig-os` or once at startup.

const std = @import("std");

pub const Kind = enum { standard, subaddress, integrated, integrated_subaddress };
pub const Net = enum { mainnet, stagenet, testnet };

pub const Verdict = struct {
    ok: bool = false,
    kind: Kind = .standard,
    net: Net = .mainnet,
    /// The public spend key, hex, when `ok`. A payout address is a public key
    /// pair; there is nothing secret about it.
    spend: [64]u8 = [_]u8{0} ** 64,
    view: [64]u8 = [_]u8{0} ** 64,
    payment_id: [16]u8 = [_]u8{0} ** 16,
    /// Set when `ok` is false: a sentence for a human, not an error code.
    reason: []const u8 = "",
};

const ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

fn base58Value(c: u8) ?u8 {
    for (ALPHABET, 0..) |candidate, i| {
        if (candidate == c) return @intCast(i);
    }

    return null;
}

/// Decodes Monero's block base58. Returns the number of bytes written.
///
/// The blocks are 11 characters to 8 bytes, and the last one is short: reading
/// the whole string as one big number instead gives 70 bytes for a 69-byte
/// address, which is why a naive decoder rejects every real address ever made.
fn decode(text: []const u8, out: []u8) ?usize {
    var written: usize = 0;
    var i: usize = 0;

    while (i < text.len) {
        // `@min(11, usize)` narrows to u4, and `size * 8` then overflows at 11.
        const size: usize = @min(11, text.len - i);
        const bytes_in_block = (size * 8) / 11;

        var value: u64 = 0;
        for (text[i .. i + size]) |c| {
            const digit = base58Value(c) orelse return null;
            const product = @mulWithOverflow(value, 58);
            if (product[1] != 0) return null;
            const sum = @addWithOverflow(product[0], @as(u64, digit));
            if (sum[1] != 0) return null;
            value = sum[0];
        }

        if (written + bytes_in_block > out.len) return null;

        // 8 bytes, big endian in the number, little endian in the address.
        var b: usize = 0;
        while (b < bytes_in_block) : (b += 1) {
            out[written + b] = @truncate(value >> @intCast(8 * (bytes_in_block - 1 - b)));
        }
        written += bytes_in_block;
        i += size;
    }

    return written;
}

// --------------------------------------------------------------------- keccak

const RC = [24]u64{
    0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000,
    0x000000000000808b, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
    0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800a, 0x800000008000000a,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
};

const ROT = [25]u6{
    0,  1,  62, 28, 27,
    36, 44, 6,  55, 20,
    3,  10, 43, 25, 39,
    41, 45, 15, 21, 8,
    18, 2,  61, 56, 14,
};

fn rotl(value: u64, shift: u6) u64 {
    if (shift == 0) return value;
    const back: u6 = @intCast(64 - @as(u7, shift));
    return (value << shift) | (value >> back);
}

fn keccakF(state: *[25]u64) void {
    var round: usize = 0;
    while (round < 24) : (round += 1) {
        var c: [5]u64 = undefined;
        for (0..5) |x| c[x] = state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20];

        for (0..5) |x| {
            const d = c[(x + 4) % 5] ^ rotl(c[(x + 1) % 5], 1);
            var y: usize = 0;
            while (y < 25) : (y += 5) state[y + x] ^= d;
        }

        var b: [25]u64 = undefined;
        for (0..5) |x| {
            for (0..5) |y| {
                b[y + 5 * ((2 * x + 3 * y) % 5)] = rotl(state[x + 5 * y], ROT[x + 5 * y]);
            }
        }

        // chi, row by row. The lane index is 5y + x: writing `y + x` here
        // computes the same lane twice per row and silently drops the rest,
        // which produces a digest that looks plausible and matches nothing.
        for (0..5) |y| {
            for (0..5) |x| {
                state[5 * y + x] = b[5 * y + x] ^ (~b[5 * y + (x + 1) % 5] & b[5 * y + (x + 2) % 5]);
            }
        }

        state[0] ^= RC[round];
    }
}

/// Keccak-256. `input` must be shorter than one rate block for the callers here
/// (65 or 73 bytes against a 136-byte rate), and that is asserted rather than
/// silently truncating.
pub fn keccak256(input: []const u8) [32]u8 {
    std.debug.assert(input.len < 136);

    var block = [_]u8{0} ** 136;
    @memcpy(block[0..input.len], input);
    block[input.len] ^= 0x01; // Keccak padding, not SHA3's 0x06
    block[135] ^= 0x80;

    var state = [_]u64{0} ** 25;
    for (0..17) |i| {
        state[i] ^= std.mem.readInt(u64, block[i * 8 ..][0..8], .little);
    }
    keccakF(&state);

    var out: [32]u8 = undefined;
    for (0..4) |i| std.mem.writeInt(u64, out[i * 8 ..][0..8], state[i], .little);

    return out;
}

// -------------------------------------------------------------------- address

fn network(byte: u8) ?struct { kind: Kind, net: Net } {
    return switch (byte) {
        18 => .{ .kind = .standard, .net = .mainnet },
        19 => .{ .kind = .integrated, .net = .mainnet },
        42 => .{ .kind = .subaddress, .net = .mainnet },
        43 => .{ .kind = .integrated_subaddress, .net = .mainnet },
        24 => .{ .kind = .standard, .net = .stagenet },
        25 => .{ .kind = .integrated, .net = .stagenet },
        36 => .{ .kind = .subaddress, .net = .stagenet },
        37 => .{ .kind = .integrated_subaddress, .net = .stagenet },
        53 => .{ .kind = .standard, .net = .testnet },
        54 => .{ .kind = .integrated, .net = .testnet },
        63 => .{ .kind = .subaddress, .net = .testnet },
        64 => .{ .kind = .integrated_subaddress, .net = .testnet },
        else => null,
    };
}

/// Checks one address. Cheap enough to call on every login.
pub fn check(input: []const u8) Verdict {
    const text = std.mem.trim(u8, input, " \t\r\n");

    if (text.len == 0) return .{ .reason = "empty" };
    if (text.len != 95 and text.len != 106) {
        return .{ .reason = "a Monero address is 95 characters (106 with a payment id)" };
    }

    const integrated = text.len == 106;
    const body: usize = if (integrated) 73 else 65;

    var raw: [77]u8 = undefined;
    const written = decode(text, &raw) orelse
        return .{ .reason = "not base58: one of the characters cannot appear in an address" };
    if (written != body + 4) {
        return .{ .reason = "not a valid base58 encoding of an address (wrong length inside)" };
    }

    const digest = keccak256(raw[0..body]);
    if (!std.mem.eql(u8, digest[0..4], raw[body .. body + 4])) {
        return .{ .reason = "checksum does not match: at least one character is wrong" };
    }

    const info = network(raw[0]) orelse
        return .{ .reason = "network byte is not a Monero network" };
    const has_payment_id = info.kind == .integrated or info.kind == .integrated_subaddress;
    if (has_payment_id != integrated) {
        return .{ .reason = "this address kind and its payment id disagree" };
    }

    var verdict = Verdict{ .ok = true, .kind = info.kind, .net = info.net };
    _ = std.fmt.bufPrint(&verdict.spend, "{s}", .{std.fmt.fmtSliceHexLower(raw[1..33])}) catch {};
    _ = std.fmt.bufPrint(&verdict.view, "{s}", .{std.fmt.fmtSliceHexLower(raw[33..65])}) catch {};
    if (integrated) {
        _ = std.fmt.bufPrint(&verdict.payment_id, "{s}", .{std.fmt.fmtSliceHexLower(raw[65..73])}) catch {};
    }

    return verdict;
}

/// What a miner needs to know before it starts: is this something a mainnet
/// pool can pay, and if not, why not in one sentence.
pub fn payable(input: []const u8) Verdict {
    const verdict = check(input);
    if (verdict.ok and verdict.net != .mainnet) {
        return .{ .reason = "this is a stagenet/testnet address: a mainnet pool cannot pay it" };
    }

    return verdict;
}

pub fn kindLabel(kind: Kind) []const u8 {
    return switch (kind) {
        .standard => "standard",
        .subaddress => "subaddress",
        .integrated => "integrated (payment id)",
        .integrated_subaddress => "integrated subaddress",
    };
}

pub fn netLabel(net: Net) []const u8 {
    return switch (net) {
        .mainnet => "mainnet",
        .stagenet => "stagenet",
        .testnet => "testnet",
    };
}

// ---------------------------------------------------------------------- tests

const testing = std.testing;

// A real mainnet address from the XMRig documentation. Deliberately not the
// developer's own: `scripts/verify-fee.sh` requires that exactly one file under
// src/ mentions it, so that a second address cannot appear without a reviewer
// seeing it in the fee audit.
const SAMPLE = "4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge";

test "keccak-256 matches the published vectors" {
    // Keccak-256("") and Keccak-256("abc"). These differ from SHA3-256, which
    // is the whole reason this is implemented rather than imported.
    const empty = keccak256("");
    try testing.expectEqualStrings(
        "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
        &std.fmt.bytesToHex(empty, .lower),
    );

    const abc = keccak256("abc");
    try testing.expectEqualStrings(
        "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45",
        &std.fmt.bytesToHex(abc, .lower),
    );
}

test "a real address verifies" {
    const verdict = check(SAMPLE);
    try testing.expect(verdict.ok);
    try testing.expectEqual(Kind.standard, verdict.kind);
    try testing.expectEqual(Net.mainnet, verdict.net);
    try testing.expectEqualStrings("eda9fe8dfcdd25d5430ea64229d04f6b41b2e5a1587c29cd499a63eb79d11711", &verdict.spend);

    try testing.expect(payable(SAMPLE).ok);
    // The view key is a key of its own, not the spend key again.
    try testing.expect(!std.mem.eql(u8, &verdict.spend, &verdict.view));
}

test "one changed character fails the checksum" {
    // The failure this module exists for: a typo that the alphabet check
    // accepts and nobody notices until the payout.
    var typo: [95]u8 = undefined;
    @memcpy(&typo, SAMPLE);
    typo[40] = if (typo[40] == 'a') 'b' else 'a';

    const verdict = check(&typo);
    try testing.expect(!verdict.ok);
    try testing.expectEqualStrings("checksum does not match: at least one character is wrong", verdict.reason);
}

test "not-an-address is refused with a reason a person can act on" {
    try testing.expect(!check("").ok);
    try testing.expect(!check("wallet.rig").ok);
    try testing.expect(!check("4AdUnd").ok);
    // 95 characters, but '0' and 'O' are not in the base58 alphabet Monero uses.
    try testing.expect(!check("40dUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge").ok);
}

test "a testnet address is a valid address this pool cannot pay" {
    // Network byte 53 is testnet standard. Build one by re-encoding is a lot of
    // work for a test, so the check is exercised through the version byte: a
    // well-formed mainnet address with byte 53 and a recomputed checksum is
    // exactly what a testnet address looks like.
    var raw: [69]u8 = undefined;
    _ = decode(SAMPLE, &raw) orelse unreachable;
    raw[0] = 53;
    const digest = keccak256(raw[0..65]);
    @memcpy(raw[65..69], digest[0..4]);

    // Re-encode: only needed to get a string back into `check`.
    const encoded = try testing.allocator.alloc(u8, 95);
    defer testing.allocator.free(encoded);
    var written: usize = 0;
    var i: usize = 0;
    while (i < raw.len) {
        const size: usize = @min(8, raw.len - i);
        const chars = (size * 11 + 7) / 8;
        var value: u64 = 0;
        for (raw[i .. i + size]) |byte| value = value * 256 + byte;
        var k: usize = 0;
        while (k < chars) : (k += 1) {
            encoded[written + chars - 1 - k] = ALPHABET[@intCast(value % 58)];
            value /= 58;
        }
        written += chars;
        i += size;
    }

    const verdict = check(encoded[0..written]);
    try testing.expect(verdict.ok);
    try testing.expectEqual(Net.testnet, verdict.net);
    try testing.expect(!payable(encoded[0..written]).ok);
}

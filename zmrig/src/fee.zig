//! The developer fee: a share of Monero mining *time*, spent on the developer's
//! wallet.
//!
//! Why time and not a cut of every share: the pool pays whoever logs in. A
//! miner cannot take 1 % out of a share it already solved, so the only way to
//! pay a fee without a second program in the middle is to mine for the other
//! wallet for 1 % of the clock. XMRig, SRBMiner and every other miner with a
//! fee do the same thing; the difference here is that it is stated in the
//! banner, in `--check`, in the log when a session opens and in `--help`, and
//! `--donate-level=0` turns it off.
//!
//! Monero only. The wallet below is a Monero address on the Monero network: a
//! fee session on ArQmA, Wownero, Graft, Safex, Yada or Scala would pay a pool
//! in a coin that address cannot spend, so those algorithms accrue nothing.
//!
//! The clock is debt-based rather than interval-based, so nothing is lost to a
//! reconnect: every second of Monero mining adds `percent / 100` seconds of
//! debt, and a fee session spends it down.

const std = @import("std");

/// Every fee session mines to this address.
pub const wallet = "46SQLW7DXaq6GJaQbHUFMAhd1VYpfQFJQ2gfZo9TCB8bf9vnf1MUwAD2Fwj6KMsY4RU3oKA3x6hByg8BKg7FfMWn6ysb5tJ";

pub const default_percent: u32 = 1;
/// `--donate-level=11` is a typo, not a generous user.
pub const max_percent: u32 = 10;

/// A fee session opens once this much time is owed. At the default 1 % that is
/// 60 s of Monero mining after 100 minutes: XMRig's cadence, and long enough
/// that a reconnect does not show up in the hashrate line.
pub const start_ms: i64 = 60_000;
/// Debt stops growing here, so a pool that refused the developer wallet for a
/// week does not turn into a two-hour fee session the day it starts accepting
/// it.
pub const max_debt_ms: i64 = 3_600_000;
/// A single fee session is capped: a pool that keeps a job coming and never
/// answers a share must not hold the wallet for an hour.
pub const max_session_ms: i64 = 30 * 60_000;
/// A refusal is followed by a pause before the next attempt: without one the
/// monitor would end the user's session again the second the debt is still
/// owed, which is a reconnect loop, not a fee.
pub const retry_ms: i64 = 120_000;
/// Three refusals in a row and the fee waits half an hour instead.
pub const max_failures: u8 = 3;
pub const suspend_ms: i64 = 30 * 60_000;

pub const Clock = struct {
    percent: u32 = default_percent,

    /// Milliseconds of Monero mining owed to the developer. Written by the
    /// monitor thread once a second, read by the mining loop before a
    /// connection, hence atomic.
    owed_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    /// True while the current session mines for the developer wallet.
    donating: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Whether the job being mined right now is Monero. Written by the mining
    /// loop when a job lands, read by the monitor's one-second tick.
    monero: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Mining-loop state: never touched by another thread.
    session_start_ms: i64 = 0,
    failures: u8 = 0,
    suspended_until_ms: i64 = 0,

    pub fn init(percent: u32) Clock {
        return .{ .percent = @min(percent, max_percent) };
    }

    pub fn on(self: *const Clock) bool {
        return self.percent > 0;
    }

    /// The mining loop tells the clock which coin it is hashing. `--algo=auto`
    /// pools switch under us, so this follows every job, not the config.
    pub fn noteMonero(self: *Clock, is_monero: bool) void {
        self.monero.store(is_monero, .release);
    }

    pub fn moneroNow(self: *const Clock) bool {
        return self.monero.load(.acquire);
    }

    pub fn owed(self: *const Clock) i64 {
        return self.owed_ms.load(.acquire);
    }

    pub fn isDonating(self: *const Clock) bool {
        return self.donating.load(.acquire);
    }

    /// One accounting tick. `dt_ms` is wall-clock elapsed since the last call,
    /// `monero` whether the job being mined right now is rx/0.
    ///
    /// While a fee session runs the debt goes down by the elapsed time, not by
    /// the percentage: the developer is mining, so it is paid per second. While
    /// the user mines, debt grows by `percent` of the elapsed time.
    pub fn tick(self: *Clock, dt_ms: i64, monero: bool) void {
        if (dt_ms <= 0) return;

        if (self.isDonating()) {
            self.owed_ms.store(@max(self.owed() - dt_ms, 0), .release);
            return;
        }

        if (!self.on() or !monero) return;

        const growth = @divTrunc(@as(i64, self.percent) * dt_ms, 100);
        const next = @min(self.owed() + growth, max_debt_ms);
        self.owed_ms.store(next, .release);
    }

    /// Is a fee session allowed to open now?
    pub fn due(self: *const Clock, now_ms: i64) bool {
        if (!self.on()) return false;
        if (now_ms < self.suspended_until_ms) return false;

        return self.owed() >= start_ms;
    }

    /// The mining loop is about to connect with the developer wallet.
    pub fn begin(self: *Clock, now_ms: i64) void {
        self.session_start_ms = now_ms;
        self.donating.store(true, .release);
    }

    /// The session ended, however it ended.
    pub fn finish(self: *Clock) void {
        self.donating.store(false, .release);
        self.session_start_ms = 0;
    }

    /// The monitor asks this once a second: a fee session that has paid its
    /// debt, or that has run long enough, must end even though the pool is
    /// still chatting.
    pub fn expired(self: *const Clock, now_ms: i64) bool {
        if (!self.isDonating()) return false;
        if (self.owed() <= 0) return true;
        if (self.session_start_ms == 0) return false;

        return now_ms - self.session_start_ms >= max_session_ms;
    }

    /// The pool would not take the developer wallet (unknown address, wrong
    /// network, a ban). Suspend rather than hammer: the user's own mining is
    /// what matters, and the debt stays owed for later.
    pub fn fail(self: *Clock, now_ms: i64) void {
        self.finish();
        self.failures +|= 1;

        if (self.failures >= max_failures) {
            self.failures = 0;
            self.suspended_until_ms = now_ms + suspend_ms;

            return;
        }

        self.suspended_until_ms = now_ms + retry_ms;
    }

    /// A successful fee session clears the failure streak.
    pub fn succeeded(self: *Clock) void {
        self.failures = 0;
    }

    pub fn suspended(self: *const Clock, now_ms: i64) bool {
        return now_ms < self.suspended_until_ms;
    }
};

test "one percent of an hour is 36 seconds of debt" {
    var clock = Clock.init(1);

    // An hour of Monero mining, ticked a second at a time.
    var i: usize = 0;
    while (i < 3600) : (i += 1) clock.tick(1000, true);

    try std.testing.expectEqual(@as(i64, 36_000), clock.owed());
    try std.testing.expect(!clock.due(0));
}

test "the default fee opens a session after 100 minutes" {
    var clock = Clock.init(1);

    var elapsed: i64 = 0;
    while (!clock.due(elapsed)) : (elapsed += 1000) {
        clock.tick(1000, true);
        if (elapsed > 3 * 3600 * 1000) return error.NeverDue;
    }

    // 60 s owed at 1 % is 6000 s of mining.
    try std.testing.expect(elapsed >= 5_999_000);
    try std.testing.expect(elapsed <= 6_001_000);
}

test "a fee session spends the debt and ends by itself" {
    var clock = Clock.init(1);
    clock.owed_ms.store(start_ms, .release);

    clock.begin(0);
    try std.testing.expect(clock.isDonating());
    try std.testing.expect(!clock.expired(59_000));

    var i: usize = 0;
    while (i < 60) : (i += 1) clock.tick(1000, true);

    try std.testing.expectEqual(@as(i64, 0), clock.owed());
    try std.testing.expect(clock.expired(60_000));

    clock.finish();
    try std.testing.expect(!clock.expired(60_000));
}

test "a fee session cannot run past the cap" {
    var clock = Clock.init(10);
    clock.owed_ms.store(max_debt_ms, .release);
    clock.begin(1_000);

    try std.testing.expect(!clock.expired(1_000 + max_session_ms - 1));
    try std.testing.expect(clock.expired(1_000 + max_session_ms));
}

test "other coins accrue nothing" {
    var clock = Clock.init(1);

    var i: usize = 0;
    while (i < 3600) : (i += 1) clock.tick(1000, false);

    try std.testing.expectEqual(@as(i64, 0), clock.owed());
    try std.testing.expect(!clock.due(std.time.milliTimestamp()));
}

test "zero percent is off, and the debt stops at the cap" {
    var off = Clock.init(0);
    off.tick(3_600_000, true);
    try std.testing.expectEqual(@as(i64, 0), off.owed());
    try std.testing.expect(!off.due(0));

    var clock = Clock.init(10);
    clock.tick(100 * 3_600_000, true);
    try std.testing.expectEqual(max_debt_ms, clock.owed());
}

test "a refusal pauses the fee instead of looping, three of them park it" {
    var clock = Clock.init(1);
    clock.owed_ms.store(start_ms, .release);

    // One refusal: the debt is still owed, but not immediately acted on --
    // otherwise the monitor ends the user's session again every second.
    clock.begin(0);
    clock.fail(1_000);
    try std.testing.expect(!clock.isDonating());
    try std.testing.expect(!clock.due(2_000));
    try std.testing.expect(clock.due(1_000 + retry_ms));

    clock.begin(1_000 + retry_ms);
    clock.fail(2_000 + retry_ms);
    try std.testing.expect(!clock.due(3_000 + retry_ms));

    clock.begin(3_000 + retry_ms);
    clock.fail(4_000 + retry_ms);
    try std.testing.expect(!clock.due(4_000 + retry_ms));
    try std.testing.expect(clock.suspended(4_000 + retry_ms));
    try std.testing.expect(!clock.due(4_000 + retry_ms + suspend_ms - 1));
    try std.testing.expect(clock.due(4_000 + retry_ms + suspend_ms));
    // Suspended is not forgiven: the debt is still there.
    try std.testing.expectEqual(start_ms, clock.owed());
}

test "a successful session clears the failure streak" {
    var clock = Clock.init(1);
    clock.owed_ms.store(start_ms, .release);

    clock.begin(0);
    clock.fail(1_000);
    clock.succeeded();
    // Two more failures must not add up to a suspension, because the success
    // in between reset the streak.
    clock.begin(2_000 + retry_ms);
    clock.fail(3_000 + retry_ms);
    clock.begin(4_000 + retry_ms);
    clock.fail(5_000 + retry_ms);
    try std.testing.expect(!clock.suspended(6_000 + retry_ms + suspend_ms));
}

test "a failed tick of zero or negative length does nothing" {
    var clock = Clock.init(1);
    clock.tick(0, true);
    clock.tick(-5_000, true);
    try std.testing.expectEqual(@as(i64, 0), clock.owed());
}

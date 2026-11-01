// How much RandomX memory a run needs, and whether it fits.
//
// This used to be one constant — 2416 MiB, the size of Monero's cache plus its
// dataset — applied to every algorithm. The seven configurations in this
// repository are not the same size: Panthera/Scala (Scala, `panthera`) needs
// 128 MiB of cache and a 64 MiB dataset, so a 512 MiB VPS can mine it in fast
// mode with 2 MiB pages while Monero would not even fit. Sizing the reservation
// and the `--mode=auto` decision from Monero's numbers meant those machines fell
// back to light mode for no reason: 82 H/s where fast mode does 857 H/s on the
// same two cores, because light mode rebuilds every dataset line from the cache
// on the fly. It is a fallback for boxes that cannot give 2 GiB, not a mode.
//
// The numbers come from the C engine (`xmo_algo_memory`), which reads the
// compiled-in configuration; this module is the rule that turns them into a
// decision, kept pure so the Zig unit tests can check it without linking C.

const std = @import("std");
const options = @import("options.zig");

/// RAM left for the OS, the binary, the per-thread scratchpads and page cache.
pub const slack_bytes: u64 = 512 * 1024 * 1024;

pub const Sizes = struct {
    cache: u64,
    dataset: u64,

    pub fn total(self: Sizes) u64 {
        return self.cache + self.dataset;
    }
};

/// Does full-memory mode (the 2 GiB dataset) fit on this machine?
///
/// `fast` is a promise the user made; `light` one they made the other way;
/// `auto` is this function deciding, and it is the only case that looks at RAM.
pub fn fullMemory(sizes: Sizes, mode: options.Mode, total_ram: u64) bool {
    return switch (mode) {
        .light => false,
        .fast => true,
        .auto => total_ram >= sizes.total() + slack_bytes,
    };
}

/// Bytes this mode will map: the cache always, the dataset only in full mode.
pub fn bytesFor(sizes: Sizes, mode: options.Mode, total_ram: u64) u64 {
    return sizes.cache + if (fullMemory(sizes, mode, total_ram)) sizes.dataset else 0;
}

/// The same number in MiB, rounded up — for messages and the huge-page plan.
pub fn mibFor(sizes: Sizes, mode: options.Mode, total_ram: u64) u64 {
    return (bytesFor(sizes, mode, total_ram) + 1024 * 1024 - 1) / (1024 * 1024);
}

test "full mode is chosen per algorithm, because the algorithms differ in size" {
    const testing = std.testing;
    const mib: u64 = 1024 * 1024;

    const monero = Sizes{ .cache = 256 * mib, .dataset = 2080 * mib };
    const scala = Sizes{ .cache = 128 * mib, .dataset = 64 * mib };

    // A 1 GiB VPS: Scala fits with room to spare, Monero does not.
    try testing.expect(fullMemory(scala, .auto, 1024 * mib));
    try testing.expect(!fullMemory(monero, .auto, 1024 * mib));

    // A 3 GiB box holds both.
    try testing.expect(fullMemory(monero, .auto, 3072 * mib));
    try testing.expect(fullMemory(scala, .auto, 3072 * mib));

    // 2.5 GiB is still short of Monero's 2336 + 512.
    try testing.expect(!fullMemory(monero, .auto, 2560 * mib));
    try testing.expect(fullMemory(monero, .auto, 2336 * mib + slack_bytes));

    // An explicit mode is never second-guessed.
    try testing.expect(fullMemory(monero, .fast, 64 * mib));
    try testing.expect(!fullMemory(scala, .light, 64 * 1024 * mib));
}

test "bytes and MiB follow the mode" {
    const testing = std.testing;
    const mib: u64 = 1024 * 1024;
    const monero = Sizes{ .cache = 256 * mib, .dataset = 2080 * mib };

    try testing.expectEqual(@as(u64, 2336 * mib), bytesFor(monero, .fast, 1));
    try testing.expectEqual(@as(u64, 256 * mib), bytesFor(monero, .light, 64 * 1024 * mib));
    try testing.expectEqual(@as(u64, 2336), mibFor(monero, .fast, 1));

    // Rounded up, never down: a page count derived from a rounded-down MiB
    // value is one page short of the dataset.
    const odd = Sizes{ .cache = 1, .dataset = 64 * mib - 1 };
    try testing.expectEqual(@as(u64, 1), mibFor(odd, .light, 1));
    try testing.expectEqual(@as(u64, 64), mibFor(odd, .fast, 1));
}

//! Command line and config file handling.
//!
//! Flags mirror XMRig's so existing scripts and muscle memory keep working:
//!   zmrig -o pool:port -u WALLET -p x -a rx/0 -t 2 --rig-id rig --keepalive
//! A JSON config file can replace or extend the command line:
//!   zmrig -c /etc/zmrig/config.json

const std = @import("std");
const api = @import("api.zig");
const transport = @import("transport.zig");

pub const Pool = struct {
    host: []const u8 = "",
    port: u16 = 0,
    transport: transport.Kind = .tcp,
    user: []const u8 = "",
    /// Static "x" until a `-p`/config value replaces it with an allocated
    /// string; `freePool` knows about that one exception.
    password: []const u8 = "x",
    rig_id: ?[]const u8 = null,
    keepalive: bool = true,
    nicehash: bool = false,
    tls_insecure: bool = false,
    tls_ca: ?[]const u8 = null,
    ws_path: ?[]const u8 = null,
    ws_origin: ?[]const u8 = null,
    host_header: ?[]const u8 = null,
    connect_host: ?[]const u8 = null,
    connect_port: ?u16 = null,
    proxy_url: ?[]const u8 = null,
    proxy_spec: transport.Proxy = .{},
    /// True when the URL scheme (or --tls) named a transport explicitly.
    user_transport: bool = false,
    /// True when the URL/flag carried an explicit port.
    user_port: bool = false,
    /// Optional per-pool algorithm pin; null means "whatever the pool sends".
    algo: ?api.Algo = null,
    /// `"algo":"auto"` on this pool: advertise the whole RandomX family.
    algo_all: bool = false,

    pub fn proxy(self: *const Pool) transport.Proxy {
        return self.proxy_spec;
    }

    /// True when the pool was reached over a WebSocket, i.e. its URL path is
    /// meaningful (Cloudflare routes on it).
    pub fn isWs(self: *const Pool) bool {
        return self.transport.usesWs();
    }
};

pub fn freePool(allocator: std.mem.Allocator, pool: Pool) void {
    allocator.free(pool.host);
    allocator.free(pool.user);
    // Pools that never saw a `-p` still point at the static default.
    if (!std.mem.eql(u8, pool.password, "x")) allocator.free(pool.password);
    if (pool.rig_id) |v| allocator.free(v);
    if (pool.tls_ca) |v| allocator.free(v);
    if (pool.connect_host) |v| allocator.free(v);
    if (pool.host_header) |v| allocator.free(v);
    if (pool.ws_origin) |v| allocator.free(v);
    if (pool.proxy_url) |v| allocator.free(v);
    if (pool.ws_path) |v| allocator.free(v);
    allocator.free(pool.proxy_spec.host);
    if (pool.proxy_spec.user) |v| allocator.free(v);
    if (pool.proxy_spec.pass) |v| allocator.free(v);
}

/// Per-pool options given before any pool URL. `zmrig -u WALLET -o pool`
/// must behave exactly like `zmrig -o pool -u WALLET`: the old code appended a
/// placeholder pool for the `-u`, which then failed validation with
/// InvalidPool. Values are remembered here and copied into every pool that is
/// created afterwards (and into the last pool when one already exists).
const Pending = struct {
    user: ?[]const u8 = null,
    password: ?[]const u8 = null,
    rig_id: ?[]const u8 = null,
    keepalive: ?bool = null,
    nicehash: ?bool = null,
    tls_insecure: bool = false,
    transport: ?transport.Kind = null,

    fn apply(self: *const Pending, allocator: std.mem.Allocator, pool: *Pool) ParseError!void {
        if (self.user) |value| {
            if (pool.user.len != 0) allocator.free(pool.user);
            pool.user = allocator.dupe(u8, value) catch return error.OutOfMemory;
        }
        if (self.password) |value| {
            if (!std.mem.eql(u8, pool.password, "x")) allocator.free(pool.password);
            pool.password = allocator.dupe(u8, value) catch return error.OutOfMemory;
        }
        if (self.rig_id) |value| {
            if (pool.rig_id) |old| allocator.free(old);
            pool.rig_id = allocator.dupe(u8, value) catch return error.OutOfMemory;
        }
        if (self.keepalive) |value| pool.keepalive = value;
        if (self.transport) |value| {
            pool.transport = value;
            pool.user_transport = true;
        }
        if (self.nicehash) |value| pool.nicehash = value;
        if (self.tls_insecure) pool.tls_insecure = true;
    }
};

/// The workers the miner can hold. It is the width of the arrays the mining
/// core allocates per thread, and `-t` has to be policed against it *here*:
/// the check used to live only in the mining core, so `--check` blessed
/// `-t 0` and the run then refused to start - and `-t 99999` was turned into a
/// "202398 MB dataset does not fit" message about a thread count that could
/// never have existed.
pub const max_threads: usize = 128;

pub const Mode = enum { auto, fast, light };

/// Which options the command line actually set. The config file is read first
/// and the command line is merged on top, so a flag that was *not* given must
/// not overwrite the config with its default value (that is how a `mode` of
/// "light" in config.json was silently replaced by "auto").
pub const Seen = struct {
    mode: bool = false,
    huge_pages: bool = false,
    huge_pages_jit: bool = false,
    auto_hugepages: bool = false,
    profile: bool = false,
    health_restart: bool = false,
    jit: bool = false,
    affinity: bool = false,
    affinity_mask: bool = false,
    user_agent: bool = false,
    init_threads: bool = false,
    threads: bool = false,
    priority: bool = false,
    print_time: bool = false,
    retries: bool = false,
    retry_pause: bool = false,
    ban_cooldown: bool = false,
    idle_timeout: bool = false,
    keepalive_interval: bool = false,
    scratchpad_prefetch: bool = false,
    optimized_init: bool = false,
    dataset_cache: bool = false,
    msr: bool = false,
    msr_restore: bool = false,
    colors: bool = false,
    verbose: bool = false,
    background: bool = false,
    report: bool = false,
    report_time: bool = false,
    report_file: bool = false,
    report_interval: bool = false,
    report_id: bool = false,
    power: bool = false,
};

pub const ProfileSetting = enum {
    auto,
    free,
    watt,

    pub fn fromName(name: []const u8) ?ProfileSetting {
        if (std.mem.eql(u8, name, "auto")) return .auto;
        if (std.mem.eql(u8, name, "free")) return .free;
        if (std.mem.eql(u8, name, "watt")) return .watt;

        return null;
    }

    pub fn label(self: ProfileSetting) []const u8 {
        return switch (self) {
            .auto => "auto",
            .free => "free",
            .watt => "watt",
        };
    }
};

/// What to do about the RandomX MSR preset: prefetchers off is worth 5-15% on
/// Zen and Intel bare metal, and exactly nothing in a VM that does not pass the
/// registers through. `auto` is the default, so the win is not left on the table
/// by somebody who did not read the help; `--no-msr` is how you stop it.
pub const MsrMode = enum { auto, on, off };

pub const Options = struct {
    pools: std.ArrayListUnmanaged(Pool) = .{},
    seen: Seen = .{},
    algo: ?api.Algo = null,
    /// `--algo=auto`: advertise every RandomX variant this engine can hash
    /// correctly, so a pool that pays for the most profitable coin per hash
    /// (MoneroOcean and forks) may switch this rig between them. Without it the
    /// pool sees a single-algorithm rig and leaves it on rx/0.
    algo_all: bool = false,
    threads: ?usize = null,
    mode: Mode = .auto,
    huge_pages: bool = true,
    huge_pages_jit: bool = true,
    jit: bool = true,
    priority: i32 = -1,
    affinity: bool = true,
    /// `--cpu-affinity=0x3`: only mine on these CPUs (bit per core).
    affinity_mask: ?u64 = null,
    /// `--user-agent`: what the pool sees in the WebSocket upgrade.
    user_agent: ?[]const u8 = null,
    /// `--randomx-init`: threads used to build the dataset (0 = every CPU).
    init_threads: usize = 0,
    colors: bool = true,
    verbose: bool = false,
    print_time: u32 = 60,
    retries: u32 = 5,
    retry_pause: u32 = 5,
    /// Minutes a pool is left alone after it banned this IP, refused the
    /// wallet, or said it is full. Retrying a ban is how it becomes a longer ban.
    ban_cooldown: u32 = 900,
    /// Seconds of total pool silence before the connection is dropped.
    /// 0 disables the watchdog.
    idle_timeout: u32 = 300,
    /// Seconds between `keepalived` messages when nothing else is sent.
    keepalive_interval: u32 = 60,
    /// How the JIT prefetches the scratchpad: 0 nop, 1 prefetcht0 (default),
    /// 2 prefetchnta, 3 a plain load. Baked into the compiled program, so it
    /// only takes effect on a fresh cache.
    scratchpad_prefetch: i32 = 1,
    /// Reserve the huge pages this mode needs when the pool is empty and we are
    /// root. Measured +20.7 % on a 2 vCPU host (855.7 -> 1033.0 H/s); disabled
    /// with `--no-auto-hugepages` for hosts where /proc must not change.
    auto_hugepages: bool = true,
    /// `--no-health-restart`: never exit to recover from a stall.
    health_restart: bool = true,
    /// How long a fault must hold before the process exits for a restart.
    health_restart_seconds: u32 = 900,
    /// Grace period before the health rules judge anything (dataset init,
    /// first share). 180 s is generous for a laptop; a bare-metal server is
    /// hashing in 20.
    health_warmup_seconds: u32 = 180,
    /// `--profile=free|watt|auto`: what the machine is for. `free` maximises
    /// hashrate (electricity is not the user's problem: cafe, school lab,
    /// flat-rate VPS), `watt` maximises hashrate per watt (physical cores only,
    /// stops on battery). `auto` resolves to `watt` on a laptop running on
    /// battery and to `free` everywhere else.
    profile: ProfileSetting = .auto,
    /// `--max-temp=°C`: keep the hottest CPU sensor at or below this. Null and
    /// 0 both mean "no governor": a machine with no thermal policy behaves
    /// exactly as it did before this flag existed.
    max_temp: ?f32 = null,
    /// `--thermal-file=PATH`: take the temperature from this file instead of
    /// sysfs. For rigs whose sensor is not in /sys (a BMC, a USB thermometer
    /// read by udev) and for the test suite, which starts the real binary and
    /// changes a real number.
    thermal_file: ?[]const u8 = null,
    /// `--autotune[=SECONDS]`: measure the thread count on this machine, print
    /// the winner and the config line to keep. Never trusts the L3 heuristic.
    autotune: bool = false,
    autotune_seconds: u32 = 8,
    /// Use the AVX2 dataset initialiser (faster seeding, identical hashes).
    optimized_init: bool = true,
    /// MB of dataset memory to keep mapped after an algorithm switch, so a
    /// pool that moves between RandomX forks does not pay a 20 s rebuild every
    /// time it moves back. `null` is the default: as much as the kernel can
    /// hand out for the next engine, decided at the switch. 0 disables it.
    dataset_cache_mb: ?u64 = null,
    /// Apply the RandomX MSR preset (prefetchers off). `auto`, the default,
    /// does it when the machine can take it: root, bare metal, and an MSR
    /// device the kernel answers on. Anything else is a logged no-op, because
    /// writing nobody's registers is the only safe thing to do in a container.
    msr: MsrMode = .auto,
    /// Put the old MSR values back on exit.
    msr_restore: bool = true,
    /// `--donate-level=N`: percent of Monero mining time spent on the
    /// developer's wallet (0 turns the fee off). See `fee.zig`.
    donate_percent: u32 = @import("fee.zig").default_percent,
    log_file: ?[]const u8 = null,
    api_port: u16 = 0,
    api_token: ?[]const u8 = null,
    http_host: []const u8 = "127.0.0.1",
    background: bool = false,
    config_path: ?[]const u8 = null,
    self_test: bool = false,
    self_test_light: bool = false,
    /// `--check-wallet ADDR`: decode the address, verify its checksum and say
    /// what it is. Exits non-zero when a pool could not pay it.
    check_wallet: ?[]const u8 = null,
    /// `--allow-bad-wallet`: start even though the address fails its checksum.
    /// For the rare rig that logs into a pool with something that is address
    /// shaped but is not a Monero address; without it, a bad checksum under
    /// rx/0 is a refusal rather than a rig that hashes for nobody.
    allow_bad_wallet: bool = false,
    check: bool = false,
    benchmark: bool = false,
    bench_hashes: u64 = 1_000_000,
    /// `--report`: short benchmark, then print a machine report code.
    report: bool = false,
    report_seconds: u32 = 15,
    /// `--report-file`: keep this file updated while mining.
    report_file: ?[]const u8 = null,
    report_interval: u32 = 60,
    report_id: ?[]const u8 = null,
    /// `--power W`: wall power of the machine, used by the report.
    power_watts: ?f64 = null,
    /// `--verify-share`: JSON lines on stdin, hashes on stdout (pool mode).
    verify_share: bool = false,
    // Transport defaults applied to every pool that did not specify them.
    transport_override: ?transport.Kind = null,
    ws_path: ?[]const u8 = null,
    ws_origin: ?[]const u8 = null,
    host_header: ?[]const u8 = null,
    connect_to: ?[]const u8 = null,
    tls_ca: ?[]const u8 = null,
    proxy_url: ?[]const u8 = null,
    cloudflare: bool = false,
    version: bool = false,
    help: bool = false,

    pub fn deinit(self: *Options, allocator: std.mem.Allocator) void {
        for (self.pools.items) |pool| freePool(allocator, pool);
        self.pools.deinit(allocator);
        if (self.log_file) |v| allocator.free(v);
        if (self.report_file) |v| allocator.free(v);
        if (self.report_id) |v| allocator.free(v);
        if (self.api_token) |v| allocator.free(v);
        if (self.config_path) |v| allocator.free(v);
        if (self.ws_path) |v| allocator.free(v);
        if (self.ws_origin) |v| allocator.free(v);
        if (self.host_header) |v| allocator.free(v);
        if (self.connect_to) |v| allocator.free(v);
        if (self.tls_ca) |v| allocator.free(v);
        if (self.proxy_url) |v| allocator.free(v);
        if (self.thermal_file) |v| allocator.free(v);
    }

    /// Resolves the algorithm for a pool: explicit flag > pool flag > job value.
    pub fn poolAlgo(self: *const Options, pool: *const Pool) ?api.Algo {
        return pool.algo orelse self.algo;
    }

    /// What to announce in the login request, in priority order.
    ///
    ///   pinned algo   one entry -- the rig refuses anything else
    ///   --algo=auto   every variant the engine implements (api.auto_algos)
    ///   neither       empty: the miner says nothing and mines whatever job the
    ///                 pool sends, which is what `zmrig` has always done
    ///
    /// `buf` is owned by the caller so this stays allocation-free; the returned
    /// slice points into it.
    pub fn loginAlgos(self: *const Options, pool: *const Pool, buf: *[api.auto_algos.len]api.Algo) []const api.Algo {
        if (self.poolAlgo(pool)) |algo| {
            buf[0] = algo;

            return buf[0..1];
        }

        if (self.algo_all or pool.algo_all) {
            @memcpy(buf[0..api.auto_algos.len], api.auto_algos[0..]);

            return buf[0..api.auto_algos.len];
        }

        return buf[0..0];
    }
};

pub const ParseError = error{
    MissingValue,
    UnknownOption,
    InvalidNumber,
    InvalidPool,
    NoPools,
    NoWallet,
    OutOfMemory,
    InvalidConfig,
    /// `-t 0`, `-t 99999`: a count no run can use.
    InvalidThreads,
    /// `--scratchpad-prefetch` is 0..3. Anything else used to be accepted and
    /// silently hashed with mode 1, which is a tuning flag that does nothing.
    InvalidPrefetch,
    /// `--priority` outside -20..19 (the range `setpriority` accepts) and
    /// outside the XMRig 1..5 scale, where the kernel ignored it silently.
    InvalidPriority,
    /// A pool written as `host:0`.
    InvalidPoolPort,
    /// `--tls-ca` pointed at a file that cannot be read: the handshake cannot
    /// succeed, so the run is refused here rather than at the first connect.
    UnreadableTlsCa,
    /// The config file exists but cannot be read (usually permissions).
    ConfigUnreadable,
    /// The config file was read but is not a JSON object.
    ConfigInvalidJson,
    HelpRequested,
};

pub const usage =
    \\Usage: zmrig [options]
    \\
    \\Network:
    \\  -o, --url=URL            pool URL. Schemes: tcp (default), tls, ws, wss -
  \\                           e.g. wss://pool.example.com/monero
    \\  -u, --user=USER          wallet address (login)
\\      --check-wallet=ADDR  verify a Monero address (checksum, network) and exit
\\      --allow-bad-wallet   start anyway if the address fails its checksum
\\                           (rx/0 refuses to start on a bad checksum: the rig
\\                           would mine and never be paid)
    \\  -p, --pass=PASS          password / worker name (default: x)
    \\  -a, --algo=ALGO          rx/0, rx/2, rx/wow, rx/arq, rx/graft, rx/sfx, rx/yada, panthera
    \\                           'auto' advertises all RandomX variants, so a pool that
    \\                           pays the best coin per hash (MoneroOcean) can switch
    \\                           this rig between them instead of leaving it on rx/0
    \\      --rig-id=ID          rig identifier sent to the pool
    \\      --keepalive          send keepalive (default: on)
    \\      --no-keepalive       never send keepalive
    \\      --transport=NAME     tcp | tls | ws | wss, overrides the URL scheme
    \\      --cloudflare[=HOST]  shortcut for wss://HOST:443/ (Cloudflare-friendly)
    \\      --ws-path=PATH       WebSocket path (default /), e.g. /monero/<token>
    \\      --ws-origin=URL      Origin header for the WebSocket upgrade
    \\      --tls                connect with TLS (stratum+ssl:// also works)
    \\      --tls-ca=FILE        trust the certificates in FILE (pin a private CA)
    \\      --tls-insecure       accepted for compatibility; pin with --tls-ca
    \\      --connect-to=HOST[:P] dial this address instead of the pool host
    \\      --proxy=URL          http://user:pass@host:port or socks5://host:port
    \\      --retries=N          reconnect attempts per pool before failover (default: 5)
    \\      --ban-cooldown=N     seconds a pool is left alone after it bans this IP,
    \\                           refuses the wallet, or reports itself full (default: 900)
    \\      --retry-pause=N      seconds between reconnects (default: 5)
    \\      --idle-timeout=N     drop a pool that says nothing for N seconds (0 = never, default 300)
    \\      --scratchpad-prefetch=N  0=nop 1=prefetcht0 (default) 2=prefetchnta 3=load
    \\      --no-optimized-init  use the portable dataset initialiser
    \\      --keepalive-interval=N  send keepalived every N seconds of silence (0 = off, default 60)
    \\
    \\Mining:
    \\  -t, --threads=N          number of mining threads (default: cache aware)
    \\      --mode=MODE          auto | fast (2 GiB dataset) | light (256 MiB cache)
    \\      --randomx-init=N     threads used to build the dataset (default: every CPU)
    \\      --dataset-cache[=MB] keep the old dataset mapped across an algorithm
    \\                           switch (default: auto - as much as fits; 0 = off)
    \\      --no-dataset-cache   always rebuild a dataset after a switch
    \\      --no-huge-pages      disable huge pages
    \\      --auto-hugepages     reserve the pages this mode needs when running as root (default)
    \\      --no-auto-hugepages  never reserve huge pages, even when running as root
    \\      --profile=NAME       auto | free (max hashrate) | watt (max hashrate per watt)
    \\      --no-health-restart  never exit to recover from a stall
    \\      --health-restart=SEC exit after SEC s of stall / all-rejected
    \\                           (default 900; the supervisor restarts it)
    \\      --health-warmup=SEC  do not judge the miner for SEC s (default 180)
    \\      --autotune[=SEC]     measure the thread count here, print the winner, then exit
    \\      --no-huge-pages-jit  disable huge pages for the JIT code
    \\      --msr                apply the RandomX MSR preset (needs root and bare metal)
    \\      --no-msr             do not touch MSR registers (default)
    \\      --no-msr-restore     keep the MSR values after exit (default: restore)
    \\      --randomx-wrmsr, --no-rdmsr   XMRig spellings of the two flags above
    \\      --no-wrmsr           XMRig spelling of --no-msr
    \\      --no-jit             disable the JIT compiler (slow, ~6x lower hashrate)
    \\      --no-affinity        do not pin threads to cores
    \\      --cpu-affinity=0x3   pin threads to these CPUs (bitmask, XMRig style)
    \\      --priority=N         1..5 (XMRig scale) or a raw nice value like -10
    \\      --cpu-priority=N     same as --priority (XMRig spelling)
    \\      --max-temp=C         keep the hottest CPU sensor at or below C degrees:
    \\                           shed threads as it warms, pause above C+15, never
    \\                           go above the thread count you asked for
    \\      --thermal-file=PATH  read the temperature from PATH instead of sysfs
    \\      --no-thermal         disable the governor (same as --max-temp=0)
    \\
    \\Logging:
    \\      --no-color           disable colours
    \\      --verbose            verbose output
    \\      --print-time=N       hashrate report interval in seconds (default: 60, 0 = off)
    \\      --log-file=FILE      append the log to FILE
    \\      --user-agent=UA      User-Agent for WebSocket pool connections
    \\
    \\Monitoring:
    \\      --http-host=HOST     local API bind address (default: 127.0.0.1)
    \\      --http-port=PORT     local monitoring API port (0 = off)
    \\      --http-access-token=T  require "Authorization: Bearer T"
    \\      --host-header=NAME   Host: header for WebSocket upgrades
    \\
    \\Other:
    \\  -c, --config=FILE        JSON config file
    \\      --self-test[=light]  verify the hash engine against known vectors and exit
    \\                           (light skips the 2 GiB dataset check)
    \\      --background         detach from the terminal and keep mining
    \\      --nicehash           mask the nonce for a NiceHash/rental pool
    \\      --donate-level=N     percent of Monero time for the developer (0-10, default 3)
    \\      --no-donate          same as --donate-level=0
    \\      --check              validate the configuration and exit
    \\      --dry-run            alias of --check (XMRig spelling)
    \\      --bench[=HASHES]     benchmark the hash rate and exit
    \\      --report             benchmark for --report-time seconds, print a
    \\                           machine report code for the web dashboard
    \\      --report-time=N      seconds to measure with --report (default: 15)
    \\      --report-file=FILE   keep FILE updated with the report code
    \\      --report-interval=N  seconds between report file updates (60)
    \\      --report-id=NAME     machine name in the report (default: rig-id)
    \\      --power=W            wall power in watts, used by the report
    \\      --verify-share       read {"seed","blob","nonce"} JSON lines on stdin and
    \\                           print the hashes: share verification for a pool
    \\                           (--mode=fast builds the dataset once: 9x faster
    \\                           per share for 2.3 GiB of RAM; -t N hashes N
    \\                           shares at once over that one dataset)
    \\  -h, --help               this help
    \\  -V, --version            print the version
    \\
    \\Every option that takes a value also accepts the "--option value" form.
    \\
;

/// `--max-temp=75` and `--max-temp=75.5`. Out-of-range values are rejected
/// rather than clamped: a target of 20 °C would park the miner for ever, and a
/// target of 150 °C is not a policy, it is a typo.
fn parseTemperature(text: []const u8) ParseError!f32 {
    const value = std.fmt.parseFloat(f32, text) catch return error.InvalidNumber;

    if (!(value >= 45 and value <= 95)) return error.InvalidNumber;

    return value;
}

fn parseNumber(comptime T: type, text: []const u8) ParseError!T {
    return std.fmt.parseInt(T, text, 10) catch error.InvalidNumber;
}

fn needValue(args: []const []const u8, index: *usize, inline_value: ?[]const u8) ParseError![]const u8 {
    if (inline_value) |v| return v;

    index.* += 1;
    if (index.* >= args.len) return error.MissingValue;

    return args[index.*];
}

/// Splits "--opt=value" into the option name and the value.
fn splitArg(arg: []const u8) struct { name: []const u8, value: ?[]const u8 } {
    if (std.mem.indexOfScalar(u8, arg, '=')) |pos| {
        return .{ .name = arg[0..pos], .value = arg[pos + 1 ..] };
    }

    return .{ .name = arg, .value = null };
}

pub fn parseUrl(allocator: std.mem.Allocator, url: []const u8) ParseError!Pool {
    var pool = Pool{};
    var rest = url;
    var scheme_kind: ?transport.Kind = null;

    if (std.mem.indexOf(u8, rest, "://")) |pos| {
        const scheme = rest[0..pos];
        rest = rest[pos + 3 ..];

        if (std.mem.eql(u8, scheme, "stratum+ssl") or std.mem.eql(u8, scheme, "stratum+tls") or std.mem.eql(u8, scheme, "tls")) {
            scheme_kind = .tls;
        } else if (std.mem.eql(u8, scheme, "stratum+ws") or std.mem.eql(u8, scheme, "ws")) {
            scheme_kind = .ws;
        } else if (std.mem.eql(u8, scheme, "stratum+wss") or std.mem.eql(u8, scheme, "wss") or std.mem.eql(u8, scheme, "https")) {
            scheme_kind = .wss;
        } else if (std.mem.eql(u8, scheme, "stratum+tcp") or std.mem.eql(u8, scheme, "stratum") or std.mem.eql(u8, scheme, "tcp") or std.mem.eql(u8, scheme, "http")) {
            // `http://` means a plain WebSocket endpoint in practice; keep it as
            // tcp unless the caller asks for ws explicitly.
            scheme_kind = if (std.mem.eql(u8, scheme, "http")) .ws else .tcp;
        } else {
            return error.InvalidPool;
        }
    }

    // Keep a path for WebSocket endpoints (Cloudflare routes and relays use it).
    if (std.mem.indexOfScalar(u8, rest, '/')) |pos| {
        const path = rest[pos..];
        if (path.len > 1) {
            pool.ws_path = allocator.dupe(u8, path) catch return error.OutOfMemory;
            // A malformed URL must not leak the path we just took ownership of.
            errdefer allocator.free(pool.ws_path.?);
        }
        rest = rest[0..pos];
    }

    var host = rest;
    var port_text: ?[]const u8 = null;

    if (std.mem.startsWith(u8, rest, "[")) {
        const end = std.mem.indexOfScalar(u8, rest, ']') orelse return error.InvalidPool;
        host = rest[1..end];
        if (end + 1 < rest.len and rest[end + 1] == ':') port_text = rest[end + 2 ..];
    } else if (std.mem.lastIndexOfScalar(u8, rest, ':')) |pos| {
        host = rest[0..pos];
        port_text = rest[pos + 1 ..];
    }

    if (host.len == 0) return error.InvalidPool;

    pool.host = allocator.dupe(u8, std.mem.trim(u8, host, "[]")) catch return error.OutOfMemory;
    // "pool:notaport" failed after the host was allocated: free it again.
    errdefer allocator.free(pool.host);

    const kind = scheme_kind orelse .tcp;
    pool.transport = kind;
    pool.user_transport = scheme_kind != null;
    pool.user_port = port_text != null;
    pool.port = if (port_text) |p| parseNumber(u16, p) catch return error.InvalidPool else kind.defaultPort();

    return pool;
}

pub fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) ParseError!Options {
    var opts = Options{};
    // A parse that fails half way has already allocated host names, wallet
    // strings and file paths. Without this, every rejection - a typo in
    // --max-temp, a bad pool URL - leaks what it read before the typo. The
    // process normally exits anyway, which is exactly why nobody noticed.
    errdefer opts.deinit(allocator);
    // Per-pool options seen before the pool they belong to (see `Pending`).
    var pending = Pending{};
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (arg.len == 0) continue;

        if (!std.mem.startsWith(u8, arg, "-")) return error.UnknownOption;

        const split = splitArg(arg);
        const name = split.name;
        const inline_value = split.value;

        if (std.mem.eql(u8, name, "-h") or std.mem.eql(u8, name, "--help")) {
            opts.help = true;
        } else if (std.mem.eql(u8, name, "-V") or std.mem.eql(u8, name, "--version")) {
            opts.version = true;
        } else if (std.mem.eql(u8, name, "-o") or std.mem.eql(u8, name, "--url")) {
            const value = try needValue(args, &i, inline_value);
            var pool = try parseUrl(allocator, value);
            errdefer freePool(allocator, pool);
            try pending.apply(allocator, &pool);
            opts.pools.append(allocator, pool) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, name, "-u") or std.mem.eql(u8, name, "--user")) {
            const value = try needValue(args, &i, inline_value);
            pending.user = value;
            if (opts.pools.items.len > 0) {
                const last = &opts.pools.items[opts.pools.items.len - 1];
                if (last.user.len != 0) allocator.free(last.user);
                last.user = allocator.dupe(u8, value) catch return error.OutOfMemory;
            }
        } else if (std.mem.eql(u8, name, "-p") or std.mem.eql(u8, name, "--pass") or std.mem.eql(u8, name, "--password")) {
            const value = try needValue(args, &i, inline_value);
            pending.password = value;
            if (opts.pools.items.len > 0) {
                const last = &opts.pools.items[opts.pools.items.len - 1];
                if (!std.mem.eql(u8, last.password, "x")) allocator.free(last.password);
                last.password = allocator.dupe(u8, value) catch return error.OutOfMemory;
            }
        } else if (std.mem.eql(u8, name, "-a") or std.mem.eql(u8, name, "--algo")) {
            const value = try needValue(args, &i, inline_value);
            // `auto` is the one value that is not an algorithm name: it is the
            // instruction to advertise all of them.
            if (std.ascii.eqlIgnoreCase(value, "auto")) {
                opts.algo = null;
                opts.algo_all = true;
            } else {
                opts.algo = api.Algo.fromName(value) orelse return error.UnknownOption;
                opts.algo_all = false;
            }
        } else if (std.mem.eql(u8, name, "--rig-id")) {
            const value = try needValue(args, &i, inline_value);
            pending.rig_id = value;
            if (opts.pools.items.len > 0) {
                const last = &opts.pools.items[opts.pools.items.len - 1];
                if (last.rig_id) |id| allocator.free(id);
                last.rig_id = allocator.dupe(u8, value) catch return error.OutOfMemory;
            }
        } else if (std.mem.eql(u8, name, "--keepalive")) {
            pending.keepalive = true;
            if (opts.pools.items.len > 0) opts.pools.items[opts.pools.items.len - 1].keepalive = true;
        } else if (std.mem.eql(u8, name, "--no-keepalive")) {
            pending.keepalive = false;
            if (opts.pools.items.len > 0) opts.pools.items[opts.pools.items.len - 1].keepalive = false;
        } else if (std.mem.eql(u8, name, "--nicehash")) {
            pending.nicehash = true;
            if (opts.pools.items.len > 0) opts.pools.items[opts.pools.items.len - 1].nicehash = true;
        } else if (std.mem.eql(u8, name, "--transport")) {
            const value = try needValue(args, &i, inline_value);
            opts.transport_override = transport.Kind.fromName(value) orelse return error.UnknownOption;
        } else if (std.mem.eql(u8, name, "--cloudflare")) {
            // `--cloudflare=host` is a convenience: it also sets the pool. The
            // space separated form works too, as long as what follows is not
            // another flag (`--cloudflare --ws-path /x` stays a plain preset).
            var value_opt = inline_value;
            if (value_opt == null and i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                i += 1;
                value_opt = args[i];
            }
            // With a host this is a complete shortcut (the pool it creates is
            // already wss on 443), so it must not also rewrite the transport of
            // pools given with -o. Without a host it is a preset for all pools.
            if (value_opt == null) opts.cloudflare = true;
            if (value_opt) |value| {
                const url = if (std.mem.indexOf(u8, value, "://") != null)
                    value
                else
                    try std.fmt.allocPrint(allocator, "wss://{s}", .{value});
                defer if (url.ptr != value.ptr) allocator.free(url);

                var pool = try parseUrl(allocator, url);
                errdefer freePool(allocator, pool);
                try pending.apply(allocator, &pool);
                opts.pools.append(allocator, pool) catch return error.OutOfMemory;
            }
        } else if (std.mem.eql(u8, name, "--ws-path")) {
            const value = try needValue(args, &i, inline_value);
            opts.ws_path = allocator.dupe(u8, value) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, name, "--ws-origin")) {
            const value = try needValue(args, &i, inline_value);
            opts.ws_origin = allocator.dupe(u8, value) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, name, "--host-header")) {
            const value = try needValue(args, &i, inline_value);
            opts.host_header = allocator.dupe(u8, value) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, name, "--connect-to")) {
            const value = try needValue(args, &i, inline_value);
            opts.connect_to = allocator.dupe(u8, value) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, name, "--tls-ca")) {
            const value = try needValue(args, &i, inline_value);
            opts.tls_ca = allocator.dupe(u8, value) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, name, "--proxy")) {
            const value = try needValue(args, &i, inline_value);
            opts.proxy_url = allocator.dupe(u8, value) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, name, "--tls")) {
            // Only the transport: `--tls` must never imply "do not verify"
            // (that flag exists separately and is a no-op right now).
            pending.transport = .tls;
            if (opts.pools.items.len > 0) {
                const last = &opts.pools.items[opts.pools.items.len - 1];
                if (last.transport == .tcp) last.transport = .tls;
                last.user_transport = true;
            }
        } else if (std.mem.eql(u8, name, "--tls-insecure")) {
            pending.tls_insecure = true;
            if (opts.pools.items.len > 0) opts.pools.items[opts.pools.items.len - 1].tls_insecure = true;
        } else if (std.mem.eql(u8, name, "-t") or std.mem.eql(u8, name, "--threads")) {
            opts.threads = try parseNumber(usize, try needValue(args, &i, inline_value));
            opts.seen.threads = true;
        } else if (std.mem.eql(u8, name, "--mode")) {
            const value = try needValue(args, &i, inline_value);
            if (std.mem.eql(u8, value, "auto")) {
                opts.mode = .auto;
            opts.seen.mode = true;
            } else if (std.mem.eql(u8, value, "fast")) {
                opts.mode = .fast;
            opts.seen.mode = true;
            } else if (std.mem.eql(u8, value, "light")) {
                opts.mode = .light;
            opts.seen.mode = true;
            } else {
                return error.UnknownOption;
            }
        } else if (std.mem.eql(u8, name, "--no-huge-pages")) {
            opts.huge_pages = false;
            opts.seen.huge_pages = true;
            // Reserving for pages we will not use would be a pointless root write.
            opts.auto_hugepages = false;
            opts.seen.auto_hugepages = true;
        } else if (std.mem.eql(u8, name, "--msr")) {
            opts.msr = .on;
            opts.seen.msr = true;
        } else if (std.mem.eql(u8, name, "--no-msr")) {
            opts.msr = .off;
            opts.seen.msr = true;
        } else if (std.mem.eql(u8, name, "--no-msr-restore")) {
            opts.msr_restore = false;
            opts.seen.msr_restore = true;
        } else if (std.mem.eql(u8, name, "--no-health-restart")) {
            opts.health_restart = false;
            opts.seen.health_restart = true;
        } else if (std.mem.eql(u8, name, "--health-warmup")) {
            opts.health_warmup_seconds = try parseNumber(u32, try needValue(args, &i, inline_value));
        } else if (std.mem.eql(u8, name, "--health-restart")) {
            // Optional value: "--health-restart" alone re-enables it, with a
            // value it also sets the delay.
            if (inline_value) |value| {
                opts.health_restart_seconds = try parseNumber(u32, value);
            } else {
                opts.health_restart = true;
            }
            opts.seen.health_restart = true;
        } else if (std.mem.eql(u8, name, "--profile")) {
            const value = try needValue(args, &i, inline_value);
            opts.profile = ProfileSetting.fromName(value) orelse return error.UnknownOption;
            opts.seen.profile = true;
        } else if (std.mem.eql(u8, name, "--max-temp")) {
            const value = try needValue(args, &i, inline_value);
            opts.max_temp = try parseTemperature(value);
        } else if (std.mem.eql(u8, name, "--thermal-file")) {
            const value = try needValue(args, &i, inline_value);
            if (opts.thermal_file) |old| allocator.free(old);
            opts.thermal_file = allocator.dupe(u8, value) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, name, "--no-thermal")) {
            opts.max_temp = null;
        } else if (std.mem.eql(u8, name, "--autotune")) {
            opts.autotune = true;
            if (inline_value) |v| {
                opts.autotune_seconds = parseNumber(u32, v) catch return error.InvalidNumber;
                if (opts.autotune_seconds == 0) return error.InvalidNumber;
            }
        } else if (std.mem.eql(u8, name, "--auto-hugepages")) {
            // Only meaningful with huge pages on; --no-huge-pages wins.
            opts.auto_hugepages = opts.huge_pages;
            opts.seen.auto_hugepages = true;
        } else if (std.mem.eql(u8, name, "--no-auto-hugepages")) {
            opts.auto_hugepages = false;
            opts.seen.auto_hugepages = true;
        } else if (std.mem.eql(u8, name, "--no-huge-pages-jit")) {
            opts.huge_pages_jit = false;
            opts.seen.huge_pages_jit = true;
        } else if (std.mem.eql(u8, name, "--no-jit")) {
            opts.jit = false;
            opts.seen.jit = true;
        } else if (std.mem.eql(u8, name, "--cpu-affinity")) {
            // XMRig takes a CPU bitmask: 0x3 means cores 0 and 1.
            const value = try needValue(args, &i, inline_value);
            // Base 0 accepts both "0x3" (XMRig style) and "3".
            opts.affinity_mask = std.fmt.parseInt(u64, value, 0) catch return error.InvalidNumber;
            opts.seen.affinity_mask = true;
        } else if (std.mem.eql(u8, name, "--user-agent")) {
            opts.user_agent = try needValue(args, &i, inline_value);
            opts.seen.user_agent = true;
        } else if (std.mem.eql(u8, name, "--randomx-init")) {
            opts.init_threads = try parseNumber(usize, try needValue(args, &i, inline_value));
            opts.seen.init_threads = true;
        } else if (std.mem.eql(u8, name, "--randomx-wrmsr") or std.mem.eql(u8, name, "--wrmsr")) {
            // XMRig's spelling; `--msr` is ours. `=N` selects a preset, which we
            // do not support, so only the bare form is accepted.
            if (inline_value) |v| {
                if (!std.mem.eql(u8, v, "1")) return error.UnknownOption;
            }
            opts.msr = .on;
        } else if (std.mem.eql(u8, name, "--randomx-no-rdmsr") or std.mem.eql(u8, name, "--no-rdmsr")) {
            opts.msr_restore = false;
        } else if (std.mem.eql(u8, name, "--no-wrmsr")) {
            opts.msr = .off;
        } else if (std.mem.eql(u8, name, "--donate-level")) {
            // Same spelling and meaning as XMRig: percent of mining time that
            // goes to the developer. 0 turns it off entirely.
            const value = try needValue(args, &i, inline_value);
            const level = parseNumber(u32, value) catch return error.InvalidNumber;
            if (level > @import("fee.zig").max_percent) return error.InvalidNumber;
            opts.donate_percent = level;
        } else if (std.mem.eql(u8, name, "--no-donate")) {
            opts.donate_percent = 0;
        } else if (std.mem.eql(u8, name, "--no-affinity")) {
            opts.affinity = false;
            opts.seen.affinity = true;
        } else if (std.mem.eql(u8, name, "--priority") or std.mem.eql(u8, name, "--cpu-priority")) {
            opts.priority = try parseNumber(i32, try needValue(args, &i, inline_value));
            opts.seen.priority = true;
        } else if (std.mem.eql(u8, name, "--no-color")) {
            opts.colors = false;
            opts.seen.colors = true;
        } else if (std.mem.eql(u8, name, "--verbose") or std.mem.eql(u8, name, "-v")) {
            opts.verbose = true;
            opts.seen.verbose = true;
        } else if (std.mem.eql(u8, name, "--print-time")) {
            opts.print_time = try parseNumber(u32, try needValue(args, &i, inline_value));
            opts.seen.print_time = true;
        } else if (std.mem.eql(u8, name, "--retries")) {
            opts.retries = try parseNumber(u32, try needValue(args, &i, inline_value));
            opts.seen.retries = true;
        } else if (std.mem.eql(u8, name, "--ban-cooldown")) {
            opts.ban_cooldown = try parseNumber(u32, try needValue(args, &i, inline_value));
            opts.seen.ban_cooldown = true;
        } else if (std.mem.eql(u8, name, "--scratchpad-prefetch")) {
            opts.scratchpad_prefetch = try parseNumber(i32, try needValue(args, &i, inline_value));
            opts.seen.scratchpad_prefetch = true;
        } else if (std.mem.eql(u8, name, "--no-optimized-init")) {
            opts.optimized_init = false;
            opts.seen.optimized_init = true;
        } else if (std.mem.eql(u8, name, "--dataset-cache")) {
            const text = try needValue(args, &i, inline_value);
            if (std.mem.eql(u8, text, "auto")) {
                opts.dataset_cache_mb = null;
            } else if (std.mem.eql(u8, text, "off") or std.mem.eql(u8, text, "no")) {
                opts.dataset_cache_mb = 0;
            } else {
                opts.dataset_cache_mb = try parseNumber(u64, text);
            }
            opts.seen.dataset_cache = true;
        } else if (std.mem.eql(u8, name, "--no-dataset-cache")) {
            opts.dataset_cache_mb = 0;
            opts.seen.dataset_cache = true;
        } else if (std.mem.eql(u8, name, "--idle-timeout")) {
            opts.idle_timeout = try parseNumber(u32, try needValue(args, &i, inline_value));
            opts.seen.idle_timeout = true;
        } else if (std.mem.eql(u8, name, "--keepalive-interval")) {
            opts.keepalive_interval = try parseNumber(u32, try needValue(args, &i, inline_value));
            opts.seen.keepalive_interval = true;
        } else if (std.mem.eql(u8, name, "--retry-pause")) {
            opts.retry_pause = try parseNumber(u32, try needValue(args, &i, inline_value));
            opts.seen.retry_pause = true;
        } else if (std.mem.eql(u8, name, "--log-file")) {
            opts.log_file = allocator.dupe(u8, try needValue(args, &i, inline_value)) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, name, "--http-host")) {
            opts.http_host = try needValue(args, &i, inline_value);
        } else if (std.mem.eql(u8, name, "--http-port")) {
            opts.api_port = try parseNumber(u16, try needValue(args, &i, inline_value));
        } else if (std.mem.eql(u8, name, "--http-access-token")) {
            opts.api_token = allocator.dupe(u8, try needValue(args, &i, inline_value)) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, name, "-c") or std.mem.eql(u8, name, "--config")) {
            const value = try needValue(args, &i, inline_value);
            opts.config_path = allocator.dupe(u8, value) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, name, "--self-test")) {
            opts.self_test = true;
            // --self-test=light skips the 2 GiB dataset check, which matters
            // when a miner is already holding the huge pages.
            if (inline_value) |v| {
                if (std.mem.eql(u8, v, "light")) {
                    opts.self_test_light = true;
                } else if (!std.mem.eql(u8, v, "full")) {
                    return error.UnknownOption;
                }
            }
        } else if (std.mem.eql(u8, name, "--allow-bad-wallet")) {
            opts.allow_bad_wallet = true;
        } else if (std.mem.eql(u8, name, "--check-wallet")) {
            opts.check_wallet = allocator.dupe(u8, try needValue(args, &i, inline_value)) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, name, "--check") or std.mem.eql(u8, name, "--dry-run")) {
            // --dry-run is XMRig's name for "validate and exit".
            opts.check = true;
        } else if (std.mem.eql(u8, name, "--bench")) {
            opts.benchmark = true;
            if (inline_value) |v| opts.bench_hashes = parseNumber(u64, v) catch return error.InvalidNumber;
        } else if (std.mem.eql(u8, name, "--report")) {
            opts.report = true;
            opts.seen.report = true;
            // `--report=SECONDS` is the shorthand for a custom measurement time.
            if (inline_value) |v| {
                opts.report_seconds = parseNumber(u32, v) catch return error.InvalidNumber;
                opts.seen.report_time = true;
            }
        } else if (std.mem.eql(u8, name, "--report-time")) {
            opts.report_seconds = try parseNumber(u32, try needValue(args, &i, inline_value));
            opts.seen.report_time = true;
        } else if (std.mem.eql(u8, name, "--report-file")) {
            opts.report_file = allocator.dupe(u8, try needValue(args, &i, inline_value)) catch return error.OutOfMemory;
            opts.seen.report_file = true;
        } else if (std.mem.eql(u8, name, "--report-interval")) {
            opts.report_interval = try parseNumber(u32, try needValue(args, &i, inline_value));
            opts.seen.report_interval = true;
        } else if (std.mem.eql(u8, name, "--report-id")) {
            opts.report_id = allocator.dupe(u8, try needValue(args, &i, inline_value)) catch return error.OutOfMemory;
            opts.seen.report_id = true;
        } else if (std.mem.eql(u8, name, "--power")) {
            const value = try needValue(args, &i, inline_value);
            opts.power_watts = std.fmt.parseFloat(f64, value) catch return error.InvalidNumber;
            opts.seen.power = true;
        } else if (std.mem.eql(u8, name, "--background")) {
            opts.background = true;
            opts.seen.background = true;
        } else if (std.mem.eql(u8, name, "--verify-share")) {
            // A pool helper, not a miner: it never touches the network.
            opts.verify_share = true;
        } else {
            return error.UnknownOption;
        }
    }

    // `-o a -o b -u WALLET` must not leave the first pool without a wallet:
    // a user given on the command line is a default for every pool that does
    // not carry one of its own.
    if (pending.user) |value| {
        for (opts.pools.items) |*pool| {
            if (pool.user.len == 0) {
                pool.user = allocator.dupe(u8, value) catch return error.OutOfMemory;
            }
        }
    }

    return opts;
}

pub fn validate(opts: *const Options) ParseError!void {
    // Local actions: they measure or describe the machine, so a pool and a
    // wallet are not part of the question. `--autotune` belongs here too --
    // it used to be rejected with NoPools, which made the one command that
    // helps a fresh box useless on a fresh box.
    if (opts.help or opts.version or opts.self_test or opts.benchmark or
        opts.report or opts.verify_share or opts.autotune or opts.check_wallet != null) return;
    _ = opts.check;

    if (opts.pools.items.len == 0) return error.NoPools;

    for (opts.pools.items) |pool| {
        if (pool.host.len == 0) return error.InvalidPool;
        if (pool.user.len == 0) return error.NoWallet;
    }
}

/// A known key whose value this binary cannot use. It is still ignored - an
/// XMRig config or a file written by an older version has to keep starting -
/// but not silently: `"cpu": {"threads": "8"}` used to mine with the default
/// thread count and the log never mentioned it.
fn warnIgnored(comptime fmt: []const u8, args: anytype) void {
    const stderr = std.io.getStdErr().writer();
    stderr.print("zmrig: warning: " ++ fmt ++ "\n", args) catch {};
}

/// The values that used to be checked only by the code that used them, if at
/// all: an invalid `-t` was reported by the mining core *after* the memory
/// check had already turned it into a dataset size, `--scratchpad-prefetch=7`
/// was accepted and quietly hashed with mode 1, `--priority=99` reached a
/// `setpriority` call the kernel answers with EINVAL and nobody read, and a
/// `--tls-ca` path that did not exist was only noticed when the first TLS
/// handshake failed to build a trust store.
///
/// `--check` is what scripts and `zmrig-os doctor` use to ask "is this
/// configuration usable", so all of it is answered here, once, for both the
/// command line and the config file.
pub fn validateValues(opts: *const Options) ParseError!void {
    if (opts.threads) |threads| {
        if (threads == 0 or threads > max_threads) return error.InvalidThreads;
    }

    if (opts.scratchpad_prefetch < 0 or opts.scratchpad_prefetch > 3) return error.InvalidPrefetch;

    // -1 means "do not touch the scheduler". 1..5 is XMRig's scale, which the
    // mining core maps to a nice value; anything else is a raw nice value and
    // has to be one the kernel will accept.
    if (opts.priority != -1 and !(opts.priority >= 1 and opts.priority <= 5) and
        !(opts.priority >= -20 and opts.priority <= 19)) return error.InvalidPriority;

    for (opts.pools.items) |pool| {
        if (pool.user_port and pool.port == 0) return error.InvalidPoolPort;
    }

    for (opts.pools.items) |pool| {
        if (pool.tls_ca) |path| try checkReadable(path);
    }
    if (opts.tls_ca) |path| try checkReadable(path);
}

fn checkReadable(path: []const u8) ParseError!void {
    const file = std.fs.cwd().openFile(path, .{}) catch return error.UnreadableTlsCa;
    file.close();
}

/// Applies the transport flags to every pool that did not set them itself.
/// Called once after the command line (and the config file) have been read, so
/// `--transport`, `--proxy`, `--cloudflare` and friends work no matter where
/// the pool was defined.
pub fn applyTransportDefaults(allocator: std.mem.Allocator, opts: *Options) ParseError!void {
    // `--transport` is explicit and always wins. `--cloudflare` is a preset:
    // WebSocket + TLS on 443, which is what a Cloudflare-proxied endpoint
    // speaks and what restrictive VPS firewalls allow. Neither overrides a URL
    // that already named its own scheme or port.
    const forced = opts.transport_override;

    for (opts.pools.items) |*pool| {
        if (forced) |kind| {
            pool.transport = kind;
        } else if (opts.cloudflare and !pool.user_transport) {
            pool.transport = .wss;
        }

        if (!pool.user_port) pool.port = pool.transport.defaultPort();

        if (opts.ws_path) |path| {
            if (pool.ws_path == null) pool.ws_path = allocator.dupe(u8, path) catch return error.OutOfMemory;
        }
        if (opts.ws_origin) |origin| {
            if (pool.ws_origin == null) pool.ws_origin = allocator.dupe(u8, origin) catch return error.OutOfMemory;
        }
        if (opts.host_header) |header| {
            if (pool.host_header == null) pool.host_header = allocator.dupe(u8, header) catch return error.OutOfMemory;
        }
        if (opts.tls_ca) |path| {
            if (pool.tls_ca == null) pool.tls_ca = allocator.dupe(u8, path) catch return error.OutOfMemory;
        }

        if (opts.connect_to) |text| {
            if (pool.connect_host == null) {
                var host = text;
                var port: ?u16 = null;

                if (std.mem.lastIndexOfScalar(u8, text, ':')) |pos| {
                    if (std.mem.indexOfScalar(u8, text, ']') == null) {
                        host = text[0..pos];
                        port = parseNumber(u16, text[pos + 1 ..]) catch return error.InvalidPool;
                    }
                }

                pool.connect_host = allocator.dupe(u8, std.mem.trim(u8, host, "[]")) catch return error.OutOfMemory;
                pool.connect_port = port;
            }
        }

        if (pool.proxy_url) |url| {
            pool.proxy_spec = try parseProxy(allocator, url, null);
        } else if (opts.proxy_url) |url| {
            pool.proxy_spec = try parseProxy(allocator, url, &pool.proxy_url);
        }
    }
}

/// `http://user:pass@host:port`, `socks5://host:port`, `socks5h://...`
fn parseProxy(allocator: std.mem.Allocator, url: []const u8, store: ?*?[]const u8) ParseError!transport.Proxy {
    var spec = transport.Proxy{};
    var rest = std.mem.trim(u8, url, " \t");

    if (std.mem.indexOf(u8, rest, "://")) |pos| {
        const scheme = rest[0..pos];
        rest = rest[pos + 3 ..];

        if (std.mem.eql(u8, scheme, "http") or std.mem.eql(u8, scheme, "https") or std.mem.eql(u8, scheme, "connect")) {
            spec.kind = .http;
        } else if (std.mem.eql(u8, scheme, "socks5") or std.mem.eql(u8, scheme, "socks5h") or std.mem.eql(u8, scheme, "socks")) {
            spec.kind = .socks5;
        } else {
            return error.InvalidPool;
        }
    } else {
        spec.kind = .http;
    }

    // credentials
    if (std.mem.lastIndexOfScalar(u8, rest, '@')) |at| {
        const creds = rest[0..at];
        rest = rest[at + 1 ..];

        if (std.mem.indexOfScalar(u8, creds, ':')) |colon| {
            spec.user = allocator.dupe(u8, creds[0..colon]) catch return error.OutOfMemory;
            spec.pass = allocator.dupe(u8, creds[colon + 1 ..]) catch return error.OutOfMemory;
        } else {
            spec.user = allocator.dupe(u8, creds) catch return error.OutOfMemory;
        }
    }

    var host = rest;
    var port: u16 = switch (spec.kind) {
        .socks5 => 1080,
        else => 8080,
    };

    if (std.mem.lastIndexOfScalar(u8, rest, ':')) |pos| {
        host = rest[0..pos];
        port = parseNumber(u16, rest[pos + 1 ..]) catch return error.InvalidPool;
    }

    if (host.len == 0) return error.InvalidPool;

    spec.host = allocator.dupe(u8, std.mem.trim(u8, host, "[]")) catch return error.OutOfMemory;
    spec.port = port;

    if (store) |slot| {
        slot.* = allocator.dupe(u8, url) catch return error.OutOfMemory;
    }

    return spec;
}

// --- config file ---------------------------------------------------------------

fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;

    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn jsonBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;

    return switch (value) {
        .bool => |b| b,
        // Some hand written configs (and our own installer, once) use 1/0.
        .integer => |i| i != 0,
        else => null,
    };
}

fn jsonInt(comptime T: type, obj: std.json.ObjectMap, key: []const u8) ?T {
    const value = obj.get(key) orelse return null;

    return switch (value) {
        .integer => |v| std.math.cast(T, v),
        else => null,
    };
}

/// JSON has one number type and it may arrive as either. `"max-temp": 75` and
/// `"max-temp": 75.5` both have to work, or the installer has to guess which
/// one to write.
fn jsonFloat(obj: std.json.ObjectMap, key: []const u8) ?f32 {
    const value = obj.get(key) orelse return null;

    return switch (value) {
        .integer => |v| @floatFromInt(v),
        .float => |v| @floatCast(v),
        else => null,
    };
}

fn applyPoolObject(allocator: std.mem.Allocator, opts: *Options, obj: std.json.ObjectMap) ParseError!void {
    const url = jsonString(obj, "url") orelse return error.InvalidConfig;
    var pool = try parseUrl(allocator, url);

    if (jsonString(obj, "user")) |user| {
        pool.user = allocator.dupe(u8, user) catch return error.OutOfMemory;
    }
    if (jsonString(obj, "pass")) |pass| {
        pool.password = allocator.dupe(u8, pass) catch return error.OutOfMemory;
    }
    if (jsonString(obj, "rig-id")) |id| {
        pool.rig_id = allocator.dupe(u8, id) catch return error.OutOfMemory;
    }
    if (jsonString(obj, "algo")) |algo| {
        // A pool may say "auto": announce the family for this pool only, which
        // is what the installer writes when it picks the zmrig engine for a
        // pool that pays for more than one coin.
        if (std.ascii.eqlIgnoreCase(algo, "auto")) {
            pool.algo_all = true;
        } else {
            pool.algo = api.Algo.fromName(algo) orelse return error.InvalidConfig;
        }
    }
    if (jsonBool(obj, "tls")) |tls| {
        if (tls) {
            if (pool.transport == .tcp) pool.transport = .tls;
            pool.user_transport = true;
        }
    }
    if (jsonBool(obj, "tls-insecure")) |v| pool.tls_insecure = v;
    if (jsonBool(obj, "keepalive")) |v| pool.keepalive = v;
    if (jsonBool(obj, "nicehash")) |v| pool.nicehash = v;

    if (jsonString(obj, "transport")) |name| {
        pool.transport = transport.Kind.fromName(name) orelse return error.InvalidConfig;
        pool.user_transport = true;
        if (!pool.user_port) pool.port = pool.transport.defaultPort();
    }
    if (jsonString(obj, "ws-path")) |v| pool.ws_path = allocator.dupe(u8, v) catch return error.OutOfMemory;
    if (jsonString(obj, "ws-origin")) |v| pool.ws_origin = allocator.dupe(u8, v) catch return error.OutOfMemory;
    if (jsonString(obj, "host-header")) |v| pool.host_header = allocator.dupe(u8, v) catch return error.OutOfMemory;
    if (jsonString(obj, "connect-to")) |v| {
        var host = v;
        var port: ?u16 = null;
        if (std.mem.lastIndexOfScalar(u8, v, ':')) |pos| {
            host = v[0..pos];
            port = parseNumber(u16, v[pos + 1 ..]) catch return error.InvalidConfig;
        }
        pool.connect_host = allocator.dupe(u8, std.mem.trim(u8, host, "[]")) catch return error.OutOfMemory;
        pool.connect_port = port;
    }
    if (jsonString(obj, "tls-ca")) |v| pool.tls_ca = allocator.dupe(u8, v) catch return error.OutOfMemory;
    if (jsonString(obj, "proxy")) |v| {
        pool.proxy_url = allocator.dupe(u8, v) catch return error.OutOfMemory;
        pool.proxy_spec = try parseProxy(allocator, v, null);
    }

    opts.pools.append(allocator, pool) catch return error.OutOfMemory;
}

/// Reads an XMRig-style JSON config. Only the keys this miner implements are
/// honoured; the rest is ignored so an existing xmrig config keeps working.
pub fn parseConfigFile(allocator: std.mem.Allocator, opts: *Options, path: []const u8) ParseError!void {
    const text = std.fs.cwd().readFileAlloc(allocator, path, 4 * 1024 * 1024) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ConfigUnreadable,
    };
    defer allocator.free(text);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return error.ConfigInvalidJson;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidConfig,
    };

    if (root.get("algo")) |value| {
        if (value == .string) {
            if (std.ascii.eqlIgnoreCase(value.string, "auto")) {
                opts.algo = null;
                opts.algo_all = true;
            } else if (api.Algo.fromName(value.string)) |algo| {
                opts.algo = algo;
                opts.algo_all = false;
            } else {
                // A typo here is expensive and invisible: `"algo": "rx/01"`
                // mined rx/0 on a pool that asked for something else.
                warnIgnored("config: algo \"{s}\" is not one this miner knows; using {s}", .{
                    value.string,
                    if (opts.algo) |a| a.label() else "auto",
                });
                opts.algo_all = false;
            }
        }
    }
    if (jsonInt(u32, root, "print-time")) |v| opts.print_time = v;
    if (jsonInt(u32, root, "retries")) |v| opts.retries = v;
    if (jsonInt(u32, root, "ban-cooldown")) |v| opts.ban_cooldown = v;
    if (jsonInt(u32, root, "retry-pause")) |v| opts.retry_pause = v;
    if (jsonInt(u32, root, "idle-timeout")) |v| opts.idle_timeout = v;
    if (jsonInt(u32, root, "keepalive-interval")) |v| opts.keepalive_interval = v;
    // Written by `oneclick.sh --profile=...`. No `seen` flag: the config is
    // read before the command line, so an explicit `--profile` still wins.
    if (jsonString(root, "profile")) |v| {
        if (ProfileSetting.fromName(v)) |profile| {
            opts.profile = profile;
        } else {
            warnIgnored("config: profile \"{s}\" is not a profile: auto, free or watt; using {s}", .{ v, opts.profile.label() });
        }
    }
    // The thermal policy, as written by `oneclick.sh --max-temp=...` and by the
    // appliance's safe mode. A value outside 45..95 is ignored rather than
    // refused here: a config file that an older binary wrote must not stop the
    // miner from starting.
    if (jsonFloat(root, "max-temp")) |v| {
        opts.max_temp = if (v >= 45 and v <= 95) v else null;
    }
    if (jsonString(root, "thermal-file")) |v| {
        if (opts.thermal_file) |old| allocator.free(old);
        opts.thermal_file = allocator.dupe(u8, v) catch return error.OutOfMemory;
    }
    if (jsonBool(root, "colors")) |v| opts.colors = v;
    if (jsonBool(root, "background")) |v| opts.background = v;
    if (root.get("power")) |value| {
        switch (value) {
            .float => |v| opts.power_watts = v,
            .integer => |v| opts.power_watts = @floatFromInt(v),
            else => {},
        }
    }
    if (root.get("report")) |report_value| {
        if (report_value == .object) {
            const report = report_value.object;
            if (jsonString(report, "file")) |v| opts.report_file = allocator.dupe(u8, v) catch return error.OutOfMemory;
            if (jsonInt(u32, report, "interval")) |v| opts.report_interval = v;
            if (jsonString(report, "id")) |v| opts.report_id = allocator.dupe(u8, v) catch return error.OutOfMemory;

            // `enabled` only gates the report *file*: the standalone
            // `--report` benchmark is a command line action and must never be
            // switched on by a config file (a service would stop mining).
            if (jsonBool(report, "enabled")) |enabled| {
                if (!enabled) {
                    if (opts.report_file) |file| allocator.free(file);
                    opts.report_file = null;
                }
            }
        }
    }
    if (jsonString(root, "log-file")) |v| opts.log_file = allocator.dupe(u8, v) catch return error.OutOfMemory;

    // `"health": {"restart": false}`: the one health rule a user may want to
    // turn off, e.g. on a machine that must stay up whatever happens.
    if (root.get("health")) |health_value| {
        if (health_value == .object) {
            if (jsonBool(health_value.object, "restart")) |v| opts.health_restart = v;
            if (jsonInt(u32, health_value.object, "warmup")) |v| opts.health_warmup_seconds = v;
            if (jsonInt(u32, health_value.object, "restart-seconds")) |v| opts.health_restart_seconds = v;
        }
    }

    // XMRig's schema puts the thread count under `cpu`, and the docs here say
    // so, but `"threads": 8` at the top of the file is the mistake people make
    // - it is silently ignored, which is a rig at half its configured hashrate
    // with nothing anywhere to say why.
    if (root.get("threads")) |top| {
        if (top != .null and root.get("cpu") == null) {
            warnIgnored("config: \"threads\" at the top of the file is not read - it lives under \"cpu\", as {{\"cpu\": {{\"threads\": N}}}}", .{});
        }
    }

    if (root.get("cpu")) |cpu_value| {
        if (cpu_value == .object) {
            const cpu = cpu_value.object;
            if (jsonInt(i32, cpu, "priority")) |v| {
                opts.priority = v;
            } else if (cpu.get("priority") != null and cpu.get("priority").? != .null) {
                warnIgnored("config: cpu.priority must be a number between -20 and 19; leaving the scheduler alone", .{});
            }
            if (jsonBool(cpu, "yield")) |_| {}

            // XMRig writes the mask as an integer, or null for "all cores".
            if (cpu.get("affinity")) |aff| {
                switch (aff) {
                    .integer => |v| opts.affinity_mask = std.math.cast(u64, v),
                    .null => opts.affinity_mask = null,
                    else => {},
                }
            }

            if (cpu.get("huge-pages")) |hp| {
                if (hp == .bool) opts.huge_pages = hp.bool;
            }
            if (jsonBool(cpu, "huge-pages-jit")) |v| opts.huge_pages_jit = v;
            if (jsonBool(cpu, "asm")) |v| opts.jit = v;

            if (cpu.get("threads")) |threads| {
                switch (threads) {
                    .integer => |v| {
                        if (std.math.cast(usize, v)) |count| {
                            opts.threads = count;
                        } else {
                            warnIgnored("config: cpu.threads {d} is not a thread count; using the default", .{v});
                        }
                    },
                    .bool => |enabled| {
                        if (!enabled) opts.threads = 0;
                    },
                    // An array means "explicit per-thread affinity". Non
                    // negative entries become a CPU bitmask; -1 means "any
                    // core", exactly like XMRig's [-1, -1].
                    .array => |arr| {
                        opts.threads = arr.items.len;

                        var mask: u64 = 0;
                        var pinned = false;
                        for (arr.items) |entry| {
                            if (entry != .integer) continue;
                            if (entry.integer < 0) continue;
                            if (entry.integer > 63) continue;

                            mask |= @as(u64, 1) << @intCast(entry.integer);
                            pinned = true;
                        }
                        if (pinned) opts.affinity_mask = mask;
                    },
                    else => warnIgnored("config: cpu.threads must be a number or an array of CPU indexes; using the default (XMRig's own files put the thread count there)", .{}),
                }
            }
        }
    }

    if (root.get("randomx")) |rx_value| {
        if (rx_value == .object) {
            const rx = rx_value.object;
            if (jsonString(rx, "mode")) |mode| {
                if (std.mem.eql(u8, mode, "light")) {
                    opts.mode = .light;
                } else if (std.mem.eql(u8, mode, "fast")) {
                    opts.mode = .fast;
                } else if (std.mem.eql(u8, mode, "auto")) {
                    opts.mode = .auto;
                } else {
                    warnIgnored("config: randomx.mode \"{s}\" is not a mode: auto, fast or light; using auto", .{mode});
                }
            }
            if (jsonInt(usize, rx, "init")) |v| opts.init_threads = v;
            // `true`/`false` is XMRig's spelling and means on/off. The string
            // form exists so a generated config can say what the CLI says:
            // "auto" leaves the decision to the probe, which is the default and
            // the only honest answer for a file that may be copied to another
            // machine.
            switch (rx.get("msr") orelse .null) {
                .bool => |v| opts.msr = if (v) .on else .off,
                .string => |v| opts.msr = if (std.mem.eql(u8, v, "auto"))
                    .auto
                else if (std.mem.eql(u8, v, "off") or std.mem.eql(u8, v, "false"))
                    .off
                else
                    .on,
                else => {},
            }
            if (jsonBool(rx, "rdmsr")) |v| opts.msr_restore = v;
            // `wrmsr` is a bool or an explicit register array in XMRig. We only
            // support the built-in presets, so an array means "use the preset".
            switch (rx.get("wrmsr") orelse .null) {
                .bool => |v| opts.msr = if (v) .on else .off,
                .array => opts.msr = .on,
                else => {},
            }
            if (jsonInt(i32, rx, "scratchpad_prefetch_mode")) |v| {
                opts.scratchpad_prefetch = v;
            } else if (rx.get("scratchpad_prefetch_mode") != null and rx.get("scratchpad_prefetch_mode").? != .null) {
                warnIgnored("config: randomx.scratchpad_prefetch_mode must be 0..3; using 1 (prefetcht0)", .{});
            }
            if (jsonInt(i32, rx, "init-avx2")) |v| opts.optimized_init = v != 0;
        }
    }

    if (root.get("http")) |http_value| {
        if (http_value == .object) {
            const http = http_value.object;
            if (jsonBool(http, "enabled")) |enabled| {
                if (enabled) {
                    if (jsonInt(u16, http, "port")) |port| opts.api_port = port;
                }
            }
            if (jsonString(http, "host")) |host| opts.http_host = host;
            if (jsonString(http, "access-token")) |token| opts.api_token = allocator.dupe(u8, token) catch return error.OutOfMemory;
        }
    }

    if (root.get("pools")) |pools_value| {
        if (pools_value == .array) {
            for (pools_value.array.items) |item| {
                if (item != .object) continue;
                try applyPoolObject(allocator, opts, item.object);
            }
        }
    }
}

// --- tests -----------------------------------------------------------------
//
// The command line is the part of the miner every user touches, and a silent
// change here (a scheme that stops being recognised, a flag that stops being
// applied to the next pool) only shows up as "it connects to the wrong port".

test "pool URLs: schemes, paths and default ports" {
    const testing = std.testing;

    const pool = try parseUrl(testing.allocator, "pool.example.com:3333");
    defer freePool(testing.allocator, pool);
    try testing.expectEqualStrings("pool.example.com", pool.host);
    try testing.expectEqual(@as(u16, 3333), pool.port);
    try testing.expectEqual(transport.Kind.tcp, pool.transport);

    // No port: the scheme decides.
    const tls = try parseUrl(testing.allocator, "stratum+ssl://pool.example.com");
    defer freePool(testing.allocator, tls);
    try testing.expectEqual(transport.Kind.tls, tls.transport);
    try testing.expectEqual(@as(u16, 443), tls.port);

    const wss = try parseUrl(testing.allocator, "wss://pool.example.com/monero/TOKEN");
    defer freePool(testing.allocator, wss);
    try testing.expectEqual(transport.Kind.wss, wss.transport);
    try testing.expectEqual(@as(u16, 443), wss.port);
    try testing.expectEqualStrings("/monero/TOKEN", wss.ws_path.?);

    const ws = try parseUrl(testing.allocator, "ws://relay.example:8080/stratum");
    defer freePool(testing.allocator, ws);
    try testing.expectEqual(transport.Kind.ws, ws.transport);
    try testing.expectEqual(@as(u16, 8080), ws.port);
    try testing.expectEqualStrings("/stratum", ws.ws_path.?);

    // IPv6 literals keep their brackets out of the host, port still parses.
    const v6 = try parseUrl(testing.allocator, "[2001:db8::1]:14444");
    defer freePool(testing.allocator, v6);
    try testing.expectEqualStrings("2001:db8::1", v6.host);
    try testing.expectEqual(@as(u16, 14444), v6.port);

    try testing.expectError(error.InvalidPool, parseUrl(testing.allocator, "gopher://pool"));
    try testing.expectError(error.InvalidPool, parseUrl(testing.allocator, ""));
    try testing.expectError(error.InvalidPool, parseUrl(testing.allocator, "pool:notaport"));
}

test "arguments: order independent, flags apply to the pool they belong to" {
    const testing = std.testing;

    // `-u` before `-o` is what everyone types first, and it used to create a
    // placeholder pool.
    const args = [_][]const u8{
        "-u", "4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge",
        "--rig-id", "rig-1",
        "-o", "pool.example.com:3333",
        "-o", "backup.example.com:443",
        "-t", "3",
        "--retries", "2",
        "--mode", "light",
    };

    var opts = try parseArgs(testing.allocator, &args);
    defer opts.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), opts.pools.items.len);
    try testing.expectEqualStrings("pool.example.com", opts.pools.items[0].host);
    try testing.expectEqualStrings("backup.example.com", opts.pools.items[1].host);
    // The wallet and the rig id apply to *both* pools.
    try testing.expectEqualStrings(args[1], opts.pools.items[1].user);
    try testing.expectEqualStrings("rig-1", opts.pools.items[1].rig_id.?);
    try testing.expectEqual(@as(usize, 3), opts.threads.?);
    try testing.expectEqual(@as(u32, 2), opts.retries);
    try testing.expectEqual(Mode.light, opts.mode);
}

test "arguments: unknown flags and missing values are errors, not silence" {
    const testing = std.testing;

    try testing.expectError(error.UnknownOption, parseArgs(testing.allocator, &[_][]const u8{"--not-a-flag"}));
    try testing.expectError(error.MissingValue, parseArgs(testing.allocator, &[_][]const u8{"-o"}));
}

test "nicehash is a pool flag and survives parsing" {
    const testing = std.testing;

    const args = [_][]const u8{ "-o", "pool.example.com:3333", "--nicehash", "-u", "wallet.rig" };
    var opts = try parseArgs(testing.allocator, &args);
    defer opts.deinit(testing.allocator);

    try testing.expect(opts.pools.items[0].nicehash);
}

test "XMRig-compatible flags are accepted and reach options" {
    const testing = std.testing;

    const args = [_][]const u8{
        "-o",         "pool.example.com:3333",
        "-u",         "wallet",
        "--cpu-priority", "2",
        "--cpu-affinity", "0x3",
        "--randomx-init", "1",
        "--user-agent", "xmrig/6.26.0",
        "--donate-level", "1",
        "--randomx-wrmsr",
        "--randomx-no-rdmsr",
    };

    var opts = try parseArgs(testing.allocator, &args);
    defer opts.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 2), opts.priority);
    try testing.expectEqual(@as(?u64, 0x3), opts.affinity_mask);
    try testing.expectEqual(@as(usize, 1), opts.init_threads);
    try testing.expectEqualStrings("xmrig/6.26.0", opts.user_agent.?);
    // The XMRig flag sets the real fee, it is not decoration.
    try testing.expectEqual(@as(u32, 1), opts.donate_percent);
    try testing.expectEqual(MsrMode.on, opts.msr);
    try testing.expect(!opts.msr_restore);

    // `--donate-level=11` is a typo, not a generous user.
    try testing.expectError(error.InvalidNumber, parseArgs(testing.allocator, &[_][]const u8{ "--donate-level", "11" }));
    // Zero is a real choice, and `--no-donate` is the readable spelling of it.
    {
        var zero = try parseArgs(testing.allocator, &[_][]const u8{ "--donate-level=0" });
        defer zero.deinit(testing.allocator);
        try testing.expectEqual(@as(u32, 0), zero.donate_percent);
    }
    {
        var none = try parseArgs(testing.allocator, &[_][]const u8{"--no-donate"});
        defer none.deinit(testing.allocator);
        try testing.expectEqual(@as(u32, 0), none.donate_percent);
    }
}

test "affinity masks select the CPUs the threads are pinned to" {
    const testing = std.testing;

    // cpuFor lives in miner.zig, but the bit walk is what --check reports.
    try testing.expectEqual(@as(usize, 2), @popCount(@as(u64, 0x3)));
    try testing.expectEqual(@as(usize, 1), @popCount(@as(u64, 0x8)));
}

test "an xmrig config.json is read with the keys it uses" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "config.json", .data = 
        \\{"cpu":{"affinity":3,"priority":2,"huge-pages":true},
        \\ "randomx":{"mode":"light","init":1,"wrmsr":false,"rdmsr":false,
        \\            "scratchpad_prefetch_mode":2,"init-avx2":0},
        \\ "pools":[{"url":"pool.example.com:3333","user":"wallet"}]}
    });

    const path = try tmp.dir.realpathAlloc(testing.allocator, "config.json");
    defer testing.allocator.free(path);

    var opts = Options{};
    defer opts.deinit(testing.allocator);

    try parseConfigFile(testing.allocator, &opts, path);

    try testing.expectEqual(@as(?u64, 3), opts.affinity_mask);
    try testing.expectEqual(@as(i32, 2), opts.priority);
    try testing.expectEqual(Mode.light, opts.mode);
    try testing.expectEqual(@as(usize, 1), opts.init_threads);
    try testing.expectEqual(@as(i32, 2), opts.scratchpad_prefetch);
    try testing.expect(!opts.optimized_init);
    // `"msr": false` in the config is an instruction, not the default: the
    // default is `auto`, and a config that says false must not be upgraded back
    // to `auto` behind the user's back.
    try testing.expectEqual(MsrMode.off, opts.msr);
    try testing.expect(!opts.msr_restore);
    try testing.expectEqual(@as(usize, 1), opts.pools.items.len);
    try testing.expectEqualStrings("wallet", opts.pools.items[0].user);
}

test "proxy URLs: http and socks5, with credentials, defaults and junk" {
    const testing = std.testing;

    const http = try parseProxy(testing.allocator, "http://user:p%40ss@proxy.example:8080", null);
    defer testing.allocator.free(http.host);
    defer if (http.user) |v| testing.allocator.free(v);
    defer if (http.pass) |v| testing.allocator.free(v);

    try testing.expectEqual(transport.ProxyKind.http, http.kind);
    try testing.expectEqualStrings("proxy.example", http.host);
    try testing.expectEqual(@as(u16, 8080), http.port);
    try testing.expectEqualStrings("user", http.user.?);

    // No port on a socks5 proxy means 1080, not 8080.
    const socks = try parseProxy(testing.allocator, "socks5://127.0.0.1", null);
    defer testing.allocator.free(socks.host);
    try testing.expectEqual(transport.ProxyKind.socks5, socks.kind);
    try testing.expectEqual(@as(u16, 1080), socks.port);

    // A bare "host:port" is an HTTP proxy, like in XMRig.
    const bare = try parseProxy(testing.allocator, "proxy.example:3128", null);
    defer testing.allocator.free(bare.host);
    try testing.expectEqual(transport.ProxyKind.http, bare.kind);
    try testing.expectEqual(@as(u16, 3128), bare.port);

    try testing.expectError(error.InvalidPool, parseProxy(testing.allocator, "ftp://proxy.example:21", null));
    try testing.expectError(error.InvalidPool, parseProxy(testing.allocator, "socks5://", null));
}

test "an explicit thread array becomes a cpu mask, -1 means anywhere" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "pinned.json", .data = 
        \\{"cpu":{"threads":[0,2]},"pools":[{"url":"pool.example.com:3333","user":"w"}]}
    });
    try tmp.dir.writeFile(.{ .sub_path = "any.json", .data = 
        \\{"cpu":{"threads":[-1,-1]},"pools":[{"url":"pool.example.com:3333","user":"w"}]}
    });

    var pinned = Options{};
    defer pinned.deinit(testing.allocator);
    const pinned_path = try tmp.dir.realpathAlloc(testing.allocator, "pinned.json");
    defer testing.allocator.free(pinned_path);
    try parseConfigFile(testing.allocator, &pinned, pinned_path);

    try testing.expectEqual(@as(usize, 2), pinned.threads.?);
    try testing.expectEqual(@as(?u64, 0x5), pinned.affinity_mask);

    var any = Options{};
    defer any.deinit(testing.allocator);
    const any_path = try tmp.dir.realpathAlloc(testing.allocator, "any.json");
    defer testing.allocator.free(any_path);
    try parseConfigFile(testing.allocator, &any, any_path);

    try testing.expectEqual(@as(usize, 2), any.threads.?);
    try testing.expectEqual(@as(?u64, null), any.affinity_mask);
}

test "a pool may advertise the RandomX family on its own" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // What the installer writes for a pool that pays for several coins.
    try tmp.dir.writeFile(.{ .sub_path = "auto.json", .data =
        \\{"pools":[{"url":"pool.example.com:3333","user":"w","algo":"auto"}]}
    });
    // A pin still pins, and is not turned into the family.
    try tmp.dir.writeFile(.{ .sub_path = "pin.json", .data =
        \\{"pools":[{"url":"pool.example.com:3333","user":"w","algo":"rx/wow"}]}
    });

    var auto = Options{};
    defer auto.deinit(testing.allocator);
    const auto_path = try tmp.dir.realpathAlloc(testing.allocator, "auto.json");
    defer testing.allocator.free(auto_path);
    try parseConfigFile(testing.allocator, &auto, auto_path);

    const auto_pool = &auto.pools.items[0];
    try testing.expect(auto_pool.algo_all);
    try testing.expectEqual(@as(?api.Algo, null), auto_pool.algo);

    var buf: [api.auto_algos.len]api.Algo = undefined;
    const algos = auto.loginAlgos(auto_pool, &buf);
    try testing.expectEqual(api.auto_algos.len, algos.len);
    try testing.expectEqualStrings("panthera", algos[algos.len - 1].label());

    // The pool-level auto must not leak into an explicit --algo pin.
    var pinned = Options{ .algo_all = false };
    defer pinned.deinit(testing.allocator);
    const pin_path = try tmp.dir.realpathAlloc(testing.allocator, "pin.json");
    defer testing.allocator.free(pin_path);
    try parseConfigFile(testing.allocator, &pinned, pin_path);

    const pin_pool = &pinned.pools.items[0];
    try testing.expect(!pin_pool.algo_all);
    const pinned_list = pinned.loginAlgos(pin_pool, &buf);
    try testing.expectEqual(@as(usize, 1), pinned_list.len);
    try testing.expectEqualStrings("rx/wow", pinned_list[0].label());
}

test "the installer's profile key is read from the config file" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "config.json", .data = 
        \\{"profile":"watt","pools":[{"url":"pool.example.com:3333","user":"w"}]}
    });

    var opts = Options{};
    defer opts.deinit(testing.allocator);
    const path = try tmp.dir.realpathAlloc(testing.allocator, "config.json");
    defer testing.allocator.free(path);
    try parseConfigFile(testing.allocator, &opts, path);

    try testing.expectEqual(ProfileSetting.watt, opts.profile);

    // An unknown value in the file is ignored instead of becoming an error: a
    // newer config must not stop an older binary from mining.
    var tmp2 = testing.tmpDir(.{});
    defer tmp2.cleanup();
    try tmp2.dir.writeFile(.{ .sub_path = "config.json", .data = 
        \\{"profile":"turbo","pools":[{"url":"pool.example.com:3333","user":"w"}]}
    });

    var other = Options{};
    defer other.deinit(testing.allocator);
    const path2 = try tmp2.dir.realpathAlloc(testing.allocator, "config.json");
    defer testing.allocator.free(path2);
    try parseConfigFile(testing.allocator, &other, path2);

    try testing.expectEqual(ProfileSetting.auto, other.profile);
}

test "an autotune run needs no pool: it measures the machine" {
    const testing = std.testing;

    // `--autotune` used to be rejected with NoPools, which made the one
    // command that helps a fresh box useless on a fresh box.
    var argv = [_][]const u8{ "--autotune=5" };
    var opts = try parseArgs(testing.allocator, &argv);
    defer opts.deinit(testing.allocator);

    try testing.expect(opts.autotune);
    try testing.expectEqual(@as(u32, 5), opts.autotune_seconds);
    try validate(&opts);

    // ...while a real mining run still refuses to start without a pool.
    var plain = Options{};
    defer plain.deinit(testing.allocator);
    try testing.expectError(error.NoPools, validate(&plain));
}

test "--profile is parsed and a bad name is rejected" {
    const testing = std.testing;

    var argv = [_][]const u8{ "--profile=watt" };
    var opts = try parseArgs(testing.allocator, &argv);
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(ProfileSetting.watt, opts.profile);

    var bad = [_][]const u8{ "--profile=turbo" };
    try testing.expectError(error.UnknownOption, parseArgs(testing.allocator, &bad));
}

test "the health block in the config is honoured" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "config.json", .data = 
        \\{"health":{"restart":false,"warmup":30},"pools":[{"url":"pool.example.com:3333","user":"w"}]}
    });

    var opts = Options{};
    defer opts.deinit(testing.allocator);
    const path = try tmp.dir.realpathAlloc(testing.allocator, "config.json");
    defer testing.allocator.free(path);
    try parseConfigFile(testing.allocator, &opts, path);

    // A machine that must stay up whatever happens is a real requirement.
    try testing.expect(!opts.health_restart);
    try testing.expectEqual(@as(u32, 30), opts.health_warmup_seconds);
    // Untouched keys keep their defaults.
    try testing.expectEqual(@as(u32, 900), opts.health_restart_seconds);
}

test "algo: pinned, auto, and the default are three different logins" {
    const testing = std.testing;
    const wallet = "4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge";
    var buf: [api.auto_algos.len]api.Algo = undefined;

    // Default: announce nothing, the pool keeps deciding. This is what every
    // existing configuration does and it must not change.
    {
        const args = [_][]const u8{ "-u", wallet, "-o", "pool.example.com:3333" };
        var opts = try parseArgs(testing.allocator, &args);
        defer opts.deinit(testing.allocator);

        try testing.expect(!opts.algo_all);
        try testing.expectEqual(@as(usize, 0), opts.loginAlgos(&opts.pools.items[0], &buf).len);
    }

    // --algo=auto: the whole RandomX family, in a stable order.
    {
        const args = [_][]const u8{ "-u", wallet, "-o", "pool.example.com:3333", "--algo=auto" };
        var opts = try parseArgs(testing.allocator, &args);
        defer opts.deinit(testing.allocator);

        try testing.expect(opts.algo_all);
        try testing.expectEqual(@as(?api.Algo, null), opts.algo);

        const list = opts.loginAlgos(&opts.pools.items[0], &buf);
        try testing.expectEqual(api.auto_algos.len, list.len);
        try testing.expectEqual(api.Algo.rx_0, list[0]);
        try testing.expectEqual(api.Algo.rx_wow, list[1]);
        // Never advertise rx/2: its parameters differ per pool fork.
        for (list) |algo| try testing.expect(algo != .rx_2);
    }

    // -a rx/wow: one entry, and it wins over auto. A pin is a promise.
    {
        const args = [_][]const u8{ "-u", wallet, "-o", "pool.example.com:3333", "-a", "rx/wow" };
        var opts = try parseArgs(testing.allocator, &args);
        defer opts.deinit(testing.allocator);

        const list = opts.loginAlgos(&opts.pools.items[0], &buf);
        try testing.expectEqual(@as(usize, 1), list.len);
        try testing.expectEqual(api.Algo.rx_wow, list[0]);
    }

    // A typo is an error, not a silent rx/0. The bad flag comes *first*: parseArgs
    // leaves a half-built Options behind when it fails, and a test that leaks is
    // a test that teaches the wrong pattern.
    {
        const args = [_][]const u8{ "-a", "rx/typo" };
        try testing.expectError(error.UnknownOption, parseArgs(testing.allocator, &args));
    }
}

test "algo: auto is also readable from the JSON config" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "config.json",
        .data =
        \\{"algo":"auto","pools":[{"url":"pool.example.com:3333","user":"WALLET"}]}
        ,
    });

    // The wallet has to be a real one for the pool to be accepted.
    const path = try tmp.dir.realpathAlloc(testing.allocator, "config.json");
    defer testing.allocator.free(path);

    var opts = Options{};
    defer opts.deinit(testing.allocator);

    try parseConfigFile(testing.allocator, &opts, path);

    try testing.expect(opts.algo_all);

    var buf: [api.auto_algos.len]api.Algo = undefined;
    try testing.expectEqual(api.auto_algos.len, opts.loginAlgos(&opts.pools.items[0], &buf).len);

    // An explicit algorithm in the same key turns auto back off: the two are
    // one setting, not two that can both be true.
    try tmp.dir.writeFile(.{
        .sub_path = "pinned.json",
        .data =
        \\{"algo":"rx/wow","pools":[{"url":"pool.example.com:3333","user":"W"}]}
        ,
    });

    const pinned_path = try tmp.dir.realpathAlloc(testing.allocator, "pinned.json");
    defer testing.allocator.free(pinned_path);

    var pinned = Options{};
    defer pinned.deinit(testing.allocator);
    try parseConfigFile(testing.allocator, &pinned, pinned_path);

    try testing.expect(!pinned.algo_all);
    try testing.expectEqual(@as(?api.Algo, .rx_wow), pinned.algo);
}

test "--max-temp is a temperature, not a wish" {
    const testing = std.testing;
    const ok = [_][]const u8{ "-u", "w", "-o", "pool.example.com:3333" };

    // 75 and 75.5 are both temperatures; 20 and 150 are a typo that would park
    // the miner for ever or protect nothing.
    var args: [6][]const u8 = undefined;
    @memcpy(args[0..4], &ok);

    args[4] = "--max-temp=75";
    args[5] = "--threads=2";
    var opts = try parseArgs(testing.allocator, &args);
    defer opts.deinit(testing.allocator);
    try testing.expectEqual(@as(f32, 75), opts.max_temp.?);

    args[4] = "--max-temp=75.5";
    var half = try parseArgs(testing.allocator, &args);
    defer half.deinit(testing.allocator);
    try testing.expectEqual(@as(f32, 75.5), half.max_temp.?);

    // The floor and the ceiling of what counts as a policy.
    args[4] = "--max-temp=45";
    var low = try parseArgs(testing.allocator, &args);
    defer low.deinit(testing.allocator);
    try testing.expectEqual(@as(f32, 45), low.max_temp.?);

    args[4] = "--max-temp=44.9";
    try testing.expectError(error.InvalidNumber, parseArgs(testing.allocator, &args));
    args[4] = "--max-temp=95.1";
    try testing.expectError(error.InvalidNumber, parseArgs(testing.allocator, &args));
    args[4] = "--max-temp=warm";
    try testing.expectError(error.InvalidNumber, parseArgs(testing.allocator, &args));
}

test "no --max-temp means no governor, and --no-thermal undoes one" {
    const testing = std.testing;

    var plain = try parseArgs(testing.allocator, &[_][]const u8{ "-u", "w", "-o", "pool.example.com:3333" });
    defer plain.deinit(testing.allocator);
    try testing.expect(plain.max_temp == null);

    var undone = try parseArgs(testing.allocator, &[_][]const u8{
        "-u", "w", "-o", "pool.example.com:3333", "--max-temp=70", "--no-thermal",
    });
    defer undone.deinit(testing.allocator);
    try testing.expect(undone.max_temp == null);
}

test "--thermal-file keeps its own copy of the path" {
    const testing = std.testing;
    const source = "sensors/cpu0";

    var opts = try parseArgs(testing.allocator, &[_][]const u8{
        "-u", "w", "-o", "pool.example.com:3333", "--thermal-file", source,
    });
    defer opts.deinit(testing.allocator);

    try testing.expectEqualStrings(source, opts.thermal_file.?);
    // Not the same slice: the argv it came from may not outlive the options.
    try testing.expect(opts.thermal_file.?.ptr != source.ptr);
}

test "the thermal policy is read from the config file, and a silly one is ignored" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "safe.json", .data =
        \\{"max-temp":72,"thermal-file":"/run/cpu.temp","pools":[{"url":"pool.example.com:3333","user":"w"}]}
    });
    try tmp.dir.writeFile(.{ .sub_path = "silly.json", .data =
        \\{"max-temp":12,"pools":[{"url":"pool.example.com:3333","user":"w"}]}
    });

    var safe = Options{};
    defer safe.deinit(testing.allocator);
    const safe_path = try tmp.dir.realpathAlloc(testing.allocator, "safe.json");
    defer testing.allocator.free(safe_path);
    try parseConfigFile(testing.allocator, &safe, safe_path);

    try testing.expectEqual(@as(f32, 72), safe.max_temp.?);
    try testing.expectEqualStrings("/run/cpu.temp", safe.thermal_file.?);

    var silly = Options{};
    defer silly.deinit(testing.allocator);
    const silly_path = try tmp.dir.realpathAlloc(testing.allocator, "silly.json");
    defer testing.allocator.free(silly_path);
    try parseConfigFile(testing.allocator, &silly, silly_path);

    try testing.expect(silly.max_temp == null);
}

test "the values that used to be refused late are refused by --check" {
    const testing = std.testing;
    // `--check` is what a provisioning script and `zmrig-os doctor` ask.
    // Every one of these exited 0 from `--check` and then failed (or was
    // ignored) at run time, which is the worst of both: the check said the
    // configuration was fine.
    var opts = Options{};
    // The pool below points at string literals, so only the array is ours.
    defer opts.pools.deinit(testing.allocator);

    opts.pools.append(testing.allocator, .{ .host = "pool.example", .port = 3333, .user = "x" }) catch unreachable;

    opts.threads = 0;
    try testing.expectError(error.InvalidThreads, validateValues(&opts));
    opts.threads = max_threads + 1;
    try testing.expectError(error.InvalidThreads, validateValues(&opts));
    opts.threads = max_threads;
    try validateValues(&opts);

    opts.scratchpad_prefetch = 7;
    try testing.expectError(error.InvalidPrefetch, validateValues(&opts));
    opts.scratchpad_prefetch = -1;
    try testing.expectError(error.InvalidPrefetch, validateValues(&opts));
    opts.scratchpad_prefetch = 3;
    try validateValues(&opts);

    // 1..5 is XMRig's scale, a raw nice value is -20..19, -1 is "leave it".
    opts.priority = 99;
    try testing.expectError(error.InvalidPriority, validateValues(&opts));
    opts.priority = -21;
    try testing.expectError(error.InvalidPriority, validateValues(&opts));
    for ([_]i32{ -1, 0, 5, -20, 19 }) |p| {
        opts.priority = p;
        try validateValues(&opts);
    }

    opts.pools.items[0].user_port = true;
    opts.pools.items[0].port = 0;
    try testing.expectError(error.InvalidPoolPort, validateValues(&opts));
    opts.pools.items[0].port = 3333;
    try validateValues(&opts);

    opts.pools.items[0].tls_ca = "/nonexistent/ca.pem";
    try testing.expectError(error.UnreadableTlsCa, validateValues(&opts));
}

test "a thread count in the wrong place is reported" {
    const testing = std.testing;
    // `"threads": 8` at the top of the file, which is not where this miner (or
    // XMRig) reads it: the rig then ran at the default count in silence.
    const path = "zig-cache-test-top-level-threads.json";
    const text =
        \\{"pools":[{"url":"pool.example:3333","user":"x"}],"threads":8}
    ;
    {
        const file = std.fs.cwd().createFile(path, .{}) catch unreachable;
        defer file.close();
        file.writeAll(text) catch unreachable;
    }
    defer std.fs.cwd().deleteFile(path) catch {};

    var opts = Options{};
    defer opts.deinit(testing.allocator);

    try parseConfigFile(testing.allocator, &opts, path);

    try testing.expectEqual(@as(?usize, null), opts.threads);

    // The spelling that works is the one the docs and XMRig use.
    const good_path = "zig-cache-test-cpu-threads.json";
    const good_text =
        \\{"pools":[{"url":"pool.example:3333","user":"x"}],"cpu":{"threads":8}}
    ;
    {
        const file = std.fs.cwd().createFile(good_path, .{}) catch unreachable;
        defer file.close();
        file.writeAll(good_text) catch unreachable;
    }
    defer std.fs.cwd().deleteFile(good_path) catch {};

    var pinned = Options{};
    defer pinned.deinit(testing.allocator);

    try parseConfigFile(testing.allocator, &pinned, good_path);

    try testing.expectEqual(@as(?usize, 8), pinned.threads);
}

test "a config value this binary cannot use is reported, not silently dropped" {
    const testing = std.testing;
    // `"threads": "8"` used to mine with the default count and say nothing.
    const path = "zig-cache-test-warn-config.json";
    const text =
        \\{"pools":[{"url":"pool.example:3333","user":"x"}],
        \\ "cpu":{"threads":"8","priority":"high"},
        \\ "algo":"rx/01","profile":"turbo",
        \\ "randomx":{"mode":"quick","scratchpad_prefetch_mode":"two"}}
    ;
    {
        const file = std.fs.cwd().createFile(path, .{}) catch unreachable;
        defer file.close();
        file.writeAll(text) catch unreachable;
    }
    defer std.fs.cwd().deleteFile(path) catch {};

    var opts = Options{};
    defer opts.deinit(testing.allocator);

    try parseConfigFile(testing.allocator, &opts, path);

    // Nothing was applied, and nothing was invented either: the defaults stand.
    try testing.expectEqual(@as(?usize, null), opts.threads);
    try testing.expectEqual(@as(?api.Algo, null), opts.algo);
    try testing.expectEqual(ProfileSetting.auto, opts.profile);
    try testing.expectEqual(Mode.auto, opts.mode);
    try testing.expectEqual(@as(i32, 1), opts.scratchpad_prefetch);
    try testing.expectEqual(@as(i32, -1), opts.priority);
}

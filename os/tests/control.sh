#!/usr/bin/env bash
#
# control.sh - tests for `zmrig-os`, the appliance control tool.
#
#   ./os/tests/control.sh
#
# Runs without root and without a real image: ZMRIG_OS_ROOT points the tool at a
# temporary directory, which is the same switch the tool itself supports for
# this purpose. Nothing here needs a miner, a kernel or a network.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${0}")/../.." && pwd)
TOOL="${ROOT}/os/overlay/usr/local/bin/zmrig-os"
PASS=0
FAIL=0

# A real Monero address, used because the validator must accept exactly this
# shape. It is the developer wallet, which is public.
WALLET="46SQLW7DXaq6GJaQbHUFMAhd1VYpfQFJQ2gfZo9TCB8bf9vnf1MUwAD2Fwj6KMsY4RU3oKA3x6hByg8BKg7FfMWn6ysb5tJ"

ok()   { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*"; }

check() { # description, command...
    local what="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi
}

CHECK_MSG=""   # set by expect_*

expect_ok() { # description, command...
    local what="$1"; shift
    local out
    if out=$("$@" 2>&1); then ok "$what"; else bad "$what"; fi
    CHECK_MSG="$out"
}

expect_fail() { # description, command...
    local what="$1"; shift
    local out
    if out=$("$@" 2>&1); then bad "$what (it succeeded)"; else ok "$what"; fi
    CHECK_MSG="$out"
}

contains() { # needle, haystack
    case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac
}

newroot() {
    ROOTDIR=$(mktemp -d)
    mkdir -p "$ROOTDIR/etc/zmrig" "$ROOTDIR/usr/local/bin" "$ROOTDIR/run/zmrig" "$ROOTDIR/var/log"
    export ZMRIG_OS_ROOT="$ROOTDIR"
    export ZMRIG_OS_DRYRUN=1
}

rmroot() { [ -n "${ROOTDIR:-}" ] && rm -rf "$ROOTDIR"; ROOTDIR=""; }

printf '\nzmrig-os control tests\n\n'

# ---------------------------------------------------------------- basics
newroot
expect_ok "version prints the image version" "$TOOL" version
contains "ZMRIG OS" "$CHECK_MSG" && ok "version mentions the product" || bad "version mentions the product"

expect_ok "help prints usage" "$TOOL" help
contains "zmrig-os setup" "$CHECK_MSG" && ok "help documents setup" || bad "help documents setup"

expect_fail "unknown command is refused" "$TOOL" nonsense

# ---------------------------------------------------------------- wallet
expect_ok "a real Monero address is accepted" "$TOOL" setup --wallet "$WALLET" --pool pool.example.com:10001
contains 'WALLET="46SQLW7D' "$(cat "$ROOTDIR/etc/zmrig/os.conf" 2>/dev/null)" &&
    ok "the wallet reaches os.conf" || bad "the wallet reaches os.conf"

expect_fail "a short address is refused" "$TOOL" setup --wallet "46SQLW7DXaq6GJaQbHUFMAhd1VYpfQFJQ2gfZo9TCB8bf9vnf1MUwAD2Fwj6KMsY4RU3oKA3x6hByg8BKg7FfMWn6ys"
expect_fail "a base58-illegal character is refused" "$TOOL" setup --wallet "0SQLW7DXaq6GJaQbHUFMAhd1VYpfQFJQ2gfZo9TCB8bf9vnf1MUwAD2Fwj6KMsY4RU3oKA3x6hByg8BKg7FfMWn6ysb5tJ"
expect_fail "a wrong leading character is refused" "$TOOL" setup --wallet "9SQLW7DXaq6GJaQbHUFMAhd1VYpfQFJQ2gfZo9TCB8bf9vnf1MUwAD2Fwj6KMsY4RU3oKA3x6hByg8BKg7FfMWn6ysb5tJ"
expect_fail "an unknown mode is refused" "$TOOL" setup --wallet "$WALLET" --mode turbo
expect_fail "a donat* typo is not silently accepted" "$TOOL" setup --wallet "$WALLET" --donate-level 5

# ---------------------------------------------------------------- arguments
expect_ok "args builds a command line" "$TOOL" args
ARGS="$CHECK_MSG"

contains "-o pool.example.com:10001" "$ARGS" && ok "args carries the pool" || bad "args carries the pool"
contains "-u $WALLET" "$ARGS" && ok "args carries the wallet" || bad "args carries the wallet"
contains "--donate-level 1" "$ARGS" && ok "args keeps the 1 % fee visible" || bad "args keeps the 1 % fee visible"
contains "--profile free" "$ARGS" && ok "max mode asks for the free profile" || bad "max mode asks for the free profile"
contains "--msr" "$ARGS" && bad "msr is enabled without hardware (sandbox has no /dev/cpu/0/msr)" || ok "msr stays off where it cannot work"
contains "--log-file" "$ARGS" && ok "args keeps a log file" || bad "args keeps a log file"

"$TOOL" mode eco >/dev/null 2>&1
expect_ok "eco mode rebuilds the command line" "$TOOL" args
contains "--profile watt" "$CHECK_MSG" && ok "eco uses the watt profile" || bad "eco uses the watt profile"
contains "--priority 1" "$CHECK_MSG" && ok "eco lowers the priority" || bad "eco lowers the priority"

"$TOOL" mode light >/dev/null 2>&1
expect_ok "light mode rebuilds the command line" "$TOOL" args
contains "--mode light" "$CHECK_MSG" && ok "light keeps the 256 MB cache" || bad "light keeps the 256 MB cache"

"$TOOL" mode max >/dev/null 2>&1
expect_ok "max mode restores the free profile" "$TOOL" args
contains "--priority 5" "$CHECK_MSG" && ok "max raises the priority" || bad "max raises the priority"

expect_fail "an unknown mode is refused by 'mode'" "$TOOL" mode turbo

# --- safe mode --------------------------------------------------------------
"$TOOL" mode safe >/dev/null 2>&1
expect_ok "safe mode builds a command line" "$TOOL" args
contains "--max-temp 72" "$CHECK_MSG" && ok "safe arms the thermal governor at 72 C" || bad "safe arms the thermal governor at 72 C"
contains "--profile watt" "$CHECK_MSG" && ok "safe uses the watt profile" || bad "safe uses the watt profile"
contains "--priority 19" "$CHECK_MSG" && ok "safe runs at the lowest priority" || bad "safe runs at the lowest priority"
contains "--no-msr" "$CHECK_MSG" && ok "safe never writes hardware registers" || bad "safe never writes hardware registers"

"$TOOL" mode safe 65 >/dev/null 2>&1
expect_ok "safe mode takes a temperature" "$TOOL" args
contains "--max-temp 65" "$CHECK_MSG" && ok "the temperature reaches the miner" || bad "the temperature reaches the miner"

expect_fail "a temperature below the floor is refused" "$TOOL" mode safe 30
expect_fail "a temperature above the ceiling is refused" "$TOOL" mode safe 120
expect_fail "a temperature that is not a number is refused" "$TOOL" mode safe warm

"$TOOL" mode safe 72 >/dev/null 2>&1

# `status` has to show the number the governor is working from, and say so when
# there is no sensor instead of printing a plausible 0 C.
expect_ok "status prints the thermal line" "$TOOL" status
contains "thermal" "$CHECK_MSG" && ok "status has a thermal line" || bad "status has a thermal line"
case "$CHECK_MSG" in
    *"no sensor in /sys"*|*" C"*) ok "the thermal line is a reading or an honest absence" ;;
    *) bad "the thermal line is a reading or an honest absence" ;;
esac

# The fee switch: `setup --donate 0` has to reach the miner's own flag.
"$TOOL" setup --wallet "$WALLET" --donate 0 >/dev/null 2>&1
expect_ok "args after turning the fee off" "$TOOL" args
contains "--donate-level 0" "$CHECK_MSG" && ok "--donate 0 turns the fee off" || bad "--donate 0 turns the fee off"
"$TOOL" setup --wallet "$WALLET" --donate 3 >/dev/null 2>&1
expect_ok "args after raising the fee" "$TOOL" args
contains "--donate-level 3" "$CHECK_MSG" && ok "--donate 3 sets a 3 % rate" || bad "--donate 3 sets a 3 % rate"
"$TOOL" setup --wallet "$WALLET" >/dev/null 2>&1

# A pinned thread count has to survive into the command line.
"$TOOL" setup --wallet "$WALLET" --threads 3 >/dev/null 2>&1
expect_ok "args after pinning threads" "$TOOL" args
contains "-t 3" "$CHECK_MSG" && ok "-t 3 reaches the command line" || bad "-t 3 reaches the command line"

# The API is off by default and, when on, stays on the loopback address unless
# somebody deliberately widens it -- and it carries a token with it.
"$TOOL" setup --wallet "$WALLET" >/dev/null 2>&1
expect_ok "args with the API off" "$TOOL" args
contains "--http-port" "$CHECK_MSG" && bad "the API must be off by default" || ok "the API is off by default"

cat >> "$ROOTDIR/etc/zmrig/os.conf" <<'EOF'
API_PORT="18080"
API_HOST="0.0.0.0"
API_TOKEN="secret"
EOF
expect_ok "args with the API on" "$TOOL" args
contains "--http-port 18080" "$CHECK_MSG" && ok "the API port reaches the command line" || bad "the API port reaches the command line"
contains "--http-access-token secret" "$CHECK_MSG" && ok "the API token reaches the command line" || bad "the API token reaches the command line"

"$TOOL" setup --wallet "$WALLET" >/dev/null 2>&1

# ---------------------------------------------------------------- overrides
cat > "$ROOTDIR/etc/zmrig/kernel.conf" <<EOF
MODE="balanced"
WORKER="rig-07"
EOF
expect_ok "kernel.conf is read" "$TOOL" args
contains "-p rig-07" "$CHECK_MSG" && ok "the kernel command line overrides the worker" || bad "the kernel command line overrides the worker"
contains "--priority 3" "$CHECK_MSG" && ok "the kernel command line overrides the mode" || bad "the kernel command line overrides the mode"
rm -f "$ROOTDIR/etc/zmrig/kernel.conf"

# ---------------------------------------------------------------- status
expect_ok "status runs with a config" "$TOOL" status
contains "wallet" "$CHECK_MSG" && ok "status reports the wallet" || bad "status reports the wallet"
contains "fee" "$CHECK_MSG" && ok "status reports the fee" || bad "status reports the fee"

expect_ok "export prints the config" "$TOOL" export
contains "WALLET=" "$CHECK_MSG" && ok "export contains the config file" || bad "export contains the config file"

# ---------------------------------------------------------------- supervisor
# No wallet: the supervisor waits instead of exiting, which is what lets a
# headless rig boot before anybody has configured it.
mkdir -p "$ROOTDIR/etc/zmrig"
: > "$ROOTDIR/etc/zmrig/os.conf"
mkdir -p "$ROOTDIR/usr/local/bin"
printf '#!/bin/sh\nexit 0\n' > "$ROOTDIR/usr/local/bin/zmrig"
chmod +x "$ROOTDIR/usr/local/bin/zmrig"

timeout 3 "$TOOL" run > "$ROOTDIR/wait.log" 2>&1
contains "no wallet configured" "$(cat "$ROOTDIR/wait.log")" &&
    ok "the supervisor waits for a wallet instead of dying" ||
    bad "the supervisor waits for a wallet instead of dying"

touch "$ROOTDIR/run/zmrig/nostart"
expect_ok "nostart boots without mining" "$TOOL" run
contains "not starting" "$CHECK_MSG" && ok "nostart says why it is idle" || bad "nostart says why it is idle"
rm -f "$ROOTDIR/run/zmrig/nostart"

# ---------------------------------------------------------------- updater
mkdir -p "$ROOTDIR/bucket"
printf '#!/bin/sh\necho zmrig 9.9.9\nexit 0\n' > "$ROOTDIR/bucket/zmrig-new"
chmod +x "$ROOTDIR/bucket/zmrig-new"
NEW_SHA=$(sha256sum "$ROOTDIR/bucket/zmrig-new" | cut -d' ' -f1)

manifest() { # version, sha
    cat > "$ROOTDIR/bucket/manifest" <<EOF
{
  "product": "zmrig-os",
  "version": "$1",
  "binary_url": "file://$ROOTDIR/bucket/zmrig-new",
  "binary_sha256": "$2"
}
EOF
}

export ZMRIG_OS_MANIFEST_URL="file://$ROOTDIR/bucket/manifest"
# The updater writes a real file into the (temporary) root, so this block runs
# with the dry run off; everything it touches is inside $ROOTDIR.
export ZMRIG_OS_DRYRUN=0

manifest "9.9.9" "$NEW_SHA"
expect_ok "update --check reaches the manifest" "$TOOL" update --check
contains "9.9.9" "$CHECK_MSG" && ok "the update check reports the new version" || bad "the update check reports the new version"
contains "installed" "$CHECK_MSG" && ok "the update check reports the installed version" || bad "the update check reports the installed version"

expect_ok "update --apply installs a verified binary" "$TOOL" update --apply
contains "zmrig 9.9.9" "$("$ROOTDIR/usr/local/bin/zmrig" --version 2>/dev/null | head -1)" &&
    ok "the new binary is in place" || bad "the new binary is in place"

printf '#!/bin/sh\necho tampered\n' > "$ROOTDIR/bucket/zmrig-new"
manifest "9.9.9" "$NEW_SHA"
expect_fail "a bad checksum is refused" "$TOOL" update --apply
contains "tampered" "$("$ROOTDIR/usr/local/bin/zmrig" --version 2>/dev/null)" &&
    bad "a refused update must not overwrite the binary" || ok "a refused update does not overwrite the binary"

manifest "0.0.1" "$NEW_SHA"
expect_ok "an older manifest is still readable" "$TOOL" update --check
contains "available  0.0.1" "$CHECK_MSG" && ok "an older version is reported as available, not as an upgrade" || bad "an older version is reported as available"

# ---------------------------------------------------------------- autotune
# (the supervisor test above blanked the config on purpose; put a wallet back)
"$TOOL" setup --wallet "$WALLET" >/dev/null 2>&1
# The miner prints one machine-readable line and the tool pins it; nothing else
# in its prose output is trusted.
cat > "$ROOTDIR/usr/local/bin/zmrig" <<'EOF'
#!/bin/sh
printf 'threads   hashrate      verdict\n'
printf '       2    901.5 H/s    best so far\n'
printf 'autotune-best-threads=2\n'
printf 'autotune-best-rate=901.500\n'
printf 'autotune-rate-unit=H/s\n'
EOF
chmod +x "$ROOTDIR/usr/local/bin/zmrig"

expect_ok "autotune runs" "$TOOL" autotune 1
contains 'THREADS="3"' "$(cat "$ROOTDIR/etc/zmrig/os.conf")" &&
    bad "autotune must pin the number the miner reported, not a guess" ||
    ok "autotune does not invent a thread count"

cat > "$ROOTDIR/usr/local/bin/zmrig" <<'EOF'
#!/bin/sh
printf 'autotune-best-threads=3\n'
EOF
chmod +x "$ROOTDIR/usr/local/bin/zmrig"
expect_ok "autotune pins the winner" "$TOOL" autotune 1
contains 'THREADS="3"' "$(cat "$ROOTDIR/etc/zmrig/os.conf")" &&
    ok "the winning thread count is written to os.conf" ||
    bad "the winning thread count is written to os.conf"
# The marker is what stops the supervisor measuring a machine that already has
# an answer, so it has to be written by the same command that writes the number.
contains 'AUTOTUNED="1"' "$(cat "$ROOTDIR/etc/zmrig/os.conf")" &&
    ok "and it records that this machine has been measured" ||
    bad "autotune does not record that the machine was measured"

# Measuring an untuned machine answers the wrong question: the tuner runs first,
# and the test asserts the order, not just that both happened.
mkdir -p "$ROOTDIR/usr/local/lib/zmrig"
cat > "$ROOTDIR/usr/local/lib/zmrig/tune-linux.sh" <<'EOF'
#!/bin/sh
echo "TUNER-RAN $*"
EOF
chmod +x "$ROOTDIR/usr/local/lib/zmrig/tune-linux.sh"
out=$("$TOOL" autotune 1 2>&1)
first_tune=$(printf '%s\n' "$out" | grep -n 'TUNER-RAN' | head -1 | cut -d: -f1)
first_pin=$(printf '%s\n' "$out" | grep -n 'pinned' | head -1 | cut -d: -f1)
if [ -n "$first_tune" ] && [ -n "$first_pin" ] && [ "$first_tune" -lt "$first_pin" ]; then
    ok "the machine is tuned before it is measured"
else
    bad "the machine is measured before it is tuned (or the tuner never ran)"
fi
contains "--thp" "$(cat "$ROOTDIR/var/log/zmrig-os.log" 2>/dev/null; printf '%s' "$out")" &&
    ok "the tuner is given a profile, not left to its defaults" ||
    bad "the tuner is given a profile"

# The threshold nobody should have to find by reading the source.
if ZMRIG_OS_NO_MAIN=1 ZMRIG_OS_ROOT="$ROOTDIR" sh -c '. "$1"; autotune_due auto "" 1' _ "$TOOL"; then
    ok "an unmeasured machine with the heuristic in charge is due"
else
    bad "an unmeasured machine with the heuristic in charge is due"
fi
ZMRIG_OS_NO_MAIN=1 ZMRIG_OS_ROOT="$ROOTDIR" sh -c '. "$1"; autotune_due auto 1 1' _ "$TOOL" &&
    bad "a measured machine is measured again" || ok "a measured machine is not measured again"
ZMRIG_OS_NO_MAIN=1 ZMRIG_OS_ROOT="$ROOTDIR" sh -c '. "$1"; autotune_due 8 "" 1' _ "$TOOL" &&
    bad "a hand-picked thread count is overruled" || ok "a hand-picked thread count is left alone"
ZMRIG_OS_NO_MAIN=1 ZMRIG_OS_ROOT="$ROOTDIR" sh -c '. "$1"; autotune_due auto "" 0' _ "$TOOL" &&
    bad "AUTO_AUTOTUNE=0 is ignored" || ok "AUTO_AUTOTUNE=0 turns the measurement off"

# --auto is what the supervisor runs: no output to nobody, and no failure that
# takes the supervisor down when the miner is missing.
rm -f "$ROOTDIR/usr/local/bin/zmrig"
expect_ok "autotune --auto survives a missing miner" "$TOOL" autotune --auto
expect_ok "autotune --auto is quiet when there is nothing to do" "$TOOL" autotune --auto
expect_fail "a manual autotune still reports a missing miner" "$TOOL" autotune 1

cat > "$ROOTDIR/usr/local/bin/zmrig" <<'EOF'
#!/bin/sh
printf 'autotune-best-threads=3\n'
EOF
chmod +x "$ROOTDIR/usr/local/bin/zmrig"

# A mode change makes the old answer wrong: safe sheds threads under heat and
# eco starts lower, so the count must go back to auto.
printf 'THREADS="3"\nAUTOTUNED="1"\nWALLET="%s"\n' "$WALLET" > "$ROOTDIR/etc/zmrig/os.conf"
"$TOOL" mode eco >/dev/null 2>&1
contains 'THREADS="3"' "$(cat "$ROOTDIR/etc/zmrig/os.conf")" &&
    ok "a chosen thread count survives a mode change" ||
    bad "a mode change threw away a thread count somebody chose"
printf 'THREADS="auto"\nAUTOTUNED="1"\nWALLET="%s"\n' "$WALLET" > "$ROOTDIR/etc/zmrig/os.conf"
"$TOOL" mode max >/dev/null 2>&1
contains 'AUTOTUNED=""' "$(cat "$ROOTDIR/etc/zmrig/os.conf")" &&
    ok "a mode change clears the measurement, so it is taken again" ||
    bad "a mode change keeps a measurement that no longer applies"

# ------------------------------------------------- hashrate drift and re-measure
# The measurement is only worth keeping if the rig is still on it. These assert
# the decision, not the sleep loop: drift_due is a pure function of four
# numbers, and the thresholds are the ones the watcher uses.
drift() { ZMRIG_OS_NO_MAIN=1 ZMRIG_OS_ROOT="$ROOTDIR" sh -c '. "$1"; shift; drift_due "$@"' _ "$TOOL" "$@"; }

drift 900 1000 1000 100000 && bad "a rig at 90% of its measurement is measured again" || ok "a rig at 90% of its measurement is left alone"
drift 600 1000 1000 100000 && ok "a rig at 60% of its measurement is measured again" || bad "a rig at 60% of its measurement is measured again"
drift 900 1000 1000 10400 && bad "drift is acted on five minutes after a measurement" || ok "drift is not acted on five minutes after a measurement"
drift 600 1000 1000 100000 250 75 0 && ok "the thresholds are parameters, not magic numbers" || bad "the thresholds are parameters"
drift 100 120 1000 100000 && bad "a small rig is re-measured over noise" || ok "a small rig is not re-measured over the noise of 20% swings"
drift 0 1200 0 100000 && bad "a stopped miner looks like drift" || ok "a stopped miner is not drift"
drift '?' 1200 0 100000 && bad "an unreadable rate looks like drift" || ok "an unreadable rate is not drift"
drift 600 1000 '' 100000 && bad "a measurement with no timestamp is trusted" || ok "a measurement with no timestamp is not used"
drift 600 "" 1000 100000 && bad "an empty baseline is compared" || ok "an empty baseline is not compared"

# The miner prints the unit it chose; the tool must not assume H/s.
hs() { ZMRIG_OS_NO_MAIN=1 ZMRIG_OS_ROOT="$ROOTDIR" sh -c '. "$1"; shift; to_hs "$@"' _ "$TOOL" "$@"; }
[ "$(hs 901.500 H/s)" = "901" ] && ok "a plain rate is kept as-is" || bad "a plain rate is kept as-is ($(hs 901.500 H/s))"
[ "$(hs 1.234 kH/s)" = "1234" ] && ok "kH/s becomes H/s" || bad "kH/s becomes H/s ($(hs 1.234 kH/s))"
[ "$(hs 2.5 MH/s)" = "2500000" ] && ok "a short mantissa is padded, not shifted" || bad "a short mantissa is padded ($(hs 2.5 MH/s))"
hs 900 bogus >/dev/null 2>&1 && bad "an unknown unit is accepted" || ok "an unknown unit is refused"

# The rate and the number have to be written by the command that writes the count.
cat > "$ROOTDIR/usr/local/bin/zmrig" <<'EOF'
#!/bin/sh
printf '       4    1.234 kH/s   best so far\n'
printf 'autotune-best-threads=4\n'
printf 'autotune-best-rate=1.234\n'
printf 'autotune-rate-unit=kH/s\n'
EOF
chmod +x "$ROOTDIR/usr/local/bin/zmrig"
"$TOOL" setup --wallet "$WALLET" >/dev/null 2>&1
expect_ok "autotune runs with a unit-carrying miner" "$TOOL" autotune 1
conf=$(cat "$ROOTDIR/etc/zmrig/os.conf")
contains 'MEASURED_HS="1234"' "$conf" && ok "the measured rate is recorded in H/s" || bad "the measured rate is recorded ($conf)"
contains 'MEASURED_THREADS="4"' "$conf" && ok "and the count it belongs to" || bad "and the count it belongs to"
contains 'TUNED_AT=' "$conf" && ok "and when it was taken" || bad "and when it was taken"

out=$("$TOOL" status 2>&1)
contains "measured" "$out" && contains "1234 H/s" "$out" && ok "status shows the measurement next to the live rate" || bad "status shows the measurement"

# Reloading the miner is the only way a new measurement takes effect, and only a
# drift re-measure may revisit an existing one.
cat > "$ROOTDIR/usr/local/bin/zmrig" <<'EOF'
#!/bin/sh
printf 'autotune-best-threads=2\n'
printf 'autotune-best-rate=600.0\n'
printf 'autotune-rate-unit=H/s\n'
EOF
chmod +x "$ROOTDIR/usr/local/bin/zmrig"
"$TOOL" autotune --auto >/dev/null 2>&1
contains 'MEASURED_HS="1234"' "$(cat "$ROOTDIR/etc/zmrig/os.conf")" &&
    ok "--auto leaves an existing measurement alone" || bad "--auto overwrote an existing measurement"
"$TOOL" autotune --auto --retune >/dev/null 2>&1
contains 'MEASURED_HS="600"' "$(cat "$ROOTDIR/etc/zmrig/os.conf")" &&
    ok "--auto --retune measures again and records the new rate" || bad "--auto --retune did not measure again"

# ... and with nothing to re-measure, it does nothing at all.
printf 'THREADS="4"\nAUTOTUNED=""\nWALLET="%s"\n' "$WALLET" > "$ROOTDIR/etc/zmrig/os.conf"
expect_ok "--auto --retune with no measurement is a no-op" "$TOOL" autotune --auto --retune
contains 'AUTOTUNED=""' "$(cat "$ROOTDIR/etc/zmrig/os.conf")" &&
    ok "and it does not invent one" || bad "and it does not invent one"

# A count somebody typed is never the business of the watcher, so it must not
# carry a baseline either.
printf 'THREADS="auto"\nAUTOTUNED="1"\nMEASURED_THREADS="4"\nMEASURED_HS="1234"\nTUNED_AT="1000"\nWALLET="%s"\n' "$WALLET" > "$ROOTDIR/etc/zmrig/os.conf"
"$TOOL" setup --wallet "$WALLET" --threads 6 >/dev/null 2>&1
conf=$(cat "$ROOTDIR/etc/zmrig/os.conf")
contains 'THREADS="6"' "$conf" && contains 'MEASURED_HS=""' "$conf" && contains 'AUTOTUNED=""' "$conf" &&
    ok "a hand-picked count clears the measurement it replaced" || bad "a hand-picked count kept a stale measurement"

# `zmrig-os version` prints the base the image was built from.
mkdir -p "$ROOTDIR/etc/zmrig"
printf 'alpine 3.22.1\nkernel linux-lts\nsquashfs zstd-19\ninitramfs zst\n' > "$ROOTDIR/etc/zmrig/base"
out=$("$TOOL" version 2>&1)
contains "alpine    3.22.1" "$out" && ok "version prints the Alpine base" || bad "version prints the Alpine base"
contains "initramfs zst" "$out" && ok "and how the initramfs is packed" || bad "and how the initramfs is packed"

# Every version string in the repository has to agree, or the image reports one
# number and the release it came from reports another.
repo_version=$(sed -n 's/^pub const version = "\(.*\)";$/\1/p' "$ROOT/zmrig/src/main.zig" | head -1)
tool_version=$(ZMRIG_OS_NO_MAIN=1 ZMRIG_OS_ROOT="$ROOTDIR" sh -c '. "$1"; printf "%s" "$VERSION"' _ "$TOOL")
[ "$repo_version" = "$tool_version" ] &&
    ok "the control tool and the miner agree on the version ($repo_version)" ||
    bad "zmrig-os says $tool_version, the miner says $repo_version"
pkg_version=$(sed -n 's/.*"version": "\([0-9][0-9.]*\)".*/\1/p' "$ROOT/package.json" | head -1)
[ "$repo_version" = "$pkg_version" ] &&
    ok "package.json agrees too" || bad "package.json says $pkg_version, the miner says $repo_version"

# ------------------------------------------------- two forms: live / disk
# The installer is the part of this image that can destroy somebody's disk, so
# the tests below are mostly about what it refuses to do.
newroot
expect_ok "install with no --disk explains the two forms" "$TOOL" install
contains "live" "$CHECK_MSG" && ok "it describes the live form" || bad "it describes the live form"
contains "installed" "$CHECK_MSG" && ok "it describes the installed form" || bad "it describes the installed form"
contains "zmrig-os install --disk" "$CHECK_MSG" && ok "it shows the command" || bad "it shows the command"

expect_fail "a path that is not a device is refused" "$TOOL" install --disk /tmp/notadisk
contains "not a device path" "$CHECK_MSG" && ok "it says why" || bad "it says why"
expect_fail "a loop device is refused" "$TOOL" install --disk /dev/loop0
expect_fail "an optical device is refused" "$TOOL" install --disk /dev/sr0

# The running medium is /media in the fake root; an install must never target
# the disk the machine booted from.
mkdir -p "$ROOTDIR/media/zmrig" "$ROOTDIR/etc/zmrig"
: > "$ROOTDIR/media/zmrig/installed"
printf '/dev/sdz\n' > "$ROOTDIR/etc/zmrig/bootdev"

# A dry run of a real-looking device: /dev/zero is a character device, so the
# refusal is about the type, not about the size - which is the point of --dry-run
# being checked above with no device at all.
expect_fail "a character device is refused" "$TOOL" install --disk /dev/zero

# ------------------------------------------------------------ installed form
# What the tool believes about the medium decides the persistence questions, so
# the marker and the slot file are asserted directly.
mkdir -p "$ROOTDIR/media/zmrig/state" "$ROOTDIR/media/boot/grub" "$ROOTDIR/etc/zmrig"
printf 'b\n' > "$ROOTDIR/etc/zmrig/slot"
"$TOOL" status > "$ROOTDIR/status.log" 2>&1 || true
CHECK_MSG=$(cat "$ROOTDIR/status.log")
contains "installed" "$CHECK_MSG" && ok "status says the system is installed" || bad "status says the system is installed"
contains "slot b" "$CHECK_MSG" && ok "status shows the running slot" || bad "status shows the running slot"
contains "daily" "$CHECK_MSG" && ok "status shows the update policy" || bad "status shows the update policy"

# A live image must say so, because "why did my wallet disappear" is a question
# with exactly one useful answer.
rm -f "$ROOTDIR/media/zmrig/installed"
"$TOOL" status > "$ROOTDIR/status.log" 2>&1 || true
contains "live image" "$(cat "$ROOTDIR/status.log")" &&
    ok "status says the system is live" || bad "status says the system is live"
: > "$ROOTDIR/media/zmrig/installed"

# ------------------------------------------------------------ A/B slots
expect_ok "slot prints the running and next slot" "$TOOL" slot
contains "running" "$CHECK_MSG" && ok "slot shows the running slot" || bad "slot shows the running slot"
contains "next boot" "$CHECK_MSG" && ok "slot shows the next boot" || bad "slot shows the next boot"

expect_fail "switching to an empty slot is refused" "$TOOL" slot b
contains "empty" "$CHECK_MSG" && ok "it says the slot is empty" || bad "it says the slot is empty"
expect_fail "an unknown slot is refused" "$TOOL" slot c

: > "$ROOTDIR/media/zmrig/rootfs-b.squashfs"
expect_ok "a slot with a root filesystem can be selected" "$TOOL" slot b
contains "slot b" "$CHECK_MSG" && ok "it reports the new default" || bad "it reports the new default"
# The block is what GRUB reads: exactly 1024 bytes, with the key in it.
if [ -f "$ROOTDIR/media/boot/grub/grubenv" ]; then
    size=$(wc -c < "$ROOTDIR/media/boot/grub/grubenv")
    [ "$size" = "1024" ] && ok "the GRUB environment block is 1024 bytes" ||
        bad "the GRUB environment block is ${size} bytes, GRUB ignores anything but 1024"
    grep -q '^zmrig_slot=b$' "$ROOTDIR/media/boot/grub/grubenv" &&
        ok "the block names the slot" || bad "the block names the slot"
else
    bad "no GRUB environment block was written"
fi

# ------------------------------------------------------------ auto update
# A manifest served from a file:// path is the same code path as the release
# URL: the updater cannot tell the difference, which is why this test needs no
# network.
mkdir -p "$ROOTDIR/media/zmrig/bin"
cat > "$ROOTDIR/manifest.json" <<'EOF'
{"version":"9.9.9","binary_url":"file:///dev/null","binary_sha256":""}
EOF
export ZMRIG_OS_MANIFEST_URL="file://$ROOTDIR/manifest.json"

expect_ok "auto --check reads a manifest" "$TOOL" auto --check
contains "installed" "$CHECK_MSG" && ok "it prints what is installed" || bad "it prints what is installed"
contains "9.9.9" "$CHECK_MSG" && ok "it prints what is available" || bad "it prints what is available"

# An older manifest is not an update in either direction.
printf '{"version":"0.0.1"}\n' > "$ROOTDIR/manifest.json"
expect_ok "an older release is not an upgrade" "$TOOL" auto --check
contains "up to date" "$CHECK_MSG" && ok "it says so" || bad "it says so"

# No network (no manifest) is not a failure: a rig behind a firewall keeps
# mining and the daily job exits 0.
export ZMRIG_OS_MANIFEST_URL="file://$ROOTDIR/nothing-here.json"
expect_ok "an unreachable manifest is not an error" "$TOOL" auto --once
contains "offline" "$CHECK_MSG" && ok "it explains itself" || bad "it explains itself"
unset ZMRIG_OS_MANIFEST_URL

# AUTO_UPDATE=0 turns the whole thing off, and the miner does not phone home.
expect_ok "a config exists to switch updates off" "$TOOL" setup --wallet "$WALLET" --pool pool.example.com:10001
grep -q '^AUTO_UPDATE=' "$ROOTDIR/etc/zmrig/os.conf" && sed -i 's/^AUTO_UPDATE=.*/AUTO_UPDATE="0"/' "$ROOTDIR/etc/zmrig/os.conf" ||
    printf 'AUTO_UPDATE="0"\n' >> "$ROOTDIR/etc/zmrig/os.conf"
expect_ok "automatic updates can be switched off" "$TOOL" auto --once
contains "off" "$CHECK_MSG" && ok "it says updates are off" || bad "it says updates are off"

# ------------------------------------------------- the install, without a disk
# The installer is the only part of this image that can destroy a disk, so the
# decisions it makes are asserted directly. `ZMRIG_OS_NO_MAIN=1` lets this test
# source the tool and call the functions that build the partition table and the
# plan - the same ones a real run executes, not a copy of them.
fn() { # function name, args...
    local name="$1"; shift
    ZMRIG_OS_NO_MAIN=1 ZMRIG_OS_ROOT="$ROOTDIR" sh -c '. "$1"; shift; "$@"' _ "$TOOL" "$name" "$@"
}

pts=$(fn partition_script)
contains "label: gpt" "$pts" && ok "the install writes a GPT" || bad "the install writes a GPT"
contains "21686148-6449-6E6F-744E-656564454649" "$pts" &&
    ok "there is a BIOS-boot partition for core.img" || bad "there is a BIOS-boot partition"
contains "C12A7328-F81F-11D2-BA4B-00A0C93EC93B" "$pts" &&
    ok "there is an EFI system partition" || bad "there is an EFI system partition"
contains "0FC63DAF-8483-4772-8E79-3D69D8477DE4" "$pts" &&
    ok "there is a Linux root partition" || bad "there is a Linux root partition"
contains "start=2048, size=2048" "$pts" && ok "the BIOS boot partition is placed first" ||
    bad "the BIOS boot partition is placed first"

plan=$(fn install_plan /dev/sda /m/vmlinuz /m/initramfs.gz /m/rootfs.squashfs /dev/sda2 /dev/sda3)
contains "BOOTX64.EFI" "$plan" && ok "the plan installs the EFI loader" || bad "the plan installs the EFI loader"
contains "rootfs-a.squashfs" "$plan" && ok "the plan copies the root filesystem into slot a" ||
    bad "the plan copies the root filesystem into slot a"
contains "sector 2048" "$plan" && ok "the plan puts core.img where the BIOS looks" ||
    bad "the plan puts core.img where the BIOS looks"
contains "grubenv (slot a)" "$plan" && ok "the plan seeds the A/B environment" ||
    bad "the plan seeds the A/B environment"

fn other_slot a > "$ROOTDIR/os.txt" 2>&1
[ "$(cat "$ROOTDIR/os.txt")" = "b" ] && ok "slot a's other half is b" || bad "slot a's other half is b"
fn other_slot b > "$ROOTDIR/os.txt" 2>&1
[ "$(cat "$ROOTDIR/os.txt")" = "a" ] && ok "slot b's other half is a" || bad "slot b's other half is a"

fn newer_than 6.35.0 6.34.0 && ok "6.35.0 is newer than 6.34.0" || bad "6.35.0 is newer than 6.34.0"
fn newer_than 6.34.0 6.35.0 && bad "an older version is not newer" || ok "an older version is not newer"
fn newer_than 6.34.10 6.34.9 && ok "a two-digit patch level compares as a number" ||
    bad "a two-digit patch level compares as a number (sort -V was not used)"

# ---------------------------------------------------------------- doctor
# The doctor is expected to fail on an unconfigured sandbox (no binary on this
# path, no MSR); what matters is that it runs and reports every check.
"$TOOL" doctor > "$ROOTDIR/doctor.log" 2>&1 || true
CHECK_MSG=$(cat "$ROOTDIR/doctor.log")
contains "failed" "$CHECK_MSG" && ok "doctor prints a verdict" || bad "doctor prints a verdict"
contains "wallet" "$CHECK_MSG" && ok "doctor checks the wallet" || bad "doctor checks the wallet"
contains "thp" "$CHECK_MSG" && ok "doctor checks transparent huge pages" || bad "doctor checks transparent huge pages"

# ---------------------------------------------------------------- dry run
expect_ok "stop with nothing running is not an error" "$TOOL" stop

rmroot
unset ZMRIG_OS_ROOT ZMRIG_OS_DRYRUN ZMRIG_OS_MANIFEST_URL


# --------------------------------------------------------------------- fleet

# The identity is derived, not stored twice: the same key must give the same ID
# and the ID in `status` must be the one `id` prints.
newroot
FLEET_ID=$(fn device_id 2>/dev/null || sh "$TOOL" id 2>/dev/null | sed -n 's/^  device *//p')
case "$FLEET_ID" in
    ZMR-????-????-????) ok "device_id prints a ZMR- id" ;;
    *) bad "device_id prints a ZMR- id (got '$FLEET_ID')" ;;
esac
[ "$FLEET_ID" = "$(fn device_id)" ] && ok "the same key gives the same id" || bad "the same key gives the same id"

FLEET_CODE=$(fn enrol_code)
case "$FLEET_CODE" in
    ????-????) ok "enrol_code prints eight hex characters" ;;
    *) bad "enrol_code prints eight hex characters (got '$FLEET_CODE')" ;;
esac

# A key file that is not 64 hex characters is replaced, not used.
printf 'not-a-key' > "${ROOTDIR}/etc/zmrig/device.key"
NEW_ID=$(fn device_id)
case "$NEW_ID" in
    ZMR-????-????-????) ok "a damaged key is replaced instead of breaking the tool" ;;
    *) bad "a damaged key is replaced instead of breaking the tool (got '$NEW_ID')" ;;
esac
[ -f "${ROOTDIR}/etc/zmrig/device.key.damaged" ] && ok "the damaged key is kept beside the new one" ||
    bad "the damaged key is kept beside the new one"
rmroot

check "fleet with no URL does nothing and says so" bash -c "! sh '$TOOL' fleet --bogus 2>/dev/null"
check "sync without a fleet is a no-op" bash -c "sh '$TOOL' sync --now >/dev/null"

newroot
expect_fail "a fleet URL must be http(s)" sh "$TOOL" fleet --url ftp://example.com
contains "must start with https" "$CHECK_MSG" && ok "the refusal names the reason" || bad "the refusal names the reason"
expect_ok "https is accepted" sh "$TOOL" fleet --url https://fleet.example.com
contains 'FLEET_URL="https://fleet.example.com"' "$(cat "${ROOTDIR}/etc/zmrig/os.conf")" &&
    ok "the URL is written to os.conf" || bad "the URL is written to os.conf"
expect_ok "a bare fleet prints the identity" sh "$TOOL" fleet
contains "$(fn device_id)" "$CHECK_MSG" && ok "and that identity is the device id" || bad "and that identity is the device id"
rmroot

# help must mention the two new entry points, or nobody finds them
contains "zmrig-os id" "$(sh "$TOOL" help)" && ok "help lists 'zmrig-os id'" || bad "help lists 'zmrig-os id'"
contains "zmrig-os sync" "$(sh "$TOOL" help)" && ok "help lists 'zmrig-os sync'" || bad "help lists 'zmrig-os sync'"

printf '\n    %d passed, %d failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]

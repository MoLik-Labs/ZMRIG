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

# ---------------------------------------------------------------- doctor
# The doctor is expected to fail on an unconfigured sandbox (no binary on this
# path, no MSR); what matters is that it runs and reports every check.
"$TOOL" doctor > "$ROOTDIR/doctor.log" 2>&1 || true
CHECK_MSG=$(cat "$ROOTDIR/doctor.log")
contains "failed" "$CHECK_MSG" && ok "doctor prints a verdict" || bad "doctor prints a verdict"
contains "wallet" "$CHECK_MSG" && ok "doctor checks the wallet" || bad "doctor checks the wallet"
contains "thp" "$CHECK_MSG" && ok "doctor checks transparent huge pages" || bad "doctor checks transparent huge pages"

# ------------------------------------------------------------- topology
# A fake 8-core / 16-thread machine. The kernel exposes thread_siblings_list per
# CPU and that is the only thing the tool reads, so the whole decision - thread
# count, affinity mask, the doctor line - can be checked on a machine that has
# one core. `nproc` says 16 here; the tool must say 8.
FAKESYS="$ROOTDIR/fakesys"
for cpu in $(seq 0 15); do
    mkdir -p "$FAKESYS/devices/system/cpu/cpu$cpu/topology"
    if [ "$cpu" -lt 8 ]; then
        printf '%s,%s\n' "$cpu" "$((cpu + 8))" > "$FAKESYS/devices/system/cpu/cpu$cpu/topology/thread_siblings_list"
    else
        printf '%s,%s\n' "$((cpu - 8))" "$cpu" > "$FAKESYS/devices/system/cpu/cpu$cpu/topology/thread_siblings_list"
    fi
done

expect_ok "topology counts cores, not hyperthreads" env ZMRIG_OS_SYS="$FAKESYS" "$TOOL" topology
contains "8 physical, 16 threads" "$CHECK_MSG" && ok "8 cores on a 16-thread machine" || bad "8 cores on a 16-thread machine"
contains "0xff" "$CHECK_MSG" && ok "the mask is one bit per physical core" || bad "the mask is one bit per physical core"

# The bug this replaces: `balanced` subtracted one from nproc, so a 16-thread
# machine asked for 15 mining threads on 8 cores.
printf 'MODE="balanced"\nTHREADS="auto"\nWALLET="%s"\n' "$WALLET" > "$ROOTDIR/etc/zmrig/os.conf"
ARGS=$(ZMRIG_OS_SYS="$FAKESYS" "$TOOL" args)
contains "-t 7" " $ARGS" && ok "balanced asks for cores - 1, not threads - 1" || bad "balanced asks for cores - 1, not threads - 1"
contains "--cpu-affinity 0xff" "$ARGS" && ok "the miner is pinned to those cores" || bad "the miner is pinned to those cores"

printf 'MODE="max"\nTHREADS="auto"\nWALLET="%s"\nAFFINITY="off"\n' "$WALLET" > "$ROOTDIR/etc/zmrig/os.conf"
ARGS=$(ZMRIG_OS_SYS="$FAKESYS" "$TOOL" args)
contains "--cpu-affinity" "$ARGS" && bad "AFFINITY=off must remove the flag" || ok "AFFINITY=off removes the flag"

printf 'MODE="max"\nTHREADS="auto"\nWALLET="%s"\nAFFINITY="0x3"\n' "$WALLET" > "$ROOTDIR/etc/zmrig/os.conf"
ARGS=$(ZMRIG_OS_SYS="$FAKESYS" "$TOOL" args)
contains "--cpu-affinity 0x3" "$ARGS" && ok "an explicit mask is passed through" || bad "an explicit mask is passed through"

# A machine with no topology at all (a container, a very old kernel) falls back
# to nproc rather than silently pinning everything to one core.
EMPTYSYS="$ROOTDIR/emptysys"
mkdir -p "$EMPTYSYS"
printf 'MODE="max"\nTHREADS="auto"\nWALLET="%s"\n' "$WALLET" > "$ROOTDIR/etc/zmrig/os.conf"
expect_ok "no topology is not a failure" env ZMRIG_OS_SYS="$EMPTYSYS" "$TOOL" topology
contains "0x" "$CHECK_MSG" && bad "no topology must not invent a mask" || ok "no topology produces no mask"

# ------------------------------------------------------------- self-tuning
# The image measures each machine once, in the background, after it has already
# started earning. What it must never do is measure a rig whose operator pinned
# the thread count on purpose.
printf 'MODE="max"\nTHREADS="4"\nWALLET="%s"\n' "$WALLET" > "$ROOTDIR/etc/zmrig/os.conf"
expect_ok "autotune --auto is a no-op when threads are pinned" "$TOOL" autotune --auto
contains 'THREADS="4"' "$(cat "$ROOTDIR/etc/zmrig/os.conf")" && ok "a pinned count is left alone" || bad "a pinned count is left alone"

printf 'MODE="max"\nTHREADS="auto"\nWALLET="%s"\n' "$WALLET" > "$ROOTDIR/etc/zmrig/os.conf"
cat > "$ROOTDIR/usr/local/bin/zmrig" <<'EOF'
#!/bin/sh
printf 'autotune-best-threads=6\n'
EOF
chmod +x "$ROOTDIR/usr/local/bin/zmrig"
expect_ok "autotune --auto measures an unpinned rig" "$TOOL" autotune --auto
contains 'THREADS="6"' "$(cat "$ROOTDIR/etc/zmrig/os.conf")" && ok "the measurement is pinned" || bad "the measurement is pinned"
contains 'AUTOTUNED="' "$(cat "$ROOTDIR/etc/zmrig/os.conf")" && ok "and it is remembered, so it is not measured again" || bad "and it is remembered, so it is not measured again"

# Once measured, a second boot must not spend four minutes re-measuring.
printf 'MODE="max"\nTHREADS="auto"\nWALLET="%s"\n' "$WALLET" > "$ROOTDIR/etc/zmrig/os.conf"
expect_ok "autotune --auto runs again when nothing is recorded" "$TOOL" autotune --auto
contains 'AUTOTUNED="' "$(cat "$ROOTDIR/etc/zmrig/os.conf")" && ok "the second run records itself too" || bad "the second run records itself too"

# A different mode is a different thread budget: the old measurement is dropped.
expect_ok "a mode change clears the old measurement" "$TOOL" mode eco
contains 'THREADS="auto"' "$(cat "$ROOTDIR/etc/zmrig/os.conf")" && ok "the thread count goes back to auto" || bad "the thread count goes back to auto"
contains 'AUTOTUNED=""' "$(cat "$ROOTDIR/etc/zmrig/os.conf")" && ok "and the measurement marker is cleared" || bad "and the measurement marker is cleared"

# ---------------------------------------------------------------- dry run
expect_ok "stop with nothing running is not an error" "$TOOL" stop

rmroot
unset ZMRIG_OS_ROOT ZMRIG_OS_DRYRUN ZMRIG_OS_MANIFEST_URL

printf '\n    %d passed, %d failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]

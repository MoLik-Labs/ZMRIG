#!/usr/bin/env bash
#
# governor.sh - the one host setting where the two profiles must differ.
#
# `free` pins the CPU to its top frequency: the governor never has to ramp, so
# work never starts at a low clock. `watt` does the opposite -- power grows with
# V^2 * f, and a mining thread stalled on memory does not need the top bin -- so
# it leaves a power-aware governor alone and only repairs the one setting that
# actively wastes power (`performance`).
#
# The script reads sysfs at absolute paths, so it takes CPU_ROOT and
# POWER_SUPPLY_ROOT overrides. This test builds a fake tree and checks that the
# right file got the right value -- the alternative is trusting shell logic that
# nobody ever ran.
#
#   ./tests/oneclick/governor.sh
#
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
WORK=$(mktemp -d)
trap 'sudo -n rm -rf "$WORK" 2>/dev/null; rm -rf "$WORK" 2>/dev/null' EXIT

# tune-linux.sh refuses to run unprivileged (it changes kernel settings), so the
# test runs it the way a user would. Without any way to become root the test
# cannot exercise the code at all, and says so instead of passing vacuously.
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    if sudo -n true 2>/dev/null; then
        SUDO="sudo -n"
    else
        echo "skip: needs root or passwordless sudo"
        exit 0
    fi
fi

FAILED=0
pass() { printf ' PASS %s\n' "$*"; }
fail() { printf ' FAIL %s\n' "$*"; FAILED=1; }

# A fake /sys with two CPUs, schedutil available, and a spinning-down battery.
make_tree() {
    local root="$1" governor="$2"
    rm -rf "$root"
    mkdir -p "$root/cpu/cpu0/cpufreq" "$root/cpu/cpu1/cpufreq" "$root/ps/BAT0"

    printf 'schedutil\npowersave\nperformance\n' > "$root/cpu/cpu0/cpufreq/scaling_available_governors"
    printf 'schedutil\npowersave\nperformance\n' > "$root/cpu/cpu1/cpufreq/scaling_available_governors"
    printf '%s\n' "$governor" > "$root/cpu/cpu0/cpufreq/scaling_governor"
    printf '%s\n' "$governor" > "$root/cpu/cpu1/cpufreq/scaling_governor"
    printf 'Charging\n' > "$root/ps/BAT0/status"
}

run_tune() {
    local root="$1"
    shift
    ${SUDO} env CPU_ROOT="$root/cpu" POWER_SUPPLY_ROOT="$root/ps" \
        bash "$ROOT/scripts/tune-linux.sh" "$@" >"${WORK}/log" 2>&1
}

gov() { cat "$1/cpu/cpu0/cpufreq/scaling_governor"; }

# --- free: pin the top frequency ----------------------------------------
make_tree "${WORK}/a" schedutil
run_tune "${WORK}/a" --profile=free || fail "tune --profile=free exited non-zero"
if [ "$(gov "${WORK}/a")" = "performance" ]; then
    pass "free profile sets the performance governor"
else
    fail "free profile left the governor at '$(gov "${WORK}/a")'"
fi

if [ "$(cat "${WORK}/a/cpu/cpu1/cpufreq/scaling_governor")" = "performance" ]; then
    pass "free profile covers every CPU"
else
    fail "free profile missed cpu1"
fi

# --- watt: repair performance, leave anything power-aware alone ---------
make_tree "${WORK}/b" performance
run_tune "${WORK}/b" --profile=watt || fail "tune --profile=watt exited non-zero"
if [ "$(gov "${WORK}/b")" = "schedutil" ]; then
    pass "watt profile moves a pinned CPU back to schedutil"
else
    fail "watt profile left a pinned CPU at '$(gov "${WORK}/b")'"
fi

if printf '%s' "$(cat "${WORK}/log")" | grep -q "max hashrate per watt"; then
    pass "watt profile explains what it did"
else
    fail "watt profile is silent about the governor"
fi

make_tree "${WORK}/c" powersave
run_tune "${WORK}/c" --profile=watt
if [ "$(gov "${WORK}/c")" = "powersave" ]; then
    pass "watt profile does not touch an already power-aware governor"
else
    fail "watt profile changed powersave to '$(gov "${WORK}/c")'"
fi

# --- auto: throughput-first, regardless of battery ----------------------
make_tree "${WORK}/d" schedutil
printf 'Discharging\n' > "${WORK}/d/ps/BAT0/status"
run_tune "${WORK}/d"
if [ "$(gov "${WORK}/d")" = "performance" ]; then
    pass "auto on battery remains throughput-first like free"
else
    fail "auto on battery unexpectedly changed governor to '$(gov "${WORK}/d")'"
fi

make_tree "${WORK}/e" schedutil
run_tune "${WORK}/e"
if [ "$(gov "${WORK}/e")" = "performance" ]; then
    pass "auto on mains power behaves like free"
else
    fail "auto on mains power set the governor to '$(gov "${WORK}/e")'"
fi

# --- an unknown profile must not guess --------------------------------
make_tree "${WORK}/f" schedutil
run_tune "${WORK}/f" --profile=turbo
if [ "$(gov "${WORK}/f")" = "schedutil" ]; then
    pass "an unknown profile leaves the governor alone and warns"
else
    fail "an unknown profile changed the governor to '$(gov "${WORK}/f")'"
fi

echo
if [ "$FAILED" -eq 0 ]; then
    echo "governor: all checks passed"
    exit 0
fi

echo "governor: FAILED"
exit 1

#!/usr/bin/env bash
#
# light-fallback.sh - a cgroup too small for the dataset is a different plan, not
# a warning.
#
# RandomX maps 2336 MB in one piece. Under a 2 GB limit the miner builds the
# cache and rebuilds the dataset per hash: 973 H/s becomes 99 H/s, measured. The
# tuner used to notice, warn, reserve nothing, and still print the fast-mode
# budget - three statements that disagreed with each other and with the miner.
# Now the limit decides the mode and every number below follows it.
#
# The cgroup is a fake tree (ZMRIG_CGROUP_ROOT), `nproc` is a fake script, and
# the script runs `--status`: read-only, no root, no writes.
#
#   ./tests/oneclick/light-fallback.sh
#
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

FAILED=0
pass() { printf ' PASS %s\n' "$*"; }
fail() { printf ' FAIL %s\n' "$*"; FAILED=1; }

mkdir -p "$WORK/bin" "$WORK/cg"
printf '#!/bin/sh\necho 4\n' > "$WORK/bin/nproc"
chmod +x "$WORK/bin/nproc"

run() { # memory.max value (or "" for no cgroup) [extra args] -> stdout
    local limit="$1"; shift
    if [ -n "$limit" ]; then
        rm -rf "$WORK/cg"; mkdir -p "$WORK/cg"
        printf '%s\n' "$limit" > "$WORK/cg/memory.max"
    else
        rm -rf "$WORK/cg"
    fi
    PATH="$WORK/bin:$PATH" \
    ZMRIG_CGROUP_ROOT="$WORK/cg" \
        bash "$ROOT/scripts/tune-linux.sh" --status "$@" 2>&1
}

contains() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

# 1. A 1 GB limit cannot hold the 2336 MB dataset: the plan becomes light, and it
#    says which limit made the decision.
out=$(run $((1024 * 1024 * 1024)))
contains "planning light mode instead" "$out" &&
    pass "a 1 GB limit switches the plan to light mode" ||
    fail "a 1 GB limit switches the plan to light mode"
contains "(rx/0 light, 4 thread(s))" "$out" &&
    pass "the budget it prints is the light one" ||
    fail "the budget it prints is the light one"
contains "--memory=3g" "$out" &&
    pass "it names the memory the fast plan needs" ||
    fail "it names the memory the fast plan needs"

# 2. The light budget is the cache plus scratchpads, not the dataset: 256 + 4*2 + 32 = 296.
contains "~296 MB" "$out" &&
    pass "light needs 296 MB, not 2408 MB" ||
    fail "light needs 296 MB, not 2408 MB"

# 3. Enough memory and nothing changes: no switch, no warning.
out=$(run $((8 * 1024 * 1024 * 1024)))
contains "planning light mode" "$out" &&
    fail "an 8 GB limit must leave the plan alone" ||
    pass "an 8 GB limit leaves the plan alone"
contains "(rx/0 max, 4 thread(s))" "$out" &&
    pass "fast mode keeps its own budget" ||
    fail "fast mode keeps its own budget"

# 4. No cgroup at all is the bare-metal case, and it must not invent a limit.
out=$(run "")
contains "planning light mode" "$out" &&
    fail "no cgroup is not a memory limit" ||
    pass "no cgroup is not a memory limit"

# 5. An explicit --pages is a decision, and a decision is not overruled.
out=$(run $((1024 * 1024 * 1024)) --pages 100)
contains "planning light mode" "$out" &&
    fail "--pages is an explicit decision and must be obeyed" ||
    pass "--pages is an explicit decision and is obeyed"
contains "because --pages asked for it" "$out" &&
    pass "the explicit page count is explained" ||
    fail "the explicit page count is explained"

# 6. Too small for even the cache: switching to light would be a lie, so it does
#    not. This is the case where the honest answer is "this will not run".
out=$(run $((64 * 1024 * 1024)))
contains "planning light mode instead" "$out" &&
    fail "64 MB cannot hold the cache; the plan must not claim light mode works" ||
    pass "64 MB cannot hold the cache, and the plan does not pretend otherwise"

echo
if [ "$FAILED" -ne 0 ]; then
    echo "light fallback: FAILED"
    exit 1
fi
echo "light fallback: ok"

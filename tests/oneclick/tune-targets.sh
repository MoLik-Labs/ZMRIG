#!/usr/bin/env bash
#
# tune-targets.sh - the two settings a miner wants that are not about the CPU:
# where the interrupts land, and whether the kernel is allowed to migrate the
# dataset between NUMA nodes underneath a running thread.
#
# Neither can be exercised for real without root and without owning the machine,
# so this builds a fake /proc and /sys, fakes `id` so the root guard is satisfied,
# and runs the script in --dry-run mode: every decision is made and every write is
# printed instead of performed. The assertions are about *which file gets which
# value*, which is the part that used to be nobody's job.
#
#   ./tests/oneclick/tune-targets.sh
#
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

FAILED=0
pass() { printf ' PASS %s\n' "$*"; }
fail() { printf ' FAIL %s\n' "$*"; FAILED=1; }

mkdir -p "$WORK/bin" \
         "$WORK/sys/devices/virtual/workqueue/wq1" \
         "$WORK/proc/sys/kernel" \
         "$WORK/proc/irq/24" \
         "$WORK/proc/irq/25" \
         "$WORK/cpu/cpu0/cpufreq"

# root, and a machine with enough cores to have somewhere to steer to.
printf '#!/bin/sh\necho 0\n'   > "$WORK/bin/id";    chmod +x "$WORK/bin/id"
echo 8 > "$WORK/cores"
printf '#!/bin/sh\ncat %s\n' "$WORK/cores" > "$WORK/bin/nproc"; chmod +x "$WORK/bin/nproc"

echo '0-1' > "$WORK/proc/irq/24/smp_affinity_list"
echo '0-3' > "$WORK/proc/irq/25/smp_affinity_list"
echo 1     > "$WORK/proc/sys/kernel/numa_balancing"
echo 'f'   > "$WORK/sys/devices/virtual/workqueue/wq1/cpumask"

run() { # arguments -> stdout
    PATH="$WORK/bin:$PATH" \
    SYS_ROOT="$WORK/sys" \
    PROC_SYS="$WORK/proc/sys" \
    PROC_IRQ="$WORK/proc/irq" \
    CPU_ROOT="$WORK/cpu" \
        bash "$ROOT/scripts/tune-linux.sh" --dry-run "$@" 2>&1
}

contains() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

out=$(run --numa off --irq steer --profile free)
contains "would write 0 -> $WORK/proc/sys/kernel/numa_balancing" "$out" &&
    pass "numa_balancing is turned off, by path" ||
    fail "numa_balancing is turned off, by path"

contains "would write 0 to $WORK/proc/irq/24/smp_affinity_list" "$out" &&
    pass "interrupt 24 is moved to CPU 0" ||
    fail "interrupt 24 is moved to CPU 0"

contains "would write 0 to $WORK/proc/irq/25/smp_affinity_list" "$out" &&
    pass "an interrupt already on the mining cores is moved too" ||
    fail "an interrupt already on the mining cores is moved too"

contains "would write 1 to $WORK/sys/devices/virtual/workqueue/wq1/cpumask" "$out" &&
    pass "unbound workqueues are pinned to CPU 0" ||
    fail "unbound workqueues are pinned to CPU 0"

# `keep` is the default, and it must leave both alone: the image asks `zmrig-os`
# for these settings, and a script that steers interrupts when told not to is a
# script nobody can reason about.
out=$(run --profile free)
contains "would write 0 to $WORK/proc/irq" "$out" && fail "--irq keep must not touch interrupts" || pass "--irq keep leaves interrupts alone"
contains "would write 0 -> $WORK/proc/sys/kernel/numa_balancing" "$out" && fail "--numa keep must not touch NUMA balancing" || pass "--numa keep leaves NUMA balancing alone"

# A two-core machine has nowhere to steer to: moving every interrupt onto CPU 0
# would put half the machine's work on the core the miner is using.
echo 2 > "$WORK/cores"
out=$(run --numa off --irq steer --profile free)
contains "too few to steer interrupts" "$out" &&
    pass "a two-core machine keeps its interrupt spread" ||
    fail "a two-core machine keeps its interrupt spread"

printf '\n    %s\n\n' "$([ "$FAILED" = "0" ] && echo 'all tuning targets passed' || echo 'FAILURES')"
exit "$FAILED"

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

# MemTotal is the host's and a container's limit is not in it. A plan built from
# 32 GB of host RAM on a 2 GB container reserves 2.3 GB out of the host's pool
# for a mapping the container can never make, which costs the host and helps
# nobody. The fake cgroup here is the container: 1024 MB.
mkdir -p "$WORK/cgroup"
echo 1073741824 > "$WORK/cgroup/memory.max"
# An empty /proc/self/cgroup, so the test does not inherit the layout of the
# machine it runs on: on cgroup v2 the process sits at some nested path that
# does not exist under $WORK, and on v1 it sits somewhere else again.
: > "$WORK/cgroup.self"

limited() { # arguments -> stdout, with a 1024 MB memory limit
    # Eight cores: the two-core case above is its own test, and the page counts
    # below are arithmetic over the thread count.
    echo 8 > "$WORK/cores"
    ZMRIG_CGROUP_ROOT="$WORK/cgroup" \
    ZMRIG_SELF_CGROUP="$WORK/cgroup.self" \
    PATH="$WORK/bin:$PATH" \
    SYS_ROOT="$WORK/sys" \
    PROC_SYS="$WORK/proc/sys" \
    PROC_IRQ="$WORK/proc/irq" \
    CPU_ROOT="$WORK/cpu" \
        bash "$ROOT/scripts/tune-linux.sh" --dry-run "$@" 2>&1
}

out=$(limited --numa off --irq steer --profile free)
contains "this process may use 1024 MB (cgroup limit)" "$out" &&
    pass "the cgroup limit is read and named" ||
    fail "the cgroup limit is read and named"

contains "1024 MB usable of" "$out" &&
    pass "the RAM line reports both numbers instead of the host's" ||
    fail "the RAM line reports both numbers instead of the host's"

# The limit does not just warn: it decides the mode. A 1024 MB container will run
# light whether or not this script agrees, so the plan becomes light too and the
# pages it reserves are the 256 MB cache, not a 2336 MB mapping that cannot exist.
contains "planning light mode instead" "$out" &&
    pass "a dataset larger than the limit switches the plan to light" ||
    fail "a dataset larger than the limit switches the plan to light"

contains "would write 152 -> " "$out" &&
    pass "the reservation is sized for the cache, not the dataset" ||
    fail "the reservation is sized for the cache, not the dataset"

contains "would write 1202 -> " "$out" &&
    fail "a 1024 MB limit must never plan a 2404 MB reservation" ||
    pass "a 1024 MB limit plans no reservation it cannot hold"

contains "(rx/0 light, 8 thread(s))" "$out" &&
    pass "the budget line follows the decided mode" ||
    fail "the budget line follows the decided mode"

contains "--memory=3g" "$out" &&
    pass "the way back to fast mode is named" ||
    fail "the way back to fast mode is named"

# A limit that fits is a plan, not a refusal: 3072 MB holds rx/0's 2404 MB.
echo 3221225472 > "$WORK/cgroup/memory.max"
out=$(limited --profile free)
contains "not reserving pages" "$out" &&
    fail "a limit that fits must still reserve pages" ||
    pass "a limit that fits still reserves pages"
# 2416 MB of fast-mode budget on 8 threads is 1208 pages, under the 3072 MB cap.
contains "would write 1208 -> " "$out" &&
    pass "the reservation is capped by the limit, not by host RAM" ||
    fail "the reservation is capped by the limit, not by host RAM"

# No cgroup at all: the machine's RAM is the truth, as before.
out=$(ZMRIG_CGROUP_ROOT="$WORK/nonexistent" ZMRIG_SELF_CGROUP="$WORK/cgroup.self" \
      PATH="$WORK/bin:$PATH" SYS_ROOT="$WORK/sys" PROC_SYS="$WORK/proc/sys" \
      PROC_IRQ="$WORK/proc/irq" CPU_ROOT="$WORK/cpu" \
      bash "$ROOT/scripts/tune-linux.sh" --dry-run --profile free 2>&1)
contains "cgroup limit" "$out" &&
    fail "no cgroup must not produce a limit line" ||
    pass "a machine without a cgroup limit plans from MemTotal"

printf '\n    %s\n\n' "$([ "$FAILED" = "0" ] && echo 'all tuning targets passed' || echo 'FAILURES')"
exit "$FAILED"

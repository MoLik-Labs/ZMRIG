#!/usr/bin/env bash
#
# tune-linux.sh - prepare a Linux host for maximum RandomX hashrate.
#
# Everything this script changes is a runtime knob that the miner benefits from
# but cannot change itself (it would need root). Nothing is written to the GPU
# or to any persistent storage except the small sysfs/procfs values listed
# below, which the kernel resets on reboot.
#
# Usage:
#   sudo ./scripts/tune-linux.sh                # apply the recommended preset
#   sudo ./scripts/tune-linux.sh --dry-run      # show what would be changed
#   sudo ./scripts/tune-linux.sh --hugepages 1G # reserve 1GB pages instead of 2MB
#   sudo ./scripts/tune-linux.sh --profile watt # keep the CPU's power saving
#                                               # governor (max hashrate per watt)
#   sudo ./scripts/tune-linux.sh --algo panthera # reserve for Scala instead of
#                                               # Monero (192 MB, not 2336 MB)
#   sudo ./scripts/tune-linux.sh --mode eco      # size the pool for the threads
#                                               # eco actually runs, not for all
#   sudo ./scripts/tune-linux.sh --pages 1200    # obey an exact page count
#   ./scripts/tune-linux.sh --status            # read-only report (no root needed)
#
# The memory arithmetic is not repeated here: it comes from os/plan.sh, the same
# library the initramfs and `zmrig-os` use, so a rig cannot be tuned for one
# number and boot with another.
#
# Revert:
#   echo 0 | sudo tee /proc/sys/vm/nr_hugepages
#   echo madvise | sudo tee /sys/kernel/mm/transparent_hugepage/enabled
#
set -euo pipefail

HUGE_MODE="2M"          # 2M | 1G | off
THP_MODE="always"       # always | madvise | off
SWAPPINESS="10"
SET_GOVERNOR="performance"
PROFILE="auto"
NUMA_BALANCE="keep"     # off | on | keep
IRQ_MODE="keep"         # steer | keep
# Overridable so the profile/gonernor logic can be tested against a fake tree
# instead of real sysfs (a governor test must not change the test machine).
CPU_ROOT="${CPU_ROOT:-/sys/devices/system/cpu}"
# Narrower overrides for the interrupt and NUMA steps below: the rest of the
# script still writes absolute paths, so these exist only so the new logic can be
# exercised against a fake tree instead of the machine running the test.
SYS_ROOT="${SYS_ROOT:-/sys}"
PROC_SYS="${PROC_SYS:-/proc/sys}"
PROC_IRQ="${PROC_IRQ:-/proc/irq}"
POWER_SUPPLY_ROOT="${POWER_SUPPLY_ROOT:-/sys/class/power_supply}"
DRY_RUN=0
STATUS_ONLY=0
QUIET=0

# RandomX memory per algorithm. The seven configurations are not the same size:
# the RandomX family needs a 2080 MB dataset behind a 256 MB cache, while
# Panthera/Scala needs 64 MB behind 128 MB. Reserving Monero's 2.3 GB for a coin
# that fits in 192 MB is how a 1 GB VPS ends up refusing to start.
ALGO="${ALGO:-rx/0}"
MODE="${MODE:-max}"      # max | balanced | eco | light: decides the thread count
THREADS_WANT=""          # an explicit thread count beats the mode
PAGES_WANT=""            # an explicit page count beats the arithmetic
DATASET_MB=0             # filled in from os/plan.sh after parsing
CACHE_MB=0


color() {
    if [ -t 1 ]; then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi
}
info()  { [ "$QUIET" = 1 ] && return 0; printf ' * %s\n' "$*"; }
warn()  { printf ' ! %s\n' "$*"; }
ok()    { printf ' %s %s\n' "$(color '1;32' 'OK')" "$*"; }
step()  { [ "$QUIET" = 1 ] && return 0; printf '\n%s\n' "$(color '1;36' "$*")"; }

usage() {
    # The header is the comment block at the top; printing "until the first line
    # that is not a comment" cannot drift when a line is added to it.
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)        DRY_RUN=1 ;;
        --status)         STATUS_ONLY=1 ;;
        --hugepages)      HUGE_MODE="${2:-2M}"; shift ;;
        --hugepages=*)    HUGE_MODE="${1#*=}" ;;
        --thp)            THP_MODE="${2:-always}"; shift ;;
        --thp=*)          THP_MODE="${1#*=}" ;;
        --swappiness)     SWAPPINESS="${2:-10}"; shift ;;
        --swappiness=*)   SWAPPINESS="${1#*=}" ;;
        --no-governor)    SET_GOVERNOR="" ;;
        --profile)        PROFILE="${2:-auto}"; shift ;;
        --profile=*)      PROFILE="${1#*=}" ;;
        --numa)           NUMA_BALANCE="${2:-off}"; shift ;;
        --numa=*)         NUMA_BALANCE="${1#*=}" ;;
        --irq)            IRQ_MODE="${2:-steer}"; shift ;;
        --irq=*)          IRQ_MODE="${1#*=}" ;;
        --algo)           ALGO="${2:-rx/0}"; shift ;;
        --algo=*)         ALGO="${1#*=}" ;;
        --mode)           MODE="${2:-max}"; shift ;;
        --mode=*)         MODE="${1#*=}" ;;
        --threads)        THREADS_WANT="${2:-}"; shift ;;
        --threads=*)      THREADS_WANT="${1#*=}" ;;
        --pages)          PAGES_WANT="${2:-}"; shift ;;
        --pages=*)        PAGES_WANT="${1#*=}" ;;
        -q|--quiet)       QUIET=1 ;;
        -h|--help)        usage ;;
        *)                warn "unknown option: $1"; usage ;;
    esac
    shift
done

# The memory arithmetic lives in os/plan.sh, because three programs need the same
# answer: the initramfs reserves pages before userspace exists, `zmrig-os tune`
# re-applies them at boot, and this script is what that command calls. Two copies
# of "how many pages does this algorithm need" is one copy too many.
PLAN_SH="${PLAN_SH:-}"
if [ -z "$PLAN_SH" ]; then
    for cand in "$(dirname -- "$0")/plan.sh" "$(dirname -- "$0")/../os/plan.sh"; do
        if [ -r "$cand" ]; then PLAN_SH="$cand"; break; fi
    done
fi
if [ -z "$PLAN_SH" ]; then
    echo "error: os/plan.sh not found next to this script or in ../os/" >&2
    echo "       run it from a checkout of the repository, or set PLAN_SH=/path/to/plan.sh" >&2
    exit 1
fi
# shellcheck source=/dev/null
. "$PLAN_SH"

read_meminfo() { awk -v k="$1" '$1 == k":" { print $2 }' /proc/meminfo; }

mem_total_mb=$(( $(read_meminfo MemTotal) / 1024 ))
# ...but MemTotal is the host's, and it is not namespaced. Inside a container or
# a `systemd MemoryMax=` slice the limit is the number that decides whether a
# 2.3 GB pool is useful or is 2.3 GB taken away from the machine for a dataset
# this process cannot map.
mem_limit_mb=$(plan_memory_limit_mb)
if [ -n "$mem_limit_mb" ] && [ "$mem_limit_mb" -gt 0 ] && [ "$mem_limit_mb" -lt "$mem_total_mb" ]; then
    info "memory: this process may use ${mem_limit_mb} MB (cgroup limit); the host reports ${mem_total_mb} MB"
    MEM_HOST_MB=$mem_total_mb
    MEM_LIMITED=1
    mem_total_mb=$mem_limit_mb
fi
cores=$(nproc)

# The mode decides how many threads the miner will actually run, and the thread
# count decides the scratchpads: a `balanced` rig on 8 CPUs runs 7, not 8.
threads=$(plan_threads "$MODE" "$cores" "$THREADS_WANT")
DATASET_MB=$(plan_dataset_mb "$ALGO")
CACHE_MB=$(plan_cache_mb "$ALGO")
required_mb=$(plan_need_mb "$ALGO" "$MODE" "$cores" "$THREADS_WANT")
# Pages, capped at RAM minus 512 MB: a partial pool is still worth having, while
# asking for more pages than exist leaves nothing reserved.
PAGES=$(plan_pages "$ALGO" "$MODE" "$cores" "$mem_total_mb" 2048 "$THREADS_WANT" "$PAGES_WANT")

# The dataset and the cache are what the 1 GB pool has to hold: three of them
# would be absurd for a 192 MB Scala rig and not enough if the hash was huge.
GIGA_PAGES=$(( (required_mb + 1023) / 1024 ))
[ "$GIGA_PAGES" -lt 1 ] && GIGA_PAGES=1

# A pool smaller than the dataset is not a partial win. RandomX asks for one
# contiguous mapping, so 900 MB of pages behind a 2336 MB request is a mapping
# that does not exist - the miner falls back to 4 KiB pages and the host has
# lost 900 MB for nothing. When the cgroup is the smaller number, say why and
# leave the kernel alone.
if [ "${MEM_LIMITED:-0}" -eq 1 ] && [ "$required_mb" -gt "$mem_total_mb" ]; then
    if [ -n "$PAGES_WANT" ]; then
        warn "the ${ALGO} ${MODE} dataset needs ${required_mb} MB and this process may use ${mem_total_mb} MB; reserving ${PAGES_WANT} page(s) anyway because --pages asked for it"
    else
        warn "the ${ALGO} ${MODE} dataset needs ${required_mb} MB but this process may only use ${mem_total_mb} MB: not reserving pages (the miner will run in light mode, ~10x slower)"
        warn "give the container more memory, or set --mode light so the plan matches what will run"
        HUGE_MODE="off"
    fi
fi

show_status() {
    step "Current state"

    local hp_total hp_free hp_size
    hp_total=$(read_meminfo HugePages_Total)
    hp_free=$(read_meminfo HugePages_Free)
    hp_size=$(read_meminfo Hugepagesize)
    if [ -n "${MEM_HOST_MB:-}" ]; then
        info "Hardware: ${cores} threads, ${mem_total_mb} MB usable of ${MEM_HOST_MB} MB (cgroup limit)"
    else
        info "Hardware: ${cores} threads, ${mem_total_mb} MB RAM"
    fi

    if [ "${hp_total:-0}" -gt 0 ] 2>/dev/null; then
        ok "2MB huge pages: ${hp_free}/${hp_total} free (${hp_size} kB each)"
    else
        warn "2MB huge pages: none reserved (RandomX will run with 4KB pages -> ~18% slower, measured)"
    fi

    local one_g
    one_g=$(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages 2>/dev/null || echo 0)
    if [ "${one_g:-0}" -gt 0 ] 2>/dev/null; then
        ok "1GB huge pages: ${one_g} reserved (best case for RandomX)"
    else
        info "1GB huge pages: not reserved (optional, needs ${DATASET_MB}MB+ of free contiguous RAM)"
    fi

    if [ -r /sys/kernel/mm/transparent_hugepage/enabled ]; then
        info "THP: $(cat /sys/kernel/mm/transparent_hugepage/enabled)"
    fi

    if [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
        info "CPU governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
    else
        info "CPU governor: not exposed by this kernel (VM or locked BIOS)"
    fi

    if [ -e /dev/cpu/0/msr ]; then
        ok "MSR access: /dev/cpu/0/msr available (rdmsr/wrmsr mod can be applied)"
    elif lsmod 2>/dev/null | grep -q '^msr '; then
        warn "MSR module loaded but /dev/cpu/0/msr missing"
    else
        warn "MSR access: module not loaded -> run this script as root to enable the MSR mod"
    fi

    info "RandomX memory budget for this host: ~${required_mb} MB (${ALGO} ${MODE}, ${threads} thread(s))"
    info "dataset ${DATASET_MB} MB + cache ${CACHE_MB} MB for ${ALGO}"
    if [ "$HUGE_MODE" = "off" ]; then
        info "plan: no reservation (huge pages off, or the dataset does not fit this process's memory limit)"
    else
        info "plan: ${PAGES} x 2MB pages, or ${GIGA_PAGES} x 1GB page(s); ${mem_total_mb} MB RAM"
    fi
}

if [ "$STATUS_ONLY" -eq 1 ]; then
    show_status
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    warn "this script must run as root to change kernel settings"
    show_status
    exit 1
fi

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '   would run: %s\n' "$*"
        return 0
    fi
    if "$@"; then return 0; fi
    warn "failed: $*"
    return 1
}

write_value() {
    local path="$1" value="$2"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '   would write %s -> %s\n' "$value" "$path"
        return 0
    fi
    if printf '%s\n' "$value" > "$path" 2>/dev/null; then
        ok "$path = $value"
    else
        warn "cannot write $path (read-only or unsupported)"
    fi
}

# Same as write_value, but without the "OK" line: for values the kernel accepts
# and then silently clamps, the read-back below is the only honest report.
write_value_quiet() {
    local path="$1" value="$2"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '   would write %s -> %s\n' "$value" "$path"
        return 0
    fi
    printf '%s\n' "$value" > "$path" 2>/dev/null || warn "cannot write $path (read-only or unsupported)"
}

step "1. Huge pages"
# The kernel clamps nr_hugepages to what it can actually carve out, so a write
# that "succeeds" can still leave the miner on 4 KiB pages. Always read back.
verify_huge_pages() {
    local want="$1"
    [ "$DRY_RUN" -eq 1 ] && return 0
    local got
    got=$(cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages 2>/dev/null || echo 0)
    if [ "$got" -ge "$want" ]; then
        ok "verified: ${got} x 2MB pages reserved ($((got * 2)) MB)"
    elif [ "$got" -gt 0 ]; then
        warn "only ${got} of ${want} pages could be reserved ($((got * 2)) MB); the miner will report a partial fallback"
        warn "free memory or lower the reservation, then re-run"
    else
        warn "the kernel reserved 0 pages: the miner will fall back to 4 KiB pages and lose ~18% hashrate"
        warn "this is common inside containers (read-only /proc/sys) - reserve on the host instead"
    fi
}

case "$HUGE_MODE" in
    2M)
        pages=$PAGES
        if [ -n "$PAGES_WANT" ]; then
            info "reserving ${pages} x 2MB pages (${PAGES_WANT} asked for; the miner needs ${required_mb}MB)"
        else
            info "reserving ${pages} x 2MB pages ($((pages * 2))MB >= ${required_mb}MB needed for ${ALGO} ${MODE}, ${threads} thread(s))"
        fi
        write_value /proc/sys/vm/nr_hugepages "$pages"
        verify_huge_pages "$pages"
        ;;
    1G)
        if [ "$(read_meminfo Hugepagesize)" != "2048" ] && [ "$DRY_RUN" -eq 0 ]; then
            info "kernel default huge page size is not 2MB, continuing anyway"
        fi
        info "reserving ${GIGA_PAGES} x 1GB page(s) (dataset + cache); needs ${required_mb}MB+ free contiguous RAM"
        write_value_quiet /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages "$GIGA_PAGES"

        # Same trap as the 2MB pool: the kernel accepts the write and keeps 0
        # when it cannot find a contiguous gigabyte. Read back and fall back to
        # the 2MB pool instead of leaving the miner without huge pages at all.
        if [ "$DRY_RUN" -eq 0 ]; then
            got_1g=$(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages 2>/dev/null || echo 0)
            if [ "${got_1g:-0}" -ge "$GIGA_PAGES" ]; then
                ok "verified: ${got_1g} x 1GB pages reserved"
            elif [ "${got_1g:-0}" -gt 0 ]; then
                warn "only ${got_1g} of ${GIGA_PAGES} 1GB pages could be reserved; falling back to 2MB pages"
                pages=$PAGES
                write_value /proc/sys/vm/nr_hugepages "$pages"
                verify_huge_pages "$pages"
            else
                warn "the kernel reserved no 1GB pages (no contiguous 1GB block or 1GB pages unsupported)"
                info "falling back to 2MB pages, which give the same RandomX speed"
                pages=$PAGES
                write_value /proc/sys/vm/nr_hugepages "$pages"
                verify_huge_pages "$pages"
            fi
        fi
        ;;
    off)
        info "skipping huge page reservation"
        ;;
    *)
        warn "unknown --hugepages value '$HUGE_MODE' (expected 2M, 1G or off)"
        ;;
esac

step "2. Transparent huge pages"
if [ -w /sys/kernel/mm/transparent_hugepage/enabled ]; then
    write_value /sys/kernel/mm/transparent_hugepage/enabled "$THP_MODE"
    if [ -w /sys/kernel/mm/transparent_hugepage/defrag ]; then
        # "defer" keeps khugepaged from stalling mining threads with direct reclaim.
        write_value /sys/kernel/mm/transparent_hugepage/defrag defer
    fi
else
    warn "THP controls not writable, skipping"
fi

step "3. VM tunables"
write_value /proc/sys/vm/swappiness "$SWAPPINESS"
if [ -w /proc/sys/vm/compact_memory ]; then
    info "compacting memory so the 2MB reservations can be fulfilled"
    run sh -c 'echo 1 > /proc/sys/vm/compact_memory' || true
fi

step "3b. NUMA balancing"
# The kernel migrates pages between NUMA nodes while a process runs. A miner's
# 2.3 GiB dataset is walked uniformly at random, so a migration is a stalled hash
# that buys nothing: the threads are memory-bound and they never move node. On a
# single-node machine the setting exists and does nothing, which is the cost.
case "$NUMA_BALANCE" in
    off|on)
        if [ -w "${PROC_SYS}/kernel/numa_balancing" ]; then
            if [ "$NUMA_BALANCE" = "off" ]; then
                write_value "${PROC_SYS}/kernel/numa_balancing" 0
            else
                write_value "${PROC_SYS}/kernel/numa_balancing" 1
            fi
        else
            info "numa_balancing is not exposed by this kernel"
        fi
        ;;
    keep)
        info "numa_balancing left as it was"
        ;;
    *)
        warn "unknown --numa value '$NUMA_BALANCE' (off, on or keep)"
        ;;
esac

step "3c. Interrupts and unbound work"
# An interrupt that lands on a core running a RandomX thread costs that thread
# its working set. Steering device interrupts to the first core keeps the mining
# cores quiet, and the first core is the one that would have been doing this
# anyway. On a two-core machine there is nowhere to steer to, so it is skipped.
if [ "$IRQ_MODE" = "steer" ]; then
    if [ "${cores:-1}" -lt 4 ]; then
        info "${cores} core(s): too few to steer interrupts away from the miner"
    else
        steered=0
        for f in "${PROC_IRQ}"/[0-9]*/smp_affinity_list; do
            [ -w "$f" ] || continue
            [ "$(cat "$f" 2>/dev/null)" = "0" ] && continue
            if [ "$DRY_RUN" -eq 1 ]; then
                printf '   would write 0 to %s\n' "$f"
            else
                printf '0' > "$f" 2>/dev/null || continue
            fi
            steered=$((steered + 1))
        done
        info "interrupts on CPU 0: ${steered} handler(s) moved"

        # Unbound workqueues are the other half: they run kernel work on whatever
        # CPU looks idle, which is the CPU the miner is using.
        for f in "${SYS_ROOT}/devices/virtual/workqueue/cpumask" "${SYS_ROOT}"/devices/virtual/workqueue/*/cpumask; do
            [ -w "$f" ] || continue
            if [ "$DRY_RUN" -eq 1 ]; then
                printf '   would write 1 to %s\n' "$f"
            else
                printf '1' > "$f" 2>/dev/null || continue
            fi
        done
        info "unbound workqueues on CPU 0"
    fi
else
    info "interrupt affinity left as it was"
fi

step "4. CPU governor"

# The profile decides this, and it is the clearest place the two profiles differ.
#
# `performance` pins every core to its highest frequency. That is the right
# answer when the electricity is free: the binning-aware governor never has to
# ramp, so a block of work never starts at a low clock.
#
# Under `watt` it is the wrong answer. Power grows with V^2*f, and a mining
# thread that is stalled on memory does not need the top bin: pinning the clock
# up spends joules on waits. The distro default (`schedutil` on most systems)
# already tracks utilisation, so the watt profile keeps it and only reports
# what it found.
case "$PROFILE" in
    auto)
        # A laptop on battery is the case the watt profile exists for.
        for bat in "${POWER_SUPPLY_ROOT}"/BAT*; do
            [ -r "${bat}/status" ] || continue
            if [ "$(cat "${bat}/status" 2>/dev/null)" = "Discharging" ]; then
                PROFILE="watt"
                info "on battery: using the watt profile for the governor"
                break
            fi
        done
        [ "$PROFILE" = "auto" ] && PROFILE="free"
        ;;
esac

if [ -d "${CPU_ROOT}/cpu0/cpufreq" ]; then
    case "$PROFILE" in
        watt)
            # Do not fight the firmware: leave the governor alone unless the
            # machine is stuck on `performance`, which is the one setting that
            # actively wastes power while waiting on memory.
            for gov in "${CPU_ROOT}"/cpu*/cpufreq/scaling_governor; do
                [ -w "$gov" ] || continue
                current=$(cat "$gov" 2>/dev/null || true)
                [ "$current" = "performance" ] || continue
                if grep -qx schedutil "${CPU_ROOT}/cpu0/cpufreq/scaling_available_governors" 2>/dev/null; then
                    write_value "$gov" schedutil
                elif grep -qx powersave "${CPU_ROOT}/cpu0/cpufreq/scaling_available_governors" 2>/dev/null; then
                    write_value "$gov" powersave
                fi
            done
            info "profile watt: the CPU keeps its power-saving governor (max hashrate per watt)"
            ;;
        free)
            if [ -n "$SET_GOVERNOR" ]; then
                for gov in "${CPU_ROOT}"/cpu*/cpufreq/scaling_governor; do
                    [ -w "$gov" ] || continue
                    write_value "$gov" "$SET_GOVERNOR"
                done
            fi
            ;;
        *)
            warn "unknown profile '${PROFILE}' (auto, free or watt); leaving the governor alone"
            ;;
    esac
else
    info "governor control not available or disabled"
fi

step "5. MSR access"
if [ ! -e /dev/cpu/0/msr ]; then
    run modprobe msr || warn "modprobe msr failed (kernel module may be missing)"
fi
if [ -e /dev/cpu/0/msr ]; then
    ok "MSR device present, xmrig can apply the RandomX MSR preset"
else
    warn "no MSR device: RandomX will run without the memory latency fix"
fi

step "6. Transparent page sharing (optional, reduces latency variance)"
if [ -w /sys/kernel/mm/ksm/run ]; then
    if [ "$DRY_RUN" -eq 0 ]; then
        printf '   KSM state: %s (leave disabled for mining)\n' "$(cat /sys/kernel/mm/ksm/run)"
    fi
fi

step "Summary"
show_status

cat <<'EOF'

Next steps:
  1. Run the miner as root (or with CAP_SYS_RAWIO + CAP_IPC_LOCK + CAP_SYS_NICE) so
     huge pages, MSR writes and thread priorities are applied:
         sudo zmrig -c /etc/zmrig/config.json --msr
  2. Verify what the miner actually got, without mining:
         zmrig -o POOL:PORT -u WALLET --check
     The memory line says "huge pages reserved" when the reservation worked,
     and the msr line says whether the device is readable.
  3. The startup log repeats it:
         "hash engine ready: ..., huge pages 2336 MB (explicit)"
     A "(THP fallback)" or "(partial)" suffix means the kernel did not hand out
     the 2 MiB pages, and the hashrate drops ~24 %.
  4. These settings are not persistent across reboots. To persist them, call this
     script from a systemd unit or /etc/rc.local.
EOF

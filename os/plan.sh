#!/bin/sh
# plan.sh - the decisions the boot and the control tool must agree on.
#
# Two of them: how much memory to reserve as 2 MiB pages, and which CPUs to keep
# for mining. Both are arithmetic over arguments and /sys, with no side effects,
# so the initramfs can run them before userspace exists and a shell test can run
# them on a fake tree. Everything that *does* something with the answer (writing
# /proc/sys/vm/nr_hugepages, setting an IRQ mask) lives in os/init and in
# zmrig-os, where --dry-run can skip it.
#
# Sourced by:
#   os/init            PID 1 of the initramfs: reserves before memory fragments
#   zmrig-os           tune, doctor, args, isolate, run
#   os/tests/plan.sh   the numbers, without a kernel

# MiB of RandomX memory an algorithm needs, from the C engine's configuration.
# The seven configurations in this tree are not the same size, and reserving
# Monero's 2.3 GB for a coin whose dataset is 64 MB is how a 1 GB box ends up
# with pages it cannot use and a warning it cannot clear.
plan_cache_mb() {
    case "${1:-}" in
        panthera|xla|scala|rx/xla|rx/panthera) printf '%s' 128 ;;
        *) printf '%s' 256 ;;
    esac
}

plan_dataset_mb() {
    case "${1:-}" in
        panthera|xla|scala|rx/xla|rx/panthera) printf '%s' 64 ;;
        *) printf '%s' 2080 ;;
    esac
}

# Threads a mode will run on a machine with `cores` logical CPUs. `max` and
# `light` mean every logical CPU; balanced and safe leave one for the OS, eco
# takes half. An explicit count always wins - that is the difference between a
# measurement and somebody's decision.
plan_threads() { # mode cores [threads]
    local mode="$1" cores="$2" explicit="${3:-}"
    case "$explicit" in
        ''|auto) ;;
        *[!0-9]*) ;;
        *) printf '%s' "$explicit"; return 0 ;;
    esac
    case "$mode" in
        balanced|safe) if [ "$cores" -ge 4 ]; then printf '%s' "$((cores - 1))"; else printf '%s' "$cores"; fi ;;
        eco)           printf '%s' "$(( cores / 2 > 0 ? cores / 2 : 1 ))" ;;
        *)             printf '%s' "$cores" ;;
    esac
}

# MiB worth reserving as huge pages:
#
#   fast (anything but light)  dataset + cache + one 2 MiB scratchpad per thread
#                              + 64 MiB of slack for the allocator
#   light                      the cache only: the dataset is rebuilt from it
#                              per hash, so it is never mapped
plan_need_mb() { # algo mode cores [threads]
    local algo="$1" mode="$2" cores="$3" threads cache dataset
    cache=$(plan_cache_mb "$algo")
    dataset=$(plan_dataset_mb "$algo")
    threads=$(plan_threads "$mode" "$cores" "${4:-}")
    if [ "$mode" = "light" ]; then
        printf '%s' "$(( cache + threads * 2 + 32 ))"
    else
        printf '%s' "$(( cache + dataset + threads * 2 + 64 ))"
    fi
}

# Pages of `page_kb` to reserve. An explicit override (zmrig.os.hugepages=N) is
# obeyed exactly, including 0 for "none". Otherwise the answer is plan_need_mb,
# capped at the machine's RAM minus 512 MiB: a partial pool is still worth
# having - the miner maps the rest with transparent huge pages - while asking
# for more pages than exist makes the write fail and leaves nothing reserved.
plan_pages() { # algo mode cores total_mb page_kb [threads] [override]
    local algo="$1" mode="$2" cores="$3" total_mb="$4" page_kb="$5"
    local threads="${6:-}" override="${7:-}" need cap

    case "$page_kb" in ''|0|*[!0-9]*) printf '%s' 0; return 0 ;; esac

    case "$override" in
        ''|auto) need=$(plan_need_mb "$algo" "$mode" "$cores" "$threads") ;;
        *[!0-9]*) need=$(plan_need_mb "$algo" "$mode" "$cores" "$threads") ;;
        *) printf '%s' "$(( override ))"; return 0 ;;
    esac

    case "$total_mb" in ''|*[!0-9]*) total_mb=0 ;; esac
    if [ "$total_mb" -gt 512 ]; then
        cap=$(( total_mb - 512 ))
        [ "$need" -gt "$cap" ] && need="$cap"
    fi

    printf '%s' "$(( (need * 1024 + page_kb - 1) / page_kb ))"
}

# How many physical cores a set of CPUs amounts to: the number of distinct
# thread-sibling groups it touches. Isolation takes whole groups, so on an SMT
# machine this is half the list and on a non-SMT machine it is all of it — and
# the thread count must follow the cores, not the CPUs.
plan_iso_groups() { # sys_root cpus...
    local sys="$1"; shift
    [ "$#" -gt 0 ] || { printf '0'; return 0; }
    local cpu group seen=""
    for cpu in "$@"; do
        group=$(cat "$sys/devices/system/cpu/cpu${cpu}/topology/thread_siblings_list" 2>/dev/null || true)
        [ -n "$group" ] || group="$cpu"
        printf '%s\n' "$group"
    done | sort -u | awk 'END { print NR }'
}

# Hex bit mask for `--cpu-affinity`, from a list of CPU numbers. Empty output
# means "no mask": beyond 64 CPUs a 64-bit mask cannot describe the set, and a
# wrong mask pins the miner to the wrong cores.
plan_mask_hex() { # cpus...
    [ "$#" -gt 0 ] || return 0
    awk -v list="$*" 'BEGIN {
        n = split(list, cpus, " ")
        max = -1
        for (i = 1; i <= n; i++) { c = cpus[i] + 0; if (c > max) max = c }
        if (max < 0 || max > 63) exit 1
        for (i = 0; i < 16; i++) nib[i] = 0
        for (i = 1; i <= n; i++) { c = cpus[i] + 0; nib[int(c / 4)] = nib[int(c / 4)] + 2 ^ (c % 4) }
        out = ""
        for (i = 15; i >= 0; i--) out = out substr("0123456789abcdef", nib[i] + 1, 1)
        sub(/^0+/, "", out)
        if (out == "") out = "0"
        print out
        exit
    }' 2>/dev/null
}

# The CPUs to keep for mining: `want` logical CPUs, taken as whole SMT groups.
#
# Whole groups, not single logical CPUs: on an SMT machine cpu4 is the twin of
# cpu0, so isolating one of a pair puts the miner next to the housekeeping work
# of the other. Groups are taken from the high end, which leaves cpu0 - where
# every IRQ and most kernel threads land by default - in the housekeeping set.
#
# A whole group is never split, so the result can be smaller than `want`: asking
# for 3 on a 4-core/8-thread machine gives 2, because the third CPU would be the
# twin of one that is not isolated. The caller prints what it actually got.
#
# Prints an ascending, space-separated list; empty means "isolate nothing",
# because nothing was asked for or because the machine cannot spare it.
plan_iso_cpus() { # sys_root cores_wanted total_cpus
    local sys="$1" want="$2" total="$3" line cpu groups=""

    case "$want" in ''|0|*[!0-9]*) return 0 ;; esac
    [ "$total" -lt 2 ] && return 0
    [ "$want" -ge "$total" ] && return 0

    for line in "$sys"/devices/system/cpu/cpu[0-9]*/topology/thread_siblings_list; do
        [ -r "$line" ] || continue
        cpu=$(printf '%s' "$line" | sed 's|.*/cpu\([0-9]*\)/.*|\1|')
        case "$cpu" in ''|*[!0-9]*) continue ;; esac
        groups="$groups$cpu $(cat "$line" 2>/dev/null)
"
    done

    # No topology at all (a container, an old kernel): one CPU, one core.
    [ -n "$groups" ] || groups=$(awk -v total="$total" 'BEGIN { for (i = 0; i < total; i++) printf "%d %d\n", i, i }')

    printf '%s\n' "$groups" | awk -v want="$want" -v total="$total" '
        function expand(list,   n, i, parts, tok, ab, a, b, k, out) {
            out = ""
            n = split(list, parts, ",")
            for (i = 1; i <= n; i++) {
                tok = parts[i]
                # Only CPUs the kernel currently has: a sibling list can name a
                # CPU that is offline or beyond the count nproc reports, and a
                # group made of those is not a core this machine can spare.
                if (index(tok, "-") > 0) {
                    split(tok, ab, "-")
                    a = ab[1] + 0; b = ab[2] + 0
                    for (k = a; k <= b; k++) if (k < total) out = out " " k
                } else {
                    n2 = tok + 0
                    if (n2 < total) out = out " " n2
                }
            }
            return out
        }
        NF >= 2 {
            key = $2
            gsub(/[ \t]/, "", key)
            if (key in seen) next
            seen[key] = 1
            list = expand(key)
            n = split(list, sibs, " ")
            if (n == 0 || (n == 1 && sibs[1] == "")) next
            top = -1
            for (i = 1; i <= n; i++) if (sibs[i] + 0 > top) top = sibs[i] + 0
            printf "%d %s\n", top, list
        }' | sort -rn | awk -v want="$want" -v total="$total" '
        {
            n = split($0, f, " ")
            members[NR] = ""
            cnt[NR] = 0
            for (i = 2; i <= n; i++) { members[NR] = members[NR] " " f[i]; cnt[NR]++ }
            groups = NR
        }
        END {
            chosen = 0
            out = ""
            for (i = 1; i <= groups; i++) {
                if (chosen + cnt[i] > want) continue
                if (total - chosen - cnt[i] < 1) continue
                out = out members[i]
                chosen += cnt[i]
            }
            print out
        }' | tr ' ' '\n' | awk 'NF' | sort -n | tr '\n' ' ' | sed 's/^ *//; s/ *$//'
}

# The CPUs that are not isolated: everything the kernel and every IRQ may use.
plan_housekeeping() { # total_cpus isolated...
    local total="$1"; shift
    awk -v total="$total" -v list=" $* " 'BEGIN {
        out = ""
        for (i = 0; i < total; i++) {
            if (index(list, " " i " ") == 0) out = out " " i
        }
        sub(/^ /, "", out)
        print out
        exit
    }'
}

# A comparable description of a CPU set: "4-7" rather than "4 5 6 7", because it
# is written to a config file, a GRUB environment block and a help message.
plan_join_list() { # cpus...
    [ "$#" -gt 0 ] || return 0
    awk 'BEGIN {
        n = 0
        for (i = 1; i < ARGC; i++) {
            v = ARGV[i] + 0
            if (v in seen) continue
            seen[v] = 1
            nums[n++] = v
        }
        for (i = 0; i < n; i++) for (j = i + 1; j < n; j++)
            if (nums[j] < nums[i]) { t = nums[i]; nums[i] = nums[j]; nums[j] = t }
        out = ""
        i = 0
        while (i < n) {
            j = i
            while (j + 1 < n && nums[j + 1] == nums[j] + 1) j++
            piece = (i == j) ? nums[i] "" : nums[i] "-" nums[j]
            out = (out == "") ? piece : out "," piece
            i = j + 1
        }
        print out
        exit
    }' "$@"
}

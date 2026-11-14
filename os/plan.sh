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

# MiB this process may actually use, when a cgroup says so, otherwise nothing.
#
# `/proc/meminfo` is the *host's*, and it is not namespaced: a VPS whose
# container has 2 GB of a 32 GB machine reports 32 GB, and a page count computed
# from that number reserves 2.3 GB of the host's pool for a dataset that will
# never fit in the container. The cgroup limit is the only memory figure that is
# still true inside one, so it is what the plan is capped against.
#
# v2 is `memory.max` in bytes or "max"; v1 is `memory.limit_in_bytes`, where
# "unlimited" is a number close to 2^63. Both are read at the path
# `/proc/self/cgroup` names, falling back to the root, because a nested cgroup
# is the normal case on a host that runs anything else. ZMRIG_CGROUP_ROOT
# exists for the tests, exactly as it does in zmrig's topology.zig.
plan_memory_limit_mb() {
    local root="${ZMRIG_CGROUP_ROOT:-/sys/fs/cgroup}"
    local self="${ZMRIG_SELF_CGROUP:-/proc/self/cgroup}"
    local rel="" value mb

    # The path this process sits at, in either hierarchy. v2 is the line whose
    # hierarchy id is 0 and whose controllers field is empty; v1 is the line
    # that lists `memory` among its controllers. Parsing both is not defensive
    # programming for its own sake - a v1 host would otherwise read the root
    # hierarchy, which is unlimited, and silently plan from the host's RAM
    # again, which is the bug this function exists to fix.
    if [ -r "$self" ]; then
        rel=$(awk -F: '$1 == "0" && $3 != "" { print $3; exit }' "$self" 2>/dev/null)
        case "$rel" in
            /*) ;;
            *)
                rel=$(awk -F: '$2 ~ /(^|,)memory(,|$)/ && $3 != "" { print $3; exit }' "$self" 2>/dev/null)
                ;;
        esac
        [ "$rel" = "/" ] && rel=""
    fi

    for value in \
        "${root}${rel}/memory.max" \
        "${root}/memory.max" \
        "${root}/memory${rel}/memory.limit_in_bytes" \
        "${root}/memory/memory.limit_in_bytes"
    do
        [ -r "$value" ] || continue
        mb=$(cat "$value" 2>/dev/null) || continue
        case "$mb" in
            ''|max) continue ;;
            *[!0-9]*) continue ;;
        esac
        # v1 spells "no limit" as 9223372036854771712, which is 19 digits: no
        # real limit has that many, and comparing it in shell arithmetic is the
        # kind of overflow that turns a diagnostic into an abort.
        [ "${#mb}" -ge 19 ] && continue
        printf '%s' "$(( mb / 1048576 ))"
        return 0
    done
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

# 1 GiB pages worth reserving at boot for a dataset of `need_mb`.
#
# The gigantic pool is the last TLB win available to RandomX - 1040 entries at
# 2 MiB, two at 1 GiB - and it can only be created before the machine fragments,
# which is why it is a kernel parameter and not a sysctl. It also never comes
# back: the memory is out of the machine for as long as it boots. So the answer
# is a count only when the machine can spare it, and empty when it cannot.
#
# 2 GiB is what has to stay for the kernel, the page cache, the shell and the
# verifier the pool runs. A rig that swaps to serve a TLB win mines slower than
# the one that never asked.
plan_gigantic_pages() { # need_mb total_mb
    local need="${1:-0}" total="${2:-0}" pages

    case "$need" in ''|*[!0-9]*) printf '%s' ''; return 0 ;; esac
    case "$total" in ''|*[!0-9]*) printf '%s' ''; return 0 ;; esac
    [ "$need" -gt 0 ] || { printf '%s' ''; return 0; }

    pages=$(( (need + 1023) / 1024 ))
    [ "$total" -ge $(( pages * 1024 + 2048 )) ] || { printf '%s' ''; return 0; }

    printf '%s' "$pages"
}

# How many physical cores a set of CPUs amounts to: the number of distinct
# thread-sibling groups it touches. Isolation takes whole groups, so on an SMT
# machine this is half the list and on a non-SMT machine it is all of it — and
# the thread count must follow the cores, not the CPUs.
plan_iso_groups() { # sys_root cpus...
    local sys="$1"; shift
    [ "$#" -gt 0 ] || { printf '0'; return 0; }
    local cpu group
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

# How long to wait before starting the miner again after it exited on its own.
# Ten seconds for the first failure, doubling, five minutes at the top: a crash
# loop is usually the pool or the network, and a rig that reconnects every ten
# seconds turns a five-minute outage into a socket storm on the pool's side.
# A start that lasted this long was a working miner, not a crash: it clears the
# consecutive-failure count and it is what makes the boot count as good. Ten
# minutes is long enough that a pool rejecting the wallet, a missing module or a
# bad config has shown up.
plan_healthy_run() { printf '%s' 600; }

plan_restart_delay() { # consecutive failures (1 or more)
    local fails="${1:-1}" delay=10
    case "$fails" in ''|*[!0-9]*) fails=1 ;; esac
    [ "$fails" -ge 1 ] || fails=1
    while [ "$fails" -gt 1 ]; do
        delay=$((delay * 2))
        [ "$delay" -ge 300 ] && { printf '%s' 300; return; }
        fails=$((fails - 1))
    done
    printf '%s' "$delay"
}

# --------------------------------------------------------------- the A/B block
# GRUB reads its environment from a 1024-byte block: a header, KEY=VALUE lines,
# '#' padding, no room for a trailing byte. Two things live in it - which root
# slot boots next, and the kernel parameters this rig needs - and they are
# written by two different programs at two different moments. So the block is
# produced here, once:
#
#   plan_grubenv_block KEY VALUE [EXISTING]
#
# Prints the block. Keys already in EXISTING are kept except the one being
# replaced. That merge is the whole point: the initramfs used to write the slot
# and nothing else, so an automatic rollback silently dropped `isolcpus=` and the
# rig came back mining on half its cores with nothing in the log to say why.
#
# Pure: it reads its arguments and one file, and prints. The caller decides
# whether to replace the real block.
plan_grubenv_size() { printf '%s' 1024; }

plan_grubenv_block() { # key value [existing-file]
    local key="${1:?plan_grubenv_block needs a key}" value="${2:-}" into="${3:-}"
    [ -n "$into" ] && [ -r "$into" ] || into=/dev/null
    awk -v key="$key" -v value="$value" -v total="$(plan_grubenv_size)" '
        BEGIN { head = "# GRUB Environment Block\n"; body = "" }
        {
            line = $0
            # Comments and blank lines are not keys. GRUB ignores both, and the
            # padding is made of them, so keeping them would grow the block on
            # every write until it overflowed.
            if (line == "" || substr(line, 1, 1) == "#") next
            eq = index(line, "=")
            if (eq > 0 && substr(line, 1, eq - 1) == key) next
            body = body line "\n"
        }
        END {
            body = key "=" value "\n" body
            room = total - length(head) - length(body) - 1
            # A block of any other size is a block GRUB ignores, so too many
            # keys is a failure to report, not a block to write.
            if (room < 0) exit 1
            pad = ""
            for (i = 0; i < room; i++) pad = pad "#"
            printf "%s%s%s\n", head, body, pad
        }' "$into"
}

# The rollback decision, and the number behind it: an installed rig counts boots
# that never reached the point where the miner had been up for five minutes, and
# after plan_boot_limit of them the other slot is worth trying. Returned as a
# word, so the callers (PID 1 and the tests) cannot drift apart on the boundary.
plan_boot_limit() { printf '%s' 3; }

# keep          this slot is fine (or it has not failed enough times yet)
# rollback      switch to the other slot and reboot
# boot-anyway   it has failed, but there is no other slot to boot
plan_boot_action() { # count, other-slot-present (0/1)
    local count="${1:-0}" other="${2:-0}"
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
    [ "$count" -ge "$(plan_boot_limit)" ] || { printf 'keep'; return; }
    [ "$other" = "1" ] && printf 'rollback' || printf 'boot-anyway'
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

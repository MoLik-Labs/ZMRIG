#!/usr/bin/env bash
#
# plan.sh - tests for the numbers the boot and the control tool both decide.
#
#   ./os/tests/plan.sh
#
# Two halves. The first is pure arithmetic: how much memory an algorithm needs,
# how many pages that is, and which CPUs "isolate 4" actually takes on a given
# topology - all against fake trees, no kernel, no root. The second drives the
# real `zmrig-os` in a temporary root, because a plan that never reaches a config
# file is a plan that changes nothing.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${0}")/../.." && pwd)
PLAN="${ROOT}/os/plan.sh"
TOOL="${ROOT}/os/overlay/usr/local/bin/zmrig-os"
PASS=0
FAIL=0

WALLET="46SQLW7DXaq6GJaQbHUFMAhd1VYpfQFJQ2gfZo9TCB8bf9vnf1MUwAD2Fwj6KMsY4RU3oKA3x6hByg8BKg7FfMWn6ysb5tJ"

ok()  { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*"; }
eq()  { # description, expected, actual
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}

# shellcheck disable=SC1090
. "$PLAN"

# A fake /sys with a topology: `make_topology <root> <siblings...>` where each
# argument is one physical core's thread list, eg "0,4".
make_topology() {
    local dir="$1"; shift
    local pair cpu
    rm -rf "$dir"
    for pair in "$@"; do
        for cpu in $(printf '%s' "$pair" | tr ',' ' '); do
            mkdir -p "$dir/devices/system/cpu/cpu${cpu}/topology"
            printf '%s\n' "$pair" > "$dir/devices/system/cpu/cpu${cpu}/topology/thread_siblings_list"
        done
    done
}

printf '\nzmrig-os plan tests\n\n'

# ---------------------------------------------------------------- memory
echo "memory"
eq "Monero in fast mode: 256 MB cache + 2080 MB dataset + scratchpads + slack" \
   2416 "$(plan_need_mb xmr max 8)"
eq "the same size for the other RandomX coins" 2416 "$(plan_need_mb wow max 8)"
eq "Scala/Panthera is 192 MB, not 2.3 GB" 272 "$(plan_need_mb xla max 8)"
eq "the alias rx/panthera agrees" 272 "$(plan_need_mb rx/panthera max 8)"
eq "light mode maps the cache only" 296 "$(plan_need_mb xmr light 4)"
eq "an unknown algorithm is sized for the largest configuration" 2416 "$(plan_need_mb nonsense max 8)"
eq "a pinned thread count is used instead of the core count" 2416 "$(plan_need_mb xmr max 16 8)"
eq "an unpinned count follows the cores" 2432 "$(plan_need_mb xmr max 16)"

# ---------------------------------------------------------------- threads
echo "threads"
eq "max uses every logical CPU" 8 "$(plan_threads max 8)"
eq "balanced leaves one" 7 "$(plan_threads balanced 8)"
eq "safe leaves one" 7 "$(plan_threads safe 8)"
eq "eco takes half" 4 "$(plan_threads eco 8)"
eq "eco on a small box takes one, not zero" 1 "$(plan_threads eco 2)"
eq "balanced on two cores keeps both: one thread cannot mine" 2 "$(plan_threads balanced 2)"
eq "light uses every logical CPU" 8 "$(plan_threads light 8)"
eq "an explicit count wins over the mode" 3 "$(plan_threads balanced 8 3)"

# ---------------------------------------------------------------- pages
echo "huge pages"
eq "2416 MB at 2 MiB per page rounds up" 1208 "$(plan_pages xmr max 8 32000 2048)"
eq "Scala reserves 136 pages, not 1208" 136 "$(plan_pages xla max 8 32000 2048)"
eq "a 2 GB box is capped at RAM - 512 MB" 744 "$(plan_pages xmr max 8 2000 2048)"
eq "the cap is a cap, not a floor" 244 "$(plan_pages xmr max 8 1000 2048)"
eq "an explicit override is obeyed exactly" 600 "$(plan_pages xmr max 8 32000 2048 auto 600)"
eq "an override of 0 disables the reservation" 0 "$(plan_pages xmr max 8 32000 2048 auto 0)"
eq "no page size means no pages" 0 "$(plan_pages xmr max 8 32000 0)"
eq "1 GB pages are counted in 1 GB units" 3 "$(plan_pages xmr max 8 32000 1048576)"
eq "unreadable RAM is not a reason to crash" 1208 "$(plan_pages xmr max 8 null 2048)"

# ---------------------------------------------------------------- mask
echo "cpu mask"
eq "0-3 is 0xf" f "$(plan_mask_hex 0 1 2 3)"
eq "2 and 3 is 0xc" c "$(plan_mask_hex 2 3)"
eq "cpu 0 alone is 1" 1 "$(plan_mask_hex 0)"
eq "cpu 63 is the top bit" "8000000000000000" "$(plan_mask_hex 63)"
eq "cpu 64 cannot be described by a 64-bit mask" "" "$(plan_mask_hex 64)"
eq "no cpus means no mask" "" "$(plan_mask_hex)"

# ---------------------------------------------------------------- topology
echo "isolation"
make_topology /tmp/zmrig-plan-8t "0,4" "1,5" "2,6" "3,7"
make_topology /tmp/zmrig-plan-4c "0" "1" "2" "3"

# Whole cores only: on 4 cores / 8 threads, asking for 2 takes the top pair.
eq "2 of 8 threads is one whole core" "3 7" "$(plan_iso_cpus /tmp/zmrig-plan-8t 2 8)"
eq "3 of 8 threads cannot split a pair, so it takes 2" "3 7" "$(plan_iso_cpus /tmp/zmrig-plan-8t 3 8)"
eq "4 of 8 threads is two whole cores" "2 3 6 7" "$(plan_iso_cpus /tmp/zmrig-plan-8t 4 8)"
iso_list=$(plan_iso_cpus /tmp/zmrig-plan-8t 4 8)
hk_list=$(plan_housekeeping 8 "$iso_list")
# plan_join_list's whole job is to turn a list into a mask, so it splits.
# shellcheck disable=SC2086
eq "the low-numbered CPUs stay with the kernel" "0-1,4-5" "$(plan_join_list $hk_list)"
eq "a non-SMT machine takes the top CPUs one by one" "2 3" "$(plan_iso_cpus /tmp/zmrig-plan-4c 2 4)"
eq "asking for every CPU is refused: the kernel needs one" "" "$(plan_iso_cpus /tmp/zmrig-plan-4c 4 4)"
eq "asking for none is not an error" "" "$(plan_iso_cpus /tmp/zmrig-plan-4c 0 4)"
eq "a one-CPU machine isolates nothing" "" "$(plan_iso_cpus /tmp/zmrig-plan-4c 1 1)"
mkdir -p /tmp/zmrig-plan-empty
eq "no topology: the top CPUs, one per core" "2 3" "$(plan_iso_cpus /tmp/zmrig-plan-empty 2 4)"

# A sibling list that names a CPU the machine does not have (offline CPU, or a
# container whose /sys is bigger than nproc) must not produce a CPU that cannot
# be used.
make_topology /tmp/zmrig-plan-offline "0,2" "1,3"
eq "siblings beyond the CPU count are ignored" "1" "$(plan_iso_cpus /tmp/zmrig-plan-offline 1 2)"

echo "cpu lists"
eq "a run of CPUs is a range" "4-7" "$(plan_join_list 4 5 6 7)"
eq "two runs are two ranges" "2-3,6-7" "$(plan_join_list 6 7 2 3)"
eq "a single CPU has no dash" "5" "$(plan_join_list 5)"
eq "duplicates do not repeat" "1-2" "$(plan_join_list 2 1 2)"
eq "housekeeping is everything else" "0 1 4 5 6 7" "$(plan_housekeeping 8 2 3)"

# ---------------------------------------------------------------- the tool
echo "the tool"

newroot() {
    ROOTDIR=$(mktemp -d)
    mkdir -p "$ROOTDIR/etc/zmrig" "$ROOTDIR/usr/local/bin" "$ROOTDIR/run/zmrig" \
             "$ROOTDIR/var/log" "$ROOTDIR/usr/local/lib/zmrig" "$ROOTDIR/media/zmrig" "$ROOTDIR/media/boot/grub"
    cp "$PLAN" "$ROOTDIR/usr/local/lib/zmrig/plan.sh"
    export ZMRIG_OS_ROOT="$ROOTDIR"
    export ZMRIG_OS_DRYRUN=1
    # Four CPUs, no SMT: the tool reads its topology from here, so a two-core CI
    # runner still exercises a four-core rig.
    export ZMRIG_OS_SYS=/tmp/zmrig-plan-4c
    # A live stick: no `installed` marker, so nothing writes to the medium.
    unset ZMRIG_OS_MANIFEST_URL
}

rmroot() { [ -n "${ROOTDIR:-}" ] && rm -rf "$ROOTDIR"; ROOTDIR=""; }

# A root with no wallet yet: the refusals come first, because once a wallet is
# configured "quickstart without a wallet" is no longer a refusal - it is a
# one-argument reconfiguration, which is the point of the command.
newroot
"$TOOL" quickstart --mode max >/dev/null 2>&1 && bad "quickstart without a wallet is refused" || ok "quickstart without a wallet is refused"
"$TOOL" quickstart --wallet "46SQLW7D" >/dev/null 2>&1 && bad "a short wallet is refused" || ok "a short wallet is refused"
"$TOOL" quickstart --wallet "$WALLET" --mode turbo >/dev/null 2>&1 && bad "an unknown mode is refused" || ok "an unknown mode is refused"
"$TOOL" quickstart --wallet "$WALLET" --pool nonsense >/dev/null 2>&1 && bad "a pool without a port is refused" || ok "a pool without a port is refused"
rmroot

newroot
out=$("$TOOL" quickstart --wallet "$WALLET" --pool pool.example.com:10001 --mode balanced 2>&1)
printf '%s\n' "$out" > "$ROOTDIR/quick.log"
grep -q 'WALLET="46SQLW7D' "$ROOTDIR/etc/zmrig/os.conf" && ok "quickstart writes the wallet" || bad "quickstart writes the wallet"
grep -q 'MODE="balanced"' "$ROOTDIR/etc/zmrig/os.conf" && ok "quickstart writes the mode" || bad "quickstart writes the mode"
grep -q 'POOL="pool.example.com:10001"' "$ROOTDIR/etc/zmrig/os.conf" && ok "quickstart writes the pool" || bad "quickstart writes the pool"
grep -qE 'mining      |not running' "$ROOTDIR/quick.log" && ok "quickstart reports whether the miner started" ||
    bad "quickstart reports whether the miner started"

args=$("$TOOL" args 2>/dev/null)
case "$args" in
    *"-t 3"*) ok "balanced on 4 CPUs pins 3 threads" ;;
    *) bad "balanced on 4 CPUs pins 3 threads (got: $args)" ;;
esac
# Without isolation the miner is pinned to the physical cores, which is what the
# `AFFINITY=auto` default is for: four CPUs, no SMT, so every CPU is a core.
case "$args" in
    *"--cpu-affinity 0xf"*) ok "auto pins the miner to the physical cores" ;;
    *) bad "auto pins the miner to the physical cores (got: $args)" ;;
esac

# isolate: the tool writes the count, the miner gets the mask
"$TOOL" isolate 2 >/dev/null 2>&1
grep -q 'ISOLATE="2"' "$ROOTDIR/etc/zmrig/os.conf" && ok "isolate writes the count" || bad "isolate writes the count"
args=$("$TOOL" args 2>/dev/null)
case "$args" in
    *"--cpu-affinity 0xc"*) ok "isolate 2 of a 4-core machine pins cpus 2 and 3" ;;
    *) bad "isolate 2 of a 4-core machine pins cpus 2 and 3 (got: $args)" ;;
esac
"$TOOL" isolate > "$ROOTDIR/iso.log" 2>&1
grep -q 'isolated    2-3' "$ROOTDIR/iso.log" && ok "isolate reports the set it actually took" || bad "isolate reports the set it actually took"
grep -q 'housekeeping 0-1' "$ROOTDIR/iso.log" && ok "isolate reports what the kernel keeps" || bad "isolate reports what the kernel keeps"

# Threads follow the CPUs the miner may actually use: pinning more threads than
# the mask allows is cache thrash dressed up as a bigger number.
"$TOOL" mode balanced >/dev/null 2>&1
args=$("$TOOL" args 2>/dev/null)
case "$args" in
    *"-t 2"*) ok "balanced counts the isolated CPUs, not every CPU" ;;
    *) bad "balanced counts the isolated CPUs, not every CPU (got: $args)" ;;
esac
"$TOOL" mode max >/dev/null 2>&1
args=$("$TOOL" args 2>/dev/null)
case "$args" in
    *"-t 2"*) ok "max mode mines on the isolated set only" ;;
    *) bad "max mode mines on the isolated set only (got: $args)" ;;
esac

"$TOOL" isolate 4 >/dev/null 2>&1 && bad "isolating every CPU is refused" || ok "isolating every CPU is refused"
"$TOOL" isolate off >/dev/null 2>&1
grep -q 'ISOLATE="0"' "$ROOTDIR/etc/zmrig/os.conf" && ok "isolate off clears the count" || bad "isolate off clears the count"
args=$("$TOOL" args 2>/dev/null)
case "$args" in
    *"--cpu-affinity 0xc"*) bad "isolate off drops the isolated mask" ;;
    *"--cpu-affinity 0xf"*) ok "isolate off goes back to the physical cores" ;;
    *) bad "isolate off goes back to the physical cores (got: $args)" ;;
esac

# status shows the two numbers a "why is it slower" question turns into
"$TOOL" status > "$ROOTDIR/status.log" 2>&1
grep -q 'hugepages' "$ROOTDIR/status.log" && ok "status shows the huge page pool" || bad "status shows the huge page pool"
grep -q 'cpus ' "$ROOTDIR/status.log" && ok "status shows where the threads run" || bad "status shows where the threads run"

# doctor --json is a document, not a log line
"$TOOL" doctor --json > "$ROOTDIR/doctor.json" 2>/dev/null || true
if command -v python3 >/dev/null 2>&1; then
    if python3 - "$ROOTDIR/doctor.json" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))
assert isinstance(doc["fail"], int) and isinstance(doc["warn"], int)
assert doc["checks"], "no checks"
for check in doc["checks"]:
    assert check["status"] in ("ok", "warn", "fail"), check
    assert check["check"] and check["detail"], check
EOF
    then ok "doctor --json parses and carries every check"
    else bad "doctor --json parses and carries every check"; fi
else
    ok "doctor --json (python3 is missing; not checked)"
fi

# The GRUB environment block holds more than one key: writing the slot must not
# forget the kernel parameters, and writing them must not forget the slot.
: > "$ROOTDIR/media/zmrig/installed"
printf '%s\n' 'a' > "$ROOTDIR/etc/zmrig/slot"
# `zmrig-os slot b` refuses a slot with no root filesystem on it, which is the
# right refusal - so the fixture has to look like an installed rig that has one.
: > "$ROOTDIR/media/zmrig/rootfs-b.squashfs"
"$TOOL" slot b >/dev/null 2>&1
"$TOOL" isolate 2 >/dev/null 2>&1
grubenv="$ROOTDIR/media/boot/grub/grubenv"
[ -f "$grubenv" ] && ok "isolate writes the GRUB environment block" || bad "isolate writes the GRUB environment block"
grep -q '^zmrig_slot=b$' "$grubenv" 2>/dev/null && ok "the slot survives a second key" || bad "the slot survives a second key"
grep -q '^zmrig_extra=isolcpus=2-3' "$grubenv" 2>/dev/null && ok "the kernel parameters name the isolated CPUs" ||
    bad "the kernel parameters name the isolated CPUs"
eq "the block is exactly 1024 bytes" 1024 "$(wc -c < "$grubenv" 2>/dev/null | tr -d ' ')"
"$TOOL" isolate off >/dev/null 2>&1
grep -q '^zmrig_slot=b$' "$grubenv" 2>/dev/null && ok "turning isolation off keeps the slot" || bad "turning isolation off keeps the slot"

# The doctor is read into a file, not into `grep -q`: grep exits at the first
# match, the tool then dies of SIGPIPE, and `pipefail` turns that into a failed
# test that a shorter version of the same output would have passed.
doctor_report() {
    "$TOOL" doctor > "$ROOTDIR/doctor.log" 2>/dev/null || true
    cat "$ROOTDIR/doctor.log"
}
doctor_has() { # description, needle
    if grep -qF "$2" "$ROOTDIR/doctor.log" 2>/dev/null; then ok "$1"; else bad "$1"; fi
}

# An installed rig verifies its slot at boot when a checksum sits next to it.
printf '%064d\n' 0 > "$ROOTDIR/media/zmrig/rootfs-a.squashfs.sha256"
doctor_report >/dev/null
doctor_has "an installed rig reports a verified slot" "verified at boot"
rm -f "$ROOTDIR/media/zmrig/rootfs-a.squashfs.sha256"
doctor_report >/dev/null
doctor_has "a slot with no checksum is called unverified" "boots unverified"

# Security: a config anyone can rewrite, and a miner API anyone can reach.
chmod 666 "$ROOTDIR/etc/zmrig/os.conf"
doctor_report >/dev/null
doctor_has "doctor reports a world-writable config" "writable by group or other"
chmod 600 "$ROOTDIR/etc/zmrig/os.conf"
printf 'API_PORT="3333"\nAPI_HOST="0.0.0.0"\n' >> "$ROOTDIR/etc/zmrig/os.conf"
doctor_report >/dev/null
doctor_has "doctor fails an open mining API" "NO token"
printf 'API_TOKEN="secret"\n' >> "$ROOTDIR/etc/zmrig/os.conf"
doctor_report >/dev/null
doctor_has "a token makes the open API acceptable" "with a token"

# ------------------------------------------------------------- temperature
# A board exposes a dozen sensors and only one of them is the die. The order is
# the whole point: acpitz reads 20 C colder than coretemp on the same machine,
# and a governor that believes it lets the rig cook.
make_hwmon() { # dir  name:millidegrees ...
    local dir="$1"; shift
    rm -rf "$dir/class/hwmon"
    mkdir -p "$dir/class/hwmon"
    local i=0 spec name temp
    for spec in "$@"; do
        i=$((i + 1))
        name=${spec%:*}; temp=${spec#*:}
        mkdir -p "$dir/class/hwmon/hwmon$i"
        printf '%s\n' "$name" > "$dir/class/hwmon/hwmon$i/name"
        printf '%s\n' "$temp" > "$dir/class/hwmon/hwmon$i/temp1_input"
    done
}

SYSROOT=$(mktemp -d)
make_hwmon "$SYSROOT" acpitz:35000 coretemp:61000 nct6775:45000
eq "the die wins over the board and the ACPI guess" "61 C" \
    "$(ZMRIG_OS_SYS="$SYSROOT" "$TOOL" status 2>/dev/null | awk '$1 == "thermal" { sub(/ C$/, " C"); print $2, $3 }')"

# One file per core: the hottest core is the one that decides the fan.
make_hwmon "$SYSROOT" coretemp:52000 coretemp:71000 coretemp:60000
eq "the hottest core wins, not the last one read" "71 C" \
    "$(ZMRIG_OS_SYS="$SYSROOT" "$TOOL" status 2>/dev/null | awk '$1 == "thermal" { print $2, $3 }')"

# No CPU driver at all: a desktop Super I/O is still better than acpitz.
make_hwmon "$SYSROOT" acpitz:30000 nct6683:54000
eq "a Super I/O beats the ACPI guess" "54 C" \
    "$(ZMRIG_OS_SYS="$SYSROOT" "$TOOL" status 2>/dev/null | awk '$1 == "thermal" { print $2, $3 }')"

# A laptop: the embedded controller under thinkpad_acpi, and thinkpad ACPI
# thermal zones that are colder than the EC.
rm -rf "$SYSROOT/class/hwmon"
make_hwmon "$SYSROOT" thinkpad:58000
eq "an embedded controller is read" "58 C" \
    "$(ZMRIG_OS_SYS="$SYSROOT" "$TOOL" status 2>/dev/null | awk '$1 == "thermal" { print $2, $3 }')"

# Nothing in hwmon: fall back to the ACPI zones, and still to the hottest,
# non-acpitz zone first.
rm -rf "$SYSROOT/class/hwmon"
mkdir -p "$SYSROOT/class/thermal/thermal_zone0" "$SYSROOT/class/thermal/thermal_zone1"
printf 'acpitz\n' > "$SYSROOT/class/thermal/thermal_zone0/type"
printf '32000\n' > "$SYSROOT/class/thermal/thermal_zone0/temp"
printf 'x86_pkg_temp\n' > "$SYSROOT/class/thermal/thermal_zone1/type"
printf '66000\n' > "$SYSROOT/class/thermal/thermal_zone1/temp"
eq "an ACPI zone is used when hwmon is empty" "66 C" \
    "$(ZMRIG_OS_SYS="$SYSROOT" "$TOOL" status 2>/dev/null | awk '$1 == "thermal" { print $2, $3 }')"
rm -f "$SYSROOT/class/thermal/thermal_zone1/temp"
eq "acpitz is the last resort, not the first answer" "32 C" \
    "$(ZMRIG_OS_SYS="$SYSROOT" "$TOOL" status 2>/dev/null | awk '$1 == "thermal" { print $2, $3 }')"
rm -rf "$SYSROOT"

# ------------------------------------------------------------ the A/B block
# GRUB wants exactly 1024 bytes and ignores a block of any other size, so a
# wrong-size write is a rollback that silently does nothing. And the block holds
# the kernel parameters as well as the slot: replacing it to change the slot is
# how a rig comes back after a rollback without `isolcpus=`, mining on half its
# cores and looking healthy.
ENVROOT=$(mktemp -d)
ENV="${ENVROOT}/grubenv"
printf '# GRUB Environment Block\nzmrig_slot=a\nzmrig_extra=isolcpus=4-7 nohz_full=4-7\n' > "$ENV"

block=$(plan_grubenv_block zmrig_slot b "$ENV")
eq "the block is exactly 1024 bytes" "1024" "$(printf '%s\n' "$block" | wc -c | tr -d ' ')"
eq "the new slot is in it" "zmrig_slot=b" "$(printf '%s\n' "$block" | sed -n 's/^\(zmrig_slot=.*\)/\1/p')"
eq "the kernel parameters survive a slot change" "zmrig_extra=isolcpus=4-7 nohz_full=4-7" \
   "$(printf '%s\n' "$block" | sed -n 's/^\(zmrig_extra=.*\)/\1/p')"
eq "the header is the first line" "# GRUB Environment Block" "$(printf '%s\n' "$block" | head -1)"
eq "the old slot key is not left behind" "1" \
   "$(printf '%s\n' "$block" | grep -c '^zmrig_slot=')"

# Writing twice must not grow the block: the padding is stripped before the
# merge, and a write that kept it would overflow after a few hundred reboots.
printf '%s\n' "$block" > "$ENV"
again=$(plan_grubenv_block zmrig_slot a "$ENV")
eq "a second write is still 1024 bytes" "1024" "$(printf '%s\n' "$again" | wc -c | tr -d ' ')"
eq "and only one slot key survives it" "1" "$(printf '%s\n' "$again" | grep -c '^zmrig_slot=')"
eq "with the value it was given" "zmrig_slot=a" "$(printf '%s\n' "$again" | sed -n 's/^\(zmrig_slot=.*\)/\1/p')"

# A value with an '=' in it (a kernel parameter always has one) is a value, not
# a second key.
eq "a value containing = is kept whole" "zmrig_extra=quiet loglevel=3" \
   "$(printf '%s\n' "$(plan_grubenv_block zmrig_extra 'quiet loglevel=3' "$ENV")" | sed -n 's/^\(zmrig_extra=.*\)/\1/p')"

# Too many keys for the block is a failure to report, not a block to write.
big=$(awk 'BEGIN { s = ""; for (i = 0; i < 1500; i++) s = s "x"; print "k=" s }' )
if plan_grubenv_block k "$big" "$ENV" > /dev/null 2>&1; then
    bad "a value too large for the block was written anyway"
else
    ok "a block that would overflow is refused"
fi

# A missing file is a fresh install, not an error.
eq "a fresh block still has the right size" "1024" \
   "$(printf '%s\n' "$(plan_grubenv_block zmrig_slot a /nonexistent/grubenv)" | wc -c | tr -d ' ')"
rm -rf "$ENVROOT"

# ------------------------------------------------------------ the restart delay
# A crash loop is the pool's problem as much as the rig's, so the wait between
# attempts doubles up to five minutes instead of retrying every ten seconds.
eq "the first restart waits 10 s" "10" "$(plan_restart_delay 1)"
eq "the second waits 20 s" "20" "$(plan_restart_delay 2)"
eq "the third waits 40 s" "40" "$(plan_restart_delay 3)"
eq "the fourth waits 80 s" "80" "$(plan_restart_delay 4)"
eq "the fifth waits 160 s" "160" "$(plan_restart_delay 5)"
eq "the sixth is capped at five minutes" "300" "$(plan_restart_delay 6)"
eq "and it stays capped" "300" "$(plan_restart_delay 40)"
eq "a zero count still waits something" "10" "$(plan_restart_delay 0)"
eq "junk waits something too" "10" "$(plan_restart_delay x)"
# A start that lasted this long clears the count: "five failures in a row" must
# not mean "five failures since August".
eq "a healthy run is ten minutes" "600" "$(plan_healthy_run)"

# ------------------------------------------------------------ the rollback rule
# Three boots that never reached "the miner has been up for five minutes" is the
# trigger; whether another slot exists decides between rolling back and trying
# the broken one again.
eq "the limit is three boots" "3" "$(plan_boot_limit)"
eq "a first boot is kept" "keep" "$(plan_boot_action 0 1)"
eq "two failures are still a keep" "keep" "$(plan_boot_action 2 1)"
eq "the third failure rolls back" "rollback" "$(plan_boot_action 3 1)"
eq "and keeps rolling back" "rollback" "$(plan_boot_action 9 1)"
eq "without another slot it boots anyway" "boot-anyway" "$(plan_boot_action 3 0)"
eq "a counter that is not a number is zero" "keep" "$(plan_boot_action "" 1)"
eq "junk in the counter is zero too" "keep" "$(plan_boot_action "x" 1)"

rmroot
unset ZMRIG_OS_ROOT ZMRIG_OS_DRYRUN ZMRIG_OS_SYS

printf '\n    %d passed, %d failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]

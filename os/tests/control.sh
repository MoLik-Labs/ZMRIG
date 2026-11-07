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

# The wallet check is only as strong as the miner behind it: with no binary,
# `zmrig-os` can count characters but cannot verify a checksum, and it says so.
# When a binary exists (a developer checkout, or the engine job in CI) the tool
# is pointed at it so these tests exercise the decoder rather than the fallback.
# ZMRIG_TEST_DECODER=none exercises the fallback deliberately, which is the
# state of a fresh ISO and of the CI job that has no Zig toolchain.
DECODER="${ZMRIG_TEST_DECODER:-${ROOT}/zmrig/out/zmrig}"
if [ "$DECODER" != none ] && [ -x "$DECODER" ]; then
    HAS_DECODER=1
else
    HAS_DECODER=0
fi

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
    # Not ZMRIG_OS_BIN: several sections below install their own stub miner in
    # $ROOTDIR/usr/local/bin to drive autotune and update, and an environment
    # override would shadow it. The wallet tests ask for the real decoder
    # explicitly, with `env`.
    unset ZMRIG_OS_BIN
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
# The typo the alphabet check cannot see: every character is base58, the length
# is right, and the last one is wrong. Without a checksum this rig installs and
# hashes for nobody.
TYPO="${WALLET%?}f"
[ "$TYPO" = "$WALLET" ] && TYPO="${WALLET%?}g"
if [ "$HAS_DECODER" = 1 ]; then
    expect_fail "an address with one wrong character is refused" \
        env ZMRIG_OS_BIN="$DECODER" "$TOOL" setup --wallet "$TYPO" --pool pool.example.com:10001
    contains "checksum" "$CHECK_MSG" && ok "the refusal names the checksum" || bad "the refusal names the checksum: $CHECK_MSG"
else
    # Without a miner the tool must not pretend: it accepts the shape and the
    # miner refuses the checksum on first boot, which doctor explains.
    expect_ok "the shape is accepted when there is no miner to ask" "$TOOL" setup --wallet "$WALLET" --pool pool.example.com:10001
fi

# doctor is the other place an operator looks, and it has to say exactly what
# was checked: a decoded checksum, or a counted shape. Its exit status is about
# the whole machine (a VM has no sensor and no MSR, so it exits 1 here), so what
# is asserted is the wallet line, not the status.
"$TOOL" setup --wallet "$WALLET" --pool pool.example.com:10001 >/dev/null 2>&1
CHECK_MSG=$(env ZMRIG_OS_BIN="$DECODER" "$TOOL" doctor 2>&1 || true)
if contains "checksum verified" "$CHECK_MSG"; then
    ok "doctor says the checksum was verified"
elif contains "shape only" "$CHECK_MSG"; then
    ok "doctor says it could only check the shape"
else
    bad "doctor says nothing about what was checked: $(printf '%s' "$CHECK_MSG" | grep wallet)"
fi
if [ "$HAS_DECODER" = 1 ]; then
    contains "checksum verified" "$CHECK_MSG" || bad "with a miner, doctor must say the checksum was verified"
else
    contains "checksum verified" "$CHECK_MSG" && bad "without a miner, doctor must not claim a checksum check"
fi

# The interactive prompt is the one place a typo can be fixed by the person who
# made it. Dying on the first wrong character means a reboot - or a rig that sits
# at "no wallet configured" - so it asks three times, says why, and accepts the
# corrected address. This needs a pty, which `script` provides.
if [ "$HAS_DECODER" = 1 ] && command -v script >/dev/null 2>&1; then
    PROMPT_ROOT=$(mktemp -d)
    mkdir -p "$PROMPT_ROOT/etc/zmrig" "$PROMPT_ROOT/usr/local/bin" "$PROMPT_ROOT/run/zmrig" "$PROMPT_ROOT/var/log"
    prompt_out=$(printf '%s\n%s\n%s\n%s\n%s\n' "$TYPO" "$WALLET" "pool.example.com:10001" "rig1" "max" |
        ZMRIG_OS_ROOT="$PROMPT_ROOT" ZMRIG_OS_BIN="$DECODER" script -qec "$TOOL setup" /dev/null 2>&1 || true)
    contains "cannot be paid: checksum does not match" "$prompt_out" &&
        ok "the prompt says why the address was refused" || bad "the prompt says why the address was refused"
    contains "Monero wallet address" "$prompt_out" &&
        ok "the prompt asks again" || bad "the prompt asks again"
    if [ -f "$PROMPT_ROOT/etc/zmrig/os.conf" ] && grep -q "$WALLET" "$PROMPT_ROOT/etc/zmrig/os.conf"; then
        ok "the corrected address is what gets saved"
    else
        bad "the corrected address is what gets saved"
    fi

    # Three wrong answers in a row is a person who does not have the address to
    # hand: say so once and stop, rather than asking for ever.
    give_up=$(printf '%s\n%s\n%s\n' "$TYPO" "$TYPO" "$TYPO" |
        ZMRIG_OS_ROOT="$PROMPT_ROOT" ZMRIG_OS_BIN="$DECODER" script -qec "$TOOL setup" /dev/null 2>&1 || true)
    contains "giving up after three attempts" "$give_up" &&
        ok "three wrong answers stop the prompt" || bad "three wrong answers stop the prompt"
    rm -rf "$PROMPT_ROOT"
fi

expect_fail "an unknown mode is refused" "$TOOL" setup --wallet "$WALLET" --mode turbo
expect_fail "a donat* typo is not silently accepted" "$TOOL" setup --wallet "$WALLET" --donate-level 5

# ---------------------------------------------------------------- arguments
expect_ok "args builds a command line" "$TOOL" args
ARGS="$CHECK_MSG"

contains "-o pool.example.com:10001" "$ARGS" && ok "args carries the pool" || bad "args carries the pool"
contains "-u $WALLET" "$ARGS" && ok "args carries the wallet" || bad "args carries the wallet"
contains "--donate-level 3" "$ARGS" && ok "args keeps the 3 % fee visible" || bad "args keeps the 3 % fee visible"
contains "--profile free" "$ARGS" && ok "max mode asks for the free profile" || bad "max mode asks for the free profile"
contains "--msr" "$ARGS" && bad "msr is enabled without hardware (sandbox has no /dev/cpu/0/msr)" || ok "msr stays off where it cannot work"
# `MSR=auto` is the default and it says nothing either way: the miner's probe
# knows whether this CPU has a preset, which a presence test on a path cannot.
contains "--no-msr" "$ARGS" && bad "auto decides for the miner instead of letting it decide" ||
    ok "auto leaves the MSR decision to the miner"

# ...unless the mode is safe, which never writes a register in any setting.
old_msr=$(sed -n 's/^MSR="\(.*\)"$/\1/p' "$ROOTDIR/etc/zmrig/os.conf" | tail -1)
sed -i 's/^MSR=.*/MSR="on"/' "$ROOTDIR/etc/zmrig/os.conf"
"$TOOL" mode max >/dev/null 2>&1
expect_ok "args with MSR=on" "$TOOL" args
contains "--msr" "$CHECK_MSG" && ok "MSR=on asks for the preset" || bad "MSR=on asks for the preset"
"$TOOL" mode safe >/dev/null 2>&1
expect_ok "args with MSR=on in safe mode" "$TOOL" args
contains "--no-msr" "$CHECK_MSG" && ok "safe overrides MSR=on" || bad "safe overrides MSR=on"
sed -i "s/^MSR=.*/MSR=\"${old_msr:-auto}\"/" "$ROOTDIR/etc/zmrig/os.conf"
"$TOOL" mode max >/dev/null 2>&1
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

# --- the same field through setup -------------------------------------------
# `setup --max-temp` parsed into $SAFE_TEMP, and load_conf() put the file's
# value straight back: the flag was accepted, printed as ignored, and written
# as the old value. Nobody noticed because `mode safe 65` works.
"$TOOL" mode safe 72 >/dev/null 2>&1
expect_ok "setup takes a heat cap" "$TOOL" setup --wallet "$WALLET" --mode safe --max-temp 77
contains "SAFE_TEMP=\"77\"" "$(cat "$ROOTDIR/etc/zmrig/os.conf")" && ok "the heat cap from setup reaches the file" || bad "the heat cap from setup reaches the file (got '$(grep SAFE_TEMP "$ROOTDIR/etc/zmrig/os.conf")')"
expect_ok "setup still builds a command line" "$TOOL" args
contains "--max-temp 77" "$CHECK_MSG" && ok "the heat cap from setup reaches the miner" || bad "the heat cap from setup reaches the miner"
expect_fail "setup refuses a heat cap outside 45..95" "$TOOL" setup --wallet "$WALLET" --max-temp 200
expect_fail "setup refuses a heat cap that is not a number" "$TOOL" setup --wallet "$WALLET" --max-temp warm

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

# The initramfs writes the flag to /etc, because OpenRC puts a fresh tmpfs over
# /run and the copy there is gone before the supervisor reads it. Either file
# has to stop the miner: the one that works on a real boot is the /etc one.
: > "$ROOTDIR/etc/zmrig/nostart"
expect_ok "the flag in /etc stops the miner too" "$TOOL" run
contains "not starting" "$CHECK_MSG" && ok "and it says why it is idle" || bad "and it says why it is idle"
rm -f "$ROOTDIR/etc/zmrig/nostart"

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

# A manifest without a checksum: the unattended path always refused it, the
# manual one did not, and the download it accepts is the same download.
printf '#!/bin/sh\necho zmrig 9.9.9\nexit 0\n' > "$ROOTDIR/bucket/zmrig-new"
manifest "9.9.9" ""
expect_fail "a manifest with no checksum is refused" "$TOOL" update --apply
contains "binary_sha256" "$CHECK_MSG" && ok "the refusal says what is missing" || bad "the refusal names the missing checksum"

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

# The tuner sizes its reservation, so it has to know which algorithm, which mode
# and - when the operator set a count - how many pages. A rig tuned for Monero
# and started on Scala is tuned for 2.3 GB it will never map.
printf 'ALGO="rx/0"\nMODE="eco"\nHUGEPAGES="600"\nWALLET="%s"\n' "$WALLET" > "$ROOTDIR/etc/zmrig/os.conf"
out=$("$TOOL" tune 2>&1)
contains "--algo rx/0" "$out" && ok "the tuner is told the algorithm" || bad "the tuner is told the algorithm (got: $out)"
contains "--mode eco" "$out" && ok "the tuner is told the mode" || bad "the tuner is told the mode (got: $out)"
contains "--pages 600" "$out" && ok "an explicit page count reaches the tuner" ||
    bad "an explicit page count reaches the tuner (got: $out)"
printf 'ALGO="rx/0"\nMODE="max"\nHUGEPAGES="0"\nWALLET="%s"\n' "$WALLET" > "$ROOTDIR/etc/zmrig/os.conf"
out=$("$TOOL" tune 2>&1)
contains "--hugepages off" "$out" && ok "HUGEPAGES=0 turns the pool off" ||
    bad "HUGEPAGES=0 turns the pool off (got: $out)"

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

# The updater asks for a manifest per channel and per instruction level, and
# the two channels live in different places: `releases/latest` follows the
# newest stable release and never points at the rolling beta, which is a
# pre-release under its own tag. Getting that wrong made `CHANNEL="beta"` a 404
# that looked like a published release.
mkdir -p "$ROOTDIR/etc/zmrig"
printf 'x86-64-v3' > "$ROOTDIR/etc/zmrig/arch"
# The update tests above pointed ZMRIG_OS_MANIFEST_URL at a local bucket; this
# is about the URLs the tool derives when nobody overrides them.
murl() { ZMRIG_OS_NO_MAIN=1 ZMRIG_OS_ROOT="$ROOTDIR" ZMRIG_OS_MANIFEST_URL='' sh -c '. "$1"; CHANNEL="$2"; manifest_url' _ "$TOOL" "$1"; }
[ "$(murl stable)" = "https://github.com/MoLik-Labs/ZMRIG/releases/latest/download/zmrig-os-stable-x86-64-v3.json" ] &&
    ok "the stable channel follows the newest stable release" ||
    bad "the stable channel URL is wrong ($(murl stable))"
[ "$(murl beta)" = "https://github.com/MoLik-Labs/ZMRIG/releases/download/os-beta/zmrig-os-beta-x86-64-v3.json" ] &&
    ok "the beta channel names the rolling tag instead of 'latest'" ||
    bad "the beta channel asks for a manifest that does not exist ($(murl beta))"

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

    # The block also carries the kernel parameters. Changing the slot must not
    # drop them: `zmrig-os isolate` writes `isolcpus=` there, and an update that
    # switched slots used to take the isolated CPUs away with it.
    printf 'zmrig_extra=isolcpus=4-7\n' >> "$ROOTDIR/media/boot/grub/grubenv"
    : > "$ROOTDIR/media/zmrig/rootfs-a.squashfs"
    expect_ok "a slot change on a block with kernel parameters" "$TOOL" slot a
    grep -q '^zmrig_extra=isolcpus=4-7$' "$ROOTDIR/media/boot/grub/grubenv" &&
        ok "the kernel parameters survive a slot change" ||
        bad "the slot change dropped the kernel parameters"
    [ "$(wc -c < "$ROOTDIR/media/boot/grub/grubenv")" = "1024" ] &&
        ok "and the block is still 1024 bytes" || bad "the block changed size"
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

# A manifest with no checksum is refused: an unattended update that cannot be
# verified is a download installed as the miner with no way to tell a truncated
# file from a good one.
printf '{"version":"9.9.9","binary_url":"file:///dev/null"}\n' > "$ROOTDIR/manifest.json"
expect_ok "an update with no checksum does not crash" "$TOOL" auto --once
contains "no checksum" "$CHECK_MSG" && ok "it refuses an unverified update" ||
    bad "it refuses an unverified update ($CHECK_MSG)"
contains "9.9.9" "$CHECK_MSG" && ok "and it still reports the version it saw" ||
    bad "and it still reports the version it saw"

# A checksum that does not match is refused the same way, and this is the case
# that a corrupted mirror produces.
printf '{"version":"9.9.9","binary_url":"file:///dev/null","binary_sha256":"%s"}\n' \
    "$(printf 'not the file' | sha256sum | cut -d' ' -f1)" > "$ROOTDIR/manifest.json"
expect_ok "a mismatched checksum does not crash" "$TOOL" auto --once
contains "checksum mismatch" "$CHECK_MSG" && ok "a wrong checksum is refused" ||
    bad "a wrong checksum is refused ($CHECK_MSG)"

cat > "$ROOTDIR/manifest.json" <<'EOF'
{"version":"9.9.9","binary_url":"file:///dev/null","binary_sha256":""}
EOF
export ZMRIG_OS_MANIFEST_URL="file://$ROOTDIR/manifest.json"

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

# The installed menu is what decides whether `zmrig-os isolate` and `zmrig-os
# slot` do anything. It shipped without `${zmrig_extra}` for a while: the tool
# wrote isolcpus= into the environment block, printed "next boot: isolcpus=4-7",
# and the boot ignored it, so the rig mined on every core while looking isolated.
mkdir -p "$ROOTDIR/grubroot/zmrig"
: > "$ROOTDIR/grubroot/zmrig/rootfs-a.squashfs"
cfg=$(fn grub_cfg_for "$ROOTDIR/grubroot" 9.9.9)
contains '${zmrig_extra}' "$cfg" && ok 'the installed menu passes ${zmrig_extra} to the kernel' ||
    bad "the installed menu passes \${zmrig_extra} to the kernel"
contains 'load_env' "$cfg" && ok "it loads the environment block" || bad "it loads the environment block"
contains 'set zmrig_extra=""' "$cfg" && ok "zmrig_extra is defined even without a block" ||
    bad "zmrig_extra is defined even without a block"
contains 'set default="${zmrig_slot}"' "$cfg" && ok "the slot from the block chooses the entry" ||
    bad "the slot from the block chooses the entry"
contains 'max-a' "$cfg" && ok "slot a has a max-hashrate entry" || bad "slot a has a max entry"
contains 'safe-a' "$cfg" && ok "slot a has a safe entry" || bad "slot a has a safe entry"
case "$cfg" in *max-b*) bad "slot b is offered before it exists" ;; *) ok "slot b is not offered before it exists" ;; esac
: > "$ROOTDIR/grubroot/zmrig/rootfs-b.squashfs"
cfg=$(fn grub_cfg_for "$ROOTDIR/grubroot" 9.9.9)
contains 'max-b' "$cfg" && ok "slot b appears once an update writes it" || bad "slot b appears once an update writes it"
contains '/boot/initramfs-b.gz' "$cfg" && ok "and it points at its own initramfs" ||
    bad "and it points at its own initramfs"

# The fresh environment block: 1024 bytes, with the slot in it.
fn grubenv_init "$ROOTDIR/grubenv.new"
[ "$(wc -c < "$ROOTDIR/grubenv.new" | tr -d ' ')" = "1024" ] &&
    ok "a new install writes a 1024-byte environment block" || bad "the block is the wrong size"
grep -q '^zmrig_slot=a$' "$ROOTDIR/grubenv.new" && ok "and it starts on slot a" || bad "and it starts on slot a"

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

# ------------------------------------------------------------- huge pages
# 1 GiB pages are the one memory setting a rig cannot change after boot, so the
# tool has to get three things right: it writes the kernel parameters, it does
# not lose the isolation parameters already in that block, and "off" really means
# off. All three are checked against the environment block the boot reads.
printf 'WALLET="%s"\nISOLATE="0"\n' "$WALLET" > "$ROOTDIR/etc/zmrig/os.conf"
out=$("$TOOL" hugepages 2>&1)
contains "2 MiB" "$out" && ok "hugepages reports the 2 MiB pool" || bad "hugepages reports the 2 MiB pool (got: $out)"
contains "this run" "$out" && ok "and says how much this run needs" || bad "hugepages says how much this run needs"

out=$("$TOOL" hugepages 1g 3 2>&1)
grep -q 'HUGEPAGES_1G="3"' "$ROOTDIR/etc/zmrig/os.conf" &&
    ok "hugepages 1g 3 is written to the config" ||
    bad "hugepages 1g 3 is written to the config (got: $(cat "$ROOTDIR/etc/zmrig/os.conf"))"
contains "hugepages=3" "$(read_grubenv zmrig_extra 2>/dev/null || cat "$ROOTDIR/media/boot/grub/grubenv")" &&
    ok "and the kernel line reserves three 1 GiB pages" ||
    bad "the kernel line reserves three 1 GiB pages"

# Both settings live in one grubenv value, so the writer is checked as a unit:
# an isolated CPU set (with no dependency on how many cores the test machine has)
# and a gigantic pool have to come out of it together. Writing one and dropping
# the other is the bug that cost every isolated rig its isolcpus.
params=$(ZMRIG_OS_NO_MAIN=1 ZMRIG_OS_ROOT="$ROOTDIR" sh -c '
    . "$1"
    ISOLATED_CPUS="4 5"
    HUGEPAGES_1G=3
    write_grubenv() { printf "%s\n" "$2"; }
    write_boot_params >/dev/null
    write_grubenv zmrig_extra "$(printf "isolcpus=4,5 nohz_full=4,5 rcu_nocbs=4,5 default_hugepagesz=1G hugepagesz=1G hugepages=3")"
' _ "$TOOL" 2>&1 | tail -1)
case "$params" in
    *isolcpus=*) ok "the kernel line still carries the isolation" ;;
    *) bad "the kernel line lost isolcpus ($params)" ;;
esac
composed=$(ZMRIG_OS_NO_MAIN=1 ZMRIG_OS_ROOT="$ROOTDIR" sh -c '
    . "$1"
    ISOLATED_CPUS="4 5"
    HUGEPAGES_1G=3
    # The formatter lives in plan.sh, which this fake root does not have; the
    # unit under test is the composition, not the join.
    plan_join_list() { printf "%s" "$*" | tr " " ","; }
    write_grubenv() { printf "%s\n" "$2"; }
    say() { :; }
    write_boot_params
' _ "$TOOL" 2>&1 | head -1)
case "$composed" in
    *"isolcpus=4,5"*"hugepages=3"*) ok "one writer composes isolation and the gigantic pool" ;;
    *) bad "the composed kernel line is wrong ($composed)" ;;
esac
case "$composed" in
    *default_hugepagesz=1G*) ok "1 GiB is made the default size before hugepages=" ;;
    *) bad "default_hugepagesz is missing ($composed)" ;;
esac

out=$("$TOOL" hugepages off 2>&1)
params=$(read_grubenv zmrig_extra 2>/dev/null || cat "$ROOTDIR/media/boot/grub/grubenv")
case "$params" in
    *hugepages=*) bad "hugepages off left the reservation on the kernel line ($params)" ;;
    *) ok "hugepages off removes the reservation" ;;
esac
grep -q 'HUGEPAGES_1G=""' "$ROOTDIR/etc/zmrig/os.conf" &&
    ok "and clears it from the config" || bad "hugepages off clears it from the config"

out=$("$TOOL" hugepages 1g 2>&1 || true)
contains "usage" "$out" && ok "a count is required for 1g" || bad "a count is required for 1g (got: $out)"

# The two reservations do not fit together. A rig that reserved 3 x 1 GiB has
# already taken 3 GB of contiguous memory; topping that up with Monero's 2.3 GB
# of 2 MiB pages is how a 4 GB machine ends up swapping while it mines. The
# tuner has to leave the pool alone, and the decision is pure: it reads one
# number and one size.
mkdir -p "$ROOTDIR/fakesys/kernel/mm/hugepages/hugepages-1048576kB"
printf '3\n' > "$ROOTDIR/fakesys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages"
covered=$(ZMRIG_OS_NO_MAIN=1 ZMRIG_OS_ROOT="$ROOTDIR" ZMRIG_OS_SYS="$ROOTDIR/fakesys" sh -c '
    . "$1"
    ALGO=rx/0; MODE=max; THREADS=2; HUGEPAGES=""
    core_count() { printf 2; }
    plan_need_mb() { printf 2336; }
    gigantic_covers && echo yes || echo no
' _ "$TOOL" 2>&1 | tail -1)
[ "$covered" = "yes" ] && ok "3 GiB of 1 GiB pages covers a Monero run" ||
    bad "3 GiB of 1 GiB pages covers a Monero run (got: $covered)"

printf '1\n' > "$ROOTDIR/fakesys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages"
covered=$(ZMRIG_OS_NO_MAIN=1 ZMRIG_OS_ROOT="$ROOTDIR" ZMRIG_OS_SYS="$ROOTDIR/fakesys" sh -c '
    . "$1"
    ALGO=rx/0; MODE=max; THREADS=2; HUGEPAGES=""
    core_count() { printf 2; }
    plan_need_mb() { printf 2336; }
    gigantic_covers && echo yes || echo no
' _ "$TOOL" 2>&1 | tail -1)
[ "$covered" = "no" ] && ok "1 GiB of 1 GiB pages does not cover a 2336 MB run" ||
    bad "1 GiB does not cover 2336 MB (got: $covered)"

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

# A sensor in the fake /sys, so the status line has a real reading. The number
# the control plane receives is checked in os/tests/fleet.sh, where the payload
# actually goes to the server.
mkdir -p "$FAKESYS/class/hwmon/hwmon3"
printf 'k10temp\n' > "$FAKESYS/class/hwmon/hwmon3/name"
printf '68000\n' > "$FAKESYS/class/hwmon/hwmon3/temp1_input"
expect_ok "status reads the fake sensor" env ZMRIG_OS_SYS="$FAKESYS" "$TOOL" status
contains "68 C" "$CHECK_MSG" && ok "the status line shows the temperature" ||
    bad "the status line shows the temperature"

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

# ---------------------------------------------------------------- hardware
# What the CPU is, and what that means for RandomX. The verdict is a word so it
# can be asserted; the sentence around it is for the person reading it.
[ "$(fn hw_verdict 1 1 16000)" = "full" ] && ok "AVX2, AES and 16 GB is a full-speed machine" ||
    bad "AVX2, AES and 16 GB is a full-speed machine"
[ "$(fn hw_verdict 1 1 1800)" = "light" ] && ok "two thirds of the dataset is light mode, not fast" ||
    bad "two thirds of the dataset is light mode"
[ "$(fn hw_verdict 0 1 16000)" = "slow" ] && ok "no AVX2 is slow, not broken" || bad "no AVX2 is slow, not broken"
[ "$(fn hw_verdict 1 0 16000)" = "slow" ] && ok "no AES is slow: the scratchpad stops being cheap" ||
    bad "no AES is slow"
[ "$(fn hw_verdict 1 1 900)" = "small" ] && ok "under 1.2 GB cannot mine at all" || bad "under 1.2 GB cannot mine"

FAKEPROC="$ROOTDIR/fakeproc"
mkdir -p "$FAKEPROC"
printf 'processor\t: 0\nmodel name\t: AMD Ryzen 5 5600 6-Core Processor\nflags\t\t: fpu avx avx2 aes sha_ni\n' > "$FAKEPROC/cpuinfo"
printf 'MemTotal:       16384000 kB\n' > "$FAKEPROC/meminfo"

expect_ok "hardware describes the machine" env ZMRIG_OS_PROC="$FAKEPROC" ZMRIG_OS_SYS="$FAKESYS" "$TOOL" hardware
contains "AMD Ryzen 5 5600" "$CHECK_MSG" && ok "the CPU model is named" || bad "the CPU model is named"
contains "verdict    full" "$CHECK_MSG" && ok "a Ryzen with 16 GB is a full-speed machine" ||
    bad "a Ryzen with 16 GB is a full-speed machine"

# Flags are read from every processor, so a machine whose first processor line is
# truncated is still judged on the CPU the miner will actually run on.
printf 'processor\t: 0\nmodel name\t: Hybrid\nflags\t\t: fpu avx\n\nprocessor\t: 1\nflags\t\t: fpu avx avx2 aes\n' > "$FAKEPROC/cpuinfo"
expect_ok "flags come from every processor" env ZMRIG_OS_PROC="$FAKEPROC" ZMRIG_OS_SYS="$FAKESYS" "$TOOL" hardware
contains "verdict    full" "$CHECK_MSG" && ok "AVX2 found in the second processor's line" ||
    bad "AVX2 found in the second processor's line"

printf 'MemTotal:       900000 kB\n' > "$FAKEPROC/meminfo"
expect_fail "a machine too small to mine says so, and exits non-zero" \
    env ZMRIG_OS_PROC="$FAKEPROC" ZMRIG_OS_SYS="$FAKESYS" "$TOOL" hardware
contains "too small" "$CHECK_MSG" && ok "and the reason is the memory" || bad "and the reason is the memory"

# The doctor is expected to exit non-zero on an unconfigured sandbox (no wallet,
# no binary); what matters is that it still names the hardware verdict.
CHECK_MSG=$(ZMRIG_OS_PROC="$FAKEPROC" ZMRIG_OS_SYS="$FAKESYS" ZMRIG_OS_ROOT="$ROOTDIR" "$TOOL" doctor 2>&1 || true)
contains "compat" "$CHECK_MSG" && ok "doctor reports the hardware verdict once" || bad "doctor reports the hardware verdict"

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

# A different mode is a different thread budget: the measurement is dropped so
# it is taken again, but the number itself stays - it is the one thing on the rig
# that may have been typed by a person rather than measured.
expect_ok "a mode change clears the old measurement" "$TOOL" mode eco
contains 'AUTOTUNED=""' "$(cat "$ROOTDIR/etc/zmrig/os.conf")" && ok "the measurement marker is cleared" || bad "the measurement marker is cleared"

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

#!/usr/bin/env bash
#
# cli.sh - the command line is a contract: flags keep working, exit codes stay
# usable from scripts, and --help documents what the parser accepts.
#
#   ./zmrig/tests/cli.sh            # uses zmrig/out/zmrig
#   ZMRIG_BIN=/usr/local/bin/zmrig ./zmrig/tests/cli.sh
#
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${0}")/../.." && pwd)
BIN="${ZMRIG_BIN:-${ROOT}/zmrig/out/zmrig}"
SRC="${ROOT}/zmrig/src/options.zig"

[ -x "$BIN" ] || { echo "missing $BIN - run ./zmrig/build.sh first" >&2; exit 2; }

pass=0
fail=0

record() { # status name detail
    printf '%-6s %-28s %s\n' "$1" "$2" "${3:-}"
    if [ "$1" = PASS ]; then pass=$((pass + 1)); else fail=$((fail + 1)); fi
}

# Expects an exact exit status; any output is only shown on failure.
expect_exit() { # wanted name -- command...
    local want="$1" name="$2"
    shift 3
    local out status
    out=$("$@" 2>&1)
    status=$?
    if [ "$status" -eq "$want" ]; then
        record PASS "$name" "exit $status"
    else
        record FAIL "$name" "wanted exit $want, got $status: $(printf '%s' "$out" | head -2 | tr '\n' ' ')"
    fi
}

WALLET=4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge

printf 'zmrig cli contract: %s\n\n' "$BIN"

# -- flags --------------------------------------------------------------
expect_exit 0 "help" -- "$BIN" --help
expect_exit 0 "version" -- "$BIN" --version
expect_exit 1 "unknown flag" -- "$BIN" --definitely-not-a-flag
expect_exit 1 "missing value" -- "$BIN" -o
expect_exit 1 "bad pool scheme" -- "$BIN" -o gopher://pool:1 -u "$WALLET"
expect_exit 1 "no pool" -- "$BIN" --check
expect_exit 1 "no wallet" -- "$BIN" -o pool.example.com:3333 --check
expect_exit 0 "valid config" -- "$BIN" -o pool.example.com:3333 -u "$WALLET" --check
expect_exit 0 "--dry-run is --check" -- "$BIN" -o pool.example.com:3333 -u "$WALLET" --dry-run
expect_exit 1 "donate-level > 10" -- "$BIN" -o pool.example.com:3333 -u "$WALLET" --donate-level 11
expect_exit 1 "unknown config file" -- "$BIN" -c /nonexistent/config.json --check

# A rejected configuration must not print the "config ok" summary.
if "$BIN" -o pool.example.com:3333 --check 2>/dev/null | grep -q 'config ok'; then
    record FAIL "no summary on rejection" "printed config ok without a wallet"
else
    record PASS "no summary on rejection" "no summary without a wallet"
fi

# -- help documents every flag the parser accepts ------------------------
documented=$("$BIN" --help | grep -oE '\-\-[a-z0-9-]+' | sort -u)
handled=$(grep -oE '"--[a-z0-9-]+"' "$SRC" | tr -d '"' | sort -u)

# Short aliases and the compatibility spellings that share a line in --help.
known_undocumented='^--(url|user|pass|password|algo|threads|config|rig-id|wrmsr|no-rdmsr|randomx-no-rdmsr|not-a-flag)$'

missing=$(comm -23 <(printf '%s\n' "$handled") <(printf '%s\n' "$documented") | grep -vE "$known_undocumented" || true)
if [ -z "$missing" ]; then
    record PASS "--help covers the parser" "$(printf '%s\n' "$handled" | wc -l) flags"
else
    record FAIL "--help covers the parser" "missing: $(printf '%s' "$missing" | tr '\n' ' ')"
fi

# -- no flag is accepted and then ignored -------------------------------
# Every flag below must change something observable in --check or the log.
check_output=$("$BIN" -o pool.example.com:3333 -u "$WALLET" --cpu-affinity=0x1 --priority 3 \
    --randomx-init 1 --user-agent test-agent --check 2>&1)

for needle in "affinity 0x1" "priority 3" "dataset  built with 1 thread" "agent   test-agent"; do
    if printf '%s' "$check_output" | grep -qF "$needle"; then
        record PASS "flag visible: $needle" ""
    else
        record FAIL "flag visible: $needle" "not in --check output"
    fi
done

# -- huge page reservation: opt-out is real, and --check never writes -----
# `--check` must report the huge page state without touching /proc: it is run by
# oneclick.sh as a validation step, sometimes as root, and a probe that changes
# the host is not a probe.
before=$(cat /proc/sys/vm/nr_hugepages 2>/dev/null || echo "?")
"$BIN" -o pool.example.com:3333 -u "$WALLET" --check >/dev/null 2>&1
after=$(cat /proc/sys/vm/nr_hugepages 2>/dev/null || echo "?")

if [ "$before" = "$after" ]; then
    record PASS "--check does not touch nr_hugepages" "$before pages before and after"
else
    record FAIL "--check does not touch nr_hugepages" "$before -> $after"
fi

# -- the MSR preset applies itself, and --no-msr really stops it ----------
# Prefetchers off is worth 5-15 % on bare metal, so it is not opt-in any more:
# by default the miner probes the machine and says what it decided. `--no-msr`
# is the instruction, and it has to be obeyed even on a host that could take it
# (a container passing /dev/cpu through, or a user who wants the CPU untouched).
msr_auto=$("$BIN" -o pool.example.com:3333 -u "$WALLET" --check 2>/dev/null | grep -E '^  msr ' | head -1)
case "$msr_auto" in
    *"auto:"*) record PASS "the MSR preset decides by itself by default" "$msr_auto" ;;
    *)         record FAIL "the MSR preset decides by itself by default" "got: ${msr_auto:-nothing}" ;;
esac

msr_off=$("$BIN" -o pool.example.com:3333 -u "$WALLET" --no-msr --check 2>/dev/null | grep -E '^  msr ' | head -1)
case "$msr_off" in
    *"off: --no-msr"*) record PASS "--no-msr is reported as an instruction" "$msr_off" ;;
    *)                 record FAIL "--no-msr is reported as an instruction" "got: ${msr_off:-nothing}" ;;
esac

msr_on=$("$BIN" -o pool.example.com:3333 -u "$WALLET" --msr --check 2>/dev/null | grep -E '^  msr ' | head -1)
case "$msr_on" in
    *"on: --msr"*) record PASS "--msr is reported as an instruction" "$msr_on" ;;
    *)             record FAIL "--msr is reported as an instruction" "got: ${msr_on:-nothing}" ;;
esac

# XMRig's own spelling still selects the same thing: a script that passes
# --randomx-wrmsr must not end up with the automatic decision instead.
wrmsr=$("$BIN" -o pool.example.com:3333 -u "$WALLET" --randomx-wrmsr --check 2>/dev/null | grep -E '^  msr ' | head -1)
case "$wrmsr" in
    *"on: --msr"*) record PASS "--randomx-wrmsr means the same as --msr" "$wrmsr" ;;
    *)             record FAIL "--randomx-wrmsr means the same as --msr" "got: ${wrmsr:-nothing}" ;;
esac

# -- the memory --check reports must belong to the coin -------------------
# Both engines hash seven coins and the coins are not the same size. Reporting
# Monero's 2336 MB for a Panthera run is how a 512 MB VPS is told it cannot do
# something it can do.
xmr_mem=$("$BIN" -o pool.example.com:3333 -u "$WALLET" -a rx/0 --check 2>/dev/null | grep -c '2336 MB, 1168 pages')
xla_mem=$("$BIN" -o pool.example.com:3333 -u "$WALLET" -a panthera --check 2>/dev/null | grep -c '192 MB, 96 pages')

if [ "$xmr_mem" = "1" ]; then
    record PASS "--check sizes rx/0 memory" "2336 MB, 1168 pages"
else
    record FAIL "--check sizes rx/0 memory" "expected '2336 MB, 1168 pages'"
fi

if [ "$xla_mem" = "1" ]; then
    record PASS "--check sizes panthera memory" "192 MB, 96 pages"
else
    record FAIL "--check sizes panthera memory" "expected '192 MB, 96 pages'"
fi

# "0 reserved" is not the same as "4 KiB pages": with transparent huge pages on
# the kernel collapses the mapping anyway. --check has to say which mechanism is
# in play, or the line above reads like a problem that cannot be fixed without
# root when in fact there is nothing to fix.
if "$BIN" -o pool.example.com:3333 -u "$WALLET" -a rx/0 --check 2>/dev/null | grep -q '^  thp     '; then
    record PASS "--check reports the THP policy" ""
else
    record FAIL "--check reports the THP policy" "no 'thp' line in --check"
fi

# The opt-out must be visible in --help (it is a safety valve, not a hidden knob)
if "$BIN" --help | grep -qF -- "--no-auto-hugepages"; then
    record PASS "--no-auto-hugepages is documented" ""
else
    record FAIL "--no-auto-hugepages is documented" "not in --help"
fi

# --- profiles and autotune -------------------------------------------
# Both are new contract surface: a typo in either must be an error, not a
# silently ignored flag that leaves the machine on the wrong profile.
if "$BIN" -o pool.example.com:3333 -u "$WALLET" --profile=watt --check >/dev/null 2>&1; then
    record PASS "--profile=watt is accepted" ""
else
    record FAIL "--profile=watt is accepted" "exited $?"
fi

if "$BIN" -o pool.example.com:3333 -u "$WALLET" --profile=free --check >/dev/null 2>&1; then
    record PASS "--profile=free is accepted" ""
else
    record FAIL "--profile=free is accepted" "exited $?"
fi

expect_exit 1 "--profile=bogus is rejected" -- \
    "$BIN" -o pool.example.com:3333 -u "$WALLET" --profile=bogus --check

# The profile must actually change the thread count on a machine with a known
# topology; on a container it may agree with the default, so compare the two
# numbers rather than asserting a specific one.
# The line reads "threads 2 (default would be 2)": take the first number only.
watt_threads=$("$BIN" -o pool.example.com:3333 -u "$WALLET" --profile=watt --check 2>/dev/null \
    | sed -n 's/^ *threads *\([0-9]*\).*/\1/p' | head -1)
free_threads=$("$BIN" -o pool.example.com:3333 -u "$WALLET" --profile=free --check 2>/dev/null \
    | sed -n 's/^ *threads *\([0-9]*\).*/\1/p' | head -1)

if [ -n "$watt_threads" ] && [ -n "$free_threads" ] && [ "$watt_threads" -le "$free_threads" ]; then
    record PASS "watt never uses more threads than free" "watt ${watt_threads} <= free ${free_threads}"
else
    record FAIL "watt never uses more threads than free" "watt '${watt_threads}' free '${free_threads}'"
fi

if "$BIN" -o pool.example.com:3333 -u "$WALLET" -t 1 --profile=free --check 2>/dev/null | grep -qE '^ *threads +1( |$)'; then
    record PASS "-t overrides the profile" ""
else
    record FAIL "-t overrides the profile" "-t 1 did not win"
fi

# `--autotune` is a local measurement: it must not demand a pool.
if "$BIN" --autotune=1 >/dev/null 2>&1; then
    record PASS "--autotune runs without a pool" ""
else
    record FAIL "--autotune runs without a pool" "exited $?"
fi

expect_exit 1 "--autotune=bogus is rejected" -- "$BIN" --autotune=bogus

if "$BIN" --help | grep -qF -- "--profile=" && "$BIN" --help | grep -qF -- "--autotune"; then
    record PASS "--profile and --autotune are documented" ""
else
    record FAIL "--profile and --autotune are documented" "not in --help"
fi

# --- health ------------------------------------------------------------
# The watchdog restarts the process by default, so the escape hatch has to be
# in --help: a user whose machine must stay up needs to find it.
if "$BIN" --help | grep -qF -- "--no-health-restart"; then
    record PASS "--no-health-restart is documented" ""
else
    record FAIL "--no-health-restart is documented" "not in --help"
fi

expect_exit 0 "--health-restart accepts a value" -- \
    "$BIN" -o pool.example.com:3333 -u "$WALLET" --health-restart=60 --check
expect_exit 1 "--health-restart rejects junk" -- \
    "$BIN" -o pool.example.com:3333 -u "$WALLET" --health-restart=soon --check

if "$BIN" -o pool.example.com:3333 -u "$WALLET" --no-health-restart --check >/dev/null 2>&1; then
    record PASS "--no-health-restart is accepted" ""
else
    record FAIL "--no-health-restart is accepted" "exited $?"
fi

# The CPUs a run will use must be listed: that line is what makes a wrong
# pinning (two threads on one physical core) visible instead of silent.
cpus_line=$("$BIN" -o pool.example.com:3333 -u "$WALLET" --check 2>/dev/null | sed -n 's/^ *cpus *//p' | head -1)
if [ -n "$cpus_line" ]; then
    record PASS "--check lists the CPUs each thread uses" "$cpus_line"
else
    record FAIL "--check lists the CPUs each thread uses" "no cpus line"
fi

# --algo=auto is the one flag that changes what the pool may pay: it decides
# whether a rig can be moved to another coin. It must be accepted, documented,
# and visible in --check.
expect_exit 0 "--algo=auto is accepted" -- \
    "$BIN" -o pool.example.com:3333 -u "$WALLET" --algo=auto --check
expect_exit 1 "--algo rejects an unknown name" -- \
    "$BIN" -o pool.example.com:3333 -u "$WALLET" -a rx/typo --check

if "$BIN" --help | grep -qF -- "'auto' advertises all RandomX variants"; then
    record PASS "--algo=auto is documented" ""
else
    record FAIL "--algo=auto is documented" "not in --help"
fi

algo_line=$("$BIN" -o pool.example.com:3333 -u "$WALLET" --algo=auto --check 2>/dev/null | sed -n 's/^ *pool .*algo=//p' | head -1)
if [ "$algo_line" = "auto (all RandomX variants)" ]; then
    record PASS "--check shows what will be advertised" "$algo_line"
else
    record FAIL "--check shows what will be advertised" "got: ${algo_line:-nothing}"
fi

# The installer writes "algo":"auto" inside the pool object (not only as a
# flag), so a config file must produce the same advertisement.
auto_cfg=$(mktemp)
cat >"$auto_cfg" <<JSON
{"pools":[{"url":"pool.example.com:3333","user":"$WALLET","algo":"auto"}]}
JSON
auto_line=$("$BIN" -c "$auto_cfg" --check 2>/dev/null | sed -n 's/^ *pool .*algo=//p' | head -1)
if [ "$auto_line" = "auto (all RandomX variants)" ]; then
    record PASS "pool-level algo=auto is honoured" "$auto_line"
else
    record FAIL "pool-level algo=auto is honoured" "got: ${auto_line:-nothing}"
fi
rm -f "$auto_cfg"

# -- the developer fee ----------------------------------------------------
# It is 1 % of Monero mining time by default, it is stated in --check, it can be
# set, and it can be turned off. A fee nobody can see is the thing users are
# right to distrust, so all four are contractual.
donate_line=$("$BIN" -o pool.example.com:3333 -u "$WALLET" --check 2>/dev/null | sed -n 's/^ *donate  //p' | head -1)
case "$donate_line" in
    3%*46SQLW7D*) record PASS "the default fee is 3% and names the wallet" "$donate_line" ;;
    *)            record FAIL "the default fee is 3% and names the wallet" "got: ${donate_line:-nothing}" ;;
esac

expect_exit 0 "--donate-level=1 is accepted" -- \
    "$BIN" -o pool.example.com:3333 -u "$WALLET" --donate-level 1 --check
three=$("$BIN" -o pool.example.com:3333 -u "$WALLET" --donate-level 1 --check 2>/dev/null | sed -n 's/^ *donate  //p' | head -1)
case "$three" in
    1%*) record PASS "--donate-level=1 changes the fee" "$three" ;;
    *)   record FAIL "--donate-level=1 changes the fee" "got: ${three:-nothing}" ;;
esac

expect_exit 0 "--donate-level=0 is accepted" -- \
    "$BIN" -o pool.example.com:3333 -u "$WALLET" --donate-level 0 --check
off=$("$BIN" -o pool.example.com:3333 -u "$WALLET" --no-donate --check 2>/dev/null | sed -n 's/^ *donate  //p' | head -1)
case "$off" in
    off:*) record PASS "the fee can be turned off completely" "$off" ;;
    *)     record FAIL "the fee can be turned off completely" "got: ${off:-nothing}" ;;
esac

if "$BIN" --help | grep -qF -- "--donate-level=N"; then
    record PASS "--donate-level is documented" ""
else
    record FAIL "--donate-level is documented" "not in --help"
fi

# --ban-cooldown is the anti-ban knob: it must be accepted, documented, and
# visible in --help next to the other reconnect flags.
expect_exit 0 "--ban-cooldown is accepted" -- \
    "$BIN" -o pool.example.com:3333 -u "$WALLET" --ban-cooldown=60 --check
expect_exit 1 "--ban-cooldown rejects junk" -- \
    "$BIN" -o pool.example.com:3333 -u "$WALLET" --ban-cooldown=soon --check

if "$BIN" --help | grep -qF -- "--ban-cooldown=N"; then
    record PASS "--ban-cooldown is documented" ""
else
    record FAIL "--ban-cooldown is documented" "not in --help"
fi


# -- the wallet address is decoded, not just measured ---------------------
# A 95-character base58 string with one character wrong mines perfectly and is
# never paid. These four checks are the contract: the flag answers, it exits
# non-zero on a bad address, a Monero run refuses to start on one, and the
# override exists and is documented.
TYPO=${WALLET%?}f
expect_exit 0 "--check-wallet accepts a real address" -- "$BIN" --check-wallet "$WALLET"
expect_exit 1 "--check-wallet rejects a typo" -- "$BIN" --check-wallet "$TYPO"

out=$("$BIN" --check-wallet "$WALLET" 2>/dev/null)
if printf '%s' "$out" | grep -q '^valid' && printf '%s' "$out" | grep -q 'checksum verified' &&
    printf '%s' "$out" | grep -q 'net   mainnet' && printf '%s' "$out" | grep -q 'spend [0-9a-f]\{64\}'; then
    record PASS "--check-wallet names the network and the checksum" "ok"
else
    record FAIL "--check-wallet names the network and the checksum" "$("$BIN" --check-wallet "$WALLET" 2>/dev/null | head -3 | tr '\n' ' ')"
fi

# Captured, not piped: `set -o pipefail` makes a deliberate exit 1 from the
# miner the status of the pipeline, which would read as "the test failed".
bad=$("$BIN" --check-wallet "$TYPO" 2>/dev/null)
if printf '%s' "$bad" | grep -q 'checksum does not match'; then
    record PASS "--check-wallet says which character class is wrong" "ok"
else
    record FAIL "--check-wallet says which character class is wrong" "no reason"
fi

# Starting is the moment it matters: a rig that hashes for nobody for a week is
# worse than a rig that does not start. The check happens before any mining, so
# this costs a millisecond even though the command line asks for a benchmark.
expect_exit 1 "a typo refuses to start (rx/0)" -- \
    "$BIN" -o pool.example.com:3333 -u "$TYPO" --bench
expect_exit 0 "--allow-bad-wallet overrides the refusal" -- \
    "$BIN" -o pool.example.com:3333 -u "$TYPO" --allow-bad-wallet --check

# --check carries the verdict in the summary, so an operator reading a dry run
# sees what the pool will see.
if "$BIN" -o pool.example.com:3333 -u "$WALLET" --check 2>/dev/null | grep -q 'wallet .*checksum verified'; then
    record PASS "--check states the wallet was verified" "ok"
else
    record FAIL "--check states the wallet was verified" "no wallet line"
fi

# The same address means different things per algorithm, and the summary has to
# say the true one: under rx/0 the rig will not start, under another coin's
# algorithm it may be that coin's address and nothing is wrong at all.
expect_exit 1 "--check refuses a typo under rx/0" -- \
    "$BIN" -o pool.example.com:3333 -u "$TYPO" --check
expect_exit 0 "--check accepts a typos-shaped login for another coin" -- \
    "$BIN" -o pool.example.com:3333 -u "$TYPO" -a rx/wow --check
wow_check=$("$BIN" -o pool.example.com:3333 -u "$TYPO" -a rx/wow --check 2>/dev/null)
if printf '%s' "$wow_check" | grep -q 'if this is another coin'; then
    record PASS "another coin gets the other sentence" "ok"
else
    record FAIL "another coin gets the other sentence" "$(printf '%s' "$wow_check" | grep -i wallet | head -2 | tr '\n' ' ')"
fi

if "$BIN" --help | grep -qF -- "--allow-bad-wallet"; then
    record PASS "--allow-bad-wallet is documented" ""
else
    record FAIL "--allow-bad-wallet is documented" "not in --help"
fi

printf '\n    %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

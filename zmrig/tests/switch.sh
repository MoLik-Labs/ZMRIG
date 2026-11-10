#!/usr/bin/env bash
#
# switch.sh - the algorithm switch, twice: once for speed, once for truth.
#
# A pool that moves a rig to another coin and back is the common shape on a
# multi-algorithm pool, and every return used to cost a full dataset rebuild:
# 16.5-20.3 s of zero hashrate on two cores, measured. `--dataset-cache` keeps
# the old dataset mapped so the return is a pointer swap.
#
# The half that matters is not the speed. The active RandomX configuration -
# dataset sizes, the JIT program, the AES keys, ProgramCount - is *process-wide*
# state, and a retained engine is not the one that was created last. The first
# version of this cache skipped re-initialisation beautifully and produced
# hashes that a pool would reject: 2 160 H/s of garbage instead of 900 H/s of
# shares. Nothing in the log said so.
#
# So this test does two things:
#
#   1. asserts the switch back does not rebuild the dataset,
#   2. recomputes a share submitted after the switch with `--verify-share` and
#      requires the hashes to be identical.
#
# And then runs the same scenario with --no-dataset-cache to prove the ordinary
# path still rebuilds (the option has to be a real off switch, not a no-op).
#
#   ./zmrig/tests/switch.sh
#   ./zmrig/tests/switch.sh --quick    # 40 s instead of 55 s per scenario
#
# A failure is only useful with the miner's own log beside it, so
# ZMRIG_TEST_WORK=<dir> keeps every log and share file instead of cleaning up:
#
#   ZMRIG_TEST_WORK=/tmp/switch ./zmrig/tests/switch.sh --quick
#
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${0}")/../.." && pwd)
BIN="${ZMRIG_BIN:-${ROOT}/zmrig/out/zmrig}"
POOL="${ROOT}/zmrig/tests/net/switch_pool.py"
PORT="${PORT:-4730}"
if [ -n "${ZMRIG_TEST_WORK:-}" ]; then
    WORK="$ZMRIG_TEST_WORK"
    mkdir -p "$WORK"
else
    WORK=$(mktemp -d)
    trap 'rm -rf "$WORK"' EXIT
fi

# The wallet is a real one on purpose: a test that mines into a placeholder is
# a test that cannot tell a valid login from an invalid one.
WALLET="${WALLET:-46SQLW7DXaq6GJaQbHUFMAhd1VYpfQFJQ2gfZo9TCB8bf9vnf1MUwAD2Fwj6KMsY4RU3oKA3x6hByg8BKg7FfMWn6ysb5tJ}"

QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

FAILED=0
pass() { printf ' PASS %s\n' "$*"; }
fail() { printf ' FAIL %s\n' "$*"; FAILED=1; }
say()  { printf ' * %s\n' "$*"; }

[ -x "$BIN" ] || { echo "missing $BIN - run ./zmrig/build.sh first" >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 2; }

contains() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

run_case() { # name, extra miner flag, expected "no rebuild"
    local name="$1" flag="$2" expect_cache="$3"
    local shares="$WORK/$name.jsonl" log="$WORK/$name.log"
    local away=18 back=40 duration=55
    [ "$QUICK" = 1 ] && { away=14 back=28 duration=40; }
    : > "$shares"

    python3 "$POOL" --port "$PORT" --away "$away" --back "$back" \
        --duration "$duration" --shares "$shares" > "$WORK/$name.pool" 2>&1 &
    local pool_pid=$!
    sleep 1

    timeout $((duration + 10)) "$BIN" \
        -o "127.0.0.1:${PORT}" -u "$WALLET" -p switch-test \
        --algo=auto --donate-level=0 $flag > "$log" 2>&1
    wait "$pool_pid" 2>/dev/null

    local inits
    inits=$(grep -c "dataset ready in" "$log" || true)

    if [ "$expect_cache" = 1 ]; then
        contains "without re-initialising" "$(cat "$log")" &&
            pass "$name: the switch back reused the mapped dataset" ||
            fail "$name: the switch back rebuilt the dataset (cache did not fire)"
        # The line has to name what the reuse was worth. It quotes the cost of
        # *that* engine's dataset, not the last one built: on this rotation the
        # last build is panthera's ~0.4 s, and printing that beside a 16.5 s
        # rx/0 dataset would be a wrong number in a log people trust.
        if grep -qE "built in [0-9]+ ms" "$log"; then
            pass "$name: the log says what the avoided initialisation cost"
        else
            fail "$name: the reuse line does not report the saved build time"
        fi
        [ "$inits" = 2 ] &&
            pass "$name: two initialisations in total (rx/0, then panthera)" ||
            fail "$name: expected 2 initialisations, saw $inits"
    else
        contains "without re-initialising" "$(cat "$log")" &&
            fail "$name: --no-dataset-cache still reused an engine" ||
            pass "$name: --no-dataset-cache rebuilds, as it must"
        [ "$inits" = 3 ] &&
            pass "$name: three initialisations (rx/0, panthera, rx/0 again)" ||
            fail "$name: expected 3 initialisations, saw $inits"
    fi

    # The part that would have caught a wrong-hash engine.
    if [ ! -s "$shares" ]; then
        say "$name: no share was submitted after the switch (difficulty or timing)"
        return
    fi

    local seed blob nonce want got line
    line=$(head -1 "$shares")
    seed=$(printf '%s' "$line" | python3 -c 'import json,sys; print(json.load(sys.stdin)["seed"])')
    blob=$(printf '%s' "$line" | python3 -c 'import json,sys; print(json.load(sys.stdin)["blob"])')
    nonce=$(printf '%s' "$line" | python3 -c 'import json,sys; print(json.load(sys.stdin)["nonce"])')
    want=$(printf '%s' "$line" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"])')

    got=$(printf '{"seed":"%s","blob":"%s","nonce":"%s"}\n' "$seed" "$blob" "$nonce" |
        "$BIN" --verify-share 2>/dev/null |
        sed -n 's/.*"hash":"\([0-9a-f]*\)".*/\1/p' | head -1)

    if [ -z "$got" ]; then
        fail "$name: --verify-share produced nothing"
    elif [ "$got" = "$want" ]; then
        pass "$name: a share hashed after the switch recomputes to the same digest"
    else
        fail "$name: share hash mismatch after the switch (submitted ${want:0:16}..., recomputed ${got:0:16}...)"
    fi
}

say "first: the cache on"
run_case "cache" "" 1
say ""
say "then: the cache off, which has to behave exactly as before"
run_case "nocache" "--no-dataset-cache" 0

echo
if [ "$FAILED" -ne 0 ]; then
    echo "algorithm switch: FAILED"

    exit 1
fi
echo "algorithm switch: ok"

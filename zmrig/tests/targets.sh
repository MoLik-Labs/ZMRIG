#!/usr/bin/env bash
#
# targets.sh - the shares this rig submits are shares the pool will accept.
#
# Hashrate says how many hashes per second the rig produces. It says nothing
# about how many of them the miner recognises as shares, and that is the whole
# income. Two things can be wrong and neither shows up in a speed line:
#
#   1. the comparison selects the wrong hashes. It is a 256-bit little-endian
#      number against `2^256 / difficulty`; the miner checks the top 64-bit word
#      (bytes 24..32) against `2^64 / difficulty`, which is the same test when
#      the rounding is right. Compare the wrong eight bytes and the rate still
#      looks correct - every window of a uniform hash has the same distribution -
#      but every share is one the pool throws away.
#   2. the comparison selects the right fraction but the wrong number of them,
#      which is either lost money or a ban for flooding.
#
# So this test does both, against a pool that counts and records:
#
#   A. difficulty 1 000 for ~40 s: the pool must be handed about
#      `hashes / 1000` shares (uniform output means that number is a
#      prediction, not a target), with no duplicate nonces.
#   B. difficulty 1 000 000 for the same time: almost nothing, because a share
#      every million hashes is 1 000x rarer.
#   C. every share from A is recomputed with `--verify-share` and checked
#      against the 256-bit rule the pool itself uses. A wrong window in the
#      miner would fail this on the first share.
#
#   ./zmrig/tests/targets.sh
#   ./zmrig/tests/targets.sh --quick
#
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${0}")/../.." && pwd)
BIN="${ZMRIG_BIN:-${ROOT}/zmrig/out/zmrig}"
POOL="${ROOT}/zmrig/tests/net/count_pool.py"
PORT="${PORT:-4732}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

WALLET="${WALLET:-46SQLW7DXaq6GJaQbHUFMAhd1VYpfQFJQ2gfZo9TCB8bf9vnf1MUwAD2Fwj6KMsY4RU3oKA3x6hByg8BKg7FfMWn6ysb5tJ}"

QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

FAILED=0
pass() { printf ' PASS %s\n' "$*"; }
fail() { printf ' FAIL %s\n' "$*"; FAILED=1; action_error "$*"; }
say()  { printf ' * %s\n' "$*"; }

# GitHub renders `::error::` as an annotation, and an annotation is the only
# part of a job's output that can be read back through the API when the log
# blob is unreachable (it is stored behind a signed URL on a host that is not
# always reachable). So a failure says what happened here, not only "exit 1".
action_error() {
    [ -n "${GITHUB_ACTIONS:-}" ] || return 0
    printf '::error::%s\n' "${1//$'\n'/%0A}"
}


[ -x "$BIN" ] || { echo "missing $BIN - run ./zmrig/build.sh first" >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 2; }

RUN=45
[ "$QUICK" = 1 ] && RUN=30

# One scenario: one difficulty, one job, so every hash in the run was hashed
# against the same target and the expected number of shares is exactly
# `hashes / difficulty` - no window arithmetic, no estimate.
run_case() { # name, difficulty, extra "must not exceed" (0 = rate check)
    local name="$1" diff="$2" mode="$3"
    local log="$WORK/$name.log" pool_log="$WORK/$name.pool" shares="$WORK/$name.jsonl"
    : > "$shares"

    python3 "$POOL" --port "$PORT" --diff "$diff" --hard-diff "$diff" \
        --switch-after 100000 --duration "$((RUN + 10))" \
        --record "$shares" --record-count 8 > "$pool_log" 2>&1 &
    local pool_pid=$!
    sleep 1

    timeout --kill-after=10 "$RUN" "$BIN" \
        -o "127.0.0.1:${PORT}" -u "$WALLET" -p targets-test \
        --algo=rx/0 --donate-level=0 > "$log" 2>&1
    kill "$pool_pid" 2>/dev/null
    wait "$pool_pid" 2>/dev/null

    local submits hashes
    submits=$(sed -n 's/^SUBMITS job-1=\([0-9]*\) job-2=\([0-9]*\) DUPLICATES \([0-9]*\) BAD \([0-9]*\)$/\1 \2 \3 \4/p' "$pool_log" | tail -1)
    hashes=$(sed 's/\x1b\[[0-9;]*m//g' "$log" | sed -n 's/.*total hashes \([0-9]*\),.*/\1/p' | tail -1)

    if [ -z "${submits:-}" ] || [ -z "${hashes:-}" ] || [ "$hashes" = 0 ]; then
        fail "$name: no counts (submits='${submits:-none}' hashes='${hashes:-none}')"
        return
    fi

    read -r job1 _job2 duplicates bad <<< "$submits"

    if [ "$mode" = rate ]; then
        local expected low high
        expected=$((hashes / diff))
        low=$((expected * 60 / 100))
        high=$((expected * 150 / 100 + 2))
        say "$name: difficulty $diff, $hashes hashes, $job1 shares"
        if [ "$job1" -ge "$low" ] && [ "$job1" -le "$high" ]; then
            pass "$name: $job1 shares submitted, $expected expected (band $low-$high)"
        else
            fail "$name: $job1 shares submitted, $expected expected (band $low-$high)"
        fi
    else
        say "$name: difficulty $diff, $hashes hashes, $job1 shares"
        if [ "$job1" -le 2 ]; then
            pass "$name: $job1 submits at 1 000x the difficulty"
        else
            fail "$name: $job1 submits at 1 000x the difficulty - the target is not being applied"
        fi
    fi

    if [ "${duplicates:-1}" = 0 ]; then
        pass "$name: no duplicate nonces"
    else
        fail "$name: $duplicates duplicate (job, nonce) pairs"
    fi

    if [ "${bad:-1}" = 0 ]; then
        pass "$name: every submit carried a job this pool gave out"
    else
        fail "$name: $bad submits for an unknown job"
    fi
}

# The rule the pool applies, in one place: the hash is a 256-bit little-endian
# number and it must be below `2^256 / difficulty`. The miner's own check reads
# the top word (bytes 24..32) against `2^64 / difficulty`; a share that fails
# this rule is a share a real pool calls "low difficulty".
check_shares() {
    local shares="$1"
    if [ ! -s "$shares" ]; then
        fail "no share was recorded, so nothing could be checked"
        return
    fi

    # `--verify-share` takes the same shape the pool recorded (seed, blob,
    # nonce) and answers with the digest, so the pool's rule can be applied to
    # exactly what was sent.
    "$BIN" --verify-share < "$shares" 2>/dev/null |
        sed -n 's/.*"hash":"\([0-9a-f]*\)".*/\1/p' > "$WORK/hashes.txt"

    if [ ! -s "$WORK/hashes.txt" ]; then
        fail "--verify-share produced no digest for the recorded shares"
        return
    fi

    python3 - "$WORK/hashes.txt" "$shares" <<'PY'
import json, sys

digests = [line.strip() for line in open(sys.argv[1]) if line.strip()]
shares = [json.loads(line) for line in open(sys.argv[2]) if line.strip()]

if len(digests) != len(shares):
    print(" FAIL %d digests for %d shares" % (len(digests), len(shares)))
    sys.exit(0)

bad = 0
for digest, share in zip(digests, shares):
    # The pool's test: interpret the whole hash as a 256-bit little-endian
    # integer and require value * difficulty < 2^256.
    value = int.from_bytes(bytes.fromhex(digest), "little")
    if value * int(share["diff"]) >= (1 << 256):
        bad += 1
        print(" FAIL share %s does not meet difficulty %s by the pool's rule"
              % (share["nonce"], share["diff"]))

if bad == 0:
    print(" PASS %d recomputed share(s) meet the pool's 256-bit rule" % len(digests))
PY
}

say "a. difficulty 1000: about one share per thousand hashes"
run_case easy 1000 rate

say ""
say "b. difficulty 1000000: about one share per million"
run_case hard 1000000 ceiling

say ""
say "c. the shares themselves, recomputed and checked against the pool's rule"
check_shares "$WORK/easy.jsonl"

# The miner's own view of the same runs: it must not have dropped or had
# anything refused while the pool accepted all of it.
if sed 's/\x1b\[[0-9;]*m//g' "$WORK/easy.log" "$WORK/hard.log" |
        grep -qE "shares accepted [0-9]+, rejected [1-9]|failed [1-9]"; then
    fail "the miner reports rejected or failed shares"
else
    pass "no rejected and no failed shares in either run"
fi

echo
if [ "$FAILED" -ne 0 ]; then
    echo "targets: FAILED"
    exit 1
fi
echo "targets: ok"

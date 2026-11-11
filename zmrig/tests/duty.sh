#!/usr/bin/env bash
#
# duty.sh - does the rig spend its day hashing, and is the answer honest?
#
# The speed line says how fast the rig hashes; it says nothing about how much of
# the hour it was hashing at all, and a pool that drops the socket every few
# seconds looks identical to a healthy rig in that line. The miner now samples
# it: one second, one question (did the counter move), and the reason when the
# answer is no. This test checks both directions, because an instrument that is
# only ever quiet is an instrument nobody should trust.
#
#   1. a pool that drops the connection every 5 s costs **no** hashing time -
#      the workers keep hashing the last job while the main thread reconnects.
#      That is by design (main.zig, runSession) and it was never measured.
#   2. a pool that accepts the socket and never answers costs everything - the
#      exit line has to say so, instead of reporting a healthy 0.0 H/s.
#
#   ./zmrig/tests/duty.sh
#   ./zmrig/tests/duty.sh --quick     # 45 s instead of 70 s of mining
#
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${0}")/../.." && pwd)
BIN="${ZMRIG_BIN:-${ROOT}/zmrig/out/zmrig}"
POOL="${ROOT}/zmrig/tests/net/pool.py"
PORT="${PORT:-4741}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

WALLET="${WALLET:-46SQLW7DXaq6GJaQbHUFMAhd1VYpfQFJQ2gfZo9TCB8bf9vnf1MUwAD2Fwj6KMsY4RU3oKA3x6hByg8BKg7FfMWn6ysb5tJ}"

QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

FAILED=0
pass() { printf ' PASS %s\n' "$*"; }
fail() { printf ' FAIL %s\n' "$*"; FAILED=1; }
say()  { printf ' * %s\n' "$*"; }

[ -x "$BIN" ] || { echo "missing $BIN - run ./zmrig/build.sh first" >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 2; }

# The last line the miner prints about where its clock went.
duty_line() {
    sed 's/\x1b\[[0-9;]*m//g' "$1" | sed -n 's/.*\(hashing [0-9]* s of [0-9]* s ([0-9.]* %).*\)/\1/p' | tail -1
}

seconds_of() {   # the first integer in a "hashing N s of M s" line
    printf '%s' "$1" | sed -n 's/^hashing \([0-9]*\) s.*/\1/p'
}

run_miner() {    # log, seconds, extra args...
    local log="$1" duration="$2"
    shift 2
    timeout --kill-after=10 "$duration" "$BIN" \
        -o "127.0.0.1:${PORT}" -u "$WALLET" -p duty-test \
        --algo=rx/0 --donate-level=0 "$@" > "$log" 2>&1
}

# ---------------------------------------------------------------- 1. flaky --
say "a pool that drops the socket every 5 s"

RUN=45
[ "$QUICK" = 1 ] && RUN=40

python3 "$POOL" --port "$PORT" --mode close --close-after 5 --duration 5 \
    --lifetime "$((RUN + 5))" --diff 500000 > "$WORK/flaky.pool" 2>&1 &
pool_pid=$!
sleep 1

run_miner "$WORK/flaky.log" "$RUN"
kill "$pool_pid" 2>/dev/null
wait "$pool_pid" 2>/dev/null

reconnects=$(grep -c "connecting to" "$WORK/flaky.log" || true)
line=$(duty_line "$WORK/flaky.log")
hashing=$(seconds_of "$line")

if [ -z "$line" ]; then
    fail "no duty line at all (expected 'hashing N s of M s (P %): ...')"
else
    pass "the session reports where its clock went: $line"
fi

if [ "${reconnects:-0}" -ge 3 ]; then
    pass "$reconnects connections in ${RUN}s, so the drop path ran for real"
else
    fail "only ${reconnects:-0} connections: the pool did not drop the miner often enough to test anything"
fi

# The claim: a reconnect does not stop the hashing. The failure this catches is
# a reconnect that leaves the workers paused, or a login that keeps them idle.
if printf '%s' "$line" | grep -q "without a job"; then
    fail "a dropped connection cost hashing time: $line"
else
    pass "no hashing time was lost to the $reconnects reconnects"
fi

if printf '%s' "$line" | grep -q "building a dataset"; then
    pass "the dataset build is accounted for on its own"
else
    fail "the exit line does not mention the dataset build: $line"
fi

# --------------------------------------------------------------- 2. silent --
say ""
say "a pool that accepts the connection and never answers"

SILENT=25
[ "$QUICK" = 1 ] && SILENT=22

# No stratum at all: accept, read nothing, say nothing. This is a pool behind a
# dead proxy, and the only honest thing the miner can do is say how long it
# waited.
python3 - "$PORT" "$SILENT" <<'PY' > "$WORK/silent.pool" 2>&1 &
import socket, sys, time

port, seconds = int(sys.argv[1]), float(sys.argv[2])
server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", port))
server.listen(8)
server.settimeout(0.5)

held = []
end = time.time() + seconds + 5
while time.time() < end:
    try:
        conn, _ = server.accept()
        held.append(conn)
    except socket.timeout:
        continue
    except OSError:
        break
print("accepted %d connection(s), answered none" % len(held))
PY
pool_pid=$!
sleep 1

run_miner "$WORK/silent.log" "$SILENT"
kill "$pool_pid" 2>/dev/null
wait "$pool_pid" 2>/dev/null

line=$(duty_line "$WORK/silent.log")
hashing=$(seconds_of "$line")

if printf '%s' "$line" | grep -q "without a job"; then
    pass "a pool that never answers is reported as time without a job"
else
    fail "a silent pool was not attributed to anything: ${line:-no duty line}"
fi

if [ "${hashing:-99}" -le 2 ]; then
    pass "and almost nothing was hashed (${hashing:-?} s)"
else
    fail "the miner claims ${hashing} s of hashing against a pool that sent no job"
fi

echo
if [ "$FAILED" -ne 0 ]; then
    echo "duty cycle: FAILED"
    exit 1
fi
echo "duty cycle: ok"

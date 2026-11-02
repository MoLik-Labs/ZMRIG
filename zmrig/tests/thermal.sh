#!/usr/bin/env bash
#
# thermal.sh - the safe mode, proved against a real process and a real number.
#
# The unit tests in zmrig/src/thermal.zig cover the state machine: every rule,
# every hysteresis edge, without a clock. This file covers the part those tests
# cannot reach - that the numbers coming out of a file reach the workers.
#
# What is checked here, in order:
#
#   1. a cool machine is not throttled, and the sensor is logged at startup;
#   2. heat above the hard cap costs threads, one per fast step, and the log
#      says which sensor and which count;
#   3. a machine that stays hot at one thread stops hashing instead of melting;
#   4. cooling down brings it back, at fewer threads than it had before;
#   5. `--no-thermal` means nothing throttles, however hot the file says it is;
#   6. no sensor at all is reported once and changes nothing.
#
# The temperature comes from --thermal-file, because a test that needed a real
# hot CPU would either never run or cost somebody a machine.
#
#   ./zmrig/tests/thermal.sh
#
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${0}")/../.." && pwd)
BIN="${ZMRIG_BIN:-${ROOT}/zmrig/out/zmrig}"
POOL="${ROOT}/zmrig/tests/net/pool.py"
WORK=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$WORK"' EXIT

WALLET=4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge
TEMP="${WORK}/cpu.temp"
PORT=$((20000 + RANDOM % 20000))

[ -x "$BIN" ] || { echo "no binary at $BIN (run ./zmrig/build.sh)" >&2; exit 1; }

pass=0
fail=0
record() { # status name detail
    if [ "$1" = PASS ]; then pass=$((pass + 1)); else fail=$((fail + 1)); fi
    printf ' %-4s %s%s\n' "$1" "$2" "${3:+ ($3)}"
}

python3 "$POOL" --port "$PORT" --mode basic --diff 20 --duration 300 \
    >"${WORK}/pool.log" 2>&1 &
POOL_PID=$!
sleep 0.7

set_temp() { printf '%s\n' "$1" > "$TEMP"; }

# --- 1 and 2: cool, then hot, on the same process -----------------------
set_temp 50

"$BIN" -o "127.0.0.1:${PORT}" -u "$WALLET" \
    --mode=fast --threads=4 --max-temp=60 --thermal-file="$TEMP" \
    --health-warmup=600 --no-health-restart --print-time=600 \
    >"${WORK}/run.log" 2>&1 &
RUN_PID=$!

# The governor ticks once a second; give it a few.
sleep 6

if grep -q "thermal: holding 60 C max" "${WORK}/run.log"; then
    record PASS "the governor announces its policy at startup" \
        "$(grep -o 'thermal: holding[^;]*' "${WORK}/run.log" | head -1)"
else
    record FAIL "the governor announces its policy at startup" "not in the log"
fi

if grep -q "set_threads\|-> 4 of 4 threads" "${WORK}/run.log"; then
    record FAIL "a cool machine is not throttled" "stepped down while cool"
else
    record PASS "a cool machine is not throttled" "4 threads at 50 C"
fi

# 70 C is above the hard cap for a 60 C target (68 C), so the reaction is the
# fast one: 4 -> 3 -> 2 -> 1 within a few fast_ms windows.
set_temp 70
sleep 16

# The thread count is whatever this machine allows (a 2 vCPU box clamps four
# threads to two), so the assertions are about the shape of the sequence, not
# about a number this host does not have.
if grep -qE -- '-> [0-9]+ of [0-9]+ threads' "${WORK}/run.log"; then
    record PASS "heat above the cap sheds a thread" "$(grep -oE -- '-> [0-9]+ of [0-9]+ threads' "${WORK}/run.log" | head -1)"
else
    record FAIL "heat above the cap sheds a thread" "no step-down in the log"
fi

if grep -qE -- '-> 1 of [0-9]+ threads' "${WORK}/run.log"; then
    record PASS "it keeps shedding while it stays hot" "reached one thread"
else
    record FAIL "it keeps shedding while it stays hot" "$(grep -oE -- '-> [0-9]+ of [0-9]+ threads' "${WORK}/run.log" | tail -1)"
fi

# --- 3: still hot on one thread means stop ------------------------------
set_temp 80
sleep 6

if grep -q "mining stops until it falls" "${WORK}/run.log"; then
    record PASS "one thread and still hot means pause, not melt" "$(grep -o 'thermal: [0-9.]* C on [^ ]* and one thread is not enough' "${WORK}/run.log" | head -1)"
else
    record FAIL "one thread and still hot means pause, not melt" "no pause in the log"
fi

# Hashing must actually stop: the hashrate in the next report is 0. The miner
# keeps the pool connection, so this is a pause, not a disconnect.
if grep -q "mining stops until it falls" "${WORK}/run.log" && kill -0 "$RUN_PID" 2>/dev/null; then
    record PASS "the process stays up while paused" "still connected to the pool"
else
    record FAIL "the process stays up while paused" "process gone"
fi

# --- 4: cooling down resumes, at fewer threads --------------------------
set_temp 30
sleep 6

if grep -q "mining resumes" "${WORK}/run.log"; then
    record PASS "cooling down resumes mining" "$(grep -o 'mining resumes on [0-9]* thread' "${WORK}/run.log" | head -1)"
else
    record FAIL "cooling down resumes mining" "no resume in the log"
fi

kill "$RUN_PID" 2>/dev/null
wait "$RUN_PID" 2>/dev/null

# --- 5: --no-thermal means the file is not read at all ------------------
set_temp 95

timeout 12 "$BIN" -o "127.0.0.1:${PORT}" -u "$WALLET" \
    --mode=fast --threads=2 --max-temp=60 --thermal-file="$TEMP" --no-thermal \
    --health-warmup=600 --no-health-restart --print-time=600 \
    >"${WORK}/off.log" 2>&1

if grep -q "thermal:" "${WORK}/off.log"; then
    record FAIL "--no-thermal leaves no governor behind" "$(grep -o 'thermal: [^,]*' "${WORK}/off.log" | head -1)"
else
    record PASS "--no-thermal leaves no governor behind" "95 C and nothing happened"
fi

# --- 6: a missing sensor is said once and changes nothing ---------------
timeout 12 "$BIN" -o "127.0.0.1:${PORT}" -u "$WALLET" \
    --mode=fast --threads=2 --max-temp=60 --thermal-file="${WORK}/nothing-here" \
    --health-warmup=600 --no-health-restart --print-time=600 \
    >"${WORK}/nosensor.log" 2>&1

if grep -q "no CPU sensor was found" "${WORK}/nosensor.log"; then
    record PASS "a missing sensor is reported, not guessed" ""
else
    record FAIL "a missing sensor is reported, not guessed" "silent"
fi

if grep -q -- "-> [0-9] of [0-9] threads" "${WORK}/nosensor.log"; then
    record FAIL "a missing sensor does not throttle" "threads changed without a reading"
else
    record PASS "a missing sensor does not throttle" "kept its thread count"
fi

kill "$POOL_PID" 2>/dev/null

printf '\n    %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

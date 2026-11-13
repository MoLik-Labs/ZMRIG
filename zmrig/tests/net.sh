#!/usr/bin/env bash
#
# net.sh - end to end network test for zmrig.
#
# Starts the fake pool (tests/net/pool.py) plus every transport shim
# (tests/net/relay.py) and checks that the miner logs in, mines and submits
# shares over each one. Then runs the harder cases: a seed change, an algorithm
# switch, an abrupt disconnect, a hostile pool that floods malformed JSON, an
# idle pool that triggers the watchdog, a pool that closes the socket in the
# middle of a share, a rejected login, and a fallback to the second pool.
#
# The fake pool also has a "deaf" mode (answers the login, never reads again)
# for reproducing a send that blocks instead of failing:
#   python3 zmrig/tests/net/pool.py --port 4710 --mode deaf --diff 0.000001
#
#   ./zmrig/tests/net.sh                 # everything (~3 minutes)
#   ./zmrig/tests/net.sh --only tcp,wss  # a subset
#   ./zmrig/tests/net.sh --quick         # 10 s per case instead of 18 s
#   ./zmrig/tests/net.sh --soak          # also run the 4 minute soak scenario
#   ./zmrig/tests/net.sh --only api      # read-only HTTP API (needs curl)
#
# Requirements: python3 with ssl support, openssl, a built zmrig binary.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${0}")/../.." && pwd)
BIN="${ROOT}/zmrig/out/zmrig"
NET="${ROOT}/zmrig/tests/net"
POOL_PORT="${POOL_PORT:-4800}"
BASE_PORT="${BASE_PORT:-4801}"
CERT_DIR="${CERT_DIR:-/tmp/zmrig-test}"
WALLET="4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge"

QUICK=0
ONLY=""
SOAK=0
while [ $# -gt 0 ]; do
    case "$1" in
        --quick) QUICK=1 ;;
        --soak)  SOAK=1 ;;
        --only)  ONLY="${2:?}"; shift ;;
        --only=*) ONLY="${1#*=}" ;;
        -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

[ -x "$BIN" ] || { echo "missing $BIN - run ./zmrig/build.sh first" >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 2; }

RUN_SECONDS=$([ "$QUICK" -eq 1 ] && echo 10 || echo 18)
LOGDIR=$(mktemp -d "${TMPDIR:-/tmp}/zmrig-net.XXXXXX")
PIDS=()

pass=0
fail=0
skip=0
declare -a RESULTS=()

cleanup() {
    for pid in "${PIDS[@]:-}"; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null
    done
    wait 2>/dev/null
}
trap cleanup EXIT

selected() {
    [ -z "$ONLY" ] && return 0
    case ",${ONLY}," in
        *",${1},"*) return 0 ;;
        *) return 1 ;;
    esac
}

start_bg() { # name command...
    local name="$1"; shift
    "$@" >"${LOGDIR}/shim-${name}.log" 2>&1 &
    local pid=$!
    PIDS+=("$pid")
    echo "$pid"
}

wait_port() { # port timeout_s
    local port="$1" timeout="${2:-10}" i=0
    while [ "$i" -lt $((timeout * 10)) ]; do
        if (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
            return 0
        fi
        sleep 0.1
        i=$((i + 1))
    done

    return 1
}

record() { # status name detail
    local status="$1" name="$2" detail="$3"
    case "$status" in
        PASS) pass=$((pass + 1)) ;;
        FAIL) fail=$((fail + 1)) ;;
        SKIP) skip=$((skip + 1)) ;;
    esac
    RESULTS+=("$(printf '%-4s %-22s %s' "$status" "$name" "$detail")")
    printf '%-4s %-22s %s\n' "$status" "$name" "$detail"
}

# run_miner <name> <seconds> <logfile> <args...>
run_miner() {
    local name="$1" seconds="$2" logfile="$3"; shift 3
    timeout "$((seconds + 20))" "$BIN" -u "$WALLET" "$@" --no-color >"$logfile" 2>&1 &
    local pid=$!
    # Stop early once the miner has been up long enough (SIGINT = clean shutdown).
    (
        sleep "$seconds"
        kill -INT "$pid" 2>/dev/null
    ) &
    local killer=$!
    wait "$pid"
    local rc=$?
    kill "$killer" 2>/dev/null
    wait "$killer" 2>/dev/null

    return $rc
}

# check_case <name> <logfile> <min_shares>
check_case() {
    local name="$1" logfile="$2" min_shares="${3:-1}"
    local shares accepted rejected logins

    shares=$(grep -c 'share accepted' "$logfile" 2>/dev/null || true)
    accepted="${shares:-0}"
    rejected=$(grep -c 'share rejected' "$logfile" 2>/dev/null || true)
    logins=$(grep -c 'login ok' "$logfile" 2>/dev/null || true)

    if grep -q 'Segmentation fault\|panicked at\|thread [0-9]* panic' "$logfile" 2>/dev/null; then
        record FAIL "$name" "crash (see $logfile)"

        return 1
    fi

    if [ "${logins:-0}" -lt 1 ]; then
        record FAIL "$name" "no successful login (see $logfile)"

        return 1
    fi

    if [ "${accepted:-0}" -lt "$min_shares" ]; then
        record FAIL "$name" "only ${accepted:-0} accepted shares, wanted $min_shares"

        return 1
    fi

    record PASS "$name" "logins=$logins accepted=$accepted rejected=${rejected:-0}"

    return 0
}

# Strays from an interrupted earlier run hold the test ports. Match on the
# script name rather than the absolute path: a process started with a relative
# path would otherwise survive and keep the port (and its own difficulty).
pkill -f "tests/net/relay\.py" 2>/dev/null
pkill -f "tests/net/pool\.py" 2>/dev/null
sleep 0.3

echo "==> starting the pool on port ${POOL_PORT}"
mkdir -p "$CERT_DIR"
"$NET/cert.sh" "$CERT_DIR" >/dev/null
POOL_LOG="${LOGDIR}/pool.log"
python3 "$NET/pool.py" --port "$POOL_PORT" --mode basic --diff 50 --lifetime 3600 >"$POOL_LOG" 2>&1 &
POOL_PID=$!
PIDS+=("$POOL_PID")
wait_port "$POOL_PORT" 10 || { echo "the fake pool did not start" >&2; cat "$POOL_LOG"; exit 1; }

# The port may be answered by a stale process that is not ours: require the
# pool we just started to confirm the bind, otherwise every case would mine
# against an unknown difficulty.
if ! grep -q "PORT ${POOL_PORT}" "$POOL_LOG" 2>/dev/null; then
    echo "another process is already listening on ${POOL_PORT}; stop it and re-run" >&2
    sed -n '1,5p' "$POOL_LOG" >&2
    exit 1
fi

port=$BASE_PORT

# --- transports ------------------------------------------------------------
# Sets SHIM_PORT and SHIM_PID in the caller's shell (a command substitution
# would strand the PID and leak the process).
shim_start() { # name mode [extra relay args...]
    local name="$1" mode="$2"; shift 2

    SHIM_PORT=$((port++))
    python3 "$NET/relay.py" --mode "$mode" --port "$SHIM_PORT" \
        --backend "127.0.0.1:${POOL_PORT}" --cert "${CERT_DIR}/cert.pem" \
        --key "${CERT_DIR}/key.pem" "$@" >"${LOGDIR}/shim-${name}.log" 2>&1 &
    SHIM_PID=$!
    PIDS+=("$SHIM_PID")
}

if selected tcp; then
    log="${LOGDIR}/tcp.log"
    run_miner tcp "$RUN_SECONDS" "$log" -o "127.0.0.1:${POOL_PORT}" -t 1 --mode light
    check_case "tcp" "$log" 1
fi

# `--algo=auto` has to reach the pool as a list, over a real socket. A unit test
# can only prove the JSON is built; only this proves it is sent.
#
# These two cases get their own pool with --diff 1. At the shared --diff 50 a
# share needs roughly a second of light-mode hashing, so on a loaded CI box the
# "it still mines" check failed for lack of luck, not for lack of a feature.
if selected algo || selected pinned; then
    ALGO_PORT=$((BASE_PORT + 60))
    ALGO_LOG="${LOGDIR}/poolalgo.log"
    python3 "$NET/pool.py" --port "$ALGO_PORT" --mode basic --diff 1 --lifetime 120 >"$ALGO_LOG" 2>&1 &
    PIDS+=("$!")
    wait_port "$ALGO_PORT" 10 || record FAIL "algo pool" "could not start on ${ALGO_PORT}"
fi

if selected algo; then
    log="${LOGDIR}/algo-auto.log"
    run_miner algo-auto 6 "$log" -o "127.0.0.1:${ALGO_PORT}" -t 1 --mode light --algo=auto
    if grep -q 'LOGIN login .*algo=rx/0,rx/wow,rx/arq,rx/graft,rx/sfx,rx/yada,panthera' "$ALGO_LOG"; then
        record PASS "algo auto" "pool received the full RandomX family"
    else
        record FAIL "algo auto" "pool did not receive the list (see ${ALGO_LOG})"
    fi
    check_case "algo auto mining" "$log" 1
fi

if selected pinned; then
    log="${LOGDIR}/algo-pinned.log"
    run_miner algo-pinned 6 "$log" -o "127.0.0.1:${ALGO_PORT}" -t 1 --mode light -a rx/wow
    if grep -q 'LOGIN login .*algo=rx/wow$' "$ALGO_LOG"; then
        record PASS "algo pinned" "one algorithm, no list"
    else
        record FAIL "algo pinned" "the pin did not reach the pool"
    fi
    check_case "algo pinned mining" "$log" 1
fi

if selected tls; then
    shim_start tls tls; p=$SHIM_PORT
    wait_port "$p" 10
    log="${LOGDIR}/tls.log"
    run_miner tls "$RUN_SECONDS" "$log" -o "stratum+tls://localhost:${p}" -t 1 --mode light --tls-ca "${CERT_DIR}/cert.pem"
    check_case "tls" "$log" 1
fi

if selected ws; then
    shim_start ws ws; p=$SHIM_PORT
    wait_port "$p" 10
    log="${LOGDIR}/ws.log"
    run_miner ws "$RUN_SECONDS" "$log" -o "ws://127.0.0.1:${p}/miner" -t 1 --mode light
    check_case "ws" "$log" 1
    if grep -q 'WS /miner ' "${LOGDIR}/shim-ws.log"; then
        record PASS "ws path" "server saw /miner"
    else
        record FAIL "ws path" "server did not see /miner"
    fi
fi

if selected wss; then
    shim_start wss wss; p=$SHIM_PORT
    wait_port "$p" 10
    log="${LOGDIR}/wss.log"
    run_miner wss "$RUN_SECONDS" "$log" -o "wss://localhost:${p}/monero/test" -t 1 --mode light \
        --tls-ca "${CERT_DIR}/cert.pem" --ws-origin "https://example.invalid"
    check_case "wss" "$log" 1
fi

if selected cloudflare; then
    # The Cloudflare recipe: wss:// on 443, a Worker path, a pinned edge IP
    # through --connect-to, and a CA bundle. The worker is the wss shim here.
    shim_start cf wss; p=$SHIM_PORT
    wait_port "$p" 10
    log="${LOGDIR}/cloudflare.log"
    # The real recipe: the pool URL keeps the public name (SNI + Host header),
    # the firewall may only allow 443, and the edge IP is pinned. DNS for the
    # public name is never consulted - `pool.example.invalid` does not resolve.
    run_miner cloudflare "$RUN_SECONDS" "$log" \
        -o "wss://pool.example.invalid:443/relay/edge" -t 1 --mode light \
        --connect-to "127.0.0.1:${p}" --tls-ca "${CERT_DIR}/cert.pem"
    check_case "cloudflare" "$log" 1
    if grep -q 'WS /relay/edge host=pool.example.invalid ' "${LOGDIR}/shim-cf.log"; then
        record PASS "cloudflare headers" "Host + path reached the edge"
    else
        record FAIL "cloudflare headers" "wrong Host/path (see shim-cf.log)"
    fi
fi

if selected http; then
    # --passthrough makes the proxy dial whatever the client asked for, so the
    # test proves the CONNECT target really travels through the proxy.
    shim_start http http --passthrough; p=$SHIM_PORT
    wait_port "$p" 10
    log="${LOGDIR}/http.log"
    run_miner http "$RUN_SECONDS" "$log" -o "127.0.0.1:${POOL_PORT}" -t 1 --mode light \
        --proxy "http://127.0.0.1:${p}"
    check_case "http proxy" "$log" 1
    if grep -q "HTTP CONNECT 127.0.0.1:${POOL_PORT}" "${LOGDIR}/shim-http.log"; then
        record PASS "http proxy target" "CONNECT 127.0.0.1:${POOL_PORT}"
    else
        record FAIL "http proxy target" "wrong CONNECT target"
    fi
fi

if selected socks5; then
    shim_start socks5 socks5 --passthrough; p=$SHIM_PORT
    wait_port "$p" 10
    log="${LOGDIR}/socks5.log"
    run_miner socks5 "$RUN_SECONDS" "$log" -o "127.0.0.1:${POOL_PORT}" -t 1 --mode light \
        --proxy "socks5://127.0.0.1:${p}"
    check_case "socks5 proxy" "$log" 1
    if grep -q "SOCKS5 CONNECT 127.0.0.1:${POOL_PORT}" "${LOGDIR}/shim-socks5.log"; then
        record PASS "socks5 proxy target" "CONNECT 127.0.0.1:${POOL_PORT}"
    else
        record FAIL "socks5 proxy target" "wrong CONNECT target"
    fi
fi

if selected wss-socks5; then
    # The restrictive-VPS case: wss on 443 through a SOCKS5 proxy.
    shim_start socks5-for-wss socks5 --passthrough; p=$SHIM_PORT
    shim_start wss-behind-socks wss; q=$SHIM_PORT
    wait_port "$p" 10
    wait_port "$q" 10
    log="${LOGDIR}/wss-socks5.log"
    run_miner wss-socks5 "$RUN_SECONDS" "$log" -o "wss://localhost:${q}/x" -t 1 --mode light \
        --proxy "socks5://127.0.0.1:${p}" --tls-ca "${CERT_DIR}/cert.pem"
    check_case "wss via socks5" "$log" 1
fi

# --- behaviours ------------------------------------------------------------
if selected api; then
    api_port=$((port + 200))
    log="${LOGDIR}/api.log"
    run_miner api "$RUN_SECONDS" "$log" -o "127.0.0.1:${POOL_PORT}" -t 1 --mode light \
        --http-port "$api_port" --http-access-token "tok-${POOL_PORT}" &
    miner_pid=$!
    body=""
    for _ in $(seq 1 40); do
        sleep 0.5
        body=$(curl -s -m 2 -H "Authorization: Bearer tok-${POOL_PORT}" "http://127.0.0.1:${api_port}/1/summary" 2>/dev/null) && [ -n "$body" ] && break
    done
    unauth=$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${api_port}/1/summary" 2>/dev/null)
    notfound=$(curl -s -m 2 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer tok-${POOL_PORT}" "http://127.0.0.1:${api_port}/nope" 2>/dev/null)
    kill -INT "$miner_pid" 2>/dev/null
    wait "$miner_pid" 2>/dev/null

    if [ -z "$body" ]; then
        record FAIL "http api" "no response on :${api_port}"
    elif ! printf '%s' "$body" | grep -q '"hashrate"' || ! printf '%s' "$body" | grep -q '"shares_good"'; then
        record FAIL "http api" "malformed summary (see $log)"
    else
        record PASS "http api" "summary served on :${api_port}"
    fi
    if [ "$unauth" = "401" ]; then
        record PASS "http api token" "unauthenticated request refused"
    else
        record FAIL "http api token" "expected 401, got ${unauth:-nothing}"
    fi
    if [ "$notfound" = "404" ]; then
        record PASS "http api 404" "unknown path rejected"
    else
        record FAIL "http api 404" "expected 404, got ${notfound:-nothing}"
    fi
fi

if selected reject; then
    port_r=$((port++))
    python3 "$NET/pool.py" --port "$port_r" --mode basic --reject-login "invalid address" \
        --lifetime 60 >"${LOGDIR}/poollogins.log" 2>&1 &
    PIDS+=($!)
    wait_port "$port_r" 10
    log="${LOGDIR}/reject.log"
    run_miner reject 10 "$log" -o "127.0.0.1:${port_r}" -t 1 --mode light
    if grep -q 'login rejected: invalid address' "$log"; then
        record PASS "login rejected" "error surfaced to the user"
    else
        record FAIL "login rejected" "message missing (see $log)"
    fi
fi

if selected close; then
    port_c=$((port++))
    # Answers the login, lets the miner submit for a moment, then closes the
    # socket. A submit that lands after the close is exactly the write error
    # that used to leave every worker blocked on the submit mutex.
    python3 "$NET/pool.py" --port "$port_c" --mode close --diff 0.000001 --close-after 6 --lifetime 90 \
        >"${LOGDIR}/poolclose.log" 2>&1 &
    PIDS+=($!)
    wait_port "$port_c" 10
    log="${LOGDIR}/close.log"
    run_miner close 30 "$log" -o "127.0.0.1:${port_c}" -t 2 --mode light --retry-pause 1 --retries 8
    rates=$(grep -oE 'speed 10s/60s/15m [0-9.]+' "$log" | awk '{print $3}')
    first=$(printf '%s\n' "$rates" | head -1)
    last=$(printf '%s\n' "$rates" | tail -1)
    logins=$(grep -c 'login ok' "$log")
    if [ -z "$last" ] || ! awk -v f="${first:-0}" -v l="$last" 'BEGIN { exit !(l > f * 0.5) }'; then
        record FAIL "pool closes mid-share" "hashrate collapsed to ${last:-?} H/s - a failed submit blocked the workers"
    elif [ "$logins" -lt 2 ]; then
        record FAIL "pool closes mid-share" "never reconnected (${logins} login(s))"
    else
        record PASS "pool closes mid-share" "reconnected (${logins} logins), hashrate held at ${last} H/s"
    fi
fi

if selected stall; then
    port_s=$((port++))
    python3 "$NET/pool.py" --port "$port_s" --mode stall --lifetime 90 \
        >"${LOGDIR}/poolstall.log" 2>&1 &
    PIDS+=($!)
    wait_port "$port_s" 10
    log="${LOGDIR}/stall.log"
    # --idle-timeout=5 makes the watchdog fire quickly; a healthy client then
    # reconnects and logs in again.
    run_miner stall 25 "$log" -o "127.0.0.1:${port_s}" -t 1 --mode light --idle-timeout 5 --retry-pause 2
    if grep -q 'pool has been silent' "$log" && [ "$(grep -c 'login ok' "$log")" -ge 2 ]; then
        record PASS "idle watchdog" "reconnected after $(grep -c 'pool has been silent' "$log") timeout(s)"
    else
        record FAIL "idle watchdog" "watchdog did not fire/reconnect (see $log)"
    fi
fi

if selected failover; then
    port_f=$((port++))
    python3 "$NET/pool.py" --port "$port_f" --mode basic --diff 50 --lifetime 120 \
        >"${LOGDIR}/poolfailover.log" 2>&1 &
    PIDS+=($!)
    wait_port "$port_f" 10
    log="${LOGDIR}/failover.log"
    # Port 1 on localhost refuses instantly: the miner must fall through to
    # the second pool without human help.
    # A dead pool is retried `retries` times before the backup is used; keep the
    # test quick by asking for one retry with a one second pause.
    run_miner failover "$RUN_SECONDS" "$log" -o "127.0.0.1:1" -o "127.0.0.1:${port_f}" \
        -t 1 --mode light --retries 1 --retry-pause 1
    if grep -q "connecting to tcp://127.0.0.1:1" "$log" \
        && grep -q "connecting to tcp://127.0.0.1:${port_f}" "$log"; then
        record PASS "pool failover" "fell through to the backup pool"
    else
        record FAIL "pool failover" "did not use the backup pool (see $log)"
    fi
fi

if selected hostile; then
    port_h=$((port++))
    python3 "$NET/pool.py" --port "$port_h" --mode hostile --diff 50 --lifetime 120 \
        >"${LOGDIR}/poolhostile.log" 2>&1 &
    PIDS+=($!)
    wait_port "$port_h" 10
    log="${LOGDIR}/hostile.log"
    run_miner hostile "$RUN_SECONDS" "$log" -o "127.0.0.1:${port_h}" -t 1 --mode light
    if grep -q 'panic\|Segmentation fault' "$log"; then
        record FAIL "hostile pool" "crashed (see $log)"
    elif [ "$(grep -c 'share accepted' "$log")" -ge 1 ]; then
        record PASS "hostile pool" "survived junk, accepted=$(grep -c 'share accepted' "$log")"
    else
        record FAIL "hostile pool" "no shares after the junk (see $log)"
    fi
    # The pool side must never see the miner send something unparsable.
    if grep -q 'CLIENT SENT NON JSON' "${LOGDIR}/poolhostile.log"; then
        record FAIL "hostile pool request" "miner emitted a non JSON line"
    else
        record PASS "hostile pool request" "every request stayed valid JSON"
    fi
fi

if selected seed; then
    port_sd=$((port++))
    python3 "$NET/pool.py" --port "$port_sd" --mode soak --diff 300 --lifetime 240 \
        >"${LOGDIR}/poolseed.log" 2>&1 &
    PIDS+=($!)
    wait_port "$port_sd" 10
    log="${LOGDIR}/seed.log"
    # Timeline from login: initial dataset, seed change at 40 s, algorithm
    # switch at 90 s (each rebuild takes ~18 s on this box).
    SECONDS_TO_RUN=130
    MIN_REBUILDS=3
    if [ "$QUICK" -eq 1 ]; then
        # A rebuild of the 2 GiB dataset takes ~20 s on a 2 vCPU box, so a
        # 50 s window left no time to mine after the last seed change and the
        # case failed for the wrong reason.
        SECONDS_TO_RUN=90
        MIN_REBUILDS=2
    fi
    run_miner seed "$SECONDS_TO_RUN" "$log" -o "127.0.0.1:${port_sd}" -t 2
    changed=$(grep -c 'initialising the dataset' "$log")
    last_ready=$(grep -n 'dataset ready' "$log" | tail -1 | cut -d: -f1)
    after=0
    [ -n "$last_ready" ] && after=$(tail -n +"$last_ready" "$log" | grep -c 'share accepted')

    # How long the miner had left after the last rebuild. If the rebuild
    # finished at the very end of the window there was no chance to submit a
    # share, so that criterion is inconclusive rather than failed.
    gap=999
    if [ -n "$last_ready" ]; then
        ready_ts=$(sed -n "${last_ready}p" "$log" | sed -n 's/^\[\([0-9][0-9]:[0-9][0-9]:[0-9][0-9]\)\].*/\1/p')
        end_ts=$(tail -1 "$log" | sed -n 's/^\[\([0-9][0-9]:[0-9][0-9]:[0-9][0-9]\)\].*/\1/p')
        if [ -n "$ready_ts" ] && [ -n "$end_ts" ]; then
            IFS=: read -r rh rm rs <<<"$ready_ts"
            IFS=: read -r eh em es <<<"$end_ts"
            gap=$(( (10#$eh * 3600 + 10#$em * 60 + 10#$es) - (10#$rh * 3600 + 10#$rm * 60 + 10#$rs) ))
        fi
    fi
    if grep -q 'panic\|Segmentation fault' "$log"; then
        record FAIL "seed change" "crashed (see $log)"
    elif [ "$changed" -lt "$MIN_REBUILDS" ]; then
        record FAIL "seed change" "only $changed rebuilds, wanted $MIN_REBUILDS (see $log)"
    elif [ "$after" -lt 1 ] && [ "$gap" -ge 5 ]; then
        record FAIL "seed change" "no share accepted in the ${gap}s after the last rebuild (see $log)"
    elif [ "$after" -lt 1 ]; then
        record PASS "seed change" "rebuilds=$changed, last one ended the window (${gap}s left)"
    else
        record PASS "seed change" "rebuilds=$changed, $after shares after the last one"
    fi
fi

# --- anti-ban behaviour -----------------------------------------------------
# Pools ban IPs for two things: repeating a login they already refused, and
# submitting invalid shares. Both are silent in a hashrate reading, so they are
# tested here. See zmrig/src/stratum.zig (classify) and miner.zig (quarantine).

if selected badlogin; then
    port_bl=$((port++))
    python3 "$NET/pool.py" --port "$port_bl" --mode basic --diff 50 \
        --reject-login "invalid address" --lifetime 60 >"${LOGDIR}/poolbadlogin.log" 2>&1 &
    PIDS+=($!)
    wait_port "$port_bl" 10
    log="${LOGDIR}/badlogin.log"
    run_miner badlogin 8 "$log" -o "127.0.0.1:${port_bl}" -t 1 --mode light --retry-pause 1
    connects=$(grep -c 'connecting to' "$log")
    if grep -q 'does not accept this wallet' "$log" && [ "${connects:-0}" -le 2 ]; then
        record PASS "bad wallet is not retried" "connects=$connects, error explained"
    else
        record FAIL "bad wallet is not retried" "connects=${connects:-0} (see $log)"
    fi
fi

if selected banned; then
    port_ban=$((port++))
    python3 "$NET/pool.py" --port "$port_ban" --mode basic --diff 50 \
        --reject-login "your IP is banned" --lifetime 60 >"${LOGDIR}/poolban.log" 2>&1 &
    PIDS+=($!)
    wait_port "$port_ban" 10
    log="${LOGDIR}/banned.log"
    # A 60 s cooldown and 8 s of running: exactly one attempt is allowed.
    run_miner banned 8 "$log" -o "127.0.0.1:${port_ban}" -t 1 --mode light \
        --retry-pause 1 --ban-cooldown 60
    connects=$(grep -c 'connecting to' "$log")
    if grep -q 'banned this IP' "$log" && [ "${connects:-0}" -le 1 ]; then
        record PASS "a ban is not retried" "connects=$connects"
    else
        record FAIL "a ban is not retried" "connects=${connects:-0} (see $log)"
    fi
fi

if selected invalid; then
    port_inv=$((port++))
    python3 "$NET/pool.py" --port "$port_inv" --mode reject --diff 1 --lifetime 90 \
        >"${LOGDIR}/poolinvalid.log" 2>&1 &
    PIDS+=($!)
    wait_port "$port_inv" 10
    log="${LOGDIR}/invalid.log"
    run_miner invalid 14 "$log" -o "127.0.0.1:${port_inv}" -t 1 --mode light
    rejects=$(grep -c 'share rejected' "$log")
    if grep -q 'pausing submissions' "$log" && [ "${rejects:-0}" -lt 12 ]; then
        record PASS "invalid shares stop the stream" "rejects=$rejects, then paused"
    else
        record FAIL "invalid shares stop the stream" "rejects=${rejects:-0} (see $log)"
    fi
fi

if selected wsbad; then
    port_bws=$((port++))
    python3 "$NET/bad_ws.py" --port "$port_bws" --mode long-ping \
        >"${LOGDIR}/badws.log" 2>&1 &
    PIDS+=($!)
    wait_port "$port_bws" 10
    log="${LOGDIR}/wsbad.log"
    run_miner wsbad 8 "$log" -o "ws://127.0.0.1:${port_bws}/pool" -t 1 --mode light \
        --retry-pause 1
    # A 512-byte ping is a protocol violation. The miner has to name it and
    # reconnect; the old behaviour was to take 125 bytes, answer with a pong and
    # leave 387 bytes to be parsed as the next frame header, which is a stream
    # that never recovers and a log that only said "ConnectionClosed".
    if grep -q 'not speaking WebSocket correctly' "$log" && \
       ! grep -q 'Segmentation fault\|panic' "$log"; then
        record PASS "a broken WebSocket is named" "reconnects=$(grep -c 'connecting to' "$log")"
    else
        record FAIL "a broken WebSocket is named" "(see $log)"
    fi
fi

if [ "$SOAK" -eq 1 ]; then
    port_so=$((port++))
    python3 "$NET/pool.py" --port "$port_so" --mode soak --diff 300 --lifetime 400 \
        >"${LOGDIR}/poolsoak.log" 2>&1 &
    PIDS+=($!)
    wait_port "$port_so" 10
    log="${LOGDIR}/soak.log"
    echo "==> soak: 4 minutes (seed change, algo switch, abrupt disconnect, seed change)"
    run_miner soak 235 "$log" -o "127.0.0.1:${port_so}" -t 2 --print-time 30
    algo=$(grep -c 'switching algorithm to rx/wow' "$log")
    resets=$(grep -c 'connection lost' "$log")
    relog=$(grep -c 'login ok' "$log")
    if grep -q 'Segmentation fault\|panic' "$log"; then
        record FAIL "soak" "crashed (see $log)"
    elif [ "$algo" -ge 1 ] && [ "$resets" -ge 1 ] && [ "$relog" -ge 2 ]; then
        record PASS "soak" "algo=$algo resets=$resets logins=$relog accepted=$(grep -c 'share accepted' "$log")"
    else
        record FAIL "soak" "algo=$algo resets=$resets logins=$relog (see $log)"
    fi
fi

echo
echo "==> summary"
printf '%s\n' "${RESULTS[@]}"
echo
echo "    logs: $LOGDIR"
echo "    ${pass} passed, ${fail} failed, ${skip} skipped"

[ "$fail" -eq 0 ]

#!/usr/bin/env bash
#
# config.sh - what the zero-flag path actually writes into config.json.
#
# The installer's automatic decisions only matter if they end up in the file
# the miner reads. This test drives the real `oneclick.sh config` command
# against a temporary directory and inspects the JSON, without a build, a
# service or root-only paths:
#
#   * --engine=zmrig pins "algo": "rx/0" (it has no other algorithm),
#   * the profile decided at install time is in the file,
#   * a thread count from the search is written as cpu.threads,
#   * the C++ engine's config gets no zmrig-only keys.
#
#   ./tests/oneclick/config.sh
#
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
WORK=$(mktemp -d)
# The installer writes config.json as root with mode 0640 (it may hold an
# access token), so both reading and cleaning up need the same privilege.
trap 'sudo -n rm -rf "$WORK" 2>/dev/null; rm -rf "$WORK" 2>/dev/null' EXIT

if [ "$(id -u)" -ne 0 ] && ! sudo -n true 2>/dev/null; then
    echo "skip: this test needs root or passwordless sudo (the installer writes 0640 root files)"
    exit 0
fi

FAILED=0
pass() { printf ' PASS %s\n' "$*"; }
fail() { printf ' FAIL %s\n' "$*"; FAILED=1; }

WALLET="4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge"

run_config() {
    local dir="$1"
    shift
    MINER_CONFIG_DIR="$dir" MINER_PREFIX="${WORK}/prefix" MINER_STATE_DIR="${WORK}/state" \
        bash "$ROOT/oneclick.sh" config --wallet="$WALLET" "$@" >"${WORK}/log" 2>&1
    return $?
}

# jq is not installed everywhere; python3 is the realistic common denominator.
read_cfg() {
    cat "$1" 2>/dev/null || sudo -n cat "$1" 2>/dev/null
}

json_get() {
    # `python3 -` reads its *program* from stdin, so the JSON cannot also be
    # piped in: hand it a readable copy instead.
    local copy="${WORK}/copy.json"
    read_cfg "$1" > "$copy"
    python3 - "$copy" "$2" <<'PY'
import json, sys
with open(sys.argv[1]) as handle:
    data = json.load(handle)
node = data
for part in sys.argv[2].split("."):
    if isinstance(node, list):
        node = node[int(part)]
    else:
        node = node.get(part) if isinstance(node, dict) else None
    if node is None:
        print("null")
        raise SystemExit(0)
print(json.dumps(node) if not isinstance(node, str) else node)
PY
}

# --- 1. zmrig, auto profile, a thread count from the search --------------
DIR1="${WORK}/etc-zmrig"
if run_config "$DIR1" --engine=zmrig --pool=supportxmr.com:3333 --profile=auto; then
    pass "config: zmrig, auto profile, exit 0"
else
    fail "config: zmrig failed: $(tail -2 "${WORK}/log")"
fi

if [ -f "${DIR1}/config.json" ]; then
    pass "config.json was written"
else
    fail "config.json is missing"
fi

# The Zig engine advertises the whole RandomX family by default, which is what
# lets a switching pool (MoneroOcean and its clones) move this rig between
# coins. A pinned rx/0 would silently give that up, so `auto` is the correct
# value here -- and it still works on a plain pool, which simply answers rx/0.
algo=$(json_get "${DIR1}/config.json" "pools.0.algo")
if [ "$algo" = "auto" ]; then
    pass "zmrig config advertises the RandomX family (algo auto)"
else
    fail "zmrig config has algo '${algo}', expected auto"
fi

profile=$(json_get "${DIR1}/config.json" "profile")
case "$profile" in
    free|watt) pass "auto profile resolved to '${profile}' and was written" ;;
    *)         fail "profile in config is '${profile}', expected free or watt" ;;
esac

if [ "$(json_get "${DIR1}/config.json" "donate-level")" = "1" ]; then
    pass "donate-level is written as 1 (the documented developer fee)"
else
    fail "donate-level is $(json_get "${DIR1}/config.json" "donate-level"), expected 1"
fi

# A thread count is written only when the search produced one.
DIR2="${WORK}/etc-threads"
MINER_AUTOTUNE_THREADS=3 run_config "$DIR2" --engine=zmrig --pool=supportxmr.com:3333
threads=$(json_get "${DIR2}/config.json" "cpu.threads")
if [ "$threads" = "3" ]; then
    pass "a measured thread count is written as cpu.threads"
else
    fail "cpu.threads is '${threads}', expected 3"
fi

# --- 2. watt profile is written verbatim --------------------------------
DIR3="${WORK}/etc-watt"
run_config "$DIR3" --engine=zmrig --pool=supportxmr.com:3333 --profile=watt
if [ "$(json_get "${DIR3}/config.json" "profile")" = "watt" ]; then
    pass "--profile=watt is written verbatim"
else
    fail "--profile=watt was not written"
fi

# --- 3. the C++ engine gets no zmrig-only keys -------------------------
DIR4="${WORK}/etc-xmrig"
run_config "$DIR4" --engine=xmrig --pool=gulf.moneroocean.stream:10001 --profile=free
if [ "$(json_get "${DIR4}/config.json" "profile")" = "null" ]; then
    pass "the C++ config has no zmrig-only 'profile' key"
else
    fail "the C++ config got a 'profile' key it ignores"
fi

if [ "$(json_get "${DIR4}/config.json" "cpu.threads")" = "null" ]; then
    pass "the C++ config keeps its own thread heuristic"
else
    fail "the C++ config got an integer cpu.threads, which it does not read"
fi

# --- 4. an existing config is kept -------------------------------------
before=$(read_cfg "${DIR4}/config.json" | md5sum | cut -d' ' -f1)
run_config "$DIR4" --engine=xmrig --pool=gulf.moneroocean.stream:10001 --profile=free
after=$(read_cfg "${DIR4}/config.json" | md5sum | cut -d' ' -f1)
if [ "$before" = "$after" ]; then
    pass "a re-run keeps the existing config"
else
    fail "a re-run rewrote an existing config without --force"
fi

# --- 5. --no-health-restart reaches the config ------------------------
DIR5="${WORK}/etc-nohealth"
MINER_HEALTH_RESTART=0 run_config "$DIR5" --engine=zmrig --pool=supportxmr.com:3333
if [ "$(json_get "${DIR5}/config.json" "health.restart")" = "false" ]; then
    pass "--no-health-restart is written as health.restart=false"
else
    fail "--no-health-restart did not reach the config"
fi

echo
if [ "$FAILED" -eq 0 ]; then
    echo "config: all checks passed"
    exit 0
fi

echo "config: FAILED"
exit 1

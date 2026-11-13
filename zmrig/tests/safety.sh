#!/usr/bin/env bash
#
# safety.sh - run the hostile inputs against a binary built with the checks on.
#
#   ./zmrig/tests/safety.sh                      # builds a ReleaseSafe binary itself
#   ZMRIG_BIN=/tmp/safe/zmrig ./zmrig/tests/safety.sh
#   ./zmrig/tests/safety.sh --build-only
#
# Why a second build: the binary that ships is `-O ReleaseFast`, where a
# safety check is not a check. An out-of-range `@intCast` wraps or does something
# worse, and the difference between "wrapped quietly" and "undefined" is
# invisible until the same sources are compiled with the checks back on. This
# script builds that binary into a temporary directory (never over
# `zmrig/out/`, so it cannot cost you a rebuild of what you were measuring) and
# runs the inputs that a config file, a command line or a hostile pool can
# produce against it.
#
# What it has already found:
#   * `"log-file": "a\u0000b"` in a config file. A POSIX path cannot contain a
#     NUL, `createFile` on one is `unreachable` inside Zig's std, and the process
#     died with no output at all - now `error.InvalidPath` with a message.
#   * a WebSocket ping longer than the RFC allows, which was half-read.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
OUT="${SAFETY_OUT:-${TMPDIR:-/tmp}/zmrig-safe}"
BIN="${ZMRIG_BIN:-${OUT}/zmrig}"

cd "$ROOT" || exit 1

build() {
    echo "==> building ReleaseSafe into ${OUT}"
    OUT_DIR="$OUT" ZIG_OPT=ReleaseSafe bash "${ROOT}/zmrig/build.sh" --jobs "$(nproc 2>/dev/null || echo 2)" >/dev/null || {
        echo "build failed" >&2
        exit 1
    }
}

if [ "${1:-}" = "--build-only" ]; then
    build
    exit $?
fi

if [ "${ZMRIG_BIN:-}" = "" ]; then
    build
fi

[ -x "$BIN" ] || { echo "no binary at $BIN" >&2; exit 1; }

pass=0
fail=0
WORK=$(mktemp -d "${TMPDIR:-/tmp}/zmrig-safety.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# A crash means the shell saw a signal, or Zig printed its panic banner.
record() { # name ok detail
    if [ "$2" -eq 1 ]; then
        printf 'PASS %-34s %s\n' "$1" "$3"
        pass=$((pass + 1))
    else
        printf 'FAIL %-34s %s\n' "$1" "$3"
        fail=$((fail + 1))
    fi
}

crashed() { # logfile
    grep -q "panic\|Segmentation fault\|Illegal instruction\|reached unreachable" "$1" 2>/dev/null
}

# --- config files a parser has to survive ----------------------------------
cat > "$WORK/nul-path.json" <<'JSON'
{"pools":[{"url":"pool.example:3333","user":"x"}],"log-file":"logs/z\u0000mrig.log"}
JSON

cat > "$WORK/nul-ca.json" <<'JSON'
{"pools":[{"url":"pool.example:3333","user":"x"}],"tls-ca":"/etc/ssl/\u0000ca.pem"}
JSON

cat > "$WORK/shapes.json" <<'JSON'
{"pools":["pool.example:3333",{"url":null},{"url":""},{"user":"x"},
 {"url":"pool.example:3333","user":"x","cpu":{"threads":[0,1,70,90]}}],
 "cpu":{"threads":"8","priority":"high","affinity":-1},
 "randomx":{"mode":"quick","scratchpad_prefetch_mode":"two"},
 "http":{"enabled":true,"port":0,"access-token":""},
 "algo":"rx/01","profile":"turbo","dataset-cache":-1,"donate-level":1e9}
JSON

for cfg in nul-path nul-ca shapes; do
    "$BIN" --check -c "$WORK/${cfg}.json" >"$WORK/${cfg}.log" 2>&1
    rc=$?

    if crashed "$WORK/${cfg}.log"; then
        record "config: ${cfg}" 0 "crashed (rc=$rc)"
    elif [ "$rc" -gt 1 ]; then
        record "config: ${cfg}" 0 "exit $rc"
    else
        record "config: ${cfg}" 1 "rc=$rc"
    fi
done

# The two NUL cases have to be *refused*, not merely survived: silently carrying
# on would open a truncated path.
for cfg in nul-path nul-ca; do
    if grep -q "contains a NUL byte" "$WORK/${cfg}.log"; then
        record "config: ${cfg} is refused" 1 "named on stderr"
    else
        record "config: ${cfg} is refused" 0 "no refusal (see $WORK/${cfg}.log)"
    fi
done

# --- command lines ---------------------------------------------------------
WALLET="46SQLW7DXaq6GJaQbHUFMAhd1VYpfQFJQ2gfZo9TCB8bf9vnf1MUwAD2Fwj6KMsY4RU3oKA3x6hByg8BKg7FfMWn6ysb5tJ"
n=0
bad=0
while IFS= read -r args; do
    [ -z "$args" ] && continue
    n=$((n + 1))
    # shellcheck disable=SC2086
    eval "timeout 20 \"$BIN\" --check -o pool.example:3333 -u $WALLET $args" >"$WORK/cli.log" 2>&1
    rc=$?
    if [ "$rc" -ge 101 ] && [ "$rc" -ne 124 ] || crashed "$WORK/cli.log"; then
        printf 'CRASH rc=%s: %s\n' "$rc" "$args"
        tail -2 "$WORK/cli.log" | sed 's/^/    /'
        bad=$((bad + 1))
    fi
done <<'CASES'
--help
--version
-o "" -u ""
-o :
-o a:b:c:d
-o pool.example:65536
-o pool.example:-1
-o pool.example:0
-t 0
-t 129
-t -1
-t abc
-t 99999999999999999999
--scratchpad-prefetch=9
--scratchpad-prefetch=-5
--priority=0
--priority=99
--priority=-99
--proxy=ftp://x:1
--proxy=://
--proxy=not-a-proxy
--tls-ca=/nonexistent
--tls-ca=/dev/null
--cpu-affinity=0x0
--cpu-affinity=0xffffffffffffffff
--cpu-affinity=nonsense
--dataset-cache=999999999
--dataset-cache=-1
--donate-level=100
--donate-level=-1
--idle-timeout=0
--keepalive-interval=0
-c /nonexistent
-c /dev/null
-c /etc/passwd
--print-config
CASES

if [ "$bad" -eq 0 ]; then
    record "command lines" 1 "$n run, none crashed"
else
    record "command lines" 0 "$bad of $n crashed"
fi

echo
echo "    ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]

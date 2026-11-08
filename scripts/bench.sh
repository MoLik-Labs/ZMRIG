#!/usr/bin/env bash
#
# bench.sh - reproducible RandomX hashrate measurement.
#
#   ./scripts/bench.sh                       # 120s measurement with build/xmrig
#   ./scripts/bench.sh --seconds 300         # longer, more stable average
#   ./scripts/bench.sh --binary /tmp/xmrig   # measure a specific binary
#   ./scripts/bench.sh --threads 8           # override the thread hint
#   ./scripts/bench.sh --hashes 250K         # quarter-size window (faster, noisier)
#
# The miner runs the built in RandomX benchmark (offline, no pool needed), so the
# result only depends on the CPU, the memory setup and the build. Use identical
# conditions when comparing two builds or two hosts.
#
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${0}")/.." && pwd)
BINARY="${BENCH_BINARY:-${ROOT}/build/xmrig}"
SECONDS_TO_RUN=180
THREADS=""
HASHES=1M

color() { if [ -t 1 ]; then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi; }
info() { printf '%s %s\n' "$(color '1;36' '*')" "$*"; }
warn() { printf '%s %s\n' "$(color '1;33' '!')" "$*"; }
die()  { printf '%s %s\n' "$(color '1;31' 'x')" "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --seconds) SECONDS_TO_RUN="${2:?}"; shift ;;
        --seconds=*) SECONDS_TO_RUN="${1#*=}" ;;
        --binary) BINARY="${2:?}"; shift ;;
        --binary=*) BINARY="${1#*=}" ;;
        --threads) THREADS="${2:?}"; shift ;;
        --threads=*) THREADS="${1#*=}" ;;
        --hashes) HASHES="${2:?}"; shift ;;
        --hashes=*) HASHES="${1#*=}" ;;
        -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
    shift
done

[ -x "$BINARY" ] || die "binary not found: $BINARY (build it first or pass --binary)"

# BenchConfig::getSize only accepts 250K, 500K and 1M..10M in release builds.
case "${HASHES}" in
    250K|250k|500K|500k|[1-9]M|[1-9]m) ;;
    *) die "--hashes must be 250K, 500K or 1M..9M (got: ${HASHES})" ;;
esac

if [ "${SECONDS_TO_RUN}" -lt 40 ]; then
    warn "runs under 40 s are dominated by the ~20 s dataset init; use --seconds 180 for a real number"
fi

# A miner that is already running owns the huge pages, which silently degrades
# this measurement. Detect it instead of reporting a wrong number.
if pgrep -x xmrig >/dev/null 2>&1 || pgrep -x zmrig >/dev/null 2>&1 || pgrep -x xmrig-notls >/dev/null 2>&1; then
    warn "another miner process is running - stop it first or the huge pages are shared"
fi

huge_total=$(awk '$1 == "HugePages_Total:" { print $2 }' /proc/meminfo 2>/dev/null || echo 0)
thp=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo "n/a")
# Every page size this kernel can reserve, so the report says what it has
# instead of printing "0" for 1 GB pages on a kernel that has no such file.
page_sizes=$(ls /sys/kernel/mm/hugepages 2>/dev/null | sed 's/^hugepages-//; s/kB$//' | tr '\n' ' ' || true)
page_sizes=${page_sizes:-none}

info "binary:       $BINARY"
info "cpu threads:  $(nproc)"
info "huge pages:   ${huge_total:-0} reserved, THP: ${thp}"
info "page sizes:   ${page_sizes} (kB, supported by this kernel)"
info "1GB pages:    $(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages 2>/dev/null || echo 0) reserved"
info "run time:     ${SECONDS_TO_RUN}s (+ ~20s dataset init)"
echo

args=(--bench="${HASHES}" --print-time=10)
if [ -n "$THREADS" ]; then
    args+=(--cpu-max-threads-hint="$THREADS")
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

set +e
timeout --signal=TERM "${SECONDS_TO_RUN}" "$BINARY" "${args[@]}" >"$tmp" 2>&1
set -e

# Strip ANSI and keep both the 10s and the 60s hashrate columns. The 60s
# average only becomes available after a minute of mining, so short runs are
# scored on the 10s column.
parsed=$(sed 's/\x1b\[[0-9;]*m//g' "$tmp" \
    | grep -E 'speed 10s/60s/15m' \
    | awk '{ for (i = 1; i <= NF; ++i) if ($i == "10s/60s/15m") { print $(i + 1), $(i + 2); break } }' || true)

samples=$(printf '%s\n' "$parsed" | awk '$2 ~ /^[0-9]+\.?[0-9]*$/ { print $2 }')
column="60s"
if [ "$(printf '%s\n' "$samples" | grep -c . || true)" -lt 3 ]; then
    samples=$(printf '%s\n' "$parsed" | awk '$1 ~ /^[0-9]+\.?[0-9]*$/ { print $1 }')
    column="10s"
fi

init_ms=$(sed 's/\x1b\[[0-9;]*m//g' "$tmp" | grep -oE 'dataset ready \([0-9]+ ms\)' | grep -oE '[0-9]+' | head -1 || true)

if [ -z "$samples" ]; then
    warn "no hashrate samples collected, last log lines:"
    sed 's/\x1b\[[0-9;]*m//g' "$tmp" | tail -20
    exit 1
fi

threads=$(sed 's/\x1b\[[0-9;]*m//g' "$tmp" | grep -oE 'READY threads [0-9]+/[0-9]+' | grep -oE '[0-9]+/[0-9]+' | head -1 | cut -d/ -f1)

echo "$samples" | awk -v init="${init_ms:-n/a}" -v col="$column" -v threads="${threads:-0}" '
    { v[NR] = $1; sum += $1; if ($1 > max) max = $1 }
    END {
        n = NR
        # drop the first third: it still contains dataset warm-up effects
        start = int(n / 3) + 1
        s = 0; c = 0
        for (i = start; i <= n; ++i) { s += v[i]; c++ }
        printf "samples:      %d\n", n
        printf "%s average:  %.3f H/s (steady state, %d samples)\n", col, s / c, c
        printf "max:          %.3f H/s\n", max
        if (threads + 0 > 0) printf "per thread:   %.3f H/s (%d threads)\n", max / threads, threads
        printf "dataset init: %s ms\n", init
    }
'

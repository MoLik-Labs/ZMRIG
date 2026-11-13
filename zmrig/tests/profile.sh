#!/usr/bin/env bash
#
# profile.sh - measure where the time in one RandomX hash goes.
#
#   ./zmrig/tests/profile.sh              # 200 hashes per mode, rx/0
#   ./zmrig/tests/profile.sh 500          # more hashes, steadier numbers
#   ./zmrig/tests/profile.sh 200 6        # another algorithm (see xmo_algo)
#
# Builds a second copy of the hash engine with -DXMO_PROFILE into a temporary
# directory: the counters are preprocessor-removed from every other build, so
# the binary that ships is unaffected. That also means this never overwrites
# zmrig/out/libxmorx.a - a measurement must not cost you a rebuild.
#
# What the output is for: deciding what to optimise. On x86 the answer has been
# the same on every machine this was run on - the eight VM programs, whose cost
# is one random 64-byte read from the 2 GiB dataset per iteration, take ~94 % of
# a hash; the two 2 MiB AES passes take ~5 %, and everything else is noise. See
# doc/PERFORMANCE.md for the numbers and for what that rules out.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
HERE="${ROOT}/zmrig"
OUT="${PROFILE_OUT:-${TMPDIR:-/tmp}/zmrig-profile}"
ROUNDS=${1:-200}
ALGO=${2:-0}

cd "$ROOT" || exit 1

echo "==> building an instrumented engine in ${OUT}"
if ! OUT_DIR="$OUT" EXTRA_FLAGS="-DXMO_PROFILE" bash "${HERE}/build.sh" --no-zig --jobs "$(nproc 2>/dev/null || echo 2)" >/dev/null; then
    echo "build failed" >&2
    exit 1
fi

echo "==> compiling the profiler"
if ! g++ -std=c++11 -O2 -pthread -I "${HERE}/capi" \
        "${HERE}/tests/profile.cpp" "${OUT}/libxmorx.a" -o "${OUT}/profile"; then
    echo "compile failed" >&2
    exit 1
fi

echo "==> running ${ROUNDS} hashes per mode"
"${OUT}/profile" "$ROUNDS" "$ALGO"
ret=$?

# The one thing that is worth failing on: the phases have to look like phases.
# A breakdown where the VM is not the bulk of the hash means the counters are in
# the wrong place, and a wrong breakdown is worse than no breakdown.
if [ $ret -eq 0 ] && ! "${OUT}/profile" 20 "$ALGO" 2>/dev/null | awk '
    /8 VM programs/ { vm = $(NF - 1) + 0; seen = 1 }
    END { exit !(seen && vm >= 50) }'; then
    echo "the VM is not the bulk of the hash: the counters are misplaced" >&2
    exit 1
fi

exit $ret

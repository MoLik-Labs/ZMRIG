#!/usr/bin/env bash
#
# unit.sh - compile and run the zig unit tests inside zmrig.
#
#   ./zmrig/tests/unit.sh              # every module with tests
#   ./zmrig/tests/unit.sh job util     # only these
#   ZIG=/path/to/zig ./zmrig/tests/unit.sh
#
# `./zmrig/build.sh` only builds the binary: a test that stopped compiling (a
# changed signature, a renamed helper) stays invisible until someone runs this.
# The whole point of this script is that it runs every module, so a broken test
# is a failing build rather than a surprise three months later.
#
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
SRC="${ROOT}/zmrig/src"
ZIG="${ZIG:-zig}"

# Same resolver as the build: a newer Zig on PATH is not a usable Zig, and this
# suite would otherwise report a compiler error as a broken test.
if [ "$ZIG" = "zig" ]; then
    ZIG=$("${ROOT}/scripts/find-zig.sh") || { echo "no zig 0.13 (set ZIG=/path/to/zig)" >&2; exit 1; }
fi
command -v "$ZIG" >/dev/null 2>&1 || [ -x "$ZIG" ] || { echo "no zig at $ZIG" >&2; exit 1; }

MODULES=()
if [ "$#" -gt 0 ]; then
    MODULES=("$@")
else
    # Deterministic order keeps the output comparable between runs.
    while IFS= read -r file; do
        MODULES+=("$(basename "$file" .zig)")
    done < <(ls "${SRC}"/*.zig | sort)
fi

pass=0
fail=0
failed=()

for name in "${MODULES[@]}"; do
    file="${SRC}/${name}.zig"
    [ -f "$file" ] || { echo "!! no such module: ${name}" >&2; fail=$((fail + 1)); continue; }

    out=$(timeout 180 "$ZIG" test "$file" 2>&1)
    rc=$?

    if [ $rc -eq 0 ]; then
        tests=$(printf '%s\n' "$out" | grep -oE 'All [0-9]+ tests passed|[0-9]+ passed' | tail -1)
        printf '  PASS %-16s %s\n' "$name" "${tests:-ok}"
        pass=$((pass + 1))
    else
        printf '  FAIL %-16s\n' "$name"
        printf '%s\n' "$out" | sed 's/^/       /' | tail -8
        fail=$((fail + 1))
        failed+=("$name")
    fi
done

echo
if [ $fail -eq 0 ]; then
    echo "unit tests: ${pass} module(s) OK"
    exit 0
fi

echo "unit tests: ${pass} module(s) OK, ${fail} failed (${failed[*]})"
exit 1

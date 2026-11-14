#!/usr/bin/env bash
#
# find-zig.sh - print the path of a Zig 0.13 compiler, or exit 1.
#
# The miner is written against 0.13. Zig changes its standard library between
# releases in ways that break this code, so "a zig is installed" is not the
# question - "is 0.13 installed" is. That distinction cost a CI job: the Ubuntu
# runner ships a newer Zig on PATH, which looked like a satisfied dependency,
# and the static build then failed on code that had compiled here for months.
#
# Resolution order, first hit wins:
#
#   1. $ZIG, if set. Explicit beats clever; no version check, because whoever
#      set it knows what they set.
#   2. `zig` on PATH, if it reports 0.13.
#   3. the `ziglang` pip wheel, if it reports 0.13 (this is how a machine with
#      no package manager for Zig gets it: pip install ziglang==0.13.0).
#
# The path goes to stdout so callers can do ZIG=$(scripts/find-zig.sh). Every
# explanation goes to stderr, so that capture never picks up prose.
#
#   zig=$(scripts/find-zig.sh) || { echo "no zig 0.13" >&2; exit 1; }
#
# Something that is installed but the wrong version is reported, not ignored:
# a silent fallback from 0.14 to a wheel is how you end up wondering which
# compiler built the binary.

set -uo pipefail

WANT="${ZIG_WANT:-0.13}"

wanted_version() {
    # $1 = path or command name
    local v
    v=$("$1" version 2>/dev/null | head -1) || return 1
    case "$v" in
        "$WANT" | "$WANT".*) return 0 ;;
    esac
    return 1
}

describe() {
    local v
    v=$("$1" version 2>/dev/null | head -1)
    printf '%s\n' "${v:-unknown}"
}

if [ -n "${ZIG:-}" ]; then
    if command -v "$ZIG" >/dev/null 2>&1 || [ -x "$ZIG" ]; then
        printf '%s\n' "$ZIG"
        exit 0
    fi
    echo "ZIG=$ZIG is not executable" >&2
    exit 1
fi

if command -v zig >/dev/null 2>&1; then
    system_zig=$(command -v zig)
    if wanted_version "$system_zig"; then
        printf '%s\n' "$system_zig"
        exit 0
    fi
    echo "ignoring $system_zig: zig $(describe "$system_zig") is not $WANT" >&2
fi

if python3 -c "import ziglang" >/dev/null 2>&1; then
    pip_zig=$(python3 -c "import ziglang, os; print(os.path.join(os.path.dirname(ziglang.__file__), 'zig'))")
    [ -x "$pip_zig" ] || chmod +x "$pip_zig" 2>/dev/null || true
    if wanted_version "$pip_zig"; then
        printf '%s\n' "$pip_zig"
        exit 0
    fi
    echo "ignoring $pip_zig: zig $(describe "$pip_zig") is not $WANT" >&2
fi

echo "no zig $WANT found (set ZIG=/path/to/zig, or pip install ziglang==${WANT}.0)" >&2
exit 1

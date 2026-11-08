#!/usr/bin/env bash
# The tool is one place, and it says so on one page.
#
# `tool/README.md` is the index of everything a rig owner runs. This test keeps
# it true in the three directions that rot: a listed path that has moved, an
# entry point that no longer exists, and a new top-level script nobody indexed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

PAGE="tool/README.md"
fail=0

pass() { printf ' PASS %s\n' "$1"; }
bad() { printf ' FAIL %s\n' "$1"; fail=$((fail + 1)); }

[ -f "$PAGE" ] || { bad "$PAGE is missing"; exit 1; }

# The files a rig owner actually runs. Each must exist and be named on the page.
CORE="
oneclick.sh
os/overlay/usr/local/bin/zmrig-os
os/plan.sh
scripts/tune-linux.sh
deploy/docker/entry.js
deploy/docker/Dockerfile
os/build-iso.sh
"

for path in $CORE; do
    if [ ! -e "$path" ]; then
        bad "core entry point is gone: $path (fix the code, then $PAGE)"
    elif grep -qF "$path" "$PAGE"; then
        pass "entry point listed: $path"
    else
        bad "entry point is not on $PAGE: $path"
    fi
done

# Every path-shaped code span on the page must resolve.
while IFS= read -r token; do
    [ -n "$token" ] || continue
    case "$token" in
        *' '*|/*) continue ;;                 # prose, or an absolute path
        */*.*|*.*)                            # a name with a dot: only source files
            case "$token" in *.sh|*.js|Dockerfile) ;; *) continue ;; esac
            ;;

        */*|*.sh|*.js|Dockerfile) ;;
        *) continue ;;                        # a name, not a path
    esac
    if compgen -G "$token" >/dev/null 2>&1; then
        pass "reference resolves: $token"
    else
        bad "reference on $PAGE does not resolve: $token"
    fi
done < <(grep -o '`[^`]*`' "$PAGE" | tr -d '`' | sort -u)

# A new top-level script is a new surface; it does not get to appear unannounced.
for script in *.sh; do
    [ -f "$script" ] || continue
    if grep -qF "$script" "$PAGE"; then
        pass "top-level script is indexed: $script"
    else
        bad "top-level script is not on $PAGE: $script"
    fi
done

# And the suites the page points at have to exist.
for t in tests/oneclick os/tests deploy/docker/tests; do
    if compgen -G "$t/*" >/dev/null 2>&1; then
        pass "suite exists: $t"
    else
        bad "suite named on $PAGE does not exist: $t"
    fi
done

echo
if [ "$fail" -gt 0 ]; then
    echo "$fail problem(s): update $PAGE, or the code it points at"
    exit 1
fi
printf ' tool layout ok\n'

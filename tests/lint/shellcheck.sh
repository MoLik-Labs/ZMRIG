#!/usr/bin/env bash
#
# tests/lint/shellcheck.sh - every shell script, at warning severity.
#
# (This comment used to start with the tool's own name: to shellcheck 0.9 that reads
# as a directive, and it refuses to parse the file. Hence the path prefix.)
#
#   bash tests/lint/shellcheck.sh
#
# CI runs shellcheck on the scripts it ships. This runs it on all of them, which
# is the version a contributor needs: a warning in a helper that CI does not
# name is still a warning that hides the next real one. The dialect is taken
# from each file's shebang, because forcing POSIX on a bash script reports a
# hundred findings about arrays and none about anything true.
#
# `legacy/` is frozen and `web/` is generated, so neither is scanned. `.shellcheckrc`
# silences SC3043 (`local` under busybox ash) for the whole repository.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${0}")/../.." && pwd)
cd "$ROOT" || exit 1

if ! command -v shellcheck >/dev/null 2>&1; then
    printf 'shellcheck is not installed\n' >&2
    exit 2
fi

PASS=0
FAIL=0
bad=0

# Every tracked shell script, plus the extensionless ones this project ships as
# shell (the initramfs init and the appliance tool have no shebang suffix).
FILES=$(git ls-files '*.sh' 'os/init' 'os/overlay/usr/local/bin/zmrig-os' 'os/overlay/etc/init.d/zmrig-wifi' \
          'os/overlay/usr/local/lib/zmrig/firstboot.sh' \
          'os/overlay/etc/periodic/daily/zmrig-auto' 2>/dev/null |
        grep -v '^legacy/' | grep -v '^web/' | sort -u)

for f in $FILES; do
    [ -f "$f" ] || continue
    INTERPRETER=$(head -1 "$f")
    case "$INTERPRETER" in
        *bash*) DIALECT="bash" ;;
        *sh*)   DIALECT="sh" ;;
        *)      continue ;;   # not a script
    esac

    if OUT=$(shellcheck -s "$DIALECT" -S warning "$f" 2>&1); then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        bad=1
        printf '  FAIL  %s (%s dialect)\n' "$f" "$DIALECT"
        printf '%s\n' "$OUT" | sed -n '/^In /,$p' | sed 's/^/        /'
    fi
done

printf '\n    %s scripts clean, %s with findings\n\n' "$PASS" "$FAIL"
[ "$bad" = 0 ]

#!/usr/bin/env bash
#
# config-keys.sh - every setting the appliance has is written down.
#
# `os/overlay/etc/zmrig/os.conf.example` is the file an operator copies, and
# `doc/OS.md` is the table they read instead of reading the tool. Both drifted
# the same way: the example was missing seven keys the tool writes (the
# measurement, the affinity, the thermal cap) and the table was missing eight.
# A setting nobody can find is a setting nobody uses - and the ones that went
# missing here are exactly the performance ones.
#
# `os/tests/control.sh` asserts the example matches what the tool writes, by
# running the tool. This file asserts the documentation matches the example, by
# reading it: no bash, no root, no /proc, so it runs in the docs job in a second.
#
#   bash tests/docs/config-keys.sh
#
# Exit 0 when every key is documented, 1 otherwise.

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${0}")/../.." && pwd)
cd "$ROOT" || exit 2

EXAMPLE=os/overlay/etc/zmrig/os.conf.example
DOC=doc/OS.md

pass=0
fail=0

ok()  { pass=$((pass + 1)); printf ' PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf ' FAIL %s\n' "$1"; }

keys=$(sed -n 's/^\([A-Z][A-Z_0-9]*\)=.*/\1/p' "$EXAMPLE" 2>/dev/null)

# Only the configuration table, not every table in the file: doc/OS.md also has
# a manifest-field table with a `CHANNEL` row, and reading the first match found
# a row whose "default" was the literal word Manifest.
TABLE=$(mktemp)
trap 'rm -f "$TABLE"' EXIT
awk '/^## Configuration/{ inside = 1; next } inside && /^## /{ exit } inside' "$DOC" > "$TABLE"

if [ -z "$keys" ]; then
    bad "no keys found in $EXAMPLE"
    printf '\n    %d passed, %d failed\n' "$pass" "$fail"
    exit 1
fi

missing=""
for key in $keys; do
    # The table quotes every key in backticks; a bare mention in prose does not
    # count, because prose does not say what the default is.
    grep -qF -- "| \`$key\` |" "$TABLE" || missing="$missing $key"
done

if [ -z "$missing" ]; then
    ok "all $(printf '%s\n' "$keys" | wc -l | tr -d ' ') keys in $EXAMPLE are in the $DOC table"
else
    bad "$DOC does not document:$missing"
fi

# The example and the documentation must agree on the defaults as well, because
# a table that says 72 and a file that ships 85 is worse than nothing.
for key in $keys; do
    value=$(sed -n "s/^$key=\"\(.*\)\"/\1/p" "$EXAMPLE" | head -1)
    [ -n "$value" ] || continue
    # Only compare where the table states a value rather than an em dash.
    row=$(grep -F -- "| \`$key\` |" "$TABLE" | head -1)
    stated=$(printf '%s' "$row" | awk -F'|' '{ gsub(/^[ \t]+|[ \t]+$/, "", $3); print $3 }')
    case "$stated" in
        ''|'—'|'-') continue ;;
    esac
    stated=$(printf '%s' "$stated" | tr -d '`')
    if [ "$stated" = "$value" ]; then
        ok "$key's documented default ($value) matches the example"
    else
        bad "$key: the example ships \"$value\", the table says \"$stated\""
    fi
done

printf '\n    %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

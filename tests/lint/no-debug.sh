#!/usr/bin/env bash
#
# no-debug.sh - nothing shipped still talks to the person who wrote it.
#
#   bash tests/lint/no-debug.sh
#
# Debug leftovers are cheap to add and expensive to find: a `set -x` in a boot
# script writes the contents of every variable to a serial console nobody is
# watching, a `console.debug` in the fleet agent prints a wallet into a log, and
# a `TODO: handle this` marks a branch that returns the wrong answer quietly.
# None of them fail a test on their own, so this is the test.
#
# The scan covers the code this project writes. It does not cover `src/` (the
# upstream C++ miner, which has its own conventions), `legacy/` (frozen), or
# anything under a node_modules.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${0}")/../.." && pwd)
cd "$ROOT" || exit 1

PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*"; }

# What a leftover looks like, per language. Kept as one extended regex so a new
# pattern is one line and the failure message can quote the same thing.
PATTERN='(^|[^[:alnum:]_])(set -x|set -o xtrace|echo DEBUG|echo debug|printf .DEBUG|console\.debug|console\.trace|debugger;|dbg!\(|std\.debug\.print|TODO|FIXME|XXX: )'

# Files that legitimately contain the words: this one, and the docs that explain
# what a debug leftover costs.
ALLOW='^(tests/lint/no-debug\.sh|doc/|site/|README\.md|CHANGELOG\.md|legacy/|src/|node_modules/)'

# Directories this project actually writes.
DIRS='os zmrig/src zmrig/tests fleet/src fleet/tests serve pool scripts tests site/src site/plugins'

hits=$(find $DIRS -type f \
        \( -name '*.sh' -o -name '*.zig' -o -name '*.js' -o -name '*.mjs' -o -name '*.cjs' \) \
        2>/dev/null |
       grep -Ev "$ALLOW" |
       xargs -r grep -nE "$PATTERN" 2>/dev/null)

if [ -z "$hits" ]; then
    ok "no debug leftovers in the shipped scripts"
else
    bad "debug leftovers found"
    printf '%s\n' "$hits" | sed 's/^/        /'
fi

# A stray trace in a boot script is the worst of them: it runs as root, on a
# console, before anything can be turned off.
if grep -rlE '^\s*set -x' os/overlay os/*.sh 2>/dev/null | grep -q .; then
    bad "a boot script turns on tracing"
else
    ok "no boot script turns on tracing"
fi

# The appliance must never grow a debug port, a breakpoint or a "temporary"
# sleep that stays.
if grep -rnE 'sleep [0-9]+ *# *debug|--inspect|--debug-port' os/ serve/ fleet/src 2>/dev/null | grep -q .; then
    bad "a debug port or a temporary sleep is in the shipped code"
else
    ok "no debug port and no temporary sleep"
fi

printf '\n    %d passed, %d failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

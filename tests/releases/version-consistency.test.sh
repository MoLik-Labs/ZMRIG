#!/bin/sh
# Every file that carries the release number must carry the same one.
#
# This has gone wrong twice: a bump left the control tool at 6.47.0 while the
# miner said 6.48.0, and the fleet dashboard footer still said 6.44.0 long
# after. Both are the same bug - a number that lives in more than one file and
# is updated by hand - so it is worth one cheap test rather than another CI
# investigation six weeks later.
#
#   * zmrig/src/main.zig                     the miner, the authority
#   * package.json                           the site, the host, the fleet
#   * os/overlay/usr/local/bin/zmrig-os      the control tool
#   * fleet/src/version.js                   the fallback when only fleet/ ships

set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

fail=0
pass=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  BAD   %s\n' "$1"; }

miner=$(sed -n 's/^pub const version = "\(.*\)";$/\1/p' zmrig/src/main.zig | head -1)
pkg=$(sed -n 's/^  "version": "\([^"]*\)",$/\1/p' package.json | head -1)
tool=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' os/overlay/usr/local/bin/zmrig-os | head -1)
fallback=$(sed -n "s/^const FALLBACK = '\(.*\)';$/\1/p" fleet/src/version.js | head -1)

[ -n "$miner" ] && ok "the miner declares $miner" || bad "cannot read the version from zmrig/src/main.zig"

for pair in "package.json:$pkg" "the control tool:$tool" "the fleet fallback:$fallback"; do
    name=${pair%%:*}
    value=${pair#*:}
    if [ -z "$value" ]; then
        bad "cannot read the version from $name"
    elif [ "$value" = "$miner" ]; then
        ok "$name agrees on $miner"
    else
        bad "$name says $value, the miner says $miner"
    fi
done

# The changelog is the one place a version must appear, newest first, and a
# release that forgets it is a release nobody can read.
if grep -qE "^#{1,3} \[?${miner}([^0-9.]|$)" CHANGELOG.md 2>/dev/null; then
    ok "CHANGELOG.md has a section for $miner"
else
    bad "CHANGELOG.md has no section for $miner"
fi

printf 'version consistency: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

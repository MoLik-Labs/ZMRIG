#!/usr/bin/env bash
#
# latest-iso.test.sh - the download helper, against a fixture instead of GitHub.
#
#   ./tests/releases/latest-iso.test.sh
#
# The point is not that JSON parses; it is that the script can tell a stable
# release from a rolling beta, from the newest one from an older one, and that it
# refuses an architecture it does not publish rather than printing a link to
# nothing.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${0}")/../.." && pwd)
TOOL="${ROOT}/scripts/latest-iso.sh"
FIXTURE="${ROOT}/tests/releases/fixture.json"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*"; }
has() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

printf '\nlatest-iso tests\n\n'

if ! command -v node >/dev/null 2>&1; then
    printf '  SKIP  node is not installed\n\n'
    exit 0
fi

run() { ZMRIG_RELEASES_JSON="$FIXTURE" sh "$TOOL" "$@"; }

OUT=$(run)
has "v6.38.0" "$OUT" && ok "the newest stable release is picked" || bad "the newest stable release is picked"
has "zmrig-os-6.38.0-x86-64-v3.iso" "$OUT" && ok "the v3 image is listed" || bad "the v3 image is listed"
has "zmrig-os-6.38.0-x86-64-v2.iso" "$OUT" && ok "the v2 image is listed" || bad "the v2 image is listed"
has "example.test/old-v3.iso" "$OUT" && bad "an older release is not used" || ok "an older release is not used"
has "157.4 MB" "$OUT" && ok "the size comes from the release, not from a guess" || bad "the size comes from the release"
has "sudo dd if=" "$OUT" && ok "it prints the command to write a stick" || bad "it prints the command to write a stick"

OUT=$(run --arch v2)
has "x86-64-v2.iso" "$OUT" && ok "--arch v2 keeps the v2 image" || bad "--arch v2 keeps the v2 image"
has "x86-64-v3.iso" "$OUT" && bad "--arch v2 drops the v3 image" || ok "--arch v2 drops the v3 image"

OUT=$(run --arch x86-64-v3)
has "x86-64-v3.iso" "$OUT" && ok "--arch x86-64-v3 is accepted" || bad "--arch x86-64-v3 is accepted"

OUT=$(run --beta)
has "os-beta" "$OUT" && ok "--beta picks the rolling pre-release" || bad "--beta picks the rolling pre-release"
has "beta-v3.iso" "$OUT" && ok "and its own asset, not the stable one" || bad "and its own asset, not the stable one"
has "v6.38.0" "$OUT" && bad "the beta output is not the stable release" || ok "the beta output is not the stable release"

JSON=$(run --json)
node -e 'const d=JSON.parse(process.argv[1]); if(!d.tag||!Array.isArray(d.assets)||d.assets.length!==2) process.exit(1)' "$JSON" &&
    ok "--json is valid JSON with both images" || bad "--json is valid JSON with both images"
has '"channel": "stable"' "$JSON" && ok "--json names the channel" || bad "--json names the channel"

run --arch sparc >/dev/null 2>&1 && bad "an unknown architecture is refused" || ok "an unknown architecture is refused"
run --bogus >/dev/null 2>&1 && bad "an unknown option is refused" || ok "an unknown option is refused"

# A payload that is not a release list must not be read as one.
TMP=$(mktemp)
printf '{"message":"API rate limit exceeded"}\n' > "$TMP"
ZMRIG_RELEASES_JSON="$TMP" sh "$TOOL" >/dev/null 2>&1 && bad "a rate-limited answer is not an image list" || ok "a rate-limited answer is not an image list"
rm -f "$TMP"

printf '\n    %d passed, %d failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

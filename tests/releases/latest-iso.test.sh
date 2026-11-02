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
HOST_FIXTURE="${ROOT}/tests/releases/host-fixture.json"
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
run_host() { ZMRIG_RELEASES_JSON="$HOST_FIXTURE" sh "$TOOL" "$@"; }

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

# `--host`: ask a serve/ instance instead of api.github.com. The document it
# publishes is a different shape, and it carries the sha256 inline, so nothing
# here should try to download a checksum file.
OUT=$(run_host --host https://zmrig.example.com)
has "v6.38.0" "$OUT" && ok "--host reads the host's own feed" || bad "--host reads the host's own feed"
has "x86-64-v3.iso" "$OUT" && ok "--host lists the v3 image" || bad "--host lists the v3 image"
has "157.4 MB" "$OUT" && ok "--host keeps the size" || bad "--host keeps the size"
has "sha256  3f2a1c9d" "$OUT" && ok "--host prints the inline sha256" || bad "--host prints the inline sha256"
has "github.com/MoLik-Labs/ZMRIG/releases/download" "$OUT" && ok "--host still downloads from the release" || bad "--host keeps the release URL"

OUT=$(run_host --host=https://zmrig.example.com --arch v2)
has "x86-64-v2.iso" "$OUT" && ok "--host= and --arch work together" || bad "--host= and --arch work together"
has "x86-64-v3.iso" "$OUT" && bad "--host --arch v2 drops v3" || ok "--host --arch v2 drops v3"

JSON=$(run_host --from https://zmrig.example.com --json)
has '"page": "https://zmrig.example.com/download"' "$JSON" && ok "--json points at the host's download page" || bad "--json points at the host's download page"
node -e 'const d=JSON.parse(process.argv[1]); if(d.assets.length!==2||!d.assets[0].sha256) process.exit(1)' "$JSON" &&
    ok "--json carries the hash the host already knew" || bad "--json carries the hash the host already knew"

OUT=$(run_host --host https://zmrig.example.com --beta)
has "os-beta" "$OUT" && ok "--host --beta picks the rolling image" || bad "--host --beta picks the rolling image"

# A host that answers but has never reached GitHub: say what it said, do not
# claim nothing has been published.
TMP=$(mktemp)
printf '{"error":"could not reach GitHub (name lookup failed)","stable":null,"beta":null}\n' > "$TMP"
MSG=$(ZMRIG_RELEASES_JSON="$TMP" sh "$TOOL" --host https://zmrig.example.com 2>&1) && bad "a host with no feed is an error" || ok "a host with no feed is an error"
has "name lookup failed" "$MSG" && ok "and it repeats the reason the host gave" || bad "it repeats the reason the host gave"
rm -f "$TMP"

# A payload that is not a release list must not be read as one.
TMP=$(mktemp)
printf '{"message":"API rate limit exceeded"}\n' > "$TMP"
ZMRIG_RELEASES_JSON="$TMP" sh "$TOOL" >/dev/null 2>&1 && bad "a rate-limited answer is not an image list" || ok "a rate-limited answer is not an image list"
rm -f "$TMP"

printf '\n    %d passed, %d failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

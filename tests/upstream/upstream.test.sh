#!/usr/bin/env bash
#
# upstream.test.sh - os/upstream.sh against fixtures, not the internet.
#
#   ./tests/upstream/upstream.test.sh
#
# The script answers two questions that a release depends on: what the image is
# built from, and whether the Monday rebuild has anything to do. Both are string
# handling over documents somebody else controls, so both are tested with those
# documents recorded.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${0}")/../.." && pwd)
TOOL="${ROOT}/os/upstream.sh"
FIX="${ROOT}/tests/upstream"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*"; }
has() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

printf '\nupstream tests\n\n'

run() { # manifest, args...
    local manifest="$1"; shift
    ZMRIG_ALPINE_INDEX="$FIX/latest-releases.yaml" \
    ZMRIG_APK_INDEX="$FIX/apk-main.txt" \
    ZMRIG_RELEASES_JSON="$FIX/releases.json" \
    ZMRIG_PUBLISHED_MANIFEST="$manifest" \
    sh "$TOOL" "$@"
}

OUT=$(run "$FIX/manifest-new.json")
has "Alpine Linux 3.22.1" "$OUT" && ok "the Alpine point release is read from the index" ||
    bad "the Alpine point release is read from the index"
has "linux-lts 6.12.61" "$OUT" && ok "the kernel is the newest in the repository, not the oldest" ||
    bad "the kernel version is picked from the package index"
has "v6.38.0" "$OUT" && ok "the published stable release is reported" || bad "the published release is reported"
has "3.22.1" "$OUT" && ok "and the base that image was built on" || bad "the published base is reported"
has "os-beta (rolling beta)" "$OUT" && ok "the rolling beta is reported separately" ||
    bad "the rolling beta is reported separately"
has "rebuild: no" "$OUT" && ok "nothing upstream moved: no rebuild" || bad "the no-rebuild answer"

# The manifest of an older image says it was built on an older Alpine: that is
# the whole point of recording the base, and it is what the weekly job acts on.
OUT=$(run "$FIX/manifest-old.json")
has "rebuild: yes" "$OUT" && ok "an older Alpine in the published image means rebuild" ||
    bad "an older Alpine in the published image means rebuild"
has "3.22.1 replaces 3.21.3" "$OUT" && ok "and it names both versions" || bad "it names both versions"

run "$FIX/manifest-old.json" --check >/dev/null 2>&1 &&
    ok "--check exits 0 when a rebuild is warranted" || bad "--check exits 0 when a rebuild is warranted"
run "$FIX/manifest-new.json" --check >/dev/null 2>&1 &&
    bad "--check does not fire when nothing changed" || ok "--check does not fire when nothing changed"

MSG=$(run "$FIX/manifest-old.json" --check 2>&1)
has "3.22.1 replaces 3.21.3" "$MSG" && ok "--check prints the reason a workflow can log" ||
    bad "--check prints the reason"

# An image published before the manifest carried its base: rebuild once, then
# this branch is unreachable for ever. Answering "no" would freeze the image on
# whatever Alpine it was built on.
OUT=$(run "$FIX/manifest-legacy.json")
has "does not record its Alpine base" "$OUT" && ok "a manifest without a base triggers one rebuild" ||
    bad "a manifest without a base triggers one rebuild"

JSON=$(run "$FIX/manifest-new.json" --json)
node -e '
  const d = JSON.parse(process.argv[1]);
  if (d.alpine !== "3.22.1") throw new Error("alpine " + d.alpine);
  if (d.kernel !== "6.12.61") throw new Error("kernel " + d.kernel);
  if (d.rebuild !== false) throw new Error("rebuild should be false");
  if (d.published_stable !== "v6.38.0") throw new Error("stable " + d.published_stable);
' "$JSON" && ok "--json is what a workflow can parse" || bad "--json is what a workflow can parse"

JSON=$(run "$FIX/manifest-old.json" --json)
node -e '
  const d = JSON.parse(process.argv[1]);
  if (d.rebuild !== true) throw new Error("rebuild should be true");
  if (!/replaces/.test(d.reason)) throw new Error("reason " + d.reason);
' "$JSON" && ok "--json says why a rebuild is needed" || bad "--json says why a rebuild is needed"

# Offline: no index, no releases, no crash. A report that dies because the
# network is down is a report nobody can read on the machine that needs it.
OUT=$(ZMRIG_ALPINE_INDEX="$FIX/nothing-here" ZMRIG_RELEASES_JSON="$FIX/nothing-here" \
      sh "$TOOL" 2>&1)
has "cannot read the Alpine release index" "$OUT" && ok "an unreachable index is reported, not crashed on" ||
    bad "an unreachable index is reported"
has "unknown" "$OUT" && ok "and the unknown facts say unknown" || bad "the unknown facts say unknown"

ZMRIG_ALPINE_INDEX="$FIX/latest-releases.yaml" sh "$TOOL" --bogus >/dev/null 2>&1 &&
    bad "an unknown option is refused" || ok "an unknown option is refused"

printf '\n    %d passed, %d failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

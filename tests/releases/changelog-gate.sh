#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
CHECK="$ROOT/scripts/check-stable-release.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/zmrig/src"
printf 'pub const version = "6.48.0";\n' > "$WORK/zmrig/src/main.zig"
printf '# Unreleased — not a release\n' > "$WORK/CHANGELOG.md"

passed=0
failed=0
ok() { printf ' PASS %s\n' "$1"; passed=$((passed + 1)); }
bad() { printf ' FAIL %s\n' "$1"; failed=$((failed + 1)); }
expect_ok() {
    local name="$1"; shift
    if "$CHECK" "$@" "$WORK" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi
}
expect_fail() {
    local name="$1"; shift
    if "$CHECK" "$@" >/dev/null 2>&1; then bad "$name"; else ok "$name"; fi
}

expect_ok 'BETA remains a rolling prerelease while the changelog is Unreleased' refs/heads/BETA push stable
expect_fail 'master cannot publish an Unreleased changelog as stable' refs/heads/master push stable
expect_fail 'a stable version tag cannot publish an Unreleased changelog' refs/tags/v6.48.0 push stable
expect_fail 'stable tags must match the version compiled into the miner' refs/tags/v6.47.0 push stable
expect_fail 'an arbitrary branch cannot dispatch a stable release' refs/heads/ALPHA workflow_dispatch stable
expect_fail 'an arbitrary branch cannot dispatch a beta under the stable workflow' refs/heads/ALPHA workflow_dispatch beta
expect_ok 'pull-request validation does not need a release entry' refs/pull/82/merge pull_request stable

printf '# 6.48.0 — 2026-10-25\n' > "$WORK/CHANGELOG.md"
expect_ok 'master publishes only after a matching release section exists' refs/heads/master push stable
expect_ok 'the matching version tag publishes the stable image' refs/tags/v6.48.0 push stable
expect_fail 'a mismatched tag is still refused after the changelog is versioned' refs/tags/v6.47.0 push stable

if grep -Fq 'scripts/check-stable-release.sh' "$ROOT/.github/workflows/os.yml"; then
    ok 'the appliance publish job runs the stable-release gate'
else
    bad 'the appliance publish job runs the stable-release gate'
fi
if grep -Fq 'tests/releases/changelog-gate.sh' "$ROOT/.github/workflows/test.yml"; then
    ok 'CI runs the release-gate regression test'
else
    bad 'CI runs the release-gate regression test'
fi

printf '\n    %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]

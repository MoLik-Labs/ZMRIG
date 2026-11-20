#!/usr/bin/env bash
# Refuse to publish a stable ZMRIG OS release until the changelog is versioned.
# The BETA branch is intentionally a rolling pre-release; master and v* tags are
# stable channels. A manual dispatch may publish stable only from master or a
# version tag, never from an arbitrary feature branch.
set -euo pipefail

REF="${1:-${GITHUB_REF:-}}"
EVENT="${2:-${GITHUB_EVENT_NAME:-}}"
CHANNEL="${3:-${INPUTS_CHANNEL:-stable}}"
ROOT="${4:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"

case "$REF" in
  refs/heads/BETA)
    printf 'release gate: BETA is a rolling pre-release; stable changelog gate skipped\n'
    exit 0
    ;;
  refs/heads/master)
    ;;
  refs/tags/v*)
    ;;
  *)
    if [ "$EVENT" = "workflow_dispatch" ] && [ "$CHANNEL" = "beta" ]; then
      printf 'release gate: beta dispatch on %s is not the BETA rolling channel\n' "${REF:-unknown}" >&2
      exit 1
    fi
    if [ "$EVENT" = "workflow_dispatch" ] || [ "$EVENT" = "push" ]; then
      printf 'release gate: stable releases may publish only from master or a v* tag (got %s)\n' "${REF:-unknown}" >&2
      exit 1
    fi
    # Pull requests and scheduled non-release jobs do not publish stable assets.
    exit 0
    ;;
esac

VERSION=$(sed -n 's/^pub const version = "\([^"]*\)";.*/\1/p' "$ROOT/zmrig/src/main.zig" | head -1)
[ -n "$VERSION" ] || { echo "release gate: cannot read miner version" >&2; exit 1; }

if [[ "$REF" == refs/tags/* ]]; then
  expected="v${VERSION}"
  [ "${REF#refs/tags/}" = "$expected" ] || {
    printf 'release gate: tag %s does not match source version %s\n' "${REF#refs/tags/}" "$VERSION" >&2
    exit 1
  }
fi

heading=$(awk '/^# / { print; exit }' "$ROOT/CHANGELOG.md")
case "$heading" in
  "# ${VERSION}"|"# ${VERSION} "*|"# ${VERSION} —"*)
    printf 'release gate: %s is backed by changelog heading: %s\n' "$REF" "$heading"
    ;;
  *)
    printf 'release gate: refusing stable publish for %s; CHANGELOG.md starts with "%s", expected a released %s section\n' \
      "$REF" "${heading:-<no heading>}" "$VERSION" >&2
    exit 1
    ;;
esac

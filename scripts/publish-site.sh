#!/usr/bin/env bash
# Build the documentation site and put it in both places GitHub Pages reads.
#
# This repository has two Pages deployments pointing at the same URL, and which
# one finishes last decides what a visitor sees:
#
#   * "Deploy site" (.github/workflows/pages.yml) uploads `web/` as an artifact.
#   * "pages build and deployment" is GitHub's own build of the branch root,
#     because Settings → Pages → Source is still "Deploy from a branch".
#
# Neither can be changed without the `workflows`/Pages permission this tooling
# does not have, so both trees are generated from one build and `tests/docs/
# pages.sh` fails if they ever disagree. Once the Source is switched to "GitHub
# Actions", the root copy can go — see doc/SETUP.md §4a.
#
# `web/` is replaced whole; the root copy replaces only the paths Docusaurus
# owns, so nothing a human wrote in the repository root can be lost.
#
#   ./scripts/publish-site.sh            build and publish
#   ./scripts/publish-site.sh --check    fail if either copy is stale
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/site"

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

npm run build >/dev/null

# Docusaurus only writes this when it deploys with gh-pages itself.
touch build/.nojekyll

OWNED_FILES="index.html 404.html search.html search-index.json sitemap.xml robots.txt"
OWNED_DIRS="assets docs vi img"

if [ "$CHECK" = 1 ]; then
  STALE=""
  diff -rq build "$ROOT/web" >/dev/null 2>&1 || STALE="$STALE web/"
  for path in $OWNED_FILES; do
    cmp -s "build/$path" "$ROOT/$path" || STALE="$STALE $path"
  done
  for dir in $OWNED_DIRS; do
    diff -rq "build/$dir" "$ROOT/$dir" >/dev/null 2>&1 || STALE="$STALE $dir/"
  done
  if [ -n "$STALE" ]; then
    echo "the published site is stale:$STALE"
    echo "run ./scripts/publish-site.sh and commit the result"
    exit 1
  fi
  echo "the published site matches site/build"
  exit 0
fi

# 1. the artifact tree, replaced whole so no old asset can survive a deploy
rm -rf "$ROOT/web"
mkdir -p "$ROOT/web"
cp -a build/. "$ROOT/web/"

# 2. the branch-root tree, for the Pages build that reads the branch
for dir in $OWNED_DIRS; do
  rm -rf "$ROOT/$dir"
done
cp -a build/. "$ROOT/"

echo "published $(find build -type f | wc -l) files to web/ and the repository root"
echo "  https://molik-labs.github.io/ZMRIG/docs/intro"
echo "  https://molik-labs.github.io/ZMRIG/vi/docs/intro"

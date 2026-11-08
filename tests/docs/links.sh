#!/usr/bin/env bash
#
# links.sh - every relative link in the documentation points at a file.
#
# A dead link in a README is the cheapest possible way to look unfinished, and
# it is invisible until somebody clicks it. This walks every Markdown file at
# the top two levels, extracts the relative targets and checks them. Anchors are
# checked against the headings of the file they point into, so a renamed
# section fails here instead of on GitHub.
#
#   bash tests/docs/links.sh
#
# Exit code 0 when every link resolves, 1 otherwise.

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${0}")/../.." && pwd)
cd "$ROOT" || exit 2

pass=0
fail=0

ok()   { pass=$((pass + 1)); printf ' PASS %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf ' FAIL %s\n' "$1"; }

files=()
while IFS= read -r file; do files+=("$file"); done < <(
    find . -name node_modules -prune -o \
         \( -path './.git' -o -path './build' -o -path './zmrig/out' -o -path './src/3rdparty' \) -prune -o \
         -name '*.md' -print | sort
)

[ "${#files[@]}" -gt 0 ] || { echo "no Markdown files found" >&2; exit 2; }

# GitHub slugger: lowercase, drop punctuation, spaces to dashes.
#
# Docusaurus uses the same algorithm, and it keeps letters outside ASCII: the
# Vietnamese heading `## Chạy được chưa` has the anchor `#chạy-được-chưa`, which
# the old ASCII-only version of this function turned into `chy-c`. That made
# every non-English in-page link unverifiable, so python3 does the unicode part
# when it is available and the sed version stays as the fallback.
slug() {
    if command -v python3 >/dev/null 2>&1; then
        printf '%s' "$1" | python3 -c '
import re, sys
text = sys.stdin.read().lower()
text = re.sub(r"[`*_]", "", text)
text = re.sub(r"[^\w\- ]", "", text, flags=re.UNICODE)
text = re.sub(r"  +", " ", text)
print(re.sub(r" ", "-", text.strip()).strip("-"))'
        return
    fi
    printf '%s' "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -e 's/[`*_]//g' \
              -e 's/[^a-z0-9 -]//g' \
              -e 's/  */ /g' \
              -e 's/ /-/g' \
              -e 's/^-//' -e 's/-$//'
}

# The archived site renders its own Markdown (legacy/assets/md.js), and its
# slugger folds accents instead of keeping them: `## Cấu hình` becomes
# `#cau-hinh`. Those files are frozen, so a link that works there is correct
# even though GitHub would give it a different anchor.
legacy_slug() {
    printf '%s' "$1" | python3 -c '
import re, sys, unicodedata
text = sys.stdin.read().replace("đ", "d").replace("Đ", "D")
text = unicodedata.normalize("NFD", text)
text = "".join(c for c in text if not unicodedata.combining(c))
text = text.lower()
print(re.sub(r"[^a-z0-9]+", "-", text).strip("-")[:60])'
}

# Does this file have a heading whose slug is $2?
heading_exists() {
    local file="$1" anchor="$2" heading text fn=slug
    case "$file" in
        ./legacy/content/*|legacy/content/*) fn=legacy_slug ;;
    esac
    while IFS= read -r heading; do
        text=$(printf '%s' "$heading" | sed -e 's/^#* *//' -e 's/ *$//')
        [ "$("$fn" "$text")" = "$anchor" ] && return 0
    done < <(grep -E '^#{1,6} ' "$file" 2>/dev/null)
    return 1
}

# Markdown under legacy/content/ is not read from disk: docs.js renders it
# inside docs.html, so its relative links resolve against legacy/. Treat it that
# way here or every wizard link would look broken.
base_dir() {
    case "$1" in
        ./legacy/content/*) echo "./legacy" ;;
        *) echo "$(dirname "$1")" ;;
    esac
}

for file in "${files[@]}"; do
    dir=$(base_dir "$file")

    # Inline links and images: [text](target) / ![alt](target)
    while IFS= read -r target; do
        [ -z "$target" ] && continue
        case "$target" in
            http://*|https://*|mailto:*|*'{{'*) continue ;;
        esac

        # A same-page anchor (`[Did it work](#did-it-work)`) is a link too: the
        # heading it names has to exist in this file, or the reader lands at the
        # top of the page and thinks the documentation lied.
        case "$target" in
            '#'*)
                anchor=${target#\#}
                [ -z "$anchor" ] && continue
                case "$file" in
                    ./legacy/content/*|legacy/content/*)
                        # The archived site's renderer routes `#slug` to another
                        # document as well as to a heading, so a page slug is a
                        # valid anchor there. The manifest is the list of pages.
                        if heading_exists "$file" "$anchor" ||
                           grep -q "\"slug\": *\"$anchor\"" "$(dirname "$file")/index.json" 2>/dev/null; then
                            ok "$file -> #$anchor (legacy page or heading)"
                        else
                            bad "$file -> #$anchor (no such legacy page or heading)"
                        fi
                        ;;
                    *.md)
                        if heading_exists "$file" "$anchor"; then
                            ok "$file -> #$anchor"
                        else
                            bad "$file -> #$anchor (no such heading)"
                        fi
                        ;;
                esac
                continue
                ;;
        esac

        path=${target%%#*}
        anchor=""
        case "$target" in
            *'#'*) anchor=${target#*#} ;;
        esac

        # A site route (`/docs/pools/choosing`) is a Docusaurus page, not a file
        # relative to the Markdown it was written in. Resolve it against the
        # docs directory; the built site is checked by tests/docs/pages.sh.
        case "$path" in
            /docs/*)
                route=${path#/docs/}
                route=${route%/}
                if [ -f "site/docs/${route}.md" ] || [ -f "site/docs/${route}.mdx" ] \
                   || [ -f "site/docs/${route%/}/index.md" ]; then
                    ok "$file -> $path (site route)"
                else
                    bad "$file -> $path (no such page in site/docs)"
                fi
                continue
                ;;
            /*) continue ;;
        esac

        if [ -n "$path" ]; then
            # Strip a trailing query string, which only matters for site links.
            path=${path%%\?*}
            resolved="$dir/$path"
            if [ -e "$resolved" ]; then
                ok "$file -> $path"
            else
                bad "$file -> $path (missing)"
                continue
            fi
        else
            resolved="$file"
        fi

        if [ -n "$anchor" ] && [ -f "$resolved" ]; then
            case "$resolved" in
                *.md)
                    if heading_exists "$resolved" "$anchor"; then
                        ok "$file -> $path#$anchor"
                    else
                        bad "$file -> $path#$anchor (no such heading)"
                    fi
                    ;;
                *.html)
                    # docs.html is a shell: its anchors are slugs from the
                    # manifest, not ids in the markup.
                    if [ "$(basename "$resolved")" = "docs.html" ]; then
                        if grep -q "\"slug\": *\"$anchor\"" legacy/content/vi/index.json 2>/dev/null; then
                            ok "$file -> $path#$anchor"
                        else
                            bad "$file -> $path#$anchor (no such page in index.json)"
                        fi
                        continue
                    fi

                    if grep -q "id=\"$anchor\"" "$resolved" 2>/dev/null; then
                        ok "$file -> $path#$anchor"
                    else
                        bad "$file -> $path#$anchor (no such id)"
                    fi
                    ;;
            esac
        fi
    done < <(grep -oE '\]\([^)]+\)' "$file" 2>/dev/null | sed -e 's/^](//' -e 's/)$//' | sort -u)
done

printf '\n    %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

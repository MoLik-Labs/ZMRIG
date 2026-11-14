#!/usr/bin/env bash
#
# pages.sh - the published site as GitHub Pages will serve it.
#
# The documentation site is built with Docusaurus into `site/build` and copied
# into `web/` by `scripts/publish-site.sh`. `web/` is exactly what
# `.github/workflows/pages.yml` uploads as the Pages artifact, so these checks
# are the machine version of clicking through the published site.
#
#   bash tests/docs/pages.sh
#
# Exit code 0 when the published tree would survive Pages, 1 otherwise.

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${0}")/../.." && pwd)
cd "$ROOT/web" 2>/dev/null || {
    printf ' FAIL web/ does not exist; run ./scripts/publish-site.sh\n'
    exit 1
}

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf ' PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf ' FAIL %s\n' "$1"; }

# --- 1. the published entry point is the documentation site ----------------
if grep -q 'name="generator" content="Docusaurus' index.html 2>/dev/null; then
    ok "index.html is the Docusaurus build"
else
    bad "index.html is not the Docusaurus build (run ./scripts/publish-site.sh)"
fi

for file in index.html 404.html .nojekyll robots.txt; do
    [ -f "$file" ] && ok "present: ${file}" || bad "missing ${file}"
done

if grep -q 'name="generator" content="Docusaurus' 404.html 2>/dev/null; then
    ok "404.html is served by the site itself, not a redirect shim"
else
    bad "404.html is not the Docusaurus 404 page"
fi

# The hand-written site that used to live here is archived beside the build, not
# inside it: an archive that Pages uploads is a second copy of the truth.
[ -f "$ROOT/legacy/index.html" ] && ok "the previous static site is archived at legacy/, not deployed" \
    || bad "legacy/index.html disappeared"

# Old links keep working: /ZMRIG/wizard.html and /ZMRIG/docs.html are redirects
# into the documentation, so a bookmark from the previous site is not a 404.
for stub in wizard.html docs.html; do
    if [ -f "$stub" ] && grep -q 'url=/ZMRIG/docs/' "$stub"; then
        ok "${stub} redirects into the documentation"
    else
        bad "${stub} is missing or does not redirect"
    fi
done

# --- 2. every documented route exists in both locales ----------------------
ids=$(ZMRIG_SIDEBARS="$ROOT/site/sidebars.js" node -e '
const sidebars = require(process.env.ZMRIG_SIDEBARS);
const out = [];
(function walk(items) {
  for (const item of items) {
    if (typeof item === "string") out.push(item);
    else if (item && item.items) walk(item.items);
  }
})(sidebars.docs);
process.stdout.write(out.join("\n"));
' 2>/dev/null)

if [ -z "$ids" ]; then
    bad "could not read doc ids from site/sidebars.js"
else
    count=$(printf '%s\n' "$ids" | wc -l | tr -d ' ')
    ok "sidebar lists ${count} pages"
fi

missing=0
while IFS= read -r id; do
    [ -z "$id" ] && continue
    for base in docs vi/docs; do
        [ -f "${base}/${id}.html" ] \
            || { missing=$((missing + 1)); printf '      missing %s/%s.html\n' "$base" "$id"; }
    done
done <<< "$ids"
if [ "$missing" -eq 0 ]; then
    ok "every sidebar page is published in English and Vietnamese"
else
    bad "${missing} published page(s) missing"
fi

# --- 3. everything the pages ask the browser to load is on disk ------------
# Docusaurus writes `/ZMRIG/assets/...` because baseUrl is a project page, so a
# file that is present but referenced from the wrong base path is still a 404.
python3 - <<'PY' > /tmp/zmrig-assets-check.txt
import os, re, sys

ROOT = os.getcwd()
BASE = "/ZMRIG/"

def resolve(url):
    path = url.split("#")[0].split("?")[0]
    if not path.startswith(BASE):
        return True
    rel = path[len(BASE):]
    if rel in ("", "/"):
        return os.path.isfile(os.path.join(ROOT, "index.html"))
    candidates = [rel, rel + ".html", rel.rstrip("/") + "/index.html", rel + "/index.html"]
    return any(os.path.isfile(os.path.join(ROOT, c)) for c in candidates)

# Every published page, not a sample: a broken asset on page 19 is exactly as
# broken as one on the home page, and only this loop knows the difference.
pages = ["index.html", "404.html"]
for root, _dirs, files in os.walk("docs"):
    pages += [os.path.join(root, f) for f in files if f.endswith(".html")]
for root, _dirs, files in os.walk("vi"):
    pages += [os.path.join(root, f) for f in files if f.endswith(".html")]
bad = 0
checked = 0
for page in pages:
    if not os.path.isfile(page):
        print(f"missing page {page}")
        bad += 1
        continue
    html = open(page, encoding="utf-8").read()
    for attr, url in re.findall(r'(href|src)="([^"]+)"', html):
        if url.startswith(("http://", "https://", "//", "mailto:", "data:", "#")):
            continue
        checked += 1
        if not resolve(url):
            print(f"{page}: {url}")
            bad += 1
print(f"checked {checked} {bad}")
sys.exit(0 if bad == 0 else 1)
PY
result=$(tail -1 /tmp/zmrig-assets-check.txt)
checked=$(printf '%s' "$result" | awk '{print $2}')
broken=$(printf '%s' "$result" | awk '{print $3}')
if [ "${broken:-1}" = "0" ] && [ "${checked:-0}" -gt 50 ]; then
    ok "every local href/src in the published pages resolves (${checked} checked)"
else
    bad "${broken:-?} of ${checked:-?} local reference(s) broken, listed above"
    head -10 /tmp/zmrig-assets-check.txt | sed 's/^/      /'
fi

# --- 3b. every page is a finished page -------------------------------------
# The bugs a reader actually sees: a missing title in a tab, an empty share card,
# and a placeholder that leaked out of a template. Cheap to check, embarrassing
# to ship.
python3 - <<'PY2' > /tmp/zmrig-page-quality.txt
import os, re, sys

bad = 0
pages = []
for base in ("docs", "vi"):
    for root, _dirs, files in os.walk(base):
        pages += [os.path.join(root, f) for f in files if f.endswith(".html")]

TITLE = re.compile(r"<title[^>]*>(.*?)</title>", re.S)
DESC = re.compile(r'<meta[^>]+name="description"[^>]+content="([^"]*)"')
LEAKS = ("undefined", "NaN", "[object Object]", "{{", "}}", "lorem ipsum")
# Minified JavaScript is full of "}}" and "NaN"; only what a reader can see
# counts, so scripts and styles are removed before the scan.
NOISE = re.compile(r"<(script|style)\b[^>]*>.*?</\1>", re.S)

for page in pages:
    html = open(page, encoding="utf-8").read()
    title = TITLE.search(html)
    if not title or not title.group(1).strip():
        print(f"{page}: no title")
        bad += 1
    # A 404 and a noindex search page are not shareable, so they are not
    # expected to carry a description; everything a visitor can land on is.
    shareable = "noindex" not in html and not page.endswith("404.html")
    desc = DESC.search(html)
    if shareable and (not desc or len(desc.group(1).strip()) < 20):
        print(f"{page}: missing or thin description")
        bad += 1
    body = NOISE.sub("", html.split("<body", 1)[-1])
    for leak in LEAKS:
        if leak in body:
            print(f"{page}: leaked {leak!r}")
            bad += 1
            break
    # The two redirect stubs are language-neutral: they pick the destination
    # from the URL, so their own lang attribute is not a claim about content.
    stub = os.path.basename(page) in ("wizard.html", "docs.html")
    lang = "vi" if page.startswith("vi/") else "en"
    if not stub and f'<html lang="{lang}"' not in html:
        print(f"{page}: html lang is not {lang}")
        bad += 1

print(f"pages {len(pages)} bad {bad}")
sys.exit(0 if bad == 0 else 1)
PY2
quality=$(tail -1 /tmp/zmrig-page-quality.txt)
qpages=$(printf '%s' "$quality" | awk '{print $2}')
qbad=$(printf '%s' "$quality" | awk '{print $4}')
if [ "${qbad:-1}" = "0" ] && [ "${qpages:-0}" -ge 40 ]; then
    ok "all ${qpages} pages have a title, a description, the right lang and no leaked placeholder"
else
    bad "${qbad:-?} problem(s) across ${qpages:-?} pages, listed above"
    head -10 /tmp/zmrig-page-quality.txt | sed 's/^/      /'
fi

# --- 4. the sitemap advertises only pages that exist ----------------------
# `trailingSlash: false` means the URL has no `.html`, so the file on disk does.
sitemap_bad=0
sitemap_n=0
while IFS= read -r url; do
    sitemap_n=$((sitemap_n + 1))
    # Host-agnostic on purpose: the project moved from a user account to an
    # organisation once, and a test that hardcodes the host turns a rename into
    # a broken sitemap check instead of a broken sitemap.
    path=$(printf '%s' "$url" | sed 's|^https://[^/]*/ZMRIG/||')
    path=${path%%#*}
    path=${path%/}
    [ -z "$path" ] && path=index
    if [ ! -f "${path}.html" ] && [ ! -f "$path" ] && [ ! -f "$path/index.html" ]; then
        sitemap_bad=$((sitemap_bad + 1))
        printf '      sitemap advertises a missing page: %s\n' "$url"
    fi
done < <(grep -oE '<loc>[^<]+</loc>' sitemap.xml | sed -e 's|<loc>||' -e 's|</loc>||')
if [ "$sitemap_bad" -eq 0 ] && [ "$sitemap_n" -ge 20 ]; then
    ok "sitemap.xml advertises only pages that exist (${sitemap_n} entries)"
else
    bad "${sitemap_bad} sitemap entr(ies) broken (${sitemap_n} entries)"
fi

# Docusaurus writes one sitemap per locale, so the Vietnamese pages have their
# own file one directory down. Both have to exist.
# The file is written on one line, so count occurrences, not lines.
vi_sitemap=$(grep -o '<loc>' vi/sitemap.xml 2>/dev/null | wc -l | tr -d ' ')
if [ "${vi_sitemap:-0}" -ge 20 ] && grep -q '/vi/docs/' vi/sitemap.xml 2>/dev/null; then
    ok "vi/sitemap.xml advertises the Vietnamese pages (${vi_sitemap} entries)"
else
    bad "vi/sitemap.xml is missing or has too few entries"
fi

# --- 5. language and theme controls are on every page ---------------------
# Both are requirements, not decoration: English is the default and Vietnamese
# is a full translation, and the theme control has to offer system/light/dark.
switches=0
while IFS= read -r page; do
    # The labels are translated, so look for either spelling of "system".
    if grep -q 'zm-theme-switch' "$page" &&
       { grep -q 'title="System"' "$page" || grep -q 'title="Hệ thống"' "$page"; }; then
        switches=$((switches + 1))
    fi
done < <(find docs vi/docs -name '*.html' 2>/dev/null)
pages_with_switch=$(find docs vi/docs -name '*.html' 2>/dev/null | wc -l | tr -d ' ')
if [ "$switches" -eq "$pages_with_switch" ] && [ "$switches" -ge 40 ]; then
    ok "all ${switches} published pages carry the system/light/dark control"
else
    bad "only ${switches} of ${pages_with_switch} pages have the theme control"
fi

if grep -q 'navbar__link--active' docs/intro.html 2>/dev/null &&
   grep -q '<html lang="en"' docs/intro.html &&
   grep -q '<html lang="vi"' vi/docs/intro.html; then
    ok "English pages declare lang=en, Vietnamese pages declare lang=vi"
else
    bad "the locale attribute is wrong on one of the intro pages"
fi

if grep -qE 'switch-language|localeDropdown|language' docs/intro.html 2>/dev/null; then
    ok "the navbar has a language switch"
else
    bad "no language switch in the navbar"
fi

# --- 6. search is wired: DocSearch or the local index ---------------------
if grep -q 'algolia' docs/intro.html 2>/dev/null; then
    ok "search: Algolia DocSearch is mounted"
elif [ -f search-index.json ] && [ -f search.html ]; then
    ok "search: local index built (search-index.json + search.html)"
else
    bad "no search is published (no DocSearch, no local index)"
fi

# --- 7. every page advertises exactly one social card, in its own language --
# A duplicate og:image is what happens when a theme-wide default is left in
# place next to a per-page one; crawlers take whichever comes first, and the
# Vietnamese tree used to hand them the English card.
social_bad=0
social_n=0
while IFS= read -r page; do
    case "$page" in *search.html|*404.html) continue ;; esac
    social_n=$((social_n + 1))
    opens=$(grep -o 'property="og:image"' "$page" | wc -l | tr -d ' ')
    tweets=$(grep -o 'name="twitter:image"' "$page" | wc -l | tr -d ' ')
    wanted="img/og-en.png"
    case "$page" in vi/*) wanted="img/og-vi.png" ;; esac
    if [ "$opens" -ne 1 ] || [ "$tweets" -ne 1 ] || ! grep -q "og:image\" content=\"[^\"]*/$wanted\"" "$page"; then
        social_bad=$((social_bad + 1))
        printf '      %s: og:image x%s, twitter:image x%s, expected %s\n' \
            "$page" "$opens" "$tweets" "$wanted"
    fi
done < <(find docs vi/docs -name '*.html' 2>/dev/null; echo index.html; echo vi/index.html)
if [ "$social_bad" -eq 0 ] && [ "$social_n" -ge 40 ]; then
    ok "all ${social_n} pages carry one localised social card"
else
    bad "${social_bad} page(s) with a missing, duplicated or wrong-language card"
fi

# --- 8. the committed copy is the current build ---------------------------
stale=0
for file in index.html 404.html sitemap.xml docs/intro.html vi/docs/intro.html \
            docs/economics/profitability.html; do
    if [ -f "$ROOT/site/build/$file" ]; then
        cmp -s "$ROOT/site/build/$file" "$file" || { stale=$((stale + 1)); printf '      stale: %s\n' "$file"; }
    fi
done
if [ "$stale" -eq 0 ]; then
    ok "the published copy matches site/build"
else
    bad "${stale} published file(s) differ from site/build; run ./scripts/publish-site.sh"
fi

# --- 9. the old product name is gone from the published pages -------------
# The installer page documents the migration from the pre-6.32.0 name on
# purpose, so it is the one page allowed to say it.
# Only HTML pages are checked: the search index and the JS bundles legitimately
# carry the text of the installer page, which documents the migration.
stale_name=$(find docs vi/docs -name '*.html' -print0 2>/dev/null \
    | xargs -0 grep -l "xmrig-ocean" 2>/dev/null \
    | grep -v 'install/installer' | head -3)
if [ -z "$stale_name" ]; then
    ok "no published page mentions the pre-6.32.0 name"
else
    bad "the old product name is still published: ${stale_name}"
fi

printf '\n    %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

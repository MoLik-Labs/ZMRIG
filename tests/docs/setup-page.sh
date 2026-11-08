#!/usr/bin/env bash
#
# setup-page.sh - the setup guide only names things that exist.
#
# The setup page is the first page a new rig owner reads, and it is the one page
# nobody on the project rereads: a renamed `zmrig-os` subcommand, a flag that
# was never added to `oneclick.sh`, an image tag that changed - all of it reads
# perfectly and all of it fails in the reader's terminal instead of here. The
# Vietnamese twin makes that worse, because the prose around the wrong command
# is the part that gets reviewed.
#
# So both locales are parsed the way a reader uses them:
#
#   * every `zmrig-os <command>` is a command its dispatcher knows;
#   * every `zmrig <flag>` appears in the binary's own usage text;
#   * every `oneclick.sh <subcommand>` is dispatched, and `--help` lists it;
#   * every `<image> <command>` is handled by the container's shim;
#   * every percentage about the fee equals `fee.default_percent`;
#   * the page is in the sidebar, in the locale test, and linked from the
#     quickstart in both languages, so it is reachable at all.
#
#   bash tests/docs/setup-page.sh
#
# Exit code 0 when both pages name only real things, 1 otherwise.

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${0}")/../.." && pwd)
cd "$ROOT" || exit 2

EN="site/docs/install/setup.md"
VI="site/i18n/vi/docusaurus-plugin-content-docs/current/install/setup.md"
OS_TOOL="os/overlay/usr/local/bin/zmrig-os"

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf ' PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf ' FAIL %s\n' "$1"; }

for file in "$EN" "$VI" "$OS_TOOL"; do
    [ -f "$file" ] || { echo "missing $file" >&2; exit 2; }
done

# Both locales, one loop, so a page added to one and not the other shows up as a
# failure rather than as an English page served at a Vietnamese URL.
check_page() {
    local page="$1" label="$2" unknown

    # --- zmrig-os -----------------------------------------------------------
    local os_commands
    os_commands=$(sed -n '/^main() {/,/^}/p' "$OS_TOOL" |
                  sed -n 's/^ *\([a-z|][a-z0-9|-]*\)) *cmd_[a-z_]*.*/\1/p' |
                  tr '|' '\n')
    unknown=""
    while IFS= read -r command; do
        case "$command" in ''|help|version|-h|--help|-V|--version) continue ;; esac
        printf '%s\n' "$os_commands" | grep -qx -- "$command" || unknown="$unknown $command"
    done < <(grep -oE 'zmrig-os [a-z][a-z-]*' "$page" | sed 's/.*zmrig-os //' | sort -u)
    if [ -z "$unknown" ]; then
        ok "$label: every zmrig-os command is dispatched"
    else
        bad "$label: zmrig-os commands that do not exist:$unknown"
    fi

    # --- zmrig flags --------------------------------------------------------
    local flags
    flags=$(sed -n '/pub const usage =/,/^;/p' zmrig/src/options.zig)
    unknown=""
    while IFS= read -r flag; do
        printf '%s' "$flags" | grep -q -- "$flag" || unknown="$unknown $flag"
    done < <(
        # `docker run --name zmrig --restart` is a container flag on a container
        # called zmrig, not a flag of the miner.
        grep -vE 'docker (run|create)|--name zmrig' "$page" |
        grep -oE '\bzmrig (-[a-z]|--[a-z][a-z-]*)' |
        sed 's/^zmrig //' | sed 's/=.*//' | sort -u
    )
    if [ -z "$unknown" ]; then
        ok "$label: every zmrig flag is in the binary's usage"
    else
        bad "$label: zmrig flags the binary does not have:$unknown"
    fi

    # --- oneclick.sh --------------------------------------------------------
    local subcommands
    subcommands=$(sed -n '/^# Subcommands/,/^# *$/p' oneclick.sh |
                  sed -n 's/^#   \([a-z][a-z|-]*\).*/\1/p' | tr '|' '\n')
    unknown=""
    while IFS= read -r command; do
        case "$command" in ''|'--'*) continue ;; esac
        printf '%s\n' "$subcommands" | grep -qx -- "$command" || unknown="$unknown $command"
    done < <(grep -oE 'oneclick\.sh [a-z][a-z-]*' "$page" | sed 's/oneclick\.sh //' | sort -u)
    if [ -z "$unknown" ]; then
        ok "$label: every oneclick.sh subcommand exists"
    else
        bad "$label: oneclick.sh subcommands that do not exist:$unknown"
    fi

    unknown=""
    while IFS= read -r flag; do
        grep -q -- "$flag)" oneclick.sh || grep -q -- "$flag|" oneclick.sh ||
            unknown="$unknown $flag"
    done < <(grep -oE 'oneclick\.sh (--[a-z][a-z-]*)' "$page" | sed 's/oneclick\.sh //' | sort -u)
    if [ -z "$unknown" ]; then
        ok "$label: every oneclick.sh option is parsed by the installer"
    else
        bad "$label: oneclick.sh options the installer does not accept:$unknown"
    fi

    # --- the container ------------------------------------------------------
    local shim
    shim=$(sed -n '/function plan(/,/^}/p' deploy/docker/entry.js)
    unknown=""
    while IFS= read -r command; do
        printf '%s' "$shim" | grep -q "case '$command'" || unknown="$unknown $command"
    done < <(grep -oE 'ghcr\.io/[a-z-]+/zmrig( [a-z][a-z-]*)?' "$page" |
             sed 's#.*zmrig *##' | grep -v '^$' | sort -u)
    if [ -z "$unknown" ]; then
        ok "$label: every container command is handled by the shim"
    else
        bad "$label: container commands the shim does not handle:$unknown"
    fi

    # --- the fee ------------------------------------------------------------
    local percent wrong
    percent=$(grep -E '^pub const default_percent' zmrig/src/fee.zig |
              sed 's/.*= *//; s/;.*//' | grep -oE '^[0-9]+')
    wrong=""
    while IFS= read -r number; do
        [ "$number" = "$percent" ] || wrong="$wrong $number"
    # -i: "Phí 3 %" starts a section heading, and the capital P is exactly the
    # spelling a hand-written sentence uses.
    done < <(grep -oiE '(phí|thời gian|fee of) ?[0-9]+ ?%' "$page" | grep -oE '[0-9]+' | sort -u)
    if [ -z "$wrong" ]; then
        ok "$label: the fee it quotes is the source (${percent} %)"
    else
        bad "$label: states${wrong} % where the source says ${percent} %"
    fi
}

check_page "$EN" "en"
check_page "$VI" "vi"

# --- the pages are twins ----------------------------------------------------
en_id=$(grep -c '' "$EN")
vi_id=$(grep -c '' "$VI")
if [ "$en_id" -gt 20 ] && [ "$vi_id" -gt 20 ]; then
    ok "both locales exist and have content (${en_id} / ${vi_id} lines)"
else
    bad "one locale is a stub (${en_id} / ${vi_id} lines)"
fi

# Same headings, so the two locales cannot answer different questions.
en_heads=$(grep -c '^## ' "$EN")
vi_heads=$(grep -c '^## ' "$VI")
if [ "$en_heads" = "$vi_heads" ]; then
    ok "both locales have the same number of sections (${en_heads})"
else
    bad "the Vietnamese page has ${vi_heads} sections against ${en_heads} in English"
fi

# --- it is in the navigation and in the locale test -------------------------
if grep -q '"install/setup"' site/sidebars.js; then
    ok "the sidebar lists install/setup"
else
    bad "install/setup is not in sidebars.js: the page would be invisible"
fi

if grep -q '"install/setup.md"' site/tests/i18n.test.mjs; then
    ok "the locale test expects install/setup.md in both trees"
else
    bad "site/tests/i18n.test.mjs does not list install/setup.md"
fi

# --- and the quickstart sends the reader here ------------------------------
for page in site/docs/install/quickstart.md \
            site/i18n/vi/docusaurus-plugin-content-docs/current/install/quickstart.md; do
    if grep -q '/docs/install/setup' "$page"; then
        ok "$(dirname "$page" | sed 's#.*/##')/quickstart links to the setup page"
    else
        bad "$page does not link to /docs/install/setup"
    fi
done

# --- oneclick.sh --help lists what it dispatches ---------------------------
#
# `plan` and `purge` were implemented and missing from the help, which is the
# only place a reader finds them; the header is the help, so the two have to
# agree or the guide is describing a command nobody can discover.
help=$(bash oneclick.sh --help 2>&1)
dispatched=$(sed -n 's/^ *\(install|build|tune|config|start|stop|restart|status|logs|bench|report|verify|update|uninstall|purge|plan\)).*/\1/p' oneclick.sh |
             tr '|' '\n' | sort -u)
missing_help=""
for command in $dispatched; do
    printf '%s' "$help" | grep -qE "^  ($command)([ |]|$)" ||
        printf '%s' "$help" | grep -q "|$command" ||
        missing_help="$missing_help $command"
done
if [ -z "$missing_help" ]; then
    ok "--help lists every subcommand the installer dispatches"
else
    bad "--help does not list:$missing_help"
fi

printf '\n    %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

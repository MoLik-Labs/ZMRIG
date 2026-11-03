#!/bin/sh
# upstream.sh - what this image is built from, and whether it is still the newest.
#
#   ./os/upstream.sh                 # what the pins resolve to today
#   ./os/upstream.sh --check         # exit 0 when a rebuild would pick up something newer
#   ./os/upstream.sh --json          # the same, for a workflow
#   ./os/upstream.sh --published     # what the last published beta image was built from
#
# The image is Alpine `latest-stable` plus the `linux-lts` package, and both move
# without telling anybody: a point release lands, a kernel gets a CVE fix, and a
# stick built last month is quietly older than the one a new user downloads. A
# weekly CI run therefore asks this script whether a rebuild would produce a
# different image, and only builds when the answer is yes.
#
# Network is needed for the live answer and nothing else. A mirror can be pointed
# somewhere else (`--mirror`), including a directory, which is how the test suite
# exercises the parsing without asking dl-cdn for anything.
#
# shellcheck shell=sh disable=SC3043

set -eu

ROOT=$(cd -- "$(dirname -- "$0")/.." 2>/dev/null; pwd)
MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"
REPO="${GITHUB_REPOSITORY:-MoLik-Labs/ZMRIG}"
MODE="report"

say() { printf '%s\n' "$*"; }
die() { printf '%s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --check)     MODE="check" ;;
        --json)      MODE="json" ;;
        --published) MODE="published" ;;
        --mirror)    MIRROR="${2:?}"; shift ;;
        --mirror=*)  MIRROR="${1#*=}" ;;
        -h|--help)   usage ;;
        *)           die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

# The pins live in build-iso.sh, because that is the file that has to keep
# working when somebody builds an image by hand. Reading them from there means
# this script cannot drift from the build.
pin() { # variable name -> its default in build-iso.sh
    sed -n "s/^$1=\"\${$1:-\\(.*\\)}\"\$/\\1/p" "${ROOT}/os/build-iso.sh" | head -1
}

ALPINE_PIN=$(pin ALPINE_VER)
KERNEL_PIN=$(pin KERNEL_PKG)
[ -n "$ALPINE_PIN" ] || die "cannot read ALPINE_VER from os/build-iso.sh"
[ -n "$KERNEL_PIN" ] || die "cannot read KERNEL_PKG from os/build-iso.sh"

# urllib is not on the image, but this script only ever runs on a build host or
# in CI, both of which have curl or wget.
fetch() { # url -> stdout
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 60 "$1" 2>/dev/null
    else
        wget -q -T 60 -O - "$1" 2>/dev/null
    fi
}

fetch_to() { # url, file
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 60 -o "$2" "$1" 2>/dev/null
    else
        wget -q -T 60 -O "$2" "$1" 2>/dev/null
    fi
}

# `latest-stable` is a symlink to v3.NN in the mirror layout, so the number is
# only in the release listing.
resolve_alpine() { # -> 3.NN or empty
    case "$ALPINE_PIN" in
        v*|latest-stable) ;;
        *) printf '%s' "$ALPINE_PIN"; return 0 ;;
    esac

    listing=$(fetch "${MIRROR}/${ALPINE_PIN}/releases/x86_64/latest-releases.yaml") || return 0
    #  version: 3.22.2      (the newest release block wins; the file is ordered
    #  file: alpine-minirootfs-3.22.2-x86_64.tar.gz
    printf '%s\n' "$listing" \
        | sed -n 's/^[ -]*version: *\([0-9][0-9.]*\)$/\1/p' \
        | sort -t. -k1,1n -k2,2n -k3,3n \
        | tail -1
}

# The kernel package version lives in the APKINDEX, which is a tar.gz of a text
# file whose entries look like:
#   P:linux-lts
#   V:6.12.31-r0
resolve_kernel() { # -> 6.12.31-r0 or empty
    # To a file, not to a variable: a gzip stream contains NUL bytes, and a shell
    # that quietly drops those turns a valid archive into a mangled one.
    index=$(mktemp 2>/dev/null) || return 0
    if ! fetch_to "${MIRROR}/${ALPINE_PIN}/main/x86_64/APKINDEX.tar.gz" "$index"; then
        rm -f "$index"
        return 0
    fi
    # APKINDEX is CRLF, which turns every comparison into a near miss.
    tar -xzO -f "$index" APKINDEX 2>/dev/null | tr -d '\r' | awk -v pkg="$KERNEL_PIN" '
        $0 == "P:" pkg { found = 1; next }
        found && /^V:/ { print substr($0, 3); exit }
        /^$/ { found = 0 }
    '
    rm -f "$index"
}

published() { # -> "version alpine kernel" from the rolling beta manifest
    # Overridable so the test suite can hand it a fixture instead of asking
    # GitHub for a release that a pull request has not published yet.
    url="${ZMRIG_OS_PUBLISHED_URL:-https://github.com/${REPO}/releases/download/os-beta/zmrig-os-beta-x86-64-v3.json}"
    body=$(fetch "$url") || return 0
    version=$(printf '%s' "$body" | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' | head -1)
    alpine=$(printf '%s' "$body" | sed -n 's/.*"alpine": *"\([^"]*\)".*/\1/p' | head -1)
    kernel=$(printf '%s' "$body" | sed -n 's/.*"kernel_version": *"\([^"]*\)".*/\1/p' | head -1)
    printf '%s %s %s' "${version:-unknown}" "${alpine:-unknown}" "${kernel:-unknown}"
}

UPSTREAM_ALPINE=$(resolve_alpine)
UPSTREAM_KERNEL=$(resolve_kernel)
[ -n "$UPSTREAM_ALPINE" ] || UPSTREAM_ALPINE="unknown"
[ -n "$UPSTREAM_KERNEL" ] || UPSTREAM_KERNEL="unknown"

case "$MODE" in
    published)
        read -r pub_version pub_alpine pub_kernel <<EOF
$(published)
EOF
        say "published  ${pub_version} (alpine ${pub_alpine}, kernel ${pub_kernel})"
        exit 0
        ;;
esac

read -r pub_version pub_alpine pub_kernel <<EOF
$(published)
EOF
pub_version=${pub_version:-unknown}
pub_alpine=${pub_alpine:-unknown}
pub_kernel=${pub_kernel:-unknown}

# A rebuild is worth a build slot when the published image was built from
# something older than what the mirror serves today. "unknown" means either the
# release has not been published yet or the manifest predates these fields; both
# are reasons to build, and neither is a reason to fail.
wanted=0
[ "$pub_alpine" = "unknown" ] && wanted=1
[ "$pub_kernel" = "unknown" ] && wanted=1
[ "$wanted" = "0" ] && [ "$UPSTREAM_ALPINE" != "unknown" ] && [ "$UPSTREAM_ALPINE" != "$pub_alpine" ] && wanted=1
[ "$wanted" = "0" ] && [ "$UPSTREAM_KERNEL" != "unknown" ] && [ "$UPSTREAM_KERNEL" != "$pub_kernel" ] && wanted=1

if [ "$MODE" = "json" ]; then
    printf '{"alpine":"%s","kernel":"%s","pin_alpine":"%s","pin_kernel":"%s","published":"%s","published_alpine":"%s","published_kernel":"%s","rebuild":%s}\n' \
        "$UPSTREAM_ALPINE" "$UPSTREAM_KERNEL" "$ALPINE_PIN" "$KERNEL_PIN" \
        "$pub_version" "$pub_alpine" "$pub_kernel" "$([ "$wanted" = 1 ] && echo true || echo false)"
    exit 0
fi

if [ "$MODE" = "check" ]; then
    if [ "$wanted" = 1 ]; then
        say "rebuild   yes: upstream is alpine ${UPSTREAM_ALPINE} / ${KERNEL_PIN} ${UPSTREAM_KERNEL}, published is alpine ${pub_alpine} / ${pub_kernel}"
    else
        say "rebuild   no: the published beta was built from alpine ${pub_alpine} / ${pub_kernel}, which is still what the mirror serves"
    fi
    [ "$wanted" = 1 ]
    exit $?
fi

say "ZMRIG OS upstream"
say ""
say "pin        alpine ${ALPINE_PIN}, kernel ${KERNEL_PIN}"
say "upstream   alpine ${UPSTREAM_ALPINE}, ${KERNEL_PIN} ${UPSTREAM_KERNEL}"
say "published  ${pub_version} (alpine ${pub_alpine}, kernel ${pub_kernel})"
say "rebuild    $([ "$wanted" = 1 ] && echo 'wanted' || echo 'not needed')"

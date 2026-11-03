#!/bin/sh
# upstream.sh - what this image is built from, and whether upstream moved.
#
#   ./os/upstream.sh                 # the base, and every published channel
#   ./os/upstream.sh --check         # exit 0 when a rebuild would change something
#   ./os/upstream.sh --json          # the same facts for a workflow
#
# Two questions, one script, because they have the same answer:
#
#   *what is the image built from* - Alpine version, kernel flavour and version,
#   squashfs/zstd, GRUB, OpenRC. That is the base, and it is a fact that belongs
#   in a file rather than in somebody's memory of a blog post.
#
#   *should the weekly build run* - the image resolves `latest-stable` Alpine,
#   so a new point release upstream is a new image. Comparing the resolved
#   version against the manifest of the last published image is the difference
#   between "rebuild every Monday whether or not anything changed" and "rebuild
#   when something did".
#
# Nothing here downloads an image or needs a token: the Alpine release index and
# the GitHub releases API are both public reads.
set -eu

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
REPO="${ZMRIG_REPO:-MoLik-Labs/ZMRIG}"
ALPINE_MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"
KERNEL_PKG="${KERNEL_PKG:-linux-lts}"
AS_JSON=0
CHECK=0

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; }
die() { printf '%s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --check)    CHECK=1 ;;
        --json)     AS_JSON=1 ;;
        --repo)     REPO="${2:?}"; shift ;;
        --repo=*)   REPO="${1#*=}" ;;
        --kernel)   KERNEL_PKG="${2:?}"; shift ;;
        --kernel=*) KERNEL_PKG="${1#*=}" ;;
        -h|--help)  usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

fetch() { # url
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 20 -H 'user-agent: ZMRIG-upstream' "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 20 -O - "$1"
    else
        die "neither curl nor wget is installed"
    fi
}

# Two fixtures, for the same reason scripts/latest-iso.sh has one: a test that
# needs the internet is a test that fails on the day it matters. Neither is used
# by the workflows.
alpine_index() {
    if [ -n "${ZMRIG_ALPINE_INDEX:-}" ]; then cat "$ZMRIG_ALPINE_INDEX"; else fetch "$1"; fi
}
apk_index() {
    if [ -n "${ZMRIG_APK_INDEX:-}" ]; then cat "$ZMRIG_APK_INDEX"; else fetch "$1"; fi
}
manifest_body() {
    if [ -n "${ZMRIG_PUBLISHED_MANIFEST:-}" ]; then cat "$ZMRIG_PUBLISHED_MANIFEST"; else fetch "$1"; fi
}
releases_json() {
    if [ -n "${ZMRIG_RELEASES_JSON:-}" ]; then cat "$ZMRIG_RELEASES_JSON"; else fetch "$1"; fi
}

# --------------------------------------------------------------- the base
# `latest-releases.yaml` is the document the image build itself reads, so this
# answers the same question with the same source instead of with a directory
# listing that depends on how the mirror formats HTML today.
alpine_version() {
    alpine_index "$ALPINE_MIRROR/latest-stable/releases/x86_64/latest-releases.yaml" 2>/dev/null |
        sed -n 's/^ *file: *alpine-minirootfs-\([0-9][0-9.]*\)-x86_64\.tar\.gz$/\1/p' |
        head -1
}

# The kernel is a package inside that Alpine release, so its version is one
# directory listing away. A miss is not fatal: the image is built from whatever
# the package manager resolves, and this is a report, not a lock file.
kernel_version() {
    local alpine="$1"
    [ -n "$alpine" ] || return 0
    apk_index "$ALPINE_MIRROR/v${alpine}/main/x86_64/" 2>/dev/null |
        sed -n "s/.*${KERNEL_PKG}-\([0-9][0-9a-zA-Z._]*\)-r[0-9]*\.apk.*/\1/p" |
        sort -u | tail -1
}

version_of_repo() {
    sed -n 's/^pub const version = "\(.*\)";/\1/p' "$ROOT/zmrig/src/main.zig" 2>/dev/null | head -1
}

# --------------------------------------------------------- what is published
# One anonymous API call for the whole list. The panels this feeds are the
# manifest each channel publishes, not a guess about the tag naming.
published() { # channel -> "tag version" or empty
    local channel="$1" payload
    payload=$(releases_json "https://api.github.com/repos/${REPO}/releases?per_page=20" 2>/dev/null) || return 0
    printf '%s' "$payload" | CHANNEL="$channel" node -e '
      let data = "";
      process.stdin.on("data", (c) => { data += c; });
      process.stdin.on("end", () => {
        let list;
        try { list = JSON.parse(data); } catch { process.exit(0); }
        const want = process.env.CHANNEL === "beta";
        const release = (Array.isArray(list) ? list : [])
          .filter((r) => !r.draft && Boolean(r.prerelease) === want)
          .sort((a, b) => String(b.published_at).localeCompare(String(a.published_at)))[0];
        if (!release) return;
        const manifest = (release.assets || []).find((a) => /zmrig-os-(stable|beta)-.*\.json$/.test(a.name));
        process.stdout.write(release.tag_name + " " + (manifest ? manifest.name : ""));
      });
    ' 2>/dev/null || true
}

ALPINE=$(alpine_version || true)
KERNEL=$(kernel_version "$ALPINE" || true)
VERSION=$(version_of_repo)
STABLE=$(published stable || true)
BETA=$(published beta || true)

# The base the last published image was built on, read from its own manifest.
# This is why the build writes `"alpine":` into that file: without it the only
# way to answer "is the published image on the current Alpine?" would be to
# download and boot it.
published_alpine() { # tag manifest-name
    local tag="$1" name="$2" body
    [ -n "$tag" ] && [ -n "$name" ] || return 0
    body=$(manifest_body "https://github.com/${REPO}/releases/download/${tag}/${name}" 2>/dev/null) || return 0
    printf '%s' "$body" | sed -n 's/.*"alpine": *"\([^"]*\)".*/\1/p' | head -1
}

STABLE_TAG=$(printf '%s' "$STABLE" | cut -d' ' -f1)
STABLE_MANIFEST=$(printf '%s' "$STABLE" | cut -d' ' -f2)
PUBLISHED_ALPINE=$(published_alpine "$STABLE_TAG" "$STABLE_MANIFEST" || true)

# ------------------------------------------------------------- the decision
# A scheduled build exists to pick up what changed *outside* this repository:
# a new Alpine point release, a kernel that moved. A change inside the
# repository arrives as a push, which already triggers the build, so this
# deliberately does not fire on one.
reason=""
if [ -z "$ALPINE" ]; then
    reason="cannot read the Alpine release index"
elif [ -z "$STABLE" ]; then
    reason="no stable image has been published yet"
elif [ -z "$PUBLISHED_ALPINE" ]; then
    # An image published before the manifest carried its base: the only safe
    # answer is to rebuild once, after which this branch stops being reachable.
    reason="the published image does not record its Alpine base"
elif [ "$PUBLISHED_ALPINE" != "$ALPINE" ]; then
    reason="Alpine ${ALPINE} replaces ${PUBLISHED_ALPINE} in the published image"
fi

if [ "$CHECK" = "1" ]; then
    if [ -n "$reason" ]; then
        printf '%s\n' "${reason}"
        exit 0
    fi
    exit 1
fi

if [ "$AS_JSON" = "1" ]; then
    printf '{\n'
    printf '  "alpine": "%s",\n' "${ALPINE}"
    printf '  "kernel_package": "%s",\n' "${KERNEL_PKG}"
    printf '  "kernel": "%s",\n' "${KERNEL}"
    printf '  "version": "%s",\n' "${VERSION}"
    printf '  "published_stable": "%s",\n' "${STABLE_TAG}"
    printf '  "published_alpine": "%s",\n' "${PUBLISHED_ALPINE}"
    printf '  "published_beta": "%s",\n' "${BETA}"
    printf '  "rebuild": %s,\n' "$([ -n "$reason" ] && printf true || printf false)"
    printf '  "reason": "%s"\n' "${reason}"
    printf '}\n'
    exit 0
fi

printf '\nZMRIG OS %s\n\n' "${VERSION:-unknown}"
printf '  %-18s %s\n' "base" "Alpine Linux ${ALPINE:-unknown} (x86_64, OpenRC, musl)"
printf '  %-18s %s\n' "kernel" "${KERNEL_PKG} ${KERNEL:-unknown}"
printf '  %-18s %s\n' "root filesystem" "squashfs, zstd level ${SQUASHFS_LEVEL:-19}, 1 MiB blocks"
printf '  %-18s %s\n' "initramfs" "busybox + $(printf 'zstd' ) if CONFIG_RD_ZSTD=y, else gzip"
printf '  %-18s %s\n' "bootloader" "GRUB, BIOS and UEFI, built with the image"
printf '\n  published: %s\n' "${STABLE_TAG:-nothing on the stable channel}"
[ -n "$PUBLISHED_ALPINE" ] && printf '             built on Alpine %s\n' "$PUBLISHED_ALPINE"
[ -n "$BETA" ] && printf '             %s (rolling beta)\n' "$(printf '%s' "$BETA" | cut -d' ' -f1)"
printf '\n'
if [ -n "$reason" ]; then
    printf '  rebuild: yes - %s\n\n' "$reason"
else
    printf '  rebuild: no - the published image is already on Alpine %s\n\n' "${PUBLISHED_ALPINE:-this series}"
fi

#!/bin/sh
# latest-iso.sh - the download link for the newest ZMRIG OS image.
#
#   ./scripts/latest-iso.sh                 # newest stable image, both arches
#   ./scripts/latest-iso.sh --arch v2       # one instruction level
#   ./scripts/latest-iso.sh --beta          # the rolling pre-release
#   ./scripts/latest-iso.sh --json          # for a script, or the dashboard
#
# CI publishes a release on every push to master and BETA, replacing the assets
# of that version in place, so this is always the image built from the current
# source. Nothing is guessed: the size and the hash come from the release.
#
# Needs curl (or wget) and either node or python3 to read JSON - both are already
# dependencies of this repository's other tools. With neither, it prints the
# releases page instead of pretending to parse.
set -eu

REPO="${ZMRIG_REPO:-MoLik-Labs/ZMRIG}"
ARCH=""
CHANNEL="stable"
AS_JSON=0

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; }

die() { printf '%s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --arch)    ARCH="${2:?}"; shift ;;
        --arch=*)  ARCH="${1#*=}" ;;
        --beta|--prerelease) CHANNEL="beta" ;;
        --stable)  CHANNEL="stable" ;;
        --json)    AS_JSON=1 ;;
        --repo)    REPO="${2:?}"; shift ;;
        --repo=*)  REPO="${1#*=}" ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

# Accept the short form and the full image name, because both are what people
# copy from a release page.
ARCH="${ARCH#x86-64-}"
case "$ARCH" in
    ''|v3|v2) ;;
    *) die "unknown architecture: $ARCH (v3 or v2)" ;;
esac
[ -n "$ARCH" ] || ARCH="all"

# A fixture in ZMRIG_RELEASES_JSON makes this testable without the network, and
# lets a mirror answer the same question.
json() {
    if [ -n "${ZMRIG_RELEASES_JSON:-}" ]; then
        cat "$ZMRIG_RELEASES_JSON"
    elif command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 20 -H 'accept: application/vnd.github+json' \
            -H 'user-agent: ZMRIG-latest-iso' \
            "https://api.github.com/repos/${REPO}/releases?per_page=10"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 20 -O - --header='accept: application/vnd.github+json' \
            "https://api.github.com/repos/${REPO}/releases?per_page=10"
    else
        return 1
    fi
}

PAYLOAD=$(json) || {
    printf 'cannot reach GitHub.\nDownload from https://github.com/%s/releases\n' "$REPO"
    exit 1
}

# The filter is one expression away from being a jq call, and jq is not installed
# on a rig. This is the whole of the JSON the script needs.
FILTER='
let data;
try { data = JSON.parse(require("node:fs").readFileSync(0, "utf8")); }
catch (error) { process.stderr.write("unreadable release list\n"); process.exit(2); }
const channel = process.argv[1];
const arch = process.argv[2];
const wantJson = process.argv[3] === "json";

const releases = (Array.isArray(data) ? data : []).filter((release) => !release.draft);
const pick = releases.find((release) => (channel === "beta" ? release.prerelease : !release.prerelease));
if (!pick) { process.stderr.write("no " + channel + " release published yet\n"); process.exit(3); }

const assets = (pick.assets || [])
  .filter((asset) => asset.name.endsWith(".iso"))
  .filter((asset) => arch === "all" || asset.name.includes("x86-64-" + arch))
  .map((asset) => ({
    name: asset.name,
    size: asset.size,
    url: asset.browser_download_url,
    sha: (pick.assets || []).find((other) => other.name === asset.name + ".sha256"),
  }));

if (assets.length === 0) { process.stderr.write("no image for that architecture in " + pick.tag_name + "\n"); process.exit(4); }

const mb = (bytes) => (bytes / 1048576).toFixed(1) + " MB";

(async () => {
  for (const asset of assets) {
    if (!asset.sha) continue;
    try {
      const response = await fetch(asset.sha.browser_download_url, { signal: AbortSignal.timeout(5000) });
      if (!response.ok) continue;
      const text = (await response.text()).trim().split(/\s+/)[0];
      if (/^[0-9a-f]{64}$/.test(text)) asset.sha256 = text;
    } catch (error) { /* offline: print the link, skip the hash */ }
  }

  if (wantJson) {
    process.stdout.write(JSON.stringify({
      tag: pick.tag_name,
      version: (pick.tag_name.match(/\d+\.\d+\.\d+/) || [null])[0],
      channel,
      published_at: pick.published_at,
      page: pick.html_url,
      assets: assets.map((asset) => ({ name: asset.name, size: asset.size, url: asset.url, sha256: asset.sha256 || null })),
    }, null, 2) + "\n");
    return;
  }

  process.stdout.write(pick.tag_name + (pick.prerelease ? " (rolling beta)" : "") + "\n\n");
  for (const asset of assets) {
    process.stdout.write(asset.name + "\n");
    process.stdout.write("  size    " + mb(asset.size) + "\n");
    process.stdout.write("  link    " + asset.url + "\n");
    if (asset.sha256) process.stdout.write("  sha256  " + asset.sha256 + "\n");
    process.stdout.write("\n");
  }
  process.stdout.write("write it to a stick:\n");
  process.stdout.write("  curl -L -o zmrig-os.iso \"" + (assets[0].url) + "\"\n");
  process.stdout.write("  sudo dd if=zmrig-os.iso of=/dev/sdX bs=4M status=progress conv=fsync\n");
})();
'

if command -v node >/dev/null 2>&1; then
    printf '%s' "$PAYLOAD" | node -e "$FILTER" "$CHANNEL" "$ARCH" "$([ "$AS_JSON" = 1 ] && printf json || printf text)"
else
    # No node: the honest answer is the release page, not a hand-rolled parser
    # that works on today's JSON and not on tomorrow's.
    printf 'node is not installed, so this cannot read the release list.\n'
    printf 'Download from https://github.com/%s/releases\n' "$REPO"
    exit 1
fi

#!/usr/bin/env bash
#
# deps.sh - install what build-iso.sh needs, on whatever the host runs.
#
#   sudo ./os/deps.sh          # install
#   ./os/deps.sh --check       # only report what is missing
#
# This is the whole host requirement: a distro's ISO tooling, squashfs, a
# C/C++ compiler and zig. Nothing else is downloaded at build time except the
# Alpine minirootfs and its packages.
set -euo pipefail

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

# grub-mkimage is what builds the two files `zmrig-os install` writes to a disk:
# without it the ISO still boots, but it cannot install itself anywhere.
need=(xorriso mtools mksquashfs cpio gzip tar curl sha256sum grub-mkrescue grub-mkimage gcc g++)

missing=()
for t in "${need[@]}"; do
    command -v "$t" >/dev/null || missing+=("$t")
done

if [ ${#missing[@]} -eq 0 ]; then
    echo "all build tools present"
else
    echo "missing: ${missing[*]}"
fi

if [ "$CHECK" = "1" ]; then
    [ ${#missing[@]} -eq 0 ] || exit 1
    exit 0
fi

[ "$(id -u)" = "0" ] || exec sudo "$0" "$@"

if command -v apt-get >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        xorriso mtools squashfs-tools cpio gzip curl ca-certificates \
        grub-pc-bin grub-efi-amd64-bin grub-common \
        build-essential python3 python3-pip \
        qemu-system-x86 ovmf
elif command -v apk >/dev/null; then
    apk add --no-progress xorriso mtools squashfs-tools cpio gzip curl \
        grub grub-efi grub-bios build-base python3 py3-pip qemu-system-x86_64
elif command -v dnf >/dev/null; then
    dnf install -y xorriso mtools squashfs-tools cpio gzip curl \
        grub2-tools-extra grub2-efi-x64-modules gcc gcc-c++ make python3-pip \
        qemu-system-x86 edk2-ovmf
else
    echo "unknown package manager: install xorriso, mtools, squashfs-tools, cpio, curl," >&2
    echo "grub-pc-bin, grub-efi-amd64-bin, gcc, g++, qemu-system-x86 by hand" >&2
    exit 1
fi

# zig 0.13 is not in any distro at a usable version; the pip wheel is the same
# compiler the release binaries are built with. The test is the version, not
# whether `zig` exists: distributions and CI runners ship newer Zig, which
# compiles nothing in zmrig/ and would otherwise be treated as satisfied.
ROOT=$(cd -- "$(dirname -- "${0}")/.." && pwd)
if ! zig_bin=$("${ROOT}/scripts/find-zig.sh" 2>&1); then
    echo "$zig_bin" >&2
    python3 -m pip install --break-system-packages -q ziglang==0.13.0 2>/dev/null ||
        python3 -m pip install -q ziglang==0.13.0
    zig_bin=$("${ROOT}/scripts/find-zig.sh") || {
        echo "zig 0.13 still not available after pip install" >&2
        exit 1
    }
fi
echo "zig: $("$zig_bin" version) at $zig_bin"

echo "done"

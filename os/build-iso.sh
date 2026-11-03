#!/usr/bin/env bash
#
# build-iso.sh - build the ZMRIG OS bootable image.
#
#   sudo ./os/build-iso.sh                       # x86-64-v3, stable
#   sudo ./os/build-iso.sh --arch x86-64-v2      # older CPUs
#   sudo ./os/build-iso.sh --kernel linux-virt   # VMs only, smaller image
#   sudo ./os/build-iso.sh --plan                # print the steps, change nothing
#   sudo ./os/build-iso.sh --smoke               # build, then boot it in QEMU
#
# The image is a live CD/USB: GRUB (BIOS and UEFI) boots a kernel and a small
# initramfs, the initramfs finds rootfs.squashfs on the same media, stacks a
# tmpfs over it, and hands over to OpenRC. Nothing is installed to the machine's
# disk and nothing on the stick is modified, so the same stick can boot a
# hundred rigs and the wallet is configured per machine.
#
# Output (in $OUT, default os/out):
#   zmrig-os-<version>-<arch>.iso
#   zmrig-os-<version>-<arch>.iso.sha256
#   zmrig-os-<version>-<arch>.iso.json     (the update manifest this ISO serves)
#
# Needs (os/deps.sh installs them): xorriso, mtools, grub-pc-bin,
# grub-efi-amd64-bin, squashfs-tools, cpio, gzip, curl, tar, gcc, zig.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${0}")/.." && pwd)
HERE="${ROOT}/os"
ORIG_ARGS=("$@")

# "latest-stable" is a symlink the Alpine CDN maintains; pinning a version
# number here instead means the build breaks the month that release goes EOL,
# which is a strange way to lose a CI job. Pass --alpine v3.22 to pin.
ALPINE_VER="${ALPINE_VER:-latest-stable}"
ALPINE_MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"
KERNEL_PKG="${KERNEL_PKG:-linux-lts}"
ARCH_LEVEL="${ARCH_LEVEL:-x86-64-v3}"
CHANNEL="${CHANNEL:-stable}"
WORK="${ZMRIG_OS_WORK:-/tmp/zmrig-os-build}"
OUT="${OUT:-${HERE}/out}"
JOBS=$(nproc 2>/dev/null || echo 2)
PLAN=0
SMOKE=0
SELF_CHECK=0
CLEAN=0
KEEP_ROOTFS=0

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --arch)        ARCH_LEVEL="${2:?}"; shift ;;
        --arch=*)      ARCH_LEVEL="${1#*=}" ;;
        --kernel)      KERNEL_PKG="${2:?}"; shift ;;
        --kernel=*)    KERNEL_PKG="${1#*=}" ;;
        --channel)     CHANNEL="${2:?}"; shift ;;
        --channel=*)   CHANNEL="${1#*=}" ;;
        --alpine)      ALPINE_VER="${2:?}"; shift ;;
        --alpine=*)    ALPINE_VER="${1#*=}" ;;
        --out)         OUT="${2:?}"; shift ;;
        --out=*)       OUT="${1#*=}" ;;
        --work)        WORK="${2:?}"; shift ;;
        --work=*)      WORK="${1#*=}" ;;
        --jobs)        JOBS="${2:?}"; shift ;;
        --jobs=*)      JOBS="${1#*=}" ;;
        --plan)        PLAN=1 ;;
        --self-check)  SELF_CHECK=1 ;;
        --smoke)       SMOKE=1 ;;
        --clean)       CLEAN=1 ;;
        --keep-rootfs) KEEP_ROOTFS=1 ;;
        -h|--help)     usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

VERSION=$(sed -n 's/^pub const version = "\(.*\)";/\1/p' "${ROOT}/zmrig/src/main.zig" | head -1)
[ -n "$VERSION" ] || { echo "cannot read the version from zmrig/src/main.zig" >&2; exit 1; }

ISO_NAME="zmrig-os-${VERSION}-${ARCH_LEVEL}"
ISO_PATH="${OUT}/${ISO_NAME}.iso"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
say()  { printf '    %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

ROOTFS="${WORK}/rootfs"
BTREE="${WORK}/bin"
ISODIR="${WORK}/iso"
CACHE="${WORK}/cache"

plan() {
    cat <<EOF
ZMRIG OS ${VERSION} (${ARCH_LEVEL}, channel ${CHANNEL}, kernel ${KERNEL_PKG})

  work dir      ${WORK}
  output        ${ISO_PATH}

  1. fetch Alpine ${ALPINE_VER} x86_64 minirootfs into ${CACHE}
  2. build zmrig: zmrig/build.sh --static --arch=${ARCH_LEVEL}
  3. chroot: apk add alpine-base ${KERNEL_PKG} openrc e2fsprogs util-linux curl
            ca-certificates chrony openssh pciutils ifupdown-ng dhcpcd
  4. overlay: /usr/local/bin/zmrig{,-os}, /usr/local/lib/zmrig/tune-linux.sh,
     /etc/init.d/zmrig{,-firstboot}, /etc/sysctl.d/99-zmrig.conf, sshd (keys only)
  5. squashfs: mksquashfs rootfs -comp zstd -b 1M -all-root
  6. initramfs: busybox + the 30 modules needed to find the media
  7. ISO: GRUB BIOS + UEFI, five boot entries (max/balanced/eco/light/debug)
  8. checksums + ${ISO_NAME}.json manifest
EOF
}

if [ "$PLAN" = "1" ]; then
    plan
    exit 0
fi

# --self-check verifies every file and scripting assumption the build depends
# on, without root, a network or a toolchain. It is what runs on a machine that
# is about to build the image and on every pull request that touches os/.
if [ "$SELF_CHECK" = "1" ]; then
    fail=0
    want() { if [ -e "$1" ]; then printf '  ok    %s\n' "$1"; else printf '  MISS  %s\n' "$1"; fail=1; fi; }
    syntax() { if sh -n "$1" 2>/dev/null; then printf '  ok    %s (syntax)\n' "$1"; else printf '  BAD   %s (syntax)\n' "$1"; fail=1; fi; }

    for f in \
        "${HERE}/init" \
        "${HERE}/chroot-setup.sh" \
        "${HERE}/make-initramfs.sh" \
        "${HERE}/smoke-qemu.sh" \
        "${HERE}/deps.sh" \
        "${HERE}/overlay/usr/local/bin/zmrig-os" \
        "${HERE}/overlay/usr/local/lib/zmrig/firstboot.sh" \
        "${HERE}/overlay/etc/init.d/zmrig" \
        "${HERE}/overlay/etc/init.d/zmrig-firstboot" \
        "${HERE}/overlay/etc/sysctl.d/99-zmrig.conf" \
        "${HERE}/overlay/etc/modules" \
        "${HERE}/overlay/etc/zmrig/os.conf.example" \
        "${HERE}/overlay/etc/zmrig/banner.txt" \
        "${HERE}/overlay/etc/issue" \
        "${ROOT}/zmrig/build.sh" \
        "${ROOT}/scripts/tune-linux.sh" \
        "${ROOT}/zmrig/src/main.zig"; do
        want "$f"
    done

    for f in "${HERE}/init" "${HERE}/chroot-setup.sh" "${HERE}/make-initramfs.sh" \
             "${HERE}/overlay/usr/local/bin/zmrig-os" \
             "${HERE}/overlay/usr/local/lib/zmrig/firstboot.sh"; do
        syntax "$f"
    done

    # The initramfs init is PID 1: it must be executable in the archive, and the
    # archive is assembled from a chroot, so the mode matters.
    [ -x "${HERE}/init" ] && printf '  ok    init is executable\n' || { printf '  BAD   init is not executable\n'; fail=1; }

    # Every script referenced by the workflows has to exist.
    for f in os/build-iso.sh os/deps.sh os/smoke-qemu.sh os/tests/control.sh os/ci/appliance.yml; do
        want "${ROOT}/${f}"
    done

    [ "$fail" = "0" ] || { printf '\nself-check failed\n' >&2; exit 1; }
    printf '\nself-check passed\n'
    exit 0
fi

if [ "$(id -u)" != "0" ]; then
    command -v sudo >/dev/null || die "run as root (the chroot, mounts and ISO assembly need it)"
    # "\${0} \$@" would be empty: the argument loop above consumed it.
    exec sudo --preserve-env=ZMRIG_OS_WORK,OUT,ALPINE_MIRROR "$0" "${ORIG_ARGS[@]}"
fi

missing=()
for tool in mksquashfs grub-mkrescue xorriso cpio gzip tar curl sha256sum; do
    command -v "$tool" >/dev/null || missing+=("$tool")
done
if [ ${#missing[@]} -gt 0 ]; then
    die "missing tools: ${missing[*]} - run ./os/deps.sh (Debian/Ubuntu) or install the equivalents"
fi

# zig is needed for the static cross build; accept a pip-installed copy.
ZIG_BIN=${ZIG:-}
if [ -z "$ZIG_BIN" ]; then
    if command -v zig >/dev/null; then
        ZIG_BIN=$(command -v zig)
    elif python3 -c "import ziglang" >/dev/null 2>&1; then
        ZIG_BIN=$(python3 -c "import ziglang, os; print(os.path.join(os.path.dirname(ziglang.__file__), 'zig'))")
    fi
fi
[ -n "$ZIG_BIN" ] || die "zig 0.13 not found (pip install ziglang==0.13.0, or set ZIG=/path/to/zig)"

if [ "$CLEAN" = "1" ]; then
    step "cleaning ${WORK}"
    umount "${ROOTFS}/proc" "${ROOTFS}/sys" "${ROOTFS}/dev" 2>/dev/null || true
    rm -rf "$WORK"
fi

mkdir -p "$WORK" "$OUT" "$CACHE" "$BTREE" "$ISODIR"
START=$(date +%s)

# ------------------------------------------------------------------ 1. alpine
step "Alpine ${ALPINE_VER} minirootfs"
ROOTFS_TAR="${CACHE}/alpine-minirootfs-${ALPINE_VER}.tar.gz"

if [ ! -s "$ROOTFS_TAR" ]; then
    listing=$(curl -fsSL --retry 3 --max-time 60 \
        "${ALPINE_MIRROR}/${ALPINE_VER}/releases/x86_64/latest-releases.yaml") ||
        die "cannot reach ${ALPINE_MIRROR}"

    file=$(printf '%s\n' "$listing" | sed -n 's/^ *file: *\(alpine-minirootfs-.*x86_64\.tar\.gz\)$/\1/p' | head -1)
    [ -n "$file" ] || die "no minirootfs in the Alpine release listing"

    say "downloading ${file}"
    curl -fsSL --retry 3 --max-time 300 \
        -o "${ROOTFS_TAR}.part" "${ALPINE_MIRROR}/${ALPINE_VER}/releases/x86_64/${file}" ||
        die "download failed"
    mv "${ROOTFS_TAR}.part" "$ROOTFS_TAR"
else
    say "cached ${ROOTFS_TAR}"
fi

step "unpacking the root filesystem"
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"
tar -xzf "$ROOTFS_TAR" -C "$ROOTFS"

# apk needs repositories that match the release, and the minirootfs ships only
# main. Both are written explicitly so a stale file inside a cached tarball can
# never point at an old branch.
cat > "${ROOTFS}/etc/apk/repositories" <<EOF
${ALPINE_MIRROR}/${ALPINE_VER}/main
${ALPINE_MIRROR}/${ALPINE_VER}/community
EOF

# ------------------------------------------------------------------ 2. binary
step "building the miner (${ARCH_LEVEL}, static musl)"
ZIG="$ZIG_BIN" "${ROOT}/zmrig/build.sh" --static --arch="$ARCH_LEVEL" \
    --output "$BTREE" --jobs "$JOBS" >"${WORK}/build.log" 2>&1 ||
    { tail -30 "${WORK}/build.log"; die "the miner failed to build"; }

say "$("$BTREE/zmrig" --version 2>/dev/null | head -1)"
say "size: $(du -h "$BTREE/zmrig" | cut -f1), statically linked"

# ------------------------------------------------------------------ 3. chroot
step "installing packages inside the chroot"
cp /etc/resolv.conf "${ROOTFS}/etc/resolv.conf"
cp "${HERE}/chroot-setup.sh" "${ROOTFS}/tmp/chroot-setup.sh"
chmod 755 "${ROOTFS}/tmp/chroot-setup.sh"

# The bind mounts are what make apk work inside the chroot; `trap` removes them
# even when a package fails halfway, otherwise the next run sees a busy mount.
cleanup_mounts() {
    for m in proc sys dev/pts dev; do
        umount "${ROOTFS}/${m}" 2>/dev/null || true
    done
}
trap cleanup_mounts EXIT

mount -t proc proc "${ROOTFS}/proc"
mount -t sysfs sys "${ROOTFS}/sys"
mount --bind /dev "${ROOTFS}/dev"
mkdir -p "${ROOTFS}/dev/pts"
mount --bind /dev/pts "${ROOTFS}/dev/pts"

chroot "$ROOTFS" /bin/sh /tmp/chroot-setup.sh "$KERNEL_PKG" "$CHANNEL" ||
    die "the chroot setup failed"

KVER=$(cat "${ROOTFS}/tmp/chroot-kver")
say "kernel modules ${KVER}"

# ------------------------------------------------------------------ 4. overlay
step "installing the appliance files"
cp -a "${HERE}/overlay/." "${ROOTFS}/"
cp "${BTREE}/zmrig" "${ROOTFS}/usr/local/bin/zmrig"
cp "${ROOT}/scripts/tune-linux.sh" "${ROOTFS}/usr/local/lib/zmrig/tune-linux.sh"
chmod 755 "${ROOTFS}/usr/local/bin/zmrig" \
          "${ROOTFS}/usr/local/bin/zmrig-os" \
          "${ROOTFS}/usr/local/lib/zmrig/tune-linux.sh" \
          "${ROOTFS}/usr/local/lib/zmrig/firstboot.sh"

mkdir -p "${ROOTFS}/etc/zmrig"
cp "${HERE}/overlay/etc/zmrig/os.conf.example" "${ROOTFS}/etc/zmrig/os.conf.example"
printf '%s\n' "$CHANNEL" > "${ROOTFS}/etc/zmrig/channel"
printf '%s\n' "$VERSION" > "${ROOTFS}/etc/zmrig/version"
printf '%s\n' "$ARCH_LEVEL" > "${ROOTFS}/etc/zmrig/arch"

# OpenRC has to know about the two services before the image is sealed.
for svc in zmrig zmrig-firstboot; do
    chroot "$ROOTFS" rc-update add "$svc" default >/dev/null 2>&1 ||
        die "rc-update add $svc failed"
done
# sshd stays enabled: a rig with no keyboard is the normal case, and the sshd
# config accepts keys only, so an unconfigured rig is not an open one.
say "services: $(chroot "$ROOTFS" rc-update show default 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"

# The runtime state of the build host must not leak into the image.
rm -rf "${ROOTFS}/var/cache/apk"/* "${ROOTFS}/tmp"/* "${ROOTFS}/root/.ash_history" 2>/dev/null || true
: > "${ROOTFS}/etc/mtab" 2>/dev/null || true
rm -f "${ROOTFS}/etc/resolv.conf"

# ------------------------------------------------------------------ 5. initramfs
step "building the initramfs"

# Built from the same chroot the packages were installed into: the module tree
# belongs to the kernel package, and a base-system tarball has no kernel at all.
mkdir -p "${ISODIR}/boot/grub" "${ISODIR}/zmrig"
cp "${HERE}/init" "${ROOTFS}/tmp/init"
cp "${HERE}/make-initramfs.sh" "${ROOTFS}/tmp/make-initramfs.sh"
chmod 755 "${ROOTFS}/tmp/init" "${ROOTFS}/tmp/make-initramfs.sh"

chroot "$ROOTFS" /bin/sh /tmp/make-initramfs.sh /tmp/init /tmp/initramfs.cpio.gz ||
    die "the initramfs build failed"
cp "${ROOTFS}/tmp/initramfs.cpio.gz" "${ISODIR}/boot/initramfs.gz"
say "initramfs.gz: $(du -h "${ISODIR}/boot/initramfs.gz" | cut -f1)"

KERNEL_IMG=$(find "${ROOTFS}/boot" -maxdepth 1 -name 'vmlinuz*' | sort | head -1)
[ -n "$KERNEL_IMG" ] || die "no kernel in ${ROOTFS}/boot (package ${KERNEL_PKG}?)"
cp "$KERNEL_IMG" "${ISODIR}/boot/vmlinuz"
say "kernel: $(basename "$KERNEL_IMG") ($(du -h "${ISODIR}/boot/vmlinuz" | cut -f1))"

# The initramfs build leaves a 300 MB staging tree and the scripts behind; none
# of it belongs in the image.
rm -rf "${ROOTFS}/tmp"/*
: > "${ROOTFS}/etc/mtab" 2>/dev/null || true

# ------------------------------------------------------------------ 6. squashfs
step "building rootfs.squashfs"

# zstd is the smallest-and-fastest of the compressors squashfs-tools supports
# here; xz compresses a little better and costs seconds of unpacking on every
# boot of every rig.
rm -f "${ISODIR}/zmrig/rootfs.squashfs"
if mksquashfs -help 2>&1 | grep -q -- '-comp'; then
    mksquashfs "$ROOTFS" "${ISODIR}/zmrig/rootfs.squashfs" \
        -noappend -no-progress -all-root -b 1M -comp zstd >/dev/null ||
        mksquashfs "$ROOTFS" "${ISODIR}/zmrig/rootfs.squashfs" \
            -noappend -no-progress -all-root -b 1M >/dev/null
else
    mksquashfs "$ROOTFS" "${ISODIR}/zmrig/rootfs.squashfs" -noappend -no-progress >/dev/null
fi
say "rootfs.squashfs: $(du -h "${ISODIR}/zmrig/rootfs.squashfs" | cut -f1)"

cleanup_mounts

if [ "$KEEP_ROOTFS" = "0" ]; then
    rm -rf "$ROOTFS"
else
    say "kept the root filesystem at $ROOTFS"
fi

step "writing GRUB and the ISO tree"

cat > "${ISODIR}/boot/grub/grub.cfg" <<EOF
# ZMRIG OS ${VERSION} - live image, no installer, nothing written to any disk.
set timeout=5
set default=0

# The kernel command line carries the appliance settings, so a fleet is
# re-pointed by editing this file (or by pressing 'e' once) instead of by
# rebooting into a menu. zmrig.os.wallet=4... also works here.
set zmrig_params="quiet loglevel=3 nowatchdog console=tty0 console=ttyS0,115200"

menuentry "ZMRIG OS ${VERSION} - max hashrate" {
    linux /boot/vmlinuz \$zmrig_params zmrig.os.mode=max transparent_hugepage=always
    initrd /boot/initramfs.gz
}

menuentry "ZMRIG OS ${VERSION} - balanced (one core free)" {
    linux /boot/vmlinuz \$zmrig_params zmrig.os.mode=balanced transparent_hugepage=always
    initrd /boot/initramfs.gz
}

menuentry "ZMRIG OS ${VERSION} - eco (half the cores, max per watt)" {
    linux /boot/vmlinuz \$zmrig_params zmrig.os.mode=eco transparent_hugepage=madvise
    initrd /boot/initramfs.gz
}

menuentry "ZMRIG OS ${VERSION} - light (512 MB RAM, no dataset)" {
    linux /boot/vmlinuz \$zmrig_params zmrig.os.mode=light zmrig.os.hugepages=0 transparent_hugepage=always
    initrd /boot/initramfs.gz
}

menuentry "ZMRIG OS ${VERSION} - safe mode (no huge pages, no MSR)" {
    linux /boot/vmlinuz \$zmrig_params zmrig.os.mode=max zmrig.os.hugepages=0 transparent_hugepage=madvise nomodeset
    initrd /boot/initramfs.gz
}

menuentry "ZMRIG OS ${VERSION} - debug shell (no mining)" {
    linux /boot/vmlinuz \$zmrig_params zmrig.os.debug=1 zmrig.os.nostart=1 nomodeset
    initrd /boot/initramfs.gz
}
EOF

cp "${HERE}/overlay/etc/zmrig/os.conf.example" "${ISODIR}/zmrig/os.conf.example"

cat > "${ISODIR}/zmrig/README.txt" <<EOF
ZMRIG OS ${VERSION} (${ARCH_LEVEL}, ${CHANNEL})

Boot this image on the rig -- USB stick or CD, BIOS or UEFI. Nothing is
installed and nothing on the machine is modified.

First boot
  1. A wizard asks for your Monero wallet on the console. Paste it.
  2. The rig starts mining within a few seconds.

Headless / fleet
  Add these to the kernel command line in GRUB (press 'e' on the entry):
      zmrig.os.wallet=4...
      zmrig.os.pool=pool.example.com:10001
      zmrig.os.worker=rig-01
      zmrig.os.mode=max|balanced|eco|light

Keeping the config across reboots
  The image is read-only, so /etc/zmrig lives in RAM. Make a partition on the
  same stick, label it ZMRIGDATA, and the settings are picked up at every boot:
      zmrig-os persist /dev/sdX1

Daily use
      zmrig-os status        what is hashing and at what rate
      zmrig-os mode eco      change aggressiveness without a reboot
      zmrig-os logs 100      the miner log
      zmrig-os bench 30      measure this machine for 30 s
      zmrig-os doctor        every check the boot makes, printed
      zmrig-os update --apply    pull the newest miner into the running image
      zmrig-os ssh-key add   paste a public key, then 'rc-service sshd start'

The developer fee is 1 % of Monero mining time, printed in --check and in the
banner. 'zmrig-os setup --donate 0' turns it off; nothing else about the miner
changes.

Everything here is @nggkhaiz's build of ZMRIG: https://github.com/NggKhaiz/ZMRIG
EOF

mkdir -p "${ISODIR}/.disk"
printf 'ZMRIG OS %s %s\n' "$VERSION" "$ARCH_LEVEL" > "${ISODIR}/.disk/info"

rm -f "$ISO_PATH"
grub-mkrescue -o "$ISO_PATH" "$ISODIR" \
    -- -volid ZMRIGOS >"${WORK}/iso.log" 2>&1 ||
    { tail -20 "${WORK}/iso.log"; die "grub-mkrescue failed"; }

# ------------------------------------------------------------------ 8. publish
step "checksums and manifest"
(cd "$OUT" && sha256sum "$(basename "$ISO_PATH")" > "$(basename "$ISO_PATH").sha256")
ISO_SHA=$(cut -d' ' -f1 "${ISO_PATH}.sha256")
ISO_SIZE=$(stat -c %s "$ISO_PATH" 2>/dev/null || stat -f %z "$ISO_PATH")
REPO_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-NggKhaiz/ZMRIG}/releases/latest/download"

# What this image is actually made of, for the manifest and for `zmrig-os
# version` on the machine: the point release apk resolved, and the kernel that
# came with it. Both are read out of the rootfs the build just produced, so they
# cannot disagree with the image they describe.
ALPINE_BUILT=$(cat "${ROOTFS}/etc/alpine-release" 2>/dev/null | tr -d '\n' || true)
KERNEL_BUILT=$(basename "$(find "${ROOTFS}/lib/modules" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | head -1)" 2>/dev/null || true)
[ -n "$ALPINE_BUILT" ] || ALPINE_BUILT="unknown"
[ -n "$KERNEL_BUILT" ] || KERNEL_BUILT="unknown"
printf 'alpine %s, kernel %s\n' "$ALPINE_BUILT" "$KERNEL_BUILT" > "${ROOTFS}/etc/zmrig/base" 2>/dev/null || true

cat > "${OUT}/${ISO_NAME}.json" <<EOF
{
  "product": "zmrig-os",
  "channel": "${CHANNEL}",
  "version": "${VERSION}",
  "arch": "${ARCH_LEVEL}",
  "kernel": "${KERNEL_PKG}",
  "kernel_version": "${KERNEL_BUILT}",
  "alpine": "${ALPINE_BUILT}",
  "iso_url": "${REPO_URL}/${ISO_NAME}.iso",
  "iso_sha256": "${ISO_SHA}",
  "iso_bytes": ${ISO_SIZE},
  "binary_url": "${REPO_URL}/zmrig-linux-${ARCH_LEVEL}",
  "binary_sha256": "$(sha256sum "${BTREE}/zmrig" | cut -d' ' -f1)",
  "built": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF

ELAPSED=$(( $(date +%s) - START ))
step "done in ${ELAPSED}s"
say "image     ${ISO_PATH} ($(du -h "$ISO_PATH" | cut -f1))"
say "sha256    ${ISO_SHA}"
say "manifest  ${OUT}/${ISO_NAME}.json"
say "write it  sudo dd if=${ISO_PATH} of=/dev/sdX bs=4M status=progress conv=fsync"

if [ "$SMOKE" = "1" ]; then
    step "booting it in QEMU"
    "${HERE}/smoke-qemu.sh" "$ISO_PATH" || die "the image did not boot"
fi

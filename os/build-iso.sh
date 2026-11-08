#!/usr/bin/env bash
#
# build-iso.sh - build the ZMRIG OS bootable image.
#
#   sudo ./os/build-iso.sh                       # x86-64-v3, stable
#   sudo ./os/build-iso.sh --arch x86-64-v2      # older CPUs
#   sudo ./os/build-iso.sh --kernel linux-virt   # VMs only, smaller image
#   sudo ./os/build-iso.sh --firmware all        # keep every firmware blob
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
# minimal drops the GPU/Wi-Fi/Infiniband firmware blobs and the stock initramfs;
# `all` keeps the package intact for a board with a NIC that needs one of them.
FIRMWARE="${FIRMWARE:-minimal}"
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
        --firmware)    FIRMWARE="${2:?}"; shift ;;
        --firmware=*)  FIRMWARE="${1#*=}" ;;
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

# Every step is timed. A build that spends 40 minutes somewhere should say so
# in one glance at the log, because the job timeout only reports the total.
step() {
    local now elapsed=0
    now=$(date +%s)
    [ -z "${START:-}" ] || elapsed=$((now - START))
    printf '\n\033[1;36m==> %s\033[0m \033[2m(+%ss)\033[0m\n' "$*" "$elapsed"
}
say()  { printf '    %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
warn() { printf 'warning: %s\n' "$*" >&2; }

ROOTFS="${WORK}/rootfs"
BTREE="${WORK}/bin"
ISODIR="${WORK}/iso"
CACHE="${WORK}/cache"

# What is actually inside the image, in megabytes, biggest first. Printed to the
# log and, in CI, as annotations, because the job log is not always readable from
# where somebody is debugging.
size_report() { # rootfs_dir squashfs
    local rootfs="$1" squash="$2" total out

    [ -d "$rootfs" ] || return 0
    total=$(du -sm "$rootfs" 2>/dev/null | cut -f1)
    REPORT="${OUT}/size-report.txt"
    printf 'ZMRIG OS %s (%s)\n\n' "$VERSION" "$ARCH_LEVEL" > "$REPORT"

    printf '\n    image contents (MB, biggest first)\n'
    du -sm "$rootfs"/* 2>/dev/null | sort -rn | head -10 | while read -r mb path; do
        printf '      %6s  %s\n' "$mb" "/${path#"$rootfs"/}"
    done | tee -a "$REPORT"

    # The largest single files matter as much as the largest directories: one
    # 300 MB tarball looks like "an Alpine image" in a directory listing.
    printf '\n    largest files\n'
    find "$rootfs" -xdev -type f -size +10M -printf '%s %p\n' 2>/dev/null |
        sort -rn | head -8 |
        while read -r bytes path; do
            printf '      %6s MB  %s\n' "$((bytes / 1048576))" "/${path#"$rootfs"/}"
        done | tee -a "$REPORT"

    out="rootfs ${total} MB, squashfs $(( $(stat -c %s "$squash" 2>/dev/null || echo 0) / 1048576 )) MB"
    printf '\n    %s\n' "$out"
    printf '\n%s\n' "$out" >> "$REPORT"
    [ -n "${GITHUB_ACTIONS:-}" ] && printf '::notice title=Image size::%s\n' "$out" || true
    return 0
}

# Can this kernel unpack a zstd initramfs? Alpine ships the config it was built
# with in /boot, so the answer is a grep rather than an assumption, and the
# answer decides a file name and one command. `gz` is the fallback for a kernel
# package that does not ship its config at all - an unverifiable yes is not a
# good enough reason to make an image that might not boot.
initramfs_codec() { # rootfs_dir -> zst | gz
    local rootfs="$1" config rc=1

    for config in "$rootfs"/boot/config-* "$rootfs"/boot/config; do
        [ -f "$config" ] || continue
        if grep -q '^CONFIG_RD_ZSTD=y' "$config"; then rc=0; break; fi
    done

    if [ "$rc" != "0" ]; then printf 'gz'; return 0; fi
    # The config says the kernel can do it; the chroot still has to have the
    # tool that produces it.
    if [ -x "$rootfs/usr/bin/zstd" ] || [ -x "$rootfs/bin/zstd" ]; then
        printf 'zst'
    else
        printf 'gz'
    fi
}

plan() {
    cat <<EOF
ZMRIG OS ${VERSION} (${ARCH_LEVEL}, channel ${CHANNEL}, kernel ${KERNEL_PKG})

  work dir      ${WORK}
  output        ${ISO_PATH}

  1. fetch Alpine ${ALPINE_VER} x86_64 minirootfs into ${CACHE}
  2. build zmrig: zmrig/build.sh --static --arch=${ARCH_LEVEL}
  3. chroot: apk add alpine-base ${KERNEL_PKG} openrc e2fsprogs util-linux curl
            ca-certificates chrony openssh pciutils ifupdown-ng dhcpcd zstd
  4. overlay: /usr/local/bin/zmrig{,-os}, /usr/local/lib/zmrig/tune-linux.sh,
     /etc/init.d/zmrig{,-firstboot}, /etc/sysctl.d/99-zmrig.conf, sshd (keys only)
  5. squashfs: mksquashfs rootfs -comp zstd -Xcompression-level ${SQUASHFS_LEVEL:-19} -b 1M
  6. initramfs: busybox + the 30 modules needed to find the media
  7. ISO: GRUB BIOS + UEFI, five boot entries (max/balanced/eco/light/debug)
  8. checksums + ${ISO_NAME}.iso.json manifest
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
        "${HERE}/plan.sh" \
        "${HERE}/overlay/etc/init.d/zmrig" \
        "${HERE}/overlay/etc/init.d/zmrig-firstboot" \
        "${HERE}/overlay/etc/sysctl.d/99-zmrig.conf" \
        "${HERE}/overlay/etc/modules" \
        "${HERE}/overlay/etc/zmrig/os.conf.example" \
        "${HERE}/overlay/etc/zmrig/banner.txt" \
        "${HERE}/overlay/etc/issue" \
        "${ROOT}/zmrig/build.sh" \
        "${ROOT}/scripts/find-zig.sh" \
        "${ROOT}/scripts/tune-linux.sh" \
        "${ROOT}/zmrig/src/main.zig"; do
        want "$f"
    done

    for f in "${HERE}/init" "${HERE}/chroot-setup.sh" "${HERE}/make-initramfs.sh" \
             "${HERE}/plan.sh" \
             "${HERE}/overlay/usr/local/bin/zmrig-os" \
             "${HERE}/overlay/usr/local/lib/zmrig/firstboot.sh"; do
        syntax "$f"
    done

    # The initramfs init is PID 1: it must be executable in the archive, and the
    # archive is assembled from a chroot, so the mode matters.
    [ -x "${HERE}/init" ] && printf '  ok    init is executable\n' || { printf '  BAD   init is not executable\n'; fail=1; }

    # The mount teardown must come before mksquashfs. It did not once, and the
    # image build then read a live /proc and a live /sys until the job timed out
    # at ninety minutes with nothing to show for it.
    sq=$(grep -n '^step "building rootfs.squashfs"' "${HERE}/build-iso.sh" | head -1 | cut -d: -f1)
    un=$(grep -n '^cleanup_mounts$' "${HERE}/build-iso.sh" | head -1 | cut -d: -f1)
    if [ -n "$sq" ] && [ -n "$un" ] && [ "$un" -lt "$sq" ]; then
        printf '  ok    mounts are torn down before mksquashfs\n'
    else
        printf '  BAD   mksquashfs would run with /proc, /sys or /dev still mounted\n'
        fail=1
    fi

    # grub.cfg and the build have to agree on the initramfs name. They are two
    # places in the same file, which is exactly how they drift: the build wrote
    # initramfs.gz and the menu asked for it by name, so a codec change would
    # have shipped an image whose every boot entry pointed at a missing file.
    if grep -q 'initrd /boot/initramfs\.\${INITRAMFS_EXT}' "${HERE}/build-iso.sh" &&
        ! grep -q 'initrd /boot/initramfs\.gz' "${HERE}/build-iso.sh"; then
        printf '  ok    every boot entry asks for the initramfs the build wrote\n'
    else
        printf '  BAD   grub.cfg names an initramfs the build may not write\n'
        fail=1
    fi

    # The initramfs codec is a decision about somebody else's kernel. If the
    # probe is removed, the build silently promises zstd to a kernel that may
    # not have it.
    if grep -q '^initramfs_codec()' "${HERE}/build-iso.sh" &&
        grep -q 'CONFIG_RD_ZSTD=y' "${HERE}/build-iso.sh"; then
        printf '  ok    the initramfs codec is read from the kernel config\n'
    else
        printf '  BAD   the initramfs codec is assumed, not checked\n'
        fail=1
    fi

    # The workflow uploads and publishes dist/*.iso.json; the build used to
    # write dist/<name>.json, so the artifact step found nothing to upload and
    # the release job found nothing to describe. One name, asserted here.
    if grep -q '"${OUT}/${ISO_NAME}.iso.json"' "${HERE}/build-iso.sh"; then
        printf '  ok    the manifest is named *.iso.json, as the workflow expects\n'
    else
        printf '  BAD   the manifest name does not match dist/*.iso.json\n'
        fail=1
    fi

    # The installer writes these three files and nothing else bootable; if the
    # build stops producing them, `zmrig-os install` turns a disk into a brick.
    tool="${HERE}/overlay/usr/local/bin/zmrig-os"
    for need in BOOTX64.EFI core.img boot.img; do
        grep -q "$need" "$tool" || { printf '  BAD   %s never mentions %s\n' "$tool" "$need"; fail=1; }
    done
    grep -q 'grub-mkimage -O x86_64-efi' "${HERE}/build-iso.sh" &&
        printf '  ok    the image builds its own EFI bootloader\n' ||
        { printf '  BAD   no EFI bootloader is built\n'; fail=1; }

    # A daily updater that is not executable is a rig that silently stops
    # updating, which looks exactly like a rig that is up to date.
    if [ -x "${HERE}/overlay/etc/periodic/daily/zmrig-auto" ]; then
        printf '  ok    the daily update hook is executable\n'
    else
        printf '  BAD   overlay/etc/periodic/daily/zmrig-auto is missing or not executable\n'
        fail=1
    fi

    # Three files carry the version and one release bump forgot one of them: the
    # control tool said 6.47.0 while the miner it supervised said 6.48.0, and the
    # thing that noticed was a 40-second CI job. Compared here, from the sources,
    # so `--self-check` catches it before the image is built.
    tool_version=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "${HERE}/overlay/usr/local/bin/zmrig-os" | head -1)
    miner_version=$(sed -n 's/^pub const version = "\(.*\)";$/\1/p' "${HERE}/../zmrig/src/main.zig" | head -1)
    if [ -n "$tool_version" ] && [ "$tool_version" = "$miner_version" ]; then
        printf '  ok    the control tool and the miner agree on %s\n' "$tool_version"
    else
        printf '  BAD   zmrig-os says %s, the miner says %s\n' "${tool_version:-?}" "${miner_version:-?}"
        fail=1
    fi

    # PID 1 cannot be run in a test, so the two invariants that fail silently are
    # asserted against its source. Both were broken once and cost a rig its
    # configuration: the environment block has to be built by the merge in
    # plan.sh (a block written from scratch drops zmrig_extra), and the nostart
    # flag has to reach /etc (a flag in /run is wiped by OpenRC's tmpfs).
    if grep -q 'plan_grubenv_block zmrig_slot' "${HERE}/init"; then
        printf '  ok    the initramfs merges the GRUB environment block\n'
    else
        printf '  BAD   os/init writes the environment block without merging it\n'
        fail=1
    fi
    if grep -q '/newroot/etc/zmrig/nostart' "${HERE}/init"; then
        printf '  ok    nostart is written where OpenRC cannot wipe it\n'
    else
        printf '  BAD   os/init writes nostart only under /run\n'
        fail=1
    fi
    if grep -q 'zmrig_extra' "${HERE}/overlay/usr/local/bin/zmrig-os"; then
        printf '  ok    the installed menu reads the kernel parameters\n'
    else
        printf '  BAD   the installed grub.cfg ignores zmrig_extra\n'
        fail=1
    fi

    # The fleet check-in: a crontab that names the tool, and a tool that knows
    # the command. Without both, an enrolled rig silently stops listening.
    if grep -q 'zmrig-os sync' "${HERE}/overlay/etc/crontabs/root" 2>/dev/null &&
       grep -q 'sync)' "${HERE}/overlay/usr/local/bin/zmrig-os"; then
        printf '  ok    the fleet check-in is scheduled and implemented\n'
    else
        printf '  BAD   overlay/etc/crontabs/root or the sync command is missing\n'
        fail=1
    fi

    # Every script referenced by the workflows has to exist.
    for f in os/build-iso.sh os/deps.sh os/smoke-qemu.sh os/tests/control.sh \
             scripts/find-zig.sh .github/workflows/os.yml; do
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

# zig 0.13 is needed for the static cross build. Whatever is on PATH is not
# automatically it - see scripts/find-zig.sh.
ZIG_BIN=$("${ROOT}/scripts/find-zig.sh") || die "zig 0.13 not found (pip install ziglang==0.13.0, or set ZIG=/path/to/zig)"

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

    # The exact point release, recorded in the manifest: "built on 3.22" is a
    # fact a bug report can use, and it is what lets os/upstream.sh tell the
    # Monday rebuild whether anything upstream actually moved.
    ALPINE_RESOLVED=$(printf '%s\n' "$file" | sed -n 's/^alpine-minirootfs-\([0-9][0-9.]*\)-x86_64\.tar\.gz$/\1/p')
    [ -n "$ALPINE_RESOLVED" ] || ALPINE_RESOLVED="$ALPINE_VER"

    say "downloading ${file}"
    curl -fsSL --retry 3 --max-time 300 \
        -o "${ROOTFS_TAR}.part" "${ALPINE_MIRROR}/${ALPINE_VER}/releases/x86_64/${file}" ||
        die "download failed"
    mv "${ROOTFS_TAR}.part" "$ROOTFS_TAR"
else
    say "cached ${ROOTFS_TAR}"
    # A cached tarball still knows which release it is.
    ALPINE_RESOLVED=$(basename "$ROOTFS_TAR" | sed -n 's/^alpine-minirootfs-\([0-9][0-9.]*\)-x86_64\.tar\.gz$/\1/p')
    ALPINE_RESOLVED="${ALPINE_RESOLVED:-$ALPINE_VER}"
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

# apk is the only step that talks to a package mirror, and a mirror that stops
# answering hangs a job rather than failing it. 40 minutes is generous: the same
# install takes two to four on a loaded runner.
timeout 2400 chroot "$ROOTFS" /bin/sh /tmp/chroot-setup.sh "$KERNEL_PKG" "$CHANNEL" "$FIRMWARE" ||
    die "the chroot setup failed or timed out after 2400 s (apk: ${ALPINE_MIRROR})"

[ -s "${ROOTFS}/tmp/chroot-kver" ] ||
    die "the chroot did not record its kernel version (/tmp/chroot-kver is empty or missing)"
KVER=$(cat "${ROOTFS}/tmp/chroot-kver")
say "kernel modules ${KVER}"

# ------------------------------------------------------------------ 4. overlay
step "installing the appliance files"
cp -a "${HERE}/overlay/." "${ROOTFS}/"
cp "${BTREE}/zmrig" "${ROOTFS}/usr/local/bin/zmrig"
cp "${ROOT}/scripts/tune-linux.sh" "${ROOTFS}/usr/local/lib/zmrig/tune-linux.sh"
cp "${HERE}/plan.sh" "${ROOTFS}/usr/local/lib/zmrig/plan.sh"
chmod 755 "${ROOTFS}/usr/local/bin/zmrig" \
          "${ROOTFS}/usr/local/bin/zmrig-os" \
          "${ROOTFS}/usr/local/lib/zmrig/tune-linux.sh" \
          "${ROOTFS}/usr/local/lib/zmrig/firstboot.sh"
chmod 644 "${ROOTFS}/usr/local/lib/zmrig/plan.sh"

mkdir -p "${ROOTFS}/etc/zmrig"
cp "${HERE}/overlay/etc/zmrig/os.conf.example" "${ROOTFS}/etc/zmrig/os.conf.example"
printf '%s\n' "$CHANNEL" > "${ROOTFS}/etc/zmrig/channel"
printf '%s\n' "$VERSION" > "${ROOTFS}/etc/zmrig/version"
printf '%s\n' "$ARCH_LEVEL" > "${ROOTFS}/etc/zmrig/arch"

# OpenRC has to know about the two services before the image is sealed.
for svc in zmrig zmrig-firstboot crond; do
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

# Which compressor the kernel can unpack is a fact in its own config file, which
# Alpine ships in /boot, so ask it instead of assuming. zstd is ~25 % smaller
# than gzip and decompresses faster; if the config does not say
# `CONFIG_RD_ZSTD=y` (or the zstd binary is missing from the chroot), gzip is
# still correct and this stays a one-line decision instead of a broken image.
INITRAMFS_CODEC=$(initramfs_codec "$ROOTFS")

chroot "$ROOTFS" /bin/sh /tmp/make-initramfs.sh /tmp/init "/tmp/initramfs.cpio.${INITRAMFS_CODEC:-gz}" \
    "${INITRAMFS_CODEC:-gz}" ||
    die "the initramfs build failed"
# The kernel finds the initrd by the `initrd` line in grub.cfg, not by the file
# name, so the name here is for the person reading the image.
INITRAMFS_EXT="gz"
[ "$INITRAMFS_CODEC" = "zst" ] && INITRAMFS_EXT="zst"
cp "${ROOTFS}/tmp/initramfs.cpio.${INITRAMFS_EXT}" "${ISODIR}/boot/initramfs.${INITRAMFS_EXT}"
rm -f "${ISODIR}/boot/initramfs.gz"
say "initramfs.${INITRAMFS_EXT}: $(du -h "${ISODIR}/boot/initramfs.${INITRAMFS_EXT}" | cut -f1) (${INITRAMFS_CODEC})"

# What this image is built from, on the image itself. "Which Alpine is this?"
# is a question a bug report asks, and the answer should not involve anybody
# remembering the week it was built. Written here rather than with the rest of
# the overlay because the initramfs codec is only known once it has been built.
{
    printf 'alpine %s\n' "${ALPINE_RESOLVED:-$ALPINE_VER}"
    printf 'kernel %s\n' "${KERNEL_PKG}"
    printf 'squashfs zstd-%s\n' "${SQUASHFS_LEVEL:-19}"
    printf 'initramfs %s\n' "${INITRAMFS_EXT}"
} > "${ROOTFS}/etc/zmrig/base"

KERNEL_IMG=$(find "${ROOTFS}/boot" -maxdepth 1 -name 'vmlinuz*' | sort | head -1)
[ -n "$KERNEL_IMG" ] || die "no kernel in ${ROOTFS}/boot (package ${KERNEL_PKG}?)"
cp "$KERNEL_IMG" "${ISODIR}/boot/vmlinuz"
say "kernel: $(basename "$KERNEL_IMG") ($(du -h "${ISODIR}/boot/vmlinuz" | cut -f1))"

# The initramfs build leaves a 300 MB staging tree and the scripts behind; none
# of it belongs in the image.
rm -rf "${ROOTFS}/tmp"/*
: > "${ROOTFS}/etc/mtab" 2>/dev/null || true

# ------------------------------------------------------------------ 6. squashfs

# This has to happen *before* mksquashfs, not after. With /proc, /sys and /dev
# still bind-mounted the image build recurses into a live kernel interface: it
# reads /sys entries that block, follows /proc into whatever the host is doing,
# and never finishes. That is what "Build the image" looked like from outside -
# ninety minutes, then the job timeout - and it also put host device nodes in
# the image.
cleanup_mounts
for m in proc sys dev dev/pts; do
    # `cmd && die` as the last statement of the body would return 1 under
    # `set -e` whenever the answer is the good one; ask as a question instead.
    if mountpoint -q "${ROOTFS}/${m}"; then
        die "${ROOTFS}/${m} is still mounted: mksquashfs would follow it into the host"
    fi
done

step "building rootfs.squashfs"

# zstd is the smallest-and-fastest of the compressors squashfs-tools supports
# here; xz compresses a little better and costs seconds of unpacking on every
# boot of every rig.
#
# Level 19 rather than the default 15: on this image it is a few megabytes off
# the download for build time nobody watches, and zstd decompression speed is
# the same at every level (that is the whole point of the format). The level is
# probed, because squashfs-tools before 4.4 has no `-Xcompression-level`.
rm -f "${ISODIR}/zmrig/rootfs.squashfs"
SQUASHFS_LEVEL="${SQUASHFS_LEVEL:-19}"
if mksquashfs -help 2>&1 | grep -q -- '-Xcompression-level' && [ "${SQUASHFS_LEVEL}" != "0" ]; then
    timeout 1800 mksquashfs "$ROOTFS" "${ISODIR}/zmrig/rootfs.squashfs" \
        -noappend -no-progress -all-root -b 1M -comp zstd -Xcompression-level "$SQUASHFS_LEVEL" >/dev/null ||
        die "mksquashfs failed or timed out after 1800 s"
elif mksquashfs -help 2>&1 | grep -q -- '-comp'; then
    timeout 1800 mksquashfs "$ROOTFS" "${ISODIR}/zmrig/rootfs.squashfs" \
        -noappend -no-progress -all-root -b 1M -comp zstd >/dev/null ||
        timeout 1800 mksquashfs "$ROOTFS" "${ISODIR}/zmrig/rootfs.squashfs" \
            -noappend -no-progress -all-root -b 1M >/dev/null ||
        die "mksquashfs failed or timed out after 1800 s"
else
    timeout 1800 mksquashfs "$ROOTFS" "${ISODIR}/zmrig/rootfs.squashfs" -noappend -no-progress >/dev/null ||
        die "mksquashfs failed or timed out after 1800 s"
fi
say "rootfs.squashfs: $(du -h "${ISODIR}/zmrig/rootfs.squashfs" | cut -f1)"

# The image is the product, so its size is a build output, not a mystery. This
# report exists because "the ISO is 1.1 GB" was once answered with "the kernel
# modules", and that turned out to be 3 % of it.
size_report "$ROOTFS" "${ISODIR}/zmrig/rootfs.squashfs"

if [ "$KEEP_ROOTFS" = "0" ]; then
    rm -rf "$ROOTFS"
else
    say "kept the root filesystem at $ROOTFS"
fi

# --------------------------------------------------------------- 7. handlers
step "bootloader images for an installed disk"

# A machine that installs ZMRIG OS onto its own disk still has to boot it, and
# the guest has no grub-install: the image is 120 MB and a GRUB toolkit for
# five architectures is not part of it. So the two files an install actually
# writes are built here, once, and carried inside the image:
#
#   BOOTX64.EFI   a standalone GRUB for the EFI partition (no module files)
#   core.img      the BIOS half, written into a 1 MiB BIOS-boot partition
#   boot.img      the 512-byte MBR half, written over the partition table
#
# They are self-contained: the early config searches for the filesystem label
# and hands over to the grub.cfg the installer writes, so nothing depends on
# disk numbering (which changes the moment a second disk is plugged in).
if command -v grub-mkimage >/dev/null 2>&1; then
    mkdir -p "${ISODIR}/zmrig/boot"
    EARLY="${WORK}/early.cfg"
    cat > "$EARLY" <<'EOF'
search --no-floppy --label --set=root ZMRIGROOT
if [ -z "$root" ]; then
    search --no-floppy --file --set=root /boot/grub/grub.cfg
fi
if [ -z "$root" ]; then
    search --no-floppy --label --set=root ZMRIGOS
fi
set prefix=($root)/boot/grub
configfile ($root)/boot/grub/grub.cfg
EOF

    # The module list is what the early config and a normal menu need, not the
    # whole catalogue: search (by label and by file), ext2 for ext4, and the
    # loader itself.
    MODULES="part_gpt part_msdos ext2 fat search search_label search_fs_file
             normal linux echo test configfile loadenv serial terminal"

    if grub-mkimage -O x86_64-efi -o "${ISODIR}/zmrig/boot/BOOTX64.EFI" \
            -p /boot/grub -c "$EARLY" $MODULES >"${WORK}/grub-efi.log" 2>&1; then
        say "BOOTX64.EFI: $(du -h "${ISODIR}/zmrig/boot/BOOTX64.EFI" | cut -f1)"
    else
        tail -5 "${WORK}/grub-efi.log"
        die "cannot build the EFI GRUB image (grub-efi-amd64-bin)"
    fi

    if grub-mkimage -O i386-pc -o "${ISODIR}/zmrig/boot/core.img" \
            -p /boot/grub -c "$EARLY" biosdisk $MODULES >"${WORK}/grub-bios.log" 2>&1; then
        say "core.img: $(du -h "${ISODIR}/zmrig/boot/core.img" | cut -f1)"
    else
        tail -5 "${WORK}/grub-bios.log"
        die "cannot build the BIOS GRUB image (grub-pc-bin)"
    fi

    BOOTIMG=""
    for c in /usr/lib/grub/i386-pc/boot.img /usr/share/grub2/i386-pc/boot.img \
             /usr/lib/grub2/i386-pc/boot.img; do
        [ -f "$c" ] && { BOOTIMG="$c"; break; }
    done
    [ -n "$BOOTIMG" ] || die "cannot find boot.img (grub-pc-bin)"
    cp "$BOOTIMG" "${ISODIR}/zmrig/boot/boot.img"
    say "boot.img: $BOOTIMG"
else
    warn "grub-mkimage is missing: this ISO cannot install itself to a disk"
    warn "install grub-pc-bin and grub-efi-amd64-bin, or run sudo ./os/deps.sh"
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

# Empty by default, and the place to put the parameters that must be settled
# before the first process starts: 'zmrig-os isolate' writes them here on an
# installed rig. isolcpus / nohz_full / rcu_nocbs cannot be applied at runtime,
# which is why a rig that wants them reboots once.
set zmrig_extra=""

menuentry "ZMRIG OS ${VERSION} - max hashrate" {
    linux /boot/vmlinuz \$zmrig_params \$zmrig_extra zmrig.os.mode=max transparent_hugepage=always
    initrd /boot/initramfs.${INITRAMFS_EXT}
}

menuentry "ZMRIG OS ${VERSION} - balanced (one core free)" {
    linux /boot/vmlinuz \$zmrig_params \$zmrig_extra zmrig.os.mode=balanced transparent_hugepage=always
    initrd /boot/initramfs.${INITRAMFS_EXT}
}

menuentry "ZMRIG OS ${VERSION} - eco (half the cores, max per watt)" {
    linux /boot/vmlinuz \$zmrig_params \$zmrig_extra zmrig.os.mode=eco transparent_hugepage=madvise
    initrd /boot/initramfs.${INITRAMFS_EXT}
}

menuentry "ZMRIG OS ${VERSION} - light (512 MB RAM, no dataset)" {
    linux /boot/vmlinuz \$zmrig_params \$zmrig_extra zmrig.os.mode=light zmrig.os.hugepages=0 transparent_hugepage=always
    initrd /boot/initramfs.${INITRAMFS_EXT}
}

menuentry "ZMRIG OS ${VERSION} - safe (never above 72 C, one core free)" {
    linux /boot/vmlinuz \$zmrig_params \$zmrig_extra zmrig.os.mode=safe zmrig.os.maxtemp=72 transparent_hugepage=madvise
    initrd /boot/initramfs.${INITRAMFS_EXT}
}

# The CPU mitigations cost real hashrate on recent silicon and protect against
# attacks that need code execution on this machine first. On a box that only
# mines, with no browser and no other users, that trade is worth offering - and
# it is offered as a menu entry, never as the default.
menuentry "ZMRIG OS ${VERSION} - max hashrate (CPU mitigations off)" {
    linux /boot/vmlinuz \$zmrig_params \$zmrig_extra zmrig.os.mode=max transparent_hugepage=always mitigations=off
    initrd /boot/initramfs.${INITRAMFS_EXT}
}

menuentry "ZMRIG OS ${VERSION} - troubleshooting (no huge pages, no MSR)" {
    linux /boot/vmlinuz \$zmrig_params \$zmrig_extra zmrig.os.mode=max zmrig.os.hugepages=0 transparent_hugepage=madvise nomodeset
    initrd /boot/initramfs.${INITRAMFS_EXT}
}

menuentry "ZMRIG OS ${VERSION} - debug shell (no mining)" {
    linux /boot/vmlinuz \$zmrig_params zmrig.os.debug=1 zmrig.os.nostart=1 nomodeset
    initrd /boot/initramfs.${INITRAMFS_EXT}
}
EOF

cp "${HERE}/overlay/etc/zmrig/os.conf.example" "${ISODIR}/zmrig/os.conf.example"

cat > "${ISODIR}/zmrig/README.txt" <<EOF
ZMRIG OS ${VERSION} (${ARCH_LEVEL}, ${CHANNEL})

Two ways to use this image. Both boot on BIOS and UEFI, from a stick, a CD, or a
Ventoy menu.

1. LIVE  (what this stick does when you boot it)
   Nothing is installed and nothing on the machine is modified. The config lives
   in RAM, so a reboot forgets it unless you give it a ZMRIGDATA partition.

2. INSTALLED  (write it onto the machine's own disk)
       zmrig-os install --disk /dev/nvme0n1     # or /dev/sda, /dev/vda ...
       zmrig-os install --disk /dev/sda --dry-run
   The disk is partitioned (EFI + one ext4 root) and the image is copied onto it:
   about a minute. From then on the machine boots from its own disk, the config
   persists, the miner starts by itself, updates itself once a day, and an update
   that will not boot rolls back to the other slot on the third try.

   Unattended, from a Ventoy menu or a fleet: add this to the boot entry
       zmrig.os.install=/dev/nvme0n1
   and the machine installs and reboots into it with no keyboard at all.

First boot
  1. A wizard asks for your Monero wallet on the console. Paste it.
  2. The rig starts mining within a few seconds.

Headless / fleet
  Add these to the kernel command line in GRUB (press 'e' on the entry):
      zmrig.os.wallet=4...
      zmrig.os.pool=pool.example.com:10001
      zmrig.os.worker=rig-01
      zmrig.os.mode=max|balanced|eco|light|safe
      zmrig.os.maxtemp=72      (safe mode: hold the CPU at or below this)
      zmrig.os.install=/dev/sdX  (install, then reboot)

Safe mode
  For a machine somebody also needs tomorrow. One core stays free, priority is
  the lowest there is, the MSR registers are not touched, and the miner watches
  the CPU temperature once a second: it gives back threads as the box warms,
  stops hashing above 87 C, and climbs again once it is cool. The dataset stays
  in RAM the whole time, so nothing is rebuilt on the way back up.

Updates
  An installed rig checks for a newer miner once a day and installs it next to
  the running system, so it survives a reboot. The OS image itself is written
  into the spare slot and only boots after a successful copy:
      zmrig-os auto --check     is there anything newer?
      zmrig-os auto --apply     install it now
      zmrig-os slot             which slot boots next
  AUTO_UPDATE=0 in /etc/zmrig/os.conf stops all of it.

Keeping the config across reboots on a LIVE stick
  The image is read-only, so /etc/zmrig lives in RAM. Make a partition on the
  same stick, label it ZMRIGDATA, and the settings are picked up at every boot:
      zmrig-os persist /dev/sdX1

Daily use
      zmrig-os status        what is hashing, at what rate, at what temperature
      zmrig-os mode eco      change aggressiveness without a reboot
      zmrig-os logs 100      the miner log
      zmrig-os bench 30      measure this machine for 30 s
      zmrig-os doctor        every check the boot makes, printed
      zmrig-os install       the two forms above, explained
      zmrig-os ssh-key add   paste a public key, then 'rc-service sshd start'

The developer fee is 3 % of Monero mining time, printed in --check and in the
banner. 'zmrig-os setup --donate 0' turns it off; nothing else about the miner
changes.

Everything here is @nggkhaiz's build of ZMRIG: https://github.com/MoLik-Labs/ZMRIG
EOF

mkdir -p "${ISODIR}/.disk"
printf 'ZMRIG OS %s %s\n' "$VERSION" "$ARCH_LEVEL" > "${ISODIR}/.disk/info"

# The checksum of the root filesystem, next to it on the medium. The initramfs
# reads it before it mounts anything: a stick that rotted in a drawer then
# refuses to boot instead of half-booting, and an installed rig whose slot no
# longer matches the one that was written falls back to the other slot.
(cd "${ISODIR}/zmrig" && sha256sum rootfs.squashfs | cut -d' ' -f1 > rootfs.squashfs.sha256)
say "rootfs checksum $(cut -c1-16 "${ISODIR}/zmrig/rootfs.squashfs.sha256")..."

rm -f "$ISO_PATH"
timeout 600 grub-mkrescue -o "$ISO_PATH" "$ISODIR" \
    -- -volid ZMRIGOS >"${WORK}/iso.log" 2>&1 ||
    { tail -20 "${WORK}/iso.log"; die "grub-mkrescue failed or timed out after 600 s"; }

# ------------------------------------------------------------------ 8. publish
step "checksums and manifest"
(cd "$OUT" && sha256sum "$(basename "$ISO_PATH")" > "$(basename "$ISO_PATH").sha256")
ISO_SHA=$(cut -d' ' -f1 "${ISO_PATH}.sha256")
ISO_SIZE=$(stat -c %s "$ISO_PATH" 2>/dev/null || stat -f %z "$ISO_PATH")
REPO_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-MoLik-Labs/ZMRIG}/releases/latest/download"

cat > "${OUT}/${ISO_NAME}.iso.json" <<EOF
{
  "product": "zmrig-os",
  "channel": "${CHANNEL}",
  "version": "${VERSION}",
  "arch": "${ARCH_LEVEL}",
  "kernel": "${KERNEL_PKG}",
  "alpine": "${ALPINE_RESOLVED}",
  "squashfs": "zstd-${SQUASHFS_LEVEL:-19}",
  "iso_url": "${REPO_URL}/${ISO_NAME}.iso",
  "iso_sha256": "${ISO_SHA}",
  "iso_bytes": ${ISO_SIZE},
  "binary_url": "${REPO_URL}/zmrig-linux-${ARCH_LEVEL}",
  "binary_sha256": "$(sha256sum "${BTREE}/zmrig" | cut -d' ' -f1)",
  "built": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF

ELAPSED=$(( $(date +%s) - START ))
ISO_MB=$(stat -c %s "$ISO_PATH" 2>/dev/null | awk '{ printf "%d", $1 / 1048576 }')
[ -f "${OUT}/size-report.txt" ] &&
    printf 'iso %s MB (%s)\nbuilt in %s s\n' "${ISO_MB:-?}" "$(basename "$ISO_PATH")" "$ELAPSED" \
        >> "${OUT}/size-report.txt"
[ -n "${GITHUB_ACTIONS:-}" ] &&
    printf '::notice title=ISO::%s MB (%s)\n' "${ISO_MB:-?}" "$(basename "$ISO_PATH")" || true

step "done in ${ELAPSED}s"
say "image     ${ISO_PATH} ($(du -h "$ISO_PATH" | cut -f1))"
say "sha256    ${ISO_SHA}"
say "manifest  ${OUT}/${ISO_NAME}.iso.json"
say "write it  sudo dd if=${ISO_PATH} of=/dev/sdX bs=4M status=progress conv=fsync"

if [ "$SMOKE" = "1" ]; then
    step "booting it in QEMU"
    "${HERE}/smoke-qemu.sh" "$ISO_PATH" || die "the image did not boot"
fi

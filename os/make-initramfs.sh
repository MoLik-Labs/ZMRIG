#!/bin/sh
# make-initramfs.sh - builds the tiny initramfs that finds the root filesystem.
#
# Runs *inside* the Alpine chroot, where the kernel modules and a static busybox
# actually live. Writes /tmp/initramfs.cpio.gz; the host script copies it into
# the ISO tree next to the kernel.
#
# Arguments: make-initramfs.sh <init-script> <output> [codec]
#
# `codec` is `zst` when the kernel's own config says CONFIG_RD_ZSTD=y and the
# zstd binary is in the chroot, `gz` otherwise. build-iso.sh reads that config;
# this script does not guess. A ~25 % smaller initramfs is decompressed at every
# boot of every rig, so it is worth the two lines.
set -eu

INIT_SCRIPT="${1:?path to the init script}"
OUT="${2:?path to the output archive}"
CODEC="${3:-gz}"
# The shared memory and CPU plan, which the init script sources before it
# reserves anything. Same file as the one inside the image, so the boot and
# `zmrig-os doctor` cannot disagree about how many pages this machine wants.
PLAN_SCRIPT="${1%/*}/plan.sh"

export PATH=/sbin:/bin:/usr/sbin:/usr/bin

KVER=$(ls /lib/modules | head -1)
STAGE=/tmp/initramfs
rm -rf "$STAGE"
mkdir -p "$STAGE"/bin "$STAGE"/sbin "$STAGE"/etc "$STAGE"/proc "$STAGE"/sys \
         "$STAGE"/dev "$STAGE"/run "$STAGE"/tmp "$STAGE"/newroot \
         "$STAGE"/root-ro "$STAGE"/overlay "$STAGE"/media "$STAGE"/lib/modules

# ---------------------------------------------------------------- busybox
# A static busybox is the whole userland of this initramfs: no libc, no
# /lib, nothing to go missing when the image is assembled on another host.
if [ -x /bin/busybox.static ]; then
    cp /bin/busybox.static "$STAGE"/bin/busybox
else
    cp /bin/busybox "$STAGE"/bin/busybox

    # Fallback for a busybox that is dynamically linked: musl is two files.
    for lib in /lib/ld-musl-x86_64.so.1 /lib/libc.musl-x86_64.so.1 /usr/lib/libc.musl-x86_64.so.1; do
        [ -f "$lib" ] || continue
        mkdir -p "$STAGE$(dirname "$lib")"
        cp "$lib" "$STAGE$lib"
    done
fi
chmod 755 "$STAGE"/bin/busybox

# One symlink per applet: the image then works the same whichever shell script
# reaches for a tool, without maintaining a hand-written list of what init uses.
"$STAGE"/bin/busybox --list | while read -r applet; do
    case "$applet" in
        ""|busybox) continue ;;
    esac

    # Applets that must shadow their /bin and /sbin counterparts, and the
    # symlink directories that make mount/switch_root/modprobe work at all.
    for dir in bin sbin usr/bin usr/sbin; do
        [ -d "$STAGE/$dir" ] || continue
        case "$dir:$applet" in
            bin:*|sbin:*)
                ln -sf /bin/busybox "$STAGE/$dir/$applet" ;;
        esac
    done
done

mkdir -p "$STAGE"/usr/bin "$STAGE"/usr/sbin

if [ -r "$PLAN_SCRIPT" ]; then
    cp "$PLAN_SCRIPT" "$STAGE/plan.sh"
    chmod 644 "$STAGE/plan.sh"
else
    echo "warning: no plan.sh at $PLAN_SCRIPT; the boot will use its fallbacks" >&2
fi
ln -sf /bin/busybox "$STAGE"/usr/bin/env
ln -sf /bin/busybox "$STAGE"/usr/bin/awk

# ---------------------------------------------------------------- modules
# Only what is needed to reach the media and stack the overlay. Every other
# driver is loaded from the real root filesystem after switch_root, so a new
# NIC does not force a new initramfs.
# Everything a rig has to do before the real root exists: find the medium, mount
# it, and - because the first boot configures the machine over the network, and
# because a rig with no NIC is a rig somebody drives to - reach the pool.
#
# The storage half covers the buses that actually appear in mining hardware:
# SATA (ahci, ata_piix), NVMe, USB (xhci/ehci/uhci, usb-storage, uas), eMMC and
# SD cards on a small board (mmc_core, mmc_block, sdhci and its platform
# variants), and virtio for a VM.
#
# The network half is a list of drivers rather than "everything", because the
# initramfs is unpacked into RAM on every boot: the five chips that are on a
# rig or on the board of one, plus USB tethering for the machine somebody is
# setting up at a desk.
MODULES="loop squashfs overlay isofs sr_mod cdrom sd_mod usb-storage uas usbhid
         ahci libahci ata_piix ata_generic nvme nvme-core virtio_blk virtio_pci
         virtio_scsi virtio_net
         mmc_core mmc_block sdhci sdhci_pci sdhci_acpi
         ext4 jbd2 mbcache crc16 vfat fat nls_cp437 nls_iso8859-1 xhci-pci xhci-hcd
         ehci-pci uhci-hcd ehci-hcd zram
         e1000 e1000e igb r8169 igc atlantic tg3
         usbnet cdc_ether r8152 ax88179_178a"

staged=0
for mod in $MODULES; do
    # --show-depends prints insmod lines for the module and everything it needs;
    # copying the paths from those lines is what keeps the initramfs from
    # missing a dependency that only shows up on somebody else's hardware.
    # The paths are collected first and copied in this shell, not in a pipeline:
    # a subshell cannot report how many modules it staged, and staging nothing
    # at all is the failure worth catching.
    deps=$(modprobe --show-depends -S "$KVER" -d / "$mod" 2>/dev/null |
        awk '/^insmod/ { print $2 }')
    for path in $deps; do
        [ -f "$path" ] || continue
        dest="$STAGE$path"
        [ -f "$dest" ] && continue
        mkdir -p "$(dirname "$dest")"
        if cp "$path" "$dest" 2>/dev/null; then staged=$((staged + 1)); fi
    done
done
printf 'staged %s kernel modules\n' "$staged"

# fscrypt/zstd/lz4 variants of the modules we care about are picked up by the
# `-n` copy above; compression libraries the kernel needs to decompress the
# squashfs image itself are not module options, so nothing else is required.

if [ "$staged" -gt 0 ] && [ -s /lib/modules/"$KVER"/modules.dep ] &&
   [ -n "$(ls -A "$STAGE"/lib/modules 2>/dev/null)" ]; then
    depmod -b "$STAGE" "$KVER" 2>/dev/null || true
else
    printf 'warning: no kernel modules staged; the image will only boot from media the kernel already sees\n' >&2
fi

# ---------------------------------------------------------------- init
cp "$INIT_SCRIPT" "$STAGE"/init
chmod 755 "$STAGE"/init

cat > "$STAGE"/etc/mdev.conf <<'EOF'
# Nothing to rename: mdev only has to create the device nodes.
EOF

# ---------------------------------------------------------------- archive
cd "$STAGE"
# busybox cpio has no --null; nothing in this tree has a space in its name, and
# every file is named by this script.
case "$CODEC" in
    zst)
        if command -v zstd >/dev/null 2>&1; then
            # The kernel autodetects by magic bytes, so no header work is needed.
            find . | cpio -o -H newc 2>/dev/null | zstd -19 -T0 -q -o "$OUT"
        else
            printf 'warning: zstd requested but not installed; falling back to gzip\n' >&2
            find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$OUT"
        fi
        ;;
    *)
        find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$OUT"
        ;;
esac

printf 'initramfs: %s (%s)\n' "$OUT" "$(du -h "$OUT" | cut -f1)"

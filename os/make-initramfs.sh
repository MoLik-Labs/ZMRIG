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
ln -sf /bin/busybox "$STAGE"/usr/bin/env
ln -sf /bin/busybox "$STAGE"/usr/bin/awk

# ---------------------------------------------------------------- modules
# Only what is needed to reach the media and stack the overlay. Every other
# driver is loaded from the real root filesystem after switch_root, so a new
# NIC does not force a new initramfs.
MODULES="loop squashfs overlay isofs sr_mod cdrom sd_mod usb-storage uas usbhid
         ahci libahci ata_piix ata_generic nvme virtio_blk virtio_pci virtio_scsi
         ext4 jbd2 mbcache crc16 vfat fat nls_cp437 nls_iso8859-1 xhci-pci xhci-hcd
         ehci-pci uhci-hcd ehci-hcd zram"

copied=0
for mod in $MODULES; do
    # --show-depends prints insmod lines for the module and everything it needs;
    # copying the paths from those lines is what keeps the initramfs from
    # missing a dependency that only shows up on somebody else's hardware.
    modprobe --show-depends -S "$KVER" -d / "$mod" 2>/dev/null |
        awk '/^insmod/ { print $2 }' |
        while read -r path; do
            [ -f "$path" ] || continue
            dest="$STAGE$path"
            mkdir -p "$(dirname "$dest")"
            cp -n "$path" "$dest" 2>/dev/null || true
        done
done

# fscrypt/zstd/lz4 variants of the modules we care about are picked up by the
# `-n` copy above; compression libraries the kernel needs to decompress the
# squashfs image itself are not module options, so nothing else is required.

if [ -s /lib/modules/"$KVER"/modules.dep ] && [ -n "$(ls -A "$STAGE"/lib/modules 2>/dev/null)" ]; then
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

#!/usr/bin/env bash
#
# smoke-qemu.sh - boot the ISO in a throwaway VM and check that it comes up.
#
#   ./os/smoke-qemu.sh os/out/zmrig-os-6.36.0-x86-64-v3.iso
#   BOOT_TIMEOUT=900 ./os/smoke-qemu.sh image.iso     # slower emulation
#
# QEMU is given the image as a CD and the kernel is booted explicitly, so the
# test can add "nostart" to the command line and prove the image boots without
# mining on the machine running the test. The kernel and initramfs are extracted
# from the image itself -- testing a copy of the files is not testing the image.
set -euo pipefail

ISO="${1:?usage: smoke-qemu.sh image.iso}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-600}"
QEMU_MEM="${QEMU_MEM:-3072}"
HERE=$(cd -- "$(dirname -- "${0}")" && pwd)

command -v qemu-system-x86_64 >/dev/null || { echo "qemu-system-x86_64 not installed" >&2; exit 1; }
command -v xorriso >/dev/null || { echo "xorriso not installed" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "==> extracting the boot files from $ISO"
xorriso -osirrox on -indev "$ISO" \
    -extract /boot/vmlinuz "$WORK/vmlinuz" \
    -extract /boot/initramfs.gz "$WORK/initramfs.gz" \
    -extract /zmrig/rootfs.squashfs "$WORK/rootfs.squashfs" >/dev/null 2>&1 ||
    { echo "the image has no /boot/vmlinuz or no rootfs" >&2; exit 1; }

for f in vmlinuz initramfs.gz rootfs.squashfs; do
    [ -s "$WORK/$f" ] || { echo "$f is empty: the ISO is incomplete" >&2; exit 1; }
done

echo "==> booting (TCG if no /dev/kvm), timeout ${BOOT_TIMEOUT}s"
ACCEL="tcg"
[ -w /dev/kvm ] && ACCEL="kvm"

set +e
timeout "$BOOT_TIMEOUT" qemu-system-x86_64 \
    -machine q35,accel="$ACCEL" \
    -m "$QEMU_MEM" -smp 2 \
    -kernel "$WORK/vmlinuz" \
    -initrd "$WORK/initramfs.gz" \
    -append "console=ttyS0 quiet loglevel=3 zmrig.os.nostart=1 zmrig.os.wallet=46SQLW7DXaq6GJaQbHUFMAhd1VYpfQFJQ2gfZo9TCB8bf9vnf1MUwAD2Fwj6KMsY4RU3oKA3x6hByg8BKg7FfMWn6ysb5tJ" \
    -cdrom "$ISO" \
    -nographic -monitor none -no-reboot \
    > "$WORK/console.log" 2>&1
RC=$?
set -e

# A timeout is the expected ending: the image is a running appliance, not a
# program that exits. What matters is which markers appeared before it.
echo "==> console ($(wc -l < "$WORK/console.log") lines)"
sed -n '1,200p' "$WORK/console.log" | sed 's/^/    /'

ok=0
for marker in "ZMRIG-OS: root filesystem on" "ZMRIG-OS: huge pages" "ZMRIG-OS: ready"; do
    if grep -q "$marker" "$WORK/console.log"; then
        echo "    PASS  $marker"
    else
        echo "    FAIL  $marker"
        ok=1
    fi
done

# OpenRC reaching its default runlevel is the difference between "the kernel
# booted" and "the appliance booted".
if grep -qE "Started (ZMRIG|networking|chronyd)|Reached target|Welcome to Alpine" "$WORK/console.log"; then
    echo "    PASS  OpenRC started the default runlevel"
else
    echo "    WARN  no OpenRC marker seen (console may have been quiet)"
fi

if [ "$ok" != "0" ]; then
    echo "==> the image did not reach userspace (qemu exit $RC)" >&2
    exit 1
fi

echo "==> the image boots to userspace"

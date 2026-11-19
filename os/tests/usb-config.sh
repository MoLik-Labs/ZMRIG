#!/usr/bin/env sh
# Unit and scan-flow tests for USB JSON discovery, without root or hardware.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
. "$ROOT/os/usb-config.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

usb_path_is_usb '/sys/devices/pci0000:00/0000:00:14.0/usb1/1-2/block/sdb/sdb1' || fail 'USB sysfs path detection'
pass 'USB sysfs path is recognized'
if usb_path_is_usb '/sys/devices/pci0000:00/0000:00:17.0/ata1/host0/block/sda/sda1'; then
    fail 'non-USB devices are excluded'
fi
pass 'non-USB sysfs path is excluded'

# Exercise the actual partition scan with fake sysfs/dev nodes and a stub mount.
USB_SYS="$WORK/sys/devices/pci0000:00/usb1/1-2/block/sdb/sdb1"
ATA_SYS="$WORK/sys/devices/pci0000:00/ata1/host0/block/sda/sda1"
mkdir -p "$USB_SYS" "$ATA_SYS" "$WORK/sys/class/block" "$WORK/dev" "$WORK/ventoy" "$WORK/mnt"
printf '1\n' > "$USB_SYS/partition"
printf '1\n' > "$ATA_SYS/partition"
ln -s "$USB_SYS" "$WORK/sys/class/block/sdb1"
ln -s "$ATA_SYS" "$WORK/sys/class/block/sda1"
: > "$WORK/dev/sdb1"
: > "$WORK/dev/sda1"
printf '%s\n' '{"wallet":"ventoy"}' > "$WORK/ventoy/rig.json"
MOCK_FS=exfat
mount() {
    [ "$1" = -t ] && [ "$3" = -o ] || return 2
    printf '%s %s %s\n' "$2" "$4" "$5" >> "$WORK/mount.calls"
    [ "$2" = "$MOCK_FS" ] && [ "$5" = "$WORK/dev/sdb1" ] || return 1
    cp "$WORK/ventoy/rig.json" "$6/rig.json"
}
umount() { rm -f "$1/rig.json"; }

if usb_config_scan "$WORK/sys/class/block" "$WORK/dev" "$WORK/dev/sr0" "$WORK/mnt" "$WORK/scanned.json"; then :; else fail 'USB partition scan'; fi
[ "$USB_CONFIG_DEVICE" = "$WORK/dev/sdb1" ] || fail 'scan picked wrong device'
[ "$USB_CONFIG_FS" = exfat ] || fail 'scan did not recognize Ventoy exFAT'
[ "$USB_CONFIG_PATH" = rig.json ] || fail 'scan did not report chosen JSON'
[ "$(cat "$WORK/scanned.json")" = '{"wallet":"ventoy"}' ] || fail 'scan copied wrong JSON'
grep -q 'exfat ro,nosuid,nodev,noexec' "$WORK/mount.calls" || fail 'unsafe Ventoy mount options'
[ "$(wc -l < "$WORK/mount.calls")" -eq 1 ] || fail 'non-USB or boot device was mounted'
pass 'USB scan selects removable exFAT and imports the JSON'

# If exFAT, FAT or NTFS cannot mount, the loop must reach ext4 without journal
# replay. This also checks the explicit filesystem-probe order.
: > "$WORK/mount.calls"
MOCK_FS=ext4
if usb_config_scan "$WORK/sys/class/block" "$WORK/dev" "$WORK/dev/sr0" "$WORK/mnt" "$WORK/scanned-ext4.json"; then :; else fail 'filesystem fallback scan'; fi
[ "$USB_CONFIG_FS" = ext4 ] || fail 'ext4 fallback not selected'
grep -q 'ext4 ro,nosuid,nodev,noexec,noload' "$WORK/mount.calls" || fail 'ext4 fallback allows journal replay'
[ "$(wc -l < "$WORK/mount.calls")" -eq 4 ] || fail 'filesystem fallback order/count'
pass 'filesystem fallback reaches ext4 with journal replay disabled'

: > "$WORK/mount.calls"
if usb_config_scan "$WORK/sys/class/block" "$WORK/dev" "$WORK/dev/sdb1" "$WORK/mnt" "$WORK/bootdev.json"; then
    fail 'USB boot device should be excluded from rescanning'
fi
[ ! -s "$WORK/mount.calls" ] || fail 'boot device was remounted'
pass 'boot media is excluded from removable-media probing'

mkdir -p "$WORK/volume/zmrig"
printf '%s\n' '{"wallet":"primary"}' > "$WORK/volume/zmrig.json"
printf '%s\n' '{"wallet":"secondary"}' > "$WORK/volume/rig.json"
chosen=$(usb_config_copy "$WORK/volume" "$WORK/imported.json") || fail 'root JSON discovery'
[ "$chosen" = zmrig.json ] || fail 'documented filename priority'
cmp -s "$WORK/volume/zmrig.json" "$WORK/imported.json" || fail 'JSON copy content'
[ "$(stat -c %a "$WORK/imported.json")" = 600 ] || fail 'private copied profile permissions'
pass 'root-level Ventoy JSON is copied with private permissions'

rm -f "$WORK/volume/zmrig.json" "$WORK/volume/rig.json"
printf '%s\n' '{"wallet":"nested"}' > "$WORK/volume/zmrig/rig.json"
chosen=$(usb_config_copy "$WORK/volume" "$WORK/nested.json") || fail 'nested JSON discovery'
[ "$chosen" = zmrig/rig.json ] || fail 'nested profile path'
cmp -s "$WORK/volume/zmrig/rig.json" "$WORK/nested.json" || fail 'nested profile content'
pass 'ZMRIG/rig.json is recognized'

rm -f "$WORK/volume/zmrig/rig.json"
printf '%s\n' '{"wallet":"other-name"}' > "$WORK/volume/unrecognized.json"
if usb_config_copy "$WORK/volume" "$WORK/no-import.json" >/dev/null 2>&1; then
    fail 'unrecognized JSON names must not be imported'
fi
pass 'unrecognized JSON files are ignored'

# A USB symlink cannot point into the live root, and oversized payloads are
# rejected before they reach jq.
printf '%s\n' '{"wallet":"outside"}' > "$WORK/outside.json"
ln -s "$WORK/outside.json" "$WORK/volume/zmrig.json"
if usb_config_copy "$WORK/volume" "$WORK/symlink.json" >/dev/null 2>&1; then
    fail 'symlinked profiles must be ignored'
fi
rm -f "$WORK/volume/zmrig.json"
dd if=/dev/zero of="$WORK/volume/rig.json" bs=65537 count=1 2>/dev/null
if usb_config_copy "$WORK/volume" "$WORK/oversized.json" >/dev/null 2>&1; then
    fail 'oversized profiles must be ignored'
fi
pass 'symlinks and profiles over 64 KiB are rejected'

# Ensure the initramfs invokes this tested path and firstboot uses normal setup.
grep -q 'usb_config_scan /sys/class/block /dev' "$ROOT/os/init" || fail 'init calls the USB scanner'
grep -q 'for fs in exfat vfat ntfs3 ext4' "$ROOT/os/usb-config.sh" || fail 'Ventoy filesystem scan'
grep -q 'usb_path_is_usb' "$ROOT/os/usb-config.sh" || fail 'removable USB filtering'
grep -q 'ro,nosuid,nodev,noexec,noload' "$ROOT/os/usb-config.sh" || fail 'safe ext4 mount options'
grep -q 'setup --json "$USB_JSON"' "$ROOT/os/overlay/usr/local/lib/zmrig/firstboot.sh" || fail 'firstboot JSON import'
grep -q 'exfat ntfs3' "$ROOT/os/make-initramfs.sh" || fail 'filesystem drivers staged in initramfs'
pass 'initramfs and firstboot are wired to the tested USB importer'

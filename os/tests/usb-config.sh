#!/usr/bin/env sh
# Unit tests for read-only JSON discovery on Ventoy/removable filesystems.
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

mkdir -p "$WORK/volume/zmrig"
printf '{"wallet":"primary"}\n' > "$WORK/volume/zmrig.json"
printf '{"wallet":"secondary"}\n' > "$WORK/volume/rig.json"
chosen=$(usb_config_copy "$WORK/volume" "$WORK/imported.json") || fail 'root JSON discovery'
[ "$chosen" = zmrig.json ] || fail 'documented filename priority'
cmp -s "$WORK/volume/zmrig.json" "$WORK/imported.json" || fail 'JSON copy content'
[ "$(stat -c %a "$WORK/imported.json")" = 600 ] || fail 'private copied profile permissions'
pass 'root-level Ventoy JSON is copied read-only with safe permissions'

rm -f "$WORK/volume/zmrig.json" "$WORK/volume/rig.json"
printf '{"wallet":"nested"}\n' > "$WORK/volume/zmrig/rig.json"
chosen=$(usb_config_copy "$WORK/volume" "$WORK/nested.json") || fail 'nested JSON discovery'
[ "$chosen" = zmrig/rig.json ] || fail 'nested profile path'
cmp -s "$WORK/volume/zmrig/rig.json" "$WORK/nested.json" || fail 'nested profile content'
pass 'ZMRIG/rig.json is recognized too'

rm -f "$WORK/volume/zmrig/rig.json"
printf '{"wallet":"other-name"}\n' > "$WORK/volume/unrecognized.json"
if usb_config_copy "$WORK/volume" "$WORK/no-import.json" >/dev/null 2>&1; then
    fail 'unrecognized JSON names must not be imported'
fi
pass 'unrecognized JSON files are ignored'

# Neither a link into the live system nor an oversized payload may be copied.
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

# Assert the initramfs and first-boot hook are wired to the tested helper, and
# explicitly include the common Ventoy filesystems.
grep -q 'usb_config_copy /media' "$ROOT/os/init" || fail 'boot-media JSON import wiring'
grep -q 'usb_path_is_usb' "$ROOT/os/init" || fail 'removable USB filtering'
grep -q 'for usb_fs in exfat vfat ntfs3 ext4' "$ROOT/os/init" || fail 'Ventoy filesystem scan'
grep -q 'setup --json "$USB_JSON"' "$ROOT/os/overlay/usr/local/lib/zmrig/firstboot.sh" || fail 'firstboot JSON import'
grep -q 'exfat ntfs3' "$ROOT/os/make-initramfs.sh" || fail 'filesystem drivers staged in initramfs'
pass 'initramfs scans USB filesystems and firstboot imports the JSON'

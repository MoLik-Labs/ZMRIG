#!/bin/sh
# Helpers for importing a provisioning JSON file from removable media.
# The initramfs sources this file; tests source it on a normal host.

usb_path_is_usb() { # resolved sysfs path -> success only under a USB bus
    case "$1" in
        */usb[0-9]*/*) return 0 ;;
        *) return 1 ;;
    esac
}

usb_config_copy() { # mounted filesystem root, destination -> prints chosen relative path
    local source_root="$1" destination="$2" relative source_file size

    for relative in zmrig.json rig.json wallet.json config.json \
                    zmrig/rig.json zmrig/wallet.json zmrig/config.json; do
        source_file="${source_root}/${relative}"
        # USB contents are untrusted: do not follow links out of the mounted
        # volume, and bound the bytes jq will later parse.
        case "$relative" in
            zmrig/*) [ -d "${source_root}/zmrig" ] && [ ! -L "${source_root}/zmrig" ] || continue ;;
        esac
        [ -f "$source_file" ] && [ ! -L "$source_file" ] || continue
        size=$(wc -c < "$source_file" 2>/dev/null | tr -d '[:space:]')
        case "$size" in ''|*[!0-9]*) continue ;; esac
        [ "$size" -gt 0 ] && [ "$size" -le 65536 ] || continue
        if cp "$source_file" "$destination" 2>/dev/null; then
            chmod 600 "$destination" 2>/dev/null || true
            printf '%s' "$relative"
            return 0
        fi
    done
    return 1
}

usb_config_scan() { # sys_block_root dev_root boot_device mountpoint destination
    local sys_root="$1" dev_root="$2" boot_device="$3" mountpoint="$4"
    local destination="$5" sysdev name dev realpath fs mount_opts relative

    USB_CONFIG_DEVICE=""
    USB_CONFIG_FS=""
    USB_CONFIG_PATH=""

    for sysdev in "$sys_root"/*; do
        [ -e "$sysdev" ] || continue
        [ -r "$sysdev/partition" ] || continue
        name=$(basename "$sysdev")
        dev="${dev_root}/${name}"
        [ "$dev" = "$boot_device" ] && continue
        [ -e "$dev" ] || continue
        realpath=$(readlink -f "$sysdev" 2>/dev/null || true)
        usb_path_is_usb "$realpath" || continue

        for fs in exfat vfat ntfs3 ext4; do
            # Never execute binaries or device nodes from provisioning media.
            # noload also prevents ext4 journal replay on the source stick.
            case "$fs" in
                ext4) mount_opts=ro,nosuid,nodev,noexec,noload ;;
                *)    mount_opts=ro,nosuid,nodev,noexec ;;
            esac
            if mount -t "$fs" -o "$mount_opts" "$dev" "$mountpoint" 2>/dev/null; then
                relative=$(usb_config_copy "$mountpoint" "$destination" 2>/dev/null || true)
                umount "$mountpoint" 2>/dev/null || true
                if [ -n "$relative" ]; then
                    USB_CONFIG_DEVICE="$dev"
                    USB_CONFIG_FS="$fs"
                    USB_CONFIG_PATH="$relative"
                    return 0
                fi
            fi
        done
    done
    return 1
}

#!/usr/bin/env bash
# Shared by the image builder and its no-root regression tests.
# Stage exactly one initramfs codec and remove only stale alternatives.
stage_initramfs() { # source boot-dir gz|zst
    local source="$1" boot_dir="$2" codec="$3" destination

    case "$codec" in
        gz|zst) ;;
        *) printf 'unsupported initramfs codec: %s\n' "$codec" >&2; return 2 ;;
    esac

    if [ ! -s "$source" ]; then
        printf 'initramfs source is missing or empty: %s\n' "$source" >&2
        return 1
    fi

    mkdir -p "$boot_dir" || return 1
    destination="${boot_dir}/initramfs.${codec}"

    # Remove stale files before copying. Deleting initramfs.gz after the copy
    # silently made gzip-fallback images unbootable while GRUB still requested
    # /boot/initramfs.gz.
    rm -f "${boot_dir}/initramfs.gz" "${boot_dir}/initramfs.zst" || return 1
    cp -- "$source" "$destination" || return 1

    if [ ! -s "$destination" ]; then
        printf 'staged initramfs is missing or empty: %s\n' "$destination" >&2
        return 1
    fi
}

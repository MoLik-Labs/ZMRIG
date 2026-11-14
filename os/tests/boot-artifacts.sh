#!/usr/bin/env bash
# Reproduce the two codec branches without an ISO toolchain or root privileges.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
source "${ROOT}/os/stage-initramfs.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

mkdir -p "${WORK}/boot"
printf 'gzip initramfs bytes\n' > "${WORK}/input.gz"
printf 'stale zstd image\n' > "${WORK}/boot/initramfs.zst"
if ! stage_initramfs "${WORK}/input.gz" "${WORK}/boot" gz; then
    fail 'stage gzip fallback'
fi
cmp -s "${WORK}/input.gz" "${WORK}/boot/initramfs.gz" || fail 'gzip payload preserved'
[ ! -e "${WORK}/boot/initramfs.zst" ] || fail 'stale zstd removed'
pass 'gzip initramfs survives staging cleanup'

printf 'zstd initramfs bytes\n' > "${WORK}/input.zst"
printf 'stale gzip image\n' > "${WORK}/boot/initramfs.gz"
if ! stage_initramfs "${WORK}/input.zst" "${WORK}/boot" zst; then
    fail 'stage zstd initramfs'
fi
cmp -s "${WORK}/input.zst" "${WORK}/boot/initramfs.zst" || fail 'zstd payload preserved'
[ ! -e "${WORK}/boot/initramfs.gz" ] || fail 'stale gzip removed'
pass 'zstd initramfs survives staging cleanup'

if stage_initramfs "${WORK}/missing" "${WORK}/boot" gz >/dev/null 2>&1; then
    fail 'missing source must fail'
fi
if stage_initramfs "${WORK}/input.gz" "${WORK}/boot" lz4 >/dev/null 2>&1; then
    fail 'unsupported codec must fail'
fi
pass 'invalid staging inputs fail closed'

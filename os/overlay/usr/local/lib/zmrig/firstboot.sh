#!/bin/sh
# Prints the setup prompt on the physical console when the rig has no wallet.
# Does nothing -- and exits -- on a rig that is already configured, so the
# service leaves no trace after the first boot.
set -eu

CONF=/etc/zmrig/os.conf

if [ -f "$CONF" ] && grep -q '^WALLET="..*"' "$CONF"; then
    exit 0
fi

# A rig configured from the kernel command line has no os.conf yet, and must not
# be asked to type its wallet again on every boot.
if [ -f /etc/zmrig/kernel.conf ] && grep -q '^WALLET="..*"' /etc/zmrig/kernel.conf; then
    exit 0
fi

CONSOLE=/dev/tty1
[ -w "$CONSOLE" ] || CONSOLE=/dev/console

{
    clear 2>/dev/null || true
    cat /etc/zmrig/banner.txt 2>/dev/null || true
    printf '\nNo wallet configured yet.\n\n'
} > "$CONSOLE" 2>&1

exec /usr/local/bin/zmrig-os setup < "$CONSOLE" > "$CONSOLE" 2>&1

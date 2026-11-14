#!/bin/sh
# Prints the setup prompt on the physical console when the rig has no wallet.
# Does nothing -- and exits -- on a rig that is already configured, so the
# service leaves no trace after the first boot.
set -eu

CONF=/etc/zmrig/os.conf
STAMP=/etc/zmrig/.identity-shown

# The Device ID is the first thing an owner needs, and it is on the machine, not
# in a manual: printed once, on the console, before anything else asks for
# anything. A rig with a wallet and a fleet URL is not asked again.
if [ ! -f "$STAMP" ]; then
    if ID=$(/usr/local/bin/zmrig-os id 2>/dev/null); then
        CONSOLE=/dev/tty1
        [ -w "$CONSOLE" ] || CONSOLE=/dev/console
        printf '\n%s\n\n' "$ID" > "$CONSOLE" 2>&1 || true
        : > "$STAMP" 2>/dev/null || true
    fi
fi

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

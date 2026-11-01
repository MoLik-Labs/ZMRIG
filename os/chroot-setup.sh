#!/bin/sh
# chroot-setup.sh - runs *inside* the Alpine root filesystem, as root, with the
# network available. Everything that needs a package manager happens here so the
# host script stays a plain orchestrator.
#
# Arguments: /tmp/chroot-setup.sh <kernel-package> <channel>
set -eu

KERNEL_PKG="${1:-linux-lts}"
CHANNEL="${2:-stable}"

export PATH=/sbin:/bin:/usr/sbin:/usr/bin
export HOME=/root

say() { printf '\n==> %s\n' "$*"; }

# ---------------------------------------------------------------- packages
say "installing packages (${KERNEL_PKG})"

apk update --no-progress

# alpine-base pulls openrc and the boot runlevel scripts. The rest is the
# smallest set that makes an unattended rig possible: a kernel with modules,
# a time source (TLS handshakes and pool logins both fail on a wrong clock), an
# ssh server so the rig never needs a keyboard, curl for the updater, e2fsprogs
# for the persistence partition and pciutils for the doctor.
apk add --no-progress --no-cache \
    alpine-base \
    "${KERNEL_PKG}" \
    openrc \
    busybox \
    kmod \
    e2fsprogs \
    util-linux \
    curl \
    ca-certificates \
    chrony \
    openssh \
    pciutils \
    ifupdown-ng \
    dhcpcd

# A static busybox is what the initramfs runs on. It is a separate package on
# some Alpine releases and a file inside the main package on others, so this is
# best effort and make-initramfs.sh handles both cases.
apk add --no-progress --no-cache busybox-static >/dev/null 2>&1 || true

# The kernel package is the only one whose version string matters later; record
# it where the host script can read it without guessing file names.
KVER=$(ls /lib/modules | head -1)
printf '%s\n' "$KVER" > /tmp/chroot-kver

say "kernel modules: $KVER"

# ---------------------------------------------------------------- identity
printf 'zmrig-os\n' > /etc/hostname
cat > /etc/hosts <<'EOF'
127.0.0.1   localhost zmrig-os
::1         localhost
EOF

# Root is locked for passwords on purpose: the console has an autologin shell
# (physical access is already root) and ssh accepts keys only.
sed -i 's/^root:.*/root:!::0:::::/' /etc/shadow 2>/dev/null || true

mkdir -p /root/.ssh /etc/ssh
chmod 700 /root/.ssh

# ---------------------------------------------------------------- networking
# DHCP on the first wired interface. ifupdown-ng reads this file; dhcpcd is the
# fallback for images where ifupdown-ng is not the active provider.
cat > /etc/network/interfaces <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

rc-update add networking boot >/dev/null 2>&1 || true

# ---------------------------------------------------------------- services
say "enabling services"

for svc in bootmisc hostname hwdrivers modules sysctl syslog networking chronyd sshd; do
    [ -x "/etc/init.d/$svc" ] && rc-update add "$svc" default >/dev/null 2>&1 || true
done

rc-update add devfs sysinit  >/dev/null 2>&1 || true
rc-update add dmesg sysinit  >/dev/null 2>&1 || true
rc-update add mdev  sysinit  >/dev/null 2>&1 || true
rc-update add hwclock boot  >/dev/null 2>&1 || true

# SSH: keys only. A rig that accepts passwords is a rig that ends up in a
# botnet, and the console is already available to whoever can touch the machine.
cat > /etc/ssh/sshd_config.d/zmrig.conf <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
X11Forwarding no
AllowAgentForwarding no
ClientAliveInterval 60
ClientAliveCountMax 3
EOF

ssh-keygen -A >/dev/null 2>&1 || true

# chrony: a pool login over TLS fails with a skew of minutes, and a VM resumed
# from a snapshot starts with an arbitrary clock.
cat > /etc/chrony/chrony.conf <<'EOF'
# Four sources, no local stratum: this machine has no business serving time.
pool pool.ntp.org iburst maxsources 4
makestep 1.0 3
rtcsync
EOF

# Console autologin on tty1 only; tty2..6 stay a normal login prompt.
if grep -q '^tty1::' /etc/inittab 2>/dev/null; then
    sed -i 's|^tty1::.*|tty1::respawn:/sbin/getty -n -l /bin/sh -L tty1 38400 vt100|' /etc/inittab
fi

# ---------------------------------------------------------------- accounts
# doas rather than sudo: one binary, no PAM stack, and the only user is root.
printf 'permit persist :wheel\n' > /etc/doas.d/doas.conf 2>/dev/null || true

passwd -l root >/dev/null 2>&1 || true

# ---------------------------------------------------------------- tidy
# Nothing in the image should be able to pull a package at runtime: an appliance
# that installs things is an appliance whose state nobody can reproduce.
rm -rf /var/cache/apk/* /tmp/* 2>/dev/null || true
mkdir -p /var/cache/apk

printf 'channel=%s\n' "$CHANNEL" > /etc/zmrig/channel

say "chroot setup done"

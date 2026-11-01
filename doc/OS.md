# The appliance image (ZMRIG OS)

`os/` builds a bootable image: a kernel, a tiny initramfs, and a read-only
Alpine root filesystem with `zmrig`, its control tool and nothing else running.
Boot it on a rig, answer one question (the wallet), and the machine hashes until
you tell it to stop. Nothing is installed to a disk and nothing on the stick is
modified, so one stick can set up a hundred machines and a mistaken boot leaves
no trace.

This file is the operator manual. The user-facing page is
`site/docs/appliance/iso.md` (and its Vietnamese twin).

## Why an image

Everything in `doc/PERFORMANCE.md` that is not the hash loop is a system
setting: 2 MiB pages, the transparent-hugepage policy, the CPU governor,
swappiness, the write-back throttle, the NMI watchdog, and whether something
else on the machine is using a core. On a general-purpose distribution every one
of those is a fight — a `sysctl` file here, a systemd unit there, a package that
overwrites both on the next upgrade. An image makes them the operating system's
job instead of the operator's:

| Setting | General distribution | ZMRIG OS |
| --- | --- | --- |
| 2 MiB pages | reserve by hand, lost on reboot | reserved by the initramfs, before userspace |
| THP policy | distro default (`madvise` on Debian) | `always` in the max entries, set on the cmdline |
| CPU governor | `schedutil`/`powersave` | `performance`, in the tune step that runs before the miner |
| swappiness, dirty ratios | installed defaults | `/etc/sysctl.d/99-zmrig.conf`, documented line by line |
| NMI watchdog | on | off |
| What else runs | a desktop, an indexer, a snap daemon | OpenRC, sshd, chrony, the miner |
| Crash recovery | nothing | supervisor + health restart + reboot after five failures |
| Updates | `apt upgrade` changes the kernel under the miner | verified binary swap inside the running image |

## What is in it

- **Kernel**: Alpine `linux-lts` (override with `--kernel linux-virt` for VMs).
- **Initramfs**: busybox plus the ~30 modules needed to find the media
  (loop, squashfs, overlay, isofs, sr_mod, sd_mod, usb-storage, ahci, nvme,
  virtio, ext4, vfat). No network in the initramfs: nothing to fetch, nothing to
  fail.
- **Root filesystem**: Alpine with `alpine-base`, `openrc`, `kmod`, `e2fsprogs`,
  `util-linux`, `curl`, `ca-certificates`, `chrony`, `openssh`, `pciutils`,
  `ifupdown-ng`, `dhcpcd`. `zmrig` is a **static musl binary** built by
  `zmrig/build.sh --static`, so the miner cannot be broken by a libc update and
  the same file runs on any distribution.
- **Services**: `zmrig` (the miner, via `zmrig-os run`), `zmrig-firstboot` (the
  wizard on the console when no wallet is configured), `networking`, `chronyd`,
  `sshd`, `syslog`, `mdev`/`hwdrivers`.
- **Layout**: `rootfs.squashfs` and `os.conf.example` live under `/zmrig` on the
  media; the initramfs mounts the squashfs read-only and puts a tmpfs over it.

## Boot sequence

```
GRUB (BIOS or UEFI)
  └─ kernel + initramfs.gz
       ├─ mount proc, sys, devtmpfs; load the storage modules
       ├─ find the media (ISO9660, vfat or ext4) that carries /zmrig/rootfs.squashfs
       ├─ reserve 2 MiB pages now, while memory is still one block   <-- +4-6 %
       ├─ mount squashfs read-only, stack tmpfs over it
       ├─ read the config: image → media → ZMRIGDATA → kernel command line
       └─ switch_root → OpenRC
            ├─ sysctl, networking, chronyd
            ├─ zmrig-firstboot (only when there is no wallet)
            └─ zmrig → `zmrig-os run` → supervisor → `zmrig …`
```

The page reservation happens before `switch_root` on purpose: on a rig that has
been up for a week the kernel cannot find 1168 contiguous 2 MiB pages any more,
and the miner silently falls back to transparent huge pages. Reserving at boot
is the difference between 814 H/s and 786 H/s on the machine in
`doc/PERFORMANCE.md`, and it costs nothing.

## Modes

`zmrig-os mode <name>` rewrites the config and restarts the miner. The kernel
command line (`zmrig.os.mode=`) does the same for the next boot, and there are
five GRUB entries so a machine with no network and no keyboard can still be
changed.

| Mode | Threads | Priority | Profile | THP | For |
| --- | --- | --- | --- | --- | --- |
| `max` | cache-aware, all cores | 5 | free | `always` | the default: highest hashrate |
| `balanced` | cores − 1 (4+ cores) | 3 | free | `always` | still ssh-able during a full load |
| `eco` | half the cores | 1 | watt | `madvise` | quiet, cool, best hashrate per watt |
| `light` | all cores, 256 MiB cache | 2 | free | `always` | under 2.5 GiB of RAM, ~10× slower |

On a two-core machine `balanced` deliberately behaves like `max`: there is no
core to spare, and pretending otherwise would just cost hashrate.

## Measuring this machine

The thread count is the one number that differs per machine, and the cache
heuristic behind it assumes 2 MiB of L3 per thread — right for a stock Ryzen,
wrong for a small or uneven cache. The image can measure it instead:

```bash
zmrig-os autotune 8        # 8 s per candidate, then pin the winner in os.conf
```

It reuses the current mode, drops `-t`, runs `zmrig --autotune`, prints the table
and stores `autotune-best-threads` in the config. `THREADS="auto"` goes back to
the heuristic. This is the only place where a number is chosen from a
measurement on your hardware rather than from a table in the documentation.

## Configuration

`/etc/zmrig/os.conf` is a `KEY="value"` file; the tool never `source`s it, so a
config file cannot execute anything as root.

| Key | Default | Meaning |
| --- | --- | --- |
| `WALLET` | — | Monero address (validated: 95/106 chars, base58, 4/8 prefix) |
| `POOL` | `gulf.moneroocean.stream:10001` | pool `host:port` |
| `WORKER` | hostname | rig name in the pool's dashboard |
| `MODE` | `max` | `max`/`balanced`/`eco`/`light` |
| `ALGO` | `auto` | `auto` advertises every RandomX variant; or pin one |
| `THREADS` | `auto` | force `-t N` |
| `DONATE` | `1` | the developer fee, 0–10 |
| `MSR` | `auto` | `on`/`off`; `auto` uses it only on bare metal as root |
| `API_PORT` | `0` | `zmrig`'s HTTP API for external monitoring (off by default) |
| `API_HOST` | `127.0.0.1` | bind address for that API — `0.0.0.0` only with a token |
| `API_TOKEN` | — | `Authorization: Bearer` value the API then requires |
| `AUTO_REBOOT` | `1` | reboot after five failed starts in a row |
| `CHANNEL` | `stable` | which update channel to follow |
| `EXTRA_ARGS` | — | anything else, verbatim |

Precedence, lowest to highest: the image, `/zmrig/os.conf` on the media, the
`ZMRIGDATA` partition, `/etc/zmrig/kernel.conf` (written from the kernel command
line).

## Kernel command line

```
zmrig.os.wallet=4...          wallet, skips the wizard
zmrig.os.pool=host:port       pool
zmrig.os.worker=rig-01        worker name
zmrig.os.mode=max|balanced|eco|light
zmrig.os.hugepages=N          0 disables the reservation
zmrig.os.data=/dev/sdX1       partition that keeps the config
zmrig.os.debug=1              shell in the initramfs instead of the miner
zmrig.os.nostart=1            boot, but do not mine
```

A fleet is re-pointed by editing one GRUB line, or by pressing `e` once at the
menu.

## Persistence

The image is read-only, so `/etc/zmrig` (and `/root/.ssh`) live in RAM and are
gone after a reboot. Two ways to keep them:

```bash
# a small partition on the same stick, formatted and labelled ZMRIGDATA
zmrig-os persist /dev/sdb1
```

or pass every value on the kernel command line. The initramfs looks for a
partition labelled `ZMRIGDATA`, mounts it, and copies `etc/zmrig/os.conf` and
`root/.ssh/authorized_keys` into the new root.

## Updates

Three different things, deliberately separate:

```bash
zmrig-os update --check        # what version is published for this channel+arch
zmrig-os update --apply        # download the static binary, verify sha256, swap it in
zmrig-os update --iso --write /dev/sdb1   # download and flash a new image
```

`--apply` is a 19 MB download, replaces the binary inside the running overlay,
and is gone at the next reboot — which is exactly the rollback story: reboot and
you are on the version baked into the image. `--iso` never writes the device the machine booted from (`/etc/zmrig/bootdev`,
written by the initramfs).

Images are built per instruction level (`x86-64-v3` needs AVX2, `x86-64-v2`
runs on everything since Nehalem) and the updater asks for the level the image
was compiled for: `/etc/zmrig/arch` is written at build time, and a v3 binary on
a v2 CPU would be an illegal instruction, not a slower hash.

Channels: `stable` for master releases, `beta` for the rolling `os-beta`
pre-release. A release carries, per architecture, the ISO, its `.sha256`, and
`zmrig-os-<channel>-<arch>.json`, which is the manifest `zmrig-os update` reads.

## Security model

- **Console** is an autologin root shell on `tty1` (the wizard needs it). Physical
  access is already root on a mining rig; the trade is deliberate and it is the
  reason the next two points exist.
- **SSH** is key-only: `PermitRootLogin prohibit-password`, no password auth, no
  keyboard-interactive. `zmrig-os ssh-key add` installs a key; `rc-service sshd
  start`.
- **No package manager at runtime**: packages come from the image build, so what
  is running is what was built.
- **Updates are verified**: sha256 from the manifest, checked before the binary
  is moved into place; a mismatch leaves the old binary untouched and the update
  fails loudly.
- **The fee is visible**: 1 % of Monero time, printed in `--check`, in the
  banner, and in `zmrig-os status`; `zmrig-os setup --donate 0` disables it.

## Building it

```bash
sudo ./os/deps.sh                      # xorriso, mtools, grub, squashfs-tools, qemu
sudo ./os/build-iso.sh                 # x86-64-v3 → os/out/
sudo ./os/build-iso.sh --arch x86-64-v2
sudo ./os/build-iso.sh --smoke         # build, then boot it in QEMU
./os/build-iso.sh --self-check         # no root, no network: files and syntax
./os/build-iso.sh --plan               # what the build would do
```

The build is four steps: fetch the Alpine minirootfs (cached in
`/tmp/zmrig-os-build/cache`), build the static binary, `apk add` inside a chroot,
then assemble squashfs + initramfs + ISO with `grub-mkrescue`. It needs no GPU,
no KVM and no secrets.

`os/smoke-qemu.sh` extracts the kernel and initramfs **from the image**, boots
them with the image as a CD, and fails unless `ZMRIG-OS: ready` appears on the
serial console. That is what runs in CI, so "the image builds" is not the claim;
"the image boots" is.

## CI

The workflow is `os/ci/appliance.yml`, installed as `.github/workflows/os.yml`:

```bash
mkdir -p .github/workflows
cp os/ci/appliance.yml .github/workflows/os.yml
git add .github/workflows/os.yml && git commit -m "ci: build the appliance" && git push
```

It is kept outside `.github/workflows/` because installing a workflow file needs
a token with the `workflows` scope, and the automation account used to write the
rest of this repository does not have it. Everything else — the build, the
self-check, the QEMU boot test and the control tests — runs from a shell without
it.

Once installed, it does this:

1. `shellcheck -s error` over every script, then `os/tests/control.sh` (66
   checks, no root needed).
2. Builds `x86-64-v3` and `x86-64-v2` in parallel.
3. Boots the v3 image in QEMU and reads the serial console.
4. Publishes: pushes to `master` create or refresh the release for the version in
   `zmrig/src/main.zig`; pushes to `BETA` refresh the `os-beta` pre-release; tags
   publish a stable release. Every past version stays downloadable.

The image is rebuilt by the same workflow whenever `os/`, `zmrig/` or
`scripts/tune-linux.sh` change, so an ISO is never older than the code it ships.

## Troubleshooting

| Symptom | Where to look |
| --- | --- |
| `FATAL: no ZMRIG root filesystem found` | the stick was written with something other than `dd`/Etcher, or the machine cannot see the drive (add `zmrig.os.debug=1` and check `ls /dev`) |
| console shows GRUB, then nothing | the entry needs `console=ttyS0` for headless; on a TV check the cable, not the image |
| boots but never mines | `zmrig-os status`, then `zmrig-os logs 100`, then `zmrig-os doctor` |
| "no wallet configured; waiting" | the wizard had no console; set `zmrig.os.wallet=` or run `zmrig-os setup` |
| hashrate below the table | `zmrig-os doctor` — THP policy, page reservation, and governor are the three lines that matter |
| update fails | `zmrig-os update --check`; a checksum failure is reported and the binary is left alone |

## What this does not do

- No GPU. RandomX on a video card is a different project.
- No overclocking. Memory timings and voltage are firmware's job and a
  distribution should not pretend otherwise.
- No MSR inside a VM. The hypervisor rejects the write and the miner stays on
  the portable path; `zmrig-os doctor` says so instead of failing.
- No telemetry, no phone-home, no account.

# The appliance image (ZMRIG OS)

`os/` builds a bootable image: a kernel, a tiny initramfs, and a read-only
Alpine root filesystem with `zmrig`, its control tool and nothing else running.
Boot it on a rig, answer one question (the wallet), and the machine hashes until
you tell it to stop. Nothing is installed to a disk and nothing on the stick is
modified, so one stick can set up a hundred machines and a mistaken boot leaves
no trace.

The same image also **installs** itself onto a disk, which is the form to use
when the rig has one:

```bash
zmrig-os install --disk /dev/nvme0n1          # or --dry-run first
```

See [Install to disk](#install-to-disk) and [Updates](#updates).

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

## What it is built from

| | |
| --- | --- |
| base | **Alpine Linux** `latest-stable` — `3.22.x` today — x86_64, musl, OpenRC |
| kernel | `linux-lts` (`6.12.x`), `linux-virt` for a VM (`--kernel`) |
| root filesystem | squashfs, **zstd level 19**, 1 MiB blocks, read-only |
| initramfs | busybox + ~30 modules, zstd when the kernel's own config says `CONFIG_RD_ZSTD=y`, gzip otherwise |
| boot | GRUB, BIOS and UEFI, both loaders built with the image |

That table is a fact about the running image, not about this file: the build
writes it to `/etc/zmrig/base` and `zmrig-os version` prints it, so a bug report
can say which base it came from. `./os/upstream.sh` prints the same table from
the source, plus what the published images were built on.

zstd at level 19 rather than the default 15, and a zstd initramfs rather than
gzip, are worth 5.4 MB per image: the artifact CI uploads went from 155.93 MB to
150.56 MB (`x86-64-v3`) and 155.85 MB to 150.47 MB (`x86-64-v2`) across the same
two-architecture build. zstd decompresses at the same speed at every level — the
level costs build time and nothing on the rig.

The Alpine version is `latest-stable` rather than a pinned one so the weekly
build picks up point releases and security fixes without anybody remembering to
edit a number. What that costs is the reverse question — *did anything actually
change?* — and `os/upstream.sh --check` answers it by comparing the resolved
version with the `alpine` field inside the last published manifest.

## What is in it

- **Kernel**: Alpine `linux-lts` (override with `--kernel linux-virt` for VMs).
- **Initramfs**: busybox plus the ~30 modules needed to find the media
  (loop, squashfs, overlay, isofs, sr_mod, sd_mod, usb-storage, ahci, nvme,
  virtio, ext4, vfat). No network in the initramfs: nothing to fetch, nothing to
  fail.
- **Root filesystem**: Alpine with `alpine-base`, `openrc`, `kmod`, `e2fsprogs`,
  `dosfstools` (the installer's EFI partition), `util-linux` (`sfdisk` is the only
  real GPT writer in the image), `curl`, `ca-certificates`, `chrony`, `openssh`,
  `ifupdown-ng`, `dhcpcd`. `zmrig` is a **static musl binary** built by
  `zmrig/build.sh --static`, so the miner cannot be broken by a libc update and
  the same file runs on any distribution.
- **Sized deliberately**: `/boot/initramfs-lts` (the package's 171 MB initramfs,
  which this image never reads) is deleted, `/lib/firmware` keeps only what a
  wired rig loads (`rtl_nic`, `bnx2`, `bnx2x`, `tg3`, `intel/ice`, microcode —
  660 MB becomes 16 MB), and `sound`, `media`, `gpu`, `infiniband`, `isdn`, `wan`,
  `can`, `iio`, `staging`, `nfc`, `bluetooth` and `thunderbolt` modules are
  deleted with `depmod` rebuilt. Measured: rootfs 1122 → 180 MB, ISO 1081 →
  158 MB. `--firmware all` keeps the whole set for an unusual NIC, and the build
  prints a size report every run (`dist/size-report.txt`, posted on the PR).
- **Services**: `zmrig` (the miner, via `zmrig-os run`), `zmrig-firstboot` (the
  wizard on the console when no wallet is configured), `crond` (the daily update
  job), `networking`, `chronyd`, `sshd`, `syslog`, `mdev`/`hwdrivers`. The miner
  service *uses* networking, DNS and the clock rather than needing them: it starts
  with the filesystem and stratum reconnects, so a DHCP lease is no longer on the
  critical path to the first share.
- **Layout**: `rootfs.squashfs` (or `rootfs-a/b.squashfs` on an installed disk),
  `os.conf.example`, `boot/` with the kernel, the initramfs and the three GRUB
  images. The initramfs mounts the squashfs read-only, puts a tmpfs over it, and
  bind-mounts the boot medium at `/media` so the guest can keep state.

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

## Install to disk

`zmrig-os install --disk /dev/sdX` writes the running image onto a disk:

| Partition | Size | Contents |
| --- | --- | --- |
| 1 BIOS boot | 1 MiB | `core.img` — only read by a machine that boots in BIOS mode |
| 2 EFI | 100 MiB | `BOOTX64.EFI` in `EFI/BOOT/` |
| 3 root | rest, ext4, label `ZMRIGROOT` | `boot/vmlinuz-a`, `boot/initramfs-a.gz`, `zmrig/rootfs-a.squashfs`, `etc/zmrig/os.conf`, `boot/grub/grub.cfg` |

The two GRUB images are **built with the ISO** (`grub-mkimage`, in
`build-iso.sh`) and travel inside it, so the install needs no `grub-install`, no
package manager and no network. Both are standalone: their early config searches
for the `ZMRIGROOT` label and hands over to `/boot/grub/grub.cfg`, which is why
adding a second disk does not stop the rig from booting.

Order of operations, and why each one is where it is:

1. `wipefs`, `sfdisk` (GPT), `mkfs.vfat`, `mkfs.ext4` — the target is
   unrecognisable from this point on, so every input is validated first.
2. copy kernel, initramfs, squashfs; write `grub.cfg` and the environment block;
   write `os.conf` from the running configuration.
3. `sync`, unmount, then `dd` `boot.img` into the first 512 bytes and `core.img`
   at sector 2048.
4. mount the new root **read-only and hash the squashfs** against the source. A
   truncated copy fails here instead of after the reboot.
5. optionally `--autotune` the thread count on the machine that is going to run
   it, and write the winner into the installed config.

`--dry-run` prints the partition script, the files and the boot sector offsets and
changes nothing. What it prints comes from the same functions the real run calls
(`partition_script`, `install_plan`), so the plan cannot drift from the code.

Unattended: `zmrig.os.install=/dev/nvme0n1` on the kernel command line. `zmrig-os
boot` installs, `sync`s and reboots before it starts mining.

### A/B slots and rollback

Two root filesystems live side by side on the root partition, and GRUB picks one
by `--id` from a **1024-byte environment block** at `/boot/grub/grubenv`. The
initramfs and `zmrig-os` write that block in shell (header, `zmrig_slot=X`, `#`
padding) because the guest deliberately has no `grub-editenv`.

The initramfs keeps a counter on the boot medium: incremented on every boot of an
installed system, reset by the supervisor once the miner has been up for five
minutes. Three boots that never got that far flip the machine to the other slot,
write the environment block and reboot.

## Updates

Installed rigs run `/etc/periodic/daily/zmrig-auto` from busybox `crond`:

| What | Where it goes | Rollback |
| --- | --- | --- |
| the miner binary | `<medium>/zmrig/bin/zmrig-<version>`, `current` a symlink | the previous file is kept; the image's own binary is still there |
| the OS image (`AUTO_IMAGE=1`) | the other slot, verified before it becomes the default | three failed boots, or `zmrig-os slot <other>` |

`AUTO_UPDATE=0` disables both. An unreachable manifest is treated as offline —
the job exits 0 and the rig keeps mining, because a rig behind a firewall is
normal and a support ticket every morning is not.

The miner is *not* updated into `/usr/local/bin`: that directory is the tmpfs
overlay, so the change would last until the next reboot. "Reboot to roll back" is
honest for a live stick and wrong for an appliance.

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
| `safe` | cores − 1 (4+ cores) | 19 (nice) | watt | `always` | a machine that must not break |
| `light` | all cores, 256 MiB cache | 2 | free | `always` | under 2.5 GiB of RAM, ~10× slower |

On a two-core machine `balanced` deliberately behaves like `max`: there is no
core to spare, and pretending otherwise would just cost hashrate.

### `safe`: the machine survives the mode

Every other mode answers "how fast can this box go". `safe` answers "how fast can
it go for months". It leaves one core for the OS and the fan controller, drops to
the lowest scheduling priority there is (nice 19, which nothing else in this
image competes with), never writes the MSR registers, and arms the miner's
thermal governor — `--max-temp`, default 72 °C, `zmrig-os mode safe 68` to change
it.

The governor reads the hottest CPU sensor once a second and moves the thread
count, not the clock:

| reading | action | at most |
| --- | --- | --- |
| below 72 °C | nothing | — |
| at 72 °C | park one thread | every 30 s |
| at 80 °C (target + 8) | park one thread | every 5 s |
| at 87 °C (target + 15) | stop hashing | until it is below 65 °C |
| below 67 °C for two minutes | start one thread again | every 30 s |

A parked thread keeps its VM, the dataset stays in RAM and the pool connection
stays open, so a pause costs the shares that were not computed and nothing else.
`zmrig-os status` prints the current reading next to the mode, and the miner logs
every change with the sensor name, because "which sensor was at 84 °C" is the
question asked six months later.

Only CPU sensors are read (`coretemp`, `k10temp`, `zenpower`, `cpu_thermal`,
`acpitz`, Super I/O), so a warm NVMe never costs a thread. A machine with no
sensor at all says so once and keeps the thread count it was given.

## Measuring this machine

The thread count is the one number that differs per machine, and the cache
heuristic behind it assumes 2 MiB of L3 per thread — right for a stock Ryzen,
wrong for a small or uneven cache. The image can measure it instead:

```bash
zmrig-os autotune 8        # 8 s per candidate, then pin the winner in os.conf
```

It reuses the current mode, drops `-t`, tunes the machine first (huge pages, THP,
governor — measuring an untuned box answers the wrong question), runs
`zmrig --autotune`, prints the table and stores `autotune-best-threads` in the
config. `THREADS="auto"` goes back to the heuristic. This is the only place where
a number is chosen from a measurement on your hardware rather than from a table
in the documentation.

**It also happens by itself.** On a rig that has never been measured,
`THREADS="auto"` and `AUTO_AUTOTUNE=1` (the default), the supervisor starts
mining immediately and, 90 seconds later, measures the machine while it mines.
When the answer is in it writes the thread count and reloads the miner — one
restart, no reboot, and the rig was never idle waiting for a benchmark. A reload
is not counted as a crash, so a healthy rig is not walked towards the
five-failures-then-reboot limit by its own tuning.

```
threads        auto (the machine is being measured)   # while it runs
threads        8                                      # after
```

`AUTO_AUTOTUNE=0` turns it off; `THREADS=8` is a decision made by hand and is
never overwritten; `zmrig-os mode …` clears the measurement, because safe sheds
threads under heat and eco and light start lower, so a count taken in one mode is
the wrong answer in another.

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
| `FLEET_URL` | — | control plane (Telegram/Discord bot); empty means nothing is contacted |
| `FLEET_INTERVAL` | `60` | seconds between check-ins; the server may lower it |
| `EXTRA_ARGS` | — | anything else, verbatim |

Precedence, lowest to highest: the image, `/zmrig/os.conf` on the media, the
`ZMRIGDATA` partition, `/etc/zmrig/kernel.conf` (written from the kernel command
line).

## Kernel command line

```
zmrig.os.wallet=4...          wallet, skips the wizard
zmrig.os.pool=host:port       pool
zmrig.os.worker=rig-01        worker name
zmrig.os.mode=max|balanced|eco|light|safe
zmrig.os.maxtemp=72           safe mode: hold the CPU at or below this
zmrig.os.hugepages=N          0 disables the reservation
zmrig.os.fleet=https://host   control plane: enrol and configure from a bot
zmrig.os.data=/dev/sdX1       partition that keeps the config
zmrig.os.debug=1              shell in the initramfs instead of the miner
zmrig.os.nostart=1            boot, but do not mine
```

A fleet is re-pointed by editing one GRUB line, or by pressing `e` once at the
menu.

## Being told what to do

A rig with `FLEET_URL` set checks in with a control plane once a minute and
applies whatever was queued there: wallet, pool, coin, mode, heat cap, threads,
worker name, start/stop/restart, update, log, reboot. The rig calls out and never
listens, so there is no port to open and nothing to reach it through; the whole
protocol is in [doc/FLEET.md](FLEET.md).

```bash
zmrig-os id                    # Device ID, enrolment code, where the key lives
zmrig-os fleet --url https://… # point it at the bot
zmrig-os sync                  # check in now; crond does it every minute
```

The key (`device.key`, mode 600) is generated on the machine and never leaves it;
the Device ID and the enrolment code are both derived from it, so the bot can
verify a rig without ever holding a secret. On an installed rig it lives with the
root filesystem; on a live stick it is in RAM unless `zmrig-os persist` gave the
stick a partition — which is why `zmrig-os id` says so, loudly, in that case.

Everything the bot sends is validated again on the machine (`zmrig-os`'s own
wallet validator, its own mode list), so a malformed or hostile instruction is
refused there and the refusal is reported back.

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

## Updating from the command line

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

## How a rig ends up on the newest image

Five links in one chain, and every one of them is a build step rather than a
person remembering:

| step | what happens | where it is defined |
| --- | --- | --- |
| 1 | a push touching `os/`, `zmrig/` or the tuner builds both architectures and boots them in QEMU | `.github/workflows/os.yml` |
| 2 | `master` publishes `v<version>`; `BETA` publishes the rolling `os-beta`; assets are replaced in place, so a version's link never rots | the `publish` job |
| 3 | Mondays, a scheduled run asks `os/upstream.sh --check` whether Alpine moved; if it did not, no build happens | the `upstream` job |
| 4 | the job asks GitHub for every asset over HTTPS, then rewrites the release notes with direct links and checksums | the `Verify` and `Notes` steps |
| 5 | a rig's daily `crond` job applies the miner, and with `AUTO_IMAGE=1` writes the whole image into the spare A/B slot | `zmrig-os auto` |

The rolling beta exists so a change can be tried on one machine before it is a
versioned release:

```sh
# on the rig
zmrig-os update --channel beta --check
zmrig-os update --channel beta --apply          # or AUTO_IMAGE=1 for the whole system
```

### The base, and why it says `latest-stable`

The Alpine version is `latest-stable` on purpose: a pin means the image stops
picking up security fixes the day nobody is looking. The cost of that is the
opposite question — did anything move? — and `os/upstream.sh` answers it without
building anything:

```bash
./os/upstream.sh            # the base, and what each channel published
./os/upstream.sh --check     # exit 0 = a rebuild would change the image
./os/upstream.sh --json      # the same facts, for a workflow
```

```
ZMRIG OS 6.39.0

  base               Alpine Linux 3.22.1 (x86_64, OpenRC, musl)
  kernel             linux-lts 6.12.61
  root filesystem    squashfs, zstd level 19, 1 MiB blocks
  bootloader         GRUB, BIOS and UEFI, built with the image

  published: v6.39.0
             built on Alpine 3.22.1
             os-beta (rolling beta)

  rebuild: no - the published image is already on Alpine 3.22.1
```

It compares the Alpine release the mirror serves today with the `alpine` field
inside the last published manifest — which is why the build writes that field.
An image published before the field existed triggers exactly one rebuild, and
then that branch is never reached again.

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

The workflow is `.github/workflows/os.yml`. It was kept in `os/ci/` for a while
because installing a file under `.github/workflows/` needs a token with the
`workflows` scope and the account writing the repository did not have it; the
organisation's installation does, so it lives in the usual place now.

It runs on every push to `BETA` or `master` that touches `os/`, `zmrig/`,
`scripts/tune-linux.sh` or the workflow itself, on tags, and on a **pull
request** that touches the same paths — a workflow that first runs after a merge
is a workflow nobody has tested. Publishing is separate: only a tag, or a manual
run with `publish=true`, creates or refreshes a release.

It does this:

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

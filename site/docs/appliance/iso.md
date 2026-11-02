---
title: The bootable image
description: A live ZMRIG OS image — write it to a stick, answer one question, and the rig hashes. Nothing installed, nothing persisted, everything tunable.
image: https://molik-labs.github.io/ZMRIG/img/og-en.png
---

# The bootable image

`zmrig-os` is a complete operating system that mines: a kernel, a small
initramfs and a read-only Alpine root filesystem containing `zmrig` and almost
nothing else. Write it to a USB stick, boot the rig, type your wallet, and it is
mining. There is no installer, no disk to prepare and no wizard that leaves
half a system behind.

```bash
# grab the image for your CPU from the releases page, then
sudo dd if=zmrig-os-<version>-x86-64-v3.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

Two builds are published. `x86-64-v3` needs AVX2 (any x86 CPU since roughly
2015) and is the default; `x86-64-v2` runs on everything since Nehalem. The
image is compiled for one level and the updater never offers the other one.

## First boot

1. GRUB appears; the default entry is *max hashrate*.
2. The console shows the ZMRIG banner and asks for your Monero address.
3. Paste it, press Enter, and the hashrate line starts within a few seconds.

The address is checked before it is used: 95 or 106 characters, base58 alphabet,
starting with `4` or `8`. A wallet typed with a `0` or an `l` — the two
characters base58 drops precisely because they are misread — is refused instead
of mining to nowhere.

## Headless and fleets

A rig with no keyboard is configured from the kernel command line. Press `e` on
the GRUB entry, or edit `grub.cfg` on a fleet image:

```
zmrig.os.wallet=4...
zmrig.os.pool=gulf.moneroocean.stream:10001
zmrig.os.worker=rig-07
zmrig.os.mode=max
zmrig.os.maxtemp=70
```

`zmrig.os.maxtemp` is the temperature limit for `safe` mode and for any mode
that arms the governor.

The wizard does not appear when a wallet is already known. `zmrig.os.nostart=1`
boots the machine without mining, which is what a repair stick wants.

## Modes

The miner's aggressiveness is a single word, changeable while it runs:

```bash
zmrig-os mode eco       # restart with half the cores and the watt profile
zmrig-os mode safe 70   # ... and never let the CPU past 70 C
zmrig-os status         # what is hashing, at what rate, at what temperature
```

| Mode | Threads | Priority | Profile | Huge pages | For |
| --- | --- | --- | --- | --- | --- |
| `max` | cache-aware, all cores | 5 | free | reserved at boot | the default |
| `balanced` | cores − 1 on 4+ cores | 3 | free | reserved at boot | a rig you also log into |
| `eco` | half the cores | 1 | watt | THP `madvise` | quiet and cool |
| `safe` | cores − 1 on 4+ cores | 19 (nice) | watt | reserved at boot | a machine that must not break |
| `light` | all cores, 256 MiB cache | 2 | free | none | under 2.5 GiB of RAM |

There are GRUB entries for each one, so a machine with no network and no
keyboard can still be changed: the mode travels on the kernel command line and
is applied at boot.

### Safe mode

`safe` is the only mode that treats the machine's temperature as a limit rather
than a side effect. It leaves one core for the OS and the fan controller, drops
to the lowest scheduling priority there is, never writes the MSR registers, and
arms the miner's thermal governor at 72 °C (change it with
`zmrig-os mode safe 68`):

```text
zmrig-os status
  mode           safe (max 72 C)
  thermal        64 C
```

The governor runs once a second on the miner's own monitor thread. At 72 °C it
parks one thread (at most every 30 s), at 80 °C it parks one immediately (at most
every 5 s), at 87 °C it stops hashing altogether, and it comes back down the
ladder — one thread at a time, two minutes of cool per step — as the box cools.
Nothing is rebuilt on the way: a parked thread keeps its VM, the dataset stays in
RAM and the pool connection stays open, so a hot afternoon costs the shares it
did not compute and nothing else.

It reads only CPU sensors (`coretemp`, `k10temp`, `zenpower`, `cpu_thermal`,
`acpitz`, Super I/O), so a warm NVMe never costs a thread. On a machine with no
sensor at all it says so once and keeps the thread count it was given.

For a laptop, a shared office box, or any rig whose owner would notice it
breaking, this is the mode to run. It gives up a few percent of peak hashrate at
20 °C and it does not spend the hot hours hardware-throttled at a rate it cannot
control.

## What the image does that a normal distribution does not

The harshest part of RandomX is memory, and the operating system decides almost
all of it. On a general-purpose install every setting below is a fight against a
package upgrade or a systemd unit. Here they are the defaults:

- **2 MiB pages are reserved by the initramfs**, before any userspace program has
  fragmented memory. That is the +4–6 % on top of transparent huge pages, and it
  is the one tuning step that is nearly impossible to do later in the day.
- **Transparent huge pages stay enabled** (`always` on the max entries). Turning
  them off costs about 28 % — measured, see [Performance](/docs/operate/performance).
- **The CPU governor is `performance`**, set by the same step that reserves
  memory, before the miner starts.
- **`swappiness=1`**, so the 2.3 GiB dataset is never paged out; **write-back
  throttled** so a log rotation cannot stall a mining thread; **64 MiB kept
  free** so a burst allocation does not trigger reclaim mid-hash;
  **`zone_reclaim_mode=0`** so a multi-socket box does not stall on one node;
  **NMI watchdog off**, because nothing has ever been detected by it on a mining
  rig.
- **Nothing else runs.** No desktop, no update daemon, no telemetry. OpenRC,
  sshd, chrony and the miner.
- **The binary is static** (musl, one 19 MB file with no libc dependency), so an
  image update cannot break it and it runs on any distribution you copy it to.

## Stability

Long uptime is not one feature, it is a chain of them:

- the miner exits on a stall or on a run of rejected shares
  (`--health-restart`, 900 s), and says so in the log;
- `zmrig-os run` restarts it 10 s later, forever;
- five failed starts in a row reboot the machine, because at that point the
  operating system is the thing that is broken;
- logs rotate at 8 MB, so a notebook that has been mining for a year still boots;
- chrony keeps the clock right, because a pool login over TLS fails on skew.

`zmrig-os doctor` prints every check the boot makes, with the value it found:

```
  PASS  binary                 zmrig 6.35.0 - ZMRIG by @nggkhaiz
  PASS  wallet                 46SQLW7D...ysb5tJ
  PASS  memory                 32044 MB total, need 2400 MB
  PASS  hugepages              1168 x 2 MB reserved
  PASS  thp                    always
  PASS  governor               performance
  WARN  msr                    not applied (VM, or no msr module)
  PASS  swap                   off
  PASS  dns                    gulf.moneroocean.stream resolves
  PASS  config                 miner --check passed
```

## Measuring this machine

Thread count is the one number that differs per box, and the cache heuristic
assumes 2 MiB of L3 per thread. Let the machine answer instead:

```bash
zmrig-os autotune 8     # 8 s per candidate, winning count pinned in the config
```

The result is written to `os.conf`; `THREADS="auto"` returns to the heuristic.

## Keeping the settings

The root filesystem is read-only, so the config lives in RAM and disappears at
reboot. A small partition on the same stick fixes that:

```bash
zmrig-os persist /dev/sdb1      # format, label ZMRIGDATA, copy the config
```

The initramfs finds it by label on every boot and copies `os.conf` and
`/root/.ssh/authorized_keys` in.

## Monitoring without a dashboard

The image has no web UI on purpose — a web app is another thing to patch. What it
has is the miner's own JSON API, off by default:

```
API_PORT="18080"
API_HOST="0.0.0.0"
API_TOKEN="a long random string"
```

With those three lines, `http://rig:18080/2/summary` answers anyone holding the
token, which is what a fleet dashboard, Home Assistant or a `curl` in a cron job
needs. Leaving `API_HOST` at `127.0.0.1` keeps it on the machine.

## Updates

```bash
zmrig-os update --check                  # what is published for this channel
zmrig-os update --apply                  # 19 MB binary, sha256 verified, swapped in
zmrig-os update --iso --write /dev/sdb1  # flash a newer image to another stick
```

`--apply` patches the running image and is lost on reboot — reboot and you are
back on the version that was burned in. That is the whole rollback procedure, and
it needs no menu. `--iso` refuses to write the device the machine booted from.

Channels: `stable` follows master releases, `beta` follows the rolling
pre-release. Both publish a manifest per instruction level, which is what the
updater reads.

## Security

- The console is an autologin root shell — the wizard needs it, and physical
  access to a rig is already root. Everything below exists because that is true.
- SSH is **key-only**: `PermitRootLogin prohibit-password`, no passwords, no
  keyboard-interactive. `zmrig-os ssh-key add` then `rc-service sshd start`.
- No package manager runs at runtime: the image is what was built.
- Updates are sha256-verified before the binary is moved into place; a mismatch
  fails and leaves the old file alone.
- Nothing phones home. The only outbound traffic is your pool, NTP and, if you
  ask for it, an update check.

## Building it yourself

```bash
sudo ./os/deps.sh                 # xorriso, mtools, grub, squashfs-tools, qemu
sudo ./os/build-iso.sh            # → os/out/zmrig-os-<version>-x86-64-v3.iso
sudo ./os/build-iso.sh --smoke    # build, then boot it in QEMU and read the log
```

The image is rebuilt by CI whenever `os/`, `zmrig/` or `scripts/tune-linux.sh`
change, and every release keeps its ISO. The workflow also runs on pull requests
that touch `os/`, so a broken image fails before it is merged. The build also publishes the manifest
`zmrig-os update` consumes, so an image in the field can move forward without
being rewritten.

## What it is not

Not a GPU miner. Not an overclocking tool — memory timings and voltage belong to
firmware. Not a way to make MSR writes work inside a virtual machine: the
hypervisor rejects them and the miner stays on the portable path, which
`zmrig-os doctor` reports instead of hiding.

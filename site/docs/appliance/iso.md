---
title: The bootable image
description: A live ZMRIG OS image — write it to a stick, answer one question, and the rig hashes. Nothing installed, nothing persisted, everything tunable.
image: https://molik-labs.github.io/ZMRIG/img/og-en.png
---

# The bootable image

`zmrig-os` is a complete operating system that mines: a kernel, a small
initramfs and a read-only Alpine root filesystem containing `zmrig` and almost
nothing else. Write it to a USB stick, boot the rig, type your wallet, and it is
mining. Nothing has to be installed and nothing on the machine is modified.

If you would rather not depend on the stick, the same image installs onto the
machine's own disk with one command, and from then on it looks after itself:

```bash
zmrig-os install --disk /dev/nvme0n1   # partition, copy, boot from the disk
```

[Install to disk](#install-to-disk) and [Updates](#updates) below are the whole
story; the rest of this page is what the image does and how to change it.

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

## One command, no questions

The wizard asks one question at a time, which is right at a keyboard. Over ssh,
or from a script that provisions ten machines, the same thing takes one line:

```bash
zmrig-os quickstart --wallet 4... --pool gulf.moneroocean.stream:10001 --mode balanced
```

It validates the address and the pool, writes the config, tunes the machine for
the algorithm it was given, prints the Device ID and starts the miner — and says
whether the miner actually started, which is the part a provisioning script
tends to skip. `--coin` picks the algorithm the memory reservation is sized for,
`--fleet` enrols the rig with a bot, `--no-start` stops before mining.

A wrong argument is refused before anything is written: a pool without a port, an
address that is not an address, a mode that does not exist.

## Keeping the kernel off the mining cores

A mining thread that gets scheduled onto the CPU taking the pool's interrupts
loses more than the interrupt costs: its 2 MiB scratchpad cools out of the cache
while another core warms its own.

```bash
zmrig-os isolate 4     # four logical CPUs for mining
zmrig-os isolate       # what is isolated now
zmrig-os isolate off   # give them back
```

CPUs are taken as whole SMT pairs, from the top, and cpu0 is never taken — that
is where interrupts and most kernel threads land. On a 4-core/8-thread machine
`isolate 3` gives you 2 CPUs, not 3: the third would be the twin of a CPU that
stays with the kernel, and half an isolated core is not isolated. The command
prints the exact set it took instead of pretending it took what was asked.

Both halves are written, because either one alone buys nothing:

* the boot parameters `isolcpus=`, `nohz_full=` and `rcu_nocbs=` — merged into
  the GRUB environment block on an installed disk and read by every installed
  menu entry (`${zmrig_extra}`), so they take effect on the next boot; printed
  for you to type on a read-only stick. That block holds one value and is written
  by one function, so isolating CPUs after reserving 1 GiB pages keeps both, and
  `zmrig-os hugepages off` does not hand the CPUs back;
* `--cpu-affinity` for the miner, plus the IRQ masks moved to the remaining CPUs
  every time the supervisor starts.

`ISOLATE=4` in `/etc/zmrig/os.conf`, or `zmrig.os.isolate=4` on the kernel
command line, makes it survive a reboot; `ISOLATE=0` hands the machine back to
`AFFINITY=auto`, which pins the miner to every physical core. The thread count
follows the mask: a `balanced` rig on a machine where the miner may only use three
cores pins three threads, not seven.

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

## Install to disk

The live stick is deliberately disposable: `/etc/zmrig` lives in RAM and a
reboot forgets it. An installed rig is the other half of that trade.

```bash
zmrig-os install --disk /dev/nvme0n1 --dry-run   # what would happen
zmrig-os install --disk /dev/nvme0n1             # do it
```

The disk is repartitioned, not shared:

| Partition | Size | Contents |
| --- | --- | --- |
| BIOS boot | 1 MiB | `core.img`, for a machine that boots in BIOS mode |
| EFI | 100 MiB | `BOOTX64.EFI`, for UEFI |
| root | the rest | kernel, initramfs, `rootfs-a.squashfs`, config |

Then it copies, verifies what it wrote (by reading the new filesystem back and
hashing the squashfs), and prints *remove the stick and boot from the disk*.
There is no bootloader package on the machine: the two GRUB images are built
when the ISO is built and travel inside it, so the install needs no network and
no `grub-install`.

Everything after that is automatic: the miner starts, the config persists, the
thread count is measured on the machine it will run on, and the daily update
job is already enabled.

### Unattended, for Ventoy and fleets

Add one parameter to the boot entry and walk away:

```
zmrig.os.install=/dev/nvme0n1
```

The machine installs, reboots into its own disk and starts mining. With Ventoy
that is: pick the ISO, press `e`, add the parameter. A fleet is the same
parameter on every machine with the disk name that model uses.

### Cores, interrupts and NUMA

`nproc` counts hyperthreads, and RandomX does not run on hyperthreads: a sibling
pair shares one core's L2, so two threads on a pair are two threads fighting over
the same 512 KiB. The image reads the kernel's topology instead and sizes the
miner to physical cores, pins it there with `--cpu-affinity`, steers interrupts
and unbound workqueues to CPU 0 once there are four cores to steer between, and
turns NUMA balancing off in the modes where the machine exists to mine. Light mode
leaves the kernel alone.

```
$ zmrig-os topology
cores      8 physical, 16 threads
mining on  0 1 2 3 4 5 6 7
affinity   0xff (--cpu-affinity)
threads    7 (THREADS=auto, mode balanced)
```

Before this, `--mode balanced` on that machine asked for 15 mining threads — one
per hyperthread — which is hotter and slower than 8. `AFFINITY=off` in `os.conf`
(or `zmrig.os.affinity=off` on the command line) takes the pinning out for
somebody with a reason to want it gone.

### What hardware this runs on

RandomX's fast mode wants AVX2, AES-NI and 2 GB of memory for the dataset. A
machine missing any of the three still hashes — several times slower — which is
worth being told rather than left to infer from a rate that does not match the
README.

```
$ zmrig-os hardware
cpu        Intel(R) Xeon(R) Processor @ 2.60GHz (1 cores, 2 threads)
flags      avx2 aes sha_ni
memory     3939 MB total
pages      2 MB (no 1 GB pages)
verdict    full: fast mode: AVX2 and AES, and room for the 2 GB dataset
```

| verdict | means | what to do |
| --- | --- | --- |
| `full` | AVX2, AES, room for the dataset | nothing — `max` is the miner at its own rate |
| `light` | AVX2 and AES, under 2.4 GB | `--mode light`: it mines, the dataset does not fit in one array |
| `slow` | no AVX2, or no AES | it works and it is much slower; on a pre-2015 CPU boot the **x86-64-v2** image |
| `small` | under 1.2 GB | it cannot mine RandomX — the scratchpad alone is 256 MB per thread |

The command exits non-zero on `slow` and `small`, so a script that provisions a
hundred machines stops on the one that will never be fast instead of adding it to
the pile. `doctor` prints the same verdict as a single line on every boot.

### The stick, and how to make it last

A stick mining 24/7 for a year is 8,760 hours inside a device built to carry a
document across a room. The answer is that the stick does not work while the rig
mines.

**Nothing is written to it after boot.** The root filesystem is a squashfs
mounted read-only, and the writable layer stacked on top is a tmpfs in RAM — that
is where the logs, the wallet file and an updated miner live. It is also why a
reboot forgets an unpersisted config, and why a log that grows cannot fill the
stick. NAND wears from writes; during normal running there are none.

What does touch the stick, and how much:

| | writes | when |
| --- | --- | --- |
| `zmrig-os install --disk` | the whole image, once | the day you install |
| a miner update | ~19 MB into the data partition | `AUTO_UPDATE=1` (the default) and a newer binary exists |
| an image update | one slot, ~158 MB | `AUTO_IMAGE=1` (off by default) |
| `zmrig-os persist` | the config, a few kB | when you run it |

Everything else is a read. So the stick's real workload is a handful of reads a
day, not a year of writes. That turns the question from endurance into heat, power and cheap
controllers:

| Keep | Why |
| --- | --- |
| the stick **cool** | sustained heat costs NAND retention far more than reads do. A metal body and a port away from the PSU exhaust is most of it |
| the stick **small** | the image is 158 MB, so 8 GB is generous. The cheapest high-capacity sticks have the worst controllers |
| **power** clean | the only corruption window is an install or an image update. A UPS, or simply not pulling the cable mid-update, closes it |
| **reboots** few | every boot reads ~158 MB. A rig that reboots three times a day does the stick more work than one that mines for a month — and the OS reboots itself only after five failed miner starts |

**Ventoy** boots this image the way a burned stick does: the ISO is read-only and
nothing inside it is modified. Everything above applies unchanged, plus two
habits:

* **do not enable Ventoy persistence for this image.** Configuration belongs on
  the kernel command line (`zmrig.os.wallet=…`, `zmrig.os.pool=…`) or in the
  `os.conf` next to the image, and a fleet gets the rest from its roster.
  Persistence turns the log into writes on the stick, which is the one thing this
  design avoids.
* set `VTOY_DEFAULT_IMAGE` (and `VTOY_DEFAULT_IMAGE_FORCE=1`) so a headless
  machine boots straight into the image, and update Ventoy itself rarely — that
  is the only other thing that writes to the stick.

**The most durable setup is not a stick.** If the machine has a SATA or NVMe
drive, `zmrig-os install --disk /dev/…` once: the OS moves to the drive, the
stick becomes an installer you can put in a drawer, and `zmrig-os update` has
somewhere sane to write. For a live fleet, a cloned spare stick — the ISO plus
one `os.conf` — is the whole disaster plan.

Not claimed here: a lifetime in hours. It depends on the controller and on the
temperature of the room, and it has not been measured in this environment.

## Updates

An installed rig checks once a day, from busybox `crond` (`/etc/periodic/daily`),
so there is no extra systemd timer and no package to keep.

```bash
zmrig-os auto --check    # is there anything newer?
zmrig-os auto --apply    # do it now instead of at 03:00
```

- **The miner** is written next to the running system, not into `/usr/local/bin`
  — that directory is RAM, so an update there would last until the reboot. The
  previous binary is kept, and the miner is restarted into the new one.
- **The OS image** (`AUTO_IMAGE=1`, off by default) is written into the *other*
  slot, verified, and only then made the default for the next boot.
- **An update that will not boot undoes itself.** The initramfs counts boots that
  never became a mining rig; three of them flip the machine to the other slot
  and reboot. `zmrig-os slot` shows both, `zmrig-os slot b` picks one. The flip
  merges the GRUB environment block instead of replacing it, so the kernel
  parameters on that machine — `isolcpus=`, `nohz_full=`, the thermal cap —
  survive the rollback. A rig that comes back on the other slot comes back
  configured.
- **An update with no checksum is refused.** The manifest names a sha256 for the
  binary and for the image; without one there is no way to tell a truncated
  download or a captive-portal page from the real file, and installing that as
  the miner is worse than staying a version behind. The rule is the same for
  `zmrig-os update --apply` and for the daily job: they download the same bytes,
  so they cannot have different rules about verifying them. `zmrig-os auto` says
  so in one line and exits 0, so the daily job stays quiet.
- `AUTO_UPDATE=0` turns the whole thing off. No manifest reachable means
  "offline", which is not an error: the rig keeps mining and the job exits 0.

## What the image does that a normal distribution does not

The harshest part of RandomX is memory, and the operating system decides almost
all of it. On a general-purpose install every setting below is a fight against a
package upgrade or a systemd unit. Here they are the defaults:

- **It is 158 MB, and the number is a build output.** The stock Alpine initramfs
  (171 MB, never read — the image builds its own), the GPU/Wi-Fi/switch firmware
  (660 MB → 16 MB) and the sound, video-capture, GPU, InfiniBand, ISDN, WAN, CAN,
  IIO, NFC, Bluetooth and staging drivers are not in it. Every build writes
  `dist/size-report.txt` with the biggest directories, the biggest files and the
  totals, so "why is the image this big" has an answer with numbers in it. Before
  this the same image was 1081 MB. `--firmware all` puts the firmware back for a
  board with a NIC outside the keep list.
- **2 MiB pages are reserved by the initramfs**, before any userspace program has
  fragmented memory. That is the +4–6 % on top of transparent huge pages, and it
  is the one tuning step that is nearly impossible to do later in the day.
- **Transparent huge pages stay enabled** (`always` on the max entries). Turning
  them off costs about a fifth — measured by alternating the two in one session,
  see [Performance](/docs/operate/performance).
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
- `zmrig-os run` restarts it 10 s later, then 20, 40, 80, 160, and five minutes
  from the fifth failure on: a crash loop is usually the pool or the network, and
  reconnecting every ten seconds turns a short outage into a socket storm;
- a start that lasted ten minutes clears that count, so "five failed starts in a
  row" means in a row and not since last month;
- five failed starts in a row reboot the machine, because at that point the
  operating system is the thing that is broken;
- logs rotate at 8 MB, so a notebook that has been mining for a year still boots;
- chrony keeps the clock right, because a pool login over TLS fails on skew.

`zmrig-os doctor` prints every check the boot makes, with the value it found:

```
  PASS  binary                 zmrig 6.36.0 - ZMRIG by @nggkhaiz
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
It tunes the machine first — huge pages, THP, governor — because measuring an
untuned box answers the wrong question.

**It also happens on its own.** On a rig that has never been measured, the miner
starts immediately and, ninety seconds later, the supervisor measures the machine
while it mines. The answer is written to the config and the miner reloads once.
No idle boot, no reboot, and the reload is not counted as a crash. `AUTO_AUTOTUNE=0`
turns it off, and a thread count you set by hand is never overwritten:

```
threads        auto (the machine is being measured)
threads        8
```

### When the rig stops keeping its own number

A measurement is a claim about the future, and a machine only sometimes keeps it:
a dust-filled heat sink, a stick of RAM that started erroring, a background job
left running. None of that announces itself, and all of it looks the same — a
hashrate under the rate this box measured.

The image therefore stores the result next to the thread count (`MEASURED_HS`,
`MEASURED_THREADS`, `TUNED_AT`) and compares the two every fifteen minutes:

```
measured      1234 H/s at 4 thread(s), 6 h ago
```

The rule is conservative, because a needless re-measure costs more than the drift
it chases:

| Condition | Why |
| --- | --- |
| the 15-minute rate, not the 10-second one | a dataset build or a pool reconnect moves the short window |
| below 75 % of the measured rate | a rig at 90 % is having a normal day |
| at least 250 H/s measured | on a small rig two runs differ by tens of percent |
| at least 6 h since the last measurement | a re-measure runs at the wrong count for ~90 s |
| still the count the measurement chose | a number set by hand is never revisited |

When all five hold, the rig says what it saw and measures again. `zmrig-os doctor`
reports the same comparison on demand.

## What it is built from

| | |
| --- | --- |
| base | Alpine Linux `latest-stable` — `3.22.x` today — musl, OpenRC |
| kernel | `linux-lts` (`linux-virt` for a VM) |
| root filesystem | squashfs, zstd level 19, 1 MiB blocks, read-only |
| initramfs | busybox + ~30 modules, zstd when the kernel's config says it can unpack it, gzip otherwise |
| boot | GRUB, BIOS and UEFI, both built with the image |

The image writes that table to `/etc/zmrig/base`, and `zmrig-os version` prints
it, so a bug report carries its own base. `./os/upstream.sh` prints the same from
the source, and `--check` answers whether a rebuild would change anything — the
Alpine mirror serves `latest-stable`, so the weekly build compares it with the
`alpine` field of the last published manifest instead of rebuilding to be sure.

## Keeping the settings

On an installed disk this is unnecessary: the config is on the boot medium and
comes back by itself. On a live stick the root filesystem is read-only, so the
config lives in RAM and disappears at reboot; a small partition fixes that:

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

The other machine-readable surface is the image's own health check:

```bash
zmrig-os doctor --json
```

One object, one entry per check, and a non-zero exit when something failed:

```json
{"fail":1,"warn":3,"checks":[{"status":"ok","check":"wallet","detail":"46SQLW7D...ysb5tJ"}, ...]}
```

That is the line to put in a cron job or a monitoring agent, because it needs no
parsing of prose and no `grep` to decide whether a fan stopped or a wallet was
still empty.

## One bot for the whole shelf

A machine that boots a hundred rigs should not need a keyboard on each of them.
`zmrig-os fleet --url https://your-fleet` (or `zmrig.os.fleet=` on the kernel
command line) points a rig at a Telegram and Discord bot, and `zmrig-os id` prints
the Device ID you enrol it with. Wallets, pools, coins, modes and updates are then
set from the chat, and a rig that goes quiet tells you.

[Telegram and Discord control](/docs/fleet/telegram) is the guide.

## Updates, by hand

The automatic job above uses the same commands; these are the manual versions:

```bash
zmrig-os update --check                  # what is published for this channel
zmrig-os update --apply                  # 19 MB binary, sha256 verified, swapped in
zmrig-os update --iso --write /dev/sdb1  # flash a newer image to another stick
```

On a **live** stick `--apply` patches the running image and is lost on reboot —
reboot and you are back on the version that was burned in. That is the whole
rollback procedure and it needs no menu. On an **installed** rig it lands on the
boot medium and survives. `--iso` refuses to write the device the machine booted
from.

Channels: `stable` follows master releases, `beta` follows the rolling
pre-release under the `os-beta` tag. Both publish a manifest per instruction
level, which is what the updater reads — and the two are in different places,
because `releases/latest` never points at a pre-release:

```
stable  https://github.com/MoLik-Labs/ZMRIG/releases/latest/download/zmrig-os-stable-x86-64-v3.json
beta    https://github.com/MoLik-Labs/ZMRIG/releases/download/os-beta/zmrig-os-beta-x86-64-v3.json
```

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

Five steps, and every one of them is a build step rather than a person
remembering: a push builds and boots both architectures in QEMU; `master`
publishes `v<version>` and `BETA` publishes the rolling `os-beta`, replacing
assets in place so a version's link never rots; a Monday run asks
`os/upstream.sh --check` whether Alpine moved and skips the build if it did not;
the job then fetches every asset over HTTPS and rewrites the notes with the
links; and each rig's daily job applies the miner, or the whole image into the
spare A/B slot with `AUTO_IMAGE=1`.

## What it is not

Not a GPU miner. Not an overclocking tool — memory timings and voltage belong to
firmware. Not a way to make MSR writes work inside a virtual machine: the
hypervisor rejects them and the miner stays on the portable path, which
`zmrig-os doctor` reports instead of hiding.

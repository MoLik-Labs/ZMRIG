---
title: Setup from zero
description: Three ways to get a rig hashing — one command, a container, or the bootable image — plus the five checks that prove it worked, how to update it, how to audit the 3 % fee, and how to tell two rigs apart.
image: https://molik-labs.github.io/ZMRIG/img/og-en.png
---

# Setup from zero

This page is the decision, not the reference. It assumes one thing: you have a
Monero address and a machine with a CPU. Pick a route, run one command, then run
the five checks in [Did it work](#did-it-work). Everything else on this page is
what you will want on day two.

| Route | Best for | What it touches | Time |
| --- | --- | --- | --- |
| [A. One command](#a-one-command) | a machine you own and keep | installs a service, writes `/etc/zmrig/config.json` | 5–10 min, mostly compiling |
| [B. Container](#b-container) | a server, a NAS, Kubernetes, anything already running containers | nothing outside the container | 1 min |
| [C. Bootable image](#c-the-bootable-image) | a dedicated rig, or a machine you do not want to install anything on | a USB stick, or the rig's own disk | 5 min |

All three run the same miner and the same hash engine. The difference is what
happens to the host.

## First, the wallet

Wrong wallet, no payout — and a Monero address is 95 characters with a checksum,
so a typo is silent until the pool refuses it. Check it before it goes into a
config:

```bash
zmrig --check-wallet 4YourMoneroAddress
```

It prints the kind, the network, and the spend and view keys, or the exact
reason it is not usable. If you have not built the miner yet, the container does
it for you:

```bash
docker run --rm -e WALLET=4YourMoneroAddress ghcr.io/molik-labs/zmrig check
```

The installer and the appliance run the same check before they write anything,
so a bad address fails at setup rather than at the first payout.

## A. One command

```bash
curl -fsSL https://raw.githubusercontent.com/MoLik-Labs/ZMRIG/BETA/oneclick.sh \
  | sudo bash -s -- --wallet 4YourMoneroAddress
```

From a clone, `sudo ./oneclick.sh --wallet 4YourMoneroAddress` is the same thing.
The installer builds, measures the machine to pick a thread count, tunes the
host, writes the config, installs `zmrig.service`, and prints the hashrate it
measured.

Before it touches anything, ask it what it would do:

```bash
./oneclick.sh plan
```

The flags worth knowing on day one:

| Flag | Why |
| --- | --- |
| `--pool HOST:PORT` | the pool; a short name such as `supportxmr` also works |
| `--rig-id NAME` | what this machine is called on the pool dashboard |
| `--profile free\|watt` | maximum hashrate, or maximum hashrate per watt |
| `--max-temp 70` | override the safe 80 °C default; shed threads as the CPU warms |
| `--donate-level 3` | the developer fee, `0`..`10`; `0` turns it off |

The rest are in [every installer option](/docs/install/installer).

## B. Container

One command, no build, no service on the host:

```bash
docker run -d --name zmrig --restart unless-stopped \
  -e WALLET=4YourMoneroAddress \
  -e POOL=gulf.moneroocean.stream:10001 \
  -e WORKER=rig-01 \
  ghcr.io/molik-labs/zmrig
```

The container reads the same names the appliance writes to `/etc/zmrig/os.conf`,
so `MODE`, `THREADS`, `DONATE`, `SAFE_TEMP`, `MSR`, `API_PORT` and `EXTRA_ARGS`
all work. Two of them matter on a shared server:

* `--cpus=2` is a quota, not a core count. The container reads its own cgroup
  limit and caps the thread count to it, because a quota spread over too many
  threads is slower than fewer threads at full speed.
* `API_PORT=18080` switches the monitoring API on, and it binds to loopback
  inside the container — publish it deliberately, `-p 127.0.0.1:18080:18080`.

When the log says the rig mines fewer threads than the host has cores, ask the
container what it actually told the miner:

```bash
docker run --rm -e WALLET=4YourMoneroAddress ghcr.io/molik-labs/zmrig args
```

It also names the two container-side reasons a rig mines less than the host next
to it: a host with no huge page pool reserved (about 18 % of hashrate, measured —
`sysctl -w vm.nr_hugepages=1168` on the host fixes it, and the container needs no
flags for it), and `/dev/cpu/*/msr` for the prefetcher preset.

Every variable is in [the container reference](/docs/install/docker).

## C. The bootable image

A rig that only mines does not need a general-purpose distribution. The image is
a kernel, a read-only Alpine root with `zmrig` and its control tool, and nothing
else running:

```bash
# the manifest for your CPU level, then the ISO it names
curl -fsSLO https://github.com/MoLik-Labs/ZMRIG/releases/download/os-beta/zmrig-os-beta-x86-64-v3.json

# write it to a stick — the ISO comes from the releases page
sudo dd if=zmrig-os-<version>-x86-64-v3.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

Boot the rig, answer the wallet question, and it hashes. Nothing is written to
the machine, so one stick can set up a hundred machines.

A rig with a disk of its own is better off installed, and the same image does it:

```bash
zmrig-os install --disk /dev/nvme0n1   # partition, copy, boot from the disk
```

Both forms are configured by hand-free one-liners when there is no keyboard:

```bash
zmrig-os setup --wallet 4YourMoneroAddress --pool gulf.moneroocean.stream:10001 --mode max
```

The image, its modes and its persistence rules are in
[the appliance manual](/docs/appliance/iso).

## Did it work

Five checks, in this order. Each one answers a different question, and the first
three take ten seconds.

| Check | Command | What a good answer looks like |
| --- | --- | --- |
| Is it running? | `sudo ./oneclick.sh status` | a service in `active`, a hashrate that climbs past `warming up` |
| Does the hash engine match its reference vectors? | `sudo ./oneclick.sh verify` | `PASS` lines, then `verified` |
| Is the fee what the docs say? | `sudo ./oneclick.sh verify` | `fee audit: one wallet, Monero only, switchable off` |
| Is this rig laid out correctly? | `zmrig-os doctor` | every line `ok`; anything else names the machine, not the symptom |
| How fast is it, really? | `zmrig --bench=20000` or `zmrig-os bench` | a number in H/s, measured, comparable with [the benchmarks](/docs/reference/benchmarks) |

`status` only quotes measured numbers: a miner that started a moment ago says
`warming up` instead of showing the previous run's hashrate, because the dataset
takes 15–25 seconds to build.

Anything that fails has a row in
[when something is wrong](#when-something-is-wrong).

## Updating

| Route | Command | What survives |
| --- | --- | --- |
| A. One command | `sudo ./oneclick.sh update` | config, service, tuning; the binary is rebuilt |
| B. Container | `docker run --rm ghcr.io/molik-labs/zmrig update --check`, then pull and recreate | nothing inside the container — that is the point |
| C. Image, live stick | `zmrig-os update --apply` | until reboot; a live stick is read-only by design |
| C. Image, installed | `zmrig-os update --apply` | the change lands on the disk and stays |

`update --check` exits `0` when the image is current, `3` when a newer one is
published and `2` when it cannot tell — which is what the update timer reads.

## The 3 % fee, and how to audit it

The Zig engine spends 3 % of Monero mining time on the developer's wallet. The
C++ engine takes nothing. The fee is written into the config explicitly rather
than implied, and there are three independent ways to check it — none of which
requires trusting this page:

```bash
zmrig --check | grep donate        # what this rig will actually do
sudo ./oneclick.sh verify          # the installer's own audit
./scripts/verify-fee.sh --source-only   # the constants, straight from the source
```

The last one reads `fee.default_percent` out of `zmrig/src/fee.zig` and fails if
any page in this repository disagrees with it, including the page you are reading.

To change it, say so where the config is written:

```bash
sudo ./oneclick.sh config --donate-level 0     # this rig, no fee
docker run -e DONATE=0 ...                     # the container
zmrig-os setup --donate 0                      # the appliance
```

`11` is refused, and so is a word: the miner only accepts `0`..`10`, and a value
it rejects would be found at boot instead of at setup. [The fee page](/docs/reference/fee)
has the per-rate table and the exact code that implements it.

## More than one rig

Every rig needs its own name, or the pool dashboard shows one machine doing
arithmetic that does not add up:

```bash
sudo ./oneclick.sh install --wallet 4... --rig-id rig-02   # route A
docker run -e WORKER=rig-02 ...                            # route B
zmrig-os setup --wallet 4... --worker rig-02               # route C
```

Then, if you want them in one place: `zmrig-os id` prints the Device ID to enrol,
and `zmrig-os fleet --url https://your-fleet` points the rig at a Telegram bot.
The control plane is [a whole fleet](/docs/fleet/telegram); the installer has a
loop for ten machines in [unattended installs](/docs/install/installer).

## When something is wrong

| Symptom | Likely cause | Do this |
| --- | --- | --- |
| `the miner rejected the generated config` | the wallet has a character that is not base58 | `zmrig --check-wallet 4...`, then reinstall with a clean address |
| the pool bans this IP | wrong wallet, or too many reconnects | wait out the cooldown; a wrong wallet is clamped to at least 30 min |
| hashrate is a quarter of the benchmarks | no huge pages (a container or an OpenVZ VPS) | `zmrig --check` reports the page count; ask the host for 2 MiB pages |
| the rig is loud and hot | target is too high for this cooling setup | `--max-temp 70`, or `zmrig-os setup --max-temp 70` |
| the container uses fewer threads than the host has cores | a `--cpus` quota | `docker run ... args` and read the `-t` it chose |
| the service restarts in a loop | somebody edited the config | `sudo journalctl -u zmrig -n 60`, first line after the binary starts |

The full table, with the log lines that identify each one, is in
[troubleshooting](/docs/operate/troubleshooting).

## Where these numbers come from

Nothing on this page is quoted from memory. The commands are checked against the
scripts that implement them and the fee against the constant in the source, by
`tests/docs/setup-page.sh`, so a renamed subcommand fails a test instead of
failing your terminal. Where a number cannot be measured in this environment it
is not printed at all — see [how this repository is tested](/docs/development/testing).

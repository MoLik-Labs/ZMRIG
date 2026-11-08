---
title: Docker
description: The miner and the pool as one published image — ghcr.io/molik-labs/zmrig — configured with the same variable names the appliance uses, with a wallet check at every start and an update that only happens when there is something new.
image: https://molik-labs.github.io/ZMRIG/img/og-en.png
---

# Docker

One image, built by this repository's CI from the same commit as the release
binaries, published to GitHub's registry:

```console
$ docker run --rm -e WALLET=4YourAddress… -e POOL=gulf.moneroocean.stream:10001 \
    ghcr.io/molik-labs/zmrig
```

No installation, no compiler, no dependencies. `docker inspect` on a running
container answers with the commit that built it.

| Tag | What it is |
| --- | --- |
| `ghcr.io/molik-labs/zmrig:6.48.0` | one release, and it never changes |
| `ghcr.io/molik-labs/zmrig:latest` | the newest release |
| `ghcr.io/molik-labs/zmrig:edge` | the tip of `BETA` — for testing, not for a rig you care about |

## Check the wallet before anything else

A rig that mines to an address it cannot be paid at is the most expensive mistake
in this project, because it looks exactly like a working rig. The image answers
that question with no pool, no config and no boot:

```console
$ docker run --rm -e WALLET=4YourAddress… ghcr.io/molik-labs/zmrig check
valid   4YourAddress…
  check checksum verified (Keccak-256)
  kind  standard
  net   mainnet
```

A typo is refused, and says which check failed:

```console
$ docker run --rm -e WALLET=4YourAddress…f ghcr.io/molik-labs/zmrig check
invalid 4YourAddress…f
  checksum does not match: at least one character is wrong
```

A typo is refused, and the same check runs again at startup, from the miner
itself, so the verdict is in the log of every container whether or not anyone
asked for it.

## What to set

The variable names are the ones `zmrig-os` writes to `/etc/zmrig/os.conf`, so a
rig that came from the appliance and a rig that came from this image are
configured with the same vocabulary.

| Variable | Default | What it does |
| --- | --- | --- |
| `WALLET` | — | the address this rig is paid to. Required |
| `POOL` | — | `host:port`, or `tls://`, `ws://`, `wss://` |
| `WORKER` | `x` | the worker name. Many rigs on one wallet aggregate into one balance |
| `MODE` | `max` | `max` (full speed), `eco` (most hashrate per watt), `safe` (adds the thermal governor), `light` (256 MiB) |
| `ALGO` | `auto` | `rx/0`, `rx/wow`, … or `auto`, which lets the pool switch the rig between RandomX variants |
| `THREADS` | `auto` | cache-aware, and capped by a CPU quota (below) |
| `DONATE` | `3` | the developer fee, in percent. `0` turns it off |
| `SAFE_TEMP` | `72` | the ceiling `MODE=safe` never crosses, in °C |
| `MSR` | `auto` | `on`, `off`, `auto`; `safe` never writes a register |
| `API_PORT` | `0` | the miner's monitoring API; `0` is off |
| `API_HOST` | `0.0.0.0` | its bind address when `API_PORT` is set — a loopback bind is unreachable from outside a container |
| `API_TOKEN` | — | require `Authorization: Bearer T` on that API |
| `EXTRA_ARGS` | — | more miner flags, split on whitespace and never passed through a shell |

`docker run --rm -e WALLET=… -e POOL=… ghcr.io/molik-labs/zmrig args` prints the
command line it would run and exits — the answer to "why is it using four threads
when this machine has eight".

The full table, including the two variables that exist for tests, is
[doc/DOCKER.md](https://github.com/MoLik-Labs/ZMRIG/blob/BETA/doc/DOCKER.md).

## Two optimisations that matter in a container

**A CPU quota is not an affinity mask.** `docker run --cpus=2` limits the group,
but the process still sees every CPU on the host, so a miner that sizes itself
from the CPU count asks for one thread per core and then shares two cores' worth
of time. That is slower than two threads at full speed: when the quota is spent
the whole group stops, and a thread with a dataset page in cache sits idle for
the rest of the period. The image reads the cgroup quota and, when `THREADS=auto`,
caps the thread count to it:

```console
$ docker run --rm --cpus=2 -e WALLET=… -e POOL=… ghcr.io/molik-labs/zmrig args
zmrig: the container is limited to 2 CPUs (16 visible): 2 mining threads
/usr/local/bin/zmrig -o pool.example:3333 -u 4… -p x -t 2 --profile free …
```

`--cpuset-cpus` needs none of this: the kernel hides the other CPUs and the miner
sizes itself correctly.

**The fee is on the command line.** `--donate-level 3` is always passed
explicitly, so the number a rig pays is visible in `args` instead of being a
default inside a binary. Three percent is the default; `DONATE=0` turns it off and
the build fails its own tests if the code and the documentation disagree.

**Huge pages need one host command and no container flags.** The pool belongs to
the kernel (`sysctl -w vm.nr_hugepages=1168`, or `zmrig-os hugepages` on the
appliance), and an unprivileged container maps it: an anonymous `MAP_HUGETLB`
mapping needs no capability, which was measured — 2336 MB of 2336 MB came from
the pool with `CapEff: 0` and no `/dev/hugepages` mount. `docker run … args`
prints both cases by name, including the 18 % a missing pool costs.

**`--memory` is a real limit and it decides the mode.** `rx/0` maps 2336 MB;
under a smaller limit the miner keeps only the 256 MB cache and rebuilds the
dataset per hash, about 10× slower. It says so at startup and in `--check`, and
the `memory` line prints what it will actually map rather than what it would like
to. Give the container 3 GiB, or pick `MODE=light` deliberately.

## What a container cannot do

MSR writes need `/dev/cpu/*/msr` and root, and thermal sensors are not
namespaced. The image says so instead of failing quietly:

* **MSR writes** (`MSR=on`) need `--device /dev/cpu/0/msr --cap-add SYS_RAWIO
  --user 0`, one `--device` per CPU: a root container poking CPU registers, worth
  5-15 % on bare metal and nothing in a VM. `MSR=auto` leaves it to the miner's
  probe, which will say no.
* **`MODE=safe`** reads the host's sensors, which is what you want — and why the
  governor belongs on the host when the host runs more than one container.
* **The CPU governor and interrupt affinity** are host-wide: `scripts/tune-linux.sh`
  on the host is the other half of `--profile free`.

## Updating

An image is replaced, never patched in place:

```console
$ ./zmrig-docker-update --check     # 0 current, 3 available, 2 cannot tell
$ ./zmrig-docker-update --apply     # pull, then recreate — only if there is something new
```

`--check` runs the checker inside the image already on disk: it resolves the
published tag over anonymous HTTPS and compares the release label with the
version baked into the running container. No Docker socket in the container, no
`node` on the host. `--apply` pulls first and recreates second, because a failed
pull must leave the running miner alone.

Both halves, the compose file and a daily systemd timer are in
`deploy/docker/`. The timer treats "an update was installed" (3) as success and
"the registry could not be reached" (2) as a notice — a miner must not be
restarted because GitHub was briefly unreachable, and a unit that goes red on
every blip is a unit that gets masked.

Pinning is the other option and a good one:
`ghcr.io/molik-labs/zmrig:6.48.0` never changes, so a nightly `compose pull` is a
no-op until you edit the file.

## The pool, from the same image

```console
$ docker run -d --name pool -p 3333:3333 -p 8080:8080 \
    -e DAEMON=http://your-node:18081 \
    -e OPERATOR_ADDRESS=4YourAddress… \
    -v pool-data:/app/pool/data \
    ghcr.io/molik-labs/zmrig pool
```

A rig and the pool it mines to are then never built from different commits. The
pool's own settings are in [running a pool](/docs/fleet/pool).

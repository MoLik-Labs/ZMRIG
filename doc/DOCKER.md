# Docker

The miner and the pool, in one image, published by this repository's CI to
GitHub's registry:

```
ghcr.io/molik-labs/zmrig:6.48.0      one release
ghcr.io/molik-labs/zmrig:latest      the newest release
ghcr.io/molik-labs/zmrig:edge        a build of the tip of BETA
```

Nothing else is needed to run it — no installation, no compiler, no
dependencies. The image is built from the same commit as the release binaries and
the appliance images, and says so: `docker inspect` on a container built from it
answers with the commit, the version and the source URL.

## Before anything: check the wallet

A rig that mines to an address it cannot be paid at is the most expensive
mistake in this project, and it looks like a working rig. The image can answer
the question without a pool, a config or a boot:

```console
$ docker run --rm -e WALLET=46SQLW7DXaq6GJaQbHUFMAhd1VYpfQFJQ2gfZo9TCB8bf9vnf1MUwAD2Fwj6KMsY4RU3oKA3x6hByg8BKg7FfMWn6ysb5tJ \
    ghcr.io/molik-labs/zmrig check
wallet  OK: standard address, mainnet
```

A typo is refused, with the character range that is wrong:

```console
$ docker run --rm -e WALLET=46SQLW7DXaq6GJaQbHUFMAhd1VYpfQFJQ2gfZo9TCB8bf9vnf1MUwAD2Fwj6KMsY4RU3oKA3x6hByg8BKg7FfMWn6ysb5tK \
    ghcr.io/molik-labs/zmrig check
wallet  INVALID: checksum does not match: at least one character is wrong
```

The same check runs again at startup, from the miner itself, so the verdict is in
the log of every container whether or not anybody asked for it.

## Run it

```console
$ docker run -d --name zmrig --restart unless-stopped \
    -e WALLET=4YourAddress... \
    -e POOL=gulf.moneroocean.stream:10001 \
    ghcr.io/molik-labs/zmrig
$ docker logs -f zmrig
```

`WALLET` and `POOL` have no defaults. A placeholder wallet hashes for nobody and a
default pool would be choosing a custodian on your behalf, so the shim refuses
with the name of the missing variable instead of starting.

Flags work too, for anyone who already has a command line:

```console
$ docker run --rm ghcr.io/molik-labs/zmrig -o pool.example:3333 -u 4YourAddress... -p rig-7
```

Anything that does not start with `-` is a command, so the image is also a shell
with a miner in it: `docker run --rm -it ghcr.io/molik-labs/zmrig sh`.

### The environment

The names are the ones `zmrig-os` writes to `/etc/zmrig/os.conf`, so a rig that
came from the appliance image and a rig that came from this one are configured
with the same vocabulary.

| Variable | Default | What it does |
|---|---|---|
| `WALLET` | — | the address this rig is paid to. Required |
| `POOL` | — | `host:port`, or `tls://`, `ws://`, `wss://` (see [POOLS.md](POOLS.md)). Required |
| `WORKER` | `x` | the worker name the pool sees. Many rigs on one wallet aggregate into one balance |
| `MODE` | `max` | `max` (every core, full speed), `eco` (most hashrate per watt), `safe` (adds the thermal governor), `light` (256 MiB cache, 1 GiB RAM) |
| `ALGO` | `auto` | `rx/0`, `rx/wow`, … or `auto`, which advertises every RandomX variant so a pool can switch the rig between them |
| `THREADS` | `auto` | mining threads. `auto` is cache-aware, and is capped by a CPU quota (below) |
| `DONATE` | `3` | the developer fee, in percent of mining time. `0` turns it off; 1–10 are accepted |
| `SAFE_TEMP` | `72` | the temperature `MODE=safe` never goes above, in °C |
| `MSR` | `auto` | `on`, `off` or `auto`. `auto` lets the miner's probe decide; `safe` never writes a register |
| `API_PORT` | `0` | the miner's own monitoring API. `0` is off |
| `API_HOST` | `0.0.0.0` | its bind address *when `API_PORT` is set* — a loopback bind inside a container is reachable only from inside it |
| `API_TOKEN` | — | require `Authorization: Bearer T` on the API |
| `EXTRA_ARGS` | — | further miner flags, split on whitespace and passed as arguments (never through a shell) |
| `CHECK_WALLET` | `1` | print the wallet verdict at startup. The check is advisory; the miner enforces its own rule |
| `POOL_CONFIG` | — | a JSON config for the `pool` job (see [POOLS.md](POOLS.md)) |
| `ZMRIG_BIN` | `/usr/local/bin/zmrig` | which binary to run. For tests and for mounting a build of your own |
| `ZMRIG_CGROUP_DIR` | `/sys/fs/cgroup` | where the CPU quota is read from. For tests |

`docker run --rm -e WALLET=… -e POOL=… ghcr.io/molik-labs/zmrig args` prints the
command line it would run and exits. That is the debugging entry point: when a
rig mines with fewer threads than expected, the answer is in that line.

### A CPU quota is not an affinity mask

`docker run --cpus=2` limits the *group*: the process still sees every CPU on the
host, so a miner that sizes itself from the CPU count asks for one thread per
physical core and then has to share two cores' worth of time. That is slower than
two threads at full speed, because when the quota is spent the whole group is
stopped — a thread that has a dataset page in L3 sits idle for the rest of the
period.

So the image reads the cgroup quota (v2 `cpu.max` or v1 `cpu.cfs_quota_us`) and,
when `THREADS` is `auto`, caps the thread count to it:

```console
$ docker run --rm --cpus=2 -e WALLET=… -e POOL=… ghcr.io/molik-labs/zmrig args
zmrig: the container is limited to 2 CPUs (16 visible): 2 mining threads
/usr/local/bin/zmrig -o pool.example:3333 -u 4… -p x -t 2 --profile free …
```

`--cpuset-cpus` needs none of this: the kernel hides the other CPUs from
`sched_getaffinity`, so the miner sizes itself correctly. An explicit `THREADS`
is always respected — if it is above the quota the container says so and runs
anyway, because an operator who typed a number has a reason.

### What a container cannot do

These are host decisions, and the image says so rather than failing quietly:

* **Huge pages** are reserved by the kernel at boot (`sysctl vm.nr_hugepages`, or
  `zmrig-os hugepages` on the appliance). A container needs `--cap-add=IPC_LOCK`
  and a `/dev/hugepages` mount to use them. Without that the miner runs on 4 KiB
  pages, which costs a few percent.
* **MSR writes** (`MSR=on`) need `/dev/cpu/*/msr`. Opening that from a container
  lets it poke CPU registers; the default `MSR=auto` leaves the decision to the
  miner's probe, which will say no.
* **Thermal readings** come from `/sys/class/hwmon`, which is not namespaced.
  `MODE=safe` sees the host's sensors, which is what you want, but it is also
  why the governor belongs on the host when the host has more than one container.

## The other job: the pool

The same image runs the Ocean Pool, so a rig and the pool it mines to can never be
built from different commits:

```console
$ docker run -d --name pool -p 3333:3333 -p 8080:8080 \
    -e DAEMON=http://your-node:18081 \
    -e OPERATOR_ADDRESS=4YourAddress... \
    -v pool-data:/app/pool/data \
    ghcr.io/molik-labs/zmrig pool
```

`DAEMON` and `OPERATOR_ADDRESS` are documented in [POOLS.md](POOLS.md), along with
the rest of the pool's environment. `deploy/docker/compose.yaml` starts both jobs
from the same file (`docker compose --profile pool up -d`).

## Updating

An image is replaced, never patched in place: the miner and the pool are the
image's `COPY`d content, so updating means starting a newer container. Two halves,
both in `deploy/docker/`:

```console
# on the host, with the compose file from this repository
$ ./zmrig-docker-update --check     # exit 0 current, 3 available, 2 cannot tell
$ ./zmrig-docker-update --apply     # pull, then recreate — only if there is something new
```

`--check` runs the checker *inside the image already on disk*, which resolves the
published tag over anonymous HTTPS and compares the release label with the
version baked into the running container. It needs no Docker socket in the
container and no `node` on the host. `--apply` pulls first and recreates second: a
failed pull leaves the running container untouched, because the alternative is a
miner that is down because the registry was.

The checker is also inside the image:

```console
$ docker run --rm ghcr.io/molik-labs/zmrig update --check
running    6.48.0
available  6.49.0  (molik-labs/zmrig:latest)
run 'zmrig-docker-update --apply' on the host to install it
```

`--json` prints the same thing as one object, for a dashboard.

The checker reads five variables. Three are baked into the image by the
workflow; the other two exist so the checker can be pointed somewhere else in a
test, and are documented here for the same reason `ZMRIG_BIN` is.

| Variable | Default | What it does |
|---|---|---|
| `ZMRIG_VERSION` | built in | the release this image is. The comparison is against it |
| `ZMRIG_TAG` | `latest` | which published tag to compare with |
| `ZMRIG_IMAGE` | `molik-labs/zmrig` | the package, without the registry |
| `ZMRIG_REGISTRY` | `https://ghcr.io` | the registry to ask |
| `ZMRIG_TIMEOUT` | `10000` | milliseconds before the check gives up (exit 2) |

### Automatically

`deploy/docker/zmrig-docker-update.{service,timer}` run `--apply` once a day:

```console
$ sudo install -m 0755 deploy/docker/zmrig-docker-update /usr/local/bin/
$ sudo mkdir -p /etc/zmrig && sudo cp deploy/docker/compose.yaml /etc/zmrig/
$ sudo cp deploy/docker/zmrig-docker-update.service \
           deploy/docker/zmrig-docker-update.timer /etc/systemd/system/
$ sudo systemctl enable --now zmrig-docker-update.timer
```

The timer treats exit code 3 ("an update was available and has been installed") as
success and exit code 2 ("the registry could not be reached") as a *notice*: a
miner must not be restarted because GitHub was briefly unreachable, and a nightly
unit that goes red on every blip is a unit that gets masked.

Pinning is the other option, and a good one: `ghcr.io/molik-labs/zmrig:6.48.0`
never changes, so `docker compose pull` is a no-op until you edit the file.

## Building it yourself

```console
$ docker build -f deploy/docker/Dockerfile -t zmrig:dev .
$ docker run --rm zmrig:dev version
```

The build is the release build: two stages, the engine compiled from `src/` and
`zmrig/` in the first, and a runtime layer with no compiler in it. `--build-arg
ZMRIG_PORTABLE=` (empty) builds for the host CPU instead of the baseline x86-64,
which is only correct if the image will only ever run on that machine.

`deploy/docker/Dockerfile` is the published image. `deploy/Dockerfile` is the
Render/Fly pool service and stays deliberately minimal: it does not carry the
miner's environment shim or the update checker.

## Verifying a pull

Every published image carries OCI labels (version, revision, source, licence) and
a build provenance attestation, so what is running can be traced to a commit:

```console
$ docker inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' \
    ghcr.io/molik-labs/zmrig:latest
$ docker buildx imagetools inspect ghcr.io/molik-labs/zmrig:latest
```

The image is published from CI with `GITHUB_TOKEN` and a `packages: write` scope on
the repository; nothing is built on a maintainer's laptop.

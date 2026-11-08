# The tool, in one place

Everything a rig owner *runs* — as opposed to the miner, the pool and the docs —
is listed here, with the tree it lives in and the test that keeps it honest. If
you are looking for "where do I change what the installer does", this page is the
answer; if a file is not in the table, it is not part of the tool.

| Entry point | What it is | Lives in | Tested by |
| --- | --- | --- | --- |
| `oneclick.sh` | build, tune, install, supervise, update, purge — the one command | `oneclick.sh` (root, because the documented install is `curl …/BETA/oneclick.sh \| sudo bash`) | `tests/oneclick/*.sh` |
| `zmrig-os` | the appliance CLI: setup, plan, doctor, hugepages, update, rollback | `os/overlay/usr/local/bin/zmrig-os` (the path it must have *inside the image*) | `os/tests/*.sh` |
| `zmrig-os run` | the supervisor that keeps the miner alive, rotates logs and reboots after five failed starts | `os/overlay/usr/local/bin/zmrig-os` | `os/tests/control.sh` |
| `zmrig-os plan` helpers | the arithmetic: thread counts, huge page counts, memory budget, restart delay | `os/plan.sh` | `os/tests/plan.sh` |
| `zmrig-tune` | huge pages, THP, CPU governor, IRQ steering, MSR | `scripts/tune-linux.sh` | `tests/oneclick/tune-targets.sh` |
| container entry | environment → miner flags, the `args`/`plan`/`check`/`pool`/`update` verbs | `deploy/docker/entry.js` | `deploy/docker/tests/*.test.js` |
| container image | the two-stage build that publishes `ghcr.io/molik-labs/zmrig` | `deploy/docker/Dockerfile` | `deploy/docker/tests/dockerfile.test.js` |
| image update timer | `systemd` timer that pulls a newer image on a rig | `deploy/docker/zmrig-docker-update*` | `deploy/docker/tests/script.test.js` |
| bootable image | the ISO build and its overlay (`os/overlay/`) | `os/build-iso.sh` | `tests/oneclick/plan.sh`, `os/tests/*.sh` |
| release helpers | which ISO is current, version consistency | `scripts/latest-iso.sh`, `scripts/find-zig.sh` | `tests/releases/*.sh` |

Two rules, both enforced by `tests/lint/tool-layout.sh`:

1. **A tool entry point is listed above.** A new top-level script is a new
   surface a rig owner has to trust; it does not get to appear unannounced.
2. **Every listed entry point is tested.** A tool without a test is a tool that
   breaks on somebody else's machine, silently, at 3 a.m.

## Why the files are not all in this directory

They cannot be: `zmrig-os` has to be at `/usr/local/bin/zmrig-os` inside the
image, `oneclick.sh` has to be at the repository root for the one-line install,
and the container files have to sit where `docker build` copies them from.
Moving them would mean wrappers that change which file a `curl | bash` reads.

So the layout is by *audience*, and this page is the index:

| Tree | For | Not to be confused with |
| --- | --- | --- |
| `oneclick.sh`, `scripts/`, `os/`, `deploy/` | running a rig: install, tune, supervise | the miner itself |
| `zmrig/`, `src/` | the miner: Zig front end, the C++ RandomX engine | anything a user configures |
| `pool/`, `proxy/`, `serve/`, `fleet/` | services you can host | the rig's tool |
| `doc/`, `site/`, `web/` | documentation, in two languages | `docs/` and `vi/`, which are the *built* copies of `site/` that Pages serves |

## Branches

`ALPHA` → `BETA` → `master`, and nothing else that is meant to live:

| Branch | What it carries | Install from it |
| --- | --- | --- |
| `ALPHA` | the next release; it may break between commits | `MINER_BRANCH=ALPHA sudo -E ./oneclick.sh install` |
| `BETA` | what is being installed today; every merged change lands here first | the default |
| `master` | the last released version | `MINER_BRANCH=master …` |

The tool is the same code on all three — a release is a commit that was tested on
`BETA`, not a second copy of the tool.

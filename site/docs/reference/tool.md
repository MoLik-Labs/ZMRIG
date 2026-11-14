---
title: The tool, file by file
description: Which file to edit for the installer, the tuner, the appliance or the container — and the test that keeps each one honest.
image: https://molik-labs.github.io/ZMRIG/img/og-en.png
---

# The tool, file by file

The miner is `zmrig/`. Everything else a rig owner *runs* — install, tune,
supervise, update, the container — is the tool, and it has one index:
[`tool/README.md`](https://github.com/Molik-Labs/ZMRIG/blob/BETA/tool/README.md).
This page is the same map for the docs, with the reason each file is where it is.

| You run | It is | Change it when | Tested by |
| --- | --- | --- | --- |
| `oneclick.sh` | build, tune, install, supervise, update, purge | the install does the wrong thing on a clean machine | `tests/oneclick/` |
| `zmrig-os` | the appliance CLI: `setup`, `plan`, `doctor`, `hugepages`, `update`, `rollback`, `run` | a decision the image makes at boot is wrong | `os/tests/` |
| `os/plan.sh` | the arithmetic: threads, pages, memory budget, restart delay | a number has to be computed differently | `os/tests/plan.sh` |
| `zmrig-tune` | huge pages, THP, governor, IRQ steering, MSR | the host is not being prepared for RandomX | `tests/oneclick/tune-targets.sh` |
| `deploy/docker/entry.js` | environment → miner flags, and the `args`/`plan`/`check`/`pool` verbs | a container gets a different answer than a host | `deploy/docker/tests/` |
| `deploy/docker/Dockerfile` | the two-stage image behind `ghcr.io/molik-labs/zmrig` | the image is bigger or slower than it needs to be | `deploy/docker/tests/dockerfile.test.js` |
| `os/build-iso.sh` | the bootable appliance | the ISO should differ from the install | `tests/oneclick/plan.sh` |

## Why they are not in one directory

They cannot be. `zmrig-os` has to live at `/usr/local/bin/zmrig-os` *inside the
image*, `oneclick.sh` has to sit at the repository root for the documented
`curl … | sudo bash` install to work, and the container files have to be where
`docker build` copies them from. Moving them into one folder would mean
wrappers, and a wrapper changes which file a `curl | bash` actually reads — the
one thing a one-line install must not be ambiguous about.

So the layout is by audience, and the index is what makes it one place:

| Tree | For | Not to be confused with |
| --- | --- | --- |
| `oneclick.sh`, `scripts/`, `os/`, `deploy/` | running a rig | the miner |
| `zmrig/`, `src/` | the hash engine and its front end | anything a user configures |
| `pool/`, `proxy/`, `serve/`, `fleet/` | services you can host | the rig's tool |
| `doc/`, `site/`, `web/` | documentation in two languages | `docs/` and `vi/`, the built copies Pages serves |

## The two rules

`tests/lint/tool-layout.sh` runs in CI on every push, and it enforces what a
list like this is worth:

1. **Every path on the index exists**, and every top-level script is on it. A new
   entry point does not get to appear unannounced.
2. **Every entry point it names has a test directory that exists.** A tool with
   no test breaks on somebody else's machine, silently, at 3 a.m.

## Branches

`ALPHA` → `BETA` → `master`, three branches that matter:

| Branch | What it carries | How to install from it |
| --- | --- | --- |
| `ALPHA` | the next release; it may break between commits | `MINER_BRANCH=ALPHA sudo -E ./oneclick.sh install` |
| `BETA` | what is being installed today; every merged change lands here first | the default |
| `master` | the last released version | `MINER_BRANCH=master …` |

The tool is the same code on all three: a release is a commit that survived
`BETA`, not a second copy of the tool.

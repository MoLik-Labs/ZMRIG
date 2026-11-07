# 6.48.0 — the boot that comes back configured

Five bugs in the installed appliance, all of them quiet: each one made a rig look
healthier than it was, and none of them printed a warning. Found by reading the
boot path against the tests that claim to cover it.

## The rollback dropped the kernel parameters

An installed rig keeps a 1024-byte GRUB environment block with `zmrig_slot` in it.
It also keeps `zmrig_extra`: `isolcpus=`, `nohz_full=`, `rcu_nocbs=` and the
thermal cap, written there by `zmrig-os isolate` because none of them can be
applied after boot. The initramfs's `write_grubenv` wrote a block containing the
slot and nothing else, so the automatic rollback — the path that runs when nobody
is watching — threw every other key away. The rig came back on the other slot,
mining on every core, and the log said it had rolled back successfully.

Both writers now build the block with `plan_grubenv_block` in `os/plan.sh`, which
parses what is there, replaces one key, and pads back to exactly 1024 bytes. A key
too large for the block is refused rather than written truncated.

## The installed menu never read `zmrig_extra`

Worse than the first one, because it was unconditional: the `grub.cfg` that
`zmrig-os install` writes implemented `load_env` and then used `${zmrig_params}`
only. `zmrig-os isolate 4` wrote the parameters, printed `next boot: isolcpus=…`,
and the next boot ignored them — on every installed rig, from the first release
that had `isolate`. Every entry now passes `${zmrig_extra}`, `set zmrig_extra=""`
is in the header so the reference is defined with or without a block, and the
generator is a function (`grub_cfg_for`) so `os/tests/control.sh` can assert the
menu rather than the source file.

## `zmrig.os.nostart=1` did not survive the boot

The initramfs wrote the flag to `/run/zmrig/nostart`. OpenRC mounts a fresh tmpfs
over `/run`, so by the time the supervisor looked, the flag was gone and the rig
mined. The same file warns, three hundred lines earlier, that `/run` is exactly
the wrong place for a marker that has to outlive the handover. It is now written
to `/etc/zmrig/nostart` (overlay, one boot) as well, and the supervisor checks
both.

## Every rig reported a temperature of zero

`thermal_now` prints `68 C` for people. The fleet payload parsed it with a
digit test, which rejects the space, and fell back to `0`. So the server's
`alert_temp` comparison was against zero for every rig in the fleet: the overheat
alert could never fire, and `/devices` showed a column of `0 °C` that looked like
a sensor problem. `thermal_c` returns the number, `fleet_body` uses it, and
`os/tests/fleet.sh` proves 68 arrives at the real server code.

## The supervisor's failure counter never reset

`zmrig-os run` reboots after five failed starts in a row. The count only ever went
up: a rig that restarted once a month rebooted after five months, and the log said
"five failed starts" about a run of failures that had started in the spring. A
start that lasts ten minutes now clears it (`plan_healthy_run`), and the restart
delay doubles from 10 s to five minutes (`plan_restart_delay`) instead of
reconnecting to the pool every ten seconds through an outage.

## An update with no checksum is refused

`verify_sha` returned success when the manifest had no `binary_sha256`, which
means a truncated download, an error page behind a redirect, or a mirror serving
the wrong file was installed as the miner and the supervisor was restarted into
it. The automatic path now uses `verify_sha_required` and says so in one line;
the interactive paths keep the optional behaviour, where an operator is present
to decide.

## 1 GiB pages are asked for, and the answer is reported

RandomX reads a 2080 MB dataset in random 64-byte stripes. At 4 KiB that is a TLB
miss per few accesses and about 28 % of the hashrate; at 2 MiB it is 1 040 entries
spread over a TLB that holds roughly that many; at 1 GiB it is two. The mapper
always tried 2 MiB. It now tries 1 GiB first, then the 2 MiB pool, then anonymous
memory with `MADV_HUGEPAGE`, and the startup line says which one answered —
`huge pages 2336 MB (explicit, 1 GiB pages)` against `(explicit, 2 MiB pages)`
or `0 MB (THP fallback)`. The claim in the old output was "explicit", which was
true of both and told nobody anything.

What it cannot do is create the pool. Gigantic pages are contiguous physical
memory carved out before the machine fragments, so this is a kernel parameter and
a reboot, not a sysctl — on the validation host, with 3.9 GiB free and nothing
else running, writing `nr_hugepages` under `hugepages-1048576kB` returns success
and leaves the pool at 0. The new `zmrig-os hugepages` command makes it a
decision: `zmrig-os hugepages` prints both pools and what the current algorithm
needs, `zmrig-os hugepages 1g 3` writes `default_hugepagesz=1G hugepagesz=1G
hugepages=3` into the GRUB environment block the next boot reads, and `zmrig-os
hugepages off` removes it.

Reserving both pools is now impossible, which is the bug this would have
shipped: `hugepages=3` on the kernel line takes 3 GB of physically contiguous
memory at boot, and the initramfs would then ask `/proc` for Monero's 1 168 × 2 MiB
as well — 5.3 GB on a 4 GB machine, with the gigantic pool already held, so the
second write either fails or wins by pushing the rest of the system into swap
while the dataset is built. `reserve_pages` in the initramfs and `zmrig-os tune`
both skip the 2 MiB reservation when the gigantic pool already covers what this
run needs, and say so in the log.

That block also carries `isolcpus=`, and the writer is now one function
(`write_boot_params`) that composes both settings, because reserving pages and
then isolating CPUs used to be two writers to one value — the same class of bug
that cost every isolated rig its `isolcpus=` in 6.48.0. `zmrig --check` prints
the pool and how many pages this run would take from it, and `doctor` reports it
as information rather than a failure: not having a 1 GiB pool is normal, and the
fallback to 2 MiB pages is where most of the gain already is.

The extra 1-3 % is **not measured here** — no 1 GiB page can be reserved in this
environment, so that path has never run on it. The fallback path has, and so has
the composition of the kernel parameters.

The pool's share verifier had two faults that only show up with the binary it
ships with. `zmrig --verify-share` printed its fee banner on **stdout** before
switching the log to stderr, and stdout is the protocol: the first share after a
verifier was restarted came back as "unreadable verifier output" and was
dropped. The binary now sets the sink before the banner, and the pool treats a
`[timestamp]` line on that pipe as noise rather than as a reply.

The second one is worse and would have shown up as a slow pool: the queue was
only drained when a caller arrived, so with the default one verifier per core,
shares queued behind a busy slot waited for the *next* share to arrive — and
timed out. Measured after the fix: 103 shares/s on 2 vCPU with two verifiers,
530 ms for the first (cache build).

The fleet's version now has one home. The dashboard footer was printing 6.44.0
and the Discord user agent 6.37 while the release was 6.48, because a constant in
source only moves when somebody remembers; both now read `package.json` once, and
a test fails on any version literal left in `fleet/src`.

The measurement that goes with it: 2026-11-07, `--bench=3000`, alternating
between the two configurations on the same host, 897–900 H/s on 4 KiB pages
against 1090–1094 with a reserved 2 MiB pool, **+21.5 %**. A back-to-back pair
earlier the same day read 678 against 913 and came out at +34.7 %; that was the
sandbox's throughput moving 20 % between hours. Numbers from this host are only
worth the difference between two runs that take turns.

## Brotli was spending the wrong resource

The quality policy charged the scarce resource — a tenth of a CPU on a free
instance — to save bytes nobody is short of. Measured on the same three shapes
(three runs, best of three): a 32 KB page at quality 11 takes 43 ms and saves
0.1 KB against quality 10 at 14 ms; the 488 KB bundle at 11 takes 948 ms and
saves 11 KB against 9 at 44 ms. The policy is now 11 below 8 KB, 10 to 64 KB, 9
to 1 MB and 6 above, which compresses the whole 175-file site in 1.9 s instead of
2.2 s and costs 2.7 % more bytes on a page — the trade a 0.1 CPU host wants.

## The hosted site came back unstyled

The committed `web/` is the GitHub Pages build, and in it every internal
reference is `/ZMRIG/assets/...` — that is what `baseUrl` does. `serve/` answers
from the root of its own domain, so the home page arrived with a stylesheet link
to a path that does not exist there, and the CSS, both bundles, the icons and
every internal link were `404`. The page still rendered, so nothing failed
loudly: it was just a site with no stylesheet, and the documentation's own
"why it is fast" numbers were measured on a build where the assets were never
requested.

`assets.rebase()` now reads the prefix out of the home page at boot and removes
it from every text body in memory — 125 files, 4 072 references, 20 ms, once.
Absolute URLs are deliberately untouched, because the canonical link and the
`og:image` must keep pointing at the Pages site. A request that still carries the
prefix (`/ZMRIG/docs/intro`, from a bookmark or from a link on the Pages site) is
a `301` to the stripped path, and `/healthz` reports `site.rebased_from`, so the
next deploy that lands the wrong build says so in a JSON field instead of in a
screenshot. Building with `SITE_BASE_URL=/` still produces a build with nothing
to rewrite.

A test now follows every link in the committed build (`host/tests/site.test.js`,
61 pages, 73 distinct same-origin references) and fails on a single 404. It is the
test that was missing: the build's own links were never fetched by anything, which
is why a site with no stylesheet passed every check in the repository.

Two smaller things found while measuring it. The warm queue — the files
compressed in the background after the socket opens — was `every page, then every
asset`, sliced to 24; the site has 61 pages, so it never contained an asset, and
the stylesheet and both bundles were compressed on first request on every deploy.
It now takes the two home pages, then the files those pages actually reference
(parsed out of their HTML, in document order), then the other pages. And the
HTTP server had no opinion about idle sockets: Node closes one after 5 s, Render's
proxy keeps it for 60, and a documentation page with thirty assets is enough to
hand the process a socket it has already dropped. `keepAliveTimeout` is 65 s,
`headersTimeout` 66 s, `requestTimeout` 30 s.

## The MSR preset is no longer opt-in

Disabling the CPU's hardware prefetchers is worth 5-15 % on bare metal, and it
was behind a flag almost nobody passed: `--msr` had to be typed, `oneclick.sh`
wrote `wrmsr: true` and an appliance user got it only if `MSR=on`. The default is
now `auto`, which probes the machine the way `--check` always did — is there a
preset for this CPU, does `/dev/cpu/0/msr` answer, can it be written — and then
applies the preset or prints one line saying why not. Nothing is written on a
machine that cannot take it, and the old values are still restored on exit.

`--no-msr`, `"msr": false` and `MSR="off"` all still mean what they said; `safe`
mode never touches a register whatever the setting is. `oneclick.sh` and
`config/performance.json` now write `"msr": "auto"` instead of `"wrmsr": true`,
so a config file copied between a laptop and a VPS stops promising a register
write to whichever machine cannot do it.

## Two settings the image was missing

`scripts/tune-linux.sh` has set `kernel.numa_balancing=0` and
`transparent_hugepage/defrag=defer` since 6.30. The appliance did neither: an
installed rig was the one place NUMA balancing stayed on, migrating pages of a
dataset that is walked uniformly at random, and khugepaged was free to start
direct compaction against the threads building it. The sysctl file declares the
first and the initramfs sets the second, before the dataset exists.

## Also

- The site's own title and footer said "1 % developer fee" a release after the
  constant moved to 3 %. `scripts/verify-fee.sh` now reads
  `site/docusaurus.config.js` as well, and fails on a stale rate there.
- Shellcheck runs at `-S warning` in CI, for every script in the repository, in
  the dialect each shebang asks for (`tests/lint/shellcheck.sh`, 56 scripts). That
  found a `for` loop over a quoted string that only ever ran once, an `rm -rf` in
  `scripts/publish-site.sh` that an empty `OWNED_DIRS` could have pointed at `/`,
  three dead variables, and a keyword used as a variable name.
- `os/make-initramfs.sh` counts the modules it staged instead of leaving the
  count in a pipeline's subshell, so "no kernel modules staged" is reported from
  a number.

Tests: `os/tests/plan.sh` 113, `os/tests/control.sh` 240, `os/tests/fleet.sh` 27,
`zmrig/tests/cli.sh` 49, `scripts/verify-fee.sh` 10, oneclick ×5,
`tests/lint/shellcheck.sh` 56 scripts.

# 6.47.0 — a fee that is stated, and the pages that prove it

The developer fee is 3 % of Monero mining time. This is a user-visible change
from 1 %, and it is stated in the same places the old number was, because the
mechanism that makes the fee honest is not the size of it: the rate is one
constant in `zmrig/src/fee.zig`, the banner is printed from that constant at
compile time, `--check` prints it next to the destination address, the log prints
it at startup, the API reports it, and `scripts/verify-fee.sh` fails the build if
any of them disagree.

## Why 3 %

Because that is what the work costs, and because a number that is stated can be
argued with. The fee pays for the parts that do not mine: CI builds and publishes
every image, the fleet and the site need a host and somebody to watch it, and the
benchmarks behind `doc/PERFORMANCE.md` take a machine and a day each. A rig at
1 kH/s pays about a dollar a month at 3 %.

Nothing about it is hidden, and it is still a setting:

```bash
zmrig ... --donate-level=0      # off
zmrig ... --donate-level=1      # the old default
zmrig-os setup --donate 5       # on an appliance, written to os.conf
```

The banner can no longer drift from the code: it is
`std.fmt.comptimePrint` over `fee.default_percent`, so a rate change that forgets
the banner is a compile error rather than a sentence nobody re-reads.

## The audit now checks the prose too

`scripts/verify-fee.sh` had seven checks; it has nine:

* the pages state the same rate as the constant — `doc/FEE.md`, both site
  languages and the README are read, and a page that never mentions the number
  fails the build;
* the appliance default (`DONATE` in `zmrig-os`) equals the binary's.

That is the difference between a policy and a claim: before this, a fee change
could update the constant, the binary and the log and quietly leave the
documentation behind.

## `doc/FEE.md` states what it costs

A table of what 0, 1, 3, 5 and 10 percent are worth per month on a single rig,
with the arithmetic shown, so the cost is read rather than discovered from a
payout that came up short. The cadence is restated for the new rate: 60 s of
Monero mining every 33 minutes, which is what the debt clock produces at 3 %.

## Also in this release

* `DONATE="3"` in `os/overlay/etc/zmrig/os.conf.example`, with the comment that
  says it is a setting and not a rule, and `doc/OS.md` matching it.
* The installer writes `"donate-level": 3` explicitly, so the value is visible in
  `config.json` rather than implied.
* Both site languages, the README badge, the summary table and every page that
  quoted the old rate.

Tests: the fee audit (9 checks, source and binary), `zmrig/tests/cli.sh`
(default rate and a changed rate), `os/tests/control.sh` (the appliance args keep
the rate on the command line), `tests/oneclick/config.sh` (the installer writes
it).

# 6.46.0 — one service, three jobs, on the one instance a free month allows

A free Render workspace gets 750 instance hours per calendar month, shared by
every free service, with no rollover. A 31-day month is 744 hours. So one
always-on service fits and a second one does not: the workspace goes over the
limit and Render suspends the free services until the next month. Two blueprints
in the repository described two deployments, and the person applying both found
out four weeks later.

`host/server.js` is now the deployment: one process, one port, one health check,
answering all three clients.

| who | asks for | answered by |
| --- | --- | --- |
| people | `/`, `/vi/`, `/download`, `/iso/v3`, `/api/releases.json` | the committed build in `web/` |
| rigs | `POST /v1/hello`, once a minute each | the device protocol |
| the bots | nothing — they poll Telegram and Discord outwards | two long-poll loops |

The site is `web/`, the committed output of `site/`, so a deploy installs nothing
and spends no build minutes; the repository has no runtime dependencies at all.
The dashboard is deliberately not mounted: the public front door is the
documentation, and `cd fleet && npm start` is what serves the dashboard.

`/healthz` answers for all three jobs, so a deploy that lost one of them is
visible from the outside rather than from a user:

```json
{"ok":true,"bots":{"telegram":true,"discord":false},
 "fleet":{"rigs":3,"known":4},
 "site":{"root":"/opt/render/project/src/web","files":244},
 "uptime_s":3600,"rss_mb":64}
```

A control plane that refuses to start without a bot token is right when it does
nothing else, and wrong here: with no token and no roster the host serves the
documentation and accepts check-ins, and says in the log that no bot is
connected. Only a broken `PORT` stops it.

## Compression moved from boot to the first request

The site host used to compress every file at boot with Brotli at quality 11.
That is a few milliseconds on a 2 vCPU development machine and minutes on the 0.1 CPU a free
Render instance gets — minutes during which the health check fails and the deploy
is rolled back. The same boot now takes **17 ms** for 244 routes and 6.84 MB.

Each file is compressed the first time somebody asks for it, and kept. The
quality follows the size (11 up to 32 KB, 9 up to 256 KB, 6 above it), because
Brotli's cost grows far faster than its gain. A browser that accepts Brotli never
causes a gzip copy to exist. `.br`/`.gz` sidecars written at deploy time are still
preferred, so a build that ships them does no work at all, and a sidecar older
than its file is still ignored. The pages most likely to be opened first are
compressed just after the socket opens, one per tick, so a cold start answers
immediately and the warm copy is there by the time somebody clicks.

Measured here, 2 vCPU, keep-alive, 60 requests per route:

| path | first request | p50 | p95 |
| --- | ---: | ---: | ---: |
| `/` | 31.0 ms | 0.34 ms | 1.12 ms |
| `/docs/intro` | 33.5 ms | 0.31 ms | 0.45 ms |
| `/download` | 62.7 ms | 0.29 ms | 1.02 ms |
| `/vi/` | 22.1 ms | 0.26 ms | 0.49 ms |

## The blueprints say one thing each

* `render.yaml` (root) — the one service: bots, rigs and documentation.
* `fleet/render.yaml` — the control plane alone, with the dashboard, for a
  standalone run or a paid plan.
* `deploy/render-pool.yaml` — the pool alone. The duplicate site service is gone
  from it: the root blueprint already serves those bytes.

Nothing here is stored on the host. The filesystem is ephemeral, `FLEET_STATE` is
a scratch cache, and `FLEET_ROSTER` in the environment is what a restart comes
back to.

## Also in this release

* `host/tests` — 7 checks over a real socket: a rig and a browser on the same port
  are answered by different halves, the health check reports all three jobs, the
  dashboard is not published, and a missing site does not stop the rigs. The new
  CI job also boots the real process and asks it.
* `serve` — 45 → 46 checks, with the lazy tables and the quality policy covered.
* Documentation, both languages: `doc/WEB.md`, `doc/FLEET.md`,
  `site/docs/appliance/web.md`, `site/i18n/vi/.../web.md`, and the fleet pages
  that described the deployment.

Tests: `host` 7, `serve` 46, `fleet` 84, `pool` 34, `proxy` 60, docs links 103,
published pages 22, identity 25 — all passing.

# 6.45.0 — the numbers the rig boots with and the numbers it is tuned with are one file

Three programs had to agree on how much memory to reserve and which CPUs to keep
for mining: the initramfs, which reserves pages before userspace exists, the
control tool, which re-applies them at every boot, and the tuning script, which
does the same on any Linux host. Each had its own copy of the arithmetic, and
copies drift — a rig could boot with Monero's 2.3 GB reserved and then be tuned
for Scala's 192 MB thirty seconds later.

`os/plan.sh` is now that arithmetic, once: pure POSIX sh functions over their
arguments and `/sys`, with no side effects, so the initramfs can call them before
there is a shell and a test can call them on a fake tree. `plan_need_mb`,
`plan_pages`, `plan_iso_cpus`, `plan_threads`, `plan_mask_hex`,
`plan_housekeeping` and `plan_join_list`. The tuning script sources the same file
and asks it, and takes `--algo`, `--mode`, `--threads` and `--pages` to be told
what the config says instead of guessing.

## Isolation that survives a reboot

`zmrig-os isolate N` keeps N logical CPUs for mining — as whole SMT cores, from
the top, never cpu0 — pins the miner to them with `--cpu-affinity`, moves the IRQ
masks to what is left, and writes `isolcpus=`, `nohz_full=` and `rcu_nocbs=` into
the GRUB environment block. That block holds more than one key now (`zmrig_slot`
and `zmrig_extra`), and each write merges the 1024-byte block instead of
replacing it: switching slots no longer forgets the kernel parameters, and
changing the parameters no longer forgets the slot.

The thread count follows the mask. A `balanced` rig on a machine where the miner
may only run on three cores pins three threads, not seven: a pinned count larger
than the mask is oversubscription, not throughput. `ISOLATE=0` hands the machine
back to the `AFFINITY=auto` mask from 6.44.0, which is the default when nothing is
isolated.

## A tuner that is told what the rig is

`HUGEPAGES` is documented and obeyed: empty sizes the pool from the algorithm,
`0` turns the reservation off, a number is taken literally — `zmrig-os tune`
passes the count straight through instead of replacing it with "2M". The
reservation itself is capped at installed RAM minus 512 MB, so a 1 GB box gets a
partial pool it can use rather than a write the kernel clamps to zero.

`--algo` and `--mode` reach the tuner, so a Scala rig no longer reserves Monero's
dataset, and `--mode eco` reserves for the threads eco actually runs. It also
composes with 6.44.0's NUMA and interrupt steps: they are passed alongside.

## Sensors: the die, not the guess

`thermal_now` read whichever hwmon chip answered last, which on a desktop board
is as likely to be a Super I/O as the CPU. It now reads in tiers — the CPU die
(`coretemp`, `k10temp`, `zenpower`, `k8temp`, `x86_pkg_temp`), then the board
(`nct6775`/`nct6683`/`nct6687`, `it87`, `asus`, `dell_smm`, `thinkpad`,
`sp5100_tco`, `applesmc`), then anything else, and `acpitz` last, because it is a
southbridge estimate that reads 10-20 °C below the die. Inside a tier it takes
the hottest reading, not the last one read: a governor watching core 0 while
core 5 cooks is not a governor.

## Hardware compatibility

The initramfs now carries the network drivers a rig actually has — `e1000e`,
`igb`, `r8169`, `igc`, `atlantic`, `tg3`, `virtio_net`, USB tethering — and the
eMMC/SD path (`mmc_core`, `mmc_block`, `sdhci`, `sdhci_pci`, `sdhci_acpi`), so a
machine that boots from a USB stick can also reach a pool, and a small
single-board machine can find its own storage.

## The doctor answers in JSON

`zmrig-os doctor --json` is one object with one entry per check and a non-zero
exit when anything failed, which is what a monitoring agent needs instead of
prose. `status` grew `hugepages` and `cpus` lines: the two numbers a "why is it
slower than yesterday" question turns into. A damaged image that lost
`os/plan.sh` still answers `doctor` and `status` — with a failed `plan` line —
instead of dying on a missing function.

## Forty rigs, one wallet, on the pool side

6.43.0 summed the hashrate the fleet reports per wallet. This is the other half —
what the pool itself does with a hundred connections on one address. The ledger
already keyed by wallet, and now it says so: per-rig
counters, `walletSummary()` over the same share records the payout uses, and
`GET /api/worker/<wallet>` returning the balance, the summed hashrate and every
rig behind it — including the rig that went quiet, listed with a zero rate. The
rig map is capped and evicts the least recently seen, because a rig name is free
text from a public connection. Wallet and rig rates use one shared window span,
so the rigs add up to the wallet and the wallets add up to the pool.

## Also

* `zmrig-os quickstart --wallet … ` configures, tunes, enrols and starts in one
  command, and reports whether the miner actually started.
* `os/tests/plan.sh`: 84 tests over the memory and CPU arithmetic, including
  fake `/sys` trees for SMT topology and sensor tiers. `control.sh` is 217, the
  pool's unit tests 31.
* `plan.sh` ships in the initramfs, the squashfs and the shellcheck list; the ISO
  self-check knows about it.
# 6.44.0 — the machine is asked what it can do

RandomX's fast mode wants AVX2, AES-NI and 2 GB of memory for the dataset, and a
machine missing any of them still hashes — several times slower. Until now the
only way to find out was to mine and compare the rate to a number on the site.

## What changed

* **`zmrig-os hardware`** prints the CPU, the flags that matter, the memory and a
  one-word verdict — `full`, `light`, `slow` or `small` — with a sentence saying
  what to do about it. It exits non-zero on the last two, so a provisioner stops
  on the box that will never be fast instead of adding it to the pile.
* **`doctor` prints the verdict** on every boot, next to the rest of the checks.
* Flags are read from **every processor's line**, not the first one's, so a hybrid
  CPU or a truncated `cpuinfo` does not produce a wrong answer.
* `ZMRIG_OS_PROC` joins `ZMRIG_OS_SYS`: both point the tool at a fixture tree, which
  is how the four verdicts are tested on a machine that has one of them.

## Also in this release

* **The installer and the tuner now run in CI.** They were only ever run by hand:
  `oneclick.sh`'s six decision tests, the shallow-clone branch switch, the tuner's
  targets against a fake `/proc`, shellcheck, and the download helper. A silent
  `update` regression had no way to be caught before this.
* **`doc/FLEET.md` says what is hosted and what is not**, in one place: one
  process — the page and the bots — no pool, no database, no storage, no accounts;
  the documentation site is static and lives on GitHub Pages.
* **Both site languages** explain the hardware verdict and put numbers on what
  actually writes to the boot stick.

Tests: `os/tests/control.sh` 200 → 213. Nothing here is a claim about hashrate;
the verdicts are thresholds, and the code that computes them is what is tested.

# 6.43.0 — one wallet, one number

Six machines in a shed mine into one address, and until now the dashboard showed
six hashrates and a total. The total was right and the useful number was missing:
what the farm is worth at the pool is per address, because that is what the pool
pays and what an exchange sees. The fleet now groups by wallet.

## What changed

* **Hashrate is added up per wallet.** The dashboard's overview has a "By wallet"
  table — address, hashrate, share of the fleet right now, how many rigs, hottest,
  how many are mining — and `/status` in the chat grows the same lines once there
  is more than one address. One wallet, one row, and the breakdown hides itself
  when there is nothing to break down.
* **A silent rig stops contributing, but is still counted.** A rig last heard from
  an hour ago has probably not stopped mining, but its last reading is not the
  present, and adding it to a fresh number is a lie by omission. It still counts
  as a rig of the farm, and the group says how many are online.
* **A rig with no wallet is its own row, last.** A machine mining into the wrong
  address is the mistake this view exists to make visible, so it is never folded
  into somebody else's total — and a rig nobody owns is not counted at all.
* **The roster takes `wallet` and `pool` at the top.** Six machines, one address:
  writing it six times is six chances to mistype one and split the balance between
  two addresses nobody is watching. A rig that sets its own keeps it, so a
  borrowed machine still pays its owner. A bad top-level address is reported and
  the rigs keep everything else.
* New `fleet/src/farms.js`, and 10 more tests (fleet suite 74 → 84) covering the
  sum, the two-wallet order, the offline rig, the walletless rig, the share when
  everything is down, the unowned record, and both presentations.

Everything here is derived from check-ins held in memory; nothing new is stored,
on disk or anywhere else.

# 6.42.0 — the miner gets the cores, not the hyperthreads

`nproc` counts SMT siblings, and every thread rule in the image was written
against it. On a 16-thread Ryzen `--mode balanced` asked for 15 mining threads on
8 physical cores: two threads per core's L2, hotter and slower than 8. The image
now reads the kernel's topology (`thread_siblings_list`) and sizes itself to
physical cores, with `nproc` only as the fallback for a machine that reports none.

## What changed on the rig

* **Threads follow cores.** `balanced` asks for `cores - 1`, not `threads - 1`;
  doctor's huge-page arithmetic and the mode targets use the same number.
* **The miner is pinned.** `--cpu-affinity` is a mask of one bit per physical
  core, so the scheduler cannot move a thread onto a sibling pair or bounce it
  between cores. `AFFINITY=auto` (default) computes it, `off` drops the flag, any
  other value is passed through as an XMRig mask, and `zmrig.os.affinity=` sets it
  from the kernel command line.
* **Interrupts move off the mining cores.** With four cores or more,
  `zmrig-os tune` writes `0` to every writable `/proc/irq/*/smp_affinity_list` and
  `1` to the unbound workqueue `cpumask`. On two cores it does nothing — there is
  nowhere to steer to.
* **NUMA balancing is off** in max, balanced, eco and safe, and left alone in
  light, where the machine is somebody's desktop.
* `zmrig-os topology` prints what the tool decided and why; `doctor` shows it as
  one line, including the mask.

`zmrig-os tune` also stopped depending on its caller having loaded the config, so
running it by hand works.

## What was verified, and what was not

The decision is tested, not the hashrate: `os/tests/control.sh` builds an
8-core/16-thread sysfs tree and asserts `-t 7` and `--cpu-affinity 0xff` come out
of it, that `AFFINITY=off` removes the flag, that a machine with no topology
falls back instead of pinning everything to one core, and that a two-core box
keeps its interrupts spread. `tests/oneclick/tune-targets.sh` drives the tuner
against a fake `/proc` and `/sys` and asserts which file gets which value. On the
2-thread VM this was written on, `nproc` says 2 and `zmrig-os topology` says one
physical core, mask `0x1`.

The effect on hashrate has not been measured in this environment — there is no
idle Ryzen here to measure it on — so no number is claimed for it.

## Tests

`zmrig-os` control **200** (was 66), tuning targets **7** (new), fleet 26, lint 3,
docs links 101, site pages 22, identity 25.

# 6.41.0 — a control plane that survives its own host

Render's free plan gives 750 instance hours per workspace per month, one always-on
service, and a filesystem that is empty after every deploy, restart and spin-down.
The bot was written for a laptop: it kept the fleet in a JSON file, so every
restart forgot who owned which rig. That is fixed by moving the fleet into the
environment, where it never depended on a disk in the first place.

## The roster

`FLEET_ROSTER` is one JSON object naming every rig and, optionally, what it should
be running:

```json
{"owner": "tg:123456789",
 "rigs": {"ZMR-1A2B-3C4D-5E6F": {"label": "basement", "wallet": "46SQL...", "mode": "safe", "maxtemp": 72}}}
```

It can also live in `fleet/roster.json`; the environment wins when both exist.
Nothing in it is secret — a Device ID is public and a wallet is an address — and a
rig listed there is enrolled before it has ever checked in. The roster knows the
ID and not the key, because the key never leaves the machine, so the first secret
that hashes to that ID binds the record and every later request is held to it
exactly as if the rig had enrolled itself in the chat.

## Desired state, not messages

On every check-in the server compares what the roster says a rig should be with
what the rig says it is, and queues the difference. A queued command is a message
that may never arrive; a roster entry is a fact that is re-checked a minute from
now, and the minute after that. So a rig whose config was edited on the box, or
whose mode change shed threads, is brought back without anybody noticing, and a
restart of the service changes nothing because nothing was remembered.

The correction is pushed at most once per rig per five minutes (a rig that refuses
a command reports the old value for ever, and a robot shouting once a minute is
not a control plane), never while a setup is already in flight, and immediately
when the roster itself changes.

## One service, and the arithmetic behind it

A 31-day month is 744 hours, so exactly one always-on free service fits inside
750. The root `render.yaml` therefore deploys the bot, the Discord bot and the
dashboard as one process, and the pool blueprint moved to `deploy/render-pool.yaml`
for whoever wants it on a different workspace. `FLEET_STATE` is now documented as
what it is — a scratch cache — and `.github/workflows/keepalive.yml` asks
`/healthz` twice an hour, which covers a fleet that is quiet, while a fleet that
is checking in every minute keeps the service awake by itself.

## The dashboard now has every command the chat has

`/rename` and `/log <rig> [n]` were the two the browser could not do. A name is
applied immediately rather than queued — the rig never learns its own name, so
there is nothing to ask it — and the log form takes 5-80 lines like the chat,
clamped rather than refused because it is a display setting.

A rig the roster pins now says so, and lists the fields it pins. Without that,
changing a value in the browser can look like it silently failed: it applies on
one check-in and is corrected on the next, because the roster is re-read every
minute. The page now explains the loop instead of leaving somebody to guess at it.

## The USB stick, in the docs

Someone mining continuously for a year will ask whether the stick survives it,
so `docs/appliance/iso` now answers with what the image actually does: after boot
nothing is written to the stick — the root filesystem is a read-only squashfs and
the writable layer is a tmpfs — so a year of mining is a handful of reads a day.
The section covers metal-bodied sticks, small capacity, clean power, few reboots,
the two Ventoy habits that matter (`VTOY_DEFAULT_IMAGE`, and no persistence for
this image), and the honest answer that an internal drive is more durable than any
stick. It claims no lifetime in hours, because that depends on the controller and
the room.

Tests: fleet **73** (was 59) — three roster shapes, a broken roster reported
rather than thrown, a correction queued once instead of once a minute, the same
fleet surviving an emptied store, and the dashboard's rename, log length and
roster badge.

# 6.40.1 — a portable build that compiles the portable way

The Render deploy failed with one line naming a source file:

```
error: compilation failed: /src/src/crypto/randomx/blake2/avx2/blake2b_avx2.c
```

Two things were wrong, and only one of them was in that file's neighbourhood.

## The image had a compiler with no C library headers

`deploy/Dockerfile` installed `g++` with `--no-install-recommends`. On Debian,
`g++` *recommends* `libc6-dev` rather than depending on it, so the build stage
had a compiler and no `string.h`. Every translation unit then failed at its first
glibc include. The build reported **one** of them — whichever background compile
finished last — which is why the message named a perfectly good source file and
nothing else. It now installs `build-essential`, and a three-line probe compiles
and runs before the engine is touched, so a broken toolchain fails in one line
with the real error.

That was also a reporting bug worth fixing on its own: `build.sh` now records
every file that failed and prints the *first* lines of each compiler's stderr
instead of the last 25 of one, because the tail of a failed compile is the note
under the error and the line that matters is at the top.

## A `--portable` build now builds portable

RandomX picks its implementation at runtime from CPUID, so the AVX2, SSE4.1 and
SSSE3 translation units are always compiled — but their instruction set was only
ever enabled as a side effect of `-march=native`. A `--portable` build compiled
AVX2 intrinsics with AVX2 off: gcc turns that into

```
warning: AVX vector return without AVX enabled changes the ABI [-Wpsabi]
```

which is not a warning to shrug at — it means the calling convention of those
functions is not the one the rest of the build assumes. Clang refuses the same
code outright. Each file now carries its own flags (`-mavx2`, `-msse4.1`,
`-mssse3`), the flag set is part of the object-cache signature so a stale object
cannot survive the change, and the same fix applies to the ISO images built with
`--arch=x86-64-v2`, where AVX2 was never enabled either.

Measured here: `./zmrig/build.sh --jobs 2 --portable` on Debian 12 / gcc 12
builds clean with no `-Wpsabi` warning and the resulting binary passes
`--self-test=light` (all six reference vectors). The Docker image itself is built
in CI now, so the next person to break `deploy/Dockerfile` is told by a job
called "Pool image" rather than by a failed deploy.

Tests: `zmrig/build.sh` portable build + self-test, shellcheck, workflow parse.

# 6.40.0 — the rig notices when it stops keeping its own number

A measurement is a claim about the future, and a machine only sometimes keeps it.
A heat sink fills with dust, one stick of RAM starts erroring, somebody leaves a
background job running on the box. None of that announces itself, and all of it
looks the same from the outside: a hashrate under the rate the same machine
measured when it was tuned.

## The measurement is now stored with its result

`zmrig-os autotune` used to keep the thread count and throw the rate away. It now
writes three more keys next to it — `MEASURED_THREADS`, `MEASURED_HS` and
`TUNED_AT` — so the rig can answer "is this still what I measured?" instead of
only "how many threads was I told to use?".

`zmrig-os status` prints the pair, and it is the useful shape of both numbers:

```
measured      1234 H/s at 4 thread(s), 6 h ago
hashrate      1231.4 H/s
```

## It re-measures itself, on a conservative rule

The supervisor watches the two numbers every fifteen minutes. All five of these
must hold before it acts, because a needless re-measure costs more hashrate than
the drift it chases:

| Condition | Why |
| --- | --- |
| the 15-minute rate, not the 10-second one | a dataset build, a pool reconnect or a burst of shares moves the short window |
| below 75 % of the measured rate | a rig at 90 % is a rig having a normal day |
| at least 250 H/s measured | on a small machine two runs of the same box differ by tens of percent |
| at least 6 h since the last measurement | while it measures, the rig runs at the wrong count for about 90 s |
| still the count the measurement chose | a number set by hand is that person's decision, in every mode |

When it fires, the rig logs one line — what it saw, what it measured — and runs
the measurement again through the same reload handshake as 6.39.0, so nothing is
counted as a crash and nothing reboots. `zmrig-os doctor` reports the same
comparison on demand, and `zmrig-os autotune --auto --retune` is the manual form.

A count chosen by hand now clears the baseline it replaces, and so does a mode
change: comparing a rig against a rate the old mode produced would be measuring
the wrong machine.

## Debug leftovers have a test now

`tests/lint/no-debug.sh` fails on `set -x` in a boot script, `console.debug` in
the agent, `echo DEBUG`, `dbg!(`, `--inspect` and a stray `TODO`/`FIXME` in
anything this project ships. The scan found none — which is the point of writing
it down: `set -x` in a boot script writes every variable, including the wallet,
to a serial console, and nothing else here would notice.

## The control plane sees it too

The rig now reports the rate it measured (`measured` in the check-in payload), so
the bot and the dashboard have a second hashrate rule: below half of the rate the
rig measured on itself. The existing rule compares each check-in with the one a
minute before and catches a rig that fell over just now; this one catches the rig
that has been sliding for a week. The dashboard prints the baseline next to the
live rate, and the alert names the difference:

```
🐌 rig-2 is at 640.0 H/s, 45% of the 1.4 kH/s it measured itself
```

## `CHANNEL="beta"` asked for a file that was never uploaded

Found while checking that the merge into `BETA` really published something
usable: the rolling beta is a *pre-release*, and `releases/latest` never points
at a pre-release. A rig with `CHANNEL="beta"` was therefore asking
`releases/latest/download/zmrig-os-beta-<arch>.json` — a 404 on a release that
looked published. The publish job had the mirror-image bug: a push to `BETA`
uploaded `zmrig-os-stable-*.json` to the `os-beta` tag, because the channel came
from the dispatch input default rather than from the release being written.

Both are fixed and both are tested: the beta channel names `os-beta` explicitly,
and the workflow takes the channel from the tag it is publishing.

Tests: control **182** (was 157), lint **3** (new), fleet 59 (was 58), upstream
17, self-check.

# 6.39.0 — the image measures itself, and knows what it is built from

Three things a rig should never need a person for: choosing its own thread count,
telling you which base it came from, and staying on the newest image without
anybody remembering to rebuild it.

## It tunes itself, while it mines

On a rig that has never been measured, with `THREADS="auto"` and `AUTO_AUTOTUNE=1`
(the default), the supervisor starts the miner immediately and ninety seconds
later runs the measurement in the background. The winner is written to
`os.conf` and the miner reloads — one restart, no reboot, and the rig was never
idle waiting for a benchmark.

Three details that make this safe rather than clever:

* the machine is **tuned before it is measured** (huge pages, THP, governor,
  swappiness). A benchmark on an untuned box gives every candidate the same
  handicap and the number it picks is the best of a bad set;
* the reload is a handshake (`$RUN/reload`), not `zmrig-os restart`. Restarting
  would start a *second* supervisor around a miner the first one is still
  waiting for, and the reload is not counted as a crash, so a healthy rig is not
  walked towards the five-failures-then-reboot limit by its own tuning;
* `zmrig-os mode …` clears the measurement, because `safe` sheds threads under
  heat and `eco`/`light` start lower — a count taken in one mode is the wrong
  answer in another. A count set by hand is never overwritten, and
  `AUTO_AUTOTUNE=0` turns the whole thing off.

`zmrig-os status` says where the number came from: `auto`, `auto (the machine is
being measured)`, or the number.

## Which base is this?

Alpine Linux `latest-stable`, `linux-lts`, squashfs at zstd level 19, a
busybox initramfs. That is the answer, and it now lives in three places instead
of one of them being somebody's memory:

* the build writes it into the image at `/etc/zmrig/base`, and `zmrig-os version`
  prints it — a bug report carries its own base;
* the release manifest carries `"alpine"` and `"squashfs"`, so the published
  image says what it was built on;
* `./os/upstream.sh` prints the same from the source, next to what each channel
  published.

`latest-stable` is deliberate: a pin means the image stops taking security fixes
the day nobody is looking. The cost of that is the opposite question, and
`os/upstream.sh --check` answers it by comparing the Alpine release the mirror
serves today with the `alpine` field of the last published manifest — exit 0 when
a rebuild would change something. The weekly build now runs that check first and
skips both architectures when nothing moved, instead of producing an identical
158 MB file every Monday.

## Smaller, and faster to unpack

* **initramfs**: zstd instead of gzip, but only when the kernel's own
  `/boot/config-*` says `CONFIG_RD_ZSTD=y` — read from the package the image is
  built with, not assumed, with gzip as the fallback. The kernel finds the
  archive by magic bytes, so the installer and the smoke test look for either
  name.
* **root filesystem**: zstd level 19 instead of the default 15. Decompression
  speed is the same at every zstd level; only the build takes longer.

Measured by CI on the same two-architecture build, before and after: the
uploaded artifact went from 155.93 MB to **150.56 MB** (`x86-64-v3`) and 155.85 MB
to **150.47 MB** (`x86-64-v2`), and both still boot in QEMU. What is asserted
locally is the decision itself — the codec comes from the kernel config, and
`grub.cfg` names the file the build wrote.

## Automation

* the scheduled build asks `os/upstream.sh --check` and skips when upstream has
  not moved;
* `publish` now requires the ISO job to have actually succeeded, so a skipped
  build cannot reach the upload step with an empty `dist/`;
* the control-tool tests assert that every version string in the repository
  agrees. They found one that did not: `zmrig-os` still reported 6.37.0 while the
  miner said 6.38.0, which is exactly the drift that makes an updater offer an
  update a rig already has.

## Measured

| | |
| --- | ---: |
| `os/tests/control.sh` | 157 passed (was 141) |
| `tests/upstream/upstream.test.sh` | 17 passed (new) |
| `os/build-iso.sh --self-check` | passed |
| `fleet` `npm test` | 58 passed |
| `serve` `npm test` | 45 passed |
| `site` `npm test` | 67 passed |
| `tests/docs/links.sh` / `pages.sh` / `identity.sh` | 99 / 22 / 25 |

# 6.38.0 — a web host that serves the docs and the downloads, and releases that are links

Two conveniences that were missing from 6.37.0: the site and the images now live
on a host you control, and the release job proves its own links work before
anybody clicks one.

## `serve/` — the web host

One Node process, no dependencies, no build step of its own. It serves the
documentation Docusaurus produces, a download page built from the GitHub releases
API, that data as JSON, and three links that never change:

| path | |
| --- | --- |
| `/` · `/vi/` | the documentation, in both locales |
| `/download` | stable and beta, sizes, checksums, `dd` and `sha256sum` |
| `/api/releases.json` | the same data for a script |
| `/iso/v3` `/iso/v2` `/iso/beta` | `302` to the newest asset on that channel |
| `/healthz` | file count, bytes, RSS, uptime |

That last group is the point: a Ventoy menu, a shell script or a note stuck to a
rig can name `/iso/v3` for a year and keep landing on the current image.

`render.yaml` gained a second service for it. The build compiles the documentation
with `SITE_BASE_URL=/` (the host serves from its own root, not from `/ZMRIG/`),
writes the Brotli and gzip copies once, and starts the server. No secret, no
database, no dependency install for the server itself.

### Why it is fast

Every file is read into memory at boot — 238 routes, 6.31 MB, 1.63 MB compressed —
so a request is a Map lookup and one `end()`: no `stat`, no `open`, no `readdir`.
`ETag` on everything, and a conditional request is answered `304` before the body
is touched. Fingerprinted assets are `immutable` for a year; HTML revalidates.
Brotli takes the home page from 16 KB to 3.9 KB. The release feed is fetched once
per ten minutes and the rendered page is cached against it.

Measured here (2 vCPU, keep-alive, warm cache, 300 samples):

| path | p50 | p95 |
| --- | ---: | ---: |
| `/` | 0.25 ms | 0.81 ms |
| `/docs/intro` | 0.19 ms | 0.34 ms |
| a fingerprinted asset | 0.35 ms | 0.63 ms |
| eight at a time | 0.89 ms | 4.92 ms |

Nothing has been measured on Render itself; a different CPU and a real network sit
between these numbers and a user.

When GitHub cannot be reached the page says so — and says *what to fix*, walking
the `cause` chain Node hides behind `fetch failed` to name a DNS failure, a
refused connection, a timeout or an intercepted TLS certificate — keeps the last
known links, and `/iso/*` answers `404` instead of redirecting into nothing.
Nothing 500s because a third party is down.

Four things that were wrong and are not any more:

* a `.br`/`.gz` sidecar older than the file it belongs to is ignored rather than
  served, so a stale deploy artefact cannot pin a page to last build's content
  under this build's `ETag`;
* `Accept-Encoding` is read as the weighted list it is: `br;q=0` is a refusal,
  and `identity;q=0` gets a compressed body instead of an empty `406`;
* `/download` and `/api/releases.json` carry `Content-Security-Policy:
  default-src 'none'` — they are one HTML file and no script at all — while the
  documentation is left alone;
* `/docs` answers `301 /docs/intro` on the host. The build ships a `docs.html`
  stub whose meta refresh points at `/ZMRIG/docs/intro`, which is correct on
  GitHub Pages and a 404 on a service that serves from its own root.

`scripts/latest-iso.sh --host https://your-host` asks the web host instead of
`api.github.com`, for a network where GitHub is blocked and your own service is
not; the hash arrives with the document, so no second download is needed to print
it. `serve/.env.example` lists every setting, and the README carries a deploy
button.

## Releases that are links

The publish job already uploaded the images. Three things were wrong or missing:

* the channel manifests were uploaded with a glob (`dist/zmrig-os-*-*.json`) that
  also matched every `*.iso.json`, so each manifest was uploaded twice under two
  names;
* nothing checked that the asset URLs actually answered, so a broken upload was
  discovered by the first person to follow the docs;
* the release notes said what the image was, not where it was.

Now the job asks GitHub for every asset over HTTPS after uploading and fails when
one is missing or the size disagrees, and it rewrites the release notes with a
table of direct links and checksums, plus the `releases/latest/download/...` URLs
on stable releases (never on the rolling beta, where `latest` points somewhere
else).

## Shared release client

`fleet/src/releases.js` and the host needed the same answers, so the client moved
to `lib/releases.js`; `fleet/` re-exports it and nothing on that side changed. One
fix came with the move: a first failure used to be reported as an empty feed
rather than "GitHub could not be reached", which made a download page claim
nothing had been published.

## Measured

| | |
| --- | ---: |
| `serve` `npm test` | 45 passed |
| `fleet` `npm test` | 58 passed |
| `site` `npm test` | 67 passed |
| `tests/docs/pages.sh` | 22 passed (26 sidebar pages, 2808 local links) |
| `tests/docs/links.sh` | 99 passed |
| `tests/docs/identity.sh` | 25 passed |
| `os/tests/control.sh` | 141 passed |
| `os/tests/fleet.sh` | 26 passed |
| `tests/releases/latest-iso.test.sh` | 29 passed (was 17) |

The CI site job now also builds the documentation for the web host's base URL and
serves it, so a configuration that only works on GitHub Pages fails a pull request
rather than a deploy. The Telegram and Discord network paths are still the only
parts not exercised here: there is no token and no route to those hosts.

# 6.37.0 — a bot that enrols a rig by the ID on its console

The complaint this answers is "every machine needs its wallet typed in, and I
find out a rig died when the payout drops". There is now a control plane in
`fleet/`: a Telegram and Discord bot, no dependencies, one JSON file.

## A rig enrols itself by being looked at

Each machine generates a 32-byte key on first boot. Two strings are derived from
it and printed on the console (`zmrig-os id`, and at first boot before the wizard
asks anything):

```
ZMR-1A2B-3C4D-5E6F   sha256(key)[0..6), upper case - public
ABCD-1234            sha256("enroll:" + key)[0..4) - proof of presence
```

`/enroll ZMR-… ABCD-… basement` in the chat binds the rig to your account, and
from then on the wallet, pool, coin, mode, heat cap, thread count and worker name
are set from there. The server derives both strings from the key the rig presents
on every check-in, so an ID cannot be claimed by a machine that does not hold its
key, the key never leaves the rig, and nothing can connect *to* a rig.

## The bot

`/devices`, `/status`, `/device <rig>` with buttons, `/wallet`, `/pool`, `/coin`,
`/mode … [C]`, `/threads`, `/worker`, `/update`, `/log`, `/reboot`, `/rename`,
`/remove`. Changes are queued — an offline rig gets them when it returns — and
every result, applied or refused, is reported back.

Alerts: a rig that has not checked in for five minutes, a rig that came back,
heat at 85 °C, the miner stopping, a hashrate that halved. One cooldown per rig
per kind, so a hot machine does not shout every minute.

Telegram long-polls (no webhook, no certificate, works behind NAT); Discord uses
the gateway over Node's built-in `WebSocket`, so the second platform cost no
dependency.

## On the rig

```bash
zmrig-os id                      # Device ID, enrolment code, where the key lives
zmrig-os fleet --url https://…   # point it at the bot
zmrig-os sync                    # check in now (cron does it every minute)
```

`zmrig.os.fleet=` on the kernel command line does the same for media that boots
many machines, next to `zmrig.os.install=` and `zmrig.os.wallet=`. A rig with no
fleet configured contacts nothing, exactly as before, and `zmrig-os setup` stays
the local way in.

The agent validates every instruction again on the machine — a wallet that fails
`zmrig-os`'s own validator is refused there, nothing is written, and the refusal
is reported — so the bot is a convenience, not the security boundary.

## The same fleet in a browser

Not everybody wants to configure a farm from a chat window. Set
`FLEET_WEB_PASSWORD` and the fleet is a server-rendered dashboard on the same
port: fleet totals, one row per rig, per-rig controls, enrolment with your URL
already filled in, and a downloads page. Clear the variable and the bot runs
exactly as before with no HTML surface at all.

One password, no accounts, no directory of users to leak. The password is
compared with `timingSafeEqual`, ten failed logins from one address in fifteen
minutes is a `429`, every form carries a session-bound CSRF token, the cookie is
`HttpOnly`/`SameSite=Lax`, and the CSP is `default-src 'none'`. Actions are the
same *queued* instructions the bot sends, so a browser cannot push anything a rig
would not also accept from the chat.

It is cheap: pages are cached in memory against the store's revision, 6.4 KB of
CSS and under 1 KB of JS are served `immutable` and cached for a year, and every
page over 768 bytes is Brotli- or gzip-compressed behind a weak `ETag` that
answers `304 Not Modified` when nothing moved.

## An image without the bot

`scripts/latest-iso.sh` asks the releases API and downloads the current image for
the machine's CPU: `--arch v3`, `--beta`, `--json`. It prints the checksum and the
size and leaves the comparison to `sha256sum -c`. The dashboard's `/downloads`
page shows the same table, and both exist so that nobody has to set up a bot to
get an ISO.

## Measured

| | |
| --- | ---: |
| `fleet` `npm test` | 58 passed (was 42) |
| `os/tests/fleet.sh` (shell agent against the real server) | 26 passed |
| `tests/releases/latest-iso.test.sh` | 17 passed |
| `os/tests/control.sh` | 141 passed (was 126) |

The Telegram and Discord network paths are not exercised in this environment (no
token, and outbound calls to those hosts are not available here); what is tested
is everything on both sides of the socket: the handlers, the renderers, the
protocol and the agent. The dashboard is tested over a real socket, including
compression, `304`, the CSRF refusal and the login throttle. The GitHub releases
call is tested against a recorded reply, and against GitHub being unreachable.

# 6.36.0 — the image installs itself, updates itself, and fits in less RAM

Two forms, one image. The stick still boots and mines with nothing written
anywhere; the same image now also *installs* onto the machine's own disk, and
from then on there is nothing to do: it boots, it mines, it updates itself, and
an update that will not boot undoes itself.

### Install to disk
- `zmrig-os install --disk /dev/nvme0n1` partitions the disk (BIOS-boot, EFI,
  one ext4 root), copies the kernel, the initramfs and the root squashfs, and
  writes the two bootloaders. One command, about a minute, no network.
- **The bootloaders are built at image-build time**, not on the rig: a standalone
  `BOOTX64.EFI`, a `core.img` and the 512-byte `boot.img`, all inside the ISO.
  An image that needs `grub-install` is an image that needs a GRUB toolkit on
  the machine, and that is 40 MB of modules for a job that happens once.
- The EFI binary finds its config by **filesystem label**, not by disk number,
  so plugging in a second disk does not stop the rig from booting.
- `--dry-run` prints the partition table, the files and where the boot sector
  goes, and changes nothing. What it prints is the code that runs, not a copy.
- **Unattended**: `zmrig.os.install=/dev/nvme0n1` on the kernel command line
  installs and reboots. That is the Ventoy and fleet path - press `e`, type one
  parameter.
- After the copy, the squashfs is read back **through a fresh mount** and hashed
  against the source. A truncated write is caught before the machine is told to
  reboot into it.

### A/B slots and rollback
- The installed system keeps two root filesystems: `rootfs-a.squashfs` and
  `rootfs-b.squashfs`, and GRUB chooses between them by `--id` from a
  **1024-byte environment block** - the same file `grub-editenv` writes, written
  here in shell because the guest has no GRUB tools.
- The initramfs counts boots: three that fail to become a mining rig flip the
  machine to the other slot and reboot. "Failed" means the miner never got five
  minutes of uptime, which covers a kernel that panics, a squashfs that will not
  mount and a miner that exits in a loop.
- `zmrig-os slot` prints both, `zmrig-os slot b` sets the next one.

### Updates, automatically
- busybox `crond` runs `/etc/periodic/daily/zmrig-auto` once a day: check the
  manifest, install a newer miner **next to the running system** (the image is a
  read-only squashfs, so `/usr/local/bin` is RAM and an "update" there would be
  a demo), keep the previous binary, restart.
- `AUTO_IMAGE=1` also writes the whole OS image into the spare slot, verifies
  it, points the next boot at it and reboots. Off by default, because it is the
  one update that changes the kernel.
- `AUTO_UPDATE=0` turns all of it off. An unreachable manifest is not an error:
  a rig behind a firewall keeps mining and the daily job exits 0.

### Lighter, and faster to boot
The image was 1081 MB and nobody had asked why. The build now prints a size
report (biggest directories, biggest files, rootfs/squashfs/ISO totals) and posts
it on the pull request, and the answer was not the kernel modules:

| | before | after |
| --- | ---: | ---: |
| `/boot/initramfs-lts` (stock Alpine's, never read) | 171 MB | — |
| `/lib/firmware` (GPU GSP blobs, Wi-Fi, switch firmware) | 660 MB | 16 MB |
| rootfs | 1122 MB | 180 MB |
| squashfs | 1051 MB | 129 MB |
| **ISO** | **1081 MB** | **158 MB** |

Measured by the size report of the CI build on 2026-11-02 (x86-64-v3 and v2
agree to within a megabyte). Both jobs still boot to userspace in QEMU.

- **The stock initramfs is deleted**: this image builds its own and never read
  that one.
- **Firmware is trimmed to what a wired rig loads** (`rtl_nic`, `bnx2`, `bnx2x`,
  `tg3`, `intel/ice`, plus CPU microcode). `--firmware all` keeps the package
  intact for a board with an exotic NIC.
- **The kernel module tree is pruned**: sound, media, GPU, InfiniBand, ISDN, WAN,
  CAN, IIO, staging, NFC, Bluetooth and Thunderbolt are removed and `depmod` is
  rebuilt, with the count and the size printed at build time.
- `pciutils` is gone (nothing in the image called it); `dosfstools` is added for
  the EFI partition.
- The miner service no longer *needs* networking, DNS or the clock: those are
  soft dependencies now, so the miner starts with the filesystem instead of
  after DHCP. Stratum retries on its own; waiting for a lease costs ten seconds
  per boot and buys nothing.
- New GRUB entry: **max hashrate, CPU mitigations off**. It is a trade (Milldown
  class attacks need code execution on this machine first) and it is offered as
  a menu item, never as the default. Not measured in the environment that wrote
  this, and said so in the docs.

### Tests
`os/tests/control.sh` 126 checks (was 79): the installer's partition table, its
plan, the slot arithmetic, the version comparison, the GRUB environment block
being exactly 1024 bytes, and every refusal (loop device, optical device, the
disk it booted from).

# 6.35.0 — safe mode: mine without cooking the machine

Every mode until now answered "how fast can this box go". `safe` answers the
question a laptop, an office box or a rig in somebody's bedroom actually asks:
how fast can it go *for months*.

### The governor (`zmrig/src/thermal.zig`)
- **One number**: `--max-temp=72`. The bands are derived from it, so they cannot
  be set into an order that makes no sense: step down at the target, step down
  immediately at target + 8, stop hashing at target + 15, resume at target − 7.
- **Reads the hottest CPU sensor** once a second from `/sys/class/hwmon`
  (`coretemp`, `k10temp`, `zenpower`, `cpu_thermal`, `acpitz`, Super I/O) and
  `/sys/class/thermal`, ignoring GPUs, disks and batteries: a warm NVMe must not
  cost a thread.
- **Moves the thread count, not the clock.** A worker above the allowed count
  parks; it keeps its VM and the dataset stays in RAM, so a throttle costs the
  shares that were not computed and nothing else - the pool connection stays
  open and a resume does not pay the 20-40 s rebuild.
- **Two speeds, on purpose.** At the target it sheds one thread per 30 s (a
  boost spike is not a policy failure); at the hard cap it sheds one per 5 s.
  Stepping back up needs two minutes below target − 5, because cooling for two
  minutes and heating up in ten seconds is how a fan bearing dies.
- **No sensor is not a reason to stop earning**: it says so once and keeps the
  thread count it was given. `--thermal-file=PATH` points the governor at a file
  for boards whose sensor lives behind a BMC.
- 15 unit tests over the state machine (every edge, every hysteresis window) plus
  `zmrig/tests/thermal.sh`, which drives the real binary through a real pool and
  a file whose number it changes: cool, hot, one thread, pause, cool, resume.
- `--check` gained a `thermal` line, because "it throttled" and "it has no sensor
  and never could" are different answers to the same complaint.
- **The report code carries it too**: `tmax`, `tc` and `at` (threads currently
  allowed). A rig throttled to five of eight threads and a rig that is simply
  half loaded look identical from the pool side, and only one of them is on its
  way to a dead fan.

### The appliance
- **`zmrig-os mode safe [TEMP]`**: one core left for the OS and the fan
  controller, nice 19, watt profile, MSR untouched, governor armed at 72 C.
- A GRUB entry for it, and `zmrig.os.maxtemp=` on the kernel command line for a
  fleet. The old "safe mode" troubleshooting entry is now called
  "troubleshooting", which is what it always was.
- `zmrig-os status` prints the current temperature next to the mode, read from
  the same sensors the miner uses.

### The installer
- `oneclick.sh --max-temp=70` writes `"max-temp": 70` into `config.json`; the
  plan output shows the policy before it is applied, and a value outside 45-95
  is refused rather than silently clamped.

### The ISO that never finished
- **The image build squashed a live `/proc`.** `cleanup_mounts` ran *after*
  `mksquashfs`, so the build walked `${ROOTFS}/proc`, `${ROOTFS}/sys` and
  `${ROOTFS}/dev` while they were still bind mounts into the host. That is what
  the two cancelled ISO jobs were: ninety minutes inside "Build the image", then
  the job timeout. Torn down first now, with a mountpoint check and a
  `--self-check` assertion on the order.
- Every step prints its elapsed time, and the three steps that can wait on
  something outside the machine - `apk` in the chroot, `mksquashfs`,
  `grub-mkrescue` - are bounded and say so when they time out.

### Also in this version
- **The Zig engine has CI.** `cli.sh`, `unit.sh`, `net.sh`, `health.sh` and
  `thermal.sh` ran only on the machine that wrote them; they are a job in
  `.github/workflows/test.yml` now.
- **`scripts/find-zig.sh`**: the build requires Zig 0.13 and the CI runner ships
  a newer one, which it treated as satisfied. The resolver checks the version,
  and every caller - miner build, image build, deps, unit tests - uses it.
- **AVX-512 translation units carry their own flags.** Clang 19 split 512-bit
  EVEX out of `-mavx512f`, so `-march=x86-64-v2` silently disabled it in the
  three files that use `_mm512_*`. Probed, not assumed.
- **`--max-temp` parsing no longer leaks** on a rejected value: `parseArgs` frees
  what it read before the error.
- **The image build no longer deletes its own output** (`/tmp/chroot-kver` was
  removed by the tidy step two hundred lines later), and a failed compile now
  names the file and the command instead of printing "compilation failed".
- 79 appliance checks (was 66), 19 Zig modules (was 18), 33 option tests (was 29).

# 6.34.0 — ZMRIG OS: a miner you boot instead of install

A rig should not be a general-purpose computer. `os/` now builds a bootable
image — GRUB (BIOS and UEFI), a kernel, a 10 MB initramfs and a read-only Alpine
root filesystem with `zmrig` in it — and `.github/workflows/os.yml` rebuilds it
on every change, boots it in QEMU, and publishes every version. It also runs on
pull requests that touch `os/`, so the image is built before it is merged, and
publishing stays a separate decision (a tag, or a manual run).

### The image
- **Live, not an installer.** The initramfs finds `rootfs.squashfs` on the media,
  stacks a tmpfs over it and hands over to OpenRC. Nothing is written to any
  disk and nothing on the stick is modified.
- **Huge pages are reserved before userspace starts.** On a rig that has been up
  for a week the kernel cannot find 1168 contiguous 2 MiB pages, and the miner
  silently drops to transparent huge pages; reserving in the initramfs is the
  +4–6 % that `doc/PERFORMANCE.md` measures, and it costs nothing.
- **The rest of the system is tuned the same way**, line by line, in
  `/etc/sysctl.d/99-zmrig.conf`: `swappiness=1` (never page out a 2.3 GiB
  dataset), write-back throttled, 64 MiB kept free, `zone_reclaim_mode=0`, NMI
  watchdog off, TCP keepalive shortened so a dead pool is noticed in a minute.
- **Static miner**: `zmrig/build.sh --static` cross-compiles the whole engine with
  `zig cc` against musl (`--arch x86-64-v3|v2`), producing one 19 MB file with no
  libc dependency. Verified: `--self-test` passes and `--bench=3000` gives
  889–902 H/s against 886–957 for the native build on the same host, i.e. static
  costs nothing measurable.
- **A control tool instead of a hundred instructions** (`zmrig-os`, POSIX sh):
  `setup`, `mode`, `status`, `logs`, `bench`, `doctor`, `update`, `persist`,
  `ssh-key`, `boot`, `args`. 66 tests, no root, no miner, no network.
- **Four modes** — `max`, `balanced`, `eco`, `light` — as config, as a command
  (`zmrig-os mode eco`), and as separate GRUB entries so a headless rig can be
  switched with a keyboard and no network.
- **Fleet without a fleet tool**: `zmrig.os.wallet=`, `zmrig.os.pool=`,
  `zmrig.os.worker=`, `zmrig.os.mode=` and `zmrig.os.data=` on the kernel command
  line; a wallet there skips the wizard entirely.
- **Persistence** where you want it: a partition labelled `ZMRIGDATA` keeps
  `os.conf` and the ssh key across boots; without one, the image stays read-only
  and RAM-only.
- **Verified updates**: `zmrig-os update --apply` downloads the static binary for
  this image's instruction level, checks sha256, and moves it into the running
  overlay (reboot = rollback). `--iso --write /dev/sdX` flashes a new image and
  refuses the device it booted from.
- **Security stated plainly**: console autologin (the wizard needs a console),
  ssh key-only with no password auth, no package manager at runtime, no
  telemetry, fee printed everywhere and switchable off.

### Build and CI
- `os/build-iso.sh` (`--plan`, `--self-check`, `--smoke`, `--arch`, `--kernel`,
  `--clean`), `os/deps.sh`, `os/smoke-qemu.sh`, `os/tests/control.sh`.
- `build.sh` grew `--static` and `--arch=`, and its object cache now keys on the
  real compiler flags and mode. It used to hash three arrays that were still
  empty at that point, so `--static` in an existing output directory reused the
  native objects and failed at link time with `__gxx_personality_v0`.
- The workflow boots the finished ISO in QEMU and requires
  `ZMRIG-OS: ready` on the serial console, then publishes the ISO, its checksum
  and a per-architecture manifest for the updater. Releases keep every past
  version; `BETA` publishes a rolling pre-release.

# 6.33.0 — the fee is real, visible, and switchable off

The miner was fee-free by construction, which was easy to verify and impossible
to fund. `zmrig` now mines **1 % of its Monero time** to the developer wallet on
the pool the operator already configured: 60 s every 100 minutes, Monero only,
and `--donate-level=0` removes it entirely.

### The fee
- **`zmrig/src/fee.zig`** is the whole implementation: a debt clock. Every second
  of `rx/0` hashing adds 10 ms of debt at 1 %; at 60 s owed the monitor closes
  the pool socket, the miner reconnects on the same pool with the developer
  wallet and `algo=rx/0`, spends the debt down, and reconnects back to your
  wallet with no retry pause.
- **Monero only.** The wallet is a Monero address; mining ArQmA, Wownero, Graft,
  Safex, Yada or Scala to it would burn the coins, so those algorithms accrue
  nothing.
- **Refusals postpone, they do not punish.** A pool that rejects the developer
  wallet costs the fee two minutes, then thirty after three refusals. Your
  connection is never marked bad because of a fee attempt, and the debt is
  capped at one hour so it cannot grow into a two-hour session later.
- **`--donate-level=N`** now sets the rate (0–10, default 1) instead of being
  accepted and ignored; `--no-donate` is the readable spelling of `0`. The
  generated `config.json` writes `"donate-level": 1` so the value is in the file,
  not implied.
- **It is printed.** The banner, `--check` (`donate  1% of Monero (rx/0) mining
  time to 46SQLW7D…, 60 s every 100 min`), the startup log, every session in the
  log, and `"donate_level": 1` in the HTTP API. `doc/FEE.md` is the one-page
  policy; `scripts/verify-fee.sh` reads the rate, the wallet and the off switch
  out of the binary and fails if a second address or an upstream donation
  endpoint appears. `oneclick.sh verify` runs it on the installed binary.
- **The C++ engine still takes nothing** (`doc/ZERO_FEE.md`,
  `scripts/verify-fee-free.sh`): the fee belongs to the Zig front end, and
  `--engine=xmrig` remains available for the algorithms Zig does not speak.
- Measured live against the test pool: `login … user=4AdUnd…` (user),
  `login … user=46SQLW7D…` (fee), `login … user=4AdUnd…` (back), with the debt
  spent exactly.

## huge pages, measured instead of assumed

The miner used to treat "no reserved huge pages" as "4 KiB pages", and tell
unprivileged users to take a root action they did not need. It also built the
dataset with the mining thread count, so `-t 1` doubled every seed change. Both
are measured below and both are fixed; nothing else changed the hashrate, and
the sections that say so are the honest half of this list.

### Fixed
- **`--bench` and `--report` refused to start on a host that had the memory.**
  The pre-flight compared the requirement against the huge-page pool and against
  `MemAvailable` separately, so a machine that had followed the miner's own
  advice (`echo 1168 > nr_hugepages`) had 2336 MB of pool and 1.2 GB of RAM and
  matched neither a 2404 MB requirement. The two are summed now, which is what
  the allocator does, and the message says which two numbers it added.
- **`--mode=auto` decided `fast` from `MemTotal`.** On a 4 GB box already running
  something else that meant mapping a 2 GiB dataset into 1.5 GB of free memory:
  OOM kill, or a silent fall back to the 10× slower light mode. It now uses
  `MemTotal` and `MemAvailable` plus reserved-but-unused huge pages, whichever is
  smaller, and says which of the two failed when it picks light mode.
- **The dataset was built with the mining thread count.** `--randomx-init`
  defaulted to `-t`, so `-t 1` built Monero's 2 GiB dataset with one thread:
  42.9 s against 21.1 s on a 2 vCPU host, and a switching pool pays that on
  every seed change. The default is now every hardware thread; the flag still
  overrides, and `miner.zig` has a unit test for the rule.

### Changed
- **Huge-page status is measured, not assumed.** After the dataset is built the
  miner reads its own `AnonHugePages` from `/proc/self/smaps_rollup` and prints
  `huge pages: 2332 MB via THP (99% of the 2336 MB mapping, measured by the
  kernel)`. `MADV_HUGEPAGE` returning 0 means "request noted", not "granted", and
  the log no longer confuses the two.
- **The root advice is conditional.** `nr_hugepages=…` is suggested only when
  `/sys/kernel/mm/transparent_hugepage/enabled` is `never` (or unreadable). On
  the common `[madvise]` default the mapping is backed by 2 MiB pages without
  any root step, and the warning that used to appear there was wrong by 24
  percentage points: 786 H/s with THP against 615–626 H/s on 4 KiB pages, and
  800–841 H/s with the reserved pool.
- **`--check` prints a `thp` line** next to the memory line, so the decision is
  visible before the first hash instead of after an hour of mining.
- **The API test covers all seven algorithms in full-memory mode**, and decides
  on its own whether the box can hold the dataset (usable RAM plus free huge
  pages) instead of counting pages against a hardcoded 1152.

### The new mark
A bold Z — bar, diagonal, bar — drawn on a 32 unit grid, one tone, generated
from `site/tools/make-logo.py`: `logo.svg`, `logo-dark.svg`, `favicon.svg`, three
PNGs and the social cards. Diagonal cut thinner than the bars, two corners
chamfered on that axis, symmetric under a 180° rotation.

## every coin sized and tuned for itself

Both engines hashed seven coins; only Monero decided how much memory they used.
The miner reserved 2416 MB of huge pages, refused to start without them and fell
back to light mode below 3 GiB of RAM — for a Scala/Panthera rig that needs 192 MB
and is happy on a 512 MB VPS. This release reads the compiled configuration of
the algorithm at hand, everywhere it matters, and fixes the one bug that made
light mode on that coin crash.

### Fixed
- **Light mode crashed on Panthera/Scala.** The JIT snippet that reads the dataset
  (`randomx_program_read_dataset_sshash_init`) masked the block number with the
  compile-time 2 GiB mask. With `DatasetBaseSize` at 32 MB the program addresses
  cache lines it does not own — up to 2 GiB past the end of a 128 MB cache — and
  the process dies with `SIGSEGV` inside generated code, a fraction of a second
  after `--check` reported a healthy config. The emitted snippet is now patched
  with the mask of the running algorithm, the way the dataset-read path already
  was. `--self-test` has a reference vector for every algorithm now, so a bug of
  this shape cannot come back quietly.
- **Switching algorithm leaked the cache.** `posix_memalign` was released with
  `munmap`, which does nothing to a heap pointer: 2.3 GiB stayed mapped per
  switch. A pool that rotates coins (MoneroOcean) exhausted the machine in a few
  switches. Allocation and release now go through the same `mmap` path, so the
  memory is also never written twice before the dataset initialiser fills it.
- **Two different huge-page counts in one binary.** The reservation said 1208
  pages, the engine's own advice said 1168, for the same 2336 MB. One rule now.

### Changed
- **Memory is sized per algorithm** (`zmrig/src/memory.zig`). `--mode=auto`, the
  huge-page reservation, the memory gate in front of `--bench` and `--report`,
  and the startup message all use `xmo_algo_memory()` — the same numbers
  RandomX compiled. Monero 256 + 2080 MB, Panthera 128 + 64 MB; measured totals
  2 449 473 472 B and 201 326 528 B.
- **`zmrig-tune --algo=`** (and `oneclick.sh --coin`) size the reservation for
  that coin: 96 pages for Panthera instead of 1168, so the host is not asked for
  2.3 GB it will never touch. Unknown algorithms reserve for the largest
  configuration: too much is harmless, too little is not.
- **`--bench`/`--report` check for the memory they are about to use**, not for
  Monero's 2400 MB. A Panthera benchmark no longer refuses to start on a host
  that can hold it.
- **AMD hosts get the AMD JIT.** `RANDOMX_FLAG_AMD` is set from the detected CPU,
  as upstream XMRig does; the CFROUND sequence is cheaper there and the hashes are
  identical.
- **One huge-page message, not two.** The engine's advisory line is suppressed
  when the reservation code has already reported the same thing with the same
  number.

### Tests
- **`zmrig/tests/api_test.cpp`**: every algorithm hashes its reference vector in
  light mode, and the per-algorithm sizes are asserted (Monero 256 + 2080 MiB,
  Panthera 128 + 64 MiB, light mode = cache only).
- **`zmrig/src/memory.zig`** owns the `auto` rule and tests it without linking C:
  a 1 GiB box picks fast mode for Panthera and light for Monero, and an explicit
  mode is never second-guessed.
- **`--self-test`** covers all seven algorithms (was `rx/0` only, so
  `--self-test --algo=panthera` verified Monero and reported success).

### Brand
- **A new mark**: a bold Z sitting on a water line — bar, diagonal, bar, with the
  lower edge of the bottom bar rising and falling like the sea. One tone, one
  outline, nothing beside it: the wave is sampled into the letter's own polygon,
  so it cannot leave a seam, and the straight parts stay on the 32 unit grid so
  16 px still reads as a Z. The name is ZMRIG, the engine is Zig, and the rig
  swims in a pool — the letter carries all three without a caption.
  `site/tools/make-logo.py` writes `logo.svg`, `logo-dark.svg`, an adaptive
  `favicon.svg` and the three PNG icons; the social cards paste the same render.
  Light pages get black, dark pages get white, the favicon follows
  `prefers-color-scheme`.

## seven coins, one installer

Monero was the only coin the site offered, while both engines hashed six more the
whole time. The installer, the builder, the wizard and the calculator now cover
the seven algorithms that actually exist in this repository — and refuse to
pretend about the rest.

### Added
- **`--coin`**, the short form of `--algo`: `xmr`, `wow`, `arq`, `graft`, `sfx`,
  `yada`, `xla`. `oneclick.sh plan` now prints the coin next to the algorithm, and
  `--coin wow --algo rx/0` is refused as a contradiction instead of silently
  picking one. An unknown coin dies with the list; an algorithm name with a quote
  in it — the value is interpolated into `config.json` — dies before anything is
  written.
- **Coin picker in the builder.** Changing the coin resets what belonged to the
  previous one: a Wownero address left in a Monero pool preset would have produced
  a command that looked certain and was wrong. Non-Monero coins get no preset, so
  the pool field asks for the endpoint instead of inventing one, and the command
  carries `--algo` for every coin except Monero — pinning `rx/0` there would stop
  a switching pool from moving the rig to whichever RandomX coin pays best.
- **Per-coin address checks.** Monero keeps its exact rule (95/106 characters,
  base58, prefixes 4 and 8). The other six get the alphabet, a plausible length,
  and a prefix *warning* where a prefix is known — the pool verifies the checksum,
  and a page that claims otherwise is lying.
- **The coin comparison** (`site/src/lib/coins.mjs`, `CoinMatrix.jsx`), on the
  calculator page and on a page of its own: a ranking of what one rig earns per
  day on each coin, from reward, block time, network hashrate and price. Prices
  come from CoinGecko **only when the button is pressed**, so the page works
  offline; a failed request leaves every price untouched and says what failed.
  A row missing a number says which field is missing and sorts below the ones
  that can be ranked — a zero would sort to the bottom and look like an answer.
- **`doc/SETUP.md` §5b** — the whole multi-coin setup: the table, the two things
  only the user can supply (that coin's wallet, that pool's endpoint), the `plan`
  → `install` sequence, verification, and where the site's numbers come from.
- **`site/docs/pools/coins.mdx`** and its Vietnamese mirror, in both sidebars.
- **`site/tests/coins.test.mjs`** (14 checks) and seven new `plan` checks: every
  offered coin is an algorithm both engines hash, a non-Monero coin ships no pool
  preset and no default price, a blank field is never zero, `mergePrices` drops
  junk instead of guessing, and `--coin` maps to the right algorithm.

### Changed
- **README** gained the coin table and the `--coin` example; the test table and
  the badge follow the suites (474 checks).
- **The builder documents its coin rule** (en + vi); the calculator page explains
  the comparison and links to the coin page.

## the documentation site is the site

`https://molik-labs.github.io/ZMRIG/` used to serve the hand-written site in
`web/`. It now serves the Docusaurus build, at the same URL, with the same
content in both languages. No binary changed.

### Changed
- **`web/` is the published site.** `.github/workflows/pages.yml` uploads `web`
  as the Pages artifact, so the build is written there instead of only to the
  repository root. `scripts/publish-site.sh` writes both trees from one build —
  the artifact one, and the branch root that GitHub's *pages build and
  deployment* still publishes because **Settings → Pages → Source** is set to
  *Deploy from a branch*. Whichever deployment finishes last, a visitor gets the
  same pages; `--check` fails the moment they disagree. Switching that setting to
  *GitHub Actions* makes the root copy unnecessary (`doc/SETUP.md` §4a).
- **`web/` is replaced whole on every publish**, so no asset from a previous
  build can survive and serve a stale page. In the repository root only the
  paths Docusaurus owns are replaced.
- **The previous site moved to `legacy/`**, out of the deployed tree, and its
  tests run from there (`npm run test:web`, 57 checks unchanged).
- **`/ZMRIG/wizard.html` and `/ZMRIG/docs.html` are redirects now**, not pages:
  a bookmark, a forum post or the README of some fork still lands on the command
  builder or the documentation, in the visitor's language.
- **`?pool=` works on the builder**, so the pool tables in the docs link straight
  to a pre-selected pool — the one behaviour of the old wizard worth keeping.
- **`robots.txt` is part of the build** (`site/static/`), not a hand-kept file in
  the repository root that could drift from the sitemap.

### Fixed
- **The proxy installed its signal handlers too late.** They were registered
  after the listeners were created, so a `systemctl restart` in the first
  milliseconds killed the process by signal instead of exiting 0 — and its own
  e2e suite failed one run in eight because of it. The handlers now exist before
  anything is opened, and the banner prints the rig commands before the upstream
  connection is attempted, so a person at the terminal sees them first.
- **The fleet break-even price counted revenue from machines whose power is
  unknown** against only the metered machines' energy, which overstates the
  number — the one figure that decides whether to keep mining. It now uses the
  metered machines' revenue, and the test pins the difference.
- **The bilingual calculator printed the English comment lines** inside the
  "after the install" block on the Vietnamese page. Those blocks are commands to
  paste, so the commentary is gone rather than translated twice.
- **The power card read "Energy per day" above a wattage.** It now says what it
  shows: wall power, with `kWh/day` under it.

### Tests
- **`tests/docs/pages.sh`** runs against `web/` (the tree Pages actually
  uploads), 22 checks: every local reference on every page (2040 of them, not a
  sample of six), a title, a description and the right `lang` on each page with
  no leaked placeholder, the two redirect stubs, and still refuses a stale copy.
- **`legacy/tests/`** keeps running: the archived site is not deployed, but the
  checks that guard branch names, the donation address and the pool table are
  still cheap and still true.

## the documentation site

The site is no longer hand-written HTML. It is Docusaurus 3, in `site/`, with
21 pages in English and 21 in Vietnamese, and the three calculators live inside
the docs instead of beside them. No binary changed in this work.

### Added
- **`site/`**: Docusaurus 3.10 with one ordered sidebar — what it is, install,
  configure, run, pools and money, a whole fleet, reference, development,
  support. English is the default; Vietnamese is a full translation at `/vi/`,
  including the navbar, the footer and the theme strings.
- **Calculators inside the docs.** The command builder is
  `/docs/install/builder`, the profitability calculator is
  `/docs/economics/profitability`, and the pool table is a component both pages
  and the tests read. `src/lib/` holds the rules as plain modules — no DOM, no
  React — so the page and the tests cannot disagree about what a command or a
  payout means.
- **Three-state theme control** (`System` / `Light` / `Dark`). Docusaurus ships
  two states, which traps a visitor who once picked dark: they can never return
  to following the system. The swizzled toggle exposes the `null` choice the
  config already stores.
- **Algolia DocSearch wiring.** `themeConfig.algolia` is attached when
  `ALGOLIA_APP_ID`, `ALGOLIA_API_KEY` and `ALGOLIA_INDEX_NAME` are present;
  until the crawl is approved, a local index is built so there is exactly one
  search box and never two. Application and keys: `doc/DOCS-SITE.md`.
- **`doc/DOCS-SITE.md`**: how the site is built, why the output is committed,
  how to add a page in two languages, and the four settings only a maintainer
  can change.
- **`site/tests/`** (53 checks): command-builder rules and blocked states,
  calculator arithmetic against hand-computed numbers including break-even,
  the pool table against `oneclick.sh` and `doc/POOLS.md`, en/vi file-tree
  parity, a `messages` suite that rejects a dead, duplicated or untranslated
  string, and the donation address against the wallet
  `pool/src/operator.js` decodes to.
- **Social cards.** Two 1200×630 images, `img/og-en.png` and `img/og-vi.png`,
  generated by `site/tools/make-art.py` from the same pool table the site
  renders, so a card cannot drift from a page. Every page carries exactly one
  `og:image` and one `twitter:image`, in its own language.
- **Break-even price in the calculator.** A sixth card shows the `$/kWh` at
  which the power bill equals what the hardware mines — the number that decides
  whether a machine is worth running, which the profit figure alone cannot
  answer.

### Changed
- **Publishing.** Pages for this repository is set to a branch source, so the
  built site is copied into the branch root by `scripts/publish-site.sh`, which
  replaces only the paths Docusaurus owns and never deletes `web/`.
  `--check` fails when the committed copy is stale, and `tests/docs/pages.sh`
  verifies it.
- **`tests/docs/pages.sh`** rewritten for the real site (18 checks): Docusaurus
  entry point, 21 pages in both locales, every local `href`/`src`, both
  sitemaps, the language and theme controls, one social card per page in the
  page's own language, and the stale-build guard. The old
  branch-root redirect and CSP-meta checks are gone with the pages they tested.
- **`tests/docs/links.sh`** understands `/docs/…` routes, so a link between docs
  pages is checked as a page rather than as a file next to the Markdown (80
  checks, was 52).
- **`doc/SETUP.md` §4** describes the Docusaurus build for GitHub Pages,
  Cloudflare and Vercel, and §3b gives the CI job that has to be pasted by hand
  (workflow files need a token scope this session does not have).
- **README**: new docs links, the layout, and the test table.

### Fixed
- **Vietnamese pages advertised the English social card.** A theme-wide
  `image` is not locale-aware, and a root-relative path is resolved against the
  locale base, so `/vi/…` picked up a copy of the English card. The theme
  default is gone; each page carries an absolute URL in its front matter, and
  `tests/docs/pages.sh` fails if a published page ends up with two `og:image`
  tags or with none.
- **The theme switch showed only the active label**, leaving two icon-only
  buttons; now all three are labelled, and on a phone the text is hidden
  visually but kept for screen readers. `InstallBuilder` rendered three
  messages that did not exist (`builder.engineZmrig`, `builder.connectTo`,
  `builder.plan`) and would have shown raw keys; the strings exist now, and the
  new `messages` suite checks that every literal `t("…")` resolves.
- **The builder accepted a proxy URL and a `--connect-to` address it could not
  hand to the miner.** Both are validated now (`proxy-invalid`,
  `connect-to-invalid`), and the builder gained the missing dial-address field
  and a visible `plan` preview.
- **The calculator flashed "no machines yet"** for one frame before restoring
  the saved fleet, because the empty state rendered before the restore effect
  ran.
- **The Vietnamese sidebar still said Install, Configure, Run**: the category
  labels in `i18n/vi/…/current.json` were left in English.

### Removed
- The root `index.html` redirect and the `404.html` rewrite script. The
  published site now owns both files.

# v6.32.1 — the 404 on the published site

The site worked and the URL was dead, because GitHub Pages was publishing the
branch root instead of `web/`. A branch root has no site in it, and Pages
answers with the "does not contain the requested file" page.

### Fixed
- **`/index.html` and `/404.html` at the repository root.** If Pages publishes
  `BETA` as-is, `/ZMRIG/` now forwards to the real site in `web/`, and any deep
  link (`/ZMRIG/wizard.html`, `/ZMRIG/docs.html#cai-dat`) is rewritten to
  `/ZMRIG/web/…` by the 404 page. The rewrite is executed by
  `tests/docs/pages.sh`, not read: the first version turned `/ZMRIG/` into
  `/web/ZMRIG`, which is exactly the kind of bug a regex assertion misses.
- **`.nojekyll`** at the root and in `web/`, so nothing is passed through
  Jekyll in either mode.
- **`doc/SETUP.md` says what to click** (Settings → Pages → Source: GitHub
  Actions) and what each mode costs in the URL, with the mode-aware workflow
  written out for a one-off paste. The workflow files themselves are unchanged:
  the automation token this release was prepared with has no `workflows`
  permission, so a CI change could not be pushed — and a documented one-off
  beats an undocumented red X on every push.
- **Two pages still told people to run `/etc/xmrig-ocean/config.json` and
  `systemctl status xmrig-ocean`**: the home page's install steps and the
  wizard's "after install" list. Both render perfectly, which is why nothing
  caught them — `tests/docs/pages.sh` now greps the published files for the old
  name.
- **The documentation tab said `— zmrig`** while every other page said
  `— ZMRIG`; the shell builds that title at runtime and nothing compared them.
- **Two stale facts on the docs page**: the network suite was described as 22
  cases (29), and the site was described as deployable to Cloudflare only.
- **Old `/web/` links after switching the mode**: the 404 page now strips the
  extra segment once (`web/assets/redirect.js`) instead of dead-ending. Both
  directions are covered, so a cached link from the other mode still arrives
  somewhere useful.
- **CSP meta tags** on all four pages. GitHub Pages ignores `web/_headers`, so
  the policy only existed for Cloudflare; without the header the deployed site
  had no CSP at all. `tests/docs/pages.sh` fails if a page gains an inline
  `<script>` that its own `script-src 'self'` would block.
- Action versions: `configure-pages` v6, `upload-pages-artifact` v5,
  `deploy-pages` v5 (the previous three were forced onto Node 24 anyway).

### Changed
- Version **6.32.1** across the miner, the report codes, the agent string, the
  packages and the pages, so the number on the site matches the number on the
  binary.

### Added
- **`tests/docs/pages.sh`** (`npm run test:pages`, 21 checks): an entry point in
  `web/`, the branch-root redirect for JavaScript and no-JS, no root-absolute
  link, every `href`/`src` (45) and every in-page `#anchor` (17) resolving, the
  docs manifest and its Markdown files, only real pages in the sitemap, CSP
  meta, and the deploy workflow itself.

# v6.32.0 — the name on the binary

The project is called ZMRIG everywhere except in the places a user actually
looks: `--version`, the systemd unit, the path of the config file. This release
makes the tool say its own name, and keeps every install made before it working.

### Changed
- **Version string**: `6.31.0-mo14` → `6.32.0`. The `-mo` suffix described the
  upstream lineage, not this fork; the lineage now lives in `NOTICE`.
- **Installed paths**: `/etc/zmrig`, `/var/lib/zmrig`, `/var/log/zmrig`,
  `zmrig.service`, `zmrig-tune`, `zmrig-bench`, `zmrig-verify`. The C++ engine
  installs as `/usr/local/bin/xmrig`, the Zig engine as `/usr/local/bin/zmrig`;
  the service, the config and the logs stay under one name either way.
- **Banners**: `--help`, `--version`, a rejected option, a rejected config and
  the first log line all carry `ZMRIG <version> - … by @nggkhaiz`, the licence
  and the repository URL. The engine identifies itself as `RandomX (ZMRIG)`.
- **Installer**: `1.3`, with the author line in `--help`, the banner, the ready
  message and both unit `Description=` fields.
- **Packages**: npm names `zmrig`, `zmrig-proxy`, `zmrig-pool`, each with
  `author`, `homepage`, `repository` and `bugs`.

### Added
- **`NOTICE`** — author, licence, and a table of what came from where (XMRig,
  RandomX, MoneroOcean, Monero, libuv, hwloc, rapidjson, fmt), plus what was
  removed from upstream and why.
- **`tests/docs/links.sh`** (`npm run test:docs`) — every relative link and
  every `#anchor` in the documentation resolves. 52 checks; it immediately found
  three dead links, including one in the site's own install guide.
- **Migration from installer 1.2** — an install made under the old name keeps
  its config (`/etc/xmrig-ocean/config.json` is copied, mode 600, to
  `/etc/zmrig/config.json`), its state directory is moved, the old unit is
  disabled and removed, and `purge` removes both names.

### Fixed
- `tests/oneclick/config.sh` asserted `rx/0` while the installer writes `auto`.
  The installer was right: a pool that switches algorithms can only use the rig
  if it advertises the family.
- The site footer was three different pieces of markup on four pages; it is now
  one block in `site.css` with the version, the licence and the notice link.
- Every page title, `og:site_name` and meta description.

# v6.31.0-mo14 — a wizard instead of a wall of flags

The installer was already zero-flag, but the site still made a visitor read a
form with fourteen switches before seeing a command. The site now has two ways
in, and they provably agree.

### New
- **`web/wizard.html`** — a four-step wizard: wallet → pool → machine → network
  → command. Each step is one question, every option carries its reason on
  screen, and the stepper doubles as navigation. Deep links work
  (`?pool=c3pool&engine=zmrig&tls=1`), so the pool table and the docs can hand
  a visitor a pre-answered wizard. The wallet is never written into the URL or
  a copied link.
- **`web/assets/pools.js`** — one pool table (fee, minimum, endpoint, TLS port,
  why, payout cadence) used by the wizard, the builder and the docs links.
  `web/tests/pools.test.js` fails if it ever disagrees with `oneclick.sh`'s
  `pool_preset()` or with `doc/POOLS.md`.
- **`web/assets/command.js`** — the command builder became a pure function, so
  the quick builder and the wizard cannot produce different commands for the
  same answers (there is a test that compares them byte for byte).
- **A `plan` button** next to the install button: the same command with the
  `plan` subcommand, which resolves the pool and the config and changes nothing
  on the host.
- **Pool selection with facts** — fee, minimum, payout cadence, endpoint and a
  one-sentence reason for each pool; a TLS switch that knows which pools
  publish a 443 endpoint and refuses to invent one; backup-pool picker that
  cannot select the primary as its own backup.
- **Honest warnings**: choosing `zmrig` for an algorithm-switching pool now says
  that the rig will only be offered the RandomX family, which gives up the
  largest single advantage of that pool.

### Fixed
- Stale link: three places pointed at `docs.html#benchmark`, which is
  `docs.html#hieu-nang` — the page has never had that slug. Found by the new
  link checker, not by a visitor.
- The price lookup (`api.coingecko.com`) had no timeout. On a mining network
  that black-holes the API the button spun forever; now it gives up after six
  seconds and says so, and the manual field is unchanged.
- A form on the wizard could implicitly submit on Enter, which would have put
  the wallet in the address bar. Enter now advances a step, and submit is
  prevented outright.

### Fixed (tests)
- `zmrig/tests/net.sh`'s two algorithm cases were flaky on a loaded machine:
  they shared the main pool's `--diff 50`, so "a share arrived within 6 s" was
  a coin toss (0 accepted shares, twice in a row, while the CPU was busy with
  the web suite). They now get their own pool at `--diff 1` and produce ~85
  shares deterministically.

### Tests
- `web` **57 pass, 0 fail**, including new `pools.test.js` (table consistency
  across four files), `wizard.test.js` (12 cases: gating, deep links, TLS,
  failover, wallet never in the URL, wizard == builder) and `pages.test.js`
  (duplicate ids, one `h1` per page, alt text on images, every local link
  resolves, both pages load the shared files in the right order).
- No miner code changed: `zmrig/tests/*` and `proxy` counts are unchanged.

# v6.30.0-mo13 — do not get banned, and do not be blocked

Two ways to lose an evening of income that no hashrate chart shows: a pool that
bans the IP, and a network that cannot resolve the pool at all.

### New
- **A pool refusal is now a decision, not a loop** (`zmrig/src/stratum.zig`,
  `proxy/src/upstream.js`). The reply is classified — `banned`, `credentials`,
  `invalid share`, `throttled`, `full` — and each gets its own reaction:
  - a **wrong wallet or password** stops retrying that pool for **30 minutes**
    and prints the fix (95-character address? TLS port?) instead of knocking
    every five seconds, which is how one typo becomes a ban on every pool;
  - **`your IP is banned`** cools that pool for **15 minutes** (`--ban-cooldown`,
    default 900 s) and moves to the next one;
  - **full / rate-limited** pools are paused for a minute rather than hammered.
- **Invalid-share circuit breaker** (`zmrig/src/miner.zig`). Three shares the
  pool calls invalid in a row and the miner stops submitting for 10 minutes and
  says why (overclock, huge pages, `--self-test`). Pools that validate every
  share ban the IP for this: `xmrpool.eu` 10 minutes, an hour if it continues.
- **Jittered reconnects** (±20 %). Twenty rigs rebooting together used to arrive
  in the same millisecond, which from the pool side is a login flood.
- **`--pool=<name>`** (`oneclick.sh`): `moneroocean`, `supportxmr`, `c3pool`,
  `xmrpool`, `herominers`, `p2pool`, `p2pool-nano` resolve to the right host,
  port and TLS mode. `--failover=<list>` writes backup pools into
  `config.json`, used only when the first is unreachable or refuses this IP.
- **`doc/POOLS.md`**: the pool table with fees, minimums and endpoints checked
  in October 2026, plus the part nobody tests — Quad9 returns NXDOMAIN for
  `gulf.moneroocean.stream`, Cloudflare's malware resolver does the same for
  `pool.supportxmr.com`, and what to do instead (backup domain, regional
  hostname, TLS on 443, `--connect-to`).

### Measured
- No hashing code changed: the hashrate figures in `doc/BENCHMARKS.md` still
  describe this engine.
- `zmrig/tests/net.sh` proves the three behaviours over a real socket: a bad
  wallet produces **one** connection attempt, a banned IP produces **one**, and
  a pool that rejects every share gets exactly **3** submissions before the
  quarantine line appears.

### Tests
- `zmrig/tests/unit.sh` 16 modules OK (added: refusal classification, jitter
  bounds).
- `zmrig/tests/net.sh` **29 passed** (was 26).
- `zmrig/tests/cli.sh` **40 passed** (was 37).
- `tests/oneclick/plan.sh` **18 checks** (was 14): pool names, failover,
  and an explicit `host:port` is never rewritten.
- `proxy/` **60 passed** (was 57).
- Version: `6.30.0-mo13`.

# v6.29.0-mo12 — get paid for the coin that pays best

The income lever here is not hashrate. It is whether the pool is allowed to move
a rig to a coin that is worth more per hash at that moment — and until now the
miner never said it could.

### New
- **`--algo=auto`** (`zmrig/src/options.zig`, `zmrig/src/stratum.zig`). The engine
  has implemented seven RandomX variants all along, each with its own named
  configuration (`src/crypto/rx/RxAlgo.cpp`: Monero, Wownero, Arqma, Graft,
  Safex, Yada, Scala), but the login request advertised nothing, so a pool that
  pays the best coin per hash (MoneroOcean and forks) treated every rig as
  Monero-only and left it on `rx/0`.
  - `-a auto` now sends
    `"algo":["rx/0","rx/wow","rx/arq","rx/graft","rx/sfx","rx/yada","panthera"]`;
  - `-a rx/0` still sends one entry — a pin stays a promise;
  - no flag stays exactly as before: no list, the pool decides;
  - `"algo": "auto"` also works in the JSON config;
  - `--check` prints what will be advertised, because a list a pool ignores is
    otherwise invisible.
  - `rx/2` is deliberately **not** advertised: its parameters differ between pool
    forks, and guessing wrong means every share is rejected.
- **The proxy advertises the same family** (`proxy/src/upstream.js`,
  `--algo=auto` is its default). The proxy holds the pool connection, so a rig
  behind a silent proxy never gets switched no matter what the rig supports.
  `--algo=none|<name>[,<name>]` controls it, and a typo is refused at startup.
- **Per-algorithm nonce offset in the proxy** (`proxy/src/blob.js`). Panthera
  blobs carry the nonce at byte 147, not 39 (`zmrig/src/job.zig:88`). Writing the
  extranonce at 39 for a panthera job corrupts the header and every share comes
  back rejected while the log still looks normal. The offset now follows the
  algorithm, a forwarded share carries the algo of the job it was found for, and
  a test switches a live fake pool to panthera to prove both.

### Also in this release
- **A rig behind the proxy now knows what it earns.** `/status` publishes
  `hashrate`, `sharesPerHour` and `xmrPerDay` per rig and for the fleet, measured
  from accepted shares at the difficulty the proxy handed out
  (`proxy/src/network.js`). Money needs the network difficulty, which is an
  input (`--network-difficulty=` or `--network-url=`), never a guess: with
  neither flag set the column is `null` and `estimate.source` says why.
- **A switching pool keeps the fee-free engine.** `--pool=gulf.moneroocean.stream`
  used to select the C++ engine because `zmrig` could not advertise more than one
  algorithm. It can now, so `oneclick.sh` writes `"algo": "auto"` for the pool
  (`oneclick.sh`, `zmrig/src/options.zig`) and `./oneclick.sh plan` prints the
  list it will advertise. An explicit `--algo` still pins, and a non-RandomX
  `--algo` (cn/2, …) still selects the C++ engine.
- `--algo` in the JSON config accepts `"auto"` *per pool*, so one file can serve a
  Monero-only rig and a switching rig.

### Measured
- The binary's own hashrate is unchanged: this release adds no hashing code.
  What changes is *which coin* the pool is allowed to point the rigs at.
- `zmrig/tests/net.sh` gained four cases that speak over a real socket: the
  pool receives the family with `-a auto`, receives exactly `rx/wow` with a pin,
  and both configurations still mine and submit accepted shares. **26 passed, 0
  failed** (was 22).

### Fixed
- `--check` now states what is at stake on the MSR line (`--msr` is worth 5-15 %
  on Zen 3/4 per `doc/PERFORMANCE.md` §3) instead of just "off".

### Tests
- `zmrig/tests/unit.sh` 16 modules OK (added: login JSON with no list, one
  algorithm, the full family, a quote in a password; algo resolution and the JSON
  config; `auto` is not `rx/2`).
- `zmrig/tests/cli.sh` **37 passed** (was 32): `--algo=auto` accepted,
  documented, shown in `--check`; a pool object with `"algo": "auto"` in the
  config file produces the same advertisement; an unknown name still exits 1.
- `zmrig/tests/net.sh` **26 passed** (was 22).
- `tests/oneclick/plan.sh` **14 checks**: a switching pool now resolves to
  `zmrig`, the plan prints `algo auto  (RandomX family: …)`, an explicit
  `--algo=rx/wow` still pins, and the C++ path is still covered through a
  non-RandomX pool.
- `proxy/` **57 passed** (was 43): 7 for the money column, 2 that drive it
  end-to-end through `/status`, 1 for the new flags.
- Version: `6.29.0-mo12`. `doc/BENCHMARKS.md` still says `6.28.0-mo11` on
  purpose — those numbers were measured with that binary.

# zmrig-proxy 1.0.0 — one address for every rig

A new program in `proxy/`, not a fork. The miner binary is unchanged at
`6.28.0-mo11`; this release is about the farm, not the CPU.

Proxies are where income disappears quietly: rigs connected, shares accepted,
log clean. So every piece here exists to make one specific silent failure
impossible, and each has a test that fails if it comes back.

### New
- **`proxy/install.sh`** — one command to a systemd service (`--dry-run` prints
  the unit, `--uninstall` removes it). It copies `proxy/` and `pool/src` side by
  side because the proxy shares the pool's target maths, and a test runs the
  copied layout so that path cannot rot.
- **`zmrig-proxy`** (`proxy/`, Node 18+, no dependencies) — the whole farm behind
  one address and one pool connection.
  - **Extranonce per rig** (`proxy/src/blob.js`, `proxy/src/extranonce.js`):
    a little-endian `uint32` at blob offset 39, top byte per rig, 255 rigs. The
    allocator hands out `1..255` and **never 0**, because a blob whose nonce is 0
    is the signal that turns extranonce support *off* in the miner
    (`zmrig/src/job.zig:130`, `detectNicehash`) — prefix 0 silently reintroduces
    duplicate work. A rig that overwrites its own byte is reported once, with the
    byte it used instead of a flood of warnings.
  - **Per-rig difficulty** (`proxy/src/vardiff.js`): local equals upstream by
    default, so every accepted share is forwarded and the pool's hashrate
    estimate stays exact; allowed range `[upstream/8, upstream×4]`, 15 % deadband,
    `forwardRatio` and `absorbed` published on `/status`.
  - **Failover and survival** (`proxy/src/upstream.js`): one upstream connection,
    exponential backoff (5 s → 60 s) on a drop, **immediate rotation** when a pool
    refuses the login, rigs never dropped, last job replayed during an outage.
  - **Four transports, one protocol**: `stratum+tcp`, `stratum+ssl`, `ws`, `wss`
    (`proxy/src/conn.js` adapts them; `pool/src/ws.js` does the RFC 6455 work).
  - **One flag for the public path**: `--tunnel=wireguard|tailscale|cf|cf-quick`.
    `wireguard` generates a server config plus one peer file per rig
    (`10.66.66.2 …`), one UDP port, no third party. `tailscale` logs in with
    `--tunnel-token` and uses Funnel only for the WebSocket listener. `cf-quick`
    **refuses to start without `--ws`** and prints why it is a demo: random
    hostname per restart, 200 concurrent requests, no authentication, no SLA.
  - **Default-safe**: binds `127.0.0.1`, refuses `--bind=0.0.0.0` without
    `--token` or `--allow=<cidr>`, rate-limits 60 connections/minute per IP,
    status endpoint on loopback behind a bearer token.
  - **`doctor`** tests the pool, the wallet and the network before a rig is
    pointed anywhere, including the arithmetic an operator usually gets wrong:
    shares/hour = `hashrate × 3600 / difficulty`.

### Fixed (pool)
- **`nextDifficulty()` had the vardiff ratio inverted**
  (`pool/src/target.js`). It computed `observed/desired` instead of
  `desired/observed`, which is the one direction error that is invisible: a slow
  rig was given harder and harder targets until it submitted nothing at all while
  still drawing full power, and a fast rig drifted to the floor. Measured, same
  inputs: `nextDifficulty(1000, 60 s, 15 s)` returned **2000** (harder); it now
  returns **500**. `nextDifficulty(1000, 1 s, 15 s)` returned **500**; it now
  returns **2000**. The two columns were exactly swapped. The unit test now pins
  the direction (`slow < 1000`, `fast > 1000`) instead of only asserting that a
  number came back.
- **`difficultyFromTarget()` read the wire target as big-endian**
  (`pool/src/target.js`). `targetHex()` writes a little-endian `uint64` — which is
  what a miner reads — and the inverse parsed the hex as big-endian, so
  `difficultyFromTarget('efa7c64b37894100')` returned **1.0682** instead of
  **1000**. Nothing in the pool called it, which is why the old round-trip test
  (bigint in, bigint out) passed; the proxy is the first caller, and a proxy that
  believes the pool's difficulty is 1/937th of the truth forwards shares that have
  not cleared the pool target. Both the wire form and a 32-byte target (low 64
  bits) are now handled, and tested.

### Tests
- `proxy/`: **43 passing** (`14` blob/extranonce/vardiff, `8` data plane over real
  sockets — two rigs on one upstream connection, correct pool job id on forward,
  absorbed shares counted, pool death survived, login-refusal failover, `14` flags
  and access control (IPv4 and IPv6 CIDR), `4` the real binary over TCP and WebSocket including the
  token gate, `/status`, `doctor` and a clean SIGTERM).
- `pool/`: **29 tests, 26 pass**, 3 skipped by design (was 28/25).
- Docs in the same change: `doc/PROXY.md`, `README.md`, and
  `web/content/vi/proxy.md` linked from the site's navigation.

# v6.28.0-mo11 — the miner that knows when it stopped earning

Two changes, both about income that is lost silently.

### Fixed
- **Threads were pinned to the wrong CPUs on AMD (and some ARM) machines.**
  `zmrig` pinned thread *i* to cpu *i*, which is correct on most Intel parts and
  wrong everywhere siblings are numbered adjacently: on AMD Zen, cpu0/cpu1 are
  the two halves of one core. Profile `watt` asks for exactly one thread per
  physical core, so on a 8c/16t Zen box it pinned 8 threads onto 4 cores —
  ~50 % of the hashrate gone, in the profile that was supposed to be careful
  with power. New `topology.selectCpus()` builds the order from sysfs: one CPU
  per physical core first, sockets interleaved (a 2-thread run on a 2-socket
  machine takes one core from each), SMT siblings last and only for profile
  `free`. `--check` now prints the mapping (`cpus [0,2,4,6] on 16 cpu(s), 8
  physical core(s)`), which is what makes a wrong pin visible instead of silent.
- **A CPU subset is respected and reported.** A unit with `CPUAffinity=`, a
  cgroup cpuset or a `taskset` wrapper used to be ignored: the miner pinned to
  CPUs the kernel then refused, and every thread silently floated.
  `sched_getaffinity` is now consulted, and `--check` says
  `affinity process allows 1 of 2 online cpu(s)`.

### New
- **Health monitoring and self-recovery.** Three failure modes earn nothing
  while looking fine: the hashrate collapses (throttle, a stuck engine), the
  pool rejects every share (wrong algorithm after a fork, a pool-side bug), the
  pool goes silent. The miner now evaluates its own numbers once a second
  (`zmrig/src/health.zig`, 7 unit tests) and reports `warming | ok | degraded |
  stalled | rejected`; a user pause (`--pause-on-battery`) is never a fault, and
  a dip must persist ten minutes before it is called degraded.
  - the state goes into the log line `health: ok rate 60s … accepted … rejected …`
    and into the `ZMRIG1.` code as `"health"`, so a fleet dashboard can sort by
    "running but earning nothing";
  - `oneclick.sh status` shows it, with the exact consequence when it is a fault;
  - after **15 minutes** of `stalled` or `rejected` the process exits with code
    3, which `Restart=always` turns into a clean start. That trade is deliberate:
    16-30 s of lost hashrate against hours of zero. `--no-health-restart`, or
    `"health": {"restart": false}` in the config, turns it off for machines that
    must stay up regardless; `--health-restart=SEC` and `--health-warmup=SEC`
    adjust the delays.
- `zmrig/tests/health.sh`: proves both directions against a real pool — an
  honest pool never raises a fault, and a pool that rejects everything is caught
  and produces exit code 3 (7 checks, run in CI).

### Measured
- The pinning fix cannot show a number on the validation box: it is a 2 vCPU
  container where the old mapping (`0,1`) and the new one are identical, and the
  same binary varies by ±30 % between runs because the host is shared. It is
  reported as **no measurable change here**; the case it fixes needs AMD or
  dual-socket bare metal, where the old order was measurably wrong
  (`--cpu-affinity=0x1` on this box: 552.6 vs 1070.0 H/s, −47 %).
- The health check runs on the monitor thread once per second and the hash loop
  was not touched; `--report` after the change measured 810-834 H/s against
  1058.9 H/s an hour earlier on the same binary — host load, not a regression.

# v6.27.0-mo10 — no flags, two profiles, and a way out

The installer now decides everything from the machine it is on, and the miner
learned which of two very different jobs it is being asked to do.

### New
- **`--profile free` and `--profile watt`.** `free` is a machine whose
  electricity costs nothing (a coffee shop, a lab, an office PC): every logical
  CPU, `--mode fast`, huge pages, `--priority 5`, `performance` governor. `watt`
  is the opposite machine: one thread per physical core (SMT adds 5–15 % hashrate
  for 30–40 % more power), a power-aware governor left alone, and mining paused
  when a laptop drops to battery. The default is `auto`, which reads the battery
  state. New modules `zmrig/src/topology.zig` (physical cores, VM detection,
  battery) and `zmrig/src/autotune.zig` (candidates, 2 % margin, median), 13 unit
  tests between them.
- **`zmrig --autotune[=SEC]`** searches for the best thread count on the real
  dataset — one trial per candidate, 2 % margin above noise — and prints a table
  plus a machine-readable `autotune-best-threads=N` line. It needs no pool: it
  measures the machine. The installer runs it once after the build and bakes the
  winner into `config.json` as `cpu.threads` (skip with `--no-autotune`).
- **Zero-flag install.** `sudo ./oneclick.sh` with only a wallet now resolves the
  engine from the pool (a switching pool like MoneroOcean gets the C++ engine and
  its 34 algorithms; a RandomX-only pool gets `zmrig`, which is faster and
  fee-free), the profile from the battery, the threads from a measurement and the
  huge pages from the dataset size. `./oneclick.sh plan` prints every decision
  with its reason and changes nothing.
- **`oneclick.sh purge`** removes everything the tool installed — service units,
  binaries, config (wallet included), state, build cache, logs — prints the exact
  list with sizes first, asks for the word `purge` before deleting, returns
  `vm.nr_hugepages` to the kernel, and never touches a file it did not create.
  `--dry-run` lists without deleting; `--yes` for scripts.
  `uninstall` keeps its old, less destructive contract.
- **Hashes per watt in the report code.** `ZMRIG1.` grew `"hw"` (hashrate ÷
  watts, from the 60 s column) next to `"pw"`, so the profile trade can be
  checked on the actual machine instead of believed. `null` when no power source
  exists — never 0.
- **`oneclick.sh tune`** re-runs host tuning *and* the thread search, and writes
  the result into the existing `config.json`.

### Fixed
- **The 15-minute column was an 8.5-minute average.** The sample ring held 512
  one-second samples, so `rate(900)` silently fell back to the oldest sample it
  had. It is 1024 now: a real 15-minute figure after 15 minutes of mining.
- `--autotune` was rejected with `NoPools`, which made the one command that
  helps a fresh box useless on a fresh box.
- `oneclick.sh config --engine=zmrig` wrote `"algo": null` because it skipped
  engine resolution; it now pins `rx/0`.
- The installer's `performance` governor is no longer forced under the `watt`
  profile, and `tune-linux.sh --profile` is testable against a fake sysfs tree
  (`CPU_ROOT`, `POWER_SUPPLY_ROOT`).

### Performance
- Per-thread hash counters are padded to one 64-byte cache line each (no more
  false sharing across neighbouring threads), and the benchmark stop condition
  is checked every 64 hashes instead of every hash. **Both are below the noise
  floor on the 2 vCPU test box and are reported as such** — full A/B, including
  the negative results, in [`doc/PERFORMANCE.md`](doc/PERFORMANCE.md) §2b/§2c.
  End-to-end after the round: 1058.9 H/s against the 1070.0 H/s baseline, i.e.
  inside the ±2.7 % band: no regression, no claimed speedup.

### Tests
- `tests/oneclick/{plan,config,governor,purge}.sh` — 41 checks that run the real
  commands against temporary trees: the auto rules, what lands in config.json,
  which governor each profile gets, and a purge that must delete exactly its own
  paths and nothing else. Wired into CI (`installer` job) and `npm run
  test:oneclick`.
- `zmrig/tests/cli.sh` grew 8 checks for `--profile`, `--autotune` and their
  `--help` coverage; `report.zig` and `options.zig` grew 5 unit tests.

# v6.26.0-mo9 — mining through picky networks

The transport layer of `zmrig` was rewritten into a byte-stream layer
(`zmrig/src/transport.zig`) and grew everything a VPS behind a restrictive
firewall or a CDN needs. The C++ engine is untouched.

### New
- **The miner reserves its own huge pages: +25.0 % measured end-to-end.**
  A fresh box has `vm.nr_hugepages = 0`, so RandomX runs on 4 KiB pages and
  mines at 855.8 H/s; `zmrig` now reserves the 2 MiB pages the current mode needs
  (1208 of them for `--mode fast`) when it starts as root and reaches
  **1070.0 H/s** with no user action. It reports what the kernel actually granted,
  never fails the run, logs the exact sysctl command with the measured cost when
  it cannot (unprivileged/container), never writes during `--check`, and is
  switched off with `--no-auto-hugepages` (implied by `--no-huge-pages`).
  New module `zmrig/src/hugepages.zig` with the parsing and the decision logic
  under test.
- **Machine report and web dashboard.** `zmrig --report` measures for 15 s and
  prints one line — `ZMRIG1.` + base64url(JSON) — with CPU, threads, algorithm,
  hashrate (10 s / 60 s / 15 min / peak), huge pages, shares, uptime and power
  (RAPL, hwmon or `--power`). `--report-file`/`--report-interval` keep that code
  in a file while mining, `--report-id` names the machine. The code contains no
  wallet and no token.
- **`web/`**: a static documentation site (9 pages, Vietnamese, no framework,
  no tracking) and a fleet calculator that decodes report codes, prices
  electricity and revenue per machine and in total, stores the fleet in
  `localStorage`, exports/imports JSON and shares a link. Deployable to
  Cloudflare Pages or Vercel with no build step; `_headers` and `vercel.json`
  ship strict CSP and cache headers.
- `--cloudflare[=HOST[:PORT]]` (installer and `zmrig`): pool over
  WebSocket inside TLS on 443, the one shape that passes CDN-only and
  HTTPS-only egress. The installer writes it into the pool section of
  `config.json` and switches to the `zmrig` engine, which is the only one with a
  WebSocket client. `--cloudflare=host` also sets the pool.
- WebSocket and WebSocket-over-TLS stratum clients (`ws://`, `wss://`,
  `--transport ws|wss`), including RFC 6455 framing (client masking, 126/127
  extended lengths, ping/pong, close), accept-key verification and a synthetic
  line terminator so the stratum reader is shared with the TCP path.
- Proxy support: HTTP `CONNECT` with basic auth and SOCKS5 with
  username/password and remote DNS (`--proxy http://... | socks5://...`).
- `--connect-to HOST[:PORT]`: dial a specific address while keeping the pool
  name for TLS SNI and the `Host` header (whitelisted CDN ranges, anycast).
- `--tls-ca FILE`: trust a private CA / pin a relay certificate. The installer
  copies the file to `/etc/xmrig-ocean/tls-ca.pem` so the unit's private `/tmp`
  cannot break it.
- `--idle-timeout N` (default 300 s, 0 disables) and a periodic `keepalived`
  (`--keepalive-interval`, default 60 s) so CDNs and NATs do not cut idle
  sockets.
- `doc/NETWORK.md`: the whole feature, plus a complete Cloudflare Worker relay
  that turns any plain pool into a `wss` endpoint.
- **Local read-only monitoring API** (`--http-port`, `--http-host`,
  `--http-access-token`, and `--http-port/--http-token/--no-http` in the
  installer): `/1/summary` and a pretty printed `/2/summary` in the XMRig
  shape, optional bearer token, 404/401 JSON. `oneclick.sh status` now reads
  hashrate, huge pages and shares from it instead of scraping the journal.
- **Network test suite** (`zmrig/tests/net.sh`): a fake Stratum pool with
  `basic`/`soak`/`hostile`/`stall` modes plus TLS/WebSocket/WebSocket+TLS/
  HTTP-CONNECT/SOCKS5 shims. 19 checks cover every transport, the Cloudflare
  pinned-edge recipe, a rejected login, the idle watchdog, pool failover, a
  pool that floods malformed JSON, a seed change, an `rx/wow` switch, an abrupt
  reset and the API. ~10 minutes, exit code 1 on any failure.

### Fixes
- **`./zmrig/build.sh --portable` did not build.** `aes_hash_vaes512.cpp` uses
  AVX-512/VAES intrinsics but was compiled with whatever `-march=native` gave the
  build host; without AVX-512 the compiler stops at "target specific option
  mismatch" (reproduced by deleting the object and rebuilding). That file is now
  compiled with `-mvaes -mavx512f -mavx512vl` on its own, so the build no longer
  depends on the ISA of the machine doing the build. The routine is still only
  called behind a runtime CPUID check.
- **VAES-512 measured on an Intel Xeon: −3.5 %, so it stays gated.** Upstream
  calls the VAES path only on AMD Zen 5. Widening the gate to "CPU has VAES +
  AVX-512F" was tried on this host (which has `vaes`, `avx512f`, `avx512vl`):
  dataset init 15.2–15.7 s → 16.5–16.9 s and hashrate 1070.0 → 1033.0 H/s, with
  bit-identical hashes. AVX-512 frequency licensing costs more than the wider
  AES buys. Written up in `doc/PERFORMANCE.md` §2b together with the knobs that
  turned out to be inside noise, and with why vector width, quantum computing and
  a different host language cannot move RandomX hashrate.
- **Config values were silently replaced by CLI defaults.** `zmrig -c
  config.json --verbose` reset `mode`, `huge-pages`, `huge-pages-jit`, `jit`,
  `affinity`, `priority`, `print-time`, `retries`, `retry-pause`,
  `idle-timeout`, `keepalive-interval`, `scratchpad-prefetch`,
  `optimized-init`, `colors`, `verbose` and `background` to their defaults.
  Options now carry a `seen` set: only flags actually given override the file.
- **`report.enabled` in a config file used to switch on the standalone
  `--report` benchmark**, so a service would measure and exit instead of
  mining. The key now gates only the report file.
- **`--tls` implicitly disabled certificate verification** (it set
  `tls_insecure`). It now selects the transport only; `--tls-insecure` remains
  a documented no-op because Zig 0.13's TLS client cannot skip verification.
- **`--check` could be ignored when `-c` was used** because the config's report
  block took the run down the benchmark path. `--check` is now decided before
  any mining mode.
- **A client that opened the HTTP API socket and stayed silent blocked the API
  thread forever.** Every accepted socket now has a 5 s send/receive timeout.
- **`--report` segfaulted when no pool was configured** (it read
  `pools.items[0]`). It now measures the machine without a pool.
- **The report file was never created if its directory did not exist.** The
  writer creates the parent directory once.
- **The usage text lost its indentation** around `--check`/`--bench` while the
  report flags were added; fixed along with the new entries.

- **`-u WALLET -o pool` failed with `InvalidPool`.** Per-pool options seen
  before the pool they belong to created an empty placeholder pool; they are
  now defaults for the pools that follow (`-p`, `--rig-id`, `--keepalive`,
  `--nicehash`, `--tls` too), and `-o a -o b -u W` gives both pools the wallet.
- **Ctrl-C could hang for minutes** on a pool that never answers the login: the
  monitor now owns the socket from the moment it is connected (not only after
  a successful login), a 1 s receive timeout lets the read loop see the stop
  flag, and a send timeout keeps thread joins bounded during a seed change.
- **`--http-port` was documented but nothing listened on it** (see above).
- **A pool sending one oversized line killed the session**; over-long lines are
  now skipped instead of ending the connection.
- **`--background` did nothing.** It now forks, detaches from the terminal and
  keeps mining (logging to `--log-file` if one was given), like XMRig.
- **Reconnects wasted `--retry-pause` seconds.** A dropped connection is
  retried in 200 ms and repeated failures back off 200 ms → 500 ms → 1 s →
  `--retry-pause`, instead of a fixed pause after every attempt (and instead of
  hammering a dead pool in bursts).
- **Log files contained ANSI colour escapes.** The file now gets plain lines;
  only a terminal gets colour.
- **Reconnect left the rig at 0 H/s.** The disconnect path paused the workers
  and only a *seed change* unpaused them, so a dropped connection with an
  unchanged seed never resumed hashing. `applyJob` now always unpauses.
- **SIGTERM could hang for minutes** while the main thread was parked in a
  blocking read: the monitor thread now closes the socket when shutdown starts.
- **Mining stopped during a reconnect.** Workers keep hashing the last job;
  shares found in the gap are dropped with a rate-limited warning instead of
  pausing the rig.
- **SOCKS5 greeting had a wrong method count** (`NMETHODS=2` with one method
  byte), which deadlocked against a real proxy until the OS timeout. The
  greeting now always matches its length, and "no authentication" is offered
  next to username/password.
- **Proxy and TLS/WebSocket handshakes had no deadline**, so a half-open proxy
  could park the miner in `read()` forever. Handshakes now run with a 20 s
  socket timeout that is removed once the session is up.
- **Shares were submitted with a hardcoded `"algo":"rx/0"`**; the job's own
  algorithm is used now.
- **`--cloudflare` dropped an explicit port** (`--pool host:4702` became 443).
- **`status` could report the previous run's hashrate.** It is now scoped to
  the current service start and ignored when older than 90 s, so a reconnect
  loop shows "no data yet" instead of a number that looks live.
- **`--tls` marked the pool as TLS but kept port 3333** when the URL did not
  specify one; it now follows the transport's default port.

# v6.26.0-mo8 — the Zig miner

A complete second miner, in Zig, on top of the same RandomX engine: same
hashrate as the C++ frontend, no runtime, no donation code, and a build that
needs only `g++` + `zig`.

### New: `zmrig`
- `zmrig/` — Zig frontend (stratum over TCP/TLS, login/job/seed rotation,
  keepalive, failover, share submission, huge pages, thread pinning, priority,
  pipelined hashing, XMRig-compatible CLI and JSON config, live 10 s/60 s/15 min
  hashrate, session maximum, `--version/--check/--self-test/--bench`).
- `zmrig/capi/` — a small C ABI over the RandomX engine in
  `src/crypto/randomx` (`xmo_*`), so the miner keeps the reference JIT and its
  AVX-512/VAES paths instead of re-implementing them.
- `zmrig/build.sh` — compiles the engine with the project's own flags, caches
  objects per flag signature, then links the Zig frontend against
  `libxmorx.a` and the system `libstdc++`/`libgcc_s` (Zig 0.13 cannot resolve
  `-lstdc++` on a bare Debian).
- `zmrig/tests/run.sh` + `zmrig/tests/api_test.cpp` — engine conformance:
  reference vectors, pipelined vs one-shot hashing, 2 GiB dataset vs cache.
- `zmrig/README.md` — architecture, build, test, measured numbers, known limits.

### Installer (1.1)
- `--engine xmrig|zmrig` (`MINER_ENGINE`), recorded in
  `/etc/xmrig-ocean/engine`; `zmrig` installs `${PREFIX}/bin/zmrig` plus the
  `xmrig-ocean` symlink so the unit, logs and helpers stay identical.
- Zig is provisioned automatically from the PyPI wheel
  (`pip3 install ziglang==0.13.0`) when it is not on `PATH`.
- `status`/`logs`/`bench`/`verify`/`start`/`stop`/`restart` resolve the installed
  engine; `bench` drives `zmrig --bench=N` and `verify` runs the Zig self-test
  plus a `strings | grep -c donat` audit.
- Engine-specific dependencies: the `zmrig` path no longer requires
  libuv/cmake/OpenSSL/hwloc.
- Fixes found by running it end to end: `--engine` on the command line now wins
  over a stale install marker; reinstalling restarts a running miner instead of
  leaving the old process with the old config; log parsing starts at the new
  service start, so `status`/`wait_ready` cannot read yesterday's hashrate;
  `status` reports "not running" instead of a stale number; the self-test falls
  back to `--self-test=light` while a full-memory miner holds the huge pages;
  `as_root` strips leaked D-Bus session variables that make `systemctl` fail.

### Performance
- `zmrig` installed as a service: **1084–1089 H/s** (C++ frontend on the same
  host: 1075.7 H/s via `scripts/bench.sh`), dataset init 15.2 s, 2336 MB of the
  cache+dataset in 2 MiB huge pages, 0 rejected shares over the validation run.
- `zmrig --bench=100000 -t 2`: 100001 hashes in 91 071 ms = 1.098 kH/s.

### Docs
- **Branches are `ALPHA` → `BETA` → `master`, and the code now says so.**
  `oneclick.sh` defaults to `BETA` (was a short-lived session branch), and so do
  every install one-liner, the site's command builder and every documentation
  link. Two silent failures were fixed on the way: `update` fetched the branch
  without checking the result, then checked out without checking either, so a
  renamed or deleted branch left the tree where it was while the command printed
  a commit hash and "sources updated"; and switching branch inside a
  `--depth 1` single-branch clone could never work, because the fetch refspec
  does not cover the other branch. `fetch_branch`/`checkout_branch` now fetch by
  name, create the local branch from the explicit remote ref, and die with the
  branch name in the message. Both are pinned by `tests/oneclick/branch-switch.sh`
  (local fixture, no network) and by `web/tests/branches.test.js`, which fails if
  an install URL ever names a branch other than `ALPHA`, `BETA` or `master`.
- **Donations, published once.** The project takes no fee, so the README, the
  landing page and the Vietnamese guide now carry one optional Monero address
  (`doc/DONATE.md`, QR in `doc/donate/monero.png`), next to an explicit list of
  what a donation does not buy. Three guarantees are enforced, not promised:
  the address is nowhere in `src/`, `zmrig/`, `pool/` or `oneclick.sh`, so the
  fee audit still reports 0 %; `web/tests/donate.test.js` fails if any published
  copy differs from the wallet the pool actually pays to; and the QR decodes
  back to the same string.
- **`doc/SETUP.md`**: the manual half of the deployment, in one page — the branch
  layout (`BETA` is the release branch), the repository settings that need the
  Settings UI, the two workflow files to paste (site tests, GitHub Pages), the
  three ways to publish `web/`, the pool on Render/Fly/Workers with the required
  `DAEMON`, and a table of what a sandboxed session cannot do and why.
- **Markdown renderer**: images render, `javascript:` links and `src` values
  are dropped instead of emitted, and a link whose label is itself a code span
  no longer loses its anchor.
- New section in `doc/ALTERNATIVES.md` answering the "rewrite it in Zig + NASM +
  CUDA" proposal with measurements: what the Zig host buys (latency, not
  hashrate), why the NASM core already exists as the RandomX JIT, and why a
  CUDA layer cannot mine Monero.

# v6.26.0-mo7 — one-click deployment

Everything needed to go from a bare Linux machine to a tuned, supervised,
fee-free miner in one command, plus the measurements that justify the choice of
miner.

### One-click
- New `oneclick.sh`: dependency install, native build, host tuning, validated
  config, systemd service + boot-time tuning unit, first-share wait, fee audit
  and a summary card. Idempotent, with `install|build|tune|config|start|stop|
  restart|status|logs|bench|verify|update|uninstall` subcommands.
- Falls back to a supervised background process when systemd is not available.
- `status` reports service state, live hashrate (10 s/60 s/15 m), accepted
  shares, huge pages and the log tail from the local HTTP API.
- Helper binaries installed next to the miner: `xmrig-ocean-tune`,
  `xmrig-ocean-bench`, `xmrig-ocean-verify`.

### Performance / behaviour
- **Skip the algo-perf calibration when every pool pins an algorithm.** With
  `--algo` set the table is never consumed, so the first share no longer waits
  ~2 minutes (`src/App.cpp`, `MoBenchmark::skip()`).
- `scripts/tune-linux.sh --quiet` for unattended/systemd use.
- `scripts/bench.sh`: new `--hashes` window option, validated against the sizes
  the miner accepts (250K/500K/1M-9M), and a per-thread hashrate line.

### Docs
- New `doc/INSTALL.md` (installer, options, fleet install, troubleshooting) and
  `doc/ALTERNATIVES.md` (Rust/Go/other miners versus this one, with measured
  numbers: the RandomX JIT is 6.1x faster than the portable interpreter on the
  validation host).
- README starts with the one-click path; the old instructions are now "manual
  install".

# v6.26.0-mo6 — fee-free / performance release

Rebuilt from `6.26.0-mo5` with two goals: **0% developer fee** and the highest
achievable CPU hashrate on the machine that compiles the binary.

### Zero fee
- Removed `src/net/strategies/DonateStrategy.{h,cpp}`, the `donate` job index,
  the donation submit path, the donation pool endpoints and the developer wallet.
- `kDefaultDonateLevel` and `kMinimumDonateLevel` are `0`; `Pools::donateLevel()`
  is a `constexpr` returning `0`; the API and `Summary` report `0%`.
- `--donate-level` / `--donate-over-proxy` are still parsed for compatibility but
  have no effect (`doc/ZERO_FEE.md`).
- Removed the MoneroOcean hack that disabled the fee only when the first pool host
  matched `moneroocean.stream`.
- `scripts/verify-fee-free.sh` audits source and binary.

### Performance
- New `cmake/tuning.cmake`: `-march=native/-mtune=native`, `-fno-plt`,
  function/loop alignment and optional PGO (`generate`/`use`). LTO is available
  but **off by default**: GCC 12 miscompiles CryptoNight under LTO and the CPU
  backend then refuses to start (`self-test failed`).
- Runtime defaults for dedicated rigs: `huge-pages-jit` on, `yield` off,
  scratchpad `memory-pool` on, 1 GiB pages auto-detected (only requested when the
  kernel actually reserved them, no more misleading error).
- Linux: `cpu.priority` now really applies `setpriority()` (was a no-op).
- Actionable warning when huge pages are not fully allocated.
- `scripts/build-optimized.sh`, `scripts/tune-linux.sh`, `scripts/bench.sh` and
  `config/performance.json`.
- Measured in the validation sandbox: RandomX hashrate is not affected by
  compiler flags (JIT), the gain comes from memory setup and from removing the
  donation switch — see `doc/PERFORMANCE.md` §1 and §6.

### Fixes
- **Config values were silently replaced by CLI defaults.** `zmrig -c
  config.json --verbose` reset `mode`, `huge-pages`, `huge-pages-jit`, `jit`,
  `affinity`, `priority`, `print-time`, `retries`, `retry-pause`,
  `idle-timeout`, `keepalive-interval`, `scratchpad-prefetch`,
  `optimized-init`, `colors`, `verbose` and `background` to their defaults.
  Options now carry a `seen` set: only flags actually given override the file.
- **`report.enabled` in a config file used to switch on the standalone
  `--report` benchmark**, so a service would measure and exit instead of
  mining. The key now gates only the report file.
- **`--tls` implicitly disabled certificate verification** (it set
  `tls_insecure`). It now selects the transport only; `--tls-insecure` remains
  a documented no-op because Zig 0.13's TLS client cannot skip verification.
- **`--check` could be ignored when `-c` was used** because the config's report
  block took the run down the benchmark path. `--check` is now decided before
  any mining mode.
- **A client that opened the HTTP API socket and stayed silent blocked the API
  thread forever.** Every accepted socket now has a 5 s send/receive timeout.
- **`--report` segfaulted when no pool was configured** (it read
  `pools.items[0]`). It now measures the machine without a pool.
- **The report file was never created if its directory did not exist.** The
  writer creates the parent directory once.
- **The usage text lost its indentation** around `--check`/`--bench` while the
  report flags were added; fixed along with the new entries.

- **`-u WALLET -o pool` failed with `InvalidPool`.** Per-pool options seen
  before the pool they belong to created an empty placeholder pool; they are
  now defaults for the pools that follow (`-p`, `--rig-id`, `--keepalive`,
  `--nicehash`, `--tls` too), and `-o a -o b -u W` gives both pools the wallet.
- **Ctrl-C could hang for minutes** on a pool that never answers the login: the
  monitor now owns the socket from the moment it is connected (not only after
  a successful login), a 1 s receive timeout lets the read loop see the stop
  flag, and a send timeout keeps thread joins bounded during a seed change.
- **`--http-port` was documented but nothing listened on it** (see above).
- **A pool sending one oversized line killed the session**; over-long lines are
  now skipped instead of ending the connection.
- **`--background` did nothing.** It now forks, detaches from the terminal and
  keeps mining (logging to `--log-file` if one was given), like XMRig.
- **Reconnects wasted `--retry-pause` seconds.** A dropped connection is
  retried in 200 ms and repeated failures back off 200 ms → 500 ms → 1 s →
  `--retry-pause`, instead of a fixed pause after every attempt (and instead of
  hammering a dead pool in bursts).
- **Log files contained ANSI colour escapes.** The file now gets plain lines;
  only a terminal gets colour.
- Login now advertises the `mo-native` and `submit-result` extensions for every
  algorithm, not only when a KAWPOW GPU algorithm is enabled (CPU-only builds
  never negotiated them before).
- Console logging no longer produces an empty log when stdout is redirected to a
  regular file (`xmrig > miner.log`, cron, some service managers).
- RandomX dataset allocation no longer logs a hard error when 1 GiB pages are
  requested but unavailable; it falls back silently in auto mode.

### Docs
- `doc/ARCHITECTURE.md`, `doc/PERFORMANCE.md`, `doc/ZERO_FEE.md`, new README.

# v6.26.0
- [#3769](https://github.com/xmrig/xmrig/pull/3769), [#3772](https://github.com/xmrig/xmrig/pull/3772), [#3774](https://github.com/xmrig/xmrig/pull/3774), [#3775](https://github.com/xmrig/xmrig/pull/3775), [#3776](https://github.com/xmrig/xmrig/pull/3776), [#3782](https://github.com/xmrig/xmrig/pull/3782), [#3783](https://github.com/xmrig/xmrig/pull/3783) **Added support for RandomX v2.**
- [#3746](https://github.com/xmrig/xmrig/pull/3746) RISC-V: vectorized RandomX main loop.
- [#3748](https://github.com/xmrig/xmrig/pull/3748) RISC-V: auto-detect and use vector code for all RandomX AES functions.
- [#3749](https://github.com/xmrig/xmrig/pull/3749) RISC-V: detect and use hardware AES.
- [#3750](https://github.com/xmrig/xmrig/pull/3750) RISC-V: use vector hardware AES instead of scalar.
- [#3757](https://github.com/xmrig/xmrig/pull/3757) RISC-V: Fixed scratchpad prefetch, removed an unnecessary instruction.
- [#3758](https://github.com/xmrig/xmrig/pull/3758) RandomX: added VAES-512 support for Zen5.
- [#3759](https://github.com/xmrig/xmrig/pull/3759) RandomX: Optimized VAES code.
- [#3762](https://github.com/xmrig/xmrig/pull/3762) Fixed keepalive timer logic.
- [#3778](https://github.com/xmrig/xmrig/pull/3778) RandomX: ARM64 fixes.
- [#3784](https://github.com/xmrig/xmrig/pull/3784) Fixed OpenCL address-space mismatch in `keccak_f800_round`.
- [#3785](https://github.com/xmrig/xmrig/pull/3785) Don't reset nonce during donation rounds.

# v6.25.0
- [#3680](https://github.com/xmrig/xmrig/pull/3680) Added `armv8l` to the list of 32-bit ARM targets.
- [#3708](https://github.com/xmrig/xmrig/pull/3708) Minor Aarch64 JIT changes (better instruction selection, don't emit instructions that add 0, etc).
- [#3718](https://github.com/xmrig/xmrig/pull/3718) Solo mining: added support for FCMP++ hardfork.
- [#3722](https://github.com/xmrig/xmrig/pull/3722) Added Zen4 (Hawk Point) CPUs detection.
- [#3725](https://github.com/xmrig/xmrig/pull/3725) Added **RISC-V** support with JIT compiler.
- [#3731](https://github.com/xmrig/xmrig/pull/3731) Added initial Haiku OS support.
- [#3733](https://github.com/xmrig/xmrig/pull/3733) Added detection for MSVC/2026.
- [#3736](https://github.com/xmrig/xmrig/pull/3736) RISC-V: added vectorized dataset init.
- [#3740](https://github.com/xmrig/xmrig/pull/3740) RISC-V: added vectorized soft AES.
- [#3743](https://github.com/xmrig/xmrig/pull/3743) Linux: added support for transparent huge pages.
- Improved LibreSSL support.
- Improved compatibility for automatically enabling huge pages on Linux systems without NUMA support.

# v6.24.0
- [#3671](https://github.com/xmrig/xmrig/pull/3671) Fixed detection of L2 cache size for some complex NUMA topologies.
- [#3674](https://github.com/xmrig/xmrig/pull/3674) Fixed ARMv7 build.
- [#3677](https://github.com/xmrig/xmrig/pull/3677) Fixed auto-config for AMD CPUs with less than 2 MB L3 cache per thread.
- [#3678](https://github.com/xmrig/xmrig/pull/3678) Improved IPv6 support: the new default settings use IPv6 equally with IPv4.

# v6.23.0
- [#3668](https://github.com/xmrig/xmrig/issues/3668) Added support for Windows ARM64.
- [#3665](https://github.com/xmrig/xmrig/pull/3665) Tweaked auto-config for AMD CPUs with < 2 MB L3 cache per thread.

# v6.22.3
- [#3605](https://github.com/xmrig/xmrig/pull/3605) CUDA backend: added missing RandomX dataset update.
- [#3646](https://github.com/xmrig/xmrig/pull/3646) Optimized auto-config for AMD CPUs with less than 2 MB L3 cache per thread.
- [#3652](https://github.com/xmrig/xmrig/pull/3652) Fixed possible crash when submitting RandomX benchmark.
- [#3662](https://github.com/xmrig/xmrig/pull/3662) Fixed OpenCL kernel compilation error on some platforms.

# v6.22.2
- [#3569](https://github.com/xmrig/xmrig/pull/3569) Fixed corrupted API output in some rare conditions.
- [#3571](https://github.com/xmrig/xmrig/pull/3571) Fixed number of threads on the new Intel Core Ultra CPUs.

# v6.22.1
- [#3531](https://github.com/xmrig/xmrig/pull/3531) Always reset nonce on RandomX dataset change.
- [#3534](https://github.com/xmrig/xmrig/pull/3534) Fixed threads auto-config on Zen5.
- [#3535](https://github.com/xmrig/xmrig/pull/3535) RandomX: tweaks for Zen5.
- [#3539](https://github.com/xmrig/xmrig/pull/3539) Added Zen5 to `randomx_boost.sh`.
- [#3540](https://github.com/xmrig/xmrig/pull/3540) Detect AMD engineering samples in `randomx_boost.sh`.

# v6.22.0
- [#2411](https://github.com/xmrig/xmrig/pull/2411) Added support for [Yada](https://yadacoin.io/) (`rx/yada` algorithm).
- [#3492](https://github.com/xmrig/xmrig/pull/3492) Fixed `--background` option on Unix systems.
- [#3518](https://github.com/xmrig/xmrig/pull/3518) Possible fix for corrupted API output in rare cases.
- [#3522](https://github.com/xmrig/xmrig/pull/3522) Removed `rx/keva` algorithm.
- [#3525](https://github.com/xmrig/xmrig/pull/3525) Added Zen5 detection.
- [#3528](https://github.com/xmrig/xmrig/pull/3528) Added `rx/yada` OpenCL support.

# v6.21.3
- [#3462](https://github.com/xmrig/xmrig/pull/3462) RandomX: correct memcpy size for JIT initialization.

# v6.21.2
- The dependencies of all prebuilt releases have been updated. Support for old Ubuntu releases has been dropped.
- [#2800](https://github.com/xmrig/xmrig/issues/2800) Fixed donation with GhostRider algorithm for builds without KawPow algorithm.
- [#3436](https://github.com/xmrig/xmrig/pull/3436) Fixed, the file log writer was not thread-safe.
- [#3450](https://github.com/xmrig/xmrig/pull/3450) Fixed RandomX crash when compiled with fortify_source.

# v6.21.1
- [#3391](https://github.com/xmrig/xmrig/pull/3391) Added support for townforge (monero fork using randomx).
- [#3399](https://github.com/xmrig/xmrig/pull/3399) Fixed Zephyr mining (OpenCL).
- [#3420](https://github.com/xmrig/xmrig/pull/3420) Fixed segfault in HTTP API rebind.

# v6.21.0
- [#3302](https://github.com/xmrig/xmrig/pull/3302) [#3312](https://github.com/xmrig/xmrig/pull/3312) Enabled keepalive for Windows (>= Vista).
- [#3320](https://github.com/xmrig/xmrig/pull/3320) Added "built for OS/architecture/bits" to "ABOUT".
- [#3339](https://github.com/xmrig/xmrig/pull/3339) Added SNI option for TLS connections.
- [#3342](https://github.com/xmrig/xmrig/pull/3342) Update `cn_main_loop.asm`.
- [#3346](https://github.com/xmrig/xmrig/pull/3346) ARM64 JIT: don't use `x18` register.
- [#3348](https://github.com/xmrig/xmrig/pull/3348) Update to latest `sse2neon.h`.
- [#3356](https://github.com/xmrig/xmrig/pull/3356) Updated pricing record size for **Zephyr** solo mining.
- [#3358](https://github.com/xmrig/xmrig/pull/3358) **Zephyr** solo mining: handle multiple outputs.

# v6.20.0
- Added new ARM CPU names.
- [#2394](https://github.com/xmrig/xmrig/pull/2394) Added new CMake options `ARM_V8` and `ARM_V7`.
- [#2830](https://github.com/xmrig/xmrig/pull/2830) Added API rebind polling.
- [#2927](https://github.com/xmrig/xmrig/pull/2927) Fixed compatibility with hwloc 1.11.x.
- [#3060](https://github.com/xmrig/xmrig/pull/3060) Added x86 to `README.md`.
- [#3236](https://github.com/xmrig/xmrig/pull/3236) Fixed: receive CUDA loader error on Linux too.
- [#3290](https://github.com/xmrig/xmrig/pull/3290) Added [Zephyr](https://www.zephyrprotocol.com/) coin support for solo mining.

# v6.19.3
- [#3245](https://github.com/xmrig/xmrig/issues/3245) Improved algorithm negotiation for donation rounds by sending extra information about current mining job.
- [#3254](https://github.com/xmrig/xmrig/pull/3254) Tweaked auto-tuning for Intel CPUs.
- [#3271](https://github.com/xmrig/xmrig/pull/3271) RandomX: optimized program generation.
- [#3273](https://github.com/xmrig/xmrig/pull/3273) RandomX: fixed undefined behavior.
- [#3275](https://github.com/xmrig/xmrig/pull/3275) RandomX: fixed `jccErratum` list.
- [#3280](https://github.com/xmrig/xmrig/pull/3280) Updated example scripts.

# v6.19.2
- [#3230](https://github.com/xmrig/xmrig/pull/3230) Fixed parsing of `TX_EXTRA_MERGE_MINING_TAG`.
- [#3232](https://github.com/xmrig/xmrig/pull/3232) Added new `X-Hash-Difficulty` HTTP header.
- [#3240](https://github.com/xmrig/xmrig/pull/3240) Improved .cmd files when run by shortcuts on another drive.
- [#3241](https://github.com/xmrig/xmrig/pull/3241) Added view tag calculation (fixes Wownero solo mining issue).

# v6.19.1
- Resolved deprecated methods warnings with OpenSSL 3.0.
- [#3213](https://github.com/xmrig/xmrig/pull/3213) Fixed build with 32-bit clang 15.
- [#3218](https://github.com/xmrig/xmrig/pull/3218) Fixed: `--randomx-wrmsr=-1` worked only on Intel.
- [#3228](https://github.com/xmrig/xmrig/pull/3228) Fixed build with gcc 13.

# v6.19.0
- [#3144](https://github.com/xmrig/xmrig/pull/3144) Update to latest `sse2neon.h`.
- [#3161](https://github.com/xmrig/xmrig/pull/3161) MSVC build: enabled parallel compilation.
- [#3163](https://github.com/xmrig/xmrig/pull/3163) Improved Zen 3 MSR mod.
- [#3176](https://github.com/xmrig/xmrig/pull/3176) Update cmake required version to 3.1.
- [#3182](https://github.com/xmrig/xmrig/pull/3182) DragonflyBSD compilation fixes.
- [#3196](https://github.com/xmrig/xmrig/pull/3196) Show IP address for failed connections.
- [#3185](https://github.com/xmrig/xmrig/issues/3185) Fixed macOS DMI reader.
- [#3198](https://github.com/xmrig/xmrig/pull/3198) Fixed broken RandomX light mode mining.
- [#3202](https://github.com/xmrig/xmrig/pull/3202) Solo mining: added job timeout (default is 15 seconds).

# v6.18.1
- [#3129](https://github.com/xmrig/xmrig/pull/3129) Fix: protectRX flushed CPU cache only on MacOS/iOS.
- [#3126](https://github.com/xmrig/xmrig/pull/3126) Don't reset when pool sends the same job blob.
- [#3120](https://github.com/xmrig/xmrig/pull/3120) RandomX: optimized `CFROUND` elimination.
- [#3109](https://github.com/xmrig/xmrig/pull/3109) RandomX: added Blake2 AVX2 version.
- [#3082](https://github.com/xmrig/xmrig/pull/3082) Fixed GCC 12 warnings.
- [#3075](https://github.com/xmrig/xmrig/pull/3075) Recognize `armv7ve` as valid ARMv7 target.
- [#3132](https://github.com/xmrig/xmrig/pull/3132) RandomX: added MSR mod for Zen 4.
- [#3134](https://github.com/xmrig/xmrig/pull/3134) Added Zen4 to `randomx_boost.sh`.

# v6.18.0
- [#3067](https://github.com/xmrig/xmrig/pull/3067) Monero v15 network upgrade support and more house keeping.
  - Removed deprecated AstroBWTv1 and v2.
  - Fixed debug GhostRider build.
  - Monero v15 network upgrade support.
  - Fixed ZMQ debug log.
  - Improved daemon ZMQ mining stability.
- [#3054](https://github.com/xmrig/xmrig/pull/3054) Fixes for 32-bit ARM.
- [#3042](https://github.com/xmrig/xmrig/pull/3042) Fixed being unable to resume from `pause-on-battery`.
- [#3031](https://github.com/xmrig/xmrig/pull/3031) Fixed `--cpu-priority` not working sometimes.
- [#3020](https://github.com/xmrig/xmrig/pull/3020) Removed old AstroBWT algorithm.

# v6.17.0
- [#2954](https://github.com/xmrig/xmrig/pull/2954) **Dero HE fork support (`astrobwt/v2` algorithm).**
  - [#2961](https://github.com/xmrig/xmrig/pull/2961) Dero HE (`astrobwt/v2`) CUDA config generator.
  - [#2969](https://github.com/xmrig/xmrig/pull/2969) Dero HE (`astrobwt/v2`) OpenCL support.
- Fixed displayed DMI memory information for empty slots.
- [#2932](https://github.com/xmrig/xmrig/pull/2932) Fixed GhostRider with hwloc disabled.

# v6.16.4
- [#2904](https://github.com/xmrig/xmrig/pull/2904) Fixed unaligned memory accesses.
- [#2908](https://github.com/xmrig/xmrig/pull/2908) Added MSVC/2022 to `version.h`.
- [#2910](https://github.com/xmrig/xmrig/issues/2910) Fixed donation for GhostRider/RTM.

# v6.16.3
- [#2778](https://github.com/xmrig/xmrig/pull/2778) Fixed `READY threads X/X` display after algorithm switching.
- [#2782](https://github.com/xmrig/xmrig/pull/2782) Updated GhostRider documentation.
- [#2815](https://github.com/xmrig/xmrig/pull/2815) Fixed `cn-heavy` in 32-bit builds.
- [#2827](https://github.com/xmrig/xmrig/pull/2827) GhostRider: set correct priority for helper threads.
- [#2837](https://github.com/xmrig/xmrig/pull/2837) RandomX: don't restart mining threads when the seed changes.
- [#2848](https://github.com/xmrig/xmrig/pull/2848) GhostRider: added support for `client.reconnect` method.
- [#2856](https://github.com/xmrig/xmrig/pull/2856) Fix for short responses from some Raptoreum pools.
- [#2873](https://github.com/xmrig/xmrig/pull/2873) Fixed GhostRider benchmark on single-core systems.
- [#2882](https://github.com/xmrig/xmrig/pull/2882) Fixed ARMv7 compilation.
- [#2893](https://github.com/xmrig/xmrig/pull/2893) KawPow OpenCL: use separate UV loop for building programs.

# v6.16.2
- [#2751](https://github.com/xmrig/xmrig/pull/2751) Fixed crash on CPUs supporting VAES and running GCC-compiled xmrig.
- [#2761](https://github.com/xmrig/xmrig/pull/2761) Fixed broken auto-tuning in GCC Windows build.
- [#2771](https://github.com/xmrig/xmrig/issues/2771) Fixed environment variables support for GhostRider and KawPow.
- [#2769](https://github.com/xmrig/xmrig/pull/2769) Performance fixes:
  - Fixed several performance bottlenecks introduced in v6.16.1.
  - Fixed overall GCC-compiled build performance, it's the same speed as MSVC build now.
  - **Linux builds are up to 10% faster now compared to v6.16.0 GCC build.**
  - **Windows builds are up to 5% faster now compared to v6.16.0 MSVC build.**

# v6.16.1
- [#2729](https://github.com/xmrig/xmrig/pull/2729) GhostRider fixes:
  - Added average hashrate display.
  - Fixed the number of threads shown at startup.
  - Fixed `--threads` or `-t` command line option (but `--cpu-max-threads-hint` is recommended to use).
- [#2738](https://github.com/xmrig/xmrig/pull/2738) GhostRider fixes:
  - Fixed "difficulty is not a number" error when diff is high on some pools.
  - Fixed GhostRider compilation when `WITH_KAWPOW=OFF`.
- [#2740](https://github.com/xmrig/xmrig/pull/2740) Added VAES support for Cryptonight variants **+4% speedup on Zen3**.
  - VAES instructions are available on Intel Ice Lake/AMD Zen3 and newer CPUs.
  - +4% speedup on Ryzen 5 5600X.

# v6.16.0
- [#2712](https://github.com/xmrig/xmrig/pull/2712) **GhostRider algorithm (Raptoreum) support**: read the [RELEASE NOTES](src/crypto/ghostrider/README.md) for quick start guide and performance comparisons.
- [#2682](https://github.com/xmrig/xmrig/pull/2682) Fixed: use cn-heavy optimization only for Vermeer CPUs.
- [#2684](https://github.com/xmrig/xmrig/pull/2684) MSR mod: fix for error 183.

# v6.15.3
- [#2614](https://github.com/xmrig/xmrig/pull/2614) OpenCL fixes for non-AMD platforms.
- [#2623](https://github.com/xmrig/xmrig/pull/2623) Fixed compiling without kawpow.
- [#2636](https://github.com/xmrig/xmrig/pull/2636) [#2639](https://github.com/xmrig/xmrig/pull/2639) AstroBWT speedup (up to +35%).
- [#2646](https://github.com/xmrig/xmrig/pull/2646) Fixed MSVC compilation error.

# v6.15.2
- [#2606](https://github.com/xmrig/xmrig/pull/2606) Fixed: AstroBWT auto-config ignored `max-threads-hint`.
- Fixed possible crash on Windows (regression in v6.15.1).

# v6.15.1
- [#2586](https://github.com/xmrig/xmrig/pull/2586) Fixed Windows 7 compatibility.
- [#2594](https://github.com/xmrig/xmrig/pull/2594) Added Windows taskbar icon colors.

# v6.15.0
- [#2548](https://github.com/xmrig/xmrig/pull/2548) Added automatic coin detection for daemon mining.
- [#2563](https://github.com/xmrig/xmrig/pull/2563) Added new algorithm RandomX Graft (`rx/graft`).
- [#2565](https://github.com/xmrig/xmrig/pull/2565) AstroBWT: added AVX2 Salsa20 implementation.
- Added support for new CUDA plugin API (previous API still supported).

# v6.14.1
- [#2532](https://github.com/xmrig/xmrig/pull/2532) Refactoring: stable (persistent) algorithms IDs.
- [#2537](https://github.com/xmrig/xmrig/pull/2537) Fixed Termux build.

# v6.14.0
- [#2484](https://github.com/xmrig/xmrig/pull/2484) Added ZeroMQ support for solo mining.
- [#2476](https://github.com/xmrig/xmrig/issues/2476) Fixed crash in DMI memory reader.
- [#2492](https://github.com/xmrig/xmrig/issues/2492) Added missing `--huge-pages-jit` command line option.
- [#2512](https://github.com/xmrig/xmrig/pull/2512) Added show the number of transactions in pool job.

# v6.13.1
- [#2468](https://github.com/xmrig/xmrig/pull/2468) Fixed regression in previous version: don't send miner signature during regular mining.

# v6.13.0
- [#2445](https://github.com/xmrig/xmrig/pull/2445) Added support for solo mining with miner signatures for the upcoming Wownero fork.

# v6.12.2
- [#2280](https://github.com/xmrig/xmrig/issues/2280) GPU backends are now disabled in benchmark mode.
- [#2322](https://github.com/xmrig/xmrig/pull/2322) Improved MSR compatibility with recent Linux kernels and updated `randomx_boost.sh`.
- [#2340](https://github.com/xmrig/xmrig/pull/2340) Fixed AES detection on FreeBSD on ARM.
- [#2341](https://github.com/xmrig/xmrig/pull/2341) `sse2neon` updated to the latest version.
- [#2351](https://github.com/xmrig/xmrig/issues/2351) Fixed help output for `--cpu-priority` and `--cpu-affinity` option.
- [#2375](https://github.com/xmrig/xmrig/pull/2375) Fixed macOS CUDA backend default loader name.
- [#2378](https://github.com/xmrig/xmrig/pull/2378) Fixed broken light mode mining on x86.
- [#2379](https://github.com/xmrig/xmrig/pull/2379) Fixed CL code for KawPow where it assumes everything is AMD.
- [#2386](https://github.com/xmrig/xmrig/pull/2386) RandomX: enabled `IMUL_RCP` optimization for light mode mining.
- [#2393](https://github.com/xmrig/xmrig/pull/2393) RandomX: added BMI2 version for scratchpad prefetch.
- [#2395](https://github.com/xmrig/xmrig/pull/2395) RandomX: rewrote dataset read code.
- [#2398](https://github.com/xmrig/xmrig/pull/2398) RandomX: optimized ARMv8 dataset read.
- Added `argon2/ninja` alias for `argon2/wrkz` algorithm.

# v6.12.1
- [#2296](https://github.com/xmrig/xmrig/pull/2296) Fixed Zen3 assembly code for `cn/upx2` algorithm.

# v6.12.0
- [#2276](https://github.com/xmrig/xmrig/pull/2276) Added support for Uplexa (`cn/upx2` algorithm).
- [#2261](https://github.com/xmrig/xmrig/pull/2261) Show total hashrate if compiled without OpenCL.
- [#2289](https://github.com/xmrig/xmrig/pull/2289) RandomX: optimized `IMUL_RCP` instruction.
- Added support for `--user` command line option for online benchmark.

# v6.11.2
- [#2207](https://github.com/xmrig/xmrig/issues/2207) Fixed regression in HTTP parser and llhttp updated to v5.1.0.

# v6.11.1
- [#2239](https://github.com/xmrig/xmrig/pull/2239) Fixed broken `coin` setting functionality.

# v6.11.0
- [#2196](https://github.com/xmrig/xmrig/pull/2196) Improved DNS subsystem and added new DNS specific options.
- [#2172](https://github.com/xmrig/xmrig/pull/2172) Fixed build on Alpine 3.13.
- [#2177](https://github.com/xmrig/xmrig/pull/2177) Fixed ARM specific compilation error with GCC 10.2.
- [#2214](https://github.com/xmrig/xmrig/pull/2214) [#2216](https://github.com/xmrig/xmrig/pull/2216) [#2235](https://github.com/xmrig/xmrig/pull/2235) Optimized `cn-heavy` algorithm.
- [#2217](https://github.com/xmrig/xmrig/pull/2217) Fixed mining job creation sequence.
- [#2225](https://github.com/xmrig/xmrig/pull/2225) Fixed build without OpenCL support on some systems.
- [#2229](https://github.com/xmrig/xmrig/pull/2229) Don't use RandomX JIT if `WITH_ASM=OFF`.
- [#2228](https://github.com/xmrig/xmrig/pull/2228) Removed useless code for cryptonight algorithms.
- [#2234](https://github.com/xmrig/xmrig/pull/2234) Fixed build error on gcc 4.8.

# v6.10.0
- [#2122](https://github.com/xmrig/xmrig/pull/2122) Fixed pause logic when both pause on battery and user activity are enabled.
- [#2123](https://github.com/xmrig/xmrig/issues/2123) Fixed compatibility with gcc 4.8.
- [#2147](https://github.com/xmrig/xmrig/pull/2147) Fixed many `new job` messages when solo mining.
- [#2150](https://github.com/xmrig/xmrig/pull/2150) Updated `sse2neon.h` to the latest master, fixes build on ARMv7.
- [#2157](https://github.com/xmrig/xmrig/pull/2157) Fixed crash in `cn-heavy` on Zen3 with manual thread count.
- Fixed possible out of order write to log file.
- [http-parser](https://github.com/nodejs/http-parser) replaced to [llhttp](https://github.com/nodejs/llhttp).
- For official builds: libuv, hwloc and OpenSSL updated to latest versions.

# v6.9.0
- [#2104](https://github.com/xmrig/xmrig/pull/2104) Added [pause-on-active](https://xmrig.com/docs/miner/config/misc#pause-on-active) config option and `--pause-on-active=N` command line option.
- [#2112](https://github.com/xmrig/xmrig/pull/2112) Added support for [Tari merge mining](https://github.com/tari-project/tari/blob/development/README.md#tari-merge-mining).
- [#2117](https://github.com/xmrig/xmrig/pull/2117) Fixed crash when GPU mining `cn-heavy` on Zen3 system.

# v6.8.2
- [#2080](https://github.com/xmrig/xmrig/pull/2080) Fixed compile error in Termux.
- [#2089](https://github.com/xmrig/xmrig/pull/2089) Optimized CryptoNight-Heavy for Zen3, 7-8% speedup.

# v6.8.1
- [#2064](https://github.com/xmrig/xmrig/pull/2064) Added documentation for config.json CPU options.
- [#2066](https://github.com/xmrig/xmrig/issues/2066) Fixed AMD GPUs health data readings on Linux.
- [#2067](https://github.com/xmrig/xmrig/pull/2067) Fixed compilation error when RandomX and Argon2 are disabled.
- [#2076](https://github.com/xmrig/xmrig/pull/2076) Added support for flexible huge page sizes on Linux.
- [#2077](https://github.com/xmrig/xmrig/pull/2077) Fixed `illegal instruction` crash on ARM.

# v6.8.0
- [#2052](https://github.com/xmrig/xmrig/pull/2052) Added DMI/SMBIOS reader.
  - Added information about memory modules on the miner startup and for online benchmark.
  - Added new HTTP API endpoint: `GET /2/dmi`.
  - Added new command line option `--no-dmi` or config option `"dmi"`.
  - Added new CMake option `-DWITH_DMI=OFF`.
- [#2057](https://github.com/xmrig/xmrig/pull/2057) Improved MSR subsystem code quality.
- [#2058](https://github.com/xmrig/xmrig/pull/2058) RandomX JIT x86: removed unnecessary instructions.

# v6.7.2
- [#2039](https://github.com/xmrig/xmrig/pull/2039) Fixed solo mining.

# v6.7.1
- [#1995](https://github.com/xmrig/xmrig/issues/1995) Fixed log initialization.
- [#1998](https://github.com/xmrig/xmrig/pull/1998) Added hashrate in the benchmark finished message.
- [#2009](https://github.com/xmrig/xmrig/pull/2009) AstroBWT OpenCL fixes.
- [#2028](https://github.com/xmrig/xmrig/pull/2028) RandomX x86 JIT: removed redundant `CFROUND`.

# v6.7.0
- **[#1991](https://github.com/xmrig/xmrig/issues/1991) Added Apple M1 processor support.**
- **[#1986](https://github.com/xmrig/xmrig/pull/1986) Up to 20-30% faster RandomX dataset initialization with AVX2 on some CPUs.**
- [#1964](https://github.com/xmrig/xmrig/pull/1964) Cleanup and refactoring.
- [#1966](https://github.com/xmrig/xmrig/pull/1966) Removed libcpuid support.
- [#1968](https://github.com/xmrig/xmrig/pull/1968) Added virtual machine detection.
- [#1969](https://github.com/xmrig/xmrig/pull/1969) [#1970](https://github.com/xmrig/xmrig/pull/1970) Fixed errors found by static analysis.
- [#1977](https://github.com/xmrig/xmrig/pull/1977) Fixed: secure JIT and huge pages are incompatible on Windows.
- [#1979](https://github.com/xmrig/xmrig/pull/1979) Term `x64` replaced to `64-bit`.
- [#1980](https://github.com/xmrig/xmrig/pull/1980) Fixed build on gcc 11.
- [#1989](https://github.com/xmrig/xmrig/pull/1989) Fixed broken Dero solo mining.

# v6.6.2
- [#1958](https://github.com/xmrig/xmrig/pull/1958) Added example mining scripts to help new miners.
- [#1959](https://github.com/xmrig/xmrig/pull/1959) Optimized JIT compiler.
- [#1960](https://github.com/xmrig/xmrig/pull/1960) Fixed RandomX init when switching to other algo and back.

# v6.6.1
- Fixed, benchmark validation on NUMA hardware produced incorrect results in some conditions.

# v6.6.0
- Online benchmark protocol upgraded to v2, validation not compatible with previous versions.
  - Single thread benchmark now is cheat-resistant, not possible speedup it with multiple threads.
  - RandomX dataset is now always initialized with static seed, to prevent time cheat by report slow dataset initialization.
  - Zero delay online submission, to make time validation much more precise and strict.
  - DNS cache for online benchmark to prevent unexpected delays.

# v6.5.3
- [#1946](https://github.com/xmrig/xmrig/pull/1946) Fixed MSR mod names in JSON API (v6.5.2 affected).

# v6.5.2
- [#1935](https://github.com/xmrig/xmrig/pull/1935) Separate MSR mod for Zen/Zen2 and Zen3.
- [#1937](https://github.com/xmrig/xmrig/issues/1937) Print path to existing WinRing0 service without verbose option.
- [#1939](https://github.com/xmrig/xmrig/pull/1939) Fixed build with gcc 4.8.
- [#1941](https://github.com/xmrig/xmrig/pull/1941) Added CPUID info to JSON report.
- [#1941](https://github.com/xmrig/xmrig/pull/1942) Fixed alignment modification in memory pool.
- [#1944](https://github.com/xmrig/xmrig/pull/1944) Updated `randomx_boost.sh` with new MSR mod.
- Added `250K` and `500K` offline benchmarks.

# v6.5.1
- [#1932](https://github.com/xmrig/xmrig/pull/1932) New MSR mod for Ryzen, up to +3.5% on Zen2 and +1-2% on Zen3.
- [#1918](https://github.com/xmrig/xmrig/issues/1918) Fixed 1GB huge pages support on ARMv8.
- [#1926](https://github.com/xmrig/xmrig/pull/1926) Fixed compilation on ARMv8 with GCC 9.3.0.
- [#1929](https://github.com/xmrig/xmrig/issues/1929) Fixed build without HTTP.

# v6.5.0
- **Added [online benchmark](https://xmrig.com/benchmark) mode for sharing results.**
  - Added new command line options: `--submit`, `	--verify=ID`, `	--seed=SEED`, `--hash=HASH`.
- [#1912](https://github.com/xmrig/xmrig/pull/1912) Fixed MSR kernel module warning with new Linux kernels.
- [#1925](https://github.com/xmrig/xmrig/pull/1925) Add checking for config files in user home directory.
- Added vendor to ARM CPUs name and added `"arch"` field to API.
- Removed legacy CUDA plugin API.

# v6.4.0
- [#1862](https://github.com/xmrig/xmrig/pull/1862) **RandomX: removed `rx/loki` algorithm.**
- [#1890](https://github.com/xmrig/xmrig/pull/1890) **Added `argon2/chukwav2` algorithm.**
- [#1895](https://github.com/xmrig/xmrig/pull/1895) [#1897](https://github.com/xmrig/xmrig/pull/1897) **Added [benchmark and stress test](https://github.com/xmrig/xmrig/blob/dev/doc/BENCHMARK.md).**
- [#1864](https://github.com/xmrig/xmrig/pull/1864) RandomX: improved software AES performance.
- [#1870](https://github.com/xmrig/xmrig/pull/1870) RandomX: fixed unexpected resume due to disconnect during dataset init.
- [#1872](https://github.com/xmrig/xmrig/pull/1872) RandomX: fixed `randomx_create_vm` call.
- [#1875](https://github.com/xmrig/xmrig/pull/1875) RandomX: fixed crash on x86.
- [#1876](https://github.com/xmrig/xmrig/pull/1876) RandomX: added `huge-pages-jit` config parameter.
- [#1881](https://github.com/xmrig/xmrig/pull/1881) Fixed possible race condition in hashrate counting code.
- [#1882](https://github.com/xmrig/xmrig/pull/1882) [#1886](https://github.com/xmrig/xmrig/pull/1886) [#1887](https://github.com/xmrig/xmrig/pull/1887) [#1893](https://github.com/xmrig/xmrig/pull/1893) General code improvements.
- [#1885](https://github.com/xmrig/xmrig/pull/1885) Added more precise hashrate calculation.
- [#1889](https://github.com/xmrig/xmrig/pull/1889) Fixed libuv performance issue on Linux.

# v6.3.5
- [#1845](https://github.com/xmrig/xmrig/pull/1845) [#1861](https://github.com/xmrig/xmrig/pull/1861) Fixed ARM build and added CMake option `WITH_SSE4_1`.
- [#1846](https://github.com/xmrig/xmrig/pull/1846) KawPow: fixed OpenCL memory leak.
- [#1849](https://github.com/xmrig/xmrig/pull/1849) [#1859](https://github.com/xmrig/xmrig/pull/1859) RandomX: optimized soft AES code.
- [#1850](https://github.com/xmrig/xmrig/pull/1850) [#1852](https://github.com/xmrig/xmrig/pull/1852) General code improvements.
- [#1853](https://github.com/xmrig/xmrig/issues/1853) [#1856](https://github.com/xmrig/xmrig/pull/1856) [#1857](https://github.com/xmrig/xmrig/pull/1857) Fixed crash on old CPUs.

# v6.3.4
- [#1823](https://github.com/xmrig/xmrig/pull/1823) RandomX: added new option `scratchpad_prefetch_mode`.
- [#1827](https://github.com/xmrig/xmrig/pull/1827) [#1831](https://github.com/xmrig/xmrig/pull/1831) Improved nonce iteration performance.
- [#1828](https://github.com/xmrig/xmrig/pull/1828) RandomX: added SSE4.1-optimized Blake2b.
- [#1830](https://github.com/xmrig/xmrig/pull/1830) RandomX: added performance profiler (for developers).
- [#1835](https://github.com/xmrig/xmrig/pull/1835) RandomX: returned old soft AES implementation and added auto-select between the two.
- [#1840](https://github.com/xmrig/xmrig/pull/1840) RandomX: moved more stuff to compile time, small x86 JIT compiler speedup.
- [#1841](https://github.com/xmrig/xmrig/pull/1841) Fixed Cryptonight OpenCL for AMD 20.7.2 drivers.
- [#1842](https://github.com/xmrig/xmrig/pull/1842) RandomX: AES improvements, a bit faster hardware AES code when compiled with MSVC.
- [#1843](https://github.com/xmrig/xmrig/pull/1843) RandomX: improved performance of GCC compiled binaries.

# v6.3.3
- [#1817](https://github.com/xmrig/xmrig/pull/1817) Fixed self-select login sequence.
- Added brand new [build from source](https://xmrig.com/docs/miner/build) documentation.
- New binary downloads for macOS (`macos-x64`), FreeBSD (`freebsd-static-x64`), Linux (`linux-static-x64`), Ubuntu 18.04 (`bionic-x64`), Ubuntu 20.04 (`focal-x64`).
- Generic Linux download `xenial-x64` renamed to `linux-x64`.
- Builds without SSL/TLS support are no longer provided.
- Improved CUDA loader error reporting and fixed plugin load on Linux.
- Fixed build warnings with Clang compiler.
- Fixed colors on macOS.

# v6.3.2
- [#1794](https://github.com/xmrig/xmrig/pull/1794) More robust 1 GB pages handling.
  - Don't allocate 1 GB per thread if 1 GB is the default huge page size.
  - Try to allocate scratchpad from dataset's 1 GB huge pages, if normal huge pages are not available.
  - Correctly initialize RandomX cache if 1 GB pages fail to allocate on a first NUMA node.
- [#1806](https://github.com/xmrig/xmrig/pull/1806) Fixed macOS battery detection.
- [#1809](https://github.com/xmrig/xmrig/issues/1809) Improved auto configuration on ARM CPUs.
  - Added retrieving ARM CPU names, based on lscpu code and database.

# v6.3.1
- [#1786](https://github.com/xmrig/xmrig/pull/1786) Added `pause-on-battery` option, supported on Windows and Linux.
- Added command line options `--randomx-cache-qos` and `--argon2-impl`.

# v6.3.0
- [#1771](https://github.com/xmrig/xmrig/pull/1771) Adopted new SSE2NEON and reduced ARM-specific changes.
- [#1774](https://github.com/xmrig/xmrig/pull/1774) RandomX: Added new option `cache_qos` in `randomx` object for cache QoS support.
- [#1777](https://github.com/xmrig/xmrig/pull/1777) Added support for upcoming Haven offshore fork.
  - [#1780](https://github.com/xmrig/xmrig/pull/1780) CryptoNight OpenCL: fix for long input data.

# v6.2.3
- [#1745](https://github.com/xmrig/xmrig/pull/1745) AstroBWT: fixed OpenCL compilation on some systems.
- [#1749](https://github.com/xmrig/xmrig/pull/1749) KawPow: optimized CPU share verification.
- [#1752](https://github.com/xmrig/xmrig/pull/1752) RandomX: added error message when MSR mod fails.
- [#1754](https://github.com/xmrig/xmrig/issues/1754) Fixed GPU health readings for pre Vega GPUs on Linux.
- [#1756](https://github.com/xmrig/xmrig/issues/1756) Added results and connection reports.
- [#1759](https://github.com/xmrig/xmrig/pull/1759) KawPow: fixed DAG initialization on slower AMD GPUs.
- [#1763](https://github.com/xmrig/xmrig/pull/1763) KawPow: fixed rare duplicate share errors.
- [#1766](https://github.com/xmrig/xmrig/pull/1766) RandomX: small speedup on Ryzen CPUs.

# v6.2.2
- [#1742](https://github.com/xmrig/xmrig/issues/1742) Fixed crash when use HTTP API.

# v6.2.1
- [#1726](https://github.com/xmrig/xmrig/issues/1726) Fixed detection of AVX2/AVX512.
- [#1728](https://github.com/xmrig/xmrig/issues/1728) Fixed, 32 bit Windows builds was crash on start.
- [#1729](https://github.com/xmrig/xmrig/pull/1729) Fixed KawPow crash on old CPUs.
- [#1730](https://github.com/xmrig/xmrig/pull/1730) Improved displaying information for compute errors on GPUs.
- [#1732](https://github.com/xmrig/xmrig/pull/1732) Fixed NiceHash disconnects for KawPow.
- Fixed AMD GPU health (temperatures/power/clocks/fans) readings on Linux.

# v6.2.0-beta
- [#1717](https://github.com/xmrig/xmrig/pull/1717) Added new algorithm `cn/ccx` for Conceal.
- [#1718](https://github.com/xmrig/xmrig/pull/1718) Fixed, linker on Linux was marking entire executable as having an executable stack.
- [#1720](https://github.com/xmrig/xmrig/pull/1720) Fixed broken CryptoNight algorithms family with gcc 10.1.

# v6.0.1-beta
- [#1708](https://github.com/xmrig/xmrig/issues/1708) Added `title` option.
- [#1711](https://github.com/xmrig/xmrig/pull/1711) [cuda] Print errors from KawPow DAG initialization.
- [#1713](https://github.com/xmrig/xmrig/pull/1713) [cuda] Reduced memory usage for KawPow, minimum CUDA plugin version now is 6.1.0.

# v6.0.0-beta
- [#1694](https://github.com/xmrig/xmrig/pull/1694) Added support for KawPow algorithm (Ravencoin) on AMD/NVIDIA.
- Removed previously deprecated `cn/gpu` algorithm.
- Default donation level reduced to 1% but you still can increase it if you like.

# v5.11.3
- [#1718](https://github.com/xmrig/xmrig/pull/1718) Fixed, linker on Linux was marking entire executable as having an executable stack.
- [#1720](https://github.com/xmrig/xmrig/pull/1720) Fixed broken CryptoNight algorithms family with gcc 10.1.

# v5.11.2
- [#1664](https://github.com/xmrig/xmrig/pull/1664) Improved JSON config error reporting.
- [#1668](https://github.com/xmrig/xmrig/pull/1668) Optimized RandomX dataset initialization.
- [#1675](https://github.com/xmrig/xmrig/pull/1675) Fixed cross-compiling on Linux.
- Fixed memory leak in HTTP client.
- Build [dependencies](https://github.com/xmrig/xmrig-deps/releases/tag/v4.1) updated to recent versions.
- Compiler for Windows gcc builds updated to v10.1.

# v5.11.1
- [#1652](https://github.com/xmrig/xmrig/pull/1652) Up to 1% RandomX performance improvement on recent AMD CPUs.
- [#1306](https://github.com/xmrig/xmrig/issues/1306) Fixed possible double connection to a pool.
- [#1654](https://github.com/xmrig/xmrig/issues/1654) Fixed build with LibreSSL.

# v5.11.0
- **[#1632](https://github.com/xmrig/xmrig/pull/1632) Added AstroBWT CUDA support ([CUDA plugin](https://github.com/xmrig/xmrig-cuda) v3.0.0 or newer required).**
- [#1605](https://github.com/xmrig/xmrig/pull/1605) Fixed AstroBWT OpenCL for NVIDIA GPUs.
- [#1635](https://github.com/xmrig/xmrig/pull/1635) Added pooled memory allocation of RandomX VMs (+0.5% speedup on Zen2).
- [#1641](https://github.com/xmrig/xmrig/pull/1641) RandomX JIT refactoring, smaller memory footprint and a bit faster overall.
- [#1643](https://github.com/xmrig/xmrig/issues/1643) Fixed build on CentOS 7.

# v5.10.0
- [#1602](https://github.com/xmrig/xmrig/pull/1602) Added AMD GPUs support for AstroBWT algorithm.
- [#1590](https://github.com/xmrig/xmrig/pull/1590) MSR mod automatically deactivated after switching from RandomX algorithms.
- [#1592](https://github.com/xmrig/xmrig/pull/1592) Added AVX2 optimized code for AstroBWT algorithm.
  - Added new config option `astrobwt-avx2` in `cpu` object and command line option `--astrobwt-avx2`.
- [#1596](https://github.com/xmrig/xmrig/issues/1596) Major TLS (Transport Layer Security) subsystem update.
  - Added new TLS options, please check [xmrig-proxy documentation](https://xmrig.com/docs/proxy/tls) for details.
- `cn/gpu` algorithm now disabled by default and will be removed in next major (v6.x.x) release, no ETA for it right now.
- Added command line option `--data-dir`.

# v5.9.0
- [#1578](https://github.com/xmrig/xmrig/pull/1578) Added new RandomKEVA algorithm for upcoming Kevacoin fork, as `"algo": "rx/keva"` or `"coin": "keva"`.
- [#1584](https://github.com/xmrig/xmrig/pull/1584) Fixed invalid AstroBWT hashes after algorithm switching.
- [#1585](https://github.com/xmrig/xmrig/issues/1585) Fixed build without HTTP support.
- Added command line option `--astrobwt-max-size`.

# v5.8.2
- [#1580](https://github.com/xmrig/xmrig/pull/1580) AstroBWT algorithm 20-50% speedup.
  - Added new option `astrobwt-max-size`.
- [#1581](https://github.com/xmrig/xmrig/issues/1581) Fixed macOS build.

# v5.8.1
- [#1575](https://github.com/xmrig/xmrig/pull/1575) Fixed new block detection for DERO solo mining.

# v5.8.0
- [#1573](https://github.com/xmrig/xmrig/pull/1573) Added new AstroBWT algorithm for upcoming DERO fork, as `"algo": "astrobwt"` or `"coin": "dero"`.

# v5.7.0
- **Added SOCKS5 proxies support for Tor https://xmrig.com/docs/miner/tor.**
- [#377](https://github.com/xmrig/xmrig-proxy/issues/377) Fixed duplicate jobs in daemon (solo) mining client.
- [#1560](https://github.com/xmrig/xmrig/pull/1560) RandomX 0.3-0.4% speedup depending on CPU.
- Fixed possible crashes in HTTP client.

# v5.6.0
- [#1536](https://github.com/xmrig/xmrig/pull/1536) Added workaround for new AMD GPU drivers.
- [#1546](https://github.com/xmrig/xmrig/pull/1546) Fixed generic OpenCL code for AMD Navi GPUs.
- [#1551](https://github.com/xmrig/xmrig/pull/1551) Added RandomX JIT for AMD Navi  GPUs.
- Added health information for AMD GPUs (clocks/power/fan/temperature) via ADL (Windows) and sysfs (Linux).
- Fixed possible nicehash nonce overflow in some conditions.
- Fixed wrong OpenCL platform on macOS, option `platform` now ignored on this OS.

# v5.5.3
- [#1529](https://github.com/xmrig/xmrig/pull/1529) Fixed crash on Bulldozer CPUs.

# v5.5.2
- [#1500](https://github.com/xmrig/xmrig/pull/1500) Removed unnecessary code from RandomX JIT compiler.
- [#1502](https://github.com/xmrig/xmrig/pull/1502) Optimizations for AMD Bulldozer.
- [#1508](https://github.com/xmrig/xmrig/pull/1508) Added support for BMI2 instructions.
- [#1510](https://github.com/xmrig/xmrig/pull/1510) Optimized `CFROUND` instruction for RandomX.
- [#1520](https://github.com/xmrig/xmrig/pull/1520) Fixed thread affinity.

# v5.5.1
- [#1469](https://github.com/xmrig/xmrig/issues/1469) Fixed build with gcc 4.8.
- [#1473](https://github.com/xmrig/xmrig/pull/1473) Added RandomX auto-config for mobile Ryzen APUs.
- [#1477](https://github.com/xmrig/xmrig/pull/1477) Fixed build with Clang.
- [#1489](https://github.com/xmrig/xmrig/pull/1489) RandomX JIT compiler tweaks.
- [#1493](https://github.com/xmrig/xmrig/pull/1493) Default value for Intel MSR preset changed to `15`.
- Fixed unwanted resume after RandomX dataset change.

# v5.5.0
- [#179](https://github.com/xmrig/xmrig/issues/179) Added support for [environment variables](https://xmrig.com/docs/miner/environment-variables) in config file.
- [#1445](https://github.com/xmrig/xmrig/pull/1445) Removed `rx/v` algorithm.
- [#1453](https://github.com/xmrig/xmrig/issues/1453) Fixed crash on 32bit systems.
- [#1459](https://github.com/xmrig/xmrig/issues/1459) Fixed crash on very low memory systems.
- [#1465](https://github.com/xmrig/xmrig/pull/1465) Added fix for 1st-gen Ryzen crashes.
- [#1466](https://github.com/xmrig/xmrig/pull/1466) Added `cn-pico/tlo` algorithm.
- Added `--randomx-no-rdmsr` command line option.
- Added console title for Windows with miner name and version.
- On Windows `priority` option now also change base priority.

# v5.4.0
- [#1434](https://github.com/xmrig/xmrig/pull/1434) Added RandomSFX (`rx/sfx`) algorithm for Safex Cash.
- [#1445](https://github.com/xmrig/xmrig/pull/1445) Added RandomV (`rx/v`) algorithm for *new* MoneroV.
- [#1419](https://github.com/xmrig/xmrig/issues/1419) Added reverting MSR changes on miner exit, use `"rdmsr": false,` in `"randomx"` object to disable this feature.
- [#1423](https://github.com/xmrig/xmrig/issues/1423) Fixed conflicts with exists WinRing0 driver service.
- [#1425](https://github.com/xmrig/xmrig/issues/1425) Fixed crash on first generation Zen CPUs (MSR mod accidentally enable Opcache), additionally now you can disable Opcache and enable MSR mod via config `"wrmsr": ["0xc0011020:0x0", "0xc0011021:0x60", "0xc0011022:0x510000", "0xc001102b:0x1808cc16"],`.
- Added advanced usage for `wrmsr` option, for example: `"wrmsr": ["0x1a4:0x6"],` (Intel) and `"wrmsr": ["0xc0011020:0x0", "0xc0011021:0x40:0xffffffffffffffdf", "0xc0011022:0x510000", "0xc001102b:0x1808cc16"],` (Ryzen).
- Added new config option `"verbose"` and command line option `--verbose`.

# v5.3.0
- [#1414](https://github.com/xmrig/xmrig/pull/1414) Added native MSR support for Windows, by using signed **WinRing0 driver** (© 2007-2009 OpenLibSys.org).
- Added new [MSR documentation](https://xmrig.com/docs/miner/randomx-optimization-guide/msr).
- [#1418](https://github.com/xmrig/xmrig/pull/1418) Increased stratum send buffer size.

# v5.2.1
- [#1408](https://github.com/xmrig/xmrig/pull/1408) Added RandomX boost script for Linux (if you don't like run miner with root privileges).
- Added support for [AMD Ryzen MSR registers](https://www.reddit.com/r/MoneroMining/comments/e962fu/9526_hs_on_ryzen_7_3700x_xmrig_520_1gb_pages_msr/) (Linux only).
- Fixed command line option `--randomx-wrmsr` option without parameters.

# v5.2.0
- **[#1388](https://github.com/xmrig/xmrig/pull/1388) Added [1GB huge pages support](https://xmrig.com/docs/miner/hugepages#onegb-huge-pages) for Linux.**
  - Added new option `1gb-pages` in `randomx` object with command line equivalent `--randomx-1gb-pages`.
  - Added automatic huge pages configuration on Linux if use the miner with root privileges.
- **Added [automatic Intel prefetchers configuration](https://xmrig.com/docs/miner/randomx-optimization-guide#intel-specific-optimizations) on Linux.**
   - Added new option `wrmsr` in `randomx` object with command line equivalent `--randomx-wrmsr=6`.
- [#1396](https://github.com/xmrig/xmrig/pull/1396) [#1401](https://github.com/xmrig/xmrig/pull/1401) New performance optimizations for Ryzen CPUs.
- [#1385](https://github.com/xmrig/xmrig/issues/1385) Added `max-threads-hint` option support for RandomX dataset initialization threads.
- [#1386](https://github.com/xmrig/xmrig/issues/1386) Added `priority` option support for RandomX dataset initialization threads.
- For official builds all dependencies (libuv, hwloc, openssl) updated to recent versions.
- Windows `msvc` builds now use Visual Studio 2019 instead of 2017.

# v5.1.1
- [#1365](https://github.com/xmrig/xmrig/issues/1365) Fixed various system response/stability issues.
  - Added new CPU option `yield` and command line equivalent `--cpu-no-yield`.
- [#1363](https://github.com/xmrig/xmrig/issues/1363) Fixed wrong priority of main miner thread.

# v5.1.0
- [#1351](https://github.com/xmrig/xmrig/pull/1351) RandomX optimizations and fixes.
  - Improved RandomX performance (up to +6-7% on Intel CPUs, +2-3% on Ryzen CPUs)
  - Added workaround for Intel JCC erratum bug see https://www.phoronix.com/scan.php?page=article&item=intel-jcc-microcode&num=1 for details.
  - Note! Always disable "Hardware prefetcher" and "Adjacent cacheline prefetch" in BIOS for Intel CPUs to get the optimal RandomX performance.
- [#1307](https://github.com/xmrig/xmrig/issues/1307) Fixed mining resume after donation round for pools with `self-select` feature.
- [#1318](https://github.com/xmrig/xmrig/issues/1318#issuecomment-559676080) Added option `"mode"` (or `--randomx-mode`) for RandomX.
  - Added memory information on miner startup.
  - Added `resources` field to summary API with memory information and load average.

# v5.0.1
- [#1234](https://github.com/xmrig/xmrig/issues/1234) Fixed compatibility with some AMD GPUs.
- [#1284](https://github.com/xmrig/xmrig/issues/1284) Fixed build without RandomX.
- [#1285](https://github.com/xmrig/xmrig/issues/1285) Added command line options `--cuda-bfactor-hint` and `--cuda-bsleep-hint`.
- [#1290](https://github.com/xmrig/xmrig/pull/1290) Fixed 32-bit ARM compilation.

# v5.0.0
This version is first stable unified 3 in 1 GPU+CPU release, OpenCL support built in in miner and not require additional external dependencies on compile time, NVIDIA CUDA available as external [CUDA plugin](https://github.com/xmrig/xmrig-cuda), for convenient, 3 in 1 downloads with recent CUDA version also provided.

This release based on 4.x.x series and include all features from v4.6.2-beta, changelog below include only the most important changes, [full changelog](doc/CHANGELOG_OLD.md) available separately.

- [#1272](https://github.com/xmrig/xmrig/pull/1272) Optimized hashrate calculation.
- [#1263](https://github.com/xmrig/xmrig/pull/1263) Added new option `dataset_host` for NVIDIA GPUs with less than 4 GB memory (RandomX only).
- [#1068](https://github.com/xmrig/xmrig/pull/1068) Added support for `self-select` stratum protocol extension.
- [#1227](https://github.com/xmrig/xmrig/pull/1227) Added new algorithm `rx/arq`, RandomX variant for upcoming ArQmA fork.
- [#808](https://github.com/xmrig/xmrig/issues/808#issuecomment-539297156) Added experimental support for persistent memory for CPU mining threads.
- [#1221](https://github.com/xmrig/xmrig/issues/1221) Improved RandomX dataset memory usage and initialization speed for NUMA machines.
- [#1175](https://github.com/xmrig/xmrig/issues/1175) Fixed support for systems where total count of NUMA nodes not equal usable nodes count.
- Added config option `cpu/max-threads-hint` and command line option `--cpu-max-threads-hint`.
- [#1185](https://github.com/xmrig/xmrig/pull/1185) Added JIT compiler for RandomX on ARMv8.
- Improved API endpoint `GET /2/backends` and added support for this endpoint to [workers.xmrig.info](http://workers.xmrig.info).
- Added command line option `--no-cpu` to disable CPU backend.
- Added OpenCL specific command line options: `--opencl`, `--opencl-devices`, `--opencl-platform`, `--opencl-loader` and `--opencl-no-cache`.
- Added CUDA specific command line options: `--cuda`, `--cuda-loader` and `--no-nvml`.
- Removed command line option `--http-enabled`, HTTP API enabled automatically if any other `--http-*` option provided.
- [#1172](https://github.com/xmrig/xmrig/issues/1172) **Added OpenCL mining backend.**
  - [#268](https://github.com/xmrig/xmrig-amd/pull/268) [#270](https://github.com/xmrig/xmrig-amd/pull/270) [#271](https://github.com/xmrig/xmrig-amd/pull/271) [#273](https://github.com/xmrig/xmrig-amd/pull/273) [#274](https://github.com/xmrig/xmrig-amd/pull/274) [#1171](https://github.com/xmrig/xmrig/pull/1171) Added RandomX support for OpenCL, thanks [@SChernykh](https://github.com/SChernykh).
- Algorithm `cn/wow` removed, as no longer alive.

# Previous versions
[doc/CHANGELOG_OLD.md](doc/CHANGELOG_OLD.md)

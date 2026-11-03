---
title: Install in one command
description: Install ZMRIG with one command and a wallet address. What the installer decides on its own, what it prints, and how to check that it worked.
image: https://molik-labs.github.io/ZMRIG/img/og-en.png
---

# Install in one command

```bash
curl -fsSL https://raw.githubusercontent.com/MoLik-Labs/ZMRIG/BETA/oneclick.sh \
  | sudo bash -s -- --wallet 4YourMoneroAddress
```

If the repository is already cloned:

```bash
sudo ./oneclick.sh --wallet 4YourMoneroAddress
```

That is the whole install. It installs the build dependencies, compiles the hash
engine and the miner, measures the machine to pick a thread count, tunes the
host, writes `/etc/zmrig/config.json`, creates `zmrig.service`, runs a
self-check, and prints the hashrate it measured. Re-running is safe: no duplicate
services, no overwritten config without `--force`, no rebuild when the binary is
newer than the sources.

## What it decides, and why

| Decision | How the installer chooses |
| --- | --- |
| Engine | `zmrig` (1 % of Monero time, `--donate-level=0` to remove it). It advertises the whole RandomX family, so a switching pool can still move the rig to whichever coin pays best. `--algo` outside RandomX, or `--engine=xmrig`, selects the C++ engine, which takes nothing. |
| Profile | `free` (maximum hashrate) everywhere, except a laptop on battery → `watt` (maximum hashes per watt). |
| Threads | Measured after the build: each candidate runs 8 s on the real dataset, the winner is written to the config. |
| Huge pages | Sized from the dataset. If the kernel grants fewer, it falls back to transparent huge pages and says so. |
| Governor | `performance` for `free`, the existing powersave governor for `watt`. |

See the same list without touching the machine:

```bash
./oneclick.sh plan
```

```text
==> plan
    engine         zmrig  (RandomX family, 1% dev fee)
    pool           gulf.moneroocean.stream:10001
    algo           auto  (RandomX family: rx/0, rx/wow, rx/arq, …)
    profile        free  (auto: no battery, electricity is treated as free)
    mode           auto (fast when RAM allows)
    huge pages     none yet, the installer reserves what the dataset needs
    autotune       8 s per candidate, winner written to config.json
    service        zmrig.service (systemd)
```

## Verify it worked

```bash
sudo ./oneclick.sh status      # service, hashrate 10s/60s/15m, shares, huge pages
sudo ./oneclick.sh verify      # self-test + developer-fee audit
sudo ./oneclick.sh logs 50     # last 50 log lines
```

```text
==> verifying zmrig
    OK  PASS rx/0 reference vector
    OK  PASS pipelined hashing
    OK  PASS full-memory dataset matches the cache
    OK  fee audit: one wallet, Monero only, switchable off
    OK  verified
```

`status` only reports measured numbers: a miner that started a moment ago says
`warming up` instead of quoting the previous run, because the dataset takes
15–25 seconds to build.

## The two power profiles

```bash
# free electricity: café, school, an office machine — maximum hashrate
sudo ./oneclick.sh install --wallet 4YourMoneroAddress --profile free

# every watt costs money: laptop, metered VPS — maximum hashes per watt
sudo ./oneclick.sh install --wallet 4YourMoneroAddress --profile watt
```

`free` uses every logical CPU, `--mode fast`, huge pages and `--priority 5`.
`watt` drops to one thread per physical core (SMT adds 5–15 % hashrate for
30–40 % more power), does not pin the CPU to its highest clock, and stops by
itself when a laptop switches to battery.

## Update, remove

```bash
sudo ./oneclick.sh update        # git pull, rebuild, restart
sudo ./oneclick.sh uninstall     # stop, remove service and binary, keep the config
sudo ./oneclick.sh purge --dry-run
sudo ./oneclick.sh purge         # remove everything the tool created
```

`purge` prints every path it created with its size, requires the word `purge`
to confirm, resets `vm.nr_hugepages` to 0, and never touches a file it did not
make. `--dry-run` lists without deleting.

## If something is wrong

- **No huge pages.** In a container or an OpenVZ VPS the kernel may refuse; the
  miner logs the shortfall and continues at roughly 78 % hashrate. Nothing to
  fix — ask the host for 2 MiB pages.
- **Service restarts in a loop.** Almost always a config the miner rejects. Run
  `sudo journalctl -u zmrig -n 60` and look for the first line after the binary
  starts; the installer validates the config before writing it, so this usually
  means someone edited it.
- **`the miner rejected the generated config`.** The wallet contains a character
  that is not valid base58. Re-run with a clean address.

The rest of the failure modes are in
[Troubleshooting](/docs/operate/troubleshooting).

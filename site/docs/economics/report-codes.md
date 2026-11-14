---
title: Report codes
description: The ZMRIG1. format — what a machine measures, how to decode a code yourself, and why it contains no wallet or token.
image: https://molik-labs.github.io/ZMRIG/img/og-en.png
---

# Report codes

A report code is how a machine describes itself without a server: one line of
text, printable on a console, pasteable into chat, readable in a browser.

```bash
sudo ./oneclick.sh report --power 45
ZMRIG1.eyJ2IjoxLCJpZCI6InZwc…
```

```bash
# while mining: keep the file fresh
zmrig --report-file /var/lib/zmrig/report.txt --report-interval 60
sudo cat /var/lib/zmrig/report.txt
```

## Format

`ZMRIG1.` followed by base64url of a compact JSON object. Version 1 of the
format:

```json
{
  "v": 1,
  "id": "vps-sg-02",
  "ver": "6.32.1",
  "cpu": "AMD EPYC 7B13 64-Core Processor",
  "arch": "x86_64",
  "cores": 32,
  "thr": 2,
  "algo": "rx/0",
  "mode": "fast",
  "hs": [1461.2, 1470.5, 1466.1, 1478.9],
  "hp": [1168, 1168],
  "shares": [806, 0, 0],
  "hash": 881234012,
  "up": 86400,
  "pw": 22,
  "pwsrc": "rapl",
  "hw": 66.8,
  "tmax": 72,
  "tc": 68.5,
  "at": 7,
  "health": "ok",
  "pool": "gulf.moneroocean.stream:10001",
  "ts": 1793412000
}
```

| Field | Meaning |
| --- | --- |
| `hs` | hashrate over 10 s, 60 s, 15 min, session best (H/s) |
| `hp` | huge pages granted, needed |
| `shares` | accepted, rejected, failed |
| `hash` | total hashes computed |
| `up` | uptime in seconds |
| `pw`, `pwsrc` | watts, and the source: `rapl`, `hwmon`, `user`, `none` |
| `hw` | hashes per watt, when power is known, else `null` |
| `tmax` | the `--max-temp` target, or `null` when no thermal policy is armed |
| `tc` | the temperature the governor last acted on, or `null` |
| `at` | threads currently allowed to hash — below `thr` while it is throttling |
| `health` | the miner's view of its own income: `ok`, `warming`, `degraded`, `stalled`, `rejected` |

`at` below `thr` is the one field a fleet dashboard cannot derive from
hashrate: a throttled rig and a healthy rig at half load look identical from the
pool side, and only one of them has a bearing on its way out.

Nothing else is in it. **No wallet address, no pool password, no public IP, no
hostname** beyond the worker name you chose yourself.

## Decode it yourself

```bash
cut -d. -f2 report.txt | tr '_-' '/+' | base64 -d | python3 -m json.tool
```

Or in a browser console:

```js
JSON.parse(atob("eyJ2Ijox…".replace(/-/g, "+").replace(/_/g, "/")))
```

You should not have to trust a decoder on a website to read a number your own
machine produced. The calculator on this site decodes locally and sends nothing,
but the two lines above are the whole trick.

## Choosing the hashrate window

`--report` measures a 10 s warm-up plus a window of `--report-time` seconds
(15 by default), then reports the **stable** hashrate rather than the average
since startup: an average would include the dataset build and come out 20–25 %
low.

In the calculator you pick the window:

| Window | Use it for |
| --- | --- |
| 10 s | the current state of the machine |
| 60 s | the default; smooths brief dips |
| 15 min | a thermal-throttled or shared host |
| session best | what the machine can do when nothing else is running |

Comparing machines on different windows is the fastest way to draw a wrong
conclusion about a CPU.

## A fleet

1. Give each machine a distinct `--report-id`.
2. Let the miner keep writing its report file.
3. Collect the lines and paste them into the
   [calculator](/docs/economics/profitability) one per line — or as raw JSON, if
   you keep your own inventory.

Codes survive copy-paste: the alphabet is base64url, so no line breaks, spaces or
shell quoting are needed.

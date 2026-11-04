# Donations

The Zig miner already takes 3 % of Monero time as a fee (`doc/FEE.md`); the
C++ engine takes nothing (`doc/ZERO_FEE.md`). This page exists for the people
who want to send something on top of that anyway. The address below is the same
one the fee pays, it is published in exactly two places (here and
`zmrig/src/fee.zig`), and no donation of yours is required for anything to
work.

## The address

```
46SQLW7DXaq6GJaQbHUFMAhd1VYpfQFJQ2gfZo9TCB8bf9vnf1MUwAD2Fwj6KMsY4RU3oKA3x6hByg8BKg7FfMWn6ysb5tJ
```

<p align="center">
  <img src="donate/monero.png" width="190" alt="QR code for the Monero donation address 46SQLW7D…n6ysb5tJ">
</p>

* **Asset:** Monero (XMR) only. Do not send BTC, ETH, USDT or anything wrapped;
  they would be lost.
* **Format:** standard mainnet address, 95 characters, network byte `18`
  (not an integrated address, not a subaddress).
* **Same wallet as the pool fee.** `pool/src/operator.js` decodes to exactly
  this address, and every running pool instance publishes it at `/api/config`
  and on its status page. One wallet, one audit trail.
* **QR:** `doc/donate/monero.png` encodes the plain address — no `monero:` URI,
  no amount, no payment id — so every wallet scans it correctly. It was decoded
  back to the text above with OpenCV before it was committed.

## Check it before you send

Do not trust the string because it is on GitHub; verify it. Two checks cover
everything a donor can get wrong.

**1. Length and shape.** 95 characters, starts with `46SQLW7D`, ends with
`n6ysb5tJ`.

```bash
grep -oE '\b4[1-9A-HJ-NP-Za-km-z]{94}\b' doc/DONATE.md | sort -u | wc -l   # expect 1
```

**2. Base58 checksum.** Monero encodes the 69-byte address body with the
CryptoNote block-wise base58 alphabet and appends a 4-byte Keccak-256 checksum.
This script decodes the address above and re-computes it:

```python
import sys
from Crypto.Hash import keccak          # pip install pycryptodome

ALPHABET = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
ADDRESS = '46SQLW7DXaq6GJaQbHUFMAhd1VYpfQFJQ2gfZo9TCB8bf9vnf1MUwAD2Fwj6KMsY4RU3oKA3x6hByg8BKg7FfMWn6ysb5tJ'

def decode_block(text, size):
    value = 0
    for char in text:
        value = value * 58 + ALPHABET.index(char)
    return value.to_bytes(size, 'big')

raw = b''
for offset in range(0, len(ADDRESS), 11):
    group = ADDRESS[offset:offset + 11]
    raw += decode_block(group, 8) if len(group) == 11 else decode_block(group, 5)

body, checksum = raw[:-4], raw[-4:]
digest = keccak.new(digest_bits=256, data=body).digest()[:4]

print('bytes    ', len(raw))            # 69
print('network  ', body[0])             # 18 = mainnet, standard
print('checksum ', 'OK' if digest == checksum else 'BAD')
sys.exit(0 if digest == checksum else 1)
```

A wrong checksum means a typo, a truncated copy or an address that was never a
Monero address at all — the wallet would refuse it, but check before, not after.

The QR can be checked independently:

```python
import cv2                              # pip install opencv-python-headless
print(cv2.QRCodeDetector().detectAndDecode(cv2.imread('doc/donate/monero.png'))[0])
```

## What a donation does not buy

* **No effect on the miner.** The address is not in `src/`, `zmrig/`, `pool/` or
  `oneclick.sh`. Nothing parses this page at build or run time, so
  `sudo ./oneclick.sh verify` reports the fee the binary actually takes,
  whether this page exists or not.
* **No supporter edition.** There is one binary, and it mines at full speed for
  everybody. Anyone selling a "faster build" is not us.
* **No priority support, no roadmap vote, no badge.** Issues are answered in the
  order they arrive and by how reproducible they are.
* **No subscription.** There is nothing recurring to cancel, and no invoice to
  ignore.

## What helps more than a transfer

1. **Mine to the pool** — the 3 % fee is what funds the work, and it only exists
   while somebody is mining.
2. **Send a measurement.** `zmrig/tests/ab.sh` compares two knobs on the same
   machine; a before/after table settles arguments that opinions do not.
3. **Report a bug** with the command, the full output and the hardware. Light
   mode on a 2 GiB VPS and MSR reads on bare metal are the two areas where a
   report is worth the most.
4. **Send a patch** — pool share accounting, the Zig frontend and `doc/` typos
   are all fair game.

## If you find another address

This project has published exactly one: the string at the top of this page.
Addresses in forks, issues, pull requests, videos, chat messages or "official
mirror" sites are not ours. When in doubt, compare against this file in the
repository history (`git log -p doc/DONATE.md`), not against a screenshot.

## Privacy

Donations are public on the Monero chain by design. Nothing else is collected:
the miner sends no telemetry, the site has no analytics, and the pool holds no
account for a donor. If you would rather stay anonymous, do not include a
payment ID and do not send from an address that is linked to you elsewhere.

---
title: Support and donations
description: Where to send a Monero donation, how to verify the address before sending, what a donation does not buy, and what helps the project more.
image: https://molik-labs.github.io/ZMRIG/img/og-en.png
---

# Support and donations

The Zig miner already takes 1 % of Monero time as a fee
([what that costs](/docs/reference/fee)); the C++ engine takes nothing. This
page exists for the people who want to send something on top of that anyway.
Nothing in the software reads the address below.

## The address

```text
46SQLW7DXaq6GJaQbHUFMAhd1VYpfQFJQ2gfZo9TCB8bf9vnf1MUwAD2Fwj6KMsY4RU3oKA3x6hByg8BKg7FfMWn6ysb5tJ
```

<img src="/img/donate-monero.png" width="190" alt="QR code for the Monero donation address 46SQLW7D…n6ysb5tJ" />

- **Monero (XMR) only.** Anything else — BTC, ETH, USDT, wrapped tokens — is
  lost, and no one can recover it.
- **A standard mainnet address**, 95 characters, network byte `18`. Not an
  integrated address, not a subaddress.
- **The same wallet as the pool fee.** `pool/src/operator.js` decodes to this
  exact address, and every pool instance publishes it at `/api/config` and on its
  status page. One wallet, one audit trail.

## Check it before you send

Do not trust a string because it is on GitHub. The address starts with
`46SQLW7D` and ends with `n6ysb5tJ`; a Monero address is base58 with a 4-byte
Keccak-256 checksum, so a typo cannot survive a decode.

```python
from Crypto.Hash import keccak              # pip install pycryptodome

ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
ADDRESS = "46SQLW7DXaq6GJaQbHUFMAhd1VYpfQFJQ2gfZo9TCB8bf9vnf1MUwAD2Fwj6KMsY4RU3oKA3x6hByg8BKg7FfMWn6ysb5tJ"

def decode_block(text, size):
    value = 0
    for char in text:
        value = value * 58 + ALPHABET.index(char)
    return value.to_bytes(size, "big")

raw = b""
for offset in range(0, len(ADDRESS), 11):
    group = ADDRESS[offset:offset + 11]
    raw += decode_block(group, 8) if len(group) == 11 else decode_block(group, 5)

body, checksum = raw[:-4], raw[-4:]
digest = keccak.new(digest_bits=256, data=body).digest()[:4]
print(len(raw), body[0], "OK" if digest == checksum else "BAD")
# 69 18 OK
```

A bad checksum means a typo, a truncated copy, or something that was never a
Monero address.

## What a donation does not buy

- **No effect on the miner.** Nothing parses this page at build or run time, and
  `sudo ./oneclick.sh verify` reports whichever fee the binary really takes,
  published address or not.
- **No supporter edition.** There is one binary and it mines at full speed for
  everybody. Anyone selling a "faster build" is not this project.
- **No priority support, roadmap vote or badge.** Issues are answered in the
  order they arrive and by how reproducible they are.
- **No subscription.** There is nothing recurring to cancel.

## What helps more than a transfer

1. **Mine to the pool.** The 1 % fee is what funds the work, and it only exists
   while somebody is mining.
2. **Send a measurement.** `zmrig/tests/ab.sh` compares two settings on the same
   machine; a before/after table settles arguments that opinions do not.
3. **Report a bug** with the command, the full output and the hardware. Light
   mode on a 2 GiB VPS and MSR reads on bare metal are where a report is worth
   the most.
4. **Send a patch.** Pool share accounting, the Zig front end and `doc/` typos
   are all fair game.

## If you find another address

This project has published exactly one, the string above. Addresses in forks,
issues, pull requests, videos, chat messages or "official mirror" sites are not
ours. Compare against `doc/DONATE.md` in the repository history
(`git log -p doc/DONATE.md`), not against a screenshot.

## Privacy

Donations are public on the Monero chain by design. Nothing else is collected:
the miner sends no telemetry, the site has no analytics, and the pool keeps no
account for a donor. To stay unlinked, send without a payment ID and from an
address you have not used elsewhere.

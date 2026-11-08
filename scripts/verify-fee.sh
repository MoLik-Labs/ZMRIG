#!/usr/bin/env bash
#
# verify-fee.sh - audit the developer fee of the Zig miner.
#
#   ./scripts/verify-fee.sh                     # needs zmrig/out/zmrig
#   ./scripts/verify-fee.sh --binary PATH       # audit an installed binary
#   ./scripts/verify-fee.sh --source-only       # constants only, no binary
#
# What this proves, and why each check exists:
#
#   1. the rate is the documented one and one address exists in the binary --
#      a fee that can be edited without anyone noticing is not a policy;
#   2. `--check` prints the rate, the address and the cadence -- so the operator
#      sees it before the first hash, not after the first payout;
#   3. `--donate-level=0` and `--no-donate` print `off` -- a fee that cannot be
#      switched off is not a fee, it is a tax;
#   4. no second donation host, relay or wallet string in the binary -- the fee
#      must go to the pool the user configured;
#   5. the fee is Monero-only in the source -- an address on another network
#      would burn the coins.
#
# Exit code 0 means: every line below is what the code says it is.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${0}")/.." && pwd)
BINARY="${ROOT}/zmrig/out/zmrig"
SOURCE_ONLY=0
FAILED=0

EXPECTED_PERCENT=3
EXPECTED_WALLET="46SQLW7DXaq6GJaQbHUFMAhd1VYpfQFJQ2gfZo9TCB8bf9vnf1MUwAD2Fwj6KMsY4RU3oKA3x6hByg8BKg7FfMWn6ysb5tJ"

color() { if [ -t 1 ]; then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi; }
pass() { printf ' %s %s\n' "$(color '1;32' 'PASS')" "$*"; }
fail() { printf ' %s %s\n' "$(color '1;31' 'FAIL')" "$*"; FAILED=1; }
info() { printf ' %s %s\n' "$(color '1;36' '*')" "$*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --source-only) SOURCE_ONLY=1 ;;
        --binary) BINARY="${2:?}"; shift ;;
        --binary=*) BINARY="${1#*=}" ;;
        -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'unknown option: %s\n' "$1"; exit 2 ;;
    esac
    shift
done

info "source audit"

# 1. The rate in the code is the rate on the site and in the installer.
percent=$(grep -E '^pub const default_percent' "${ROOT}/zmrig/src/fee.zig" | sed 's/.*= *//; s/;.*//' | grep -oE '^[0-9]+')
if [ "${percent:-x}" = "${EXPECTED_PERCENT}" ]; then
    pass "default_percent = ${percent} (as documented)"
else
    fail "default_percent = ${percent:-?} (documented: ${EXPECTED_PERCENT})"
fi

# 1b. The prose says the same number as the code. A fee change that updates the
#     constant and forgets the page is exactly how a published rate and a shipped
#     rate drift apart, so it is a build failure rather than a review note.
prose_mismatch=0
for page in \
    "${ROOT}/doc/FEE.md" \
    "${ROOT}/site/docs/reference/fee.md" \
    "${ROOT}/site/i18n/vi/docusaurus-plugin-content-docs/current/reference/fee.md" \
    "${ROOT}/README.md"; do
    [ -f "$page" ] || continue
    if ! grep -qE "(\*\*)?${EXPECTED_PERCENT}( ?|,)(%|%)" "$page"; then
        fail "$(basename "$page") never states ${EXPECTED_PERCENT} %"
        prose_mismatch=1
    fi
done
[ "$prose_mismatch" = "0" ] && pass "the pages state the same rate as the constant"

# 1b2. The site's own title and footer, which are not pages and have no prose to
#      review: the tab title said "1 % developer fee" for a whole release after the
#      constant moved to 3, because nothing was looking at the config.
cfg="${ROOT}/site/docusaurus.config.js"
if [ -f "$cfg" ]; then
    stale=$(grep -oE '[0-9]+([.][0-9]+)? ?% (developer )?fee' "$cfg" |
            grep -vE "^${EXPECTED_PERCENT}([.]0+)? ?%" | head -3)
    if [ -n "$stale" ]; then
        fail "site/docusaurus.config.js still advertises: ${stale}"
    else
        pass "the site title and footer advertise ${EXPECTED_PERCENT} %"
    fi
fi

# 1c. The appliance ships the same default, so an image and a binary from the
#     same commit cannot disagree about what a fresh rig pays.
tool_percent=$(grep -E '^DONATE_DEFAULT=' "${ROOT}/os/overlay/usr/local/bin/zmrig-os" | sed 's/.*="//; s/".*//')
if [ "${tool_percent:-x}" = "${EXPECTED_PERCENT}" ]; then
    pass "os.conf default DONATE = ${tool_percent} (same as the binary)"
else
    fail "os.conf default DONATE = ${tool_percent:-?} (binary: ${EXPECTED_PERCENT})"
fi

# 2. One wallet, in one file.
wallet_hits=$(grep -rl -- "${EXPECTED_WALLET}" "${ROOT}/zmrig/src" 2>/dev/null | wc -l | tr -d ' ')
if [ "${wallet_hits}" = "1" ] && grep -q -- "${EXPECTED_WALLET}" "${ROOT}/zmrig/src/fee.zig"; then
    pass "one developer wallet, in zmrig/src/fee.zig"
else
    fail "${wallet_hits} file(s) under zmrig/src mention the wallet (expected 1)"
fi

# 3. The fee is paid on Monero only, and the code says so where it counts.
if grep -q 'next_job.algo == .rx_0' "${ROOT}/zmrig/src/main.zig"; then
    pass "the clock only accrues on rx/0 jobs"
else
    fail "main.zig no longer gates the fee on rx/0"
fi

if [ "$SOURCE_ONLY" = "1" ]; then
    info "binary audit skipped (--source-only)"
    exit "$FAILED"
fi

[ -x "$BINARY" ] || { fail "no binary at ${BINARY} (build it, or pass --binary)"; exit 1; }

info "binary audit: ${BINARY}"

# 4. Exactly one wallet string in the shipped binary.
if command -v strings >/dev/null 2>&1; then
    # A comptime string can be emitted more than once (one copy per call site
    # with its own formatting), so what matters is the set, not the count.
    addresses=$(strings "$BINARY" | grep -oE "[48][1-9A-HJ-NP-Za-km-z]{94}" | sort -u)
    if [ "${addresses}" = "${EXPECTED_WALLET}" ]; then
        pass "the binary carries exactly one Monero address: the documented one"
    else
        fail "the binary carries an unexpected address set: $(printf '%s' "$addresses" | head -2 | tr '\n' ' ')"
    fi

    # 5. No second donation host, relay or pool. XMRig's own donate endpoint and
    #    the MoneroOcean relay are the two that a copy-paste would bring along.
    others=$(strings "$BINARY" | grep -Eci "donate\.v2\.xmrig\.com|xmrig\.com/donate|donate\.moneroocean|44tLjm" || true)
    if [ "${others:-0}" = "0" ]; then
        pass "no upstream donation host or wallet in the binary"
    else
        fail "${others} upstream donation string(s) in the binary"
    fi
fi

# 6. The fee is visible before the first hash, and it can be turned off.
check_out=$("$BINARY" -o pool.example.com:3333 -u TEST --check 2>&1 || true)
if printf '%s' "$check_out" | grep -qE "^ *donate +${EXPECTED_PERCENT}% of Monero \(rx/0\) mining time to ${EXPECTED_WALLET}"; then
    pass "--check prints the rate, the coin and the address"
else
    fail "--check does not print the fee line"
    printf '%s\n' "$check_out" | grep -i donate | head -2
fi

if printf '%s' "$check_out" | grep -qE "^ *donate +.*60 s every 33 min"; then
    pass "--check prints the cadence (60 s every 33 min at 3%)"
else
    fail "--check does not print the cadence"
fi

if "$BINARY" -o pool.example.com:3333 -u TEST --donate-level=0 --check 2>&1 | grep -qE "^ *donate +off"; then
    pass "--donate-level=0 turns the fee off"
else
    fail "--donate-level=0 is not honoured"
fi

if "$BINARY" -o pool.example.com:3333 -u TEST --no-donate --check 2>&1 | grep -qE "^ *donate +off"; then
    pass "--no-donate turns the fee off"
else
    fail "--no-donate is not honoured"
fi

# 7. A rate above the documented maximum is a typo, not a generous user.
if "$BINARY" -o pool.example.com:3333 -u TEST --donate-level=11 --check >/dev/null 2>&1; then
    fail "--donate-level=11 was accepted"
else
    pass "--donate-level=11 is rejected"
fi

printf '\n'
if [ "$FAILED" = "0" ]; then
    printf ' %s developer fee: %s%% of Monero time, one wallet, switchable off\n' "$(color '1;32' 'OK')" "$EXPECTED_PERCENT"
else
    printf ' %s the fee audit found a problem\n' "$(color '1;31' 'FAIL')"
fi
exit "$FAILED"

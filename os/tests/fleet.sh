#!/usr/bin/env bash
#
# fleet.sh - the rig side of the control plane, against the real server.
#
#   ./os/tests/fleet.sh
#
# No root, no Telegram token and no network: os/tests/fleet-stub.js starts the
# actual fleet HTTP server from fleet/src on a loopback port, and the tool talks
# to it exactly as a rig would. What this proves is the half that cannot be
# proved in JavaScript: that the shell agent produces a body the server accepts,
# applies what comes back, and tells the truth about it afterwards.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${0}")/../.." && pwd)
TOOL="${ROOT}/os/overlay/usr/local/bin/zmrig-os"
STUB="${ROOT}/os/tests/fleet-stub.js"
WALLET="46SQLW7DXaq6GJaQbHUFMAhd1VYpfQFJQ2gfZo9TCB8bf9vnf1MUwAD2Fwj6KMsY4RU3oKA3x6hByg8BKg7FfMWn6ysb5tJ"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*"; }
check() { local what="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi; }
contains() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

WORK=$(mktemp -d)
ROOTDIR="${WORK}/root"
mkdir -p "${ROOTDIR}/etc/zmrig" "${ROOTDIR}/run/zmrig" "${ROOTDIR}/usr/local/bin" "${ROOTDIR}/var/log"
PORTFILE="${WORK}/ports.json"
STATE="${WORK}/state.json"

cleanup() {
    [ -n "${STUB_PID:-}" ] && kill "$STUB_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

export ZMRIG_OS_ROOT="$ROOTDIR"
export ZMRIG_OS_DRYRUN=1

zig_tool() { sh "$TOOL" "$@"; }

printf '\nzmrig-os fleet tests\n\n'

if ! command -v node >/dev/null 2>&1; then
    printf '  SKIP  node is not installed: the stub control plane needs it\n\n'
    exit 0
fi

node "$STUB" "$STATE" "$PORTFILE" &
STUB_PID=$!
for _ in $(seq 1 100); do
    [ -s "$PORTFILE" ] && break
    sleep 0.1
done
if [ ! -s "$PORTFILE" ]; then
    printf '  FAIL  the stub control plane did not start\n'
    exit 1
fi

PORT_DEVICE=$(node -e "process.stdout.write(String(JSON.parse(require('fs').readFileSync('$PORTFILE')).device))")
PORT_CONTROL=$(node -e "process.stdout.write(String(JSON.parse(require('fs').readFileSync('$PORTFILE')).control))")
DEVICE="http://127.0.0.1:${PORT_DEVICE}"
CONTROL="http://127.0.0.1:${PORT_CONTROL}"

# ------------------------------------------------------------- identity

ID=$(zig_tool id | sed -n 's/^  device *//p')
CODE=$(zig_tool id | sed -n 's/^  enrol code *//p')
case "$ID" in ZMR-????-????-????) ok "zmrig-os id prints a Device ID" ;; *) bad "zmrig-os id prints a Device ID (got '$ID')" ;; esac
case "$CODE" in ????-????) ok "zmrig-os id prints an enrolment code" ;; *) bad "zmrig-os id prints an enrolment code (got '$CODE')" ;; esac
[ "$(zig_tool id | sed -n 's/^  device *//p')" = "$ID" ] && ok "the ID is stable across runs" || bad "the ID is stable across runs"
[ -f "${ROOTDIR}/etc/zmrig/device.key" ] && ok "the key is written once and reused" || bad "the key is written once and reused"
[ "$(wc -c < "${ROOTDIR}/etc/zmrig/device.key" | tr -d ' ')" -ge 64 ] && ok "the key is 32 bytes of hex" || bad "the key is 32 bytes of hex"
check "the key file is not world-readable" test "$(stat -c %a "${ROOTDIR}/etc/zmrig/device.key")" = "600"

# ---------------------------------------------------------- pointing it

check "sync without a server is a no-op, not an error" zig_tool sync --now
zig_tool fleet --url "$DEVICE" >/dev/null 2>&1
check "the server URL is stored in os.conf" grep -q "^FLEET_URL=\"${DEVICE}\"" "${ROOTDIR}/etc/zmrig/os.conf"
check "a non-URL is refused" bash -c "! sh '$TOOL' fleet --url not-a-url"
check "fleet with no argument prints the identity" bash -c "sh '$TOOL' fleet | grep -q '$ID'"

# ------------------------------------------------------- first check-in

zig_tool sync --now >/dev/null 2>&1
SEEN_ID=$(curl -fsS "${CONTROL}/state?id=${ID}" | node -e "
let data='';process.stdin.on('data',(d)=>data+=d).on('end',()=>{
  const parsed=JSON.parse(data);
  process.stdout.write(parsed.device ? parsed.device.id : 'none');
});")
[ "$SEEN_ID" = "$ID" ] && ok "the first check-in reaches the server" || bad "the first check-in reaches the server (got '$SEEN_ID')"

ENROLLED=$(curl -fsS "${CONTROL}/state?id=${ID}" | node -e "
let data='';process.stdin.on('data',(d)=>data+=d).on('end',()=>{
  const parsed=JSON.parse(data);
  process.stdout.write(parsed.device ? String(parsed.device.status.state) : 'none');
});")
[ "$ENROLLED" = "stopped" ] && ok "the rig reports its real state (stopped, no wallet)" || bad "the rig reports its real state (got '$ENROLLED')"

# ------------------------------------------------------------- enrolment

check "the bot can enrol the rig" bash -c "curl -fsS '${CONTROL}/enrol?id=${ID}&owner=tg:1&label=basement' >/dev/null"

# --------------------------------------------------------- a queued wallet

curl -fsS "${CONTROL}/queue?id=${ID}&cmd=setup&wallet=${WALLET}" >/dev/null
zig_tool sync --now >/dev/null 2>&1
check "a wallet from the bot lands in os.conf" grep -q "^WALLET=\"${WALLET}\"" "${ROOTDIR}/etc/zmrig/os.conf"
check "the miner would now start with it" bash -c "sh '$TOOL' args 2>/dev/null | grep -q '${WALLET}'"

ACKS=$(curl -fsS "${CONTROL}/state?id=${ID}" | node -e "
let data='';process.stdin.on('data',(d)=>data+=d).on('end',()=>{
  const parsed=JSON.parse(data);
  process.stdout.write(parsed.device ? String(parsed.device.queue) : 'none');
});")
[ "$ACKS" = "0" ] && ok "the queue is empty after the change was applied" || bad "the queue is empty after the change was applied (got '$ACKS')"

# ------------------------------------------------------------ refusals

BEFORE=$(md5sum "${ROOTDIR}/etc/zmrig/os.conf" | cut -d' ' -f1)
curl -fsS "${CONTROL}/queue?id=${ID}&cmd=setup&wallet=not-a-wallet" >/dev/null
zig_tool sync --now >/dev/null 2>&1
AFTER=$(md5sum "${ROOTDIR}/etc/zmrig/os.conf" | cut -d' ' -f1)
[ "$BEFORE" = "$AFTER" ] && ok "a bad wallet is refused and nothing is written" || bad "a bad wallet is refused and nothing is written"

curl -fsS "${CONTROL}/queue?id=${ID}&cmd=setup&mode=turbo" >/dev/null
zig_tool sync --now >/dev/null 2>&1
check "an unknown mode is refused" bash -c "! grep -q '^MODE=\"turbo\"' '${ROOTDIR}/etc/zmrig/os.conf'"
# A result travels with the check-in after the one that produced it, so give it one.
zig_tool sync --now >/dev/null 2>&1

FAILED=$(curl -fsS "${CONTROL}/state?id=${ID}" | node -e "
let data='';process.stdin.on('data',(d)=>data+=d).on('end',()=>{
  const parsed=JSON.parse(data);
  process.stdout.write(String((parsed.events||[]).filter((e)=>e.kind==='ack' && e.text.includes('failed')).length));
});")
[ "$FAILED" -ge 2 ] && ok "both refusals are reported back to the bot" || bad "both refusals are reported back to the bot (got $FAILED)"

# ------------------------------------------------------------- operations

CPID_FILE="${ROOTDIR}/run/zmrig/zmrig.pid"
sleep 30 &
FAKE_PID=$!
printf '%s\n' "$FAKE_PID" > "$CPID_FILE"

curl -fsS "${CONTROL}/queue?id=${ID}&cmd=stop" >/dev/null
zig_tool sync --now >/dev/null 2>&1
check "stop from the bot stops the miner" bash -c "! kill -0 $FAKE_PID 2>/dev/null"

kill "$FAKE_PID" 2>/dev/null

curl -fsS "${CONTROL}/queue?id=${ID}&cmd=log" >/dev/null
zig_tool sync --now >/dev/null 2>&1
printf 'seed line one\nseed line two\n' > "${ROOTDIR}/var/log/zmrig.log"
zig_tool sync --now >/dev/null 2>&1
LOG_SEEN=$(curl -fsS "${CONTROL}/state?id=${ID}" | node -e "
let data='';process.stdin.on('data',(d)=>data+=d).on('end',()=>{
  const parsed=JSON.parse(data);
  process.stdout.write(String(parsed.device ? parsed.device.log : ''));
});")
contains "seed line two" "$LOG_SEEN" && ok "a log request brings the rig's log back" || bad "a log request brings the rig's log back (got '$LOG_SEEN')"

# -------------------------------------------------------- pacing and quiet

NEXT_FILE="${ROOTDIR}/run/zmrig/sync.next"
[ -s "$NEXT_FILE" ] && ok "the server's interval is written down" || bad "the server's interval is written down"
BEFORE_SEEN=$(cat "$NEXT_FILE")
zig_tool sync --quiet >/dev/null 2>&1
[ "$(cat "$NEXT_FILE")" = "$BEFORE_SEEN" ] && ok "a check-in before its time does not contact the server" || bad "a check-in before its time does not contact the server"

OUTPUT=$(sh "$TOOL" sync 2>&1)
[ -z "$OUTPUT" ] && ok "sync stays silent when there is nothing to say" || bad "sync stays silent when there is nothing to say (got '$OUTPUT')"

check "status shows the device and the server" bash -c "sh '$TOOL' status | grep -q '$ID' && sh '$TOOL' status | grep -q '$DEVICE'"

# ---------------------------------------------------------- wrong server

zig_tool fleet --url http://127.0.0.1:1 >/dev/null 2>&1
check "an unreachable server is not an error" zig_tool sync --now --quiet
zig_tool fleet --url "$DEVICE" >/dev/null 2>&1

printf '\n    %d passed, %d failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

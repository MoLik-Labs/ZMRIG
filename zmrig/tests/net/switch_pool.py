#!/usr/bin/env python3
"""A fake pool that takes a rig for a detour and brings it back.

It logs in with a Monero job, switches to Panthera at `--away` seconds, and
comes back to Monero with the *same seed* at `--back` seconds. That round trip
is what a small pool does whenever the most profitable coin changes and changes
back, and it is the case `--dataset-cache` exists for:

  * without the cache the return costs a full dataset rebuild (16.5-20.3 s on
    two cores, measured), during which the rig hashes nothing;
  * with the cache the return is a pointer swap - but only if the process-wide
    RandomX configuration is re-applied, because hashing Monero's dataset under
    Panthera's parameters produces *wrong hashes rather than slow ones*.

So this pool also records the shares it is sent after the switch, in the shape
`zmrig --verify-share` reads, so the test can recompute them and prove the
hashes are right rather than fast.

  python3 zmrig/tests/net/switch_pool.py --port 4712 --shares /tmp/shares.jsonl

Nothing in here is allowed to block forever. A test that runs in CI and waits
for a rig that never arrives is worse than a failing test: the job sits at
"in progress" for as long as the runner allows, and the log that would explain
it is the one nobody gets to read. So the listener has a deadline, a silent
connection has a deadline, and both of them end the process.
"""

import argparse
import json
import socket
import struct
import sys
import threading
import time

TICK = 0.5            # how often a wait is allowed to look at the clock again
CONNECT_GRACE = 10.0  # a rig that is not here by now is not coming

SEND_LOCK = threading.Lock()
T0 = time.time()


def log(message):
    with SEND_LOCK:
        sys.stdout.write("%6.1f %s\n" % (time.time() - T0, message))
        sys.stdout.flush()


def blob_hex(height, tag, algo):
    """A blob the size the algorithm wants.

    Panthera owns its nonce at byte 147, so its blobs are 152 bytes and a
    Monero-sized one is a job nothing can hash - the miner says `ShortBlob`
    and the test would be measuring the wrong thing.
    """
    size = 152 if algo in ("panthera", "rx/xla", "scala", "xla") else 76
    raw = bytearray(size)
    raw[0:8] = struct.pack("<Q", height)
    raw[8] = tag & 0xFF

    return bytes(raw).hex()


def seed_hex(tag):
    return (str(tag) * 64)[:64]


class Pool:
    def __init__(self, args):
        self.args = args
        self.conn = None
        self.jobs = {}

    def send(self, message):
        with SEND_LOCK:
            self.conn.sendall((json.dumps(message) + "\n").encode())

    def job(self, job_id, height, seed, algo, tag):
        params = {
            "blob": blob_hex(height, tag, algo),
            "job_id": job_id,
            "target": self.args.target,
            "height": height,
            "seed_hash": seed,
            "algo": algo,
        }
        self.jobs[job_id] = {"seed": seed, "blob": params["blob"], "algo": algo}

        return params

    def readline(self):
        """One line, or None at the end of the stream - or at the deadline.

        The socket has a timeout so a rig that is hashing and not submitting
        (a slow runner, a difficulty that is too high) cannot hold the pool
        past `--duration`: the check below is the only reason the test has a
        bounded running time at all.
        """
        while b"\n" not in self.buf:
            try:
                chunk = self.conn.recv(65536)
            except socket.timeout:
                if time.time() >= self.deadline:
                    return None
                continue
            if not chunk:
                return None
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)

        return line.rstrip(b"\r")

    def serve(self):
        self.conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.conn.settimeout(TICK)
        self.buf = b""

        login = json.loads(self.readline())
        log("LOGIN %s" % (login.get("params") or {}).get("login"))

        first = self.job("job-1", 1001, seed_hex(1), "rx/0", 1)
        self.send({"id": login.get("id"), "jsonrpc": "2.0", "error": None,
                   "result": {"id": "rig", "job": first, "status": "OK"}})
        log("JOB job-1 rx/0")

        start = time.time()

        def later(after, fn):
            threading.Thread(target=lambda: (time.sleep(max(0, start + after - time.time())), fn()),
                             daemon=True).start()

        def away():
            job = self.job("job-2", 1002, seed_hex(2), "panthera", 2)
            self.send({"jsonrpc": "2.0", "method": "job", "params": job})
            log("JOB job-2 panthera")

        def back():
            job = self.job("job-3", 1003, seed_hex(1), "rx/0", 3)
            self.send({"jsonrpc": "2.0", "method": "job", "params": job})
            log("JOB job-3 rx/0 again, same seed")

        later(self.args.away, away)
        later(self.args.back, back)

        self.deadline = time.time() + self.args.duration
        recorded = 0
        while time.time() < self.deadline:
            line = self.readline()
            if line is None:
                break
            try:
                message = json.loads(line)
            except ValueError:
                continue
            if message.get("method") != "submit":
                continue

            params = message.get("params") or {}
            self.send({"id": message.get("id"), "jsonrpc": "2.0", "error": None,
                       "result": {"status": "OK"}})

            # Only the shares from after the switch back prove anything: the
            # earlier ones were hashed by an engine that had never been away.
            job_id = params.get("job_id")
            if job_id != "job-3" or recorded >= self.args.record:
                continue

            job = self.jobs.get(job_id)
            if job is None:
                continue

            recorded += 1
            entry = {"seed": job["seed"], "blob": job["blob"],
                     "nonce": params.get("nonce"), "result": params.get("result")}
            with open(self.args.shares, "a") as handle:
                handle.write(json.dumps(entry) + "\n")
            log("SHARE job=job-3 nonce=%s" % params.get("nonce"))

        log("DONE, %d share(s) recorded for verification" % recorded)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=4712)
    parser.add_argument("--away", type=float, default=18)
    parser.add_argument("--back", type=float, default=40)
    parser.add_argument("--duration", type=float, default=60)
    parser.add_argument("--record", type=int, default=1)
    # Difficulty 1: every hash is a share, so the test does not depend on luck.
    parser.add_argument("--target", default="f753e3a5")
    parser.add_argument("--shares", default="/tmp/zmrig-switch-shares.jsonl")
    # Only the self-test shortens this: it exists to prove the pool gives up.
    parser.add_argument("--connect-grace", type=float, default=CONNECT_GRACE)
    args = parser.parse_args()

    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", args.port))
    server.listen(2)
    server.settimeout(TICK)
    log("listening %d" % args.port)

    # A rig that never connects used to leave this process in accept() forever,
    # and the suite waited on it. Give up out loud instead.
    give_up = time.time() + args.duration + args.connect_grace
    conn = None
    while conn is None:
        try:
            conn, _ = server.accept()
        except socket.timeout:
            if time.time() >= give_up:
                log("no rig connected in %.0f s, giving up" % (args.duration + args.connect_grace))
                sys.exit(2)
    pool = Pool(args)
    pool.conn = conn
    try:
        pool.serve()
    finally:
        try:
            conn.close()
        except OSError:
            pass


if __name__ == "__main__":
    main()

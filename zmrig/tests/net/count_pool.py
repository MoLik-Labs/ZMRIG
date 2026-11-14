#!/usr/bin/env python3
"""A pool that counts, because the number that matters is shares per hash.

The miner decides whether a hash is a share by comparing the low 64 bits of the
digest against the job's target. Nothing in the hashrate line says whether that
comparison is right: if it were off by a byte, by a comparison operator, or by
comparing the high half of the hash instead of the low half, the rig would
either submit too rarely (money lost, and the pool says nothing) or far too
often (the pool calls it a flood and bans the IP).

RandomX output is uniform, so a correct comparison submits exactly
`hashes / difficulty` shares and no more. This pool does not re-implement
RandomX to check any individual hash; it counts, and the counts are the proof:

  * submits are counted per job, so one run can serve a job at difficulty 2 000
    and then one at 1 000 000 and report both;
  * duplicate (job, nonce) pairs are counted, because a rig that resubmits is a
    rig whose pipeline bookkeeping is off by one;
  * shares are never rejected, so a submit the miner should not have made is
    still visible in the count instead of being hidden by a refusal.

  python3 zmrig/tests/net/count_pool.py --port 4720 --diff 1000

Prints one line at the end:

  SUBMITS job-1=37 job-2=0 DUPLICATES 0 BAD 0

and, with `--record FILE`, writes the shares it was sent in the shape
`zmrig --verify-share` reads, so a test can recompute them and check them
against the rule the pool actually uses (see `zmrig/tests/targets.sh`).
"""

import argparse
import json
import socket
import sys
import threading
import time

MAX64 = (1 << 64) - 1
LOCK = threading.Lock()
T0 = time.time()


def log(message):
    with LOCK:
        sys.stdout.write("%6.1f %s\n" % (time.time() - T0, message))
        sys.stdout.flush()


def target_hex(diff):
    return (MAX64 // max(int(diff), 1)).to_bytes(8, "little").hex()


class Pool:
    def __init__(self, args):
        self.args = args
        self.conn = None
        self.buf = b""
        self.deadline = 0.0
        self.jobs = {}
        self.submits = {}
        self.duplicates = 0
        self.bad = 0
        self.seen = set()
        self.known = set()
        self.recorded = 0

    def send(self, message):
        with LOCK:
            self.conn.sendall((json.dumps(message) + "\n").encode())

    def job(self, job_id, height, diff, tag):
        blob = bytearray(76)
        blob[0:8] = height.to_bytes(8, "little")
        blob[8] = tag & 0xFF

        self.known.add(job_id)
        self.submits.setdefault(job_id, 0)

        target = target_hex(diff)
        self.jobs[job_id] = {"blob": bytes(blob).hex(),
                             "seed": (str(tag) * 64)[:64],
                             "target": target, "diff": diff}

        return {
            "blob": bytes(blob).hex(),
            "job_id": job_id,
            "target": target,
            "height": height,
            "seed_hash": (str(tag) * 64)[:64],
            "algo": "rx/0",
        }

    def readline(self):
        """One line, or None when the stream ends or the run is over.

        The socket has a timeout so the deadline check below is reached even
        when the rig is hashing and not submitting - the alternative is a pool
        that outlives its own `--duration` and takes the test with it.
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
        self.conn.settimeout(0.5)

        login = json.loads(self.readline())
        log("LOGIN %s" % (login.get("params") or {}).get("login"))

        first = self.job("job-1", 2001, self.args.diff, 1)
        self.send({"id": login.get("id"), "jsonrpc": "2.0", "error": None,
                   "result": {"id": "rig", "job": first, "status": "OK"}})
        log("JOB job-1 diff %s" % self.args.diff)

        start = time.time()
        self.deadline = start + self.args.duration
        switched = False

        while time.time() < self.deadline:
            if not switched and time.time() - start >= self.args.switch_after:
                switched = True
                second = self.job("job-2", 2002, self.args.hard_diff, 2)
                self.send({"jsonrpc": "2.0", "method": "job", "params": second})
                log("JOB job-2 diff %s (hard: a correct miner submits almost never)"
                    % self.args.hard_diff)

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
            job_id = params.get("job_id")
            nonce = params.get("nonce")

            if job_id not in self.known:
                self.bad += 1
                log("SUBMIT for an unknown job %r" % (job_id,))
            else:
                self.submits[job_id] += 1
                key = (job_id, nonce)
                if key in self.seen:
                    self.duplicates += 1
                    log("DUPLICATE nonce %r for %r" % (nonce, job_id))
                else:
                    self.seen.add(key)
                    job = self.jobs[job_id]
                    if self.args.record and self.recorded < self.args.record_count:
                        self.recorded += 1
                        with open(self.args.record, "a") as handle:
                            handle.write(json.dumps({
                                "seed": job["seed"], "blob": job["blob"],
                                "nonce": nonce, "target": job["target"],
                                "diff": job["diff"], "job_id": job_id,
                            }) + "\n")

            self.send({"id": message.get("id"), "jsonrpc": "2.0", "error": None,
                       "result": {"status": "OK"}})

    def summary(self):
        # One fixed shape, so a reader (and `zmrig/tests/targets.sh`) does not
        # have to know which jobs this run happened to create.
        print("SUBMITS job-1=%d job-2=%d DUPLICATES %d BAD %d" % (
            self.submits.get("job-1", 0), self.submits.get("job-2", 0),
            self.duplicates, self.bad))
        sys.stdout.flush()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=4720)
    parser.add_argument("--diff", type=float, default=2000)
    parser.add_argument("--hard-diff", type=float, default=1000000)
    parser.add_argument("--switch-after", type=float, default=45,
                        help="seconds before the hard job replaces the easy one")
    parser.add_argument("--duration", type=float, default=120)
    parser.add_argument("--record", default=None,
                        help="write the shares it is sent to this JSONL file")
    parser.add_argument("--record-count", type=int, default=8)
    args = parser.parse_args()

    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", args.port))
    server.listen(4)
    log("listening %d" % args.port)

    conn, _ = server.accept()
    pool = Pool(args)
    pool.conn = conn
    try:
        pool.serve()
    except (OSError, ValueError) as error:
        log("pool stopped: %s" % error)
    finally:
        pool.summary()
        try:
            conn.close()
        except OSError:
            pass


if __name__ == "__main__":
    main()

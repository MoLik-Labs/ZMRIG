#!/usr/bin/env python3
"""A WebSocket endpoint that speaks the protocol wrong, on purpose.

Two modes, both of which a real CDN or a misconfigured reverse proxy in front of
a pool can produce, and neither of which the miner can recover from by
pretending the frame was fine:

  long-ping     RFC 6455 5.5: a control frame carries at most 125 bytes and is
                never fragmented. This sends a 512-byte ping. A client that
                answers by truncating the payload to its 125-byte buffer leaves
                387 bytes in the socket, which are then read as the header of
                the next frame: the stream desynchronises and the connection
                hangs instead of reconnecting.

  bad-accept    A 101 whose Sec-WebSocket-Accept does not match. The miner warns
                and continues (some proxies rewrite it), which is deliberate.

Usage:
  python3 zmrig/tests/net/bad_ws.py --port 4900 --mode long-ping
"""

import argparse
import base64
import hashlib
import socket
import sys
import threading
import time

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def handshake(conn, wrong_accept):
    request = b""
    while b"\r\n\r\n" not in request:
        chunk = conn.recv(4096)
        if not chunk:
            return False
        request += chunk

    key = ""
    for line in request.decode("latin1").split("\r\n"):
        if line.lower().startswith("sec-websocket-key:"):
            key = line.split(":", 1)[1].strip()

    accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
    if wrong_accept:
        accept = base64.b64encode(b"x" * 20).decode()

    conn.sendall(
        (
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            "Sec-WebSocket-Accept: %s\r\n\r\n" % accept
        ).encode()
    )

    return True


def handle(conn, mode):
    try:
        if not handshake(conn, mode == "bad-accept"):
            return

        if mode == "long-ping":
            # FIN + ping, 16-bit extended length, no mask, 512 bytes of payload.
            conn.sendall(b"\x89\x7e" + (512).to_bytes(2, "big") + b"P" * 512)
        elif mode == "bad-accept":
            # A correct, empty text frame after the wrong accept value: the
            # miner should stay connected and keep reading.
            conn.sendall(b"\x81\x04ping")

        time.sleep(30)
    except Exception:
        pass
    finally:
        conn.close()


def serve(port, mode):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(8)

    while True:
        conn, _ = srv.accept()
        threading.Thread(target=handle, args=(conn, mode), daemon=True).start()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--mode", choices=("long-ping", "bad-accept"), default="long-ping")
    args = parser.parse_args()

    sys.stdout.write("bad_ws: %s on 127.0.0.1:%d\n" % (args.mode, args.port))
    sys.stdout.flush()

    serve(args.port, args.mode)


if __name__ == "__main__":
    main()

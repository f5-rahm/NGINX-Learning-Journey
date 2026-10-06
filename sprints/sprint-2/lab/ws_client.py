#!/usr/bin/env python3
"""
Minimal WebSocket client for Sprint 2 Day 3 (no third-party packages).

    ws_client.py ws://localhost:8082/ws/chat hello there     # send each word, print echoes
    ws_client.py ws://localhost:8082/ws/chat --idle 8        # handshake, then sit idle
"""
import argparse, base64, os, socket, struct, sys, time
from urllib.parse import urlsplit


def send_frame(sock, opcode, data):
    mask = os.urandom(4)                                  # clients must mask (RFC 6455 5.3)
    header = bytes([0x80 | opcode])
    n = len(data)
    if n < 126:
        header += bytes([0x80 | n])
    elif n < 65536:
        header += bytes([0x80 | 126]) + struct.pack("!H", n)
    else:
        header += bytes([0x80 | 127]) + struct.pack("!Q", n)
    sock.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))


def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("connection closed by peer")
        buf += chunk
    return buf


def recv_frame(sock):
    b1, b2 = recv_exact(sock, 2)
    n = b2 & 0x7F
    if n == 126:
        n = struct.unpack("!H", recv_exact(sock, 2))[0]
    elif n == 127:
        n = struct.unpack("!Q", recv_exact(sock, 8))[0]
    return b1 & 0x0F, recv_exact(sock, n)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("url")
    p.add_argument("messages", nargs="*")
    p.add_argument("--host", default="lumina.local", help="Host header to send")
    p.add_argument("--idle", type=float, default=0, help="seconds to stay idle after the messages")
    a = p.parse_args()

    u = urlsplit(a.url)
    sock = socket.create_connection((u.hostname, u.port or 80))
    key = base64.b64encode(os.urandom(16)).decode()
    sock.sendall((f"GET {u.path or '/'} HTTP/1.1\r\nHost: {a.host}\r\nUpgrade: websocket\r\n"
                  f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = sock.recv(4096)
        if not chunk:
            sys.exit("connection closed during handshake")
        head += chunk
    head, _, rest = head.partition(b"\r\n\r\n")
    status = head.split(b"\r\n")[0].decode()
    print(f"< {status}")
    if " 101 " not in status + " ":
        sys.exit(1)
    if rest:
        print("(server sent frame bytes with the handshake)")

    t0 = time.time()
    try:
        print(f"< {recv_frame(sock)[1].decode(errors='replace')}")      # welcome frame
        for m in a.messages:
            send_frame(sock, 0x1, m.encode())
            print(f"> {m}\n< {recv_frame(sock)[1].decode(errors='replace')}")
        if a.idle:
            print(f"... idle for {a.idle:g}s")
            sock.settimeout(a.idle)
            try:
                op, data = recv_frame(sock)
                print(f"< frame opcode {op} after {time.time() - t0:.1f}s")
            except socket.timeout:
                print(f"still open after {a.idle:g}s idle")
        send_frame(sock, 0x8, struct.pack("!H", 1000))
        print("> close")
    except ConnectionError as e:
        print(f"!! {e} after {time.time() - t0:.1f}s")
    finally:
        sock.close()


if __name__ == "__main__":
    main()

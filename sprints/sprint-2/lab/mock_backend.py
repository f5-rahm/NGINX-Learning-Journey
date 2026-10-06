#!/usr/bin/env python3
"""
Mock backends for Sprint 2.

Run one node per process so a single node can be killed mid-lab
(lab/mocks.sh does this for you):

    mock_backend.py --port 8001 --name api-node-1        # HTTP echo node
    mock_backend.py --port 8003 --name chat-ws --ws      # WebSocket echo node
    mock_backend.py                                      # all three in one process

HTTP nodes answer any method and echo what they received as JSON:
node, method, path, the peer address NGINX connected from, how many requests
this TCP connection has carried (conn_requests > 1 means NGINX reused it, Day 2),
headers, and body size.

Query parameters (any path):
    ?delay=2.5     sleep before answering (slow backend, timeouts, least_conn)
    ?status=503    answer with this status code (proxy_next_upstream)
    ?drop=1        close the connection without answering (a crashing backend)
"""

import argparse
import base64
import hashlib
import json
import socket
import struct
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class NodeHandler(BaseHTTPRequestHandler):
    # HTTP/1.1 so NGINX can keep upstream connections open (keepalive)
    protocol_version = "HTTP/1.1"
    node_id = "unknown"

    def _handle(self):
        # one handler instance lives as long as its TCP connection
        self.conn_requests = getattr(self, "conn_requests", 0) + 1
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""

        # Python's http.server collapses a leading "//" in self.path; echo the raw
        # request-line target so URI-mapping mistakes like "//v1/stats" stay visible
        raw_path = self.requestline.split(" ")[1] if " " in self.requestline else self.path
        query = parse_qs(urlsplit(raw_path).query)
        delay = float(query.get("delay", ["0"])[0])
        status = int(query.get("status", ["200"])[0])
        if delay > 0:
            time.sleep(delay)
        if query.get("drop", ["0"])[0] == "1":
            self.log_message('"%s" dropped without a response', self.requestline)
            self.close_connection = True
            self.connection.shutdown(socket.SHUT_RDWR)
            return

        payload = {
            "node": self.node_id,
            "method": self.command,
            "http_version": self.request_version,
            "path": raw_path,
            "peer": f"{self.client_address[0]}:{self.client_address[1]}",
            "conn_requests": self.conn_requests,
            "headers": dict(self.headers.items()),
            "body_bytes": len(body),
        }
        resp = (json.dumps(payload, indent=2) + "\n").encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("X-Handled-By", self.node_id)
        self.send_header("Content-Length", str(len(resp)))
        self.end_headers()
        self.wfile.write(resp)

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = _handle

    def log_message(self, fmt, *args):
        sys.stdout.write(f"[{self.node_id}] {self.client_address[1]} {fmt % args}\n")
        sys.stdout.flush()


def run_http_node(port, name, bind="127.0.0.1"):
    handler = type("Handler", (NodeHandler,), {"node_id": name})
    server = ThreadingHTTPServer((bind, port), handler)
    server.daemon_threads = True
    print(f"[{name}] HTTP echo node listening on {bind}:{port}", flush=True)
    server.serve_forever()


# --- WebSocket (RFC 6455) -----------------------------------------------------

def recv_exact(conn, n):
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            raise ConnectionError
        buf += chunk
    return buf


def send_frame(conn, opcode, data):
    header = bytes([0x80 | opcode])
    if len(data) < 126:
        header += bytes([len(data)])
    elif len(data) < 65536:
        header += bytes([126]) + struct.pack("!H", len(data))
    else:
        header += bytes([127]) + struct.pack("!Q", len(data))
    conn.sendall(header + data)


def ws_session(conn, name):
    """Handshake, then echo text frames back until the client closes."""
    try:
        raw = b""
        while b"\r\n\r\n" not in raw:
            chunk = conn.recv(4096)
            if not chunk:
                return
            raw += chunk
        lines = raw.decode(errors="ignore").split("\r\n")
        headers = {k.strip().lower(): v.strip()
                   for k, _, v in (l.partition(":") for l in lines[1:] if ":" in l)}

        key = headers.get("sec-websocket-key")
        conn_tokens = [t.strip().lower() for t in headers.get("connection", "").split(",")]
        if headers.get("upgrade", "").lower() != "websocket" or "upgrade" not in conn_tokens or not key:
            body = b"expected a WebSocket upgrade\n"
            conn.sendall(b"HTTP/1.1 400 Bad Request\r\nContent-Length: "
                         + str(len(body)).encode() + b"\r\nConnection: close\r\n\r\n" + body)
            print(f"[{name}] 400: handshake missing headers (Upgrade={headers.get('upgrade')!r} "
                  f"Connection={headers.get('connection')!r})", flush=True)
            return

        accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
        conn.sendall((
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
        ).encode())
        print(f"[{name}] 101: upgraded connection from port {conn.getpeername()[1]}", flush=True)
        send_frame(conn, 0x1, f"welcome from {name}".encode())

        while True:
            b1, b2 = recv_exact(conn, 2)
            opcode, masked, length = b1 & 0x0F, b2 & 0x80, b2 & 0x7F
            if length == 126:
                length = struct.unpack("!H", recv_exact(conn, 2))[0]
            elif length == 127:
                length = struct.unpack("!Q", recv_exact(conn, 8))[0]
            mask = recv_exact(conn, 4) if masked else b"\0\0\0\0"
            data = bytes(c ^ mask[i % 4] for i, c in enumerate(recv_exact(conn, length)))
            if opcode == 0x8:                      # close
                send_frame(conn, 0x8, data[:2])
                return
            if opcode == 0x9:                      # ping
                send_frame(conn, 0xA, data)
            elif opcode in (0x1, 0x2):             # text / binary
                send_frame(conn, opcode, b"echo: " + data)
    except (ConnectionError, OSError):
        pass
    finally:
        print(f"[{name}] connection closed", flush=True)
        conn.close()


def run_ws_node(port, name, bind="127.0.0.1"):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((bind, port))
    s.listen(64)
    print(f"[{name}] WebSocket echo node listening on {bind}:{port}", flush=True)
    while True:
        conn, _ = s.accept()
        threading.Thread(target=ws_session, args=(conn, name), daemon=True).start()


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--port", type=int, help="run a single node on this port")
    p.add_argument("--name", help="node name reported in responses")
    p.add_argument("--ws", action="store_true", help="run a WebSocket node instead of HTTP")
    p.add_argument("--bind", default="127.0.0.1", help="address to listen on (any 127.x.y.z works on Linux)")
    args = p.parse_args()

    if args.port:
        name = args.name or f"node-{args.port}"
        (run_ws_node if args.ws else run_http_node)(args.port, name, args.bind)
        return

    for target, port, name in ((run_http_node, 8001, "api-node-1"),
                               (run_http_node, 8002, "api-node-2"),
                               (run_ws_node, 8003, "chat-ws")):
        threading.Thread(target=target, args=(port, name), daemon=True).start()
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()

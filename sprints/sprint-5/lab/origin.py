#!/usr/bin/env python3
"""Sprint 5 origin: the Lumina API behind the gateway, countable and easy to slow down.

Every response is a small JSON document saying which URI was asked for, what
the origin was told about the client (X-Real-IP / X-Forwarded-For), and how
many requests are in progress at the origin right now.

Query parameters (any path):
    ?delay=2.5          sleep before answering (a slow endpoint)
    ?status=503         answer with this status code
    ?size=2m            answer with a body of this many bytes instead of JSON
                        (plain number, or with a k / m suffix): a download

POST bodies are read and their size is reported as "body_bytes".

Control endpoints (never counted):
    /_stats              JSON: requests per URI, total, in flight now, most in flight at once
    /_stats/reset        zero all counters
"""
import argparse
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

LOCK = threading.Lock()
STATS = {"by_uri": {}, "total": 0, "inflight": 0, "max_inflight": 0}
CHUNK = b"x" * 65536


def parse_size(text):
    text = text.strip().lower()
    mult = {"k": 1024, "m": 1024 * 1024}.get(text[-1:], 1)
    return int(float(text.rstrip("km")) * mult)


class Origin(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"      # keepalive capable
    disable_nagle_algorithm = True     # no 40 ms Nagle/delayed-ACK stall between headers and body
    server_version = "lumina-api"
    sys_version = ""

    def do_HEAD(self):
        self._handle(head=True)

    def do_GET(self):
        self._handle()

    def do_POST(self):
        self._handle()

    def _send(self, status, body=b"", ctype="application/json", head=False):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if body and not head:
            self.wfile.write(body)

    def _json(self, obj, status=200, head=False):
        self._send(status, (json.dumps(obj, indent=2) + "\n").encode(), head=head)

    def _control(self, path):
        if path == "/_stats":
            with LOCK:
                return self._json(STATS)
        if path == "/_stats/reset":
            with LOCK:
                STATS.update(by_uri={}, total=0, max_inflight=STATS["inflight"])
            return self._json({"reset": True})
        return self._json({"error": "unknown control endpoint"}, 404)

    def _handle(self, head=False):
        # Python's http.server collapses a leading "//" in self.path; keep the raw URI
        raw = self.requestline.split(" ")[1] if " " in self.requestline else self.path
        parts = urlsplit(raw)
        query = parse_qs(parts.query)
        if parts.path.startswith("/_"):
            return self._control(parts.path)

        body_bytes = 0
        length = int(self.headers.get("Content-Length") or 0)
        while body_bytes < length:
            got = self.rfile.read(min(65536, length - body_bytes))
            if not got:
                break
            body_bytes += len(got)

        with LOCK:
            STATS["total"] += 1
            STATS["by_uri"][raw] = STATS["by_uri"].get(raw, 0) + 1
            STATS["inflight"] += 1
            STATS["max_inflight"] = max(STATS["max_inflight"], STATS["inflight"])
            inflight = STATS["inflight"]
        try:
            delay = float(query.get("delay", ["0"])[0])
            if delay > 0:
                time.sleep(delay)
            status = int(query.get("status", ["200"])[0])

            if "size" in query:
                size = parse_size(query["size"][0])
                self.send_response(status)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(size))
                self.end_headers()
                if not head:
                    left = size
                    while left > 0:
                        n = min(left, len(CHUNK))
                        self.wfile.write(CHUNK[:n])
                        left -= n
                return

            self._json({
                "origin": "lumina-api",
                "method": self.command,
                "uri": raw,
                "host": self.headers.get("Host"),
                "x_real_ip": self.headers.get("X-Real-IP"),
                "x_forwarded_for": self.headers.get("X-Forwarded-For"),
                "body_bytes": body_bytes,
                "inflight": inflight,
                "status": status,
            }, status, head)
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            with LOCK:
                STATS["inflight"] -= 1

    def log_message(self, fmt, *args):
        print("%s %s" % (time.strftime("%H:%M:%S"), fmt % args), flush=True)


class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 1024          # listen() backlog: must be set before the constructor calls listen()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=8015)
    ap.add_argument("--bind", default="0.0.0.0")
    args = ap.parse_args()
    server = Server((args.bind, args.port), Origin)
    print("lumina-api listening on %s:%d" % (args.bind, args.port), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()

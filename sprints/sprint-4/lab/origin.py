#!/usr/bin/env python3
"""Sprint 4 cache-aware origin: a slow, countable backend for the Lumina edge.

Every response is a small JSON document saying which URI was asked for, the
Host the origin saw, and how many times this URI has reached the origin. When
the edge serves from cache, that count stops moving.

Query parameters (any path):
    ?delay=2.5          sleep before answering (a slow origin)
    ?status=503         answer with this status code
    ?cc=max-age=60      send this Cache-Control header (no-store, private, ...)
    ?expires=30         send Expires: now + 30 s
    ?accel=30           send X-Accel-Expires: 30 (NGINX-only expiry)
    ?cookie=1           send a Set-Cookie header
    ?vary=Accept-Encoding   send this Vary header
    ?ver=2              change the ETag (a new version of the object)

Every 200 carries ETag and Last-Modified, and conditional requests
(If-None-Match / If-Modified-Since) that still match get 304 Not Modified.

Control endpoints (never cached by a sane edge, never counted):
    /_stats              JSON: requests per URI, 304s, total, TCP connections opened
    /_stats/reset        zero all counters
    /_mode?status=503    every non-control request now answers 503
    /_mode?delay=3       every non-control request now waits 3 s first
    /_mode?drop=1        every non-control request is dropped: the connection closes with no answer
    /_mode               back to normal
"""
import argparse
import hashlib
import json
import threading
import time
from email.utils import formatdate
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

LOCK = threading.Lock()
STATS = {"by_uri": {}, "not_modified": 0, "total": 0, "connections": 0}
MODE = {"status": 0, "delay": 0.0, "drop": 0}
BOOT = time.time()


def bump_connections():
    with LOCK:
        STATS["connections"] += 1


class Origin(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"      # keepalive capable, so upstream reuse is visible
    disable_nagle_algorithm = True     # headers and body go out as separate writes: no 40 ms Nagle/delayed-ACK stall
    server_version = "lumina-origin"
    sys_version = ""

    def setup(self):
        super().setup()
        bump_connections()

    def do_HEAD(self):
        self._handle(head=True)

    def do_GET(self):
        self._handle()

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        self._handle()

    def _send(self, status, body=b"", headers=(), head=False):
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        if status != 304:
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body and not head and status != 304:
            self.wfile.write(body)

    def _json(self, obj, status=200):
        body = (json.dumps(obj, indent=2) + "\n").encode()
        self._send(status, body, [("Cache-Control", "no-store")])

    def _control(self, path, query):
        if path == "/_stats":
            with LOCK:
                return self._json(STATS)
        if path == "/_stats/reset":
            with LOCK:
                STATS.update(by_uri={}, not_modified=0, total=0, connections=0)
            return self._json({"reset": True})
        if path == "/_mode":
            MODE["status"] = int(query.get("status", ["0"])[0])
            MODE["delay"] = float(query.get("delay", ["0"])[0])
            MODE["drop"] = int(query.get("drop", ["0"])[0])
            return self._json({"mode": MODE})
        return self._json({"error": "unknown control endpoint"}, 404)

    def _handle(self, head=False):
        # Python's http.server collapses a leading "//" in self.path; keep the raw URI
        raw = self.requestline.split(" ")[1] if " " in self.requestline else self.path
        parts = urlsplit(raw)
        query = parse_qs(parts.query)
        if parts.path.startswith("/_"):
            return self._control(parts.path, query)

        if MODE["drop"]:
            self.close_connection = True
            return
        delay = float(query.get("delay", ["0"])[0]) + MODE["delay"]
        status = MODE["status"] or int(query.get("status", ["200"])[0])
        if delay > 0:
            time.sleep(delay)

        etag = '"%s"' % hashlib.sha1((parts.path + query.get("ver", ["1"])[0]).encode()).hexdigest()[:16]
        last_modified = formatdate(BOOT, usegmt=True)
        with LOCK:
            STATS["total"] += 1
            if status == 200 and self.headers.get("If-None-Match") == etag:
                STATS["not_modified"] += 1
                hits = STATS["by_uri"].get(raw, 0)
                status = 304
            else:
                hits = STATS["by_uri"][raw] = STATS["by_uri"].get(raw, 0) + 1

        headers = [("X-Origin-Hits", str(hits)), ("ETag", etag), ("Last-Modified", last_modified)]
        if "cc" in query:
            headers.append(("Cache-Control", query["cc"][0]))
        if "expires" in query:
            headers.append(("Expires", formatdate(time.time() + float(query["expires"][0]), usegmt=True)))
        if "accel" in query:
            headers.append(("X-Accel-Expires", query["accel"][0]))
        if "vary" in query:
            headers.append(("Vary", query["vary"][0]))
        if query.get("cookie") == ["1"]:
            headers.append(("Set-Cookie", "lumina_session=%d; Path=/; HttpOnly" % hits))

        body = (json.dumps({
            "origin": "lumina-origin",
            "uri": raw,
            "host": self.headers.get("Host"),
            "status": status,
            "origin_hits": hits,
            "generated_at": time.strftime("%H:%M:%S"),
        }, indent=2) + "\n").encode()
        self._send(status, body, headers, head)

    def log_message(self, fmt, *args):
        print("%s %s" % (time.strftime("%H:%M:%S"), fmt % args), flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=8014)
    ap.add_argument("--bind", default="0.0.0.0")
    args = ap.parse_args()
    server = ThreadingHTTPServer((args.bind, args.port), Origin)
    server.daemon_threads = True
    server.request_queue_size = 128
    print("lumina-origin listening on %s:%d" % (args.bind, args.port), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()

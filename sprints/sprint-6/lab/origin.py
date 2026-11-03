#!/usr/bin/env python3
"""Sprint 6 origin: the Lumina application behind the edge, in two pools, plus a telemetry intake.

One process, three listeners:
    :8016  the "stable" pool (HTTP)
    :8026  the "beta" pool (HTTP)
    :8036  the telemetry intake (raw TCP): answers "ACK <bytes received>" to whatever it reads

Every HTTP response is a small JSON document: which pool answered, the method and URI,
the X-User header it received (or null), and the size of the request body.

Special paths (both pools):
    /api/account         an account record that includes a card number (for masking)
    /downloads/<name>    a small file; ?size=10k makes it bigger
    ?status=N            answer with this status code

Control endpoints (stable port only, never counted):
    /_stats              JSON: requests per pool and URI, the last X-User seen, telemetry connections
    /_stats/reset        zero all counters
    /_revoked            JSON: {"revoked": [jti, ...]}  (what the edge refreshes from)
    /_revoke?jti=ID      add ID to the revocation list
    /_unrevoke?jti=ID    remove ID (or all, without ?jti)
"""
import argparse
import json
import socketserver
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

LOCK = threading.Lock()
STATS = {"by_pool": {"stable": 0, "beta": 0}, "by_uri": {}, "total": 0, "last_x_user": None, "telemetry": 0}
REVOKED = []
ACCOUNT = {
    "account": "ACME-0042",
    "owner": "Alice Example",
    "card": "4111 1111 1111 1111",
    "backup_card": "5500-0000-0000-0004",
    "note": "primary card 4012888888881881, order 1234567890",
}


def parse_size(text):
    text = text.strip().lower()
    mult = {"k": 1024, "m": 1024 * 1024}.get(text[-1:], 1)
    return int(float(text.rstrip("km")) * mult)


def make_handler(pool):
    class Origin(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        disable_nagle_algorithm = True
        server_version = "lumina-app"
        sys_version = ""

        def do_GET(self):
            self._handle()

        def do_POST(self):
            self._handle()

        def do_HEAD(self):
            self._handle(head=True)

        def _send(self, status, body, ctype="application/json", head=False):
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            if not head:
                self.wfile.write(body)

        def _json(self, obj, status=200, head=False):
            self._send(status, (json.dumps(obj, indent=2) + "\n").encode(), head=head)

        def _control(self, path, query):
            jti = query.get("jti", [None])[0]
            with LOCK:
                if path == "/_stats":
                    return self._json(STATS)
                if path == "/_stats/reset":
                    STATS.update(by_pool={"stable": 0, "beta": 0}, by_uri={}, total=0, last_x_user=None, telemetry=0)
                    return self._json({"reset": True})
                if path == "/_revoked":
                    return self._json({"revoked": REVOKED})
                if path == "/_revoke" and jti:
                    if jti not in REVOKED:
                        REVOKED.append(jti)
                    return self._json({"revoked": REVOKED})
                if path == "/_unrevoke":
                    if jti:
                        if jti in REVOKED:
                            REVOKED.remove(jti)
                    else:
                        REVOKED.clear()
                    return self._json({"revoked": REVOKED})
            return self._json({"error": "unknown control endpoint"}, 404)

        def _handle(self, head=False):
            raw = self.requestline.split(" ")[1] if " " in self.requestline else self.path
            parts = urlsplit(raw)
            query = parse_qs(parts.query)
            if parts.path.startswith("/_"):
                if pool != "stable":
                    return self._json({"error": "control endpoints are on the stable port"}, 404)
                return self._control(parts.path, query)

            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length else b""
            x_user = self.headers.get("X-User")
            with LOCK:
                STATS["total"] += 1
                STATS["by_pool"][pool] += 1
                key = "%s %s" % (pool, raw)
                STATS["by_uri"][key] = STATS["by_uri"].get(key, 0) + 1
                STATS["last_x_user"] = x_user
            status = int(query.get("status", ["200"])[0])

            if parts.path.startswith("/downloads/"):
                size = parse_size(query.get("size", ["64"])[0])
                return self._send(status, b"L" * size, "application/octet-stream", head)
            if parts.path == "/api/account":
                return self._json(dict(ACCOUNT, pool=pool, x_user=x_user), status, head)
            self._json({
                "origin": "lumina-app",
                "pool": pool,
                "method": self.command,
                "uri": raw,
                "x_user": x_user,
                "body_bytes": len(body),
                "status": status,
            }, status, head)

        def log_message(self, fmt, *args):
            print("%s %-6s %s" % (time.strftime("%H:%M:%S"), pool, fmt % args), flush=True)

    return Origin


class Telemetry(socketserver.BaseRequestHandler):
    def handle(self):
        with LOCK:
            STATS["telemetry"] += 1
        self.request.settimeout(2)
        got = b""
        try:
            while b"\n" not in got and len(got) < 65536:
                chunk = self.request.recv(4096)
                if not chunk:
                    break
                got += chunk
            line = got.split(b"\n", 1)[0].decode(errors="replace").strip()
            print("%s telem  %s" % (time.strftime("%H:%M:%S"), line), flush=True)
            self.request.sendall(b"ACK %d\n" % len(got))
        except OSError:
            pass


class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 1024


class TcpServer(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--stable", type=int, default=8016)
    ap.add_argument("--beta", type=int, default=8026)
    ap.add_argument("--telemetry", type=int, default=8036)
    args = ap.parse_args()
    beta = Server(("0.0.0.0", args.beta), make_handler("beta"))
    tel = TcpServer(("0.0.0.0", args.telemetry), Telemetry)
    threading.Thread(target=beta.serve_forever, daemon=True).start()
    threading.Thread(target=tel.serve_forever, daemon=True).start()
    stable = Server(("0.0.0.0", args.stable), make_handler("stable"))
    print("lumina-app: stable :%d, beta :%d, telemetry :%d" % (args.stable, args.beta, args.telemetry), flush=True)
    stable.serve_forever()


if __name__ == "__main__":
    main()

"""Copperline Transit demo app (Sprint 8): one small HTTP service, many roles.

Runs from a ConfigMap on the stock python:3.12-alpine image. Every answer is JSON
naming the app, version and pod that served it.

  ANY  /<anything>          echo: app, version, pod, node, method, path, selected headers
  GET  /healthz             readiness: 200, or 503 while "unready" is on
  ANY  .../slow?ms=N        answer after N ms (any path with a "slow" segment)
  ANY  .../status/NNN       answer with status NNN

Switches, only at the pod itself (the path must START with /_ctl/, so they can't be
reached through the ingress, where paths start with /arrivals, /fares, ...):
  POST /_ctl/fail?on=1|0     every answer except /healthz becomes 500 (a half-broken pod)
  POST /_ctl/unready?on=1|0  /healthz answers 503
  GET  /_ctl/stats           requests served, current switches

Env: APP, VERSION, POD_NAME, NODE_NAME, POD_IP (from the Downward API), PORT (8080),
     STARTUP_DELAY (seconds before it starts listening),
     SHUTDOWN_DRAIN (seconds it keeps serving after SIGTERM; default 0 = exit at once,
     like many real applications),
     ANNOUNCE_CLOSE (1 = say "Connection: close" when closing after a response, as
     real servers do; 0 = close silently: see recap_notes.md, the keepalive trap).
"""
import json, os, signal, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

APP = os.environ.get("APP", "app")
VERSION = os.environ.get("VERSION", "v1")
POD = os.environ.get("POD_NAME", os.uname().nodename)
NODE = os.environ.get("NODE_NAME", "?")
POD_IP = os.environ.get("POD_IP", "?")
STATE = {"fail": False, "unready": False, "served": 0}
SHOW = ("host", "x-forwarded-for", "x-real-ip", "x-forwarded-proto", "x-forwarded-host",
        "x-request-id", "x-canary", "x-user", "x-tier", "authorization", "cookie")


class Server(ThreadingHTTPServer):
    request_queue_size = 512
    daemon_threads = True


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *a):
        sys.stdout.write("%s:%s %s\n" % (self.client_address[0], self.client_address[1], fmt % a))
        sys.stdout.flush()

    def send(self, code, obj):
        body = (json.dumps(obj, indent=1) + "\n").encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Served-By", POD)
        if os.environ.get("ANNOUNCE_CLOSE", "1") == "1" and self.close_connection:
            self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def handle_any(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        if u.path == "/_ctl/stats":
            return self.send(200, {"pod": POD, **STATE})
        if u.path.startswith("/_ctl/"):
            on = q.get("on", ["1"])[0] == "1"
            STATE[u.path[6:]] = on
            return self.send(200, {"pod": POD, u.path[6:]: on})
        if u.path == "/healthz":
            if STATE["unready"]:
                return self.send(503, {"pod": POD, "ready": False})
            return self.send(200, {"pod": POD, "ready": True})
        STATE["served"] += 1
        if STATE["fail"]:
            return self.send(500, {"app": APP, "version": VERSION, "pod": POD, "error": "failing"})
        code = 200
        parts = u.path.split("/")
        if "status" in parts[:-1]:
            code = int(parts[parts.index("status") + 1])
        if "slow" in parts:
            time.sleep(int(q.get("ms", ["1000"])[0]) / 1000)
        self.send(code, {
            "app": APP, "version": VERSION, "pod": POD, "node": NODE, "pod_ip": POD_IP,
            "method": self.command, "path": self.path, "client": self.client_address[0],
            "body_bytes": len(body),
            "headers": {k: v for k, v in self.headers.items() if k.lower() in SHOW},
        })

    do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = do_PATCH = handle_any


def main():
    delay = float(os.environ.get("STARTUP_DELAY", "0"))
    if delay:
        print(f"starting in {delay}s", flush=True)
        time.sleep(delay)
    srv = Server(("0.0.0.0", int(os.environ.get("PORT", "8080"))), H)
    drain = float(os.environ.get("SHUTDOWN_DRAIN", "0"))

    def on_term(*_):
        print(f"SIGTERM: draining {drain}s then exit", flush=True)
        def stop():
            time.sleep(drain)
            os._exit(0)
        threading.Thread(target=stop, daemon=True).start()
    signal.signal(signal.SIGTERM, on_term)
    print(f"{APP} {VERSION} on {POD} listening", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()

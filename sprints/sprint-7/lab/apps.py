"""Sprint 7 lab: Tidewater Logistics' applications, all in one container (s7-apps, 10.57.0.20).

  :9001  partners  the partner API behind the mTLS edge; reports the partner identity it received
  :9002  ops       the internal ops tool; reports the ops user and role it received
  :9003  portal    the staff portal behind single sign-on; reports the user, groups and cookies it received
  :9100  authz     the ops tool's authorization service, for auth_request (GET /check)
  :9443  ledger    the finance ledger, HTTPS only, and only for clients with a certificate from the
                   Tidewater Internal CA (the edge's client certificate)
  :8017  control   counters and switches for the lab (published on 127.0.0.1:8017)

Every service answers any path with JSON. Nothing here is hardened: it's a lab backend.
"""
import json
import os
import ssl
import tempfile
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CERTS = "/lab/certs"
TOKENS_FILE = "/lab/secrets/ops_tokens.json"

lock = threading.Lock()
stats = {"requests": {}, "authz": {"calls": 0, "by_user": {}}}
ledger_mode = {"impostor": False}


def count(service, method, uri):
    key = f"{service} {method} {urllib.parse.urlsplit(uri).path}"
    with lock:
        stats["requests"][key] = stats["requests"].get(key, 0) + 1


def cert_names(escaped_pem):
    """Subject alternative names of a PEM certificate forwarded URL-escaped by the edge."""
    if not escaped_pem:
        return None
    pem = urllib.parse.unquote(escaped_pem)
    with tempfile.NamedTemporaryFile("w", suffix=".pem", delete=False) as f:
        f.write(pem)
        path = f.name
    try:
        info = ssl._ssl._test_decode_cert(path)
        return [f"{kind}:{value}" for kind, value in info.get("subjectAltName", ())]
    except Exception:
        return ["unreadable certificate"]
    finally:
        os.unlink(path)


class Base(BaseHTTPRequestHandler):
    service = "?"
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def send_json(self, status, obj, headers=None):
        data = (json.dumps(obj, indent=1) + "\n").encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def answer(self, body):
        raise NotImplementedError

    def handle_any(self):
        body = self.body()
        if self.service != "authz":
            count(self.service, self.command, self.path)
        self.answer(body)

    def do_GET(self): self.handle_any()
    do_POST = do_PUT = do_DELETE = do_PATCH = do_HEAD = do_GET


class Partners(Base):
    service = "partners"

    def answer(self, body):
        h = self.headers
        self.send_json(200, {
            "service": "partners", "method": self.command, "uri": self.path,
            "partner": h.get("X-Partner"),
            "partner_dn": h.get("X-Partner-DN"),
            "partner_verify": h.get("X-Partner-Verify"),
            "partner_cert_names": cert_names(h.get("X-Partner-Cert")),
        })


class Ops(Base):
    service = "ops"

    def answer(self, body):
        h = self.headers
        self.send_json(200, {
            "service": "ops", "method": self.command, "uri": self.path,
            "ops_user": h.get("X-Ops-User"), "ops_role": h.get("X-Ops-Role"),
            "token_received": bool(h.get("Authorization")),
            "body_bytes": len(body),
        })


class Portal(Base):
    service = "portal"

    def answer(self, body):
        h = self.headers
        cookies = [c.split("=", 1)[0].strip() for c in (h.get("Cookie") or "").split(";") if c.strip()]
        self.send_json(200, {
            "service": "portal", "method": self.command, "uri": self.path,
            "user": h.get("X-User"), "email": h.get("X-Email"), "groups": h.get("X-Groups"),
            "cookies_received": cookies,
        })


def load_tokens():
    try:
        with open(TOKENS_FILE) as f:
            return json.load(f)
    except Exception:
        return {}


class Authz(Base):
    """GET /check: who is this, and may they do this?

    The credential is "Authorization: Bearer <token>". The method being authorized is
    X-Original-Method if the edge sends it, otherwise the method of the check itself.
    Viewers may read (GET, HEAD); admins may do anything.
    """
    service = "authz"

    def answer(self, body):
        path = urllib.parse.urlsplit(self.path).path
        if path == "/slow":
            time.sleep(3)
            return self.send_json(200, {"slow": True})
        if path != "/check":
            return self.send_json(404, {"error": "no such endpoint", "path": path})
        auth = self.headers.get("Authorization") or ""
        token = auth[7:].strip() if auth.lower().startswith("bearer ") else ""
        who = load_tokens().get(token) if token else None
        method = self.headers.get("X-Original-Method") or self.command
        with lock:
            stats["authz"]["calls"] += 1
            name = who["user"] if who else ("(none)" if not token else "(unknown)")
            stats["authz"]["by_user"][name] = stats["authz"]["by_user"].get(name, 0) + 1
            stats["authz"]["last"] = {"user": name, "method_seen": self.command,
                                      "x_original_method": self.headers.get("X-Original-Method"),
                                      "x_original_uri": self.headers.get("X-Original-URI"),
                                      "content_length": self.headers.get("Content-Length")}
        if not who:
            return self.send_json(401, {"error": "no valid ops token"},
                                  {"WWW-Authenticate": 'Bearer realm="tidewater-ops"'})
        if who["role"] != "admin" and method not in ("GET", "HEAD"):
            return self.send_json(403, {"error": f"{who['role']} may not {method}"},
                                  {"X-Ops-User": who["user"], "X-Ops-Role": who["role"]})
        self.send_json(200, {"ok": True}, {"X-Ops-User": who["user"], "X-Ops-Role": who["role"]})


class Ledger(Base):
    service = "ledger"
    served_as = "ledger"

    def answer(self, body):
        cert = self.connection.getpeercert() or {}
        subject = ",".join(f"{k}={v}" for rdn in cert.get("subject", ()) for k, v in rdn)
        self.send_json(200, {
            "service": "ledger", "method": self.command, "uri": self.path,
            "client_certificate": subject or None,
            "served_as": self.served_as,
        })


def ledger_context(name):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(f"{CERTS}/{name}.crt", f"{CERTS}/{name}.key")
    ctx.load_verify_locations(f"{CERTS}/internal-ca.crt")
    ctx.verify_mode = ssl.CERT_REQUIRED
    return ctx


class LedgerServer(ThreadingHTTPServer):
    """HTTPS, client certificate required. The handshake runs in the request's thread."""
    context = None

    def get_request(self):
        sock, addr = self.socket.accept()
        return self.context.wrap_socket(sock, server_side=True, do_handshake_on_connect=False), addr

    def handle_error(self, request, client_address):
        pass  # failed handshakes (no client certificate, untrusted server) are expected in the lab


def run_ledger(name, port):
    """One TLS server per process, so the impostor shares nothing (no session cache, no ticket keys)."""
    LedgerServer.context = ledger_context(name)
    Ledger.served_as = name
    server = LedgerServer(("127.0.0.1", port), Ledger)
    server.daemon_threads = True
    server.serve_forever()


relayed = set()  # open relay connections, cut when the ledger switches


def cut_relays():
    import socket
    with lock:
        socks = list(relayed)
    for x in socks:
        try:
            x.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass


def relay(client):
    """:9443 is a TCP relay: to the real ledger (:9445) or, in impostor mode, to the impostor (:9444).
    Switching cuts the open connections, like moving the ledger's address to another server would."""
    import socket
    with lock:
        relayed.add(client)
    try:
        upstream = socket.create_connection(("127.0.0.1", 9444 if ledger_mode["impostor"] else 9445))
    except OSError:
        with lock:
            relayed.discard(client)
        client.close()
        return

    def pipe(a, b):
        try:
            while True:
                data = a.recv(65536)
                if not data:
                    break
                b.sendall(data)
        except OSError:
            pass
        finally:
            for x in (a, b):
                try:
                    x.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass

    threading.Thread(target=pipe, args=(client, upstream), daemon=True).start()
    pipe(upstream, client)
    with lock:
        relayed.discard(client)
    client.close()
    upstream.close()


def serve_relay(port):
    import socket
    ls = socket.socket()
    ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    ls.bind(("", port))
    ls.listen(128)
    while True:
        c, _ = ls.accept()
        threading.Thread(target=relay, args=(c,), daemon=True).start()


class Control(Base):
    service = "control"

    def handle_any(self):
        self.body()
        u = urllib.parse.urlsplit(self.path)
        q = urllib.parse.parse_qs(u.query)
        if u.path == "/_stats":
            with lock:
                return self.send_json(200, {**stats, "ledger_impostor": ledger_mode["impostor"]})
        if u.path == "/_stats/reset":
            with lock:
                stats["requests"].clear()
                stats["authz"] = {"calls": 0, "by_user": {}}
            return self.send_json(200, {"reset": True})
        if u.path == "/_ledger/impostor":
            ledger_mode["impostor"] = q.get("on", ["1"])[0] == "1"
            cut_relays()
            return self.send_json(200, {"ledger_impostor": ledger_mode["impostor"]})
        self.send_json(404, {"error": "unknown control path"})


def serve(server):
    server.daemon_threads = True
    server.request_queue_size = 128
    threading.Thread(target=server.serve_forever, daemon=True).start()


if __name__ == "__main__":
    for port, handler in ((9001, Partners), (9002, Ops), (9003, Portal), (9100, Authz), (8017, Control)):
        serve(ThreadingHTTPServer(("", port), handler))
    import multiprocessing
    for name, port in (("ledger", 9445), ("impostor", 9444)):
        multiprocessing.Process(target=run_ledger, args=(name, port), daemon=True).start()
    threading.Thread(target=serve_relay, args=(9443,), daemon=True).start()
    print("tidewater apps: partners :9001, ops :9002, portal :9003, authz :9100, ledger :9443 (TLS), control :8017")
    while True:
        time.sleep(3600)

#!/usr/bin/env python3
"""Northwind storefront origin for the Black Friday war room.

Shopper paths (what the edges proxy):
  GET  /catalog/<cat>/            a category page: its products and their prices
  GET  /catalog/<cat>/<sku>       a product page with its price
  GET  /doorbuster/<sku>          a doorbuster deal (VIP early access is enforced at the edge)
  POST /checkout                  place an order
  GET  /healthz                   ok

Catalog and product pages are cacheable for a day (Cache-Control: max-age=86400), so nothing expires during the war room.
Everything else is private. Every response says which edge asked (X-Edge, if sent) and
carries X-Origin-Hits: how many times this exact URI has reached the origin.

War-room controls (only from the host, 10.58.0.1, or the war room's client, 10.58.0.2;
an edge that forwards them gets 403):
  POST /_ops/reprice?sku=S&price=P      change one price
  POST /_ops/reprice?cat=C&pct=N        change every price in a category by N percent
  GET  /_ops/stats[?prefix=/catalog/]   requests per URI (and the total under prefix)
  POST /_ops/reset                      prices back to the list, counters to zero
"""
import argparse
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

LIST_PRICES = {
    "tvs": {"tv-55": 399.00, "tv-65": 649.00, "tv-77": 1299.00},
    "laptops": {"laptop-13": 899.00, "laptop-15": 1199.00},
    "headphones": {"hp-pro": 249.00, "hp-lite": 79.00},
}
DOORBUSTERS = {"tv-65": 299.00, "laptop-13": 499.00}

OPS_CLIENTS = {"10.58.0.1", "10.58.0.2", "127.0.0.1"}

lock = threading.Lock()
prices = {}
hits = {}


def reset():
    with lock:
        prices.clear()
        for cat, items in LIST_PRICES.items():
            prices[cat] = dict(items)
        hits.clear()


def find(sku):
    for cat, items in prices.items():
        if sku in items:
            return cat
    return None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "northwind-origin"
    sys_version = ""

    def log_message(self, fmt, *args):
        pass

    def send(self, status, body, cache=None, extra=None):
        data = (json.dumps(body, indent=1) + "\n").encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", cache or "private, no-store")
        self.send_header("X-Origin-Hits", str(self.count))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def route(self):
        u = urlsplit(self.path)
        q = {k: v[-1] for k, v in parse_qs(u.query).items()}
        parts = [p for p in u.path.split("/") if p]
        if u.path.startswith("/_ops/"):
            self.count = 0
            if self.client_address[0] not in OPS_CLIENTS:
                return self.send(403, {"error": "war-room controls are not reachable through an edge"})
            return self.ops(u.path, q)
        with lock:
            hits[self.path] = hits.get(self.path, 0) + 1
            self.count = hits[self.path]
        edge = self.headers.get("X-Edge", "")
        if u.path == "/healthz":
            return self.send(200, {"status": "ok"})
        if self.command in ("GET", "HEAD") and len(parts) >= 2 and parts[0] == "catalog":
            cat = parts[1]
            with lock:
                items = dict(prices.get(cat, {}))
            if not items:
                return self.send(404, {"error": "no such category"})
            if len(parts) == 2:
                return self.send(200, {"category": cat, "products": items, "edge": edge}, "public, max-age=86400")
            sku = parts[2]
            if sku not in items:
                return self.send(404, {"error": "no such product"})
            return self.send(200, {"sku": sku, "price": items[sku], "edge": edge}, "public, max-age=86400")
        if self.command in ("GET", "HEAD") and len(parts) == 2 and parts[0] == "doorbuster":
            sku = parts[1]
            if sku not in DOORBUSTERS:
                return self.send(404, {"error": "no such deal"})
            return self.send(200, {"deal": sku, "price": DOORBUSTERS[sku], "member": self.headers.get("X-Member", ""), "edge": edge})
        if self.command == "POST" and u.path == "/checkout":
            n = int(self.headers.get("Content-Length") or 0)
            if n:
                self.rfile.read(n)
            return self.send(200, {"order": "accepted", "edge": edge})
        return self.send(404, {"error": "not found"})

    def ops(self, path, q):
        if path == "/_ops/reprice" and self.command == "POST":
            with lock:
                if "sku" in q:
                    cat = find(q["sku"])
                    if not cat:
                        return self.send(404, {"error": "no such sku"})
                    prices[cat][q["sku"]] = round(float(q["price"]), 2)
                    return self.send(200, {"repriced": {q["sku"]: prices[cat][q["sku"]]}})
                cat = q.get("cat")
                if cat not in prices:
                    return self.send(404, {"error": "no such category"})
                pct = float(q.get("pct", "0"))
                for sku in prices[cat]:
                    prices[cat][sku] = round(prices[cat][sku] * (1 + pct / 100), 2)
                return self.send(200, {"repriced": dict(prices[cat])})
        if path == "/_ops/stats":
            prefix = q.get("prefix", "")
            with lock:
                by_uri = {k: v for k, v in sorted(hits.items()) if k.startswith(prefix)}
            return self.send(200, {"total": sum(by_uri.values()), "by_uri": by_uri})
        if path == "/_ops/reset" and self.command == "POST":
            reset()
            return self.send(200, {"reset": True})
        if path == "/_ops/prices":
            with lock:
                return self.send(200, json.loads(json.dumps(prices)))
        return self.send(404, {"error": "no such control"})

    do_GET = do_HEAD = do_POST = do_PURGE = do_DELETE = route


class Server(ThreadingHTTPServer):
    request_queue_size = 256      # the listen() backlog; the default of 5 drops connections under load
    daemon_threads = True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8020)
    args = ap.parse_args()
    reset()
    srv = Server(("0.0.0.0", args.port), Handler)
    srv.serve_forever()


if __name__ == "__main__":
    main()

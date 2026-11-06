#!/usr/bin/env python3
"""Black Friday war room: tickets, checks and the scoreboard.

Runs inside the bf-client container (./warroom.sh wraps it). The client can send from any
10.58.x.y address, so a check can be a shopper, a bot, the partner or the ops team.

    next            open the next ticket
    check           check the open ticket, then that the solved ones still hold
    board           the scoreboard
    answer VALUE    answer the open ticket's question
    skip            give up on the open ticket
    token ID [TTL]  a member cookie value
"""
import hashlib
import hmac
import http.client
import json
import os
import random
import re
import subprocess
import sys
import threading
import time

LB = ("10.58.0.10", 8100)
NODES = {"edge-a": "10.58.0.11", "edge-b": "10.58.0.12"}
ORIGIN = ("10.58.0.20", 8020)
LUA = ("10.58.0.30", 8080)
OPS = "10.58.0.5"
BOTS = "10.58.66.0/24"
PARTNER = "10.58.66.77"
STATE = "/state/board.json"
KEY_FILE = "/lab/secrets/shop.key"
EDITION = os.environ.get("EDITION", "")

G, R, Y, B, D, N = "\033[0;32m", "\033[0;31m", "\033[1;33m", "\033[1m", "\033[2m", "\033[0m"

TICKETS = {
    1: ("Stage 1: The Cache", "Wrong price on the doorbuster TV"),
    2: ("Stage 1: The Cache", "The whole TV category was repriced"),
    3: ("Stage 1: The Cache", "Is the cache earning its keep?"),
    4: ("Stage 2: Who Gets In", "Scalper bots on checkout"),
    5: ("Stage 2: Who Gets In", "A partner caught in the block"),
    6: ("Stage 2: Who Gets In", "Two nodes, double the limit"),
    7: ("Stage 3: Code at the Edge", "VIP early access"),
    8: ("Stage 3: Code at the Edge", "Should we move to OpenResty?"),
    9: ("Finale", "Midnight"),
}
GUIDE = {1: "stage-1-cache.md", 2: "stage-1-cache.md", 3: "stage-1-cache.md",
         4: "stage-2-limits.md", 5: "stage-2-limits.md", 6: "stage-2-limits.md",
         7: "stage-3-edge-code.md", 8: "stage-3-edge-code.md", 9: "finale.md"}
POINTS, FIRST_TRY_BONUS, FINALE_POINTS = 100, 25, 200


# ---------------------------------------------------------------- plumbing

def ensure_ip(ip):
    have = subprocess.run(["ip", "-o", "-4", "addr", "show", "dev", "eth0"], capture_output=True, text=True).stdout
    if " %s/" % ip not in have:
        subprocess.run(["ip", "addr", "add", ip + "/16", "dev", "eth0"], stderr=subprocess.DEVNULL)


def req(method, target, path, src=None, headers=None, body=None, timeout=6):
    """One request on its own connection. Returns (status, {lowercase header: value}, body text)."""
    host, port = target
    if src:
        ensure_ip(src)
    try:
        c = http.client.HTTPConnection(host, port, timeout=timeout, source_address=(src, 0) if src else None)
        h = {"Connection": "close"}
        h.update(headers or {})
        if body is not None and not isinstance(body, bytes):
            body = body.encode()
        c.request(method, path, body=body, headers=h)
        r = c.getresponse()
        data = r.read().decode(errors="replace")
        hdrs = {k.lower(): v for k, v in r.getheaders()}
        c.close()
        return r.status, hdrs, data
    except (OSError, http.client.HTTPException) as e:
        return 0, {}, str(e)


def node(name):
    return (NODES[name], 8080)


def jget(text):
    try:
        return json.loads(text)
    except ValueError:
        return {}


def origin_prices():
    st, _, body = req("GET", ORIGIN, "/_ops/prices")
    return jget(body) if st == 200 else {}


def reprice(**q):
    path = "/_ops/reprice?" + "&".join("%s=%s" % kv for kv in q.items())
    return req("POST", ORIGIN, path)[0] == 200


def catalog_urls():
    urls = []
    for cat, items in origin_prices().items():
        urls.append("/catalog/%s/" % cat)
        urls.extend("/catalog/%s/%s" % (cat, sku) for sku in items)
    return urls


def served_price(st, body, sku):
    d = jget(body)
    if "price" in d:
        return d["price"]
    return d.get("products", {}).get(sku)


def warm():
    """Every catalog page into both nodes' caches (and the client's view of them)."""
    for name in NODES:
        for u in catalog_urls():
            req("GET", node(name), u, src=shopper())


def lab_key():
    with open(KEY_FILE) as f:
        return f.read().strip()


def token(member, ttl=900, key=None):
    exp = int(time.time()) + ttl
    msg = "%s.%d" % (member, exp)
    sig = hmac.new((key or lab_key()).encode(), msg.encode(), hashlib.sha256).hexdigest()
    return "%s.%s" % (msg, sig)


def load():
    try:
        with open(STATE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {"edition": EDITION, "current": None, "next": 1, "tickets": {}, "seq": 0}


def save(b):
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(b, f, indent=1)
    os.replace(tmp, STATE)


BOARD = None


def fresh_ip(base=110):
    """A client address nobody has used yet (limits and caches have no memory of it)."""
    BOARD["seq"] = BOARD.get("seq", 0) + 1
    s = BOARD["seq"] + int(time.time()) % 5000
    return "10.58.%d.%d" % (base + (s // 250) % 40, s % 250 + 1)


def shopper():
    return "10.58.100.%d" % random.randint(2, 250)


def log_lines(name, kind="error"):
    try:
        with open("/lab/logs/%s/%s.log" % (name, kind), errors="replace") as f:
            return f.readlines()
    except OSError:
        return []


def marks():
    return {n: len(log_lines(n)) for n in NODES}


def starts():
    return dict(kv.split("=", 1) for kv in os.environ.get("STARTS", "").split() if "=" in kv)


def reloads_since(t):
    """How many reloads or restarts each node had since the ticket opened."""
    out = {}
    now = starts()
    for n in NODES:
        lines = log_lines(n)[t["marks"].get(n, 0):]
        count = sum(1 for l in lines if "reconfiguring" in l)
        if now.get(n) != t["starts"].get(n):
            count += 1
        out[n] = count
    return out


class Check:
    def __init__(self):
        self.results = []

    def ok(self, text):
        self.results.append((True, text, ""))

    def fail(self, text, detail=""):
        self.results.append((False, text, detail))

    def expect(self, cond, text, detail=""):
        self.results.append((bool(cond), text, "" if cond else detail))
        return cond

    @property
    def passed(self):
        return all(r[0] for r in self.results) and bool(self.results)

    def show(self, indent="  "):
        for good, text, detail in self.results:
            print("%s%s %s" % (indent, G + "[PASS]" + N if good else R + "[FAIL]" + N, text))
            if detail and not good:
                print("%s       %s%s%s" % (indent, D, detail, N))


def until(fn, secs=3.5, every=0.25):
    end = time.time() + secs
    while True:
        v = fn()
        if v or time.time() > end:
            return v
        time.sleep(every)


def statuses(method, target, path, src, n=4, headers=None, body=None):
    """n requests; returns (list of statuses, set of X-Edge values)."""
    sts, edges = [], set()
    for _ in range(n):
        st, h, _ = req(method, target, path, src=src, headers=headers, body=body)
        sts.append(st)
        if h.get("x-edge"):
            edges.add(h["x-edge"])
    return sts, edges


# ---------------------------------------------------------------- Plus API

API_VERSION = {}


def api(name, method, path, data=None, src=OPS):
    host = NODES[name]
    if name not in API_VERSION:
        st, _, body = req("GET", (host, 8085), "/api/", src=src)
        vs = jget(body) if st == 200 else []
        API_VERSION[name] = max(vs) if isinstance(vs, list) and vs else 9
    body = json.dumps(data) if data is not None else None
    hdrs = {"Content-Type": "application/json"} if body else None
    return req(method, (host, 8085), "/api/%d%s" % (API_VERSION[name], path), src=src, headers=hdrs, body=body)


def kv_set(name, zone, key, value):
    """Add or update one key: POST adds (409 if it exists), PATCH updates."""
    st, _, body = api(name, "POST", "/http/keyvals/%s" % zone, {key: value})
    if st == 409:
        st, _, body = api(name, "PATCH", "/http/keyvals/%s" % zone, {key: value})
    return st, body


# ---------------------------------------------------------------- tickets

def open_1(b):
    req("POST", ORIGIN, "/_ops/reset")          # a new war room: list prices, zero counters
    warm()
    reprice(sku="tv-65", price="599.00")
    return "tv-65 is cached at $649 on both nodes. Merchandising fixed it to $599 at the origin."


def check_1(c, regression=False):
    prices = origin_prices()
    want = prices.get("tvs", {}).get("tv-65")
    if not regression:
        for n in NODES:
            st, h, body = req("GET", node(n), "/catalog/tvs/tv-65", src=shopper())
            c.expect(st == 200 and served_price(st, body, "tv-65") == want,
                     "%s serves tv-65 at the origin's price ($%s)" % (n, want),
                     "got HTTP %s, price %s, cache %s" % (st, served_price(st, body, "tv-65"), h.get("x-cache-status")))
    # The mechanism: reprice another product, invalidate it as ops on each node, see the new price
    old = prices.get("headphones", {}).get("hp-lite", 79.0)
    new = round(old + (1 if int(old) % 2 == 0 else -1), 2)
    for n in NODES:
        req("GET", node(n), "/catalog/headphones/hp-lite", src=shopper())
        req("GET", node(n), "/catalog/laptops/laptop-13", src=shopper())
    reprice(sku="hp-lite", price="%.2f" % new)
    for n in NODES:
        if EDITION == "plus":
            st, _, _ = req("PURGE", node(n), "/catalog/headphones/hp-lite", src=OPS)
        else:
            st, _, _ = req("GET", node(n), "/catalog/headphones/hp-lite", src=OPS, headers={"X-Refresh": "1"})
        st, h, body = req("GET", node(n), "/catalog/headphones/hp-lite", src=shopper())
        c.expect(served_price(st, body, "hp-lite") == new,
                 "%s: after ops invalidates a repriced product, shoppers get the new price" % n,
                 "hp-lite repriced to $%s at the origin; %s still served %s (cache %s)"
                 % (new, n, served_price(st, body, "hp-lite"), h.get("x-cache-status")))
        st, h, _ = req("GET", node(n), "/catalog/laptops/laptop-13", src=shopper())
        c.expect(h.get("x-cache-status") == "HIT", "%s: the rest of the cache is untouched (laptop-13 still a HIT)" % n,
                 "laptop-13 came back %s" % h.get("x-cache-status"))
    # Nobody else can do it: a shopper straight at a node, and a shopper through the LB pretending to be ops
    before = jget(req("GET", ORIGIN, "/_ops/stats?prefix=/catalog/laptops/laptop-13")[2]).get("total", 0)
    tries = [(node("edge-a"), {}), (LB, {"X-Forwarded-For": OPS})]
    for target, extra in tries:
        who = "a shopper at edge-a" if target != LB else "a shopper via the LB claiming X-Forwarded-For: %s" % OPS
        if EDITION == "plus":
            st, _, _ = req("PURGE", target, "/catalog/laptops/laptop-13", src=shopper(), headers=extra)
            c.expect(st == 403, "PURGE from %s is refused with 403" % who, "got HTTP %s" % st)
        else:
            hdrs = dict(extra, **{"X-Refresh": "1"})
            st, h, _ = req("GET", target, "/catalog/laptops/laptop-13", src=shopper(), headers=hdrs)
            c.expect(st == 200 and h.get("x-cache-status") == "HIT",
                     "X-Refresh from %s is ignored (served from cache)" % who,
                     "got HTTP %s, cache %s" % (st, h.get("x-cache-status")))
    after = jget(req("GET", ORIGIN, "/_ops/stats?prefix=/catalog/laptops/laptop-13")[2]).get("total", 0)
    c.expect(after == before, "those attempts never reached the origin", "the origin saw laptop-13 %d more time(s)" % (after - before))


CONTROL = ["/catalog/laptops/", "/catalog/laptops/laptop-13", "/catalog/laptops/laptop-15", "/catalog/headphones/hp-pro"]


def open_2(b):
    warm()
    reprice(cat="tvs", pct="-10")
    return "Every TV dropped 10% at the origin. The edges still serve the old prices for all of /catalog/tvs/."


def check_2(c, regression=False):
    prices = origin_prices().get("tvs", {})
    stale = []
    for n in NODES:
        st, _, body = req("GET", node(n), "/catalog/tvs/", src=shopper())
        if jget(body).get("products") != prices:
            stale.append("%s /catalog/tvs/" % n)
        for sku, p in prices.items():
            st, _, body = req("GET", node(n), "/catalog/tvs/%s" % sku, src=shopper())
            if served_price(st, body, sku) != p:
                stale.append("%s %s (%s, not %s)" % (n, sku, served_price(st, body, sku), p))
    c.expect(not stale, "every page under /catalog/tvs/ serves the origin's prices on both nodes", "stale: " + ", ".join(stale[:4]))
    if regression:
        return
    misses = []
    for n in NODES:
        for u in CONTROL:
            st, h, _ = req("GET", node(n), u, src=shopper())
            if h.get("x-cache-status") != "HIT":
                misses.append("%s %s (%s)" % (n, u, h.get("x-cache-status")))
    c.expect(not misses, "the other categories were not thrown away (still HITs on both nodes)",
             "not cached any more: " + ", ".join(misses[:4]))
    if EDITION == "plus":
        r = reloads_since(BOARD["tickets"]["2"])
        c.expect(not any(r.values()), "no reload or restart since the ticket opened",
                 "reloads/restarts: %s" % ", ".join("%s %d" % kv for kv in r.items()))


def open_3(b):
    if EDITION == "plus":
        return "Finance wants cache numbers per node, live, for the ops team's dashboards."
    return "Finance wants cache numbers per node. The access logs are all you have."


def check_3(c, regression=False):
    probe = "probe=%d" % random.randint(10**6, 10**7)
    if EDITION == "plus":
        for n in NODES:
            st, _, body = api(n, "GET", "/http/caches/shop")
            d = jget(body)
            if not c.expect(st == 200 and "hit" in d, "%s: ops can read the shop cache's numbers from the API" % n,
                            "GET http://%s:8085/api/%s/http/caches/shop as ops: HTTP %s" % (n, API_VERSION.get(n), st)):
                continue
            before = d["hit"]["responses"]
            for _ in range(5):
                req("GET", node(n), "/catalog/headphones/hp-pro", src=shopper())
            d = jget(api(n, "GET", "/http/caches/shop")[2])
            after = d.get("hit", {}).get("responses", before)
            c.expect(after - before >= 5, "%s: the hit counter follows real traffic" % n,
                     "5 cached requests, hits went %s -> %s" % (before, after))
            st, _, _ = req("GET", (NODES[n], 8085), "/api/", src=shopper())
            c.expect(st == 403, "%s: a shopper connecting to :8085 is refused (403)" % n, "got HTTP %s" % st)
        return
    for n in NODES:
        p = "/catalog/headphones/hp-pro?" + probe
        req("GET", node(n), p, src=shopper())
        req("GET", node(n), p, src=shopper())
        req("GET", node(n), "/healthz?" + probe, src=shopper())
        time.sleep(0.3)
        lines = [l for l in log_lines(n, "access") if probe in l]
        got = [re.search(r"cache=(\S+)", l).group(1) if re.search(r"cache=(\S+)", l) else "?" for l in lines]
        c.expect(got == ["MISS", "HIT", "-"], "%s: its access log records each request's cache result as cache=..." % n,
                 "for a MISS, a HIT and an uncached request, the log had: %s" % (got or "no lines with the probe"))


def open_4(b):
    return "%s is hammering /checkout and scraping the site. Refuse that whole network, on both nodes." % BOTS


TARGETS = (("edge-a", ("10.58.0.11", 8080)), ("edge-b", ("10.58.0.12", 8080)), ("the LB", LB))


def everywhere(method, path, src, n=2, headers=None, body=None):
    """The same request straight at each node and through the load balancer: {target: [statuses]}."""
    return {name: statuses(method, target, path, src, n=n, headers=headers, body=body)[0] for name, target in TARGETS}


def describe(results):
    return "; ".join("%s %s" % (k, v) for k, v in results.items())


def bot_blocked(c, label, src, want=403):
    bad = []
    for method, path, body in (("GET", "/catalog/tvs/", None), ("POST", "/checkout", "{}"), ("GET", "/doorbuster/tv-65", None)):
        res = everywhere(method, path, src, body=body)
        if any(s != want for v in res.values() for s in v):
            bad.append("%s %s: %s" % (method, path, describe(res)))
    c.expect(not bad, label, " | ".join(bad))


def check_4(c, regression=False):
    bot_blocked(c, "the bot network gets 403 everywhere, on both nodes (10.58.66.6)", "10.58.66.6")
    bot_blocked(c, "... and the rest of the range too (10.58.66.200)", "10.58.66.200")
    src = shopper()
    sts, _ = statuses("GET", LB, "/catalog/tvs/", src, n=2)
    sts2, _ = statuses("POST", LB, "/checkout", src, n=2, body="{}")
    c.expect(all(s == 200 for s in sts + sts2), "shoppers are unaffected", "%s got %s" % (src, sts + sts2))
    if EDITION != "plus":
        return
    # The mechanism: the ops team adds a range on one node and the cluster follows, no reload
    st, body = kv_set("edge-b", "denylist", "10.58.67.0/24", "1")
    if not c.expect(st in (201, 204), "ops can add a range to the denylist through edge-b's API",
                    "POST/PATCH http://edge-b:8085/api/.../http/keyvals/denylist: HTTP %s %s" % (st, body.strip()[:120])):
        return
    blocked = until(lambda: req("GET", node("edge-a"), "/catalog/tvs/", src="10.58.67.9")[0] == 403)
    c.expect(blocked, "a range added on edge-b blocks on edge-a within 3 s", "10.58.67.9 still gets through edge-a")
    kv_set("edge-b", "denylist", "10.58.67.0/24", "0")
    allowed = until(lambda: req("GET", node("edge-a"), "/catalog/tvs/", src="10.58.67.9")[0] == 200)
    c.expect(allowed, "setting it to 0 on edge-b lets it back in on edge-a within 3 s", "10.58.67.9 still blocked on edge-a")


def open_5(b):
    return "%s is a price-comparison partner inside the blocked range. Let it in; keep the rest of the range out." % PARTNER


def check_5(c, regression=False):
    res = everywhere("GET", "/catalog/tvs/", PARTNER)
    c.expect(all(s == 200 for v in res.values() for s in v), "the partner (%s) gets in on both nodes" % PARTNER, describe(res))
    bot_blocked(c, "the rest of the bot range is still refused (10.58.66.76)", "10.58.66.76")
    if EDITION == "plus" and not regression:
        r = reloads_since(BOARD["tickets"]["5"])
        c.expect(not any(r.values()), "no reload or restart since the ticket opened",
                 "reloads/restarts: %s" % ", ".join("%s %d" % kv for kv in r.items()))


def pace(path, src, rate, secs, method="POST"):
    sts, edges = [], set()
    t0 = time.time()
    for i in range(int(rate * secs)):
        wait = t0 + i / rate - time.time()
        if wait > 0:
            time.sleep(wait)
        st, h, _ = req(method, LB, path, src=src, body="{}" if method == "POST" else None)
        sts.append(st)
        if h.get("x-edge"):
            edges.add(h["x-edge"])
    return sts, edges


def open_6(b):
    return ("/checkout allows 5 requests/s per shopper (burst 5) on each node. Through the load balancer a shopper "
            "gets about twice that. Make it 5/s for the whole site.")


def check_6(c, regression=False):
    src = fresh_ip()
    sts, edges = pace("/checkout", src, rate=10, secs=6)
    passed = sts.count(200)
    c.expect(passed <= 45, "a shopper sending 10 checkouts/s for 6 s gets about 5/s through (<= 45 of 60)",
             "%d of 60 got 200 (statuses: %s)" % (passed, {s: sts.count(s) for s in set(sts)}))
    c.expect(passed >= 25, "... and is not limited below that (>= 25 of 60)", "%d of 60 got 200" % passed)
    other = fresh_ip()
    sts2, _ = statuses("POST", LB, "/checkout", other, n=3, body="{}")
    c.expect(all(s == 200 for s in sts2), "another shopper checking out at the same time is unaffected", "got %s" % sts2)
    if EDITION == "plus":
        c.expect(len(edges) == 2, "the limited shopper was still spread across both nodes (no pinning)",
                 "all requests went to %s" % "/".join(sorted(edges)))


VIP_CHECK_MEMBER = "vip-check"


def vip_add(member):
    if EDITION == "plus":
        st, body = kv_set("edge-a", "vip", member, "1")
        return [("edge-a API", st)]
    return [(n, req("POST", node(n), "/ops/vip/%s" % member, src=OPS)[0]) for n in NODES]


def vip_remove(member):
    if EDITION == "plus":
        st, body = kv_set("edge-b", "vip", member, "0")
        return [("edge-b API", st)]
    return [(n, req("DELETE", node(n), "/ops/vip/%s" % member, src=OPS)[0]) for n in NODES]


def open_7(b):
    return ("From now until midnight, /doorbuster/ is for VIP members only. Marketing adds and removes "
            "VIPs during the night, and every change must reach both nodes.")


def check_7(c, regression=False):
    m = "vip-%d" % random.randint(1000, 9999)
    cookie = {"Cookie": "nw_member=" + token(m)}
    src = shopper()
    res = everywhere("GET", "/doorbuster/tv-65", src, headers=cookie)
    c.expect(all(s == 403 for v in res.values() for s in v), "a member who isn't a VIP gets 403 on /doorbuster/", describe(res))
    sts, _ = statuses("GET", LB, "/doorbuster/tv-65", src, n=2)
    c.expect(all(s == 403 for s in sts), "no member cookie: 403", "got %s" % sts)
    added = vip_add(m)
    c.expect(all(200 <= st < 300 for _, st in added), "ops adds a VIP (%s)" % ("edge-a's API" if EDITION == "plus" else "POST /ops/vip/<id> on each node"),
             ", ".join("%s: HTTP %s" % a for a in added))
    def all_in():
        return all(x == 200 for v in everywhere("GET", "/doorbuster/tv-65", src, headers=cookie).values() for x in v)
    c.expect(until(all_in), "the new VIP gets in on both nodes within 3 s", "still refused somewhere")
    st, _, body = req("GET", LB, "/doorbuster/tv-65", src=src, headers=cookie)
    c.expect(jget(body).get("member") == m, "the origin sees the verified member ID (X-Member)", "origin saw: %s" % jget(body).get("member"))
    forged = {"Cookie": "nw_member=" + token(m, key="not-the-lab-key")}
    expired = {"Cookie": "nw_member=" + token(m, ttl=-60)}
    sts, _ = statuses("GET", LB, "/doorbuster/tv-65", src, n=2, headers=forged)
    sts2, _ = statuses("GET", LB, "/doorbuster/tv-65", src, n=2, headers=expired)
    c.expect(all(s == 403 for s in sts + sts2), "the VIP's ID in a forged or expired cookie: 403", "got %s" % (sts + sts2))
    removed = vip_remove(m)
    def all_out():
        return all(x == 403 for v in everywhere("GET", "/doorbuster/tv-65", src, headers=cookie).values() for x in v)
    c.expect(until(all_out), "a VIP removed (%s) is refused on both nodes within 3 s"
             % ("on edge-b's API" if EDITION == "plus" else "DELETE on each node"),
             "still let in somewhere; removal: %s" % ", ".join("%s: HTTP %s" % r for r in removed))
    if EDITION != "plus":
        st = req("POST", node("edge-a"), "/ops/vip/sneaky", src=shopper())[0]
        st2 = req("POST", LB, "/ops/vip/sneaky", src=shopper(), headers={"X-Forwarded-For": OPS})[0]
        c.expect(st == 403 and st2 == 403, "shoppers can't add VIPs (straight at a node, or via the LB claiming to be ops)",
                 "got HTTP %s and %s" % (st, st2))


def open_8(b):
    return ("The platform team asks whether the edge logic would be better in Lua on OpenResty. "
            "Run ./warroom.sh bench, read the results, then ./warroom.sh answer njs|lua: which handled more requests per second?")


def check_8(c, regression=False):
    try:
        with open("/state/bench.json") as f:
            bench = json.load(f)
    except (OSError, ValueError):
        c.fail("the benchmark has been run", "run ./warroom.sh bench")
        return
    c.ok("the benchmark has been run")
    ans = BOARD["tickets"]["8"].get("answer")
    if not ans:
        c.fail("the platform team has your answer", "./warroom.sh answer njs   (or lua)")
        return
    c.expect(ans == bench["faster"], "your answer matches your benchmark (%s)" % bench["faster"],
             "you answered %s; in your run %s handled more requests per second" % (ans, bench["faster"]))


def bench_prepare():
    m = "bench-member"
    with open("/state/bench.cookie", "w") as f:
        f.write(token(m, ttl=3600))
    # A member who is NOT a VIP: both engines verify the cookie, look the member up and refuse at the edge,
    # so the benchmark measures the edge logic, not the origin
    if EDITION == "plus":
        kv_set("edge-a", "vip", m, "0")
    else:
        req("DELETE", node("edge-a"), "/ops/vip/%s" % m, src=OPS)
    req("DELETE", LUA, "/ops/vip/%s" % m, src=OPS)
    cookie = {"Cookie": "nw_member=" + token(m, ttl=3600)}
    for name, target in (("edge-a", node("edge-a")), ("lua", LUA)):
        st, _, _ = req("GET", target, "/doorbuster/tv-65", src=OPS, headers=cookie)
        if st != 403:
            print("%s answered %s for a non-VIP member, not 403: finish ticket 7 first" % (name, st))
            sys.exit(1)
    # A wrong-key cookie must be refused too, or there's no verification to measure
    st, _, _ = req("GET", LUA, "/doorbuster/tv-65", src=OPS, headers={"Cookie": "nw_member=" + token(m, key="x")})
    if st != 403:
        print("lua answered %s for a forged cookie" % st)
        sys.exit(1)


def bench_report():
    res = {}
    for name in ("edge-a", "lua"):
        with open("/state/bench-%s.json" % name) as f:
            d = json.load(f)
        with open("/state/bench-%s.rss" % name) as f:
            rss = [int(x) for x in f.read().split()]
        s = d.get("summary", {})
        pct = d.get("latencyPercentiles", {})
        codes = d.get("statusCodeDistribution", {})
        res[name] = {"rps": round(s.get("requestsPerSec", 0)), "p99_ms": round((pct.get("p99") or 0) * 1000, 2),
                     "codes": codes, "worker_rss_kb": rss}
    res["faster"] = "njs" if res["edge-a"]["rps"] >= res["lua"]["rps"] else "lua"
    with open("/state/bench.json", "w") as f:
        json.dump(res, f, indent=1)
    print("\n%-22s %12s %10s %-18s %s" % ("", "requests/s", "p99 ms", "statuses", "worker RSS (KB)"))
    for name, label in (("edge-a", "njs (edge-a)"), ("lua", "Lua (OpenResty)")):
        r = res[name]
        print("%-22s %12d %10.2f %-18s %s" % (label, r["rps"], r["p99_ms"], r["codes"], r["worker_rss_kb"]))
    print("\nBoth verified a member cookie (HMAC-SHA256), looked the member up in shared memory, and refused at the edge (403).")
    print("Now: ./warroom.sh answer njs   (or lua)")


def open_9(b):
    return "Midnight. The doors open, traffic surges, and every fix from tonight has to hold under load."


CHECKS = {1: check_1, 2: check_2, 3: check_3, 4: check_4, 5: check_5, 6: check_6, 7: check_7, 8: check_8}
OPENS = {1: open_1, 2: open_2, 3: open_3, 4: open_4, 5: open_5, 6: open_6, 7: open_7, 8: open_8, 9: open_9}


class Rush:
    """Background shoppers: catalog browsing through the load balancer while the finale checks run."""
    def __init__(self, threads=16):
        self.stop = False
        self.count = 0
        self.errors = 0
        self.threads = [threading.Thread(target=self.run, args=("10.58.120.%d" % (i + 1),), daemon=True) for i in range(threads)]
        self.urls = catalog_urls()

    def run(self, src):
        ensure_ip(src)
        c = None
        while not self.stop:
            try:
                if c is None:
                    c = http.client.HTTPConnection(*LB, timeout=5, source_address=(src, 0))
                c.request("GET", random.choice(self.urls))
                r = c.getresponse()
                r.read()
                self.count += 1
                if r.status != 200:
                    self.errors += 1
            except (OSError, http.client.HTTPException):
                self.errors += 1
                c = None

    def __enter__(self):
        for t in self.threads:
            t.start()
        return self

    def __exit__(self, *a):
        self.stop = True


# ---------------------------------------------------------------- commands

def banner_ticket(n, msg):
    stage, title = TICKETS[n]
    print("\n%s%s  |  Ticket %d: %s%s" % (B, stage, n, title, N))
    print("  %s" % msg)
    print("  %sRequirements, hints and answers: %s, ticket %d%s" % (D, GUIDE[n], n, N))
    print("  When it's fixed: ./warroom.sh check\n")


def cmd_next(b):
    cur = b.get("current")
    if cur and b["tickets"][str(cur)]["status"] == "open":
        print("Ticket %d is still open. Finish it (./warroom.sh check) or ./warroom.sh skip." % cur)
        return 1
    n = b.get("next", 1)
    if n == 1 and ready_banner(b, quiet=True) != 0:
        print("The war room isn't ready yet: ./warroom.sh status, then ./warroom.sh check")
        return 1
    if n > 9:
        print("No tickets left. ./warroom.sh board")
        return 0
    t = {"status": "open", "attempts": 0, "points": 0, "opened": int(time.time())}
    b["tickets"][str(n)] = t
    msg = OPENS[n](b)
    t["marks"], t["starts"] = marks(), starts()
    b["current"], b["next"] = n, n + 1
    save(b)
    banner_ticket(n, msg)
    return 0


def run_check(n, regression=False):
    c = Check()
    CHECKS[n](c, regression=regression)
    return c


def cmd_check(b):
    cur = b.get("current")
    if not cur:
        return ready_banner(b)
    t = b["tickets"][str(cur)]
    if t["status"] != "open":
        print("Ticket %d is %s. ./warroom.sh next opens the next one." % (cur, t["status"]))
        return 0
    t["attempts"] += 1
    stage, title = TICKETS[cur]
    print("\n%sTicket %d: %s%s (attempt %d)" % (B, cur, title, N, t["attempts"]))
    if cur == 9:
        return finale(b, t)
    c = run_check(cur)
    c.show()
    if c.passed:
        t["status"] = "solved"
        t["points"] = POINTS + (FIRST_TRY_BONUS if t["attempts"] == 1 else 0)
        t["solved"] = int(time.time())
        print("\n%sSOLVED%s: +%d points%s" % (G + B, N, t["points"], " (first try)" if t["attempts"] == 1 else ""))
    else:
        print("\n%sNot yet%s: %d of %d checks pass. Fix and ./warroom.sh check again." % (Y + B, N, sum(r[0] for r in c.results), len(c.results)))
    save(b)
    regressions(b, exclude=cur)
    if t["status"] == "solved":
        print("Next: ./warroom.sh next")
    return 0


def regressions(b, exclude):
    solved = [int(k) for k, v in b["tickets"].items() if v["status"] == "solved" and int(k) not in (exclude, 8, 9)]
    if not solved:
        return
    print("\n%sStill holding?%s" % (B, N))
    for n in sorted(solved):
        c = run_check(n, regression=True)
        mark = G + "holds" + N if c.passed else R + "BROKEN" + N
        print("  Ticket %d (%s): %s" % (n, TICKETS[n][1], mark))
        if not c.passed:
            c.show(indent="    ")


def finale(b, t):
    print("  Midnight rush: shoppers browse the catalog through the load balancer while every fix is checked again.\n")
    passed = 0
    with Rush() as rush:
        time.sleep(1)
        for n in range(1, 8):
            c = run_check(n, regression=True)
            ok = c.passed
            passed += ok
            print("  Ticket %d (%s): %s" % (n, TICKETS[n][1], G + "holds" + N if ok else R + "BROKEN" + N))
            if not ok:
                c.show(indent="    ")
        served, errors = rush.count, rush.errors
    print("\n  The rush: %d catalog requests served, %d errors" % (served, errors))
    clean = errors == 0
    pts = round(FINALE_POINTS * passed / 7) if clean else round(FINALE_POINTS * passed / 7 / 2)
    t["points"] = max(t.get("points", 0), pts)
    if passed == 7 and clean:
        t["status"] = "solved"
        print("\n%sThe doors held.%s +%d points" % (G + B, N, pts))
    else:
        print("\n%s%d of 7 fixes held%s%s: %d points so far (best run counts). Fix and ./warroom.sh check again."
              % (Y + B, passed, N, "" if clean else ", and shoppers saw errors (half points)", t["points"]))
    save(b)
    return 0


def ready_banner(b, quiet=False):
    """Before the first ticket: is the war room usable?"""
    c = Check()
    sts, edges = statuses("GET", LB, "/catalog/tvs/", shopper(), n=4)
    c.expect(all(s == 200 for s in sts) and len(edges) == 2, "shoppers reach both edges through the load balancer",
             "got %s via %s" % (sts, "/".join(sorted(edges)) or "?"))
    c.expect(bool(origin_prices()), "the war room can see the origin's prices")
    st, _, body = req("GET", LB, "/doorbuster/tv-65", src=shopper(), headers={"Cookie": "nw_member=" + token("ready-check")})
    c.expect(jget(body).get("member") == "ready-check", "the edges verify member cookies (the lab key is in place)",
             "the origin saw member %r" % jget(body).get("member"))
    if quiet:
        return 0 if c.passed else 1
    c.show()
    if c.passed:
        print("\n%sBlack Friday war room is ready to go%s (%s edition): 9 tickets waiting. ./warroom.sh next" % (G + B, N, EDITION))
        return 0
    print("\n%sThe war room is not ready%s: fix the items above (./warroom.sh status)" % (R + B, N))
    return 1


def cmd_board(b):
    print("\n%sNorthwind Black Friday war room%s  (%s edition)\n" % (B, N, b.get("edition") or EDITION))
    total = 0
    for n in range(1, 10):
        stage, title = TICKETS[n]
        t = b["tickets"].get(str(n))
        if not t:
            st, pts, att = D + "waiting" + N, "", ""
        else:
            colors = {"solved": G, "open": Y, "skipped": R}
            st = colors.get(t["status"], "") + t["status"] + N
            pts = str(t.get("points", 0))
            att = str(t.get("attempts", 0))
            total += t.get("points", 0)
        print("  %d  %-38s %-22s %-18s %8s" % (n, title, stage, st, pts and pts + " pts" + (" (%s checks)" % att if att else "")))
    best = 8 * (POINTS + FIRST_TRY_BONUS) + FINALE_POINTS
    print("\n  %sScore: %d of %d%s\n" % (B, total, best, N))
    return 0


def cmd_answer(b, value):
    cur = b.get("current")
    if cur != 8:
        print("Only ticket 8 takes an answer.")
        return 1
    if value not in ("njs", "lua"):
        print("Answer njs or lua.")
        return 1
    b["tickets"]["8"]["answer"] = value
    save(b)
    print("Recorded: %s. Now ./warroom.sh check" % value)
    return 0


def cmd_skip(b):
    cur = b.get("current")
    if not cur or b["tickets"][str(cur)]["status"] != "open":
        print("No open ticket.")
        return 1
    b["tickets"][str(cur)]["status"] = "skipped"
    save(b)
    print("Ticket %d skipped (no points). Later tickets may build on it. ./warroom.sh next" % cur)
    return 0


def main():
    global BOARD
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "token":
        print(token(args[0], int(args[1]) if len(args) > 1 else 900))
        return 0
    BOARD = load()
    if BOARD.get("edition") and EDITION and BOARD["edition"] != EDITION:
        print("This scoreboard is for the %s edition." % BOARD["edition"])
        return 1
    BOARD["edition"] = EDITION
    if cmd == "next":
        return cmd_next(BOARD)
    if cmd == "check":
        return cmd_check(BOARD)
    if cmd == "board":
        return cmd_board(BOARD)
    if cmd == "answer":
        return cmd_answer(BOARD, args[0] if args else "")
    if cmd == "skip":
        return cmd_skip(BOARD)
    if cmd == "bench_prepare":
        return bench_prepare()
    if cmd == "bench_report":
        bench_report()
        return 0
    print(__doc__)
    return 1


if __name__ == "__main__":
    sys.exit(main() or 0)

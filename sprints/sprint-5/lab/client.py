#!/usr/bin/env python3
"""Sprint 5 client: send requests to the gateway from any address in the lab network.

Runs inside the s5-client container (helpers.sh wraps it). --from IP picks the
source address; the address is added to the container's interface the first time
it's used, so the gateway sees a different client per IP.

    get   [--from IP] PATH            one request: status, time, size, speed, Retry-After
    burst N [--from IP] [--conc C] PATH
                                      N requests at the same moment, one connection each:
                                      how many got each status, and when they were answered
                                      (--conc C: as fast as possible, but only C at a time)
    pace  N RATE [--from IP] [--alt HOST:PORT] PATH
                                      N requests one after another at RATE per second
                                      (--alt: every other one goes to a second gateway)
    hold  N SECS [--from IP] PATH     N requests at once, each kept open SECS seconds
                                      (the origin is asked to wait), then the statuses
    slow  [--from IP] [--every S] [--body] [--for SECS] PATH
                                      a slow client: dribble the headers (or, with --body,
                                      the body) one piece every S seconds, and report when
                                      and how the gateway gave up on it (or, after --for
                                      SECS, that the client gave up first)
    h2    N [--from IP] PATH          N requests at once over ONE HTTP/2 connection (h2c)
    sweep N [--base IP] PATH          one request from each of N consecutive client addresses
                                      starting at --base (default 10.55.110.1)

Common options: -H 'Name: value' (repeatable), --method, --data-size BYTES (POST a body),
--edge HOST:PORT (default $EDGE or 10.55.0.10:8095).
"""
import argparse
import http.client
import os
import socket
import subprocess
import sys
import threading
import time

EDGE = os.environ.get("EDGE", "10.55.0.10:8095")


def ensure_ip(ip):
    if not ip:
        return
    have = subprocess.run(["ip", "-o", "-4", "addr", "show", "dev", "eth0"], capture_output=True, text=True).stdout
    if " %s/" % ip not in have:
        # another helper running in parallel may add it first ("File exists"): that's fine
        subprocess.run(["ip", "addr", "add", ip + "/16", "dev", "eth0"], stderr=subprocess.DEVNULL)


def host_port(edge):
    host, _, port = edge.partition(":")
    return host, int(port or 80)


def request(args, path, timeout=20.0, extra_query=""):
    """One request on its own connection. Returns (status, seconds, bytes, headers)."""
    host, port = host_port(args.edge)
    t0 = time.monotonic()
    try:
        conn = http.client.HTTPConnection(host, port, timeout=timeout,
                                          source_address=(args.src, 0) if args.src else None)
        headers = {}
        for h in args.header or []:
            k, _, v = h.partition(":")
            headers[k.strip()] = v.strip()
        body = None
        method = args.method
        if args.data_size:
            body = b"d" * args.data_size
            method = method if method != "GET" else "POST"
        conn.request(method, path + extra_query, body=body, headers=headers)
        resp = conn.getresponse()
        n = 0
        while True:
            chunk = resp.read(65536)
            if not chunk:
                break
            n += len(chunk)
        conn.close()
        return resp.status, time.monotonic() - t0, n, dict((k.lower(), v) for k, v in resp.getheaders())
    except (socket.timeout, TimeoutError):
        return "timeout", time.monotonic() - t0, 0, {}
    except (ConnectionError, http.client.HTTPException, OSError) as e:
        return "closed" if isinstance(e, (ConnectionError, http.client.RemoteDisconnected)) else "error", \
            time.monotonic() - t0, 0, {}


def human(n):
    for unit in ("B", "KB", "MB"):
        if n < 1024 or unit == "MB":
            return ("%d %s" % (n, unit)) if unit == "B" else ("%.1f %s" % (n, unit))
        n /= 1024.0


def summary(results):
    """'200 x 6, 429 x 14 (Retry-After: 1)': a status's Retry-After is shown when all its responses had one."""
    counts, retry = {}, {}
    for status, *rest in results:
        counts[status] = counts.get(status, 0) + 1
        hdrs = rest[2] if len(rest) > 2 else {}
        retry.setdefault(status, set()).add(hdrs.get("retry-after"))
    parts = []
    for k in sorted(counts, key=str):
        ra = retry[k]
        parts.append("%s x %d" % (k, counts[k]) + (" (Retry-After: %s)" % ra.pop() if len(ra) == 1 and None not in ra else ""))
    return ", ".join(parts)


def cmd_get(args):
    status, secs, n, hdrs = request(args, args.path)
    line = "%s  %.2fs  %s" % (status, secs, human(n))
    if n >= 100 * 1024 and secs > 0:
        line += "  %s/s" % human(n / secs)
    if "retry-after" in hdrs:
        line += "  Retry-After: %s" % hdrs["retry-after"]
    print(line)


def run_parallel(args, n, extra_query="", conc=0):
    """n requests, conc at a time (0 = all at once), each on its own connection.
    Each result's time is when it was answered, counted from the start of the run."""
    workers = min(conc, n) if conc else n
    results = [None] * n
    gate = threading.Barrier(workers)
    nxt = iter(range(n))
    take = threading.Lock()
    start = []

    def worker():
        gate.wait()
        with take:
            if not start:
                start.append(time.monotonic())
        while True:
            with take:
                i = next(nxt, None)
            if i is None:
                return
            status, _, size, hdrs = request(args, args.path, extra_query=extra_query)
            results[i] = (status, time.monotonic() - start[0], size, hdrs)

    threads = [threading.Thread(target=worker) for _ in range(workers)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return results


def timeline(results):
    """Group answers by status and by when they arrived (0.1 s buckets)."""
    groups = {}
    for status, secs, *_ in results:
        key = (round(secs, 1), str(status))
        groups[key] = groups.get(key, 0) + 1
    return "  ".join("%s x%d @%.1fs" % (s, c, t) for (t, s), c in sorted(groups.items()))


def cmd_burst(args):
    t0 = time.monotonic()
    results = run_parallel(args, args.n, conc=args.conc)
    how = "at once" if not args.conc or args.conc >= args.n else "%d at a time" % args.conc
    print("%d %s in %.2fs: %s" % (args.n, how, time.monotonic() - t0, summary(results)))
    print("  when: " + timeline(results))


def cmd_pace(args):
    gap = 1.0 / args.rate
    start = time.monotonic()
    statuses = []
    edges = [args.edge] + ([args.alt] if args.alt else [])
    for i in range(args.n):
        wait = start + i * gap - time.monotonic()
        if wait > 0:
            time.sleep(wait)
        args.edge = edges[i % len(edges)]
        statuses.append(request(args, args.path))
    print("%d at %g/s%s: %s" % (args.n, args.rate, " alternating %s" % " / ".join(edges) if args.alt else "", summary(statuses)))
    print("  in order: " + " ".join(str(s[0]) for s in statuses))


def cmd_hold(args):
    sep = "&" if "?" in args.path else "?"
    results = run_parallel(args, args.n, extra_query="%sdelay=%g" % (sep, args.secs))
    print("%d at once, each held %gs: %s" % (args.n, args.secs, summary(results)))
    print("  when: " + timeline(results))


def cmd_slow(args):
    host, port = host_port(args.edge)
    s = socket.create_connection((host, port), timeout=120, source_address=(args.src, 0) if args.src else None)
    t0 = time.monotonic()
    if args.body:
        size = 4096
        s.sendall(("POST %s HTTP/1.1\r\nHost: lumina\r\nContent-Type: text/plain\r\n"
                   "Content-Length: %d\r\n\r\n" % (args.path, size)).encode())
        pieces = [b"b"] * size
        what = "body bytes"
    else:
        s.sendall(("GET %s HTTP/1.1\r\n" % args.path).encode())
        pieces = [("X-Slow-%d: x\r\n" % i).encode() for i in range(2000)]
        what = "header lines"
    sent = 0
    reply = None
    s.settimeout(args.every)
    for piece in pieces:
        if args.for_secs and time.monotonic() - t0 >= args.for_secs:
            break
        try:
            reply = s.recv(4096)     # anything (or EOF) before we're done: the gateway gave up on us
            break
        except socket.timeout:
            pass
        try:
            s.sendall(piece)
            sent += 1
        except OSError:
            reply = b""
            break
    secs = time.monotonic() - t0
    s.close()
    head = "sent %d %s, one every %gs" % (sent, what, args.every)
    if reply is None:
        print("%s; still connected after %.1fs, so this client gave up" % (head, secs))
    elif reply:
        print("%s; after %.1fs the gateway answered: %s" % (head, secs, reply.split(b"\r\n", 1)[0].decode(errors="replace")))
    else:
        print("%s; after %.1fs the gateway closed the connection without an answer" % (head, secs))


def cmd_sweep(args):
    """One request from each of N consecutive addresses, starting at --base."""
    a, b, c, d = (int(x) for x in args.base.split("."))
    start = (a << 24) | (b << 16) | (c << 8) | d
    ips = []
    for i in range(args.n):
        v = start + i
        ips.append("%d.%d.%d.%d" % (v >> 24, (v >> 16) & 255, (v >> 8) & 255, v & 255))
    have = subprocess.run(["ip", "-o", "-4", "addr", "show", "dev", "eth0"], capture_output=True, text=True).stdout
    for ip in ips:
        if " %s/" % ip not in have:
            subprocess.run(["ip", "addr", "add", ip + "/16", "dev", "eth0"], stderr=subprocess.DEVNULL)
    results = []
    for ip in ips:
        args.src = ip
        results.append(request(args, args.path))
    print("one request from each of %d clients (%s to %s): %s" % (args.n, ips[0], ips[-1], summary(results)))


def cmd_h2(args):
    host, port = host_port(args.edge)
    url = "http://%s:%d%s" % (host, port, args.path)
    # --parallel without --parallel-immediate: curl waits for the first connection and multiplexes on it
    cmd = ["curl", "-s", "--http2-prior-knowledge", "--parallel", "--parallel-max", str(args.n),
           "--max-time", "20", "-w", "%{http_version} %{http_code} %{num_connects}\\n"]
    if args.src:
        cmd += ["--interface", args.src]
    for h in args.header or []:
        cmd += ["-H", h]
    for _ in range(args.n):
        cmd += [url, "-o", "/dev/null"]
    out = subprocess.run(cmd, capture_output=True, text=True).stdout.split("\n")
    rows = [line.split() for line in out if line.strip()]
    conns = sum(int(r[2]) for r in rows)
    print("%d over HTTP/%s, %d TCP connection(s): %s" % (len(rows), rows[0][0] if rows else "?", conns,
          summary([(r[1],) for r in rows])))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--from", dest="src", default=os.environ.get("FROM", ""))
    common.add_argument("-H", "--header", action="append")
    common.add_argument("--method", default="GET")
    common.add_argument("--data-size", type=int, default=0)
    common.add_argument("--edge", default=EDGE)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("get", parents=[common]); p.add_argument("path")
    p = sub.add_parser("burst", parents=[common]); p.add_argument("n", type=int); p.add_argument("path")
    p.add_argument("--conc", type=int, default=0, help="at most this many in progress at once (default: all)")
    p = sub.add_parser("pace", parents=[common]); p.add_argument("n", type=int); p.add_argument("rate", type=float); p.add_argument("path")
    p.add_argument("--alt", help="HOST:PORT: send every other request here instead of --edge")
    p = sub.add_parser("hold", parents=[common]); p.add_argument("n", type=int); p.add_argument("secs", type=float); p.add_argument("path")
    p = sub.add_parser("slow", parents=[common]); p.add_argument("path"); p.add_argument("--every", type=float, default=2.0)
    p.add_argument("--body", action="store_true")
    p.add_argument("--for", dest="for_secs", type=float, default=0, help="give up after this many seconds")
    p = sub.add_parser("h2", parents=[common]); p.add_argument("n", type=int); p.add_argument("path")
    p = sub.add_parser("sweep", parents=[common]); p.add_argument("n", type=int); p.add_argument("path")
    p.add_argument("--base", default="10.55.110.1", help="first client address (default 10.55.110.1)")
    args = ap.parse_args()
    ensure_ip(args.src)
    {"get": cmd_get, "burst": cmd_burst, "pace": cmd_pace, "hold": cmd_hold, "slow": cmd_slow, "h2": cmd_h2,
     "sweep": cmd_sweep}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())

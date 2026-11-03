#!/usr/bin/env python3
"""Sprint 6 tools: mint sessions, sign links, and talk to the telemetry port.

The signing key is read from lab/secrets/lumina.key (created by ./lab.sh up), the same
key the edge receives in its LUMINA_KEY environment variable.

    tools.py token SUB [--plan P] [--ttl S] [--jti ID] [--key K]   a session token (JWT, HS256)
    tools.py link PATH [--ttl S] [--key K]                         PATH?expires=...&sig=...
    tools.py tel DEVICE [--sig S] [--data TEXT] [--silent]         one telemetry connection
    tools.py decode TOKEN                                          header and payload, no checks
"""
import argparse
import base64
import hashlib
import hmac
import json
import os
import socket
import sys
import time

LAB = os.path.dirname(os.path.abspath(__file__))
KEY_FILE = os.path.join(LAB, "secrets", "lumina.key")
TEL = (os.environ.get("TEL_HOST", "127.0.0.1"), int(os.environ.get("TEL_PORT", "8097")))


def lab_key():
    try:
        with open(KEY_FILE) as f:
            return f.read().strip()
    except OSError:
        sys.exit("no key at %s: run ./lab.sh up first" % KEY_FILE)


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def mac(key, msg):
    return hmac.new(key.encode(), msg.encode(), hashlib.sha256)


def token(args):
    key = args.key if args.key is not None else lab_key()
    payload = {"sub": args.sub, "plan": args.plan, "exp": int(time.time()) + args.ttl}
    if args.jti:
        payload["jti"] = args.jti
    head = b64url(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
    body = b64url(json.dumps(payload, separators=(",", ":")).encode())
    sig = b64url(mac(key, head + "." + body).digest())
    print("%s.%s.%s" % (head, body, sig))


def link(args):
    key = args.key if args.key is not None else lab_key()
    expires = int(time.time()) + args.ttl
    sig = mac(key, "%s:%d" % (args.path, expires)).hexdigest()
    print("%s?expires=%d&sig=%s" % (args.path, expires, sig))


def tel(args):
    sig = args.sig if args.sig is not None else mac(lab_key(), args.device).hexdigest()[:16]
    t0 = time.time()
    try:
        s = socket.create_connection(TEL, timeout=10)
    except OSError as e:
        sys.exit("connect failed: %s" % e)
    s.settimeout(10)
    if not args.silent:
        s.sendall(("HELLO %s %s\n%s\n" % (args.device, sig, args.data)).encode())
    try:
        got = s.recv(4096)
    except socket.timeout:
        got = None
    except ConnectionResetError:
        got = b""
    took = time.time() - t0
    if got is None:
        print("no answer after %.1fs (still open)" % took)
    elif got:
        print("%s  after %.1fs" % (got.decode(errors="replace").strip(), took))
    else:
        print("closed without an answer after %.1fs" % took)


def decode(args):
    for part in args.token.split(".")[:2]:
        print(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)).decode(errors="replace"))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("token")
    p.add_argument("sub")
    p.add_argument("--plan", default="standard")
    p.add_argument("--ttl", type=int, default=3600, help="seconds until exp (negative: already expired)")
    p.add_argument("--jti")
    p.add_argument("--key", help="sign with this key instead of the lab's")
    p.set_defaults(fn=token)
    p = sub.add_parser("link")
    p.add_argument("path")
    p.add_argument("--ttl", type=int, default=300)
    p.add_argument("--key")
    p.set_defaults(fn=link)
    p = sub.add_parser("tel")
    p.add_argument("device")
    p.add_argument("--sig", help="send this signature instead of the right one")
    p.add_argument("--data", default="temp=21.5")
    p.add_argument("--silent", action="store_true", help="connect and send nothing")
    p.set_defaults(fn=tel)
    p = sub.add_parser("decode")
    p.add_argument("token")
    p.set_defaults(fn=decode)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()

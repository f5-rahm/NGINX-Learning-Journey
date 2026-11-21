#!/usr/bin/env python3
"""Sprint 8 side quest: lab JWTs signed with lab/secrets/jwt.key (HS256), and its JWK.

  tools.py jwk                      the JSON Web Key Set NGINX Plus validates with
  tools.py token SUB TIER [ROLES]   a token for SUB with claim tier=TIER and roles (comma list), 1 h
  tools.py decode TOKEN             the token's header and claims
"""
import base64, hashlib, hmac, json, os, sys, time

KEY_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "secrets", "jwt.key")


def b64(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def unb64(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def key():
    try:
        return open(KEY_FILE).read().strip().encode()
    except OSError:
        sys.exit(f"No key at {KEY_FILE}: run ./lab.sh up first.")


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    cmd = argv[1]
    if cmd == "jwk":
        print(json.dumps({"keys": [{"kty": "oct", "kid": "copperline-lab", "alg": "HS256", "k": b64(key())}]}))
    elif cmd == "token" and len(argv) >= 4:
        roles = [r for r in (argv[4] if len(argv) > 4 else "").split(",") if r]
        h = b64(json.dumps({"alg": "HS256", "typ": "JWT", "kid": "copperline-lab"}).encode())
        now = int(time.time())
        p = b64(json.dumps({"iss": "https://id.copperline.test", "sub": argv[2], "tier": argv[3],
                            "roles": roles, "iat": now, "exp": now + 3600}).encode())
        s = b64(hmac.new(key(), f"{h}.{p}".encode(), hashlib.sha256).digest())
        print(f"{h}.{p}.{s}")
    elif cmd == "decode" and len(argv) == 3:
        h, p, _ = argv[2].split(".")
        print(json.dumps({"header": json.loads(unb64(h)), "claims": json.loads(unb64(p))}, indent=1))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)

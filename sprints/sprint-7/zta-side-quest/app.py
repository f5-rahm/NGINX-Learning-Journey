# Throwaway portal: trusts X-User as-is, and independently verifies the forwarded tokens (RS256, stdlib only).
import base64, hashlib, json, time, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ISS = "http://localhost:8088/realms/tidewater"
AUD = "portal-app"
JWKS_URL = "http://10.89.0.30:8080/realms/tidewater/protocol/openid-connect/certs"
_jwks = {}

def b64d(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))

def key(kid):
    if kid not in _jwks:
        for k in json.load(urllib.request.urlopen(JWKS_URL, timeout=5))["keys"]:
            if k.get("kty") == "RSA":
                _jwks[k["kid"]] = (int.from_bytes(b64d(k["n"]), "big"), int.from_bytes(b64d(k["e"]), "big"))
    return _jwks.get(kid)

DIGESTINFO = bytes.fromhex("3031300d060960864801650304020105000420")

def verify(tok):
    if not tok:
        return {"result": "no token"}
    try:
        h, p, s = tok.split(".")
        hdr, claims = json.loads(b64d(h)), json.loads(b64d(p))
    except Exception as e:
        return {"result": f"malformed: {e}"}
    out = {"iss": claims.get("iss"), "aud": claims.get("aud"), "azp": claims.get("azp"),
           "typ": claims.get("typ"), "preferred_username": claims.get("preferred_username"),
           "exp_in": claims.get("exp", 0) - int(time.time()), "bytes": len(tok)}
    k = key(hdr.get("kid"))
    if hdr.get("alg") != "RS256" or not k:
        out["result"] = f"rejected: alg {hdr.get('alg')} / unknown kid"; return out
    n, e = k
    em = pow(int.from_bytes(b64d(s), "big"), e, n).to_bytes((n.bit_length() + 7) // 8, "big")
    digest = hashlib.sha256(f"{h}.{p}".encode()).digest()
    expect = b"\x00\x01" + b"\xff" * (len(em) - 3 - len(DIGESTINFO) - 32) + b"\x00" + DIGESTINFO + digest
    if em != expect:
        out["result"] = "rejected: bad signature"; return out
    aud = claims.get("aud"); aud = aud if isinstance(aud, list) else [aud]
    if claims.get("iss") != ISS:
        out["result"] = "rejected: wrong iss"
    elif claims.get("exp", 0) < time.time():
        out["result"] = "rejected: expired"
    elif AUD not in aud:
        out["result"] = f"rejected: aud is not {AUD}"
    else:
        out["result"] = "valid"
    return out

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        auth = self.headers.get("Authorization") or ""
        body = json.dumps({
            "header_trust": {"user": self.headers.get("X-User")},
            "access_token": verify(auth[7:] if auth.lower().startswith("bearer ") else ""),
            "id_token": verify((self.headers.get("X-Id-Token") or "")[7:]),
        }, indent=1).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass

ThreadingHTTPServer(("0.0.0.0", 9003), H).serve_forever()

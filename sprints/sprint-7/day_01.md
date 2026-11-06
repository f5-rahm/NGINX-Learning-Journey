# Sprint 7 &bull; Day 1: Mutual TLS, Both Ways
**Day:** 1 of 3  
**Estimated Time:** 70 Minutes (15 concepts, 5 setup, 40 activities, 10 quiz)  
**Theme:** On BIG-IP, "only partners with our certificate get in" is a Client SSL profile with **Client Certificate: require** and a trusted CA bundle, and "we prove ourselves to the backend" is a certificate and key in the Server SSL profile. NGINX does both in a handful of directives. Today you put mutual TLS on Tidewater Logistics' partner API, turn a certificate into an identity the application can trust, revoke a partner, and make the edge prove itself to the finance ledger and check that the ledger is the real one.

---

## 1. Concepts to Understand (15 Minutes)

### 1.1 What "Mutual" Adds to the Handshake
In ordinary TLS only the server shows a certificate. With mutual TLS the server also asks for one:
* **The server sends a CertificateRequest** with the list of CA names it accepts. A client with several certificates uses that list to pick one.
* **The client sends its certificate**, and then a **CertificateVerify**: a signature, made with its private key, over the handshake so far. That's the proof of possession. A copied certificate without its key is useless.
* **The server checks the chain** up to a CA it trusts, plus the dates and, if configured, revocation. Then the request starts, and every request on that connection carries the same client identity.

What NGINX needs:

| Directive | What it does |
| :--- | :--- |
| `ssl_client_certificate file` | The CAs that client certificates must chain to. Their names are sent in the CertificateRequest. |
| `ssl_trusted_certificate file` | More CAs for verification (intermediates) whose names are **not** advertised |
| `ssl_verify_client on \| optional \| optional_no_ca \| off` | Whether a certificate is required, and how strictly it's checked (1.2) |
| `ssl_verify_depth n` | How long the chain may be: `1` means the client's certificate must be signed directly by a trusted CA |
| `ssl_crl file` | A certificate revocation list (1.4) |

### 1.2 The Four Modes, and What a Refusal Looks Like
| `ssl_verify_client` | No certificate | A certificate that fails verification | A valid certificate |
| :--- | :--- | :--- | :--- |
| `off` (default) | Served | Not asked for | Not asked for |
| `on` | **400**, code 496 | **400**, code 495 | Served |
| `optional` | Served, `$ssl_client_verify` = `NONE` | **400**, code 495 | Served |
| `optional_no_ca` | Served, `NONE` | **Served**, `FAILED:<reason>`, if the only problem is the CA | Served |

* The refusals happen **before any location runs**. NGINX answers with its own `400` page, using the internal codes **495** (certificate error) and **496** (no certificate). `error_page 495` / `error_page 496` are the hooks to answer differently, for example with a JSON error and a `401` or `403`.
* `$ssl_client_verify` is `SUCCESS`, `NONE`, or `FAILED:<reason>`. With `optional_no_ca`, you decide what to do with a failure. That's the mode for "let the application explain the problem", and the mode where mistakes happen (Activity 3.5).
* The TLS handshake succeeds in every case. The refusal is an HTTP response, which is why the log shows a request with status `400`.

### 1.3 From Certificate to Identity
NGINX exposes the client certificate as variables:

| Variable | Example |
| :--- | :--- |
| `$ssl_client_verify` | `SUCCESS` |
| `$ssl_client_s_dn` | `OU=Integrations,O=Acme Freight,CN=acme` (RFC 2253 order: the CN comes **last**) |
| `$ssl_client_i_dn` | The issuer's DN |
| `$ssl_client_serial`, `$ssl_client_fingerprint` | The serial number, the SHA-1 fingerprint |
| `$ssl_client_v_start`, `$ssl_client_v_end`, `$ssl_client_v_remain` | Validity dates, and days left |
| `$ssl_client_escaped_cert` | The whole certificate as URL-escaped PEM, ready for a header |

* **There's no variable for the subject alternative names** (SAN: DNS names, URIs, email addresses), neither in open source nor in Plus. Many PKIs put the real identity there (a SPIFFE ID such as `spiffe://partners.tidewater/acme` is a URI SAN). The usual answer is to forward the certificate (`$ssl_client_escaped_cert`) and let the application parse it.
* **Pull the CN out with a `map`** and a regex on `$ssl_client_s_dn`.
* **An identity is only an identity if it was verified.** The DN variables describe whatever certificate was presented, verified or not.
* **Headers the edge sets must replace what the client sent.** `proxy_set_header X-Partner ...` overwrites a client's `X-Partner`. A header the edge doesn't set passes through untouched.

### 1.4 Revocation
A certificate is valid until it expires, even after the partner relationship ends. Revocation is how you take it back early:
* **CRL (`ssl_crl`):** a file, signed by the CA, listing revoked serial numbers. NGINX **reads it when the configuration loads**, like a certificate. A new CRL means a reload.
* **A CRL has an expiry of its own** (its *Next Update*). OpenSSL treats an expired CRL as a verification failure for **every** certificate from that CA. A CRL that nobody renewed locks out every partner at once.
* **OCSP for clients (`ssl_ocsp on`):** NGINX asks the CA's OCSP responder about each client certificate, with a cache (`ssl_ocsp_cache`). It's fresher than a CRL, but the responder becomes a dependency of every new connection.
* **Short-lived certificates** (hours or days) make revocation matter less. That's where service meshes and SPIFFE went.

### 1.5 The Edge as a TLS Client
`proxy_pass https://...` encrypts to the upstream, and that's all it does by default:

| Directive | Default | What it does |
| :--- | :--- | :--- |
| `proxy_ssl_certificate` / `_key` | none | The certificate the edge presents when the upstream asks for one |
| `proxy_ssl_verify` | **`off`** | Whether to check the upstream's certificate at all |
| `proxy_ssl_trusted_certificate` | none | The CAs the upstream's certificate must chain to |
| `proxy_ssl_name` | the host in `proxy_pass` | The name the certificate must match. With `proxy_pass https://ledger`, that's the upstream block's name, `ledger`. |
| `proxy_ssl_server_name` | `off` | Send that name as SNI |
| `proxy_ssl_session_reuse` | `on` | Resume TLS sessions to the upstream |

* **`proxy_ssl_verify off` is the default**, so out of the box the edge encrypts to whoever answers, impostors included.
* **Certificates are checked at the handshake, and connections live on.** Since nginx 1.29.7, upstream connections are kept alive by default (`keepalive` is on in `upstream` blocks, and `proxy_http_version` defaults to `1.1`). A connection verified once is reused for many requests. That's good for latency, and it's why a configuration change to upstream TLS only takes effect on new connections.

### 1.6 BIG-IP Lens

| Need | BIG-IP | NGINX |
| :--- | :--- | :--- |
| Ask for a client certificate | Client SSL profile, Client Certificate: `request` / `require` | `ssl_verify_client optional` / `on` |
| Trusted CAs | Trusted Certificate Authorities | `ssl_client_certificate` (+ `ssl_trusted_certificate`) |
| CA names sent to the client | Advertised Certificate Authorities | The names in `ssl_client_certificate` |
| Chain length | Certificate Chain Traversal Depth | `ssl_verify_depth` |
| Revocation | CRL file in the profile, or an OCSP / CRLDP authentication profile | `ssl_crl`, `ssl_ocsp` |
| Read the certificate | iRule `X509::subject [SSL::cert 0]`, `SSL::verify_result` | `$ssl_client_s_dn`, `$ssl_client_verify` |
| SAN | `X509::extensions` | No variable: forward `$ssl_client_escaped_cert` |
| Present a certificate upstream | Server SSL profile, Certificate and Key | `proxy_ssl_certificate` / `_key` |
| Check the server's certificate | Server SSL profile, Server Certificate: `require`, Authenticate Name | `proxy_ssl_verify on`, `proxy_ssl_name` |

The main difference: BIG-IP's Server SSL profile defaults to `ignore`, and NGINX's `proxy_ssl_verify` defaults to `off`. Neither checks the backend until you ask.

---

## 2. Lab Setup (5 Minutes)

Sprint 7 runs in containers like Sprints 4–6. Tidewater Logistics has one edge (`nginx:mainline`) with two HTTPS ports, and everything behind it:

```bash
cd /srv/nginx-journey/sprints/sprint-7/lab
cp day1_nginx.conf nginx.conf           # the edge: TLS on both ports, nothing checked yet
./lab.sh up                             # certificates, network, apps, Keycloak, OAuth2 Proxy, edge, ready check
source helpers.sh                       # partner, ops, office, login, as, cert, revoke, ...: in every new terminal
```
The first `up` makes the lab's PKI in `lab/certs/` and random ops tokens in `lab/secrets/` (both owner-only, not in git), and starts Keycloak, which takes about 30 seconds. Keycloak and OAuth2 Proxy are for Day 3; today they just run. The ready check ends with `Sprint 7 lab ready: edge :8091 (portal, ops, IdP) and :8092 (partners) -> s7-apps`.

| Address / port | Service |
| :--- | :--- |
| 8081–8097 | Earlier sprints (reserved) |
| **:8092** (container `s7-edge`, 10.57.0.10) | **The partner API**, HTTPS: today's port |
| **:8091** | The staff portal, the ops tool and Keycloak's front door, HTTPS (Days 2 and 3) |
| `s7-apps` (10.57.0.20) | The applications: partner API :9001, ops :9002, portal :9003, authz :9100, **ledger :9443 (HTTPS only)**; counters on 127.0.0.1:8017 |
| `s7-idp`, `s7-sso` | Keycloak and OAuth2 Proxy (Day 3); Keycloak's admin console on http://localhost:8031 |

**The lab PKI (`lab/certs/`)**

| CA | Certificates it signed |
| :--- | :--- |
| **Tidewater Internal CA** | `edge` (the edge's server certificate, for `localhost`), `ledger` (`ledger.internal`), `edge-client` (the edge's client certificate, CN `tidewater-edge`) |
| **Tidewater Partner CA** | `acme`, `globex`, `initech` (one client certificate per partner) |
| **Rogue CA** | `fake-acme` (same subject as Acme's), `impostor` (a server certificate for `ledger.internal`) |

| Command | What it does |
| :--- | :--- |
| `partner NAME PATH [curl options]` | One request to :8092 with NAME's client certificate (`acme`, `globex`, `initech`, `fake-acme`, or `none`): `<- STATUS`, then the body |
| `cert NAME` | A certificate's subject, issuer, serial, names and dates |
| `revoke NAME` / `unrevoke NAME` / `crl` | Revoke a partner certificate or take it back (each writes a new CRL), show the CRL |
| `crl-short SECONDS` / `crl-fresh` | Write a CRL that expires soon / a normal 30-day CRL |
| `./lab.sh impostor on\|off` | The ledger's address answers with the impostor's certificate |
| `elog [N]` / `alog [N]` | The edge's error log / access log |
| `./lab.sh reload` | `nginx -t`, reload, and a check that the master accepted it |

The partner API answers with JSON: what it received as `partner`, `partner_dn` and `partner_verify`, and the names it read from a forwarded certificate (`partner_cert_names`). Each activity edits `lab/nginx.conf`; after each edit, run `./lab.sh reload`.

---

## 3. Hands-on Guided Discovery Activities (40 Minutes)

### Activity 3.1: Meet the Certificates (4 min)
```bash
cert acme
cert fake-acme
partner none /shipments/7
```
The partner API answers without any certificate: `:8092` is HTTPS, but nobody is asked who they are.

<details>
<summary>What's the difference between <code>acme</code> and <code>fake-acme</code>?</summary>

Only the issuer. The subject is the same (`OU=Integrations,O=Acme Freight,CN=acme`), and so is the DNS name. `acme` was signed by the Tidewater Partner CA, `fake-acme` by a "Rogue CA" anyone could create in a minute. A subject is just text: what makes a certificate trustworthy is who signed it.
</details>

### Activity 3.2: Require a Certificate (6 min)
In the `:8092` server, after `server_name`:
```nginx
ssl_client_certificate certs/partner-ca.crt;
ssl_verify_client      on;
```
```bash
./lab.sh reload
for p in none acme fake-acme initech; do echo "== $p"; partner $p /shipments/7 | head -3; done
echo | openssl s_client -connect localhost:8092 2>/dev/null | grep -A1 "Acceptable client"
alog 4
```
* `none`: `400 No required SSL certificate was sent`
* `acme`: `200`
* `fake-acme`: `400 The SSL certificate error`
* `initech`: `200`

`openssl s_client` shows the CA name the edge now advertises: `O = Tidewater Logistics, CN = Tidewater Partner CA`.

<details>
<summary>Initech's contract ended last month. Why did it get in?</summary>

Its certificate is still valid: it chains to the Partner CA and hasn't expired. Nothing has told the edge it's revoked yet (Activity 3.6).
</details>

<details>
<summary>The access log shows <code>ssl_verify=FAILED:unable to verify the first certificate</code> for <code>fake-acme</code>, with status 400. Did the TLS handshake fail?</summary>

No. The handshake completed and the request was read. Then NGINX, before any location, answered `400` because verification failed. That's why it's in the access log with the request line, and why `$ssl_client_verify` has a value to log.
</details>

### Activity 3.3: Refusals a Partner's Code Can Read (4 min)
Partners' integrations parse JSON, not HTML error pages. In the same server:
```nginx
error_page 495 = @cert_rejected;
error_page 496 = @cert_missing;

location @cert_missing {
    default_type application/json;
    return 401 '{"error": "client certificate required"}\n';
}
location @cert_rejected {
    default_type application/json;
    return 403 '{"error": "client certificate rejected"}\n';
}
```
```bash
./lab.sh reload
partner none /shipments/7
partner fake-acme /shipments/7
```
`401 {"error": "client certificate required"}` and `403 {"error": "client certificate rejected"}`.

### Activity 3.4: Who Is Calling? (8 min)
Pass the certificate details to the API. In `location /`, before `proxy_pass`:
```nginx
proxy_set_header X-Partner-DN     $ssl_client_s_dn;
proxy_set_header X-Partner-Verify $ssl_client_verify;
proxy_set_header X-Partner-Cert   $ssl_client_escaped_cert;
```
```bash
./lab.sh reload
partner acme /shipments/7
```
`partner_dn` is `OU=Integrations,O=Acme Freight,CN=acme`, with the CN last, and `partner_cert_names` lists `DNS:api.acme.example` and `URI:spiffe://partners.tidewater/acme`: the API read the SANs from the forwarded certificate. `partner` is still `null`.

Now try to be someone else:
```bash
partner globex /shipments/7 -H 'X-Partner: acme' | grep -E '"partner"|dn'
```
<details>
<summary>What did the API believe, and why?</summary>

`"partner": "acme"` with `"partner_dn": "O=Globex Shipping,CN=globex"`. The edge doesn't set `X-Partner`, so Globex's own header passed straight through. Any header the application trusts must be **set** by the edge.
</details>

Give the API a simple name. In `http`, before the servers:
```nginx
map $ssl_client_s_dn $partner {
    "~(^|,)CN=(?<cn>[^,]+)" $cn;
    default                 "";
}
```
And in `location /`:
```nginx
proxy_set_header X-Partner        $partner;
```
```bash
./lab.sh reload
partner globex /shipments/7 -H 'X-Partner: acme' | grep '"partner"'
```
`"partner": "globex"`: the edge's header replaced the client's.

### Activity 3.5: The Optional Trap (6 min)
Some partners' tools can't present a certificate yet, so someone suggests `optional_no_ca`: "the API can check `X-Partner-Verify` itself". Change `ssl_verify_client on;` to `ssl_verify_client optional_no_ca;`, then:
```bash
./lab.sh reload
for p in none fake-acme initech; do echo "== $p"; partner $p /shipments/7 | grep -E '^<-|"partner"|verify'; done
```
<details>
<summary>What does the API see from <code>fake-acme</code>, and why is that dangerous?</summary>

`200` with `"partner": "acme"` and `"partner_verify": "FAILED:unable to verify the first certificate"`. `optional_no_ca` lets a certificate from an unknown CA through, and `$ssl_client_s_dn` describes it anyway, so the `map` extracted `acme` from the forgery. Every part of the application that reads `X-Partner` and forgets `X-Partner-Verify` now trusts the rogue CA.
</details>

Make the name depend on verification. Replace the `map` with two:
```nginx
map $ssl_client_s_dn $cert_cn {
    "~(^|,)CN=(?<cn>[^,]+)" $cn;
    default                 "";
}
map $ssl_client_verify $partner {
    SUCCESS $cert_cn;
    default "";
}
```
```bash
./lab.sh reload
partner fake-acme /shipments/7 | grep -E '"partner"|verify'
```
`"partner": null`. Now set `ssl_verify_client on;` again and reload: Tidewater's partners all have certificates.

<details>
<summary>With <code>optional</code> instead of <code>optional_no_ca</code>, what would <code>fake-acme</code> get?</summary>

`403` from `@cert_rejected`: `optional` makes the certificate optional, but a certificate that **is** presented must verify. Only `optional_no_ca` lets an unverifiable one through. In the lab, `none` got `200` with `"partner_verify": "NONE"` under both.
</details>

### Activity 3.6: Revoking a Partner (7 min)
Initech is revoked in the CA's database, and the CA has published a CRL:
```bash
crl
cert initech | grep serial
```
The CRL lists serial `1002`, Initech's. In the `:8092` server, before `ssl_verify_client`:
```nginx
ssl_crl                certs/partner-ca.crl;
```
```bash
./lab.sh reload
partner initech /shipments/7
```
`403 {"error": "client certificate rejected"}`, and the access log says `ssl_verify=FAILED:certificate revoked`.

Now Globex's key leaks:
```bash
revoke globex
partner globex /shipments/7 | head -1
./lab.sh reload
partner globex /shipments/7 | head -1
```
<details>
<summary>Why was Globex still let in after <code>revoke</code>?</summary>

The CRL file changed, but NGINX read the old one when the configuration loaded. Until the reload, the old CRL is in force. Publishing a CRL is only half of a revocation: every NGINX that uses it has to reload.
</details>

Globex gets a new key; take the revocation back for the rest of the sprint:
```bash
unrevoke globex && ./lab.sh reload
```

The CRL has its own expiry. Make one that expires in 15 seconds:
```bash
crl-short 15 && ./lab.sh reload
partner acme /shipments/7 | head -1
sleep 16
partner acme /shipments/7
alog 1
```
<details>
<summary>What happened to Acme, which did nothing wrong?</summary>

`403`, with `ssl_verify=FAILED:CRL has expired`. Once the CRL is past its *Next Update*, OpenSSL fails every certificate from that CA. The CRL renewal job is now part of the partner API's availability.
</details>

```bash
crl-fresh && ./lab.sh reload
partner acme /shipments/7 | head -1
```

### Activity 3.7: The Edge Proves Itself to the Ledger (5 min)
`/ledger/` goes to the finance ledger, which only speaks HTTPS and only to clients with a certificate from the Internal CA:
```bash
partner acme /ledger/balance | head -1
elog 1
```
`502`, and the error log says `tlsv13 alert certificate required`: the ledger asked for a client certificate and the edge had none. In `location /ledger/`:
```nginx
proxy_ssl_certificate     certs/edge-client.crt;
proxy_ssl_certificate_key certs/edge-client.key;
```
```bash
./lab.sh reload
partner acme /ledger/balance
```
`200`, and the ledger saw `commonName=tidewater-edge`. Now someone moves the ledger's address to their own server:
```bash
./lab.sh impostor on
partner acme /ledger/balance | grep -E '<-|served'
```
<details>
<summary>Why did the edge send the request to the impostor?</summary>

`"served_as": "impostor"`, with `200`. `proxy_ssl_verify` is `off` by default: the edge encrypted the connection but never checked who was at the other end. Your partner's request (and the edge's client certificate) went to the impostor.
</details>

Check the ledger's certificate. In `location /ledger/`:
```nginx
proxy_ssl_trusted_certificate certs/internal-ca.crt;
proxy_ssl_verify              on;
```
```bash
./lab.sh reload
partner acme /ledger/balance | head -1; elog 1
./lab.sh impostor off
partner acme /ledger/balance | head -1; elog 1
```
<details>
<summary>The impostor gets <code>502</code>, but so does the real ledger. Why?</summary>

The error log says `upstream SSL certificate does not match "ledger"`. The name checked is the host in `proxy_pass https://ledger`, the upstream block's name, and the ledger's certificate is for `ledger.internal`.
</details>

Tell the edge which name to expect, and send it as SNI too:
```nginx
proxy_ssl_name        ledger.internal;
proxy_ssl_server_name on;
```
```bash
./lab.sh reload
partner acme /ledger/balance | head -1
./lab.sh impostor on;  partner acme /ledger/balance | head -1
./lab.sh impostor off
```
`200` for the ledger, `502` for the impostor (`unable to verify the first certificate`).

> **Note:** switching to the impostor cuts the open connections, like moving an address to another server would. Without that, the edge would have kept using connections it had already verified with the real ledger: since nginx 1.29.7, upstream connections are kept alive by default, and a certificate is checked once, at the handshake.

---

## 4. Day 1 Concept Examination (10-Question Randomized Quiz)

```bash
cd /srv/nginx-journey && python3 -m http.server 8090
```
👉 **http://&lt;lab-host&gt;:8090/quiz.html?sprint=7&day=1**

When you're done for the day: `./lab.sh down` (the PKI and the tokens stay for Day 2).

---

## 5. Key Takeaways for Day 1
* **`ssl_verify_client on` + `ssl_client_certificate`** is a partner gate in two lines. Refusals happen before locations run: `error_page 495` and `496` are the hooks for a friendlier answer.
* **Only a verified certificate is an identity.** Map the CN from `$ssl_client_s_dn` only when `$ssl_client_verify` is `SUCCESS`, and remember `optional_no_ca` lets unknown CAs through.
* **Set every identity header at the edge.** A header you don't set is whatever the client sent.
* **There's no SAN variable.** Forward `$ssl_client_escaped_cert` when the application needs more than the DN.
* **A CRL is read at reload and has its own expiry.** Revoking means publishing a CRL and reloading every edge; an expired CRL locks everyone out.
* **`proxy_ssl_verify` is off by default.** Presenting a certificate upstream (`proxy_ssl_certificate`) and checking the upstream's (`proxy_ssl_verify`, `proxy_ssl_trusted_certificate`, `proxy_ssl_name`) are separate decisions.

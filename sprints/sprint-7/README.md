# Sprint 7: Security Hardening & Zero Trust
**Cadence:** 3 sessions, any days that week  
**Milestone:** The Tidewater edge: partners proven by certificate (and refused when revoked), the edge proving itself to the finance ledger and checking it's the real one, an ops tool that asks an authorization service before every change, the head office's wall screen let in by address, and staff signed in once through Keycloak, with admin pages for the admins group  
**Shape:** 3 days, then an optional NGINX Plus side quest (JWT validation and native OpenID Connect).

---

## 1. Sprint at a Glance

| Day | Theme | Concepts (~15 min) | Lab | Guide |
| :--- | :--- | :--- | :--- | :--- |
| **1** | Mutual TLS, both ways | The mutual handshake, the four `ssl_verify_client` modes and 495/496, the certificate's variables (and the missing SAN), CRLs and OCSP, the edge as a TLS client | Require a certificate, JSON refusals, identity headers and spoofing, the `optional_no_ca` trap, revoking a partner and an expired CRL, mTLS to the ledger and an impostor | [`day_01.md`](day_01.md) |
| **2** | `auth_request` | Subrequests and status codes, what the service sees, failing closed, caching decisions, `satisfy` | The ops tool behind authz, `auth_request_set`, the method trap, a broken and a slow service, a cache key that leaks decisions, the office exception | [`day_02.md`](day_02.md) |
| **3** | Single sign-on & the sprint lab | The OIDC code flow, OAuth2 Proxy beside NGINX, one IdP at two addresses, sessions and sign-out | The IdP's front door, wiring OAuth2 Proxy, username vs `sub`, the leaking cookie, admins only, a sign-out that isn't, **build the Tidewater edge**, `test_sprint07.sh` | [`day_03.md`](day_03.md) |
| **Side quest** | NGINX Plus | `auth_jwt` with a JWKS, `auth_jwt_require`, `oidc_provider` / `auth_oidc` | Bearer tokens for the dispatch API, audience and groups, the portal's sign-in without OAuth2 Proxy | [`day_03_enterprise.md`](day_03_enterprise.md) |

---

## 2. Lab Environment

The lab runs in **containers** like Sprints 4–6, from `/srv/nginx-journey/sprints/sprint-7/lab` through `lab.sh`. This week's edge has two HTTPS ports and five services behind it, including an identity provider.

| Address / port | Service |
| :--- | :--- |
| 8081–8097 | Earlier sprints (reserved) |
| **:8091** (container `s7-edge`, 10.57.0.10) | **The edge, HTTPS:** the staff portal `/portal/`, the ops tool `/ops/`, and Keycloak's front door (`/realms/`, `/resources/`) |
| **:8092** | **The edge, HTTPS:** the partner API, and `/ledger/` |
| `s7-apps` (10.57.0.20) | The applications: partner API :9001, ops :9002, portal :9003, authz :9100, ledger :9443 (HTTPS, client certificate required); counters and switches on 127.0.0.1:8017 |
| `s7-idp` (10.57.0.30) | **Keycloak 26.8**, realm `tidewater`; admin console on http://localhost:8031 (`admin` / `admin-lab`) |
| `s7-sso` (10.57.0.40) | **OAuth2 Proxy 7.15**, client `portal` |
| 10.57.0.5 | The head office's address (`office` in `helpers.sh`) |
| :8094, 127.0.0.1:8085 (`s7-plus`, 10.57.0.60) | NGINX Plus for the side quest, and its API |

```bash
cd /srv/nginx-journey/sprints/sprint-7/lab
cp day1_nginx.conf nginx.conf           # or the day's config, or starter_nginx.conf for the sprint lab
./lab.sh up                             # PKI, network, apps, Keycloak, OAuth2 Proxy, edge, then the ready check
source helpers.sh                       # partner, ops, office, login, as, cert, revoke, ...
./lab.sh down                           # when you're done for the day
```

**Memory.** Keycloak needs about 0.6–0.7 GB (the container is capped at 1 GB). With everything up, the lab uses under 1 GB.

**Generated on the first `up` (owner-only, not in git):**
* `lab/certs/`, made by `pki.sh` in the `nginx:mainline` image (OpenSSL 3.5): the **Tidewater Internal CA** (the edge's server certificate, the ledger's, and the edge's client certificate), the **Tidewater Partner CA** (`acme`, `globex`, `initech`, with Initech revoked on the CRL), and a **Rogue CA** (`fake-acme` and the ledger's `impostor`). `./lab.sh pki` makes a new set.
* `lab/secrets/ops_tokens.json` (a viewer token for carol, an admin token for dave) and the OAuth2 Proxy cookie secret.

**Keycloak's realm (`lab/realm.json`):** users **alice** (`staff`, `admins`; `alice-pass`) and **bob** (`staff`; `bob-pass`); clients `portal` (OAuth2 Proxy), `plus-portal` (the side quest), and `dispatch-cli` (bearer tokens for the side quest, audience `dispatch-api`). The issuer is `https://localhost:8091/realms/tidewater`: the browser reaches Keycloak through the edge, and OAuth2 Proxy and NGINX Plus use its internal address for the back channel.

**`lab.sh`**
* `up`, `check`, `reload` (reports a reload the master refused), `t`/`T`, `edge` (recreate only the edge), `down`.
* `pki`, `stats` / `reset` (the apps' counters, including authz calls), `impostor on|off` (the ledger's address answers with the rogue certificate; switching cuts open connections), `logs [edge|apps|idp|sso|plus]`.
* `plus up|down|reload|t` for the side quest. The whole `lab/` directory is mounted into the edge at `/lab`, so edits and a new CRL are seen by a reload. Logs are in `lab/logs/`.

**`helpers.sh`**
* `r PATH` / `rh PATH`: one request to :8091 (`rh` with headers). `partner NAME PATH`: one request to :8092 with a partner's certificate (`acme`, `globex`, `initech`, `fake-acme`, `none`).
* `ops WHO PATH` (`viewer`, `admin`, `bogus`, `none`), `office PATH` (from 10.57.0.5).
* `login USER`, `as USER PATH`, `logout USER`: a scripted browser sign-in through Keycloak and requests with its cookies.
* `cert NAME`, `revoke` / `unrevoke NAME`, `crl`, `crl-short SECONDS`, `crl-fresh`.
* `astats` / `areset`, `elog` / `alog`.
* Side quest: `pr` / `prh`, `jwt USER`, `decode TOKEN`, `api USER PATH`, `plogin USER`, `pas USER PATH`.

**From a browser:** every URL is `https://localhost:809x`, so tunnel the ports from your workstation (`ssh -L 8091:localhost:8091 -L 8092:localhost:8092 <lab-host>`) and accept the lab CA's certificate warning, or import `lab/certs/internal-ca.crt`.

> **Version notes (verified on nginx 1.31.6 / OpenSSL 3.5.7 in `nginx:mainline`, Keycloak 26.8.2, OAuth2 Proxy 7.15.6, NGINX Plus R37.1.1):**
> * **Since nginx 1.29.7, upstream connections are kept alive by default** (`keepalive` on in `upstream` blocks, `proxy_http_version 1.1`). A TLS connection to an upstream is verified once and then reused.
> * There's no variable for a client certificate's subject alternative names, in open source or Plus.
> * NGINX Plus's OIDC module requires an `https` issuer (`[emerg] issuer URL requires "https" scheme`).
> * In the lab, the `auth_request` subrequest reached the authorization service as a `GET` whatever the client's method.

---

## 3. Daily Detail

### Day 1: Mutual TLS, Both Ways
**Concepts:**
* CertificateRequest, the client certificate and proof of possession.
* `ssl_client_certificate`, `ssl_verify_client` (`on`, `optional`, `optional_no_ca`), `ssl_verify_depth`; codes 495 and 496.
* `$ssl_client_*` variables; no SAN variable; identity only from a verified certificate.
* CRLs (read at reload, with their own expiry), OCSP, short-lived certificates.
* `proxy_ssl_certificate`, `proxy_ssl_verify` (off by default), `proxy_ssl_trusted_certificate`, `proxy_ssl_name`; kept-alive upstream connections.

**Lab:**
* Require a certificate; JSON refusals with `error_page 495`/`496`.
* Identity headers, a spoofed `X-Partner`, and a CN map.
* `optional_no_ca` and a forged CN, then a map that depends on verification.
* Revoking Initech and Globex, and a CRL that expires.
* The edge's client certificate for the ledger, an impostor ledger, and the name check.

### Day 2: `auth_request`
**Concepts:**
* Subrequests, status codes, `auth_request_set`.
* What the authorization service sees: headers, URI, method, body.
* Failing closed and timeouts.
* Caching decisions: the key, negative answers, the revocation delay.
* `satisfy any` / `all`.

**Lab:**
* The ops tool behind the authz service; `WWW-Authenticate` passed on.
* User and role to the tool, the token kept from it.
* A viewer's `POST` allowed until the method is passed.
* A wrong path and a slow service: `500`.
* One authz call for five requests, and a cache key that lets a viewer write.
* The head office without a token.

### Day 3: Single Sign-On & the Sprint Lab
**Concepts:**
* The OIDC authorization code flow with PKCE; front and back channel.
* OAuth2 Proxy's endpoints and `X-Auth-Request-*` headers.
* One issuer, two addresses: Keycloak's hostname options and its front door.
* Proxy sessions vs IdP sessions; sign-out.

**Lab:**
* The discovery document both ways; no admin console on the front door.
* OAuth2 Proxy behind `auth_request` and `error_page 401`.
* `sub` vs username, and the session cookie that reached the application.
* `allowed_groups=admins`.
* A sign-out that signs you straight back in.
* Then build the Tidewater edge (Section 4) and pass `test_sprint07.sh`.

---

## 4. Lab Specification: The Tidewater Edge

Copy `lab/starter_nginx.conf` to `lab/nginx.conf`. The edge listens on 8092 (partner API) and 8091 (portal, ops tool, Keycloak's front door, which the starter already has). The upstreams are defined in the starter.

**Requirements:**
1. **No certificate:** a request to the partner API without a client certificate gets `401` with a JSON body containing an `"error"` field, and never reaches the partner API.
2. **Untrusted and revoked certificates:** a client certificate that isn't from the Tidewater Partner CA, or that is on its CRL (`certs/partner-ca.crl`), gets `403` with a JSON body containing an `"error"` field, and never reaches the partner API.
3. **Partner identity:** the partner API receives `X-Partner` set to the CN of the verified client certificate, and `X-Partner-Cert` set to the certificate itself (URL-escaped PEM). A client's own `X-Partner` never reaches it.
4. **Ledger:** `/ledger/` on the partner API port is proxied to the `ledger` upstream over HTTPS. The edge presents `certs/edge-client.crt`, and only talks to a ledger whose certificate is from the Tidewater Internal CA for the name `ledger.internal`.
5. **Ops authorization:** every request under `/ops/` is authorized by the authz service (`GET /check` on the `authz` upstream). Without a token it accepts, the client gets `401`. The ops tool receives `X-Ops-User` and `X-Ops-Role` as the authz service returned them, never as the client sent them, and never receives the client's token.
6. **Viewers:** a viewer's requests that change something (any method but `GET` and `HEAD`) get `403` and never reach the ops tool. An admin's `POST` reaches it with its body.
7. **Caching:** each token's decision is cached for 30 seconds, separately per method, including refusals: repeated requests with the same token and method reach the authz service at most once in that time. One token's or one method's decision never answers for another.
8. **The head office:** `/ops/status` is served to the head office (10.57.0.5) without a token. From anywhere else it needs a valid token, and the rest of `/ops/` always does.
9. **Staff portal:** `/portal/` requires a sign-in through OAuth2 Proxy and Keycloak: a request without a session is redirected to Keycloak's login page. The portal receives the signed-in user's username (not the subject ID) as `X-User` and their groups as `X-Groups`, never what the client sent, and receives no cookies.
10. **Admins:** `/portal/admin/` is for members of the `admins` group: other signed-in staff get `403`, and a request without a session is redirected to sign in.

`lab/solution_nginx.conf` is the reference.

---

## 5. Automated Test Suite (`test_sprint07.sh`)

```bash
cd /srv/nginx-journey/sprints/sprint-7 && ./test_sprint07.sh
```
* It runs `lab/lab.sh check` first. If the lab isn't ready, it stops with a setup message and tests nothing.
* It adds two ops tokens of its own to `lab/secrets/ops_tokens.json` (and removes them at the end), and uses fresh paths, so earlier runs and decisions the edge has cached don't affect it.
* It takes a few seconds: it signs in as bob and alice through Keycloak.
* Run against the untouched starter, it reports 0/10 and **`Sprint 7 start is ready to go`**.
* Override `EDGE`, `PARTNER` or `CONTROL` to point it elsewhere.

| # | Assertion (gate: 10/10) | Requirement |
| :--- | :--- | :---: |
| 1 | No certificate: `401` with a JSON `"error"`, and the partner API never sees it | 1 |
| 2 | `fake-acme` (rogue CA) and `initech` (revoked): `403` with a JSON `"error"`, never reaching the API; `globex` is served | 2 |
| 3 | `acme` sending `X-Partner: globex` arrives as `acme`; `globex` as `globex`; the API reads `URI:spiffe://partners.tidewater/acme` from `X-Partner-Cert` | 3 |
| 4 | `/ledger/` answers `200` and the ledger saw `tidewater-edge`; with the impostor `502`; the real ledger again `200` | 4 |
| 5 | No token and a made-up token: `401`; the viewer and admin tokens arrive as carol/viewer and dave/admin despite spoofed headers, without the token | 5 |
| 6 | A viewer's `POST` and `DELETE`: `403`, never reaching the tool; an admin's `POST` arrives with its 7-byte body | 6 |
| 7 | Five requests with a new made-up token: five `401`s and one authz call; five with the viewer token: no new call; then the viewer's `POST`: `403`; another made-up token: `401` | 7 |
| 8 | `/ops/status`: the office `200` without a token; the host `401` without one and `200` with one; the office on another `/ops/` path: `401` | 8 |
| 9 | Anonymous `/portal/` ends on Keycloak's login page; bob signed in (sending `X-User: alice`) arrives as `bob`, groups `staff`, no cookies | 9 |
| 10 | `/portal/admin/`: bob `403`, alice `200`, anonymous `302` | 10 |

---

## 6. Daily Quizzes

All pools live in [`data/quizzes.json`](../../data/quizzes.json). Each day has 20 questions (8 scenario, 6 config, 3 diagnose, 3 recall). The quiz draws 10, and 8/10 passes.

* **Day 1:** verify modes and 495/496, trust anchors and advertised CAs, `$ssl_client_*` and the SAN gap, verified identity and spoofing, CRLs, `proxy_ssl_*`.
* **Day 2:** `auth_request` status handling, `auth_request_set`, what the subrequest carries, failing closed, cache keys and lifetimes, `satisfy`.
* **Day 3:** the code flow and PKCE, OAuth2 Proxy's endpoints and headers, the issuer and the front door, `sub` vs username, cookies, groups, sign-out.
* **Enterprise:** `auth_jwt`, JWKS caching, `auth_jwt_require`, array claims, `oidc_provider` / `auth_oidc`, the callback, open source vs Plus.

```bash
cd /srv/nginx-journey && python3 -m http.server 8090
# http://<lab-host>:8090/quiz.html?sprint=7&day=1   (day=2, day=3, and day=3&pool=enterprise)
```

---

## 7. Optional Extras

* **7.1 OCSP instead of a CRL.** What would `ssl_ocsp on;` change for Tidewater's partner API, and what new failure would it bring?

  <details>
  <summary>Answer</summary>

  NGINX would ask the CA's OCSP responder about each client certificate (cached with `ssl_ocsp_cache`), so a revocation takes effect within the cache lifetime, without publishing a CRL and reloading every edge. The responder becomes part of every new partner connection: if it's down or slow, verification fails or stalls. A CRL's failure mode is its expiry date; OCSP's is the responder's availability.
  </details>

* **7.2 Short-lived certificates.** If partner certificates lasted 24 hours and were renewed automatically, what would you still need from today's lab?

  <details>
  <summary>Answer</summary>

  The trust anchor, the verification mode, the identity map and the header hygiene stay the same. Revocation matters much less: a stolen certificate is useless within a day. What you add is the renewal path (ACME, SPIFFE/SPIRE, a mesh's CA) and monitoring of `$ssl_client_v_remain`, because now an expiry is an outage within a day instead of within a year.
  </details>

* **7.3 Where should the session live?** OAuth2 Proxy keeps the whole session in an encrypted cookie. What does that mean with three edge nodes, and with a 4 KB cookie limit?

  <details>
  <summary>Answer</summary>

  Any node can validate the cookie without shared state, as long as they share the cookie secret: that's the appeal. The cost is size: tokens with many groups can push the cookie past browser limits (OAuth2 Proxy then splits it into several cookies), and a server-side store (Redis, `--session-store-type=redis`) keeps only an ID in the cookie, at the price of a shared dependency. NGINX Plus's OIDC module keeps the session on the NGINX side and only an ID in the cookie, so nodes must share that state or keep a user on one node.
  </details>

* **7.4 The token the API never sees.** Day 2's ops tool gets `X-Ops-User` instead of the token. When would an application still need the token itself?

  <details>
  <summary>Answer</summary>

  When it calls other services on the user's behalf and those services check the token themselves (end-to-end identity rather than a trusted edge). Then forward it deliberately, to that application only, ideally exchanged for a token whose audience is the downstream service (OAuth token exchange), rather than passing the user's original token everywhere.
  </details>

---

## 8. Tracker Sync

* **Platform milestone:** Tidewater's edge admits partners only with a valid, unrevoked certificate and tells the API which partner it is; proves itself to the finance ledger and refuses an impostor; puts every ops action through the authorization service, with decisions cached safely; lets the head office's screen in by address; and signs staff in once through Keycloak, with admin pages for admins.
* **Graduation:** `test_sprint07.sh` 10/10, and at least 80% on each day's quiz.

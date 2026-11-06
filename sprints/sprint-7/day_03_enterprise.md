# Sprint 7 &bull; Day 3 (Optional) Enterprise Side Quest: JWT Validation and Native OpenID Connect

**Day:** Optional, after Day 3  
**Estimated Time:** 45 Minutes (10 concepts, 5 setup, 30 hands-on)  
**Theme:** Today's single sign-on needed a second program, OAuth2 Proxy, because open source NGINX can't validate a token or run an OpenID Connect flow by itself. NGINX Plus can do both: **`auth_jwt`** checks bearer tokens against the IdP's published keys, and the **OIDC module** (`oidc_provider` + `auth_oidc`) signs users in with no proxy next to it. You put Tidewater's dispatch API behind Keycloak's tokens, and rebuild the staff portal's sign-in in NGINX Plus itself.

> **Status:** run end to end on the lab box on NGINX Plus R37.1.1 (nginx 1.31.3), with the commands below.

---

## 1. Concepts to Understand (10 Minutes)

### 1.1 A Bearer Token Is Checked, Not Looked Up
A command-line tool or a service doesn't have a browser to sign in with. It gets an **access token** from the IdP and sends it with each request: `Authorization: Bearer <JWT>`.
* A JWT is `header.claims.signature`. Keycloak signs with RS256: its private key signs, and anyone can check with the **public keys** it publishes as a **JWKS** (`.../protocol/openid-connect/certs`). The header's `kid` says which key.
* **`auth_jwt "realm";`** turns the check on in a location: signature, `exp` and `nbf`. **`auth_jwt_key_request /_jwks;`** fetches the keys through a subrequest (an `internal` location that proxies to the IdP), and **`auth_jwt_key_cache 10m;`** keeps them. No call to the IdP per request: that's the difference from Day 2's `auth_request`.
* A valid signature only proves the IdP issued it. **Who it was issued for** is in the claims: `iss` (which IdP and realm), `aud` (which API it's meant for), `azp` (which client asked). **`auth_jwt_require $a $b ...;`** refuses the token unless every variable is non-empty and not `0`, with `error=403` to refuse with `403` instead of `401`.
* **Claims become variables:** `$jwt_claim_preferred_username`, `$jwt_claim_iss`, and so on. Array claims (`groups`) need **`auth_jwt_claim_set $var groups;`**, which joins them with commas.

### 1.2 Native OpenID Connect
```nginx
oidc_provider tidewater {
    issuer        https://localhost:8091/realms/tidewater;
    config_url    http://10.57.0.30:8080/realms/tidewater/.well-known/openid-configuration;
    client_id     plus-portal;
    client_secret plus-lab-secret;
}
```
* **`auth_oidc tidewater;`** in a location does what OAuth2 Proxy and `auth_request` did together: no session, redirect to the IdP (with PKCE, `state` and `nonce`); on return, exchange the code, check the ID token, create a session.
* **The session lives in NGINX Plus's shared memory**, referenced by a cookie (`NGX_OIDC_SESSION`), not in an encrypted cookie.
* **Claims are variables:** `$oidc_claim_preferred_username`, `$oidc_claim_groups` (arrays are joined with commas).
* **The callback** is `/oidc_callback` by default (`redirect_uri`). It's an ordinary URI: it must reach a location where `auth_oidc` is on.
* **The issuer must be `https`.** The module refuses to load with an `http` issuer. `config_url` overrides where the metadata comes from, so the back channel can stay internal.

### 1.3 Open Source vs Plus

| Need | Open source | NGINX Plus |
| :--- | :--- | :--- |
| Browser sign-in | OAuth2 Proxy (or another proxy) + `auth_request` | `oidc_provider` + `auth_oidc` |
| Session | The proxy's encrypted cookie | Plus shared memory + a cookie |
| Bearer tokens for an API | `auth_request` to a validator, or njs with `crypto.subtle` and a JWKS you fetch and cache yourself | `auth_jwt` + `auth_jwt_key_request` + `auth_jwt_key_cache` |
| Claims as variables | Headers from the validator, or njs | `$jwt_claim_*`, `$oidc_claim_*` |
| Moving parts | NGINX + a proxy (or your script) | NGINX Plus |

BIG-IP equivalents: APM's OAuth resource server (JWT validation with a JWK configuration and a provider) for `auth_jwt`, and APM as an OAuth client / OIDC relying party for `auth_oidc`.

---

## 2. Lab Setup (5 Minutes)

This side quest uses the [NGINX Plus lab convention](../../docs/nginx-plus-lab.md): the license in `~/plus/license.jwt`, the image in `~/plus/plus.env`. The main lab must be running: Keycloak's front door is the open source edge.

```bash
cd /srv/nginx-journey/sprints/sprint-7/lab
./lab.sh up                             # if it isn't running already
./lab.sh plus up                        # s7-plus: :8094 HTTPS, Plus API on 127.0.0.1:8085
source helpers.sh
```
`lab/plus/nginx.conf` is the Plus configuration: `/api/` (the dispatch API) and `/portal/` both go to the portal app, unprotected. After each edit, `./lab.sh plus reload`.

| Command | What it does |
| :--- | :--- |
| `jwt USER` | An access token for USER from Keycloak, for the `dispatch-cli` client (passwords `alice-pass`, `bob-pass`) |
| `decode TOKEN` | A token's claims, unchecked |
| `pr PATH` / `prh PATH` | One request to Plus (:8094) with no token or session (`prh` shows the headers) |
| `api USER PATH [curl options]` | One request to Plus's `/api/` with a fresh token for USER |
| `plogin USER` / `pas USER PATH` | Sign in to Plus's portal through Keycloak / one request with that session |

Keycloak already has the clients: `dispatch-cli` (puts `dispatch-api` in the token's audience) and `plus-portal` (redirect URI `https://localhost:8094/oidc_callback`).

---

## 3. Hands-on (30 Minutes)

### 3.1 Look at a Token (3 min)
```bash
T=$(jwt bob); decode "$T" | grep -E '"(iss|aud|azp|exp|preferred_username)"' ; decode "$T" | grep -A2 groups
curl -s --cacert certs/internal-ca.crt https://localhost:8091/realms/tidewater/protocol/openid-connect/certs | python3 -m json.tool | grep -E '"(kid|alg|use)"'
pr /api/loads | head -1
```
`iss` is `https://localhost:8091/realms/tidewater`, `aud` is `dispatch-api`, `azp` is `dispatch-cli`, and `groups` is an array. The JWKS lists the realm's keys by `kid`. `/api/loads` without any token: `200`. The API is open.

### 3.2 Check the Signature (7 min)
In `lab/plus/nginx.conf`, replace `location /api/ { ... }` with:
```nginx
location /api/ {
    auth_jwt             "dispatch";
    auth_jwt_type        signed;
    auth_jwt_key_request /_jwks;
    auth_jwt_key_cache   10m;
    proxy_set_header X-User   $jwt_claim_preferred_username;
    proxy_set_header X-Groups $jwt_claim_groups;
    proxy_set_header Authorization "";
    proxy_pass http://portal;
}

location = /_jwks {
    internal;
    proxy_pass http://10.57.0.30:8080/realms/tidewater/protocol/openid-connect/certs;
}
```
```bash
./lab.sh plus reload
pr /api/loads | head -1
api bob /api/loads | grep -E '<-|"user"|groups'
T=$(jwt bob); pr /api/loads -H "Authorization: Bearer ${T%?????}AAAAA" | head -1
```
No token: `401`. Bob's token: `200` as `bob`. A changed signature: `401`.

<details>
<summary><code>"groups"</code> is <code>null</code>. Why?</summary>

`groups` is a JSON array, and `$jwt_claim_groups` is empty for arrays. `auth_jwt_claim_set $jwt_groups groups;` (in `http`) gives `admins,staff` (3.4).
</details>

### 3.3 Is This Token for Us? (5 min)
The signature only says Keycloak issued the token. A token Keycloak issued to some other client of the realm, for some other API, is signed with the same key. In `http`:
```nginx
map $jwt_claim_iss $jwt_issuer_ok {
    "https://localhost:8091/realms/tidewater" 1;
    default                                    0;
}
map $jwt_claim_aud $jwt_audience_ok {           # aud can be a string or an array
    "~(^|,)dispatch-api(,|$)" 1;
    default                   0;
}
```
In `location /api/`:
```nginx
auth_jwt_require $jwt_issuer_ok $jwt_audience_ok;
```
```bash
./lab.sh plus reload
api bob /api/loads | head -1
```
Still `200`: bob's token is for `dispatch-api`.

<details>
<summary>Change <code>dispatch-api</code> in the map to <code>billing-api</code> and reload. What does bob get, and what does it show?</summary>

`401`: a correctly signed, unexpired token is refused because it wasn't issued for this API. Without the audience check, any token from the realm (one issued for the billing system, say) would open the dispatch API. Put `dispatch-api` back.
</details>

### 3.4 Admins Only (5 min)
In `http`:
```nginx
auth_jwt_claim_set $jwt_groups groups;
map $jwt_groups $jwt_is_admin {
    "~(^|,)admins(,|$)" 1;
    default             0;
}
```
In `location /api/`, change `X-Groups $jwt_claim_groups` to `X-Groups $jwt_groups`. Then add a location for the admin part of the API:
```nginx
location /api/admin/ {
    auth_jwt             "dispatch";
    auth_jwt_type        signed;
    auth_jwt_key_request /_jwks;
    auth_jwt_key_cache   10m;
    auth_jwt_require     $jwt_issuer_ok $jwt_audience_ok;
    auth_jwt_require     $jwt_is_admin error=403;
    proxy_set_header X-User   $jwt_claim_preferred_username;
    proxy_set_header X-Groups $jwt_groups;
    proxy_set_header Authorization "";
    proxy_pass http://portal;
}
```
```bash
./lab.sh plus reload
api bob /api/loads | grep groups
api bob /api/admin/users | head -1
api alice /api/admin/users | grep -E '<-|"user"|groups'
```
Bob's groups: `staff`; `/api/admin/`: `403`. Alice: `200`, `admins,staff`.

<details>
<summary>Keycloak rotates its signing key. What happens to tokens signed with the new key while NGINX still has the old JWKS cached?</summary>

Their `kid` isn't in the cached key set, so they fail until the cache expires (`auth_jwt_key_cache 10m`) and the keys are fetched again. IdPs publish a new key **before** using it, for longer than relying parties cache, so a sensible cache lifetime and the IdP's rotation overlap avoid the gap.
</details>

### 3.5 Sign-In Without OAuth2 Proxy (10 min)
In `http`:
```nginx
oidc_provider tidewater {
    issuer        https://localhost:8091/realms/tidewater;
    config_url    http://10.57.0.30:8080/realms/tidewater/.well-known/openid-configuration;
    client_id     plus-portal;
    client_secret plus-lab-secret;
}
```
Replace `location /portal/ { ... }` with:
```nginx
location /portal/ {
    auth_oidc tidewater;
    proxy_set_header X-User   $oidc_claim_preferred_username;
    proxy_set_header X-Email  $oidc_claim_email;
    proxy_set_header X-Groups $oidc_claim_groups;
    proxy_set_header Cookie   "";
    proxy_pass http://portal;
}
```
```bash
./lab.sh plus reload
prh /portal/ | grep -iE '^HTTP|^location' | cut -c1-180
plogin alice
docker logs s7-plus 2>&1 | grep oidc_callback | tail -1 | cut -c1-160
```
<details>
<summary>The sign-in ends at <code>404 https://localhost:8094/oidc_callback</code>. Why?</summary>

Keycloak sent the browser back to `/oidc_callback`, the default `redirect_uri`, and no location with `auth_oidc` covers that URI: it fell into the server's default handling, which looked for a file (`open() "/etc/nginx/html/oidc_callback" failed`). The callback has to reach the module.
</details>

```nginx
location = /oidc_callback {
    auth_oidc tidewater;
}
```
```bash
./lab.sh plus reload
plogin alice
pas alice /portal/home | grep -E '<-|"user"|email|groups|cookies'
plogin bob; pas bob /portal/home -H 'X-User: alice' | grep '"user"'
```
Alice: `200`, `admins,staff`, no cookies forwarded. Bob can't claim to be alice. That's Day 3's portal with one container fewer.

<details>
<summary>What did you <em>not</em> have to configure here that Day 3 needed?</summary>

An `/oauth2/` location, an internal auth location, `error_page 401` with a named `@login` location, `auth_request_set` for each header, and a separate service with its own cookie secret, its own flags for the three back-channel URLs, and its own process to monitor. The OIDC flow, the session and the claims are all inside NGINX Plus.
</details>

The complete answer is `lab/plus/solution_nginx.conf` (`PLUS_CONF=solution_nginx.conf ./lab.sh plus up` runs it).

---

## 4. Debrief

### What Plus Changed

| | Day 3 (open source) | Side quest (Plus) |
| :--- | :--- | :--- |
| Staff sign-in | OAuth2 Proxy + `auth_request` + `error_page` | `auth_oidc` |
| Where the session lives | OAuth2 Proxy's encrypted cookie | Plus shared memory |
| API tokens | Not covered: a validator behind `auth_request`, or njs | `auth_jwt` with the IdP's keys, cached |
| Per-request call to another service | Yes: `/oauth2/auth` | No |

### In BIG-IP Terms

| Tonight | BIG-IP |
| :--- | :--- |
| `auth_jwt` + `auth_jwt_key_request` | APM OAuth resource server: JWT provider + JWK configuration |
| `auth_jwt_require` on claims | Per-request policy branches on token claims |
| `oidc_provider` + `auth_oidc` | APM access profile with an OAuth Client / OIDC relying party |
| `$oidc_claim_*` → headers | Session variables → HTTP header SSO |

<details>
<summary>Question: open source NGINX with njs could check JWTs too (Sprint 6's HMAC check, but with RS256 and <code>crypto.subtle.verify</code>). What would you have to build that <code>auth_jwt</code> gives you?</summary>

Fetching the JWKS (`ngx.fetch`, with a resolver), caching it across requests and workers (a shared dictionary, refreshed with `js_periodic`), picking the key by `kid`, importing it (`crypto.subtle.importKey('jwk', ...)`), verifying the signature, and checking `exp`, `nbf`, `iss` and `aud` yourself, with every failure path tested. It works (an RS256 Keycloak token verified with njs's WebCrypto while this sprint was built), but it's code you own, and Sprint 6's lesson applies: native first, script where it earns it.
</details>

Clean up: `./lab.sh plus down`. Then the [Enterprise Quiz](../../quiz.html?sprint=7&day=3&pool=enterprise).

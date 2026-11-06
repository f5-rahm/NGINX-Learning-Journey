# Sprint 7 &bull; Day 3: Single Sign-On with OAuth2 Proxy & the Sprint Lab
**Day:** 3 of 3  
**Estimated Time:** 85 Minutes (15 concepts, 5 setup, 25 activities, 30 sprint lab, 10 quiz)  
**Theme:** Staff shouldn't have a password per application. They sign in once with the company's identity provider, and every internal application trusts that sign-in. On BIG-IP that's an APM access profile acting as an OAuth client / OpenID Connect relying party. Open source NGINX doesn't speak OpenID Connect itself, so the standard pattern pairs it with **OAuth2 Proxy**: NGINX asks it, with Day 2's `auth_request`, whether this browser has a session, and sends the browser to sign in when it doesn't. Today you put Tidewater's staff portal behind Keycloak, pass the right identity to the application, restrict the admin pages to a group, and then build the whole Tidewater edge from the starter.

---

## 1. Concepts to Understand (15 Minutes)

### 1.1 The Authorization Code Flow, in Browser Steps
OpenID Connect (OIDC) is a sign-in layer on OAuth 2.0. For a web application it works like this:
1. The browser asks for `/portal/`. It has no session, so it's **redirected to the identity provider (IdP)**, Keycloak, with the application's `client_id`, a `redirect_uri`, a random `state`, and a PKCE `code_challenge`.
2. **The user signs in at the IdP**, not at the application. The application never sees the password.
3. The IdP redirects the browser back to the `redirect_uri` with a one-time **code**.
4. The application **exchanges the code** at the IdP's token endpoint, server to server, with its client secret and the PKCE `code_verifier`. It gets an **ID token** (a signed JWT: who the user is) and an access token.
5. The application checks the ID token's signature against the IdP's published keys (the **JWKS**), its issuer, audience and expiry, then **creates its own session** (a cookie) so the next request doesn't repeat all this.

Steps 1–3 go through the browser (the **front channel**); step 4 and fetching the keys are direct (the **back channel**). `state` ties the callback to the browser that started the sign-in; PKCE ties the code to the client that asked for it.

### 1.2 OAuth2 Proxy Next to NGINX
OAuth2 Proxy does steps 1 and 3–5, and NGINX does the rest:

| URI on the edge | Who handles it | What happens |
| :--- | :--- | :--- |
| `/portal/...` | NGINX: `auth_request /oauth2/auth` | Valid session cookie: `202`, plus `X-Auth-Request-*` headers. No session: `401`. |
| `/oauth2/auth` (internal) | OAuth2 Proxy | Checks the cookie. `?allowed_groups=admins` also checks group membership: `403` if not a member. |
| `/oauth2/start?rd=/portal/x` | OAuth2 Proxy | Sends the browser to the IdP (step 1), remembering where to come back to |
| `/oauth2/callback` | OAuth2 Proxy | Exchanges the code (step 4), sets the session cookie, sends the browser back to `rd` |
| `/oauth2/sign_out` | OAuth2 Proxy | Deletes its session cookie |

* **The `401` from `auth_request` becomes a redirect** with `error_page 401 = @login;` and a named location that `return 302 /oauth2/start?rd=$request_uri;`.
* **The session lives in OAuth2 Proxy's cookie** (`_tidewater_sso` here), encrypted with a secret only OAuth2 Proxy knows. NGINX never decrypts it.
* **The identity comes back as headers** on the `/oauth2/auth` response: `X-Auth-Request-User` (the token's `sub`, a UUID in Keycloak), `X-Auth-Request-Preferred-Username`, `X-Auth-Request-Email`, `X-Auth-Request-Groups`. Day 2's `auth_request_set` carries them to the application.

### 1.3 One IdP, Two Addresses
The browser reaches Keycloak through the edge, at `https://localhost:8091/realms/tidewater`. OAuth2 Proxy reaches it directly, at `http://10.57.0.30:8080`. Tokens carry an **issuer** (`iss`), and everyone must agree on it:
* Keycloak's `--hostname https://localhost:8091` fixes the public URL and the issuer. `--hostname-backchannel-dynamic` lets back-channel callers use the internal address for the token endpoint and keys.
* OAuth2 Proxy is told the issuer, and separately where to send the browser (`--login-url`), where to redeem codes (`--redeem-url`) and where the keys are (`--oidc-jwks-url`).
* **The edge's front door for Keycloak** proxies `/realms/` and `/resources/` (the login pages and their scripts and styles) with `Host`, `X-Forwarded-Proto` and `X-Forwarded-Port`, so the URLs Keycloak writes into its pages point back through the edge. The admin console isn't on the front door: it's on a separate local port.

### 1.4 Sessions and Signing Out
Two sessions exist after a sign-in: **OAuth2 Proxy's cookie** for the portal (7 days by default) and **Keycloak's own SSO session** (its cookies, on the IdP's paths). Deleting one doesn't delete the other (Activity 3.5). A complete sign-out also ends the IdP session (OIDC RP-initiated logout, at the IdP's `end_session_endpoint`).

### 1.5 BIG-IP Lens

| Need | BIG-IP APM | NGINX open source |
| :--- | :--- | :--- |
| Act as an OIDC relying party | Access profile + OAuth Client agent, OAuth provider / server objects | OAuth2 Proxy, behind `auth_request` |
| Session | APM session (`MRHSession` cookie, session DB on the device) | OAuth2 Proxy's encrypted cookie |
| Claims to the application | Session variables → HTTP header SSO / iRule `HTTP::header insert` | `X-Auth-Request-*` → `auth_request_set` → `proxy_set_header` |
| Group-based access | Policy branch on a claim, or an ACL | `/oauth2/auth?allowed_groups=...` |
| Sign-out | `/vdesk/hangup.php3`, plus IdP logout | `/oauth2/sign_out`, plus IdP logout |

NGINX Plus does OIDC natively, without OAuth2 Proxy: that's today's [side quest](day_03_enterprise.md).

---

## 2. Lab Setup (5 Minutes)

```bash
cd /srv/nginx-journey/sprints/sprint-7/lab
cp day3_nginx.conf nginx.conf           # Days 1 and 2 finished; the portal is still open
./lab.sh up                             # or ./lab.sh reload if the lab is still up
source helpers.sh
```
Keycloak's realm `tidewater` has two staff members: **alice** (groups `staff` and `admins`, password `alice-pass`) and **bob** (`staff`, `bob-pass`). OAuth2 Proxy (`s7-sso`) is already configured as the `portal` client; you wire it into NGINX.

| Command | What it does |
| :--- | :--- |
| `r PATH` / `rh PATH` | One request to :8091 without a session (`rh` with headers) |
| `login USER [PASSWORD]` | Walks the sign-in like a browser: `/oauth2/start`, Keycloak's login form, the callback. Keeps the cookies in `lab/temp/jars/USER.txt`. |
| `as USER PATH [curl options]` | One request with USER's cookies (and keeps any new ones) |
| `logout USER` | Forgets USER's cookies |

The portal app answers with JSON: `user`, `email` and `groups` as it received them, and the names of the cookies it received (`cookies_received`).

**From a browser:** the URLs are `https://localhost:8091`, so from your workstation use an SSH tunnel (`ssh -L 8091:localhost:8091 <lab-host>`), then open `https://localhost:8091/portal/` and accept the lab CA's certificate warning.

---

## 3. Hands-on Guided Discovery Activities (25 Minutes)

### Activity 3.1: The IdP's Two Faces (4 min)
```bash
r /realms/tidewater/.well-known/openid-configuration | sed 1d | python3 -m json.tool | grep -E '"(issuer|authorization_endpoint|token_endpoint)"'
curl -s http://127.0.0.1:8031/realms/tidewater/.well-known/openid-configuration | python3 -m json.tool | grep -E '"(issuer|authorization_endpoint|token_endpoint)"'
r /admin/ | head -2
```
Through the front door, every endpoint is `https://localhost:8091/...`. Through the direct port, the issuer and the authorization endpoint are the same, but the token endpoint is the direct address. `/admin/` on the edge is the edge's own default answer: the admin console isn't exposed.

<details>
<summary>Why must the issuer be identical both ways?</summary>

Every token carries the issuer it was minted under (`iss`), and every relying party checks it against the issuer it was configured with. If the browser-facing and server-facing views disagreed, tokens obtained in the browser would fail validation on the server. The endpoints can differ; the issuer can't.
</details>

### Activity 3.2: Wire In OAuth2 Proxy (8 min)
In the `:8091` server, replace `location /portal/ { ... }` with:
```nginx
location /oauth2/ {
    proxy_set_header Host              $http_host;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-For   $remote_addr;
    proxy_pass http://sso;
}
location = /oauth2/auth {
    internal;
    proxy_pass http://sso;
    proxy_set_header Host              $http_host;
    proxy_set_header X-Forwarded-Proto https;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
}

location /portal/ {
    auth_request /oauth2/auth;
    error_page 401 = @login;
    auth_request_set $sso_user   $upstream_http_x_auth_request_user;
    auth_request_set $sso_groups $upstream_http_x_auth_request_groups;
    proxy_set_header X-User   $sso_user;
    proxy_set_header X-Groups $sso_groups;
    proxy_pass http://portal;
}

location @login {
    return 302 /oauth2/start?rd=$request_uri;
}
```
```bash
./lab.sh reload
rh /portal/reports | grep -iE '^HTTP|^location'
rh '/oauth2/start?rd=/portal/reports' | grep -iE '^HTTP|^location' | cut -c1-160
login bob
as bob /portal/reports
```
An anonymous request is sent to `/oauth2/start`, which sends it on to Keycloak with `client_id=portal`, `code_challenge_method=S256` and a `state`. `login bob` ends at `200 https://localhost:8091/portal/`, and the portal answers for bob.

<details>
<summary>Look at what the portal received. What two things are wrong?</summary>

* `"user"` is a UUID (`5d33c125-...`), not `bob`. `X-Auth-Request-User` is the token's `sub`, Keycloak's internal user ID: stable, but no use to an application that expects a username.
* `"cookies_received": ["_tidewater_sso"]`. The browser's session cookie went to the application. Anyone with access to the application's logs or code can now replay bob's session at the edge.
</details>

### Activity 3.3: The Right Name, and Nothing Else (4 min)
In `location /portal/`, use the username and the email, and drop the cookies:
```nginx
auth_request_set $sso_user   $upstream_http_x_auth_request_preferred_username;
auth_request_set $sso_email  $upstream_http_x_auth_request_email;
auth_request_set $sso_groups $upstream_http_x_auth_request_groups;
proxy_set_header X-User   $sso_user;
proxy_set_header X-Email  $sso_email;
proxy_set_header X-Groups $sso_groups;
proxy_set_header Cookie   "";
```
```bash
./lab.sh reload
as bob /portal/reports -H 'X-User: alice' | grep -E 'user|email|cookies'
```
`"user": "bob"` (not the `alice` he claimed), his email, and `"cookies_received": []`.

<details>
<summary>The portal itself might need a cookie of its own one day. What then?</summary>

Then clearing every cookie is too blunt, and you'd remove only the session cookie, for example with a `map` on `$http_cookie` that cuts `_tidewater_sso=...` out of the header. The rule stays the same: the edge's session cookie is the edge's business.
</details>

### Activity 3.4: Admins Only (5 min)
`/portal/admin/` is for the `admins` group. OAuth2 Proxy's auth endpoint can check groups itself. Add, in the `:8091` server:
```nginx
location = /_sso_admins {
    internal;
    proxy_pass http://sso/oauth2/auth?allowed_groups=admins;
    proxy_set_header Host              $http_host;
    proxy_set_header X-Forwarded-Proto https;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
}

location /portal/admin/ {
    auth_request /_sso_admins;
    error_page 401 = @login;
    auth_request_set $sso_user   $upstream_http_x_auth_request_preferred_username;
    auth_request_set $sso_email  $upstream_http_x_auth_request_email;
    auth_request_set $sso_groups $upstream_http_x_auth_request_groups;
    proxy_set_header X-User   $sso_user;
    proxy_set_header X-Email  $sso_email;
    proxy_set_header X-Groups $sso_groups;
    proxy_set_header Cookie   "";
    proxy_pass http://portal;
}
```
```bash
./lab.sh reload
as bob /portal/admin/users | head -1
login alice
as alice /portal/admin/users | grep -E '<-|"user"|groups'
rh /portal/admin/users | grep -iE '^HTTP|^location'
```
Bob: `403`. Alice: `200`, groups `admins,staff`. A stranger: sent to sign in.

<details>
<summary>Why not check the group in NGINX with a <code>map</code> on <code>$sso_groups</code>?</summary>

Not with `if`: it runs in the rewrite phase, before `auth_request` has asked anything, so `$sso_groups` is still empty there. The variables set by `auth_request_set` are only usable afterwards (in `proxy_set_header`, the log, or njs in the content phase). Letting OAuth2 Proxy answer `403` puts the group check in the same access-phase decision as the session check, and the edge configuration stays a list of "this path needs that group". Either way, the group comes from the signed token, never from the request.
</details>

### Activity 3.5: Signing Out Isn't Signing Out (4 min)
```bash
as bob /oauth2/sign_out | head -1
as bob /portal/reports | head -1
curl -s -L --cacert certs/internal-ca.crt -b temp/jars/bob.txt -c temp/jars/bob.txt -o /dev/null \
     -w '%{http_code} %{url_effective}\n' 'https://localhost:8091/oauth2/start?rd=/portal/reports'
as bob /portal/reports | grep '"user"'
```
After `sign_out`, the portal sends bob to sign in (`302`). But following that sign-in, he's back on `/portal/reports` as bob, without typing a password.

<details>
<summary>What happened, and how would a real sign-out work?</summary>

`/oauth2/sign_out` deleted OAuth2 Proxy's cookie, but Keycloak's own session (its cookies in bob's jar) is still alive, so Keycloak signed him in again silently. On a shared computer that's a problem. A full sign-out also ends the IdP session: OAuth2 Proxy can redirect to Keycloak's `end_session_endpoint` after clearing its cookie (`/oauth2/sign_out?rd=<the IdP's logout URL>`, with the IdP's domain allowed in `--whitelist-domain`), and Keycloak then ends its session and sends the browser back.
</details>

---

## 4. The Sprint Lab: The Tidewater Edge (30 Minutes)

Build Tidewater's edge from the starter: the requirements are in [`README.md` section 4](README.md#4-lab-specification-the-tidewater-edge). You may reuse anything you wrote this week.

Start with the baseline: the starter loads, and every requirement fails.
```bash
cd /srv/nginx-journey/sprints/sprint-7/lab
cp starter_nginx.conf nginx.conf
./lab.sh reload
cd .. && ./test_sprint07.sh
```
The run ends with `Requirements: 0 / 10 passed` and **`Sprint 7 start is ready to go`**. Then work through the TODOs, reload, and run the test as often as you like. Each failure says what it sent and what came back.

<details>
<summary>Hints, if you're stuck (one per requirement, no code)</summary>

* **No certificate:** which code does NGINX use internally for "no certificate", and how do you answer it with JSON?
* **Untrusted and revoked:** both are verification failures. Which file lists revoked serials?
* **Identity:** the test sends a client certificate *and* a different `X-Partner` header. And which certificate's CN may become `X-Partner`?
* **Ledger:** three separate things: present a certificate, check the ledger's, and the name to check it against.
* **Ops identity:** the tool must not receive the token.
* **Viewers:** what method does the authz service see?
* **Caching:** the test uses tokens it has never used before, and expects exactly one authz call for five requests with the same one. Then a `POST` with a token whose `GET` is cached.
* **Office:** only `/ops/status`, and the host without a token must still get `401`.
* **Portal:** the test sends `X-User: alice` while signed in as bob.
* **Admins:** a stranger must be sent to sign in, not refused.
</details>

`lab/solution_nginx.conf` is the reference.

---

## 5. Day 3 Concept Examination (10-Question Randomized Quiz)

```bash
cd /srv/nginx-journey && python3 -m http.server 8090
```
👉 **http://&lt;lab-host&gt;:8090/quiz.html?sprint=7&day=3**

**Enterprise side quest (optional):** [NGINX Plus: JWT Validation and Native OpenID Connect](day_03_enterprise.md), with its quiz at `quiz.html?sprint=7&day=3&pool=enterprise`.

When you're done: `./lab.sh down`.

---

## 6. Key Takeaways for Day 3
* **OAuth2 Proxy + `auth_request`** is open source NGINX's single sign-on: NGINX asks, OAuth2 Proxy holds the session and talks to the IdP.
* **`error_page 401 = @login`** turns "no session" into a redirect to `/oauth2/start?rd=...`.
* **Pass the username, not the `sub`,** and never forward the edge's session cookie to the application.
* **Groups come from the token:** `/oauth2/auth?allowed_groups=...` answers `403` for non-members.
* **The IdP needs one public issuer,** a front door that forwards `Host`, `X-Forwarded-Proto` and `X-Forwarded-Port`, and its admin console kept off the front door.
* **Signing out of the proxy isn't signing out of the IdP.**

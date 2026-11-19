# Sprint 7 Recap Notes (working file)
Raw findings and clarifications collected during the sprint, to be shaped into the recap. Everything here was verified on nginx 1.31.6 / OpenSSL 3.5.7 in the `nginx:mainline` container, Keycloak 26.8.2, OAuth2 Proxy 7.15.6 and NGINX Plus R37.1.1, unless marked otherwise.

---

## Findings From Building the Sprint

### Mutual TLS (Day 1)
* **`$ssl_client_s_dn` is RFC 2253 order:** `OU=Integrations,O=Acme Freight,CN=acme`, CN last. A CN `map` needs `(^|,)CN=` rather than a leading `/CN=` (that's the `_legacy` variant's format).
* **No SAN variable.** The binaries of both `nginx:mainline` and Plus R37.1 have `ssl_client_cert`, `_escaped_cert`, `_fingerprint`, `_i_dn`, `_raw_cert`, `_s_dn`, `_serial`, `_sigalg`, `_v_end`, `_v_remain`, `_v_start`, `_verify` (and the `_legacy` DNs), and nothing for subject alternative names. The lab forwards `$ssl_client_escaped_cert` and the Python app reads the SANs from it (`DNS:api.acme.example`, `URI:spiffe://partners.tidewater/acme`).
* **The modes, measured:** `on`: no certificate → `400 No required SSL certificate was sent` (496), rogue CA → `400 The SSL certificate error` (495). `optional`: no certificate → served with `NONE`, rogue → 495. `optional_no_ca`: rogue → **served** with `FAILED:unable to verify the first certificate`, **and `$ssl_client_s_dn` filled in from the forgery**, so a naive CN map produced `X-Partner: acme`. A **revoked** certificate was still 495 under `optional_no_ca`: only CA problems pass.
* `error_page 495 = @named` / `496 = @named` with `return 403/401 '{"error": ...}'` works for JSON refusals, in a server with `ssl_verify_client on`.
* `openssl s_client` showed `No client certificate CA names sent` before, and `Acceptable client certificate CA names: O = Tidewater Logistics, CN = Tidewater Partner CA` after `ssl_client_certificate`.
* **The CRL is read at load.** After `revoke globex` wrote a new CRL, Globex kept getting `200` until the reload, then `403`.
* **An expired CRL locks everyone out:** a CRL made with `openssl ca -gencrl -crlsec 15` worked, then after 16 s every Partner CA certificate got `FAILED:CRL has expired` (`403` through `@cert_rejected`). Swapping a good CRL into the file didn't help until the reload.
* **Upstream mTLS:** without `proxy_ssl_certificate`, the ledger's `CERT_REQUIRED` showed up in the edge's error log as `SSL_read() failed (... tlsv13 alert certificate required ...) while reading response header from upstream`: in TLS 1.3 the client certificate failure arrives after the handshake. With `proxy_ssl_verify on` and no `proxy_ssl_name`, the real ledger failed with `upstream SSL certificate does not match "ledger"`: the default name is the `upstream` block's name.
* **Upstream keepalive is now the default (nginx 1.29.7):** the changelog says *"the keepalive directive in the upstream block is enabled by default"* and *"ngx_http_proxy_module supports keepalive by default; the default value for proxy_http_version is 1.1; the Connection proxy header is not sent by default anymore."* Found the hard way: with no `keepalive` configured, switching the ledger's address to an impostor didn't change anything for the edge, because it kept reusing connections it had verified with the real ledger. `/proc/net/tcp` in the apps container showed established connections from the edge to every upstream port (9001, 9002, 9100, 9443). The lab's impostor switch now cuts the open connections.
* While chasing that, a first impostor built as a second `SSLContext` in the same Python process seemed to resume the real ledger's sessions; the real cause was keepalive. The ledger and impostor now run in separate processes behind a TCP relay anyway.

### `auth_request` (Day 2)
* **Status handling, measured:** service `200`/`204` → request continues; `401` → `401` (with the service's `WWW-Authenticate` copied); `403` → `403`; `404`, `302`, `500` → `500` with `auth request unexpected status: N`; a 2 s service with `proxy_read_timeout 1s` → `upstream timed out`, then `unexpected status: 504`, client `500` after 1 s.
* **The subrequest arrived as `GET` for a client's `POST` and `HEAD`**, without a body or `Content-Length` (with the standard `proxy_pass_request_body off` pair). Inside the auth location, `$request_method` still held the client's method, so `X-Original-Method $request_method` fixed the viewer-can-write bug.
* **`auth_request_set` reads the subrequest's response headers** (`$upstream_http_x_ops_user`). Without it, the service's `X-Ops-User` went nowhere.
* **`proxy_cache` in the auth location works:** five requests, one authz call. With `proxy_cache_key $http_authorization`, a viewer's cached `GET` decision answered their `POST` (`200`); with `"$http_authorization $request_method"` it was `403`.
* **`$upstream_cache_status` in the main `log_format` showed `-`:** it describes the main request's upstream. `auth_request_set $authz_cache $upstream_cache_status;` brought the subrequest's `MISS`/`HIT` into the log. A request with no `Authorization` header showed `EXPIRED` the second time round.
* **`satisfy any` + `allow 10.57.0.5`:** the office's requests never reached the authz service (`ops="-"` in the log).
* `if` can't use `auth_request_set` variables: an `if ($g = "") { return 418; }` after `auth_request` answered `418` for a signed-in user, because `if` runs in the rewrite phase, before the access phase asks.

### Single sign-on (Day 3)
* **Keycloak's two faces:** `--hostname https://localhost:8091` + `--hostname-backchannel-dynamic true`: through the front door, every endpoint was `https://localhost:8091/...`; on the direct port, the issuer and authorization endpoint stayed public while the token, JWKS and userinfo endpoints used the direct address.
* **The front door needs `X-Forwarded-Port`:** with `Host $http_host` and `X-Forwarded-Proto https` only, Keycloak advertised `https://localhost/realms/...` (no port) for the token endpoint, assuming 443 for HTTPS.
* **OAuth2 Proxy with `--skip-oidc-discovery`** needs the issuer plus `--login-url` (public), `--redeem-url` and `--oidc-jwks-url` (internal). It warns at start that `--reverse-proxy` trusts every address unless `--trusted-proxy-ip` is set.
* **`X-Auth-Request-User` is the `sub`** (a UUID in Keycloak); `X-Auth-Request-Preferred-Username` is the username. Groups need a Keycloak group-membership mapper (`full.path: false` for `staff` instead of `/staff`).
* **The `_tidewater_sso` cookie reached the portal app** until `proxy_set_header Cookie "";`. OAuth2 Proxy also sets `_tidewater_sso_csrf` during the sign-in, so a check for a session cookie must match the exact name.
* **`/oauth2/auth?allowed_groups=admins`** answers `403` for a signed-in non-member.
* **`/oauth2/sign_out` kept the Keycloak session:** after signing out, `/oauth2/start` went through Keycloak without a login form and back to the portal as bob.
* Keycloak 26.8 (start-dev): about 17–30 s to start with the realm import, about 620–660 MB of memory.

### NGINX Plus (side quest)
* **The Plus binary has** `auth_jwt`, `auth_jwt_claim_set`, `auth_jwt_header_set`, `auth_jwt_key_cache`, `auth_jwt_key_file`, `auth_jwt_key_request`, `auth_jwt_leeway`, `auth_jwt_require`, `auth_jwt_type`, and the OIDC module: `oidc_provider` (`issuer`, `config_url`, `cookie_name`, `session_store`, `proxy_location`, `client_id`, `client_secret`, `scope`, `redirect_uri`, `post_logout_uri`, `logout_token_hint`, `frontchannel_logout_uri`, `pkce`, `extra_auth_args`), `auth_oidc`, `$oidc_claim_*`, `$oidc_id_token`, `$oidc_access_token`, `$oidc_userinfo`.
* **`issuer URL requires "https" scheme`:** the OIDC module refused an `http://` issuer at load. That's why the lab's Keycloak front door is HTTPS.
* **`$jwt_claim_groups` was empty for the array claim**; `auth_jwt_claim_set $jwt_groups groups;` gave `admins,staff`. `$oidc_claim_groups` joins arrays by itself.
* **The OIDC callback needs `auth_oidc`:** with `auth_oidc` only in `/portal/`, the return to `/oidc_callback` was served as a file: `open() "/etc/nginx/html/oidc_callback" failed`, `404`. `location = /oidc_callback { auth_oidc tidewater; }` fixed it. The redirect to Keycloak included `code_challenge_method=S256` (PKCE on by default) and `nonce`.
* **The session cookie is `NGX_OIDC_SESSION`** with a short hex ID; the session itself stays in NGINX.
* **Single-file bind mounts don't see edits:** `sed -i` and editors that write a new file replace the inode, and a container with `-v file:file` keeps the old one. The side quest mounts the whole `lab/` directory instead.
* **njs can verify Keycloak's RS256 tokens:** `crypto.subtle.importKey('jwk', ...)` with `RSASSA-PKCS1-v1_5`/`SHA-256` and `crypto.subtle.verify` returned `true` for a real token and `false` for a tampered one (`for...of` isn't supported by the default engine, as in Sprint 6).

---

## Q&A During the Sprint

### Day 1, Concepts 1.2: why the handshake always succeeds
* **Q:** Does the handshake succeed even when the certificate is refused because OpenSSL handles TLS and NGINX doesn't?
* **A:** No. OpenSSL is a library inside the NGINX worker, and NGINX tells it what to do. With `ssl_verify_client` set, NGINX asks for a certificate (`SSL_VERIFY_PEER`) but installs a verify callback that **always accepts**: OpenSSL checks the chain, dates and CRL, stores the result, and lets the handshake finish. NGINX then reads that result **when the HTTP request is processed** (`SSL_get_verify_result` / is there a peer certificate) and ends the request with its internal 495/496, sent as a `400` page. That deferral is deliberate: it's what lets `error_page 495/496` answer with JSON, lets `optional_no_ca` pass a `FAILED:` result through to you, and fills in `$ssl_client_verify`.
* **Measured** (throwaway `nginx:mainline` 1.31.6 on :8088, `ssl_verify_client on`, no client certificate): TLS 1.2 and TLS 1.3 both completed the handshake and returned `HTTP/1.1 400 Bad Request`.
* **BIG-IP delta:** a Client SSL profile with **Client Certificate: require** refuses *inside* the handshake: TMM sends a fatal TLS alert (`handshake_failure`, `bad_certificate`, `unknown_ca`, ...) and the client never gets an HTTP response. NGINX's `on` behaves more like the profile set to **request**, with an iRule on `HTTP_REQUEST` checking `SSL::verify_result` and answering with an HTTP error. NGINX has no setting that makes the HTTP module reject the certificate inside the handshake.
* **TLS 1.3 nuance:** in TLS 1.3 the client sends its certificate after it has already seen the server's Finished, so from the client's side the handshake is done before the server judges the certificate. Even a BIG-IP alert arrives "after the handshake" as the client sees it (the same effect seen with the ledger's `tlsv13 alert certificate required`).

* **User's takeaway (after Activity 3.2):** because NGINX refuses at the HTTP layer, a failed client certificate becomes a normal, configurable HTTP response natively (`400` by default, JSON with `error_page 495/496` in 3.3). On BIG-IP the same result means Client SSL **request** mode plus an iRule that pulls the certificate apart (`SSL::cert`, `SSL::verify_result`) and builds the response (`HTTP::respond`). Gains: readable errors for partners, refusals in the access log with `$ssl_client_verify`, one decision point. Costs: no in-handshake refusal (an unauthenticated client completes TLS and sends a request before the 400; `stream` with `ssl_verify_client on` just closes the connection instead: measured on 1.31.6, handshake completed, connection closed with no data, `[info] client sent no required SSL certificate while SSL handshaking`), and the same deferral is what makes the `optional_no_ca` trap possible.

### Day 1, Concepts 1.3: what is a SPIFFE ID?
* **Q:** What's a SPIFFE ID (in the Acme certificate's SAN)?
* **A:** SPIFFE (CNCF) is a standard for workload identity independent of hostnames/IPs: `spiffe://<trust-domain>/<path>`, carried as the **only URI SAN** in an X.509-SVID (the CN carries no meaning) or in a JWT-SVID. SPIRE, the reference implementation, attests workloads and issues short-lived certificates (about an hour) that rotate automatically; Istio, Linkerd and Consul use the same ID format. It's one more reason NGINX's missing SAN variable matters: the identity lives in the SAN, so you forward `$ssl_client_escaped_cert` and parse the certificate in the application (or in njs).
* **BIG-IP delta:** no native equivalent; the nearest is an iRule/APM policy parsing the SAN from `SSL::cert` / `X509::extensions`. SPIFFE standardizes the format and automates issuance and rotation.
* The guide uses the term in 1.3/1.4 without defining it (user had not met it before).

### Day 1, Concepts 1.4: does a CRL update need a reload on NGINX Plus?
* **Q:** Do CRL updates require a reload on NGINX Plus?
* **A: Yes, same as open source.** Measured on Plus R37.1.1 (throwaway container): client certificate `200`; revoke + rewrite `crl.pem`: still `200` immediately and 5 s later; after `nginx -s reload`: `400`. `ssl_crl` takes no variables (`ssl_crl $host` → `[emerg] cannot load CRL "/w/$host"`), and the Plus API has no CRL endpoint. A reload is graceful (new workers, old ones drain), so the usual pattern is: fetch CRL → `nginx -t` → reload, on a timer well inside the CRL's `nextUpdate` (remember the expired-CRL lockout above).
* **No-reload alternative, in OSS and Plus: `ssl_ocsp on | leaf`** (since 1.19.0) asks the certificate's OCSP responder (from its AIA, or `ssl_ocsp_responder`) during the handshake. Measured: revoking in the responder (`openssl ocsp -index`) turned `200` into `400` with no reload; error log at `info`: `client SSL certificate verify error: certificate revoked while reading client request headers`. Needs a `resolver` if the responder is a hostname.
* **Trade-offs:** a live dependency on the responder for every new client connection (latency, and a responder outage = refusals), unless `ssl_ocsp_cache shared:NAME:SIZE` is set, which holds each answer until the response's `nextUpdate` (measured: a cached status persisted 30 s and changed after ~65 s with a 1-minute `nextUpdate`). So the cache trades freshness for availability, like the CRL's lifetime does.
* **BIG-IP delta:** on BIG-IP the CRL is a file object in the Client SSL profile, also not live (you update the file object; a CRL DP or OCSP responder object + authentication profile gives live checks). NGINX's `ssl_ocsp` is the equivalent of the OCSP authentication profile, built into the SSL config.
* Test artifact: `openssl ocsp` noticed index.txt edits one request late; not an NGINX behaviour.

### Day 1, Activity 3.3: an HTML error page instead of JSON?
* **Q:** Could the refusal be a custom HTML/JS/CSS page?
* **A:** Yes: `error_page 495 496 =403 /errors/cert.html;` + `location /errors/ { internal; alias ...; }` (or `return` HTML from the `@named` location with `default_type text/html`). Measured on nginx 1.31.6 (throwaway, :8088/:8089): without `=CODE` the client gets **400** (495/496 are converted); with `=403`, 403.
* **Trap:** the page's sub-resources are new requests on the same mTLS server, refused before any location runs: `/errors/style.css` without a certificate came back as the error page HTML (`403 text/html`). A location can't exempt them. Fix: a self-contained page (inline CSS/JS, `data:`/inline SVG images), or assets from another origin without mTLS; `optional` + a `map` on `$ssl_client_verify` also works but re-implements `on` (the 3.5 trap territory).
* **BIG-IP delta:** same constraint as an iRule `HTTP::respond` page; on BIG-IP you design for it in the iRule, in NGINX you find out when the page arrives unstyled.

### Day 2, Concepts 1.1: why a `return` wins without asking
* **Q:** What does "a `return` in the same location wins without asking" mean, and what was Sprint 5's lesson?
* **A:** Phases run in a fixed order: SERVER_REWRITE / REWRITE (`rewrite`, `set`, `if`, `return`) → PREACCESS (`limit_req`, `limit_conn`) → ACCESS (`allow`/`deny`, `auth_basic`, `auth_request`, `auth_jwt`) → CONTENT (`proxy_pass`). A `return` ends the request in REWRITE, so nothing after it runs: no subrequest, no service call, no 401. `location /ops/ { auth_request /_authz; return 200 "ok"; }` answers everyone. Sprint 5 Day 1 1.5: a location that answers with `return` is never rate limited; Sprint 5 Day 3 used the same order deliberately (`geo` + `if (...) { return 403; }` refuses before the limits count the client).
* **BIG-IP delta:** like an `HTTP_REQUEST` iRule doing `HTTP::respond` before the access policy has run: the policy never sees the request. In NGINX the order is fixed by phase, not by the order the directives appear in the file.

### Day 2, Concepts 1.2: what the service sees by default, and how much you control
* **Q:** Is 1.2 what the service *can* see or what it sees by default? How much control is there?
* **A:** By default. Measured on nginx 1.31.6 (throwaway, :8088, mock on :9001), client `POST /x/fleet?x=1` with `Authorization`, `Cookie` and a 7-byte body:
  * Default auth location: `GET /check`, every client header (Authorization, Cookie, **Content-Length: 7**), **no body**. The mock sat waiting for 7 bytes that never came (a real service hangs until a timeout → 504 → client 500). The subrequest never carries the body (auth_request gives it an empty fake body); the inherited `Content-Length` is the danger, which is why the `proxy_pass_request_body off` + `Content-Length ""` pair exists.
  * With the pair: `GET /check`, no Content-Length, returned at once.
  * `proxy_pass_request_headers off` + explicit `proxy_set_header`s: the service saw only what was listed (Authorization, X-Original-Method POST, X-Original-URI `/c/fleet?x=1`, X-Client-IP); the Cookie was gone. `$request_method`, `$request_uri`, `$remote_addr`, `$ssl_client_*` all reflect the client's request inside the auth location.
  * `proxy_method POST` changed the check's method; `proxy_pass http://.../check?u=$request_uri` put the original URI in the check's URL (variables in proxy_pass work; needs a `resolver` for hostnames).
* **Control summary:** method (`proxy_method`), URL (`proxy_pass` with variables), headers (add/override/remove with `proxy_set_header`, or allow-list with `proxy_pass_request_headers off`), timeouts, TLS to the service (`proxy_ssl_*`), caching. Not the body: auth_request never forwards it. Judging the body needs njs (read it, then `r.subrequest` to the service) or a check inside the application.
* **Guide note:** day_02.md 1.2 says "a subrequest would pass it [the body]": it doesn't. Wording fix offered.
* **BIG-IP delta:** An iRule sideband call (`connect`/`send`/`recv`) builds the request from scratch, so you list what to send; NGINX starts from a copy of the client's headers and you remove things. Allow-listing (`proxy_pass_request_headers off`) is the BIG-IP-like default-deny posture, and keeps cookies and other secrets away from the auth service.

### Day 2, Concepts 1.4: the cache lifetime is a revocation delay
* **Q:** Expand on "the lifetime is a revocation delay".
* **A:** With `proxy_cache_valid 200 30s`, a `200` for token T is stored under T's key. Revoking T at the service changes nothing at the edge until the entry expires: every request in up to 30 s (per edge, per cache) is served from the cached `200` and never reaches the service. Worst case = the full `proxy_cache_valid`, since revocation can land just after a fill. Same in reverse for cached `401`/`403`: a newly issued or re-enabled token is refused until its negative entry expires. Pick the time as "how long may a revoked credential keep working", not just as load reduction. Things that make it longer: `proxy_cache_use_stale` (an outage keeps serving the old `200`), `Cache-Control`/`X-Accel-Expires` from the service (they override `proxy_cache_valid` unless `proxy_ignore_headers` is set), several edges each with their own cache. Ways to shorten: short valid times, a cache key that includes something the IdP rotates, purge (Plus `proxy_cache_purge`), or make revocation rare by using short-lived tokens. Activity 3.5 shows it live.
* **BIG-IP delta:** same trade as an iRule `table set ... $token $verdict 30` (the timeout is the delay; `table delete` is the instant revoke, NGINX OSS has no purge equivalent) or APM session lifetime vs. per-request checks.

### Day 2, Activity 3.2: why the copy into `$ops_user`?
* **Q:** Why set a variable instead of referencing `$upstream_http_x_ops_user` directly?
* **A:** A variable is a lookup run against the request using it, at the moment it's used; `$upstream_*` means "this request's own upstream". The auth subrequest and the main request are separate request objects, each with its own upstream. `proxy_set_header` runs in the main request while building the request to the ops tool, which hasn't answered, so the direct reference is empty. `auth_request_set` evaluates in the subrequest's context when it finishes and stores the value on the main request. Measured on 1.31.6 (throwaway :8088): `X-Direct $upstream_http_x_ops_user` not sent, `X-Copied $ops_user` = carol; the main access log showed the ops tool's `$upstream_status` (202) and its own `X-Ops-User`. Plus `auth_jwt` doesn't need the bridge: it validates in the main request.
* **User's choice:** this is the Day 2 recap image (`authz-two-requests.svg/.png`), even though it's tangential to the day's focus.

### Day 2, Activity 3.2: cons of identity headers instead of the token
* **Q:** Replacing `Authorization` with user/role headers is standard; what are the cons?
* **A:** The trusted-identity-header pattern moves trust to the network: anyone who reaches the backend directly (another service, SSRF, the lab's `s7-net`, where :9002 is reachable) can forge `X-Ops-Role: admin`. Every route to the backend must overwrite the header (one forgotten `location` passes the client's through; underscore/duplicate header parsing differs between components). The backend loses the credential (no delegation to further services, no scopes/expiry/jti), each hop no longer verifies (not zero-trust), the edge's cache lifetime becomes the system's revocation delay, and plain headers carry structured claims badly. Mitigations: network policy, mTLS edge→backend (Day 1's ledger), or a short-lived edge-signed JWT the backend verifies.
* **BIG-IP delta:** same trade-off as APM + `HTTP::header insert`; same mitigations (lock down BIG-IP→pool path, or APM-issued signed tokens).

## Day 1

### Day 1: Quiz
* **8/10.** Missed:
  * `s7d1q01` (copied certificate file, no key): **CertificateVerify**, the client's signature over the handshake with its private key, is the proof of possession. A certificate is public; the key is the credential (that's why 3.6's story is a *leaked key*).
  * `s7d1q11` (two-map chain under `optional_no_ca`, `fake-acme`): `$partner` is **empty**. `$cert_cn` is `acme` (the forged subject still fills `$ssl_client_s_dn`), but `$ssl_client_verify` is `FAILED:...`, so the `SUCCESS`-gated map falls to `default ""`. The tempting answer, `acme`, was the behaviour *before* the 3.5 fix.

## Day 2

### Day 2: For the recap (user's notes)
* **Zero trust, a con of how the lab is built.** The edge verifies the token once, removes it, and the ops tool trusts `X-Ops-User`/`X-Ops-Role` from anyone who can reach it. Fine for the lab, and it shows off what `auth_request` + `auth_request_set` can do, but in production **each leg should verify**: mTLS edge→backend (Day 1's ledger leg), or an edge-signed short-lived token the backend checks, not a bare header on a trusted network. (Detail in Q&A, "cons of identity headers".)
* **Activity 3.3 slip: right headers, wrong location.** First attempt put `X-Original-Method`/`X-Original-URI` in `location /ops/` instead of `location = /_authz`, so they went to the ops tool and the authz service still judged a `GET`; viewer's `POST` stayed `200`. Caught because the result didn't change, then moved to `/_authz`. The NGINX nuance behind it: `auth_request` and the main request are two requests through two different locations, and each location's `proxy_set_header` only shapes its own upstream request (same root as the image: each request has its own upstream). Also: they couldn't go at `server` level either, because `/_authz` already sets `proxy_set_header Content-Length ""`, and a location with any `proxy_set_header` inherits none from above.

### Day 2: Quiz
* **9/10.** Missed `s7d2q15` (`$upstream_cache_status` in the main `log_format` always shows `-`): answer **B**, in the access log `$upstream_*` describe the main request's upstream (the ops tool); copy the subrequest's value with `auth_request_set $authz_cache $upstream_cache_status;`. Same root as the Day 2 image (two requests, two upstreams).

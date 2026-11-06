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

(Added as the sprint is played.)

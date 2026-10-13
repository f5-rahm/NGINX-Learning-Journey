# Sprint 3: TLS Termination, HTTP/2, HTTP/3 & Edge Hardening
**Cadence:** 3 sessions, any days that week  
**Milestone:** The Lumina Zero-Trust Edge: Sprint 2's gateway behind TLS 1.3, HTTP/2, HTTP/3 and browser security headers  
**Shape:** From Sprint 3 on, every sprint has **3 days**. The Enterprise Side Quest is an **optional** add-on to Day 3, with its own optional quiz.

---

## 1. Sprint at a Glance

| Day | Theme | Concepts (~15 min) | Lab (~35 min) | Guide |
| :--- | :--- | :--- | :--- | :--- |
| **1** | TLS termination at the edge | Client SSL profile → `ssl_*` directives, the two cipher knobs (TLS 1.2 vs 1.3), dual RSA/ECDSA certificates, SNI and the default server, session cache vs tickets | Protocol floor (two gates), restrict both cipher knobs, RSA-only clients, refuse unknown SNI, make resumption survive a reload | [`day_01.md`](day_01.md) |
| **2** | ALPN, HTTP/2 and HTTP/3 | ALPN, `http2 on`, multiplexing and HPACK, client vs upstream protocol, QUIC, `reuseport`, `Alt-Svc`, per-socket default servers | Turn on h2, measure multiplexing and HPACK in the access log, add HTTP/3, watch `Alt-Svc` upgrade a client, close the QUIC SNI gap | [`day_02.md`](day_02.md) |
| **3** | Security headers & the sprint lab | HSTS, `nosniff`, framing, CSP, `add_header ... always`, inheritance and `add_header_inherit merge`, hiding leaks | Headers on errors, the inheritance trap, hide `Server` version and backend headers, **build the Lumina edge**, `test_sprint03.sh` | [`day_03.md`](day_03.md) |
| *3+* | *Optional Enterprise Side Quest* | *Shrinking certificate lifetimes, NGINX Plus key-value certificates, ACME in-process* | *A: rotate a certificate through the Plus API under load, no reload. B: issue one from a Pebble test CA with `nginx-module-acme`.* | [`day_03_enterprise.md`](day_03_enterprise.md) |

---

## 2. Lab Environment

All Sprint 3 labs run from `/srv/nginx-journey/sprints/sprint-3/lab` with the `ngx` helper from Sprint 1 Day 1.

| Port | Service |
| :--- | :--- |
| 8080 / 8081 / 8082 | Dashboard (reserved) / Sprint 1 lab / Sprint 2 lab |
| **8083** | **Sprint 3 lab: plain HTTP, redirects to HTTPS** |
| **8443 TCP + UDP** | **Sprint 3 lab: HTTPS (TLS, HTTP/2) and HTTP/3 (QUIC)** |
| 8001 / 8002 / 8003 | Sprint 2 mock backends (`../../sprint-2/lab/mocks.sh start`) |
| 8444 / 127.0.0.1:8085 | Side Quest A: NGINX Plus container, TLS traffic / API |
| 8087 / 8447 | Side Quest B: ACME-managed OSS instance (HTTP challenges / HTTPS) |
| 14000 / 15000 | Side Quest B: Pebble ACME test server |

```bash
cd /srv/nginx-journey/sprints/sprint-3/lab
mkdir -p logs temp/{client,proxy,fastcgi,uwsgi,scgi}
./make_certs.sh                 # private Lumina Lab CA, lumina-ecdsa and lumina-rsa (200 days) in certs/
source helpers.sh               # c, hs, resume, h3, h3alt: load in every new terminal
```

**Lab PKI (`make_certs.sh`):**
* An ECDSA P-256 CA and two `lumina.local` leaf certificates (ECDSA P-256 and RSA 2048). The SAN is `lumina.local` only.
* `./make_certs.sh issue NAME DAYS ec|rsa` issues more (Side Quest A uses it for a rotation).
* `certs/` is gitignored: no private key ever enters the repo.

**Helpers (`helpers.sh`):**
* `c` is a `curl` that trusts the lab CA and resolves `lumina.local`.
* `hs` makes one `openssl s_client` handshake and summarizes it on one line.
* `resume [--reload]` tests session resumption.
* `h3` / `h3alt` run curl with HTTP/3 in a container (`alpine/curl-http3:8.11.0`). The host's curl 7.81 has no HTTP/3.

> **Version notes (verified on the lab's nginx 1.31.6, OpenSSL 3.0.2):**
> * `ssl_protocols` already defaults to TLS 1.2 and 1.3.
> * `http2` is a per-server directive (`listen ... http2` is deprecated).
> * `add_header_inherit merge` and `proxy_http_version 2` are available.
> * HTTP/3 runs through NGINX's OpenSSL compatibility layer, which has **no 0-RTT**.

---

## 3. Daily Detail

### Day 1: TLS Termination at the Edge
**Concepts:**
* The client SSL profile mapped onto `ssl_*` directives.
* `ssl_ciphers` (TLS 1.2) vs `ssl_conf_command Ciphersuites` (TLS 1.3).
* Certificate selection per handshake.
* SNI, `default_server` and `ssl_reject_handshake`, including what happens to clients that connect by IP.
* Session cache vs tickets, and why the **default server** has to see the session settings.
* `301` vs `308` for the HTTPS redirect.

**Lab:**
* The two gates in front of TLS 1.1.
* Restrict both cipher knobs.
* Fail, then satisfy an RSA-only client.
* Refuse unknown SNI.
* Make resumption survive a reload, and find out why it first doesn't.

### Day 2: ALPN, HTTP/2 and HTTP/3
**Concepts:**
* ALPN and `http2 on`.
* Streams, HPACK, TCP head-of-line blocking.
* The upstream protocol as a separate decision (HTTP/1.1 default; `proxy_http_version 2` exists).
* QUIC on UDP, `reuseport` once per address:port.
* `Alt-Svc` discovery.
* Separate default servers for TCP and UDP.

**Lab:**
* Turn on HTTP/2.
* Three parallel requests on one connection vs three.
* HPACK shrinking a 600-byte header to 11 bytes.
* Add HTTP/3, and watch `Alt-Svc` move a client from h2 to h3.
* Find and close the SNI gap that QUIC opens.

### Day 3: Security Headers & the Sprint Lab
**Concepts:**
* HSTS (and its commitments), `nosniff`, `X-Frame-Options` / `frame-ancestors`, CSP, Referrer-Policy.
* `add_header` status codes and `always`.
* Inheritance and `add_header_inherit merge`.
* `server_tokens off` and `proxy_hide_header`.

**Lab:**
* Headers missing from 404 and 502 responses until `always`.
* One `Cache-Control` that silently drops HSTS and `Alt-Svc`.
* Hide the version and a backend header.
* Then build the Lumina edge (Section 4) and pass `test_sprint03.sh`.

### Day 3+ (Optional): Enterprise Side Quest
**Concepts:**
* Certificate lifetimes shrinking (200 → 100 → 47 days).
* NGINX Plus `keyval` + `ssl_certificate data:$var` + write API.
* ACME (RFC 8555) challenges.
* `nginx-module-acme` running inside NGINX.

**Lab:**
* **A (NGINX Plus):** load, rotate and persist a certificate through the API with zero failed handshakes and no reload, and see why the key and certificate must be one value.
* **B (OSS + module):** issue a certificate from Pebble, see challenges pass behind a blanket redirect, and restart without re-issuing.

---

## 4. Lab Specification: Lumina Zero-Trust Edge

Copy `lab/starter_nginx.conf` to `lab/nginx.conf`. Certificates come from `lab/make_certs.sh`. Mock backends are Sprint 2's.

1. **Plain HTTP (8083):** every request is redirected with `301` to `https://lumina.local:8443`, keeping the path and query string.
2. **TLS (8443) for `lumina.local`:**
   * TLS 1.2 and TLS 1.3 only.
   * TLS 1.2 only with ECDHE key exchange and AEAD ciphers (no CBC suites).
   * Both `certs/lumina-ecdsa.*` and `certs/lumina-rsa.*` are served, so ECDSA clients and RSA-only clients both connect.
   * Sessions resume, **including after a reload**.
3. **Unknown names:** on 8443, handshakes for any other SNI name, or with no SNI, are refused, over TCP **and** QUIC.
4. **Protocols:** HTTP/2 through ALPN. HTTP/3 on UDP 8443, advertised on responses with `Alt-Svc: h3=":8443"`.
5. **Response headers:** every HTTPS response, **errors included**, carries:
   * `Strict-Transport-Security` with `max-age` of at least `31536000`;
   * `X-Content-Type-Options: nosniff`;
   * `X-Frame-Options: DENY`.
6. **No leaks:** the `Server` header shows no version, and the backends' `X-Handled-By` header never reaches clients.
7. **Sprint 2 services, now over HTTPS:**
   * `/healthz` answers `200` JSON with `"status": "healthy"`.
   * `/api/v1/` proxies to the `8001`/`8002` pool, and the backend receives `X-Forwarded-Proto: https`.
   * `/ws/chat` relays WebSockets to `8003`.
   * `/` serves the SPA in `lab/html/`.

`lab/solution_nginx.conf` is the reference configuration.

---

## 5. Automated Test Suite (`test_sprint03.sh`)

```bash
cd /srv/nginx-journey/sprints/sprint-3 && ./test_sprint03.sh
```
* The suite starts any Sprint 2 mocks that aren't running (and stops them afterward).
* It **reloads your NGINX once** (test 6).
* It runs the HTTP/3 checks with Docker.
* Override `HTTP_PORT`, `TLS_PORT` or `PIDFILE` to point it elsewhere.

| # | Core assertion (gate: 13/13) | Requirement |
| :--- | :--- | :---: |
| 1 | `http://…:8083/courses/42?ref=mail` → `301` to `https://lumina.local:8443/courses/42?ref=mail` | 1 |
| 2 | The default handshake is TLS 1.3; TLS 1.1 is refused | 2 |
| 3 | TLS 1.2 accepts `ECDHE-ECDSA-AES128-GCM-SHA256` and refuses CBC suites | 2 |
| 4 | An ECDSA client gets the ECDSA cert; an RSA-only client gets the RSA cert | 2 |
| 5 | TCP handshakes with an unknown SNI name, or none, are refused | 3 |
| 6 | A session saved before a reload resumes after it | 2 |
| 7 | HTTP/2 negotiated | 4 |
| 8 | HTTP/3 answers on UDP 8443, and `Alt-Svc` advertises `h3=":8443"` | 4 |
| 9 | QUIC handshakes with an unknown SNI name are refused | 3 |
| 10 | HSTS (≥ 1 year), `nosniff` and `X-Frame-Options: DENY` on `/`, `/healthz`, an API 200, an API 404 and an API 502 | 5 |
| 11 | `Server: nginx` with no version, and no `X-Handled-By` | 6 |
| 12 | `/healthz` is healthy, and the API sees `X-Forwarded-Proto: https` | 7 |
| 13 | `wss://…/ws/chat` returns `101` with the correct accept key and relays the welcome frame | 7 |

---

## 6. Daily Quizzes

All pools live in [`data/quizzes.json`](../../data/quizzes.json). Each day has 20 questions (8 scenario, 6 config, 3 diagnose, 3 recall). The quiz draws 10, and 8/10 passes.

* **Day 1:** protocol defaults and the two gates, the two cipher knobs, certificate selection, SNI/default server/`ssl_reject_handshake`, cache vs tickets and reloads, redirect codes.
* **Day 2:** ALPN, `http2 on`, multiplexing and HPACK, client vs upstream protocol, QUIC/UDP, `reuseport`, `Alt-Svc`, per-socket default servers, 0-RTT.
* **Day 3:** HSTS semantics, the other headers, `always`, inheritance and `add_header_inherit merge`, `server_tokens`, `proxy_hide_header`, duplicate headers.
* **Day 3 Enterprise (optional, 10 questions, not part of graduation):** key-value certificates, atomic rotation, ACME challenges, `nginx-module-acme` behavior.

```bash
cd /srv/nginx-journey && python3 -m http.server 8090
# http://<lab-host>:8090/quiz.html?sprint=3&day=1   (day=2, day=3, and day=3&pool=enterprise)
```

---

## 7. Optional Extras

* **3.1 Browser test.** Trust `lab/certs/ca.crt` on your workstation, map `lumina.local` to the lab host, and open UDP 8443 in the security group. Then watch the protocol column in the browser's developer tools switch to `h3` on the second load.
* **3.2 Session tickets across a farm.** Run a second NGINX on another port with the same `ssl_session_ticket_key` files, and show that a session from one resumes on the other. Remove the shared key and show that it doesn't.
* **3.3 Post-quantum key exchange.** The NGINX Plus R37.1 image is built on a newer OpenSSL. Check whether it negotiates `X25519MLKEM768` with a client that offers it, and compare with the host's OpenSSL 3.0.2.

---

## 8. Tracker Sync

* **Platform milestone:** Lumina is reachable only over modern TLS. It speaks HTTP/1.1, HTTP/2 and HTTP/3, refuses names it doesn't own on every socket, resumes sessions across reloads, and sends browser security policy on every response.
* **Graduation:** `test_sprint03.sh` 13/13, and at least 80% on each day's quiz (the Enterprise quiz is optional).

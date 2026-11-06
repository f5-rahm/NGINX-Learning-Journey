# Sprint 6: Programmability & Extensibility (njs)
**Cadence:** 3 sessions, any days that week  
**Milestone:** Lumina Edge Functions: sessions verified at the edge with a key that's never written down, identity passed to the application, beta customers routed by a signed claim, a revocation list every worker shares, signed download links, orders checked before they reach the application, card numbers masked on the way out, and a TCP telemetry port that only admits devices that sign their greeting  
**Shape:** 3 days. Sprint 6's enterprise side quest moves into the **Side Quest Gauntlet** that follows this sprint (with Sprints 4 and 5's): [The Black Friday War Room](../../gauntlet/black-friday/README.md).

---

## 1. Sprint at a Glance

| Day | Theme | Concepts (~15 min) | Lab | Guide |
| :--- | :--- | :--- | :--- | :--- |
| **1** | How njs runs | What njs is (and isn't), the request object and the handlers, the two engines and how long state lives, the JavaScript you get, run-time exceptions | Reload and `nginx -t` for scripts, globals in njs vs QuickJS, the `njs` shell, `js_set` (once per request, only when used) vs `map`, reading a session, a cookie that causes a `500` | [`day_01.md`](day_01.md) |
| **2** | Signatures, bodies and shared state | HMAC and JWT checks, the key in `env`, `secure_link` vs njs, header and body filters, request bodies, `internalRedirect` / `subrequest` / `ngx.fetch`, `js_shared_dict_zone` + `js_periodic` | A key the workers can't see, `X-User` and spoofing, native vs scripted signed links, masking that truncates, refusing bad orders, a revocation list without a reload | [`day_02.md`](day_02.md) |
| **3** | Routing, TCP & the sprint lab | `proxy_pass $var` on a verified claim, stream njs (`js_preread`, `preread_timeout`, `ssl_preread`), the cost of a blocking script, native vs script | A cookie anyone can set vs a signed claim, a TCP gatekeeper, a silent client, two slow requests that stall the edge, **build Lumina Edge Functions**, `test_sprint06.sh` | [`day_03.md`](day_03.md) |

---

## 2. Lab Environment

Like Sprints 4 and 5, the lab runs in **containers**: `nginx:mainline` (nginx 1.31.6 with **njs 1.0.1**) as the edge, and the Lumina application behind it. Everything runs from `/srv/nginx-journey/sprints/sprint-6/lab` through `lab.sh`. There's no client container this week: you talk to the edge from the host.

| Address / port | Service |
| :--- | :--- |
| 8081–8095 | Earlier sprints (reserved) |
| **:8096** (container `s6-edge`, 10.56.0.10) | **Sprint 6 lab: the Lumina edge**, HTTP |
| **:8097** | The edge's telemetry port, TCP |
| 127.0.0.1:8016 (container `s6-origin`, 10.56.0.20) | **The application**: the stable pool :8016, the beta pool :8026, the telemetry intake :8036 |

```bash
cd /srv/nginx-journey/sprints/sprint-6/lab
cp day1_nginx.conf nginx.conf           # or the day's config, or starter_nginx.conf for the sprint lab
cp day1_lumina.js lumina.js             # and the matching script
./lab.sh up                             # network, origin, edge, then the ready check
source helpers.sh                       # r, rh, token, link, tel, decode, revoke, unrevoke, ostats, elog
./lab.sh down                           # when you're done for the day
```

**The signing key.** The first `up` writes a random key to `lab/secrets/lumina.key` (directory 700, file 600, gitignored) and starts the edge with it in the `LUMINA_KEY` environment variable. `tools.py` signs tokens, links and telemetry greetings with the same file. `./lab.sh down` keeps the key; delete `lab/secrets/` to get a new one (then `./lab.sh edge`).

**`lab.sh`**
* `up`, `check`, `reload`, `t`/`T` (`nginx -t` / `-T` inside the edge), `edge` (recreate only the edge), `down`.
* `njs [-n QuickJS] -c 'code'` runs the njs shell from the same image.
* `stats` / `reset` read and zero the application's counters. `logs [edge|origin]` follows container output.
* The whole `lab/` directory is mounted into the edge at `/lab`, so edits to `nginx.conf` and `lumina.js` are picked up by `./lab.sh reload`. Logs are in `lab/logs/` (gitignored).

**`helpers.sh`**
* `r PATH [curl options]`: one request to the edge, `<- STATUS` and then the body. `rh` shows the headers too.
* `token SUB [--plan P] [--ttl S] [--jti ID] [--key K]`: a session token (JWT, HS256). `--ttl -60` is already expired; `--key` signs with another key (a forgery).
* `link PATH [--ttl S] [--key K]`: a signed download link.
* `tel DEVICE [--sig S] [--silent]`: one telemetry connection with a signed greeting (or the signature you give, or nothing).
* `decode TOKEN`, `revoke ID` / `unrevoke [ID]`, `ostats`, `elog [N]`.

**The application (`origin.py`)** answers any path with JSON: the **pool** that answered, the method and URI, the **`X-User`** it received and the body size. `/api/account` includes card numbers, `/downloads/*` is a small file, and `/_revoked` lists revoked session IDs (`/_revoke?jti=`, `/_unrevoke`).

> **Version notes (verified on nginx 1.31.6 + njs 1.0.1 in `nginx:mainline`):**
> * The default engine (`njs`) gives each request a fresh context; `js_engine qjs` reuses contexts, so globals persist per worker.
> * The default engine has no `class`, destructuring, spread, generators, `Map`/`Set` or BigInt; QuickJS has them. QuickJS has no `require()`.
> * Workers see only the environment variables named by `env` directives. `js_periodic` runs on worker 0. `ngx.fetch` to a hostname needs a `resolver`. `js_set` handlers can't be async.

---

## 3. Daily Detail

### Day 1: How njs Runs
**Concepts:**
* njs as a module inside the worker, compiled at configuration load.
* The request object; `js_content`, `js_set`, filters, `js_periodic`, `js_preread`.
* The `njs` and QuickJS engines: context per request vs reused; globals per worker.
* The JavaScript you get, and what the default engine lacks.
* Syntax errors vs run-time exceptions.

**Lab:**
* An edit that needs a reload; a syntax error that `nginx -t` refuses.
* A global counter under each engine.
* The `njs` shell with both engines.
* `$client_lang` from `js_set`, called once per request and only when used, and the `map` that does the same.
* `/edge/info`: arguments, cookies and a decoded (unverified) session; a forgery it believes.
* A malformed cookie that causes a `500`, and `try`/`catch`.

### Day 2: Signatures, Bodies and Shared State
**Concepts:**
* HMAC, JWT HS256 checks (signature, algorithm, expiry, revocation).
* `env` and `process.env`: what the environment protects against, and what it doesn't.
* `secure_link` (MD5, secret in the config) vs njs (HMAC-SHA256, key outside).
* `js_header_filter` and `js_body_filter`; `Content-Length` when the body changes.
* `r.requestText`; `internalRedirect` vs `subrequest` vs `ngx.fetch`.
* `js_shared_dict_zone` and `js_periodic`.

**Lab:**
* Verification that fails closed without `env`, then rejects forged and expired tokens.
* `X-User` from the verified session, and a location that lets a spoofed one through.
* Native and scripted signed links.
* Card masking that truncates the response, then the fix.
* Order validation at the edge.
* A revocation list refreshed every 2 seconds (after adding the resolver it needs).

### Day 3: Routing, TCP & the Sprint Lab
**Concepts:**
* `proxy_pass http://$pool` and who controls the variable.
* Stream njs: `js_preread`, `js_access`, `js_filter`, `s.on('upload')`, `preread_timeout`, and native `ssl_preread`.
* The event loop: what blocks a worker and what doesn't.
* Native vs script, and the sprint in iRule terms.

**Lab:**
* Beta routing on a plain cookie, then on a verified claim, and a location that skips it.
* A TCP gatekeeper for the telemetry port, and a silent client.
* Two slow requests that stall the whole edge.
* Then build Lumina Edge Functions (Section 4) and pass `test_sprint06.sh`.

---

## 4. Lab Specification: Lumina Edge Functions

Copy `lab/starter_nginx.conf` to `lab/nginx.conf` and `lab/starter_lumina.js` to `lab/lumina.js`. The edge listens on 8096 (HTTP) and 8097 (TCP). The pools are the `stable` and `beta` upstreams; the telemetry intake is the `telemetry` upstream in the `stream` block.

**Formats.** All signatures use HMAC-SHA256 with the signing key.
* **Session:** the `lumina_session` cookie holds a JWT: `base64url(header).base64url(claims).base64url(signature)`, where the header is `{"alg":"HS256","typ":"JWT"}` and the signature is over `header.claims`. Claims: `sub` (the user), `plan` (`beta` or `standard`), `exp` (Unix seconds) and optionally `jti` (the session ID). A session is **valid** when its signature is right, `exp` is in the future, and it isn't revoked.
* **Download link:** `/downloads/<name>?expires=<Unix seconds>&sig=<hex HMAC of "<path>:<expires>">`, where `<path>` is the URI path, for example `/downloads/report.pdf`.
* **Telemetry greeting:** the first line of a connection, `HELLO <device> <sig>`, where `sig` is the first 16 hex digits of the HMAC of `<device>`.

**Requirements:**
1. **Key:** every signature is checked with the key in the edge's `LUMINA_KEY` environment variable. The key isn't written in any configuration or script file.
2. **Identity:** a request with a valid session reaches the application with an `X-User` header holding the session's `sub`. Every other request reaches the application without `X-User`, whatever the client sent.
3. **Malformed sessions:** a malformed session cookie is treated as no session, never as an error.
4. **Beta:** a request with a valid session whose `plan` is `beta` goes to the beta pool; everything else goes to the stable pool.
5. **Revocation:** a session whose `jti` is on the application's revocation list (`http://s6-origin:8016/_revoked`, JSON `{"revoked": [...]}`) stops being valid within 5 seconds of being listed, and is valid again within 5 seconds of being removed.
6. **Edge info:** `GET /edge/info` is answered by the edge itself, never the application, with a JSON object: `"client"` (the client's address) and `"user"` (the `sub` of a valid session, or `null`).
7. **Downloads:** only valid signed links are served under `/downloads/`. A missing or wrong signature gets `403`; a valid signature whose expiry has passed gets `410`. Refused requests never reach the application.
8. **Orders:** `POST /api/orders` accepts only a JSON object with an integer `qty` from 1 to 100; anything else gets `400` from the edge and never reaches the application.
9. **Card numbers:** no response under `/api/` carries a full card number: each 16-digit number (optionally in groups of four separated by spaces or dashes) is replaced by `****-****-****-` and its last four digits. The client still receives the complete response.
10. **Telemetry:** a connection to 8097 reaches the telemetry intake only if its first line is a valid greeting. Any other connection is closed without contacting the intake, and a client that sends nothing is closed within 5 seconds.

`lab/solution_nginx.conf` and `lab/solution_lumina.js` are the reference.

---

## 5. Automated Test Suite (`test_sprint06.sh`)

```bash
cd /srv/nginx-journey/sprints/sprint-6 && ./test_sprint06.sh
```
* It runs `lab/lab.sh check` first. If the lab isn't ready, it stops with a setup message and tests nothing.
* Every run uses fresh user names, session IDs and paths, so earlier runs and your own experiments don't affect it.
* It takes about 10 seconds: the revocation check waits for the edge to notice, and a silent telemetry client waits to be closed.
* Run against the untouched starter, it reports 0/10 and **`Sprint 6 start is ready to go`**.
* Override `EDGE` or `ORIGIN` to point it elsewhere.

| # | Assertion (gate: 10/10) | Requirement |
| :--- | :--- | :---: |
| 1 | A session or link signed with the lab key is accepted while the same one signed with another key isn't, and the key is in no `.conf`, `.js` or `.json` file under `lab/` | 1 |
| 2 | A valid session reaches the application as `X-User: <sub>`; a client's own `X-User` doesn't, with or without a session | 2 |
| 3 | Five malformed session cookies: `/edge/info` says `"user": null` and `/api/` answers `200` for each | 3 |
| 4 | A valid beta session reaches the beta pool; standard, none, forged (another key) and expired beta sessions reach stable | 4 |
| 5 | A session stops being valid within 6 s of its `jti` being revoked, and is valid again within 6 s of removal | 5 |
| 6 | `/edge/info` returns JSON with the client's address and `user` (null, then the session's `sub`); the application never sees it | 6 |
| 7 | Valid link `200`; no signature, wrong signature, another path, another key `403`; expired `410`; the application sees only the valid one | 7 |
| 8 | A valid order reaches the application; eight invalid bodies get `400` and don't | 8 |
| 9 | `/api/account`: three card numbers become `****-****-****-1111`, `-0004`, `-1881`; `order 1234567890` is untouched; the JSON is complete | 9 |
| 10 | A signed greeting gets `ACK`; a wrong signature and another device's signature are closed; a silent client is closed within 6 s; the intake sees one connection | 10 |

---

## 6. Daily Quizzes

All pools live in [`data/quizzes.json`](../../data/quizzes.json). Each day has 20 questions (8 scenario, 6 config, 3 diagnose, 3 recall). The quiz draws 10, and 8/10 passes.

* **Day 1:** where njs runs, compile at load, the handlers, `js_set` evaluation, the two engines and globals, the default engine's language, exceptions and `500`, decoding vs verifying.
* **Day 2:** HMAC and JWT checks, `env`, `secure_link` vs njs, `proxy_set_header` and spoofing, filters and `Content-Length`, request bodies, `internalRedirect` / `subrequest` / `ngx.fetch`, shared dictionaries and `js_periodic`.
* **Day 3:** `proxy_pass $var`, routing in every location, stream njs, `preread_timeout`, `ssl_preread`, blocking scripts, native vs script.
* **Enterprise:** Sprint 6's enterprise questions are part of the Side Quest Gauntlet's quiz (Sprints 4–6): [Gauntlet Quiz](../../quiz.html?sprint=6&day=3&pool=gauntlet).

```bash
cd /srv/nginx-journey && python3 -m http.server 8090
# http://<lab-host>:8090/quiz.html?sprint=6&day=1   (day=2, day=3)
```

---

## 7. Optional Extras

* **6.1 Constant-time comparison.** The lab compares signatures with `!=`. Why might a security reviewer object, and how much does it matter over a network?

  <details>
  <summary>Answer</summary>

  A string comparison can stop at the first differing character, so in theory the response time leaks how many leading characters of a forged signature were right, letting an attacker build a valid one byte by byte. Over a network the difference (nanoseconds) is buried in jitter, and the HMAC is computed fresh per request, but the standard practice is still a constant-time comparison: compare every character and accumulate the differences (`diff |= a.charCodeAt(i) ^ b.charCodeAt(i)`) before deciding. It costs nothing and ends the discussion in a review.
  </details>

* **6.2 One key, three jobs.** The lab signs sessions, links and telemetry with one key. What goes wrong, and what would you do in production?

  <details>
  <summary>Answer</summary>

  A key that leaks from one system (say, the link signer in a CMS) forges all three, and rotating it logs everyone out, breaks every link and disconnects every device at once. Use one key per purpose (separate `env` variables), and support two keys during a rotation (accept old and new, sign with new), with a key ID (`kid` in a JWT header) to say which signed what.
  </details>

* **6.3 `js_engine qjs` for the whole edge.** What would you check before switching the lab's script to QuickJS?

  <details>
  <summary>Answer</summary>

  That nothing keeps per-request data in a global (with context reuse it survives into the next request on that worker), that `require()` isn't used (QuickJS has only `import`), and the memory and throughput under load, since reused contexts keep what their globals hold. In exchange you get the modern language (`class`, `Map`, destructuring) and, for scripts with heavy setup, less work per request.
  </details>

* **6.4 Test a function before the reload.** `lumina.js` is a module that NGINX loads. How could you run its `session()` logic in the `njs` shell without NGINX?

  <details>
  <summary>Answer</summary>

  Keep the pure logic (parse, verify, check expiry) in functions that take plain values (a token string, a key, the current time) instead of `r`, and export them. Then a small test script can `import` the module in the shell (`./lab.sh njs -m test.js`) and call them with known inputs. Code that needs `r`, `ngx.shared` or `ngx.fetch` stays thin. It's the same habit as keeping iRule procedures in a library and testing them separately.
  </details>

---

## 8. Tracker Sync

* **Platform milestone:** Lumina's edge verifies sessions with a key that never touches a file, tells the application who the user is (and nothing a client made up), routes beta customers by a signed claim, honors revocations within seconds without a reload, serves only signed download links, refuses malformed orders, masks card numbers in responses, and admits only signed devices to its telemetry port.
* **Graduation:** `test_sprint06.sh` 10/10, and at least 80% on each day's quiz.

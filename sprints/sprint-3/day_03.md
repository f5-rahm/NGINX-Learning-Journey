# Sprint 3 &bull; Day 3: Security Headers & the Sprint Lab
**Day:** 3 of 3  
**Estimated Time:** 75 Minutes (10 concepts, 3 setup, 17 activities, 35 Lumina build, 10 quiz)  
**Optional:** [Enterprise Side Quest](day_03_enterprise.md), 45 minutes: certificates without reloads (NGINX Plus) and automatic issuance (ACME)  
**Theme:** TLS protects the connection. Response headers tell the browser how to behave once the page arrives. Add them so they appear on every response, then put the whole sprint together on Lumina.

---

## 1. Concepts to Understand (10 Minutes)

### 1.1 The Headers That Matter at the Edge

| Header | What it tells the browser | Watch out for |
| :--- | :--- | :--- |
| `Strict-Transport-Security` (HSTS) | "Only ever use HTTPS for this host, for `max-age` seconds." Removes the plain-HTTP first request after the first visit. | Browsers ignore it over plain HTTP, so send it from the HTTPS server only. `includeSubDomains` covers every subdomain, including ones that don't have HTTPS yet. `preload` is close to permanent: undoing it takes months. Start with a short `max-age` and raise it. |
| `X-Content-Type-Options: nosniff` | Trust `Content-Type`; don't guess. Stops a user-uploaded "image" from running as script. | None; always send it |
| `X-Frame-Options: DENY` / CSP `frame-ancestors 'none'` | Don't render this page inside someone else's frame (clickjacking) | `frame-ancestors` is the modern form. Sending both is common. |
| `Content-Security-Policy` | Which sources may load script, style, images... | Application-specific. Deploy as `Content-Security-Policy-Report-Only` first. |
| `Referrer-Policy` | How much of the URL leaks to other sites | `strict-origin-when-cross-origin` is the browser default today |

**BIG-IP lens:** on BIG-IP these come from an HTTP profile's header insert, an iRule (`HTTP::header insert` in `HTTP_RESPONSE`), or ASM/Advanced WAF policy. In NGINX they come from `add_header`, which has two traps (1.2 and 1.3).

### 1.2 `add_header` and Status Codes
By default, `add_header` adds the header **only to 200, 201, 204, 206, 301, 302, 303, 304, 307 and 308** responses.
* A 404 page, a 502 from a dead backend, or a 429 from a rate limiter goes out **without** your security headers.
* The `always` parameter adds the header to every status. For security headers, always use `always`.

### 1.3 `add_header` Inheritance, Revisited
Sprint 1 Day 2 and Sprint 2 Day 1 met this rule: a level inherits `add_header` (or `proxy_set_header`) from its parent **only if it defines none of its own**.
* One `add_header Cache-Control no-store` in a location silently drops HSTS, `nosniff`, `X-Frame-Options` and Day 2's `Alt-Svc` **for that location**.
* `nginx -t` says nothing.
* **Fixes:**
  * Put the full list in an `include` snippet, used in every location that adds its own header.
  * Or, on newer NGINX (the lab's 1.31.6 has it), **`add_header_inherit merge;`** in the child, which keeps the parent's headers and adds its own.

### 1.4 Headers You Remove

| Leak | Comes from | Fix |
| :--- | :--- | :--- |
| `Server: nginx/1.31.6` | NGINX | `server_tokens off;` leaves just `nginx` (removing the header entirely needs NGINX Plus or a third-party module) |
| `X-Powered-By`, `X-AspNet-Version`, and the mocks' `X-Handled-By` | The backend | `proxy_hide_header X-Handled-By;` (per header; inherited like other proxy settings) |

If the backend already sends a header that you also `add_header`, the client gets **both copies**. Hide the backend's copy first, or set it in only one place.

---

## 2. Lab Setup (3 Minutes)

```bash
cd /srv/nginx-journey/sprints/sprint-3/lab
../../sprint-2/lab/mocks.sh start
cp day3_nginx.conf nginx.conf             # Day 2's result: TLS + HTTP/2 + HTTP/3, no security headers yet
ngx -t && (ngx -s reload 2>/dev/null || ngx)
source helpers.sh
hdrs() { for p in "$@"; do echo "== $p"; c -D - -o /dev/null "https://lumina.local:8443$p" \
  | grep -iE '^(HTTP|strict|x-content|x-frame|alt-svc|cache-control|server|x-handled)' | tr -d '\r'; done; }
```
`hdrs /a /b ...` prints the status and the interesting headers for each path.

---

## 3. Hands-on Guided Discovery Activities (17 Minutes)

### Activity 3.1: Baseline (2 min)
```bash
hdrs / /nope /api/x
```
* Only `Alt-Svc` from Day 2, plus `Server: nginx/1.31.6`.
* On `/api/x`, the backend's own `X-Handled-By: api-node-N`.

### Activity 3.2: Add the Headers, Then Check the Errors (6 min)
Add to the lumina.local server, next to `Alt-Svc`:
```nginx
add_header Strict-Transport-Security "max-age=31536000";
add_header X-Content-Type-Options    "nosniff";
add_header X-Frame-Options           "DENY";
```
```bash
ngx -t && ngx -s reload
hdrs / /nope '/api/x?status=502'
```
Which responses got the headers? Fix the three lines so that every response does, then rerun `hdrs`. Also try one over HTTP/3:
```bash
h3 -I --http3-only https://lumina.local:8443/nope | grep -iE '^(HTTP|strict)'
```
<details>
<summary>Result</summary>

* Without `always`, only the 200 has them. The 404 and the 502 (the mock answering `?status=502`) go out bare.
* Add `always` to each line. Note that `Alt-Svc` already had it.
</details>

### Activity 3.3: The Inheritance Trap (5 min)
Downloads should never be cached. Add to `location /downloads/`:
```nginx
add_header Cache-Control "no-store" always;
```
```bash
ngx -t && ngx -s reload
hdrs /downloads/
```
* `Cache-Control` is there. HSTS, `nosniff`, `X-Frame-Options` and `Alt-Svc` are gone, so this location no longer even advertises HTTP/3.
* Fix it with `add_header_inherit merge;` in the same location, reload, and check again.
* *Journal:* which fix would you choose for a 40-location production config, `add_header_inherit merge` or an `include` snippet? What does each one look like in `nginx -T`?

### Activity 3.4: Stop the Leaks (4 min)
```bash
hdrs /api/x
```
Make the version and the backend's `X-Handled-By` disappear, using the directives from concept 1.4. Where does each belong, `http`, `server` or `location`?
```bash
ngx -t && ngx -s reload && hdrs /api/x
```

---

## 4. Sprint Lab: The Lumina Zero-Trust Edge (35 Minutes)

Requirements: [README Section 4](README.md#4-lab-specification-lumina-zero-trust-edge).
```bash
cd /srv/nginx-journey/sprints/sprint-3/lab
cp starter_nginx.conf nginx.conf          # every TODO is a requirement; Days 1-3 and Sprint 2 have the how
ngx -t && ngx -s reload
cd .. && ./test_sprint03.sh               # gate: 13/13
```
* The test reloads your NGINX once to check session resumption across a reload.
* It runs HTTP/3 checks through the `alpine/curl-http3` container.
* `lab/solution_nginx.conf` is the reference. Try the test first.

---

## 5. Day 3 Concept Examination (10-Question Randomized Quiz)

👉 **http://&lt;lab-host&gt;:8090/quiz.html?sprint=3&day=3** (serve with `cd /srv/nginx-journey && python3 -m http.server 8090`)

The optional Enterprise Side Quest has its own 10-question quiz. It doesn't count toward graduation.

---

## 6. Key Takeaways for Day 3
* **Security headers need `always`,** or every error page goes out without them.
* **One `add_header` in a child level drops every inherited one,** including `Alt-Svc`. Use `add_header_inherit merge` or an `include` snippet, and audit with `nginx -T`.
* **HSTS is a commitment.** Ramp up `max-age`, and treat `includeSubDomains` and `preload` as decisions, not defaults.
* **Hide what you didn't mean to publish:** `server_tokens off` for NGINX's version, and `proxy_hide_header` for the backend's headers.
* **The edge is a stack:** TLS policy (Day 1), protocols (Day 2), browser policy (Day 3), and the Sprint 2 proxying underneath.

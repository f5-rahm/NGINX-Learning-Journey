# Sprint 6 &bull; Day 3: Routing, TCP and the Price of a Script
**Day:** 3 of 3  
**Estimated Time:** 90 Minutes (15 concepts, 5 setup, 25 activities, 35 sprint lab, 10 quiz)  
**Theme:** Today the verified session decides **where** a request goes, not only who it's from. The same engine then moves down to TCP, where there are no headers or cookies, only the first bytes of a connection, like an iRule in `CLIENT_DATA`. Then the bill: a script runs inside the worker, so a slow one is everyone's problem. The sprint lab puts the week's pieces together into Lumina's edge.

---

## 1. Concepts to Understand (15 Minutes)

### 1.1 Routing on a Verified Claim
* **`proxy_pass http://$pool;`** picks an `upstream` block by name at request time. The variable can come from `map`, `set` or `js_set`.
* **Whatever sets the variable decides who can reach the pool.** A `map` on a plain cookie (`$cookie_lumina_plan`) routes anyone who sets that cookie. A `map` can't check a signature, so routing on a **verified** claim needs the script: `js_set $pool` returns `beta` only when the session passes Day 2's checks.
* **Every location that proxies must use the same variable.** A named location reached by `internalRedirect` (`@app`) has its own `proxy_pass`. If it still says `http://stable`, those requests skip the routing.
* **When native is enough:** routing on a header your own load balancer sets, on the client network (`geo`), or a percentage split (`split_clients`) needs no script. Sprint 8 brings the same choices to Kubernetes (`VirtualServer` matches and splits).

### 1.2 njs for TCP: the Stream Module
The `stream` module proxies TCP and UDP, and `ngx_stream_js_module` gives it njs. There's no request object: the function gets a **session**, `s`, with the connection's addresses and its data as it arrives.

| Directive | Runs | Typical job |
| :--- | :--- | :--- |
| `js_preread` | Before the upstream is chosen, while the client's first bytes arrive | Read a greeting, protocol header or token, then allow or deny |
| `js_access` | In the access phase | Allow or deny on the address, or on variables |
| `js_filter` | On every piece of data, in both directions, for the whole connection | Change or inspect the stream |
| `js_set` | When a variable is used | Choose an upstream (`proxy_pass $var`) |

* **The data handler.** `s.on('upload', function (data, flags) { ... })` is called as client bytes arrive. Return without deciding to wait for more; `s.allow()` lets the connection through (the bytes read so far are forwarded to the upstream); `s.deny()` closes it **before any upstream connection is made**.
* **`preread_timeout`** (default 30 s) bounds how long a client can keep a connection open without completing the preread. A client that sends nothing holds a connection, and a slot, until then.
* **TLS without a script:** `ssl_preread on;` exposes the ClientHello's SNI (`$ssl_preread_server_name`) and ALPN, so `map` + `proxy_pass $var` routes TLS by hostname with no script and no decryption.
* BIG-IP: `CLIENT_DATA` with `TCP::collect`, `TCP::payload`, `TCP::release` / `reject`. iRules can also hold the decision while asking another service; njs preread can `await` too, but every second spent there is the client's connection held open.

### 1.3 What a Script Costs
* **A worker is a single thread running an event loop.** While a script runs, that worker does nothing else: no other request, no other connection. A script that takes 2 seconds stalls every request that worker is serving. NGINX's speed comes from never blocking. A script breaks that promise if you let it.
* **What blocks:** CPU loops (parsing a huge body, regular expressions on large text, crypto per request), synchronous work over large data. **What doesn't:** `await ngx.fetch()`, `r.subrequest()` and timers. The worker serves other requests while it waits.
* **Mitigations:**
  * Keep per-request work small.
  * Move expensive or remote decisions to `js_periodic` + a shared dictionary (Day 2).
  * Set limits on bodies (`client_max_body_size`) and on fetches (`js_fetch_timeout`, `js_fetch_max_response_buffer_size`).
  * Don't run scripts where native directives do the job.
* **Memory:**
  * With the default engine, each request's context is freed when the request ends.
  * With QuickJS, reused contexts keep what their globals point to.
  * The shared dictionary is a fixed size you choose. When it's full, `set` fails unless the zone evicts (`evict`).

### 1.4 Native or Script: the Rule of Thumb

| Job | Native | njs |
| :--- | :--- | :--- |
| Pick a value from a header, cookie or address | `map`, `geo`, `split_clients` | Only if it must be verified or computed |
| Signed links | `secure_link` (MD5, secret in config) | HMAC-SHA256, key outside the config |
| Identity from a token | Plus `auth_jwt` (Sprint 7), `auth_request` to a service | HMAC JWT checks, as this week |
| Rewrite response bodies | `sub_filter` (fixed strings) | Patterns, structure-aware edits |
| Validate request bodies | `client_max_body_size` only | Structure and values |
| Route TLS by hostname | `ssl_preread` + `map` | Not needed |
| Inspect a custom TCP protocol | Nothing | `js_preread` |
| Shared counters and lists | `limit_req` / `limit_conn` zones; Plus `keyval` | `js_shared_dict_zone` |

Native directives can't throw, are written in C, and are understood by every NGINX operator. Scripts are code: they need tests, reviews and owners. Choose them where they earn it.

### 1.5 BIG-IP Lens: the Sprint in One Table

| iRule habit | njs equivalent |
| :--- | :--- |
| `when HTTP_REQUEST { ... HTTP::respond }` | `js_content` |
| `set` a value for later events | `js_set $var` (computed once, when used) |
| `pool beta` | `js_set $pool` + `proxy_pass http://$pool` |
| `CRYPTO::sign` / `verify` | `crypto.createHmac` |
| `HTTP::collect` / `HTTP::payload` | `r.requestText`; `js_header_filter` + `js_body_filter` |
| `table` | `js_shared_dict_zone` |
| `after -periodic`, iCall | `js_periodic` |
| sideband (`connect`/`send`/`recv`) | `ngx.fetch`, `r.subrequest` |
| `CLIENT_DATA` + `TCP::collect` + `reject` | `js_preread` + `s.on('upload')` + `s.deny()` |
| "iRules run on the TMM's data path: keep them short" | Scripts run on the worker's event loop: keep them short |

---

## 2. Lab Setup (5 Minutes)

```bash
cd /srv/nginx-journey/sprints/sprint-6/lab
cp day3_nginx.conf nginx.conf           # Day 2's edge: sessions, X-User, links, masking, orders, revocation
cp day3_lumina.js lumina.js             # the script as Day 2 left it
./lab.sh up                             # or ./lab.sh reload if the lab is still up
source helpers.sh
```
New today: `tel DEVICE [--sig S] [--silent]` opens one connection to the telemetry port, **:8097**, and sends `HELLO <device> <sig>` (the right signature unless you give one) and a reading. It prints what came back and when: the intake answers `ACK <bytes>`. `ostats` counts the connections that reached the intake as `telemetry`.

---

## 3. Hands-on Guided Discovery Activities (25 Minutes)

### Activity 3.1: Routing on a Claim (8 min)
Beta customers should reach the beta pool. The quick way: a `map` on a cookie. At `http` level, above `upstream stable`:
```nginx
map $cookie_lumina_plan $plan_pool {
    beta     beta;
    default  stable;
}
```
and in `location /api/`, change `proxy_pass http://stable;` to:
```nginx
proxy_pass http://$plan_pool;
```
```bash
./lab.sh reload
r /api/me | grep pool
r /api/me -b 'lumina_plan=beta' | grep pool
```
`stable`, then `beta`: anyone who types the cookie is a beta customer. Route on the **verified** session instead. Above `// GET /edge/info`, and `pool` in the export list:
```js
// js_set $pool: beta for a verified session on the beta plan, stable for everyone else
function pool(r) {
    var s = session(r);
    return s && s.plan == 'beta' ? 'beta' : 'stable';
}
```
In `nginx.conf`, under the other `js_set` lines:
```nginx
js_set $pool lumina.pool;
```
and in `location /api/`, `proxy_pass http://$pool;`.
```bash
./lab.sh reload
r /api/me -b 'lumina_plan=beta' | grep pool
r /api/me -b "lumina_session=$(token alice --plan beta)" | grep -E 'pool|x_user'
r /api/me -b "lumina_session=$(token bob)" | grep pool
r /api/me -b "lumina_session=$(token mallory --plan beta --key guess)" | grep pool
T=$(token carol --plan beta --jti s-7); revoke s-7; sleep 2.5
r /api/me -b "lumina_session=$T" | grep pool
unrevoke s-7
r /api/orders -d '{"qty": 2}' -b "lumina_session=$(token alice --plan beta)" | grep pool
```
<details>
<summary>Everything routes correctly except the last one. Why?</summary>

The plain cookie, Bob's standard plan, Mallory's forgery and Carol's revoked session all go to `stable`; only Alice's verified beta session reaches `beta`. Revocation applies to routing for free, because `pool()` uses the same `session()` check.

Alice's **order** went to `stable`: `/api/orders` is handled by `js_content`, which hands it to `@app` with `internalRedirect`, and `@app` still says `proxy_pass http://stable;`. Routing has to be applied in every location that proxies. In the sprint lab, all of them use `$pool`.
</details>

### Activity 3.2: A Gatekeeper for TCP (10 min)
Lumina's devices send readings over TCP to a telemetry intake behind the edge. First a plain TCP proxy. In `nginx.conf`, under the first `load_module` line:
```nginx
load_module /usr/lib/nginx/modules/ngx_stream_js_module.so;
```
and at the end of the file, after the `http` block's closing brace:
```nginx
stream {
    upstream telemetry { server s6-origin:8036; }

    server {
        listen 8097;
        proxy_pass telemetry;
    }
}
```
```bash
./lab.sh reload; ./lab.sh reset
tel dev-17
tel dev-17 --sig 0000000000000000
tel dev-17 --silent
ostats | grep telemetry
```
All three reach the intake (`"telemetry": 3`): a device with the wrong signature gets an `ACK` just like a real one, and a client that sends nothing holds the intake for 2 seconds until the intake gives up.

Now the gatekeeper. A greeting is `HELLO <device> <sig>`, where `sig` is the first 16 hex digits of the HMAC-SHA256 of the device name with Lumina's key. Above `// GET /edge/info`, and `telemetry` in the export list:
```js
// stream js_preread: the first line must be "HELLO <device> <sig>",
// sig = the first 16 hex digits of HMAC-SHA256(key, device)
function telemetry(s) {
    var buf = '';
    s.on('upload', function (data, flags) {
        buf += data;
        var nl = buf.indexOf('\n');
        if (nl == -1) {
            if (buf.length > 512 || flags.last) {
                s.deny();
            }
            return;                          // no full line yet: wait for more
        }
        var f = buf.slice(0, nl).trim().split(' ');
        var key = process.env.LUMINA_KEY;
        var want = key ? crypto.createHmac('sha256', key).update(f[1] || '').digest('hex').slice(0, 16) : null;
        if (f.length == 3 && f[0] == 'HELLO' && want && f[2] == want) {
            s.allow();
        } else {
            s.warn('telemetry refused: ' + buf.slice(0, nl));
            s.deny();
        }
    });
}
```
The `stream` block needs its own import (it doesn't see the `http` block's), and the server gets the handler:
```nginx
stream {
    js_path   /lab/;
    js_import lumina from lumina.js;

    upstream telemetry { server s6-origin:8036; }

    server {
        listen 8097;
        js_preread lumina.telemetry;
        proxy_pass telemetry;
    }
}
```
```bash
./lab.sh reload; ./lab.sh reset
tel dev-17
tel dev-17 --sig 0000000000000000
tel dev-17 --silent
ostats | grep telemetry
elog 1
```
<details>
<summary>Two out of three. What's left?</summary>

The valid device gets `ACK`, the wrong signature is `closed without an answer after 0.0s` with a `telemetry refused` warning, and the intake counts **1**: the refused connection never reached it.

But the silent client prints `no answer after 10.0s (still open)`. It never sends a line, so the handler never decides, and the edge holds the connection until `preread_timeout`, 30 seconds by default. A few thousand of those is a cheap way to tie up the edge.
</details>

Bound the wait. In the stream `server`, above `js_preread`:
```nginx
preread_timeout 5s;
```
```bash
./lab.sh reload; ./lab.sh reset
tel dev-17 --silent
ostats | grep telemetry
```
`closed without an answer after 5.0s`, and the intake counts **0**.

### Activity 3.3: What a Slow Script Costs (7 min)
Add a deliberately bad function: it keeps the CPU busy for a number of milliseconds. Above `// GET /edge/info`, and `spin` in the export list:
```js
// GET /edge/spin?ms=N: a script that keeps the worker busy for N milliseconds
function spin(r) {
    var until = Date.now() + Number(r.args.ms || 2000);
    while (Date.now() < until) { }
    r.return(200, 'spun on worker ' + ngx.worker_id + '\n');
}
```
and in `nginx.conf`, above `location = /edge/info`:
```nginx
location = /edge/spin {
    js_content lumina.spin;
}
```
One slow request, then six quick ones while it runs:
```bash
./lab.sh reload
(curl -s 'localhost:8096/edge/spin?ms=3000' & sleep 0.3
 for i in 1 2 3 4 5 6; do curl -s -o /dev/null -w "ping %{time_total}s\n" localhost:8096/api/ping & done; wait)
```
Every ping is answered in about 2 ms. Now **two** slow requests:
```bash
(curl -s 'localhost:8096/edge/spin?ms=3000' & curl -s 'localhost:8096/edge/spin?ms=3000' & sleep 0.3
 for i in 1 2 3; do curl -s -o /dev/null -w "ping %{time_total}s\n" localhost:8096/api/ping & done; wait)
```
<details>
<summary>What happened, and why?</summary>

With one spin (`spun on worker 0`), the other worker was free and took the new connections, so the pings never noticed. With two (`spun on worker 1`, `spun on worker 0`), both workers were busy, and **every** ping waited about **2.7 seconds**, the rest of the spin, for a request that needed 1 ms of work.

A worker runs one thing at a time. A script that blocks it blocks every connection that worker holds, and in this lab two slow requests were enough to stall the whole edge. Real versions of `spin` are less obvious: a regular expression on a large body, decompressing an upload, a loop over a big list per request. Keep per-request work small, and move slow or remote work to timers and shared state.
</details>

Remove the `/edge/spin` location before going on.

---

## 4. The Sprint Lab: Lumina Edge Functions (35 Minutes)

Build Lumina's edge from the starter: the requirements are in [`README.md` section 4](README.md#4-lab-specification-lumina-edge-functions). You may reuse any function you wrote this week. Everything you need was in an activity, but the requirements are stricter in a few places.

Start with the baseline: the starter loads, and every requirement fails.
```bash
cd /srv/nginx-journey/sprints/sprint-6/lab
cp starter_nginx.conf nginx.conf
cp starter_lumina.js lumina.js
./lab.sh reload
cd .. && ./test_sprint06.sh
```
The run ends with `Requirements: 0 / 10 passed` and **`Sprint 6 start is ready to go`**. Then work through the TODOs, reload, and run the test as often as you like. Each failure says what it sent and what came back.

<details>
<summary>Hints, if you're stuck (one per requirement, no code)</summary>

* **Key:** what does a worker's `process.env` contain by default?
* **X-User:** which locations proxy? Each of them needs to set the header, including named ones.
* **Malformed cookies:** the test sends five kinds of junk. Which line of your parser throws on each?
* **Beta pool:** the forged and expired tokens must go to `stable` too.
* **Revocation:** the test waits up to 6 seconds each way.
* **/edge/info:** the address is what the edge sees, not what a header claims.
* **Links:** a valid signature on an expired link is `410`; anything with a bad signature is `403`, expired or not.
* **Orders:** `"5"`, `2.5`, an array, a missing field and an empty body are all invalid.
* **Masking:** count the bytes, then check what the client received.
* **Telemetry:** how long does the edge wait for a client that sends nothing?
</details>

`lab/solution_nginx.conf` and `lab/solution_lumina.js` are the reference.

---

## 5. Day 3 Concept Examination (10-Question Randomized Quiz)

```bash
cd /srv/nginx-journey && python3 -m http.server 8090
```
👉 **http://&lt;lab-host&gt;:8090/quiz.html?sprint=6&day=3**

When you're done for the day: `./lab.sh down`.

**Enterprise side quest:** Sprint 6's side quest (njs with the NGINX Plus key-value store and API, and njs compared with OpenResty/Lua) moves into the **Side Quest Gauntlet** after this sprint, together with the side quests of Sprints 4 and 5.

---

## 6. Key Takeaways for Day 3
* **`proxy_pass http://$pool`** routes per request; the source of the variable decides who can choose the pool. Verified claims need the script; plain values don't.
* **Apply routing and identity in every location that proxies,** including named ones.
* **Stream njs works on bytes:** `js_preread` + `s.on('upload')`, then `s.allow()` or `s.deny()`. A denied connection never reaches the upstream.
* **`preread_timeout` bounds silent clients.** The default is 30 seconds.
* **A blocking script blocks its worker.** Two slow requests stalled the whole two-worker edge.
* **Native first, script where it earns it.** `map`, `secure_link`, `ssl_preread`, `sub_filter` and the limit zones need no code.

# Sprint 2 &bull; Day 3: Failure Handling, WebSockets & the Sprint Lab
**Date:** Thursday, Oct 8  
**Estimated Time:** 75 Minutes (15 concepts, 5 setup, 35 lab, 15 Lumina build, 10 quiz)  
**Theme:** Backends fail in different ways, and each leaves a different mark in the logs. Learn to recognize them, choose what to retry, and keep long-lived connections alive.

---

## 1. Concepts to Understand (15 Minutes)

### 1.1 Passive Health Checks
NGINX open source learns that a server is unhealthy only when a **real client request** to it fails.
```nginx
server 10.0.0.5:8080 max_fails=2 fail_timeout=5s;
```

**How marking works**
* If `max_fails` unsuccessful attempts happen within `fail_timeout`, the server is marked unavailable for `fail_timeout`. The defaults are `max_fails=1` and `fail_timeout=10s`.
* After `fail_timeout` passes, NGINX sends it real requests again. A success clears the failure count; another failure marks it unavailable again.
* `max_fails=0` disables failure accounting entirely.

**What counts as "unsuccessful"**
* The same conditions you list in `proxy_next_upstream` (1.3).
* `error` and `timeout` always count. `http_5xx` responses count only if they're listed.

**Watch out for**
* **Without a `zone`, each worker counts separately**, so a dead node can be tried up to `max_fails` × `worker_processes` times.
* **Failures from different experiments add up.** A burst of timeouts on one URL can empty the pool for every other URL.

### 1.2 Timeouts and the Errors They Produce

| Directive (default) | Measures | When it fires |
| :--- | :--- | :--- |
| `proxy_connect_timeout` (60s) | Establishing the TCP connection | Backend host unreachable or SYN dropped |
| `proxy_send_timeout` (60s) | Gap between two successive **writes** to the backend | Backend stops reading a large request body |
| `proxy_read_timeout` (60s) | Gap between two successive **reads** from the backend | Slow first byte, a stalled stream, or an idle WebSocket |

Read and send timeouts are **not** total-duration limits. A response that trickles a byte every 59 s never times out.

**Error log signatures**

| Client sees | Error log says | Meaning |
| :--- | :--- | :--- |
| 502 | `connect() failed (111: Connection refused)` | Nothing listening on that port (process down) |
| 502 | `upstream prematurely closed connection while reading response header` | Backend accepted, then died or closed without answering |
| 504 | `upstream timed out (110: Connection timed out) while reading response header` | Backend too slow for `proxy_read_timeout` |
| 502 | `no live upstreams while connecting to upstream` | Every server is currently marked unavailable. NGINX didn't even try. `$upstream_addr` shows the group name. |
| *(warn)* | `upstream server temporarily disabled` | `max_fails` reached. The server is out for `fail_timeout`. |

### 1.3 Retries: `proxy_next_upstream`
```nginx
proxy_next_upstream error timeout http_502 http_503;   # default: error timeout
proxy_next_upstream_tries 2;                           # total attempts, 0 = unlimited
proxy_next_upstream_timeout 5s;                        # 0 = unlimited
```

**When a retry is possible**
* NGINX retries on another server only **before any of the response has been sent to the client**.
* `proxy_next_upstream_timeout` is checked **before starting another attempt**. It never cuts the current attempt short. With `proxy_read_timeout 3s` and `proxy_next_upstream_timeout 4s`, a slow pool still takes 6 s to return a 504.
* If every attempt returns 503, the client gets the **last upstream's 503**, not a 502.

**Idempotency rule (since 1.9.13)**
* Requests with a non-idempotent method (`POST`, `LOCK`, `PATCH`) are **not passed to the next server if the request has already been sent** to a backend.
  * A `POST` that hit `Connection refused` **is** retried, because the backend never saw it.
  * A `POST` that the backend received and then dropped **is not** retried. The backend may have acted on it, for example by charging a card.
* `proxy_next_upstream ... non_idempotent;` overrides this. Only use it when the backend deduplicates, for example with idempotency keys.

### 1.4 WebSockets Through a Proxy
**The handshake**
* A WebSocket starts as an HTTP/1.1 `GET` with `Upgrade: websocket` and `Connection: Upgrade`.
* Both are **hop-by-hop** headers, so NGINX doesn't forward them unless told to.
* If the backend answers `101 Switching Protocols`, NGINX turns the connection into a two-way tunnel.

**The configuration**
```nginx
map $http_upgrade $connection_upgrade {   # http {} level
    default upgrade;
    ''      close;
}
location /ws/ {
    proxy_pass http://chat;
    proxy_set_header Upgrade    $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_read_timeout 3600s;             # idle tunnel lifetime
}
```
* The `map` sends `Connection: upgrade` only when the client asked to upgrade, so plain HTTP requests in the same location aren't told to upgrade.
* **1.29.7+ refinement:** the classic `'' close;` sends `Connection: close` on those plain requests, which disables upstream keepalive for them. `'' '';` sends no `Connection` header instead, and reuse keeps working. On the lab box, plain requests through a `close` map always had `conn_requests: 1`; with `''` they climbed 1, 2, 3.
* `proxy_http_version 1.1` is required. It's the default since 1.29.7, but write it explicitly for older builds.
* **`proxy_read_timeout` is the idle limit for the tunnel.** With the default 60 s, a chat with no messages for a minute is closed by NGINX. Use application pings or raise the timeout.

**Reloads**
* A reload starts new workers. The old ones keep serving their open tunnels, shown as `worker process is shutting down`, until those tunnels close or `worker_shutdown_timeout` expires.
* Day 4 shows this cost and how the NGINX Plus API avoids reloads for pool changes.

---

## 2. Lab Setup (5 Minutes)

```bash
cd /srv/nginx-journey/sprints/sprint-2/lab
./mocks.sh start
cp day3_nginx.conf nginx.conf
ngx -t && (ngx -s reload 2>/dev/null || ngx)
r() { curl -s -o /dev/null -w '%{http_code}\n' "$@"; }        # print just the status
last() { tail -n "${1:-1}" logs/access.log; }                 # what NGINX tried
```
The access log format shows every attempt: `up=[servers tried] ust=[status per attempt] urt=[time per attempt] rt=total`.

---

## 3. Hands-on Guided Discovery Activities (35 Minutes)

### Activity 3.1: Failover and Passive Marking (8 min)
Stop a node, then send traffic through the pool without a zone and the pool with one:
```bash
./mocks.sh stop 8001
: > logs/access.log; for i in $(seq 12); do r localhost:8082/api/x; done
grep -o '127.0.0.1:8001' logs/access.log | wc -l          # attempts on the dead node
sleep 6
: > logs/access.log; for i in $(seq 12); do r localhost:8082/apiz/x; done
grep -o '127.0.0.1:8001' logs/access.log | wc -l
grep 'temporarily disabled' logs/error.log | tail -2
./mocks.sh start 8001
```
* All 24 requests return **200**. The retry hides the dead node from clients.
* Those first requests still paid for a failed connect.
* **Without a zone**, 8001 was tried **3** times on the lab box (up to `max_fails` × 2 workers is possible).
* **With a zone**, it was tried exactly **2** times (`max_fails`), and then every worker skipped it.

### Activity 3.2: Timeouts and Retry Budgets (8 min)
`/retry/` uses `retry_pool`, where `max_fails=0`, so these experiments don't mark nodes down. Its `proxy_read_timeout` is 3s.
```bash
r 'localhost:8082/retry/slow?delay=5'; last
```
`504` after **6 s**: `up=[8001, 8002] ust=[504, 504] urt=[3.0, 3.0]`. Both nodes were tried, and each attempt used the full read timeout.

Now add each line below to `location /retry/`, one at a time. Reload and repeat the request each time:

| Added line | Lab result | Why |
| :--- | :--- | :--- |
| `proxy_next_upstream_tries 1;` | 504 after 3 s, one attempt | Retry budget exhausted |
| `proxy_next_upstream_timeout 2s;` | 504 after 3 s, one attempt | 3 s already elapsed > 2 s, so no new attempt |
| `proxy_next_upstream_timeout 4s;` | 504 after **6 s**, two attempts | 3 s < 4 s, so the retry starts and then runs its full 3 s |

*Journal:* what worst-case latency does a client see with `proxy_read_timeout 15s` and 3 tries?

### Activity 3.3: What Gets Retried, and What Mustn't Be (8 min)
Restore `cp day3_nginx.conf nginx.conf && ngx -s reload`, then:
```bash
r 'localhost:8082/retry/x?status=503';               last   # GET, backend answered 503
r -X POST -d a=1 'localhost:8082/retry/x?status=503'; last   # POST, same failure
r 'localhost:8082/retry/x?drop=1';                   last   # GET, backend dropped the connection
r -X POST -d a=1 'localhost:8082/retry/x?drop=1';     last   # POST, same
./mocks.sh stop 8001
for i in 1 2; do r -X POST -d a=1 localhost:8082/retry/p; last; done   # POST, connection refused
./mocks.sh start 8001
```

| Request | Lab result | Retried? |
| :--- | :--- | :--- |
| `GET` + 503 | `ust=[503, 503]`, client gets **503** | Yes |
| `POST` + 503 | `ust=[503]` | **No.** The request was sent. |
| `GET` + dropped | `ust=[502, 502]` | Yes |
| `POST` + dropped | `ust=[502]` | **No.** The backend may have processed it. |
| `POST` + refused | `ust=[502, 200]`, client gets **200** | **Yes.** It never reached a backend. |

### Activity 3.4: Reading the Error Log (4 min)
Make the pool fail completely, then read what NGINX wrote:
```bash
./mocks.sh stop 8001 8002
for i in 1 2 3; do r localhost:8082/api/x; last; done      # third line: up=[api_pool]
./mocks.sh start 8001 8002
grep -oE '\[(error|warn)\].*(refused|prematurely closed|timed out|no live upstreams|temporarily disabled)' logs/error.log \
  | sed -E 's/^\[([a-z]+)\] [0-9#]+: \*[0-9]+ /[\1] /' | sort | uniq -c
```
Match each line to the table in 1.2.
* `up=[api_pool]` means NGINX found no live server and never opened a connection.
* That is a *configuration-state* problem (everything marked down), not a network one.

### Activity 3.5: WebSockets (7 min)
```bash
curl -s -i -N --http1.1 --max-time 2 -H 'Host: lumina.local' \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -H 'Sec-WebSocket-Version: 13' \
  localhost:8082/ws/chat                                   # 101 + Sec-WebSocket-Accept
./ws_client.py ws://localhost:8082/ws/chat hello lumina --idle 8
./ws_client.py ws://localhost:8082/ws/broken hello
tail -2 logs/mock-8003.log
```
* **`/ws/chat`:** `101`, a welcome frame, and echoes. Then, while idle, the tunnel is **closed by NGINX after 5.0 s**: that is `proxy_read_timeout 5s`.
* **`/ws/broken`:** `400`. The backend log shows `Upgrade=None Connection=None`. NGINX didn't forward the hop-by-hop headers.

*Verify the handshake math:* `Sec-WebSocket-Accept` = base64(SHA-1(key + `258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)):
```bash
printf '%s' 'dGhlIHNhbXBsZSBub25jZQ==258EAFA5-E914-47DA-95CA-C5AB0DC85B11' | openssl sha1 -binary | base64
```

---

## 4. Sprint Lab: Build the Lumina Gateway (15 Minutes)

Requirements: [README Section 4](README.md#4-lab-specification-lumina-edge-reverse-proxy--websocket-relay-completed-day-3).
```bash
cd /srv/nginx-journey/sprints/sprint-2/lab
cp starter_nginx.conf nginx.conf        # fill in every TODO using Days 1-3
ngx -t && ngx -s reload
cd .. && ./test_sprint02.sh             # gate: 8/8 core
```
**Hints**
* Use **no URI** on the API `proxy_pass`.
* Put the WebSocket headers in the `/ws/chat` location. Remember Day 1's inheritance rule if you set headers at server level.
* Use `proxy_read_timeout 3600s` for chat.

`lab/solution_nginx.conf` is the reference.

---

## 5. Day 3 Concept Examination (10-Question Randomized Quiz)

👉 **http://&lt;lab-host&gt;:8090/quiz.html?sprint=2&day=3** (serve with `cd /srv/nginx-journey && python3 -m http.server 8090`)

---

## 6. Key Takeaways for Day 3
* **Passive checks need a victim.** A real request must fail before NGINX marks a server down. A `zone` makes that knowledge shared across workers.
* **Read the error log by signature:**
  * `refused`: process down.
  * `prematurely closed`: crashed mid-request.
  * `timed out`: too slow.
  * `no live upstreams`: everything is marked down.
* **Timeouts measure gaps, not totals.** Retries multiply worst-case latency, and `proxy_next_upstream_timeout` only gates *starting* a new attempt.
* **Retries stop once a non-idempotent request has been sent.** A refused `POST` is retried; a received one never is, unless you opt in with `non_idempotent`.
* **WebSockets need explicit `Upgrade`/`Connection` headers, and `proxy_read_timeout` is their idle lifetime.**

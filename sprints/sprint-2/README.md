# Sprint 2: Reverse Proxy & Load Balancing
**Timeline:** Tuesday, Oct 6 – Friday, Oct 9 (4 Business Days)  
**Milestone:** Lumina Multi-Service Gateway (Frontend, Core API & WebSocket Chat Relay)  
**Shape:** 3 OSS days building toward the Lumina lab, then 1 NGINX Plus enterprise day.

---

## 1. Sprint at a Glance

| Day | Date | Theme | Concepts (~15 min) | Lab (~35 min) | Guide |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **1** | Tue Oct 6 | How `proxy_pass` builds the request | Two-connection model, URI mapping rules, header rewriting, `proxy_set_header` inheritance | Predict-then-curl trailing-slash drill, header echo, break inheritance on purpose | [`day_01.md`](day_01.md) |
| **2** | Wed Oct 7 | Upstream pools, balancing & connection reuse | `upstream`, round-robin weights, `least_conn`, `ip_hash`, `hash ... consistent`, `backup`, keepalive pooling | Count distribution, watch `ip_hash` pin to one node, `least_conn` vs slow node, measure connection reuse | [`day_02.md`](day_02.md) |
| **3** | Thu Oct 8 | Failure handling, WebSockets & the sprint lab | Passive health checks, timeouts, 502 vs 504, `proxy_next_upstream` + idempotency, WebSocket upgrade | Kill a node mid-loop, force a 504, watch retries in the log, WebSocket handshake, build Lumina, `test_sprint02.sh` | [`day_03.md`](day_03.md) |
| **4** | Fri Oct 9 | Enterprise: NGINX Plus upstreams | What a reload costs, the OSS control API, what OSS gained (`resolve`, `sticky`, `drain`, `least_time`), Plus API v10, `state` files, `slow_start`, R33+ licensing | OSS: reload with a WebSocket pinning an old worker. Plus: build a pool from empty via the API, scale out, drain, delete, survive a restart. | [`day_04.md`](day_04.md) |

Active health probes (`health_check`, `match`) are deliberately **not** in Day 4. They are covered in Sprint 12 (High Availability).

---

## 2. Lab Environment

All Sprint 2 labs run from `/srv/nginx-journey/sprints/sprint-2/lab` with the `ngx` helper from Sprint 1 Day 1.

| Port | Service |
| :--- | :--- |
| 8080 | Learning dashboard (reserved) |
| 8081 | Sprint 1 lab |
| **8082** | **Sprint 2 lab NGINX** |
| 8001 / 8002 | `api-node-1` / `api-node-2` HTTP echo backends |
| 8003 | `chat-ws` WebSocket echo backend |
| 8004 | `api-node-3` (on demand: `./mocks.sh start 8004`) for backup, hashing, and scale-out labs |
| 8084 / 127.0.0.1:8085 | Day 4 NGINX Plus container: traffic / API and dashboard |

```bash
cd /srv/nginx-journey/sprints/sprint-2/lab
mkdir -p logs temp/{client,proxy,fastcgi,uwsgi,scgi}
./mocks.sh start            # one process per node
./mocks.sh stop 8001        # simulate a crash; ./mocks.sh start 8001 to recover
./mocks.sh logs 8001 8002   # follow backend request logs
```

**What the mock backends give you** (`lab/mock_backend.py`):
* Every HTTP response is a JSON echo of what the backend actually received: `node`, `method`, `path`, `http_version`, `peer` (the address NGINX connected from), `conn_requests` (how many requests this TCP connection has carried), `headers`, `body_bytes`.
* `?delay=2.5` makes the node slow. `?status=503` makes it answer with that status. `?drop=1` closes the connection without answering (a crashing backend). All three work on any path and any method.
* The `path` field is the raw request line, so URI mistakes like `//v1/x` stay visible (Python's server would otherwise normalize them).
* `mock_backend.py --bind 127.0.0.3` listens on another loopback address (Day 4 DNS demo).
* `ws_client.py` is a dependency-free WebSocket client: `./ws_client.py ws://localhost:8082/ws/chat hello --idle 8`.
* `chat-ws` performs a real RFC 6455 handshake. It **rejects** upgrades missing `Upgrade: websocket` or `Connection: Upgrade`, sends a welcome frame, and echoes text frames.

> **Version note (verified on the lab's nginx 1.31.6):** Since **nginx 1.29.7**, upstream `keepalive` is on by default, `proxy_http_version` defaults to `1.1`, and the proxy no longer sends a `Connection` header. Most older guides (and older distro packages) still need the classic three-line keepalive recipe. Day 2 covers both.

---

## 3. Daily Detail

### Day 1: How `proxy_pass` Builds the Request
**Concepts**
* **Two connections, one fresh request.** NGINX terminates the client connection and writes a *new* request to the backend. Nothing crosses automatically; every header the backend sees is a decision.
* **URI mapping rules.**
  * No URI in `proxy_pass` (`http://backend`): the original request URI is passed through unchanged.
  * A URI in `proxy_pass` (`http://backend/`, `http://backend/v2/`): the matched location prefix is replaced by that URI.
  * Regex locations, named locations, and `if` blocks cannot take a URI. Capture and pass it explicitly (`proxy_pass http://backend/$1;`).
  * Variables in `proxy_pass` turn off prefix replacement: you supply the full URI yourself. A variable hostname also needs a `resolver`.
* **Header rewriting.**
  * By default `Host` is set to `$proxy_host` (the upstream name or address), not what the client sent.
  * `X-Real-IP` vs `X-Forwarded-For`: `$proxy_add_x_forwarded_for` *appends* to an incoming chain, so the leftmost entry is client-controlled.
  * `X-Forwarded-Proto` lets frameworks build correct redirect URLs.
* **The inheritance trap, again.** `proxy_set_header` follows the same all-or-nothing rule as `add_header` (Sprint 1 Day 2). One `proxy_set_header` in a location throws away every header set at `server`/`http` level.

**Lab:** single backend on 8001 behind 8082. A trailing-slash drill (predict the backend URI for 8 location/`proxy_pass` pairs, then verify with the echo). Inspect default headers, add forwarding headers, then add one header in a child location and watch the rest vanish.

### Day 2: Upstream Pools, Balancing & Connection Reuse
**Concepts**
* **The `upstream` block** and server parameters: `weight`, `backup`, `down`.
* **Algorithms:**
  * Smooth weighted round-robin (the default).
  * `least_conn` for variable-latency work (LLM streams, reports).
  * `ip_hash`, which hashes the first three IPv4 octets. Everything behind one NAT or `/24` lands on one node.
  * `hash $key consistent`: Ketama consistent hashing, so adding or removing a node remaps about 1/N of keys instead of nearly all.
* **Keepalive pooling.**
  * Why opening a new TCP connection per request burns ephemeral ports and leaves sockets in `TIME_WAIT`.
  * The pool is per worker.
  * What changed in 1.29.7, and the three-line recipe older versions need.

**Lab**
* Send 100 requests and tally which node answered. Change the weights and tally again.
* Enable `ip_hash` from localhost and watch every request land on one node.
* `least_conn` against a `?delay=` node.
* Measure connection reuse with `conn_requests`, then turn it off (`proxy_http_version 1.0`) and count `TIME_WAIT` sockets with `ss`.
* **Trap:** on loopback the kernel reuses ports immediately (`tcp_tw_reuse=2`), so a repeating `peer` port proves nothing about reuse. That is why the mock reports `conn_requests`.

### Day 3: Failure Handling, WebSockets & the Sprint Lab
**Concepts**
* **Passive health:** `max_fails` / `fail_timeout`. A real client request has to fail first.
* **Timeouts:**
  * `proxy_connect_timeout`, `proxy_send_timeout` and `proxy_read_timeout`, and that read/send measure the gap between two reads or writes, not the whole response.
  * 502 (bad or no response) vs 504 (timeout).
* **`proxy_next_upstream`:**
  * Retry conditions, plus `proxy_next_upstream_tries` and `proxy_next_upstream_timeout`.
  * Non-idempotent requests (`POST`, `LOCK`, `PATCH`) are not retried *once the request has been sent* to a backend.
  * A `POST` that hits a refused connection *is* retried, because the backend never saw it.
* **WebSockets:**
  * `Upgrade`/`Connection` are hop-by-hop headers, so the proxy must set them explicitly.
  * The `map $http_upgrade $connection_upgrade` pattern.
  * Why `proxy_read_timeout` decides how long an idle socket survives.

**Lab**
* Stop node 8001 mid-loop and read `$upstream_addr` in the access log.
* Force a 504 with `?delay=`.
* `GET ?status=502` is retried; `POST ?status=502` isn't.
* Complete a WebSocket handshake and exchange frames.
* Build the full Lumina gateway (Section 4) and pass `test_sprint02.sh`.

### Day 4: Enterprise Side Quest: NGINX Plus Upstreams
**Concepts**
* **What a pool change costs in OSS:** an edit plus a reload. Old workers keep serving long-lived connections, so frequent reloads stack up worker generations.
* **The OSS control API** (1.31.5+, `nginx -l`) makes reloads scriptable and observable. It doesn't make pool changes reload-free.
* **What OSS has absorbed:** `resolve`/`service=` (1.27.3), `sticky` and `drain` (1.29.6), keepalive by default (1.29.7), and `least_time` (1.31.0).
* **Still NGINX Plus:**
  * The REST API (**version 10**) to add, modify, drain, and delete servers in shared memory with no reload.
  * `state` files.
  * `slow_start`.
  * Live per-peer metrics, `queue`.
  * Active health checks (Sprint 12).
* **R33+ licensing:** `license.jwt` plus a successful first usage report to `product.connect.nginx.com`. With the default `enforce_initial_report on`, NGINX Plus refuses traffic until that report succeeds.

**Lab**
* **OSS (verified on the lab box):** reload through the control API while a WebSocket holds an old worker open.
* **Plus (written from F5 docs, not yet run here):**
  * Run the registry image with host networking.
  * Build `lumina_api_nodes` from an empty `state` file through the API.
  * Scale out, drain and delete with no reload.
  * Restart and confirm membership persisted.
  * Stretch: `slow_start` on a recovering node.

**Prerequisites:** `license.jwt` from MyF5 (a trial is fine) and Docker on the lab box. The registry login uses the JWT, so `nginx-repo.crt`/`.key` are only needed to build your own image.

---

## 4. Lab Specification: "Lumina Edge Reverse Proxy & WebSocket Relay" (completed Day 3)

Copy `lab/starter_nginx.conf` to `lab/nginx.conf` and configure NGINX on **8082** (`server_name lumina.local`) as the edge for three tiers:

1. **`/healthz`**: answered by NGINX itself with `200` JSON.
2. **Frontend SPA**: `/` serves `lab/html/` with a `try_files` fallback to `/index.html`.
3. **Core API**: `/api/v1/` proxies to upstream `lumina_api_nodes`.
   * Nodes `127.0.0.1:8001` and `127.0.0.1:8002`, `least_conn`, `max_fails=2 fail_timeout=5s`.
   * URI passed through unchanged (`/api/v1/x?y=1` arrives as `/api/v1/x?y=1`).
   * Forward `Host`, `X-Real-IP`, `X-Forwarded-For` (appended chain), and `X-Forwarded-Proto`.
   * `proxy_next_upstream error timeout http_502 http_503;` so a dead 8001 never surfaces to clients.
4. **AI chat WebSocket**: `/ws/chat` proxies to `127.0.0.1:8003`, relays `Upgrade`/`Connection`, and sets `proxy_read_timeout 3600s`.

`lab/solution_nginx.conf` is the reference configuration.

---

## 5. Automated Test Suite (`test_sprint02.sh`)

```bash
cd /srv/nginx-journey/sprints/sprint-2 && ./test_sprint02.sh
```
The suite starts any mock backends that aren't running (and stops them afterward), and targets `http://127.0.0.1:8082` (override with `NGINX_TARGET`).

| # | Core assertion (gate: 8/8) |
| :--- | :--- |
| 1 | `/healthz` returns 200 JSON from NGINX |
| 2 | `/api/v1/` reaches an api node |
| 3 | URI and query string arrive unchanged |
| 4 | Backend sees `Host: lumina.local`, `X-Real-IP`, `X-Forwarded-Proto: http` |
| 5 | `X-Forwarded-For: 203.0.113.9` arrives as `203.0.113.9, 127.0.0.1` |
| 6 | 10 requests reach both nodes |
| 7 | `/ws/chat` returns 101 with the correct `Sec-WebSocket-Accept`, and the welcome frame is relayed |
| 8 | With 8001 **actually stopped**, 10/10 requests still succeed |

**Stretch (reported, not gated):**
* Upstream connections are reused (`conn_requests > 1`).
* `/courses/42` falls back to the SPA.

---

## 6. Daily Quizzes

Every question pool lives in one file, **[`data/quizzes.json`](../../data/quizzes.json)**, organized by sprint and then by day. It will feed the learning dashboard. Each day has 20 questions; the quiz draws 10, and 8/10 passes.

**Mix per 20-question pool:**

| Type (`type` field) | Count | Example |
| :--- | :---: | :--- |
| `scenario`: why / what happens | 8 | Why does `ip_hash` overload one node behind a corporate NAT? |
| `config`: read a config, predict the result | 6 | Given this location and `proxy_pass`, what URI reaches the backend? |
| `diagnose`: symptom or log line to cause | 3 | `upstream prematurely closed connection` and a 502: likely cause? |
| `recall`: direct syntax or command | 3 | Which variable appends to the `X-Forwarded-For` chain? |

**Topics**
* **Day 1:** URI mapping (all forms), the default `Host`, `X-Real-IP` vs XFF trust, `X-Forwarded-Proto`, `proxy_set_header` inheritance, variables in `proxy_pass`.
* **Day 2:** the algorithms and their failure modes, weights and `backup`, consistent hashing, keepalive pooling and `TIME_WAIT`, the 1.29.7 default change.
* **Day 3:** passive health, the three timeouts, 502 vs 504, retry rules and idempotency, WebSocket hop-by-hop headers, `proxy_read_timeout` on idle sockets.
* **Day 4:** `zone`, API operations (add, drain, remove), `slow_start`, `state` files, `resolve` in OSS vs Plus, reload cost vs API changes.

**Take a quiz:** serve the repo over HTTP and open `quiz.html`:
```bash
cd /srv/nginx-journey && python3 -m http.server 8090
# then http://<lab-host>:8090/quiz.html?sprint=2&day=1
```

---

## 7. Optional Side Quests

* **2.1 Keepalive history & `TIME_WAIT`.** Run the classic three-line recipe (`keepalive N` in the upstream, `proxy_http_version 1.1`, `proxy_set_header Connection ""`) against an older nginx container (for example `nginx:1.26`). Show that leaving out any one line silently disables reuse.
* **2.2 RFC 6455 handshake by hand.** Compute `Sec-WebSocket-Accept` yourself (`base64(sha1(key + 258EAFA5-E914-47DA-95CA-C5AB0DC85B11))`) and compare it with the backend's answer. Then send masked frames with `websocat` through `/ws/chat`.
* **2.3 Ephemeral port math.** Use `sysctl net.ipv4.ip_local_port_range` and `net.ipv4.tcp_tw_reuse` to calculate the maximum new-connections-per-second to a single upstream `ip:port` without keepalive. Sprint 4 goes deeper on kernel tuning.

---

## 8. Tracker Sync

* **Platform milestone:** Lumina runs as a true multi-tier architecture. The edge serves the SPA, proxies the API with transparent failover, and relays WebSocket chat.
* **Graduation:** `test_sprint02.sh` 8/8 core, and at least 80% on each day's quiz.

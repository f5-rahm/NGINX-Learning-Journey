# Sprint 2 Recap Notes (working file)
Raw findings and clarifications collected during the sprint, to be shaped into the recap. Everything here was verified on the lab's nginx 1.31.6 unless marked otherwise.

---

## Day 2: Upstream Pools, Balancing & Connection Reuse

### Balancing method syntax
* The method is a bare directive (`least_conn;`, `ip_hash;`, `hash $key [consistent];`, `random [two [method]];`, `least_time header|last_byte [inflight];`), not an attribute with a value. Each method is its own module, and including its directive is what enables it. With none, you get round-robin.
* **Two methods in one upstream: the last one wins**, with only `[warn] load balancing method redefined`. Tested both orders:
  * `least_conn; ip_hash;` behaved like `ip_hash` (40/40 requests to one node from one client).
  * `ip_hash; least_conn;` behaved like `least_conn` (20/20).
  * It's a silent copy-paste hazard, so lint for it or fail CI on warnings.
* Default `weight=1` is implicit and invisible in config and `nginx -T`. The only place it shows explicitly is the NGINX Plus API server objects (`"weight": 1`). BIG-IP shows ratio in config.

### Balancing method redefinition: full test (isolated ports, 2 workers, zone)
Probes per scenario: 10 sequential requests, then 10 fast requests while one node holds a 4 s request.

| Upstream lines | `nginx -t` | Traffic behaved like |
| :--- | :--- | :--- |
| *(none)* | ok | round-robin: `1 2 1 2...`, busy node still got 5/10 |
| `round_robin;` | **`[emerg] unknown directive "round_robin"`**, config rejected | n/a: there is no directive for round-robin; it is only "no method" |
| `round_robin;` + `least_conn;` (either order) | same `emerg`, rejected before ordering matters | n/a |
| `least_conn;` | ok | least_conn: busy node got 0/10 |
| `ip_hash;` then `least_conn;` | `[warn] load balancing method redefined in nginx.conf:8` | **least_conn** (last wins) |
| `least_conn;` then `ip_hash;` | same warn | **ip_hash**: all 10 to one node, even the busy one |
| `least_conn;` twice | same warn, even for the identical method | least_conn |
| `least_conn; random; ip_hash;` | **one warn per redefinition** (lines 8 and 9) | ip_hash |
| `ip_hash;` placed after the `server` lines | ok, no warn | ip_hash (position relative to `server` lines doesn't matter) |

* **Rule: the last method directive wins.** Every earlier one is silently discarded apart from the warn.
* **The warning points at the line of the overriding directive** (the later one), not the original.
* **Where it shows up:** only at config load (`nginx -t`, start, reload), never at runtime. On `nginx -s reload` it appears twice in `error.log`, from two different PIDs: the short-lived `nginx -s reload` process, which parses the config before signaling, and the master, when it re-reads it. It is also printed to the terminal on `-t`/`-s reload`.
* **Nothing hints at it in traffic or the access log.** Only careful testing or the config-load warning reveals which method is active, so fail CI on `[warn]` from `nginx -t`.

### Weight across methods
Test: 8001 `weight=3` vs 8002 default, 400 requests each.

| Method | Result | Role of weight |
| :--- | :--- | :--- |
| round-robin | 300 / 100 | Share (smooth weighted rotation) |
| `least_conn` | 300 / 100 | Compares connections relative to weight. Ties (all idle, sequential traffic) fall back to weighted round-robin. |
| `random` | 293 / 107 | Selection probability |
| `hash $request_uri` | 299 / 101 (400 distinct keys) | Share of the key space |
| `hash ... consistent` | 300 / 100 | More ring points for heavier servers |
| `least_time header` | **400 / 0** | **Not a ratio.** It biases the comparison. With equally fast backends, the heavier server won every request. Equal weights alternated 100/100. |

* `ip_hash` also honors weights, but this can't be measured from a single client address.
* **Lesson:** weight is only a ratio for the methods that don't measure anything. For measured methods (`least_time`, and `least_conn` under concurrency) it scales the comparison. The exact `least_time` formula is unverified; this is observed behavior.

### Methods as modules: feature support is per method
* Round-robin is the base layer. It owns the peer list and per-peer state (`weight`, `down`, `max_fails`/`fail_timeout`, `backup` list). Other methods plug in their own peer selection on top.
* So a feature works only if that method's selection code implements it:
  * Universal: `weight`, `down`, `max_fails`/`fail_timeout`.
  * `backup`: round-robin, `least_conn`, `least_time` accept it. `hash`, `ip_hash`, `random` fail `nginx -t` with `balancing method does not support parameter "backup"`.
  * `slow_start` (Plus): same restriction set. OSS rejects it entirely as `invalid parameter`.
* Layered modules wrap whatever method is configured. Before 1.29.7 the docs required the balancing method to be declared *before* `keepalive`; that ordering rule is moot now that keepalive is on by default.
* Unverified and **not in the docs**: `hash`/`ip_hash` falling back to round-robin after about 20 failed peer attempts (from memory of the source). The `ip_hash` docs only say failed requests pass to the next server until all functioning servers have been tried. Left out of the recap.
* **BIG-IP contrast:** LB method, priority groups, ratio, and OneConnect are independent, freely combinable settings. In NGINX, combinations depend on the method module, so check with `nginx -t`.

### `backup` vs BIG-IP priority groups
* **Binary, not tiered.** No backup-for-a-backup. An upstream with only `backup` servers fails with `no servers in upstream`. There's no minimum-active-members equivalent.
* **Can act per request, not only when the pool is down.** With `max_fails=0` on all servers (never marked down) and both primaries returning 503 (listed in `proxy_next_upstream`), one request went `8001 → 8002 → 8004 (backup)`. The next request went straight back to a primary. A backup is "last resort for this request", not a standby pool switched on by member health.
* For real tiers, chain upstreams: for example `error_page 502 503 = @tier2;` with a second `proxy_pass`.
* Recovery follows `fail_timeout`: right after primaries came back, the backup still took some traffic until the default 10 s elapsed (from the Day 2 lab build).

### `zone` and backup recovery (measured on isolated ports, 3 runs each)
* Sequence: baseline, stop node-1, stop node-2, restart both, wait 11 s. 10 requests per step, 2 workers.
* **No zone:** right after recovery the split varied run to run: 6/4, 8/2, 10/0 between node-2 and the backup. Each worker holds its own failure marks, so the result depends on which worker served which failed request.
* **With zone:** right after recovery, 10/10 went to the backup, every run, until `fail_timeout` expired. Then ~4/6 across the primaries.
* `resolve` fails `nginx -t` without a zone (`resolving names at run time requires upstream ... in shared memory`). `sticky cookie` loads without one.
* Even with a zone, idle keepalive connections stay per worker, because sockets belong to processes.
* BIG-IP lens: passively learned member status in NGINX OSS is per worker unless zoned. Don't assume box-wide status.

### `least_conn` and `least_time` vs BIG-IP methods
* `least_conn` counts connections **carrying a request**. Idle pooled keepalive connections are not counted. In the Day 2 lab, idle pooled connections existed to both nodes, yet `least_conn` with a zone sent 0/20 to the node with one in-flight request.
* **Closest BIG-IP analog:** `least_conn` ≈ **Fastest (application)** (outstanding L7 requests), *not* BIG-IP Least Connections, which counts open server-side connections (inflated by OneConnect's idle pool).
* `least_time` is **passive**. It learns from real responses (`header` = time to headers, `last_byte` = full response, `inflight` includes incomplete requests) combined with active connections and weight. No probes. Loads without a `zone`, but then each worker keeps its own averages (same blind spot as `least_conn` without a zone). OSS since 1.31.0.

### Connection reuse vs BIG-IP OneConnect
Same idea. The nuances:
* **Balancing granularity:** NGINX always balances **per request** and never ties a client connection to a server connection. Keepalive is purely an optimization. On BIG-IP, OneConnect (plus an HTTP profile) is what enables per-request balancing.
* **Reuse scope:** always shared across all clients (the backend only sees NGINX's address), like a `0.0.0.0` source mask.
* **Pool scope:** per worker, per server, and since 1.29.7 per `location` by default (`keepalive 32 local`). OneConnect pools are per TMM.
* **Size:** `keepalive N` caps *idle* connections per worker (LRU eviction). Active connections are capped separately by `max_conns`.
* **Lifecycle knobs** in `upstream` ≈ OneConnect max age / max reuse / idle timeout: `keepalive_time` (1h), `keepalive_requests` (1000), `keepalive_timeout` (60s). Defaults confirmed in the nginx.org upstream docs.
* **NTLM:** the same trap as OneConnect. NGINX Plus `ntlm` pins a server connection to one client connection.
* **Defaults:** before 1.29.7, the NGINX default (HTTP/1.0 + `Connection: close`, no reuse) was the equivalent of running HTTP without OneConnect, which is a misconfiguration by BIG-IP standards. Since 1.29.7, reuse is on with zero config.

---

## Day 3: Failure Handling, Retries & the Sprint Lab

### Retry decision flow
* Flowchart for Activity 3.3: `retry-decision-flow.png` (source `.svg`). Embed it in the Day 3 recap the same way the zone diagram is embedded in Day 2.
* Error log `*N` is the connection serial number. It comes from a counter shared by all workers, and upstream connections seem to use numbers from it too, so the numbers jump (`*3, *8, *11`). Use `grep '\*11 '` to follow one connection.

### Worst-case latency (Activity 3.2 journal) vs BIG-IP 3n+1
* They're not the same concept. 3n+1 is how long it takes to *detect* a down member. NGINX's tries × timeout is how long *one request* can wait.
* Worst case ≈ min(tries, servers) × (connect time + read timeout). NGINX never tries the same server twice, so `tries 3` on the 2-server `retry_pool` is 30 s, not 45 s. A blackholed backend costs `proxy_connect_timeout` (60 s) per attempt. A trickling backend has no upper limit.

### Lab build experience (learner feedback)
* **The starter config gave too much advice.** The TODO comments did too much of the thinking. For future sprint exercises, write TODOs as the requirement only and leave the directives out.
* **The test checked something the requirements didn't ask for.** The README requires only "`/healthz` answered by NGINX itself with `200` JSON". `test_sprint02.sh` also greps for `healthy`, so `{"status": "ok"}` with `application/json` failed. The test or the requirement needs fixing.
* **Personal syntax gotchas:**
  * Missing closing `;`: I missed 5 of them.
  * Time units: time values take a suffix (`proxy_read_timeout 3s`, `fail_timeout=5s`), and a bare number means seconds. Counts must not have one (`max_fails=2`, `proxy_next_upstream_tries 2`, `keepalive 32`).
  * `nginx -t` catches both, but the error points at the line *after* a missing `;`.

### Quiz
* 7/10 first pass, 8/10 on the retake.
* Missed: why NGINX picks 502 vs 504, and WebSocket `Upgrade` (the request header) vs `101 Switching Protocols` (the response status).

---

## Findings From Building the Sprint (all days)
* **1.29.7 defaults change:** upstream `keepalive 32 local` on, `proxy_http_version 1.1`, no `Connection` header sent. The classic three-line recipe is only needed on older builds.
* **`TIME_WAIT` lands on whoever closes first.** 200 non-reused HTTP/1.0 requests added 200 `TIME_WAIT` sockets on the *backend* side and 0 on NGINX.
* **Loopback port reuse:** `tcp_tw_reuse=2` makes peer ports repeat immediately, so ports can't prove connection reuse. Use the mock's `conn_requests`.
* **The WebSocket `map` with `'' close`** sends `Connection: close` on ordinary requests in that location, defeating keepalive on 1.29.7+. `'' ''` keeps reuse working (`conn_requests` 1, 2, 3).
* **`proxy_next_upstream_timeout`** is only checked before starting a new attempt. With a 3 s read timeout and a 4 s budget, a slow pool still took 6 s to return a 504.
* **Idempotency is about whether the request was sent:** a refused `POST` is retried, while a `POST` that was received and then dropped is not.
* **Without a `zone`, failure accounting is per worker:** a dead node was tried 3 times with 2 workers vs exactly `max_fails` (2) with a zone.
* **OSS gains:**
  * `resolve`/`service=` (1.27.3)
  * `sticky` and `drain` (1.29.6)
  * `least_time` (1.31.0)
  * control API (1.31.5)
* **Still Plus:** the write API, `state`, `slow_start`, live per-peer metrics, `queue`, `ntlm`, active health checks.
* **NGINX Plus API is version 10** (not 8). R33+ licensing gates traffic on the first usage report by default (`enforce_initial_report on`).
* **Python's `http.server` collapses a leading `//`**, which hid `proxy_pass` slash bugs until the mock echoed the raw request line.

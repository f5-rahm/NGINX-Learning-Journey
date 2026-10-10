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
* **The test checked something the requirements didn't ask for.** The README requires only "`/healthz` answered by NGINX itself with `200` JSON". `test_sprint02.sh` also greps for `healthy`, so `{"status": "ok"}` with `application/json` failed. **Fixed:** the README spec, the test table, and the starter TODO now require `"status": "healthy"`. The test parses the JSON and checks that field instead of grepping, so `unhealthy` no longer passes.
* **Personal syntax gotchas:**
  * Missing closing `;`: I missed 5 of them.
  * Time units: time values take a suffix (`proxy_read_timeout 3s`, `fail_timeout=5s`), and a bare number means seconds. Counts must not have one (`max_fails=2`, `proxy_next_upstream_tries 2`, `keepalive 32`).
  * `nginx -t` catches both, but the error points at the line *after* a missing `;`.

### Quiz
* 7/10 first pass, 8/10 on the retake.
* Missed: why NGINX picks 502 vs 504, and WebSocket `Upgrade` (the request header) vs `101 Switching Protocols` (the response status).

---

## Day 4: NGINX Plus Upstreams (Enterprise Side Quest)

### The OSS control socket (verified on an isolated 1.31.6 instance)
* `nginx -l unix:/path/control.sock` makes the **master** open one extra Unix socket that serves a small JSON API: `/1/nginx` (version), `/1/control/processes` (workers only, with `exiting`), `/1/control/config` (GET returns the config files, PATCH reloads).
* **Nothing changes in the traffic path.** Same workers, same listeners, no TCP port. The socket is `srw------- root`, so it's local-only and root-only.
* `-l` is a **command-line flag, not a directive.** It applies only to that run, which is why the lab restarts NGINX instead of reloading. The socket survives reloads (the master holds it) and is removed on quit.
* **A PATCH reload does the same thing as `nginx -s reload`.** The difference is the feedback: `{"logs":[]}` on success, or the `emerg` text in the response on failure, while the old config keeps serving. `-s reload` only sends a signal, and you have to read `error.log` to find out what happened.
* BIG-IP lens: a tiny local iControl that can show processes and do `tmsh load sys config`. It can't change pool members.

### Activity 3.1 findings
* **A reload retires every old worker**, not just one. All of them show `"exiting": true`. Workers with no connections exit right away (`ps` briefly shows `[nginx]` until the master reaps them). Only the worker holding the WebSocket stays, as `worker process is shutting down`.
* **OSS `drain` works with or without a `zone`.** Isolated test with 30 requests: 3 servers 11/10/9, 9004 `drain` without a zone 16/14/0, with a zone 15/15/0.
* **Duplicate `server` lines are separate servers, and NGINX doesn't warn.** Running the "add 8004" `sed` a second time left a `drain` line *and* a plain 8004 line. The plain one kept taking traffic (11/10/9), so the drain did nothing. BIG-IP won't let you add the same member to a pool twice.
* **One request slipped through right after the drain reload.** On the lab gateway, the 3rd of 20 requests (about 20 ms after `PATCH` returned) still went to the drained 8004, and the rest skipped it. Likely cause: old workers briefly accepting connections before they close their listeners. It didn't reproduce on an isolated instance (0/20 in 5 runs), so it's unconfirmed. The guide now waits 1 s before checking.
* Guide fixes made during testing: the "one worker exiting" comment was wrong, the activity never checked that 8004 took traffic (`otally` added), and the drain step now edits the existing line instead of adding one.

### Quiz
* 10/10 on the first attempt.

### Scope: what Day 4 deliberately leaves out
* **Active health checks** (`health_check`, `match`) are not an oversight. They're the Enterprise Side Quest for **Sprint 12** (High Availability). Day 4 is about changing a pool; Sprint 12 is about probing it. That's where BIG-IP monitor habits (interval, send/receive strings, mark down before users notice) map most directly.
* **`slow_start` ties the two together.** Activity 3.7's gradual climb was triggered by `fail_timeout` expiring after a passive failure. With active checks, the same ramp starts when a probe marks an unhealthy server healthy again.
* **NGINX One Console** (fleet inventory, config drift, CVE and certificate status, central config, through the NGINX Agent) is in the **Sprint 11** side quest, next to the single-instance dashboard. It's the closest analog to BIG-IQ.

### Plus setup findings
* **Image tags changed naming in R37.** `r37-debian` doesn't exist, which first made it look like R36 (`r36-debian`) was the newest release. R37 tags carry a point release: `r37.0-debian`, `r37.1-debian`, alias `nginx-plus-r37.1-debian`, and no plain `r37`. The registry's `/v2/nginx-plus/base/tags/list` lists what a license can pull (basic auth with the JWT as the username, `none` as the password). A filter for `^r[0-9]+-` silently hides every R37 tag.
* **Floating tags** (`debian`, `nginx-plus`, `nginx-plus-20260821`) all pointed at R37.1 (`nginx/1.31.3 (nginx-plus-r37.1.1)`), the same digest as `r37.1-debian`. A floating tag jumps to the next release on the next pull, so the lab pins `r37.1-debian`. `nginx-plus/agent` is Plus plus the NGINX Agent (for NGINX One / Instance Manager), which the lab doesn't need.
* **The lab moved from R36 to R37.1 mid-day.** R37.1 is built on OSS 1.31.3, so it does have the 1.29.7 keepalive defaults, and it serves API versions 1 to 10. The instance kept the same licensing `uuid` across the R36 → R37 swap, because Plus stores it in the mounted `plus/state` directory. `/license` gained a `pending_renewal` field.
* **The first container start failed:** `pread() "/etc/nginx/license.jwt" failed (21: Is a directory)`, then `License file is required`. `$HOME` was empty in that shell, so the `-v` source was `/plus/license.jwt`, and Docker silently created it as a directory. The guide now uses `--mount type=bind`, which refuses to start when the source path doesn't exist.
* **R36 was `nginx/1.29.3 (nginx-plus-r36-p8)`**, which predates the 1.29.7 keepalive and HTTP/1.1 upstream defaults. R37.1 (1.31.3) has them.
* **A successful usage report is silent in the logs.** Only `/api/<v>/license` confirms it: `reporting.healthy: true`, `fails: 0`. The trial showed `eval: true`, `active_till` (Unix time; Oct 20, 2026 here), and `grace` of 15552000 s (180 days).
* **Container log noise is harmless:** `40-env-to-license.sh: NGINX_LICENSE_JWT ... not set` (the image can also take the license as an environment variable; we mount the file), the `default.conf differs` notice (our config doesn't include `conf.d/`), and supervisord's `CRIT ... without any HTTP authentication` about its own internal socket. Every line appears twice because supervisord logs to two places.
* `docker login` warnings: `--password` on the CLI is harmless (the password is literally `none`; the secret is the JWT username). The token is stored base64-encoded in `/root/.docker/config.json`, which is `600` root, the same protection as `~/plus/license.jwt`. Optionally run `docker logout` after pulling.

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
* **NGINX Plus API version:** R37 serves 1 to 10 (matching the nginx.org docs). R36 served only 1 to 9, and `/api/10/` returned `404 UnknownVersion` there. Ask `GET /api/` instead of hard-coding. R33+ licensing gates traffic on the first usage report by default (`enforce_initial_report on`).
* **Python's `http.server` collapses a leading `//`**, which hid `proxy_pass` slash bugs until the mock echoed the raw request line.

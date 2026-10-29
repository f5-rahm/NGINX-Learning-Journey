# Sprint 5 Recap Notes (working file)
Raw findings and clarifications collected during the sprint, to be shaped into the recap. Everything here was verified on nginx 1.31.6 in the `nginx:mainline` container, with clients sending from their own addresses on the lab network, unless marked otherwise.

---

## Findings From Building the Sprint

### Rate limiting (Day 1)
* **No burst means no tolerance at all.** With `rate=10r/s` and no `burst`, 20 simultaneous requests gave 1 × 200 and 19 rejections. Paced at 8/s, all passed. Paced at **12/s, half were rejected** (`200 503 200 503 ...`), not the 1 in 6 you'd expect from "20% over". The rate is enforced per request as a minimum gap (100 ms here); a request 83 ms after the last one is early, whatever the average.
* `burst=5` at 12/s: 30 of 30 passed. The burst absorbs jitter as well as spikes.
* **The default rejection is 503,** logged at `error` (`limiting requests, excess: 1.000 by zone "api"`). `limit_req_status 429` changes it.
* **Queue vs `nodelay`,** 20 at once with `burst=5`:
  * Without `nodelay`: 1 answered at once, then 1 every 100 ms up to 0.5 s, and 14 rejected immediately. The queue makes clients wait; it doesn't make them fail.
  * With `nodelay`: 6 answered at once, 14 rejected. The burst slots still refill at the rate: right after a 6-request burst, pacing at 12/s got 3 rejections in 20.
  * `burst=8 delay=3`: 4 at once (1 + 3), 5 more spaced 100 ms apart, 11 rejected.
* **`limit_req_dry_run on`:** every request passed (status 200), logged `REJECTED_DRY_RUN` in `$limit_req_status`, and `limiting requests, dry run` in the error log.
* **An empty key is never limited:** `limit_req_zone $http_x_api_key ...`, requests with no `X-Api-Key`: 10 of 10 passed. With a key: 1 of 10.
* **Inheritance:** a `limit_req` at `server` level applied to a location without its own. A location with its own `limit_req` **dropped** the server-level one (the add_header rule again).
* **Stacking:** two `limit_req` in one location both apply. A per-IP limit with `burst=50` plus a `$server_name` limit at `20r/s burst=5`: across three clients at once, 6 passed in total.
* **`return` beats `limit_req`:** a location with `return 200` passed 10 of 10. `return` runs in the rewrite phase, before PREACCESS.
* **`rate=6r/m burst=4 nodelay`:** 5 of 8 passed at once; after 10.5 s exactly one more.
* **`Retry-After` only on rejections:** `map $limit_req_status $retry_after { REJECTED 1; default ""; }` + `add_header Retry-After $retry_after always;` → 429s carry `Retry-After: 1`, 200s carry nothing (an empty value isn't sent).
* **A zone that is too small forgets clients silently.** `zone=tiny:32k rate=1r/m`, 600 distinct clients: all 600 got their first request. The first five clients, asked again, were **allowed again** (their state had been evicted); the last five were rejected. Nothing in the error log. An attacker with many addresses gets the same effect.

### Concurrency, bandwidth and slow clients (Day 2)
* **`limit_conn` counts requests in progress, not TCP connections.** HTTP/2: 5 streams on **one** TCP connection with `limit_conn 2` → 2 × 200, 3 × rejected.
* `limit_conn` with a `$server_name` key caps the whole server: 3 in total across three clients.
* **A slow-header client is not counted by `limit_conn`** (the request isn't "being processed" until its header is read). A **slow-body** client is: with `limit_conn 1`, a normal request from the same address got 503 while its slow upload was in progress.
* **`client_header_timeout` is a total:** a header line every 2 s, timeout 5 s → closed at 5.0 s. The default (60 s) let a slowloris client hold the connection for 60 s. Logged `408`, and **no response is sent**.
* **`client_body_timeout` is between reads:** one byte every 4 s with a 3 s timeout → closed at 3.0 s (`408`), but one byte every 2 s kept the upload alive indefinitely.
* **`client_max_body_size` (default 1m)** rejects up front from `Content-Length`: `413`, `client intended to send too large body: 2000000 bytes`. A 500 KB body was accepted and buffered to a temp file (`[warn] a client request body is buffered to a temporary file`).
* **`limit_rate 200k`:** a 1 MB download took 4.8 s. `limit_rate_after 500k` → 2.2 s; a 400 KB download wasn't slowed at all. `limit_rate $var` from a `map` gave the partner network full speed (1 MB in 0.00 s).
* **`limit_rate` is per connection:** 4 parallel downloads from one client each took 4.8 s, so 4× the bandwidth. With `limit_conn 1`, 3 were rejected and one downloaded.

### Access control and real client addresses (Day 3)
* **PREACCESS runs before ACCESS:** `deny 10.55.66.0/24` + `limit_req burst=5 nodelay` in one location, 20 requests from the denied network → **6 × 403 and 14 × 429**. A blocked client that floods gets "slow down" instead of "go away", and uses limit state. Rejecting in the rewrite phase (`if ($tier = blocked) { return 403; }`) gave 20 × 403.
* `allow`/`deny` are checked in order, first match wins: `deny all; allow 10.55.10.0/24;` refused the office too.
* **Exemption by empty key:** `geo` → tier, `map $tier $limit_key { partner ""; office ""; default $binary_remote_addr; }`: partner and office 20 of 20, internet 6 of 20.
* **Without realip trust, everyone behind the load balancer shares one bucket:** two different clients forwarded by one LB address, 6 requests each: 6 × 200 and 6 × 429.
* With `set_real_ip_from <LB>; real_ip_header X-Forwarded-For;` each forwarded client had its own bucket, and **`geo` saw the real client** (a partner address behind the LB got the partner tier, 20 of 20).
* **Spoofing from outside the trusted range doesn't work:** a direct client rotating `X-Forwarded-For` values was still limited as itself.
* `real_ip_recursive on` with `X-Forwarded-For: 10.55.20.1, 10.55.100.70` from the LB → `10.55.100.70` (the rightmost untrusted address), so a forged prefix can't claim the partner tier.
* **The client's `X-Forwarded-For` reaches the origin unchanged** unless the gateway sets it. The origin saw whatever the client sent.

### Lab tooling
* **Python's `ThreadingHTTPServer` listens with a backlog of 5** unless `request_queue_size` is a class attribute: setting it on the instance after construction is too late (the constructor already called `listen()`). Bursts of 30 right after a reload (no idle upstream connections yet) overflowed the origin's accept queue (`TcpExtListenOverflows 14`), and 2–3 requests took 1.0 s, a SYN retry, logged as `$upstream_connect_time` 1.02. **Sprint 4's `origin.py` has the same latent bug** (`server.request_queue_size = 128` after the constructor).

### Side quest (NGINX Plus R37.1.1, API version 10, two nodes on the lab network)
* **Both nodes use the same config file.** Each lists both addresses in `zone_sync_server`. A node that connects to itself logs `detected local connection id, closing` and `node is offline: ignore self`, so listing yourself is harmless. Each node reports `nodes_online: 1` (its peer).
* **Denylist without a reload:** `POST {"10.55.66.0/24":"1"}` to a `type=ip` keyval zone blocked the whole range (`403` for `.6` and `.200`, `200` for others). The API's `generation` stayed `1` and `load_timestamp` didn't change.
* **A single-address key blocks just that address:** with only `10.55.66.6` in the zone, `.6` got 403 and `.7` got 200. (Which value wins when a range and an address inside it are both present wasn't tested.)
* **Sync is eventually consistent, on the 1 s `zone_sync_interval`.** An entry added on B wasn't on A 0.3 s later; it was there 2 s later. A→B looked faster only by luck of timing.
* **Deleting a key doesn't sync.** `PATCH {"key": null}` on A removed it on A; B kept it (checked for 15 s; it would stay until the zone's `timeout=1h`). **Updates do sync:** setting the value to `"0"` on A reached B, and both then allowed the range (`if ($denied)` treats `"0"` as false). So in a synced denylist, unblock by setting `0`, not by deleting.
* **A restarted node gets the zone back from its peer** (`zone "denylist" done while sending snapshots`). Restarting both nodes lost it (no `state=` file). Production: a `state` file, or a controller that re-pushes the list.
* **Limits:**
  * `/legacy/` (a per-node zone, `rate=2r/s burst=2 nodelay`): 40 requests at 4/s alternating between the nodes → **40 of 40 passed**. Each node saw 2/s, so the cluster allowed twice the limit.
  * `/api/` (the same zone with `sync`): 22 passed, 18 rejected, with the rejections in clumps (the sync lag). One node alone at 4/s: 12 of 20.
  * **A simultaneous burst still gets each node's burst:** 10 requests to each node at the same instant passed 6 + 6 with or without `sync`. Sync bounds sustained rates, not instant spikes.
* `/api/10/http/limit_reqs` gives `passed`, `delayed`, `rejected` and the two dry-run counters per zone, per node. (There's also `/http/limit_conns`.) The counters are per node even for a synced zone.
* `$HOME` was empty in this non-login shell again; `--mount` refused (`bind source path does not exist: /plus/license.jwt`), as designed.
* **Why the Plus nodes join the lab network** instead of `--network host` (the usual convention): rate limits key on the client's address, and the cluster demo needs two nodes on the same ports with one config. The API is published on the host's loopback (`127.0.0.1:8085` for A, `127.0.0.1:8098` for B) and allows only the network's gateway address (the host).

### More from rehearsing the guides
* **Changing a zone's key on reload is refused by the master, silently from the outside.** `limit_req_zone $client_key zone=api ...` after `$binary_remote_addr`: `nginx -t` passed, `nginx -s reload` exited 0, and the error log had `[emerg] limit_req "api" uses the "$client_key" key while previously it used the "$binary_remote_addr" key`. The old config kept running. Changing the zone's size or rate reloaded fine. `lab.sh reload` now checks the error log for an `[emerg]` from the reload and reports it.
* **`$server_name` is empty when the `server` block has no `server_name`.** `limit_conn_zone $server_name zone=origin:1m; limit_conn origin 3;` let 6 requests reach the origin at once. Adding `server_name lumina;` made the cap work (3 in flight).
* **The queue paces a sequential client.** `burst=5` (no `nodelay`), 60 requests at 12/s, each sent after the previous answer: 60 of 60, because the queue slowed the client to 10/s. With `nodelay`: the first 30 passed, then exactly 1 in 6 was rejected (`200 x 55, 503 x 5`).
* **`real_ip_recursive` only matters when a trusted address is inside the header.** `X-Forwarded-For: 10.55.100.70, 10.55.0.5` from the LB: without `recursive` the client became `10.55.0.5` (the LB itself); with it, `10.55.100.70`. A forged left-end address (`10.55.20.1, 10.55.100.70`) was ignored either way.
* **A slow-header request isn't even rate limited:** it was logged `408 req=- conn=-`. A slow-body request logged `408 req=PASSED conn=PASSED`.
* **The origin had 0 requests in flight during a slow upload** (`proxy_request_buffering` on by default).
* **A `limit_conn` zone counts per key across locations.** With `per_client` used as `limit_conn per_client 2` in `/api/` and `limit_conn per_client 1` in `/downloads/`, one slow API request in progress made a download `429`, and a download in progress let only one of two API requests through. Each line only sets the maximum it compares the shared count with. Independent limits need separate zones (the Day 2 guide and `day3_nginx.conf` were fixed to use a `downloads` zone).

## Day 1

### Day 1: Must include in day01_recap.md (user request)
* "`burst` turns the strict gap of Activity 3.2 into a tolerance, and `nodelay` decides whether the requests inside the tolerance wait." (from the end of Activity 3.3). For LinkedIn readers, "the strict gap of Activity 3.2" is the rule that, with no burst, any request arriving sooner than 1/rate after the last one is rejected.

### Day 1: Why is it `limit_req_zone` but just `burst`?
* **Two levels of naming.** Directives are namespaced by module (`ngx_http_limit_req_module` gives `limit_req_zone`, `limit_req`, `limit_req_status`, `limit_req_log_level`, `limit_req_dry_run`). `burst`, `nodelay` and `delay` are not directives. They are parameters of one `limit_req` line, so they are already scoped to it. Blocks (`http`, `server`, `location`, `upstream`, `map`, `geo`) exist only where a module needs a scope of its own.
* **Define then attach.** `limit_req_zone` (http level) defines the shared counter; `limit_req` attaches it where it applies. This is the BIG-IP split between a profile and the virtual server that uses it.
* **Structured front ends exist.** F5 NGINX Ingress Controller's `Policy` CRD has a `rateLimit` object (`rate`, `key`, `zoneSize`, `burst`, `noDelay`, `rejectCode`) that generates these lines (Sprint 8 side quest). Outside Kubernetes: crossplane parses nginx.conf to JSON and back, and Ansible/Jinja2, Puppet or NixOS modules build it from structured data. None replaces reading `nginx -T`: errors and behavior are always reported in raw-directive terms. AS3 → tmsh is the BIG-IP analog.

### Day 1: Why `503` and not `429` by default?
* **`429` didn't exist yet.** `limit_req` arrived in nginx 0.7.21 (2008); `429 Too Many Requests` was defined by RFC 6585 in 2012. `limit_req_status` and `limit_conn_status` came in 1.3.15 (2013), and the default stayed `503` so existing configs and monitoring behaved the same after an upgrade. (From the docs and changelog, not tested in the lab.)
* **The module was built as load shedding.** `503` means "the server is overloaded, try later", seen from the server. `429` means "you sent too much", seen from the client. The default matches the first idea, the per-client use case matches the second.
* **NGINX rarely changes defaults, but it does sometimes.** Upstream keepalive off, no `Retry-After` and `server_tokens on` have stayed the same for compatibility. Counterexample: 1.23.4 (2023) dropped TLSv1 and TLSv1.1 from the default `ssl_protocols`, so a server that never set it stopped offering them after an upgrade.
* **BIG-IP practice applies to NGINX too (user correction).** BIG-IP defaults do change between versions, so the field rule is to build custom profiles with explicit values instead of relying on the parent defaults; the user has seen customer upgrades fail without it. In NGINX: set explicitly any value your behavior depends on (`limit_req_status`, `ssl_protocols`, timeouts, buffer sizes), read the changelog's "Change:" entries before an upgrade, and diff `nginx -T` before and after. NGINX has no parent profile, so the default lives only in the binary.

### Day 1: NGINX Ingress Controller CRDs and crossplane
* **NIC configures only the NGINX inside its own pods.** It can't manage a standalone NGINX. Inside the cluster, CRDs (`VirtualServer`, `VirtualServerRoute`, `TransportServer`, `Policy`, `GlobalConfiguration`) and ConfigMap keys cover the common features. Everything else goes through snippets (raw NGINX text, off unless `-enable-snippets` is set) or custom templates. The controller regenerates nginx.conf, so hand edits in the pod are lost.
* **crossplane (tested with Python 0.5.8 on the solution config):** `crossplane parse` turns a config into JSON (`directive`, `line`, `args`, `block`), and `crossplane build` turns JSON back into a config. A script changed every `burst=` and rebuilt the file. It is structural, not semantic: `burst=20` is just the string `"burst=20"` in `args`, so the nesting the user wanted isn't there. It follows `include`, so a missing `/etc/nginx/mime.types` made the whole parse `failed` (`--single-file` skips includes). The last PyPI release is 0.5.8 (2022); the repo is not archived. F5's tooling uses the Go port, `nginx-go-crossplane`, which is more active.

### Day 1: Burst timeline measured for the recap diagram (nginx 1.31.6)
* Separate zones at `rate=10r/s`, one client sending 8 at once and 4 more at 350 ms, with raw sockets fired in a tight loop (threads spread a "burst" over ~80 ms and blur the result). Three runs, identical:
  * no burst: 1 + 1 answered, 7 + 3 rejected;
  * `burst=5`: 1 at once, 5 queued and answered at 100…500 ms, 2 rejected; the second wave gets 3 queued (answered at 600, 700, 800 ms) and 1 rejected;
  * `burst=5 nodelay`: 6 + 3 answered at once, 2 + 1 rejected. The same 9 as the queue, none waiting.
* **A queued request waits excess × gap.** The bucket is at 1.5 at 350 ms, so the new arrivals sit at 2.5, 3.5 and 4.5, which is 250, 350 and 450 ms after 350.
* **A second wave at exactly 300 ms is a knife edge:** 2 or 3 got through depending on sub-millisecond jitter, because the bucket has drained exactly 3 slots at that moment. The diagram uses 350 ms.
* Diagram: `burst-and-nodelay.svg` / `.png` (rendered like Sprint 4's kernel-limits: rsvg-convert in alpine:3.22, Lato from google/fonts).

### Day 1: Lab and quiz
* Quiz 6/10, then 9/10. All four misses were queue timing and rejections: when a queued request is answered, and when the bucket has room again.

### Day 1: Guide fix
* 1.1 and 1.2 now say `burst`, `nodelay` and `delay` are parameters on the `limit_req` line, not directives and not zone settings (the user's question above).

## Day 2

### Day 2: How can the timeouts be "like TCP profile settings" when the TCP stack is the kernel's?
* **A BIG-IP TCP profile holds two kinds of setting**, because TMOS has its own stack: how TCP behaves (congestion control, Nagle, buffers, window, SACK, keepalive probes) and when to give up on a connection (idle timeout, zero-window timeout).
* **On NGINX they live in different places.** TCP behavior is the kernel's: sysctls, plus socket options NGINX sets on `listen` (`backlog=`, `rcvbuf=`/`sndbuf=`, `so_keepalive=`, `fastopen=`, `deferred`) and `tcp_nodelay`/`tcp_nopush`. When to give up is NGINX's: `client_header_timeout`, `client_body_timeout`, `send_timeout`, `keepalive_timeout`. Day 2's settings are all in the second group.
* **The timers are in NGINX's event loop.** Each wait for a socket to become readable or writable gets a timer; if the timer fires first, NGINX closes the socket. The kernel only ACKs, retransmits and buffers bytes. It doesn't know what an HTTP header is or when one is complete, so "the whole header within 5 s" can only be NGINX's rule (and is why `limit_conn` doesn't see slowloris).
* **Kernel TCP keepalive doesn't help against slow clients.** `so_keepalive` probes find dead peers; a slowloris client is alive and answers them.
* **Guide fix:** the Day 2 theme now says "the idle and slow-client timeouts in the TCP and HTTP profiles. On NGINX the TCP stack is the kernel's, but those timeouts are NGINX's own timers."

### Day 2: From the 1.5 table to a lasting policy
* **The 1.5 table reads as whack-a-mole** (user observation): one abuse, one directive. A lasting design starts from the other side: every request goes through phases, and each phase has dimensions that must all be bounded, whether or not anyone has attacked them yet.

  | Phase | Time | Size | Count / rate |
  | :--- | :--- | :--- | :--- |
  | Connection idle | `keepalive_timeout` | n/a | `keepalive_requests`, `worker_connections` |
  | Request header | `client_header_timeout` (total) | `large_client_header_buffers` | `limit_req` |
  | Request body | `client_body_timeout` (gap) | `client_max_body_size` | `limit_conn` |
  | Processing | `proxy_read_timeout` (Sprint 2) | n/a | `limit_conn`, `$server_name` cap, `max_conns` |
  | Response | `send_timeout` (gap) | n/a | `limit_rate` (+ `limit_conn`) |

* **Layer 1, a baseline at `http` level that applies to everything.** Explicit values (the Day 1 rule: don't rely on defaults), tighter than the defaults where the defaults are generous (`client_header_timeout 60s` is). A generous per-client `limit_conn` as a backstop. This is the custom parent profile.
* **Layer 2, one profile per traffic class, not per incident.** API, static, uploads, downloads, admin. Each class loosens or tightens the baseline where its legitimate traffic differs (uploads: large body, longer body timeout, few in progress per client; downloads: `limit_rate_after` + `limit_rate`, `limit_conn` in its own zone). One `include` file per class, included by every location of that class, plays the role of a BIG-IP custom profile attached to many virtual servers.
* **Layer 3, per-client tiers** (Day 3): `geo`/`map` turn the client into a tier and the tier into values (key, rate), so partners and offices change in one place.
* **The numbers come from two budgets, not from the last attack.**
  * **Capacity, from the top:** what the gateway (`worker_connections`, file descriptors, Sprint 4 Day 3) and the origin (its real concurrency) can hold. That sets the server-wide caps (`$server_name` `limit_conn`, `max_conns`).
  * **Legitimate behavior, from the bottom:** the p99 of real clients from the access log (rate, requests in progress, body size, upload duration), times a margin of 2–3×. That sets the per-client limits. If a per-client limit would sit below the p99, the class is wrong or the key is wrong (NAT, the load balancer: Day 3).
  * Timeouts are set by the slowest legitimate client you want to serve (a bad mobile network), not the fastest attack.
* **Roll out like a profile change:** dry run first (`limit_req_dry_run`/`limit_conn_dry_run`, with `$limit_req_status`/`$limit_conn_status` in the log), then enforce, then review rejection rates as a metric. A new abuse then adjusts one class's values, not the design.
* (Design guidance; the starting numbers above weren't measured in the lab.)
* Infographic: `limits-policy.svg` / `.png` (generated from a script, rendered like `burst-and-nodelay`: rsvg-convert in alpine:3.22, Lato from google/fonts).

### Day 2: How the `Retry-After` map works (Activity 3.1)
* **`map` takes one input string.** For each request it builds the source string, takes the first matching pattern, and falls back to `default`. It's evaluated lazily, when `add_header` reads `$retry_after` for the response, so both limit checks have run by then. A plain pattern must equal the whole string; a `~` pattern is a regex and, unanchored, matches anywhere.
* **There's no "OR" across two variables, so you concatenate them.** `$limit_req_status$limit_conn_status` joins the two values with nothing in between. From the user's own access log (`req=` / `conn=`; `-` in the log is an empty value):

  | Log line | String the map sees | `Retry-After` |
  | :--- | :--- | :--- |
  | `/api/slow 200 req=PASSED conn=PASSED` | `PASSEDPASSED` | none (`default ""`) |
  | `/api/slow 429 req=PASSED conn=REJECTED` | `PASSEDREJECTED` | `1` |
  | `/tiny/ 429 req=REJECTED conn=-` | `REJECTED` (`limit_conn` never ran) | `1` |
  | `/_stats 200 req=- conn=-` | empty | none |

* **Unanchored `~REJECTED` also matches dry run** (tested on nginx:mainline, port 8088, `limit_req_dry_run on`): the dry-run "rejections" were served `200` **with** `Retry-After: 1`. `~REJECTED$` fixes it: no header under dry run, and a real `503` still got `Retry-After: 1`. It also still matches `PASSEDREJECTED` and `REJECTED`. (My first answer in chat stated this confusingly; this is the tested version. The guide keeps `~REJECTED`, since its labs never combine dry run with the map.)

### Day 2: Lab and quiz
* Lab went smoothly. Quiz 10/10 on the first attempt.
* User's takeaway: none of it was hard on its own, but the number of settings and the nuances of each is hard to keep together. That's the reason for the phase grid in the policy infographic.

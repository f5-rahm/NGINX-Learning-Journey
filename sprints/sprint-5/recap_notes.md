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

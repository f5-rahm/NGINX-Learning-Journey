# Sprint 4 Recap Notes (working file)
Raw findings and clarifications collected during the sprint, to be shaped into the recap. Everything here was verified on nginx 1.31.6 in the `nginx:mainline` container, against `lab/origin.py`, unless marked otherwise.

---

## Findings From Building the Sprint

### Caching (Day 1)
* **No lifetime, no cache.** With `proxy_cache` on and no `proxy_cache_valid`, a response with only `ETag` and `Last-Modified` was `MISS` every time. `Cache-Control: max-age` or `Expires` from the origin made it a `HIT`.
* **Precedence, as observed:**
  * `X-Accel-Expires: 0` beat `Cache-Control: max-age=60` (not cached).
  * `X-Accel-Expires: 60` beat `Cache-Control: no-store` (cached).
  * `Cache-Control: max-age=1` beat `Expires` +60 s, and `max-age=60` beat `Expires` +1 s.
  * `s-maxage=60,max-age=0` was cached.
  * Never cached: `no-store`, `no-cache`, `private`, `max-age=0`, `Set-Cookie`, `Vary: *`.
* **A 503 with `Cache-Control: max-age=60` was cached** and served as a `HIT`, although `proxy_cache_valid` only listed 200. A 404 or 503 without caching headers wasn't cached.
* **Lifetimes have whole-second granularity.** `max-age=2` was still a `HIT` after 2.2 s and `EXPIRED` after 3.2 s.
* **The default key is logged as `KEY: http://origin/path`** (the `proxy_pass` URL), with no client host. With `proxy_set_header Host $host` but the default key, `b.lumina.local` was served `a.lumina.local`'s page (`host=a.lumina.local`, `HIT`).
* **`$scheme$host$request_uri` keys look like `httpa.lumina.local/h/3`,** with no separator. `$host` is lowercased and has no port, so `A.Lumina.Local` hit `a.lumina.local`'s entry. Query parameter order makes separate entries.
* **`Authorization` is ignored by default.** Alice's response was served to an anonymous client and to Bob.
  * Bypass alone: Alice's bypassed response **replaced** the anonymous entry, and the next anonymous request was a `HIT` on Alice's copy.
  * `proxy_no_cache` alone: Alice got the anonymous copy.
  * Both: correct.
* **The same mechanism is OSS's refresh trick:** `proxy_cache_bypass $http_x_refresh` plus a request with that header replaced the entry (`BYPASS`, then `HIT` with the new copy).
* **A 32 KB keys zone held about 216 of 400 entries.** The older ones were evicted and their files deleted, with `max_size=1g` almost empty and nothing in the error log.
* **The cache survives recreating the container.** The first request after `./lab.sh edge` was a `HIT` before the cache loader had run: a worker that misses in the zone opens the file on disk.
* **`Vary: Accept-Encoding`** gave two files with the same `KEY:` line, one per variant, each a `HIT` for its own kind of client.
* **`proxy_cache_min_uses 3`:** `MISS MISS MISS HIT HIT`.

### Under Pressure (Day 2)
* **The lock works for new entries:** 20 concurrent requests, 2 s origin, 1 origin request. With a 7 s origin (beyond the 5 s `proxy_cache_lock_timeout`), all 20 reached the origin and all 20 were logged `MISS`; the burst took about 12–14 s.
* **Both lock timers matter.** `proxy_cache_lock_timeout 10s` alone with a 7 s origin: 2 origin requests (one more at the 5 s `proxy_cache_lock_age`), 18 `HIT`, burst 12.0 s. With `proxy_cache_lock_age 10s` too: 1 origin request, burst 7.1 s.
* **`proxy_cache_lock` does nothing for expired entries.** 20 concurrent requests on an expired entry with the lock on: 20 origin requests, all `EXPIRED`. Only `use_stale updating` collapses refreshes. (The first rehearsal of the Day 2 guide tripped on this, because an old expired entry was still on disk.)
* **Failure without stale config:** dropped connection gave `502 EXPIRED`, a 503 answer passed through (`503 EXPIRED`). With `error timeout http_500 http_502 http_503 http_504`, both were `STALE` 200s. A never-cached URL during the outage: `502 MISS`.
* **The origin's `stale-while-revalidate`** behaves like `updating`: concurrent requests got `UPDATING`, the request doing the refresh waited 3 s (`EXPIRED`). **`stale-if-error`** covered a dropped connection (`STALE`), but not a 503 answer.
* **Background update:** first request after expiry `STALE` in 0.00 s, then `UPDATING`, then `HIT` with the refreshed copy, origin count 2.
* **Revalidate with background update:** the client saw `STALE`, and the 304 only showed in the origin's `not_modified` counter (subrequests aren't logged). Without background update, the client saw `REVALIDATED`.
* **Throughput:** about 45,000 req/s for a cached URL (origin saw it once) vs about 820 req/s with `Authorization` (every request to the origin), `oha` on the lab network, 50 connections.
* **Slow origin (1 s), `max-age=2`, 50 connections for 10 s:**
  * Day 2 starting config: origin saw 107 (57 `MISS`, 50 `EXPIRED` at once), slowest 2.5 s.
  * Lock + stale + background: origin saw 3, slowest 1.5 s (the cold miss), the rest `HIT`/`UPDATING`.
  * Requests per second were similar in both runs.

### Kernel and Connection Limits (Day 3)
* **Backlog:** default 511. `backlog=4096` applied on **reload**. `SOMAXCONN=128` capped it to 128 in `ss` with nothing logged. `reuseport` showed one listener per worker, each with its own 4096 queue.
* **Overflow demo** (workers SIGSTOPped for 1.5 s, 100 new connections from inside the lab network):
  * `backlog=8` or `16`: about 9–17 answered at about 1.6 s, the rest at 3.2–3.9 s, with `TcpExtListenOverflows` in the hundreds.
  * `backlog=4096`: all 100 at 1.52 s, no overflows.
  * No `SyncookiesSent`.
* **Docker's port forwarding hides overflows:** clients on the host connected instantly to the forwarder, which retried the SYNs to the container itself. Load tests have to run on the lab network (`lab.sh load`).
* **Open files at 1024 with 3,000 connections:**
  * About 450 clients got 500s from `open() ... failed (24: Too many open files)` on the cache file.
  * Plus 2 `accept4()` failures and 1 `socket() ... while connecting to upstream`. The slowest response was 5.8 s.
  * The `oha` container needed `--ulimit nofile=65536` itself, or the client ran out first.
* **`worker_rlimit_nofile 16384` took effect on reload** (soft and hard 16384 in `/proc/PID/limits`). With the container's hard limit at 1024: `[alert] setrlimit(RLIMIT_NOFILE, 16384) failed (1: Operation not permitted)`, while `nginx -t` and the ready check both passed.
* **Ports** (`ip_local_port_range` 40000–40999, 20 connections, every request to the origin):

  | Config | Result |
  | :--- | :--- |
  | Default keepalive | 22,500 × 200, 33 origin connections |
  | `keepalive 0` | 984 × 200, then 94,157 × 502 `(99: Cannot assign requested address)`, about 1,000 TIME_WAIT on the edge |
  | `keepalive 0` + `tcp_tw_reuse=1` | 8,112 × 200, 35,392 × 502 |

* **`proxy_set_header Connection close`** put TIME_WAIT on the **origin** (it closed first), not on the edge.
* **The Python origin needed `TCP_NODELAY`.** Without it, Nagle plus delayed ACK added 40 ms per keepalive response, so keepalive looked 4× *slower* than `Connection: close`. That would have taught the opposite lesson.
* **Reload timing:** requests sent in the first moment after `nginx -s reload` can still reach old workers. `lab.sh reload` waits a second.

### Side Quest (NGINX Plus R37.1.1, API version 10)
* **The first license** (issued 2026-09-20) gave `[emerg] license expired` on 2026-10-21. With the renewed JWT, the side quest config loaded unchanged.
* **`PURGE` always answers 204**: for a cached entry, for a key that was never cached, and for a purge with the wrong `Host` (which left the entry in place). The status doesn't confirm anything; the next request does.
* **Wildcard purge works without `purger=on`** (the next request is a `MISS`), but the files stay on disk: 13 files before and after. With `purger=on`, the files were deleted 20–60 s after the purge (10 of 23, then 10 of 24), and the log shows `start cache purger process`.
* **`cold` stayed `true`** in `/api/10/http/caches/lumina` until the cache loader exited, about a minute after start.
* **A.1 counters matched `X-Cache-Status` exactly:** `rr 3` + `rr 2` gave miss 2, hit 3.
* **The deny check matters.** With `return 403` for outside purges, a `PURGE` from a bridge container (seen as `172.17.0.2`) got 403. Without it, the same request was proxied to the origin as `PURGE` and got the origin's 501.
* The top-level README described the side quest as "purging via REST API (`PURGE /api/cache/...`)". Purge is `proxy_cache_purge` on the data plane; the API only reports cache metrics.

---

## Day 1

### Day 1: "No invalidation in OSS? How is that production-viable?"
* **Production designs avoid needing a purge.** Static assets get fingerprinted URLs (`app.4f2c1.js`) and long lifetimes, so a deploy means new keys. HTML and API responses get short lifetimes (microcaching: 1–10 s) plus stale serving (Day 2). Neither needs a "delete" button.
* **Targeted refresh:** `proxy_cache_bypass` on a restricted header replaces one entry (verified while building Day 1). It works one exact key at a time.
* **Flush everything:** put a generation variable in `proxy_cache_key` (for example `"$cache_gen$scheme$host$request_uri"`, with `$cache_gen` set in an included file) and change it with a reload. Every old entry becomes unreachable at once. They stay on disk until `inactive` or the LRU removes them. *(Not run in the lab.)*
* **Third-party module:** `ngx_cache_purge` (FRiCKLE, plus maintained forks) adds a purge location to OSS. You compile it in, or install a distro package where one exists. Hosting stacks such as WordPress caching plugins rely on it. Not F5-supported.
* **BIG-IP lens:** on BIG-IP, invalidation is a management-plane operation (tmsh/iControl). In NGINX it is a config design choice made on the data plane.

### Day 1: What is LRU?
* **Least Recently Used** is an eviction policy. When a bounded cache is full, it throws out the entry that hasn't been touched for the longest time. The usual structure is a hash table for lookup plus a doubly linked list ordered by last use: a hit moves the entry to the front, and eviction takes from the back. Both are O(1).
* **NGINX:** the keys zone keeps each entry's node in a red-black tree (lookup) and a queue (LRU order). The cache manager evicts from the LRU end when `max_size` is exceeded, and the zone itself does so when it runs out of memory (the silent 216-of-400 finding). `inactive=` is a separate, time-based rule: it removes entries not used within that time, fresh or not.
* **Python's `functools.lru_cache`:** the speedup in Advent of Code comes from **memoization** (a repeated subproblem is answered from the cache), not from the LRU policy. With `maxsize=None` (or `functools.cache`) nothing is ever evicted, so there is no LRU at all. The LRU part only matters when you cap memory. That is also the edge cache's situation: memoization for HTTP, with LRU deciding what to keep when space runs out.

### Day 1: Does NGINX cache the new `QUERY` method?
* **No, and it can't be configured to.** The test used nginx 1.31.6 with the solution config on an isolated copy, with the origin patched to accept `QUERY`.
  * NGINX accepts and proxies `QUERY /courses/q` with a JSON body (200 from the origin).
  * There is **no `X-Cache-Status` at all**, even with `max-age=60`. `$upstream_cache_status` is empty because the cache is never consulted for that method.
  * The origin saw every request.
* **`proxy_cache_methods GET HEAD QUERY;`** gives `[emerg] invalid value "QUERY"`. The directive only accepts `GET`, `HEAD` and `POST`.
* **The contrast with the spec:** the IETF draft (safe method with body) defines `QUERY` responses as cacheable, with the **request body as part of the cache key**. NGINX's cache has no notion of that today. `POST` caching is the closest thing NGINX has: opt in with `proxy_cache_methods POST` and put `$request_body` in the key. That only works while the body fits in `client_body_buffer_size`, because `$request_body` is empty when the body was written to a temp file.
* **Why it's safe as-is:** an uncached `QUERY` is simply passed through. The risk would be the opposite: caching by URI alone would serve one query's result to a different query.

### Day 1: Why doesn't NGINX follow the RFC rule for `Authorization`?
* **The rule:** RFC 9111 §3.5 says a shared cache MUST NOT reuse a response to a request carrying `Authorization` unless the response has `public`, `s-maxage` or `must-revalidate`.
* **The 2009 nginx mailing-list thread** (August 2009, Kuramoto Eiji, Maxim Dounin, Igor Sysoev), when `proxy_cache` was new:
  * Dounin: "You instructed nginx to cache response - and it will do so", and "If it's checked by backend server - there is no reason for nginx to do anything with it."
  * Dounin gave a config workaround: `if ($http_authorization)` sends the request to a location without `proxy_cache`.
  * Sysoev agreed authenticated responses shouldn't be cached, but wanted it configurable, because anyone can force a cache miss by sending a dummy `Authorization` header.
  * A proposed `proxy_cache_ignore_for_authorization` option never landed in mainline. The answer became `proxy_cache_bypass` + `proxy_no_cache`, and the `proxy_cache_bypass` docs example lists `$http_authorization`.
* **The spec angle:** RFC 9110 §3.7 defines a gateway (reverse proxy) as acting "as an origin server for the outbound connection." NGINX treats its cache as part of the origin, run by the same operator, whose config is the policy. RFC 9111 itself doesn't carve out reverse proxies; that view is NGINX's design stance, not an exemption in the spec.
* **The same stance shows elsewhere:** NGINX ignores request-side `Cache-Control`/`Pragma` by default too. Only response headers, plus your config, decide caching.

### Day 1: Host and the cache key, four combinations
* The edge makes two independent choices: the `Host` the origin sees (`$proxy_host` by default) and whether the key includes the client's host (`$proxy_host` by default). Fixing only `proxy_set_header Host $host` is worse than fixing neither:
  * **Neither fixed:** the cache and the origin agree, so it's wrong but consistent and visible.
  * **Host only:** the origin builds per-tenant pages under a host-free key. That's a silent cross-tenant leak that depends on who asked first (Activity 3.4, `/h/2`).
  * **Key only:** safe, but wasteful (duplicate generic copies).
  * **Both fixed:** correct.
* **General rule:** the key must include everything the origin uses to build the response. Origin uses more than the key → leak. Key uses more than the origin → only cost. `Authorization` (Activity 3.5) is the same rule.
* BIG-IP delta: BIG-IP forwards the client `Host` unchanged, so the BIG-IP reflex (`proxy_set_header Host $host` alone) lands in the leak case on a caching location.
* **Assets:** diagram page `Host and the Cache Key` (artifact https://claude.ai/artifact/M3LkYKrVNek5PGBjetRtSR), and blog draft `host-and-cache-key.md` (Markdown + Mermaid sequence diagrams; images only if the blog can't render Mermaid).

### Day 1: Guide fix
* Concept 1.2 said methods other than `GET`/`HEAD` are never cached. Corrected: that's the `proxy_cache_methods` default, and `POST` is the only other method it accepts (it needs the body in the key).

### Day 1: Lab and quiz
* Lab config built up through the activities: `proxy_cache_path ... keys_zone=lumina:10m`, `proxy_set_header Host $host`, `proxy_cache_key $scheme$host$request_uri`, `proxy_cache_valid 200 1m`, `proxy_cache_bypass` + `proxy_no_cache $http_authorization` (commented "read side" / "write side"), and `X-Cache-Status ... always`.
* **Quiz:** 7/10 first attempt, 8/10 second (pass). The misses were on **keys zone sizing** and **NGINX ignoring `Authorization`**:
  * **Sizing:** about 8,000 keys per MB of `keys_zone`. A full zone evicts LRU entries and their files, whatever `max_size` says, and logs nothing. `keys_zone=...:1m max_size=50g` holds about 8,000 entries, and the disk limit is never reached.
  * **Authorization:** by default an authenticated response is stored and served to everyone. `proxy_cache_bypass` stops only reads and `proxy_no_cache` stops only writes, so you need both.
* Day 1 recap written: `day01_recap.md`.

## Day 2

### Day 2: Dashboards for cache status
* **OSS has no cache counters.** `stub_status` reports only connections and requests, so the official `nginx-prometheus-exporter` and its OSS Grafana dashboard can't show `STALE`/`UPDATING`/`REVALIDATED`. In OSS the data lives in the access log (`$upstream_cache_status`): ship it to a log pipeline and count by value, or add the third-party VTS module, which keeps per-cache-zone counters.
* **Plus counts them natively:** the API's cache zone stats (hit, stale, updating, revalidated, miss, expired, bypass), and the exporter turns them into Prometheus metrics. Sprint 11 builds the pipeline.
* **`STALE` alone isn't an outage signal once background update is on.** The first request after every expiry is `STALE` in normal operation. An outage shows as a *sustained* `STALE` rate together with origin errors (`$upstream_status`), not as `STALE` being present.

### Day 2: oha vs ab
* `ab` is single-threaded, speaks HTTP/1.0 (keepalive only with `-k`), and becomes the bottleneck long before the cache does. It also counts responses whose length differs from the first one as "Failed requests".
* `oha` is multi-threaded and async (Rust/tokio). It uses HTTP/1.1 keepalive by default, offers HTTP/2, a run duration (`-z`), a rate cap (`-q`), latency percentiles, and status and error distributions (e.g. `Cannot assign requested address` on Day 3).

### Day 2: Where `REVALIDATED` goes with background update (verified, nginx 1.31.6)
* Expired entry + `use_stale updating` + `background_update` + `revalidate`: the client request is answered at once from the old copy and logged `STALE`. A subrequest sends `If-None-Match`/`If-Modified-Since`, gets a 304, and extends the entry. The subrequest is the one that is `REVALIDATED`, and subrequests aren't logged by default.
* With `log_subrequest on;` the subrequest shows up as its own line for the same URI: `200 ... upstream=<origin> cache=REVALIDATED`, written just before the client's `STALE` line (`upstream=-`). The origin counted `not_modified: 1` and one full response.
* **Asset:** decision flowchart page `Cache Under Pressure` (artifact https://claude.ai/artifact/S4nAysV5j6VNhbmRoBoY8Q): lookup and lock, the expired-entry path, and what each `X-Cache-Status` means.

### Day 2: Does any regulation require `log_subrequest on`?
* None names it. PCI DSS Req. 10, HIPAA §164.312(b) and SOC 2 ask for an audit trail of *who accessed what*. The client's request is already logged (`STALE`). The background refresh has no client: it's the edge talking to its own origin, and the origin's log records it.
* **The cache rule that does apply is storage:** a cached response is data at rest on the edge's disk. If it can hold cardholder data or ePHI, the cache directory is in scope (PCI DSS Req. 3, HIPAA encryption at rest), or the response must not be cached (`proxy_no_cache`, `Cache-Control: no-store`). Ties to the secure key storage work planned for Sprints 8, 11 and 14.

### Day 2: Decision flowchart and compliance question
* **Asset:** `cache-under-pressure.md` (Markdown + Mermaid, the default format) and `cache-under-pressure.html` (published as artifact https://claude.ai/artifact/D6EtVGiMCDbcbdW46mcPdB). Part 1: decision flowcharts (lookup/lock path, expired-entry path), X-Cache-Status table, monitoring notes. Part 2: client/NGINX/origin sequence diagrams for 9 configurations (no protection, lock fast/slow origin, expired with lock only, updating, background update, revalidate, origin 503 not listed/listed) with a summary table. Key point it makes visible: the two `STALE` paths (background refresh vs a listed failure) look identical in the log.
* **Module builds:** the journey plan has no compile-a-module activity yet. The user wants Sprint 11 to build VTS as a dynamic module and use a community Grafana dashboard.
* **Does any regulation require `log_subrequest on`?** No. PCI DSS Req. 10, HIPAA audit controls and SOC 2 require audit trails of who accessed what, and the client's request is already logged (as `STALE`). The cache rule that does apply: a cached response is data at rest on the edge's disk, so cached cardholder data or ePHI falls under the storage rules (PCI DSS Req. 3, HIPAA). Keep such responses out of the cache with `proxy_no_cache`/`Cache-Control: no-store`, or protect the cache path like any other store.

### Day 2: Activity 3.2 rerun
* The first try reused `/s/2` and `/s/3` after they had expired: every request was `EXPIRED` and went to the origin (21 and 40 origin hits). The lock doesn't cover expired entries, which is the 1.1 rule, seen by accident.
* With `proxy_cache_lock_timeout 10s` + `proxy_cache_lock_age 10s` on new URLs: `/s/4?delay=2` → 1 origin request, 2.5 s; `/s/5?delay=8` → 1 origin request, 8.0 s, log 1 `MISS` + 19 `HIT`. Waiters served from the new entry are logged `HIT`.
* The extra ~0.5 s is the lock's polling: waiters recheck the entry on a 500 ms timer, so they can finish up to half a second after the fetch completes.

### Day 2: Lab and quiz
* Lab config built up through the activities, on top of Day 1's: `proxy_cache_lock on`, `proxy_cache_use_stale error timeout http_500 http_502 http_503 http_504 updating`, `proxy_cache_background_update on`, `proxy_cache_revalidate on`. The 10 s lock timers from the Activity 3.2 experiment were removed again.
* **Quiz:** 6/10 first attempt, 7/10 second, 8/10 third (pass). No single topic: the user found the number of rules (which status covers which path, which directive needs which) hard to hold in their head, and called the flowchart helpful for that.
* Day 2 recap written: `day02_recap.md`.

### Day 3: Is there an NGINX-tuned Linux, and are there published TCP profiles?
* **BIG-IP delta:** TMM runs its own TCP stack, with profiles per virtual server and per side. NGINX uses the kernel's stack. There is one set of `sysctl` globals per network namespace, shared by the client side and the upstream side.
* **No "NGINX distro".** The kernel version matters more than the distro (BBR, `SO_REUSEPORT` balancing, TCP Fast Open, kTLS). RHEL/Fedora's `tuned` has `network-latency`/`network-throughput` profiles, and cloud kernels (`linux-aws`) mostly tune the NIC driver. Netflix Open Connect runs NGINX on FreeBSD for kTLS + sendfile. Kernel bypass (DPDK) isn't stock NGINX, but F-Stack is a third-party fork that does it.
* **Containers share the host kernel:** the Sprint 4+ container labs get a current userland, but TCP features come from the host's 5.19 kernel. Only the `sysctl` *values* are per namespace.
* **Closest thing to separate client-side and server-side TCP profiles:** listener options (`backlog`, `reuseport`, `fastopen`, `deferred`, `so_keepalive`, `rcvbuf`/`sndbuf`), `proxy_socket_keepalive`, and per-route `ip route ... initcwnd/initrwnd/congctl` toward clients or origins.
* **Published profiles:** the NGINX blog's "Tuning NGINX for Performance" (somaxconn, netdev_max_backlog, port range, file descriptors: the Day 3 set), Netflix's EC2 tuning talk (Brendan Gregg, re:Invent 2017), Red Hat's network performance tuning guide, and ESnet fasterdata (long-distance, high-bandwidth paths, not web edges). There's no F5-blessed "f5-tcp-progressive" equivalent. Modern defaults are good: tune what `ss`/`nstat` show you're running out of.

### Day 3: F-Stack, Brendan Gregg, and NGINX + kernel metrics together
* **F-Stack:** Tencent's open-source DPDK stack (a FreeBSD TCP stack running in user space), with an NGINX port. Used inside Tencent (it came from DNSPod) and in some telecom and gaming builds. It's niche because the NIC belongs to DPDK, cores busy-poll at 100%, and `ss`/`nstat`/`tcpdump`/iptables no longer see the traffic. That's also why BIG-IP has its own TMM statistics instead of netstat.
* **Brendan Gregg:** yes, the person behind flame graphs, the USE method and the BPF performance tools (bcc/bpftrace).
* **Bringing NGINX and system data together:** a shared time axis plus shared labels (host, instance, request ID). Metrics: Prometheus scrapes the NGINX exporter *and* `node_exporter` (which exports `nstat` counters such as ListenOverflows, TIME_WAIT and file descriptors), and Grafana puts them on one dashboard. Logs: JSON access logs → Loki/Elasticsearch. Traces: OpenTelemetry, with `traceparent` linking the edge to the upstream logs. The OpenTelemetry Collector can gather all three.
* **Gap in the plan:** Sprint 11 as written is NGINX-side only (JSON logs, OTel, NGINX exporter). The user asked whether host/kernel metrics come back there. Candidate addition: `node_exporter` next to the NGINX exporter so the Day 3 counters land on the same dashboard.

### Day 3: Activity 3.2 guide fix: warm-up cached the wrong key
* **Symptom (user's run):** Fastest 1.58 s, Slowest 2.10 s, Average 1.94 s, instead of a flat ~1.5 s.
* **Cause:** the cache key is `$scheme$host$request_uri`. The warm-up `r /o/1` sends `Host: 127.0.0.1`, while `oha` inside the lab network sends `Host: s4-edge`, so the load test missed. After the stall one request went to the origin and `proxy_cache_lock` held the rest: 70 logged `HIT` at rt≈0.50 s (the lock's 500 ms recheck) and 29 at 0.000. That's stall + polling ≈ 1.58 s, or stall + one lock tick ≈ 2.1 s. Same lock behavior as the Day 2 Activity 3.2 rerun, and the Day 1 `$host`-in-the-key lesson showing up by accident.
* **Fix:** `day_03.md` warm-up is now `r /o/1 -H 'Host: s4-edge'`. The 4096 rerun needs no change: an expired entry is served `STALE` right away (`use_stale updating` + background update).
* **Also seen:** the user's `nginx.conf` still had `listen 8084;` (limit 511), so that run had no overflows and no ~3.2 s SYN-retry group.

### Day 3: Guide fix and lab
* **Guide fix:** `day_03.md` now has a line under the "New today" table: `./lab.sh load` is `oha`, run on the lab network and aimed at the edge (so it sends `Host: s4-edge`). Day 3 used `oha`'s output in Activity 3.3 without ever naming the command. The user asked "where is oha called?"
* **Activity 3.2 rerun (backlog=16, correct warm-up):** Fastest 1.58 s, Slowest 3.44 s, Average 2.85 s. 17 queued at about 1.58 s, the other 83 averaged about 3.1 s (the 1 s SYN retry landed during the stall, so they got in on the 3 s one).
* **Sprint lab:** all 10 tests passed. The user needed notes from all three days to get the final config.
* **Quiz:** 9/10 on the first attempt.
* **Plan change:** README Sprint 11 now includes `node_exporter` next to the NGINX exporter (host/kernel counters on the same dashboard).
* **Assets:** `kernel-limits.svg` + `kernel-limits.png` (the infographic for `day03_recap.md`: the three limits, who owns each one, symptom and evidence). Rendered with rsvg-convert, Lato + DejaVu Sans Mono.

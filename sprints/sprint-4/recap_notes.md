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

## Questions and Clarifications During the Sprint
*(Add findings from questions asked while working through the days here.)*

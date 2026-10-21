# Sprint 4: Performance Engineering, Caching & Kernel Tuning
**Cadence:** 3 sessions, any days that week  
**Milestone:** The Lumina Edge Accelerator: a caching edge that keeps tenants and users apart, shields a slow origin from stampedes and outages, and has the kernel and file limits to take a burst  
**Shape:** 3 days. The Enterprise Side Quest is an **optional** add-on to Day 3, with its own optional quiz.

---

## 1. Sprint at a Glance

| Day | Theme | Concepts (~15 min) | Lab (~35 min) | Guide |
| :--- | :--- | :--- | :--- | :--- |
| **1** | The edge cache | Web Acceleration profile → `proxy_cache`, keys zone vs disk, which origin headers win, the cache key and `Host`, `Authorization` and bypass vs no-cache, `$upstream_cache_status` | Turn on a cache that caches nothing, header precedence (and a cached 503), the cross-tenant key trap, Alice's page served to everyone, a keys zone too small to notice | [`day_01.md`](day_01.md) |
| **2** | The cache under pressure | Thundering herds and `proxy_cache_lock`, `proxy_cache_use_stale`, who waits for a refresh, background update, revalidation, measuring with `oha` | Cached vs uncached throughput, collapse a stampede (and outlast the lock), serve stale through drops and 503s, refresh with nobody waiting, a herd under load before and after | [`day_02.md`](day_02.md) |
| **3** | Kernel and connection limits & the sprint lab | Accept queue (`backlog`, `somaxconn`, overflows), `reuseport`, file descriptors and `worker_rlimit_nofile`, ephemeral ports and TIME_WAIT, `tcp_tw_reuse`, where these live in containers | Stall the workers and overflow the queue, run out of descriptors, hit a hard limit, exhaust ports without keepalive, **build the Lumina edge**, `test_sprint04.sh` | [`day_03.md`](day_03.md) |
| *3+* | *Optional Enterprise Side Quest* | *Invalidation without Plus, `proxy_cache_purge`, wildcard purge and the purger, securing purge, cache metrics in the Plus API* | *Watch the cache in the API, purge a URL (and miss with the wrong key), purge a section, refuse an outside purge* | [`day_03_enterprise.md`](day_03_enterprise.md) |

---

## 2. Lab Environment

From Sprint 4 on, the labs run in **containers** for current packages (`nginx:mainline`: nginx 1.31.6, OpenSSL 3.5). The host's NGINX stays stopped. Everything runs from `/srv/nginx-journey/sprints/sprint-4/lab` through `lab.sh`.

| Port | Service |
| :--- | :--- |
| 8080–8083 | Earlier sprints (reserved) |
| **8084** | **Sprint 4 lab: the Lumina edge** (container `s4-edge`) |
| **127.0.0.1:8014** | **The origin** (container `s4-origin`; the edge reaches it as `s4-origin:8014` on the `s4-net` network) |
| 8086 / 127.0.0.1:8085 | Side quest: NGINX Plus container `lumina-cache-plus`, traffic / API and dashboard |

```bash
cd /srv/nginx-journey/sprints/sprint-4/lab
cp day1_nginx.conf nginx.conf           # or the day's config, or starter_nginx.conf for the sprint lab
./lab.sh up                             # network, origin, edge, then the ready check
source helpers.sh                       # r, rr, burst, seen, key: in every new terminal
./lab.sh down                           # when you're done for the day
```

**`lab.sh`**
* `up`, `check`, `reload`, `t`/`T` (`nginx -t` / `-T` inside the edge), `edge` (recreate only the edge), `down`.
* `stats` / `reset` read and zero the origin's counters. `mode status=503|delay=3|drop=1` makes the origin fail; plain `mode` returns it to normal.
* `load [oha args] PATH` runs an `oha` load test **from inside the lab network**, so Docker's port forwarding stays out of the numbers.
* `ss`, `nstat`, `workers` and `freeze [S]` look inside the edge's network namespace and processes.
* `SOMAXCONN=`, `NOFILE=`, `PORTS=` and `TW_REUSE=` before `up` or `edge` set the edge's kernel and file limits.
* The whole `lab/` directory is mounted into the edge at `/lab`, so an edited `nginx.conf` is picked up by `./lab.sh reload`. Logs are in `lab/logs/`, the cache in `lab/cache/` (both gitignored).

**The origin (`origin.py`)** answers any path with JSON that includes the `Host` it saw and how many times that URI reached it. Query parameters set its caching headers (`cc=`, `expires=`, `accel=`, `cookie=1`, `vary=`), its status (`status=`) and its speed (`delay=`). Every 200 carries an `ETag`, and matching conditional requests get a 304.

> **Version notes (verified on nginx 1.31.6 in `nginx:mainline`):**
> * Upstream keepalive is on by default (since 1.29.7), which Day 3 relies on.
> * The container's defaults: `somaxconn` 4096, open files 1024 soft / 524288 hard, ports 32768–60999, `tcp_tw_reuse` 2 (loopback only).
> * NGINX's default `listen` backlog on Linux is 511.

---

## 3. Daily Detail

### Day 1: The Edge Cache
**Concepts:**
* `proxy_cache_path`: the keys zone (about 8,000 keys per MB), the disk, `inactive`, the cache manager and loader.
* Lifetime precedence: `X-Accel-Expires`, then `Cache-Control` / `Expires`, then `proxy_cache_valid`. What's never cached.
* The default key and `Host`, and why fixing only one is worse.
* `Authorization`: `proxy_cache_bypass` (read) vs `proxy_no_cache` (write).
* `$upstream_cache_status` and `add_header ... always`.

**Lab:**
* A cache that caches nothing until it gets a lifetime.
* Which header wins, and a cached 503.
* Tenant B gets tenant A's page, then the fix.
* Alice's page served to everyone, and bypass alone still storing it.
* The cache surviving a restart; a 32 KB zone evicting silently.

### Day 2: The Cache Under Pressure
**Concepts:**
* Thundering herds, `proxy_cache_lock` (new entries only), the lock timeout.
* `proxy_cache_use_stale` conditions, and the origin's `stale-while-revalidate` / `stale-if-error`.
* Who waits for a refresh: `updating` vs `proxy_cache_background_update`.
* `proxy_cache_revalidate` and 304s.
* Measuring the tail and the origin with `oha`.

**Lab:**
* 45,000 vs 800 requests per second.
* A 20-request stampede reduced to one, and a slow origin that outlasts the lock.
* Stale through dropped connections and 503s.
* A refresh nobody waits for.
* The 304 hidden behind background update.
* A herd under load, before (107 origin requests) and after (3).

### Day 3: Kernel and Connection Limits & the Sprint Lab
**Concepts:**
* The accept queue, `min(backlog, somaxconn)`, overflows and SYN retries, `reuseport`.
* File descriptors: `worker_connections` vs `RLIMIT_NOFILE`, `worker_rlimit_nofile`, hard limits.
* Ephemeral ports, TIME_WAIT, `tcp_tw_reuse`, upstream keepalive.
* Which settings live in `nginx.conf`, `sysctl` (per network namespace) and the container runtime.

**Lab:**
* A 1.5-second stall that costs overflowed clients 3.2 seconds.
* `somaxconn` silently capping `backlog`.
* 500s from `Too many open files`, and a hard limit that wins over the config.
* 94,000 502s from port exhaustion, `tcp_tw_reuse` as partial relief, keepalive as the fix.
* Then build the Lumina edge (Section 4) and pass `test_sprint04.sh`.

### Day 3+ (Optional): Enterprise Side Quest
**Concepts:**
* Invalidation in open source (versioned URLs, refresh via bypass).
* NGINX Plus `proxy_cache_purge`, wildcards, `purger=on`, securing and fanning out purges.
* Cache metrics in the Plus API (`/http/caches/ZONE`).

**Lab:**
* Watch the cache in the API.
* Purge one URL, and miss with the wrong `Host`.
* Purge a section.
* Refuse a purge from outside.

---

## 4. Lab Specification: The Lumina Edge Accelerator

Copy `lab/starter_nginx.conf` to `lab/nginx.conf`. The edge listens on 8084 and proxies to the `origin` upstream.

1. **A disk cache** under `cache/`.
2. **Tenants:** the origin receives the client's `Host`, and different host names never share a cache entry.
3. **Visibility:** every response carries `X-Cache-Status` with the cache result for that request.
4. **What's cached:**
   * Responses with no caching headers from the origin are cached for 1 minute.
   * Responses the origin marks `no-store` or `private`, or that set a cookie, are never served from cache.
5. **Authenticated requests:** requests with an `Authorization` header always go to the origin, and their responses are never stored.
6. **Stampedes:** a burst of concurrent requests for an uncached URL reaches the origin once.
7. **Origin failure:** when the origin fails or answers 5xx, clients get the expired cached copy instead of an error.
8. **Slow refresh:** refreshing an expired entry never makes a client wait for the origin.
9. **Accept queue:** port 8084's accept queue holds at least 4096 connections.
10. **File descriptors:** each worker can open at least 16384 files.

`lab/solution_nginx.conf` is the reference configuration.

---

## 5. Automated Test Suite (`test_sprint04.sh`)

```bash
cd /srv/nginx-journey/sprints/sprint-4 && ./test_sprint04.sh
```
* It runs `lab/lab.sh check` first. If the lab isn't ready, it stops with a setup message and tests nothing.
* Every run uses fresh URLs, so earlier activities don't matter.
* Tests 7 and 8 briefly switch the origin into failure and slow modes, and switch it back.
* Tests 9 and 10 read the edge's network namespace and `/proc`: run as root.
* Run against the untouched starter, it reports 0/10 and **`Sprint 4 start is ready to go`**.
* Override `EDGE` or `ORIGIN` to point it elsewhere.

| # | Assertion (gate: 10/10) | Requirement |
| :--- | :--- | :---: |
| 1 | A response carries `X-Cache-Status` with a cache result | 3 |
| 2 | A repeat request for a response with no caching headers is a `HIT`, and the origin saw it once | 1, 4 |
| 3 | `no-store`, `private` and `Set-Cookie` responses are never served from cache | 4 |
| 4 | The origin sees the client's `Host`, and `a.lumina.local` / `b.lumina.local` get separate entries | 2 |
| 5 | `Authorization` requests always reach the origin; an anonymous client never gets their copy | 5 |
| 6 | 20 concurrent requests for an uncached URL reach the origin once | 6 |
| 7 | Expired copies are served when the origin drops connections and when it answers 503 | 7 |
| 8 | An expired entry is answered in under a second while a 3-second origin refreshes it in the background | 8 |
| 9 | The accept queue on 8084 holds at least 4096 | 9 |
| 10 | Every worker's open-file limit is at least 16384 | 10 |

---

## 6. Daily Quizzes

All pools live in [`data/quizzes.json`](../../data/quizzes.json). Each day has 20 questions (8 scenario, 6 config, 3 diagnose, 3 recall). The quiz draws 10, and 8/10 passes.

* **Day 1:** keys zone vs disk, `inactive` vs lifetime, header precedence, what's never cached, the default key and `Host`, `Authorization`, bypass vs no-cache, cache status values.
* **Day 2:** the herd and the lock (and its limits), `proxy_cache_use_stale` conditions, origin stale directives, `updating` vs background update, revalidation, measuring.
* **Day 3:** accept queue and `somaxconn`, overflow symptoms and counters, `reuseport`, descriptors and `worker_rlimit_nofile`, hard limits, ports and TIME_WAIT, `tcp_tw_reuse`, keepalive, network namespaces.
* **Day 3 Enterprise (optional, 10 questions, not part of graduation):** invalidation options, `proxy_cache_purge` and its key, wildcards and the purger, securing purge, the Plus cache API.

```bash
cd /srv/nginx-journey && python3 -m http.server 8090
# http://<lab-host>:8090/quiz.html?sprint=4&day=1   (day=2, day=3, and day=3&pool=enterprise)
```

---

## 7. Optional Extras

* **4.1 `proxy_cache_min_uses`.** Set it to 3 and find out what happens to `X-Cache-Status` for the first three requests. When would you want one-hit wonders kept out of the cache?

  <details>
  <summary>Answer</summary>

  `MISS MISS MISS HIT HIT`: the response is stored on the third request, not the first. It keeps URLs that are requested once (crawlers, unique query strings) from pushing popular entries out of a small keys zone or disk.
  </details>

* **4.2 `Vary`.** Send `?vary=Accept-Encoding` with and without `Accept-Encoding: gzip`. Does NGINX keep two variants under one key? (Look with `key`.)

  <details>
  <summary>Answer</summary>

  Yes. `key` shows two files with the **same** `KEY:` line, and each kind of client gets a `HIT` on its own variant. NGINX adds the request headers named in `Vary` to its lookup, so a `Vary: User-Agent` origin fragments the cache into one copy per browser version.
  </details>

* **4.3 Slice the big ones.** The `nginx:mainline` image includes `ngx_http_slice_module`. Read how `slice` caches a large object in ranges, and work out what the cache key needs to include. (Hint: one object becomes many entries, one per range.)

  <details>
  <summary>Answer</summary>

  `$slice_range`. The documented pattern adds it to `proxy_cache_key`, sends it upstream with `proxy_set_header Range $slice_range`, and caches `206` responses (`proxy_cache_valid 200 206 ...`). Without it in the key, every slice would overwrite the same entry.
  </details>
* **4.4 SYN cookies.** With `backlog=16` and the workers frozen, look at `TcpExtSyncookiesSent` in `nstat`. Why doesn't the **accept** queue use SYN cookies?

  <details>
  <summary>Answer</summary>

  SYN cookies protect the **SYN** queue (half-open handshakes) when it's flooded. A full **accept** queue holds connections that already completed the handshake and are waiting for `accept()`. When it's full, the kernel drops new SYNs (`TcpExtListenOverflows` / `ListenDrops`) and no cookie is sent. That's what the freeze demo showed.
  </details>

---

## 8. Tracker Sync

* **Platform milestone:** Lumina answers repeat traffic from cache, keeps tenants and authenticated users apart, survives origin outages and slow refreshes without users noticing, and has the queue and descriptor headroom for a burst.
* **Graduation:** `test_sprint04.sh` 10/10, and at least 80% on each day's quiz (the Enterprise quiz is optional).

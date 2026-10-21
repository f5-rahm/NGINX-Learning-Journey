# Sprint 4 &bull; Day 1: The Edge Cache
**Day:** 1 of 3  
**Estimated Time:** 65 Minutes (15 concepts, 5 setup, 35 lab, 10 quiz)  
**Theme:** On BIG-IP, caching is a Web Acceleration profile attached to a virtual server. In NGINX it's a cache zone you declare once and switch on per `location`. NGINX caches **less** than you'd expect by default (nothing without an explicit lifetime), and in one place **more** than the HTTP spec allows (it ignores `Authorization`).

---

## 1. Concepts to Understand (15 Minutes)

### 1.1 Where the Cache Lives

| BIG-IP Web Acceleration | NGINX | Notes |
| :--- | :--- | :--- |
| Web Acceleration profile on a virtual server | `proxy_cache_path` (once, at `http` level) plus `proxy_cache ZONE` in a `location` | One cache can serve many locations and servers |
| RAM cache size | **Two** limits: `keys_zone` (shared memory) and `max_size` (disk) | Whichever fills first starts evicting (below) |
| Cache URI include/exclude lists | `proxy_cache_bypass`, `proxy_no_cache`, or a `location` without `proxy_cache` | 1.4 |
| Max age / min age | Origin headers first, then `proxy_cache_valid` | 1.2 |
| Invalidation (manual or iControl) | **Not in open source NGINX.** NGINX Plus has `proxy_cache_purge` | Day 3 side quest |

**One cache, two halves**
* **The keys zone** is shared memory that every worker reads. It holds one small node per entry: the hashed key, how long it's valid, and its place in the LRU list. About **8,000 keys fit in 1 MB**.
* **The bodies are files on disk**, under the `proxy_cache_path` directory. `levels=1:2` spreads them over subdirectories named after the last characters of the key's MD5 hash. Hot files stay in the Linux page cache, so a "disk" cache serves mostly from RAM.
* **When the keys zone is full**, NGINX evicts the least recently used entries and deletes their files. That happens even when the disk is nearly empty, and **nothing is logged**. A zone sized too small looks exactly like a low hit ratio.
* **Two helper processes** sit next to the workers:
  * The **cache manager** enforces `max_size` and `inactive`.
  * The **cache loader** rebuilds the keys zone from the files on disk after a start. It runs in the background, and until it's done a worker that misses in the zone checks the disk itself. So a restart doesn't empty the cache.
* **`inactive` is not the lifetime.** An entry nobody requested for `inactive` (default 10 minutes) is deleted, even if it's still fresh. An expired entry that *is* still requested stays on disk, and Day 2 serves it as a stale copy.
* **`use_temp_path=off`** writes the response straight into the cache directory instead of copying it from `proxy_temp_path`. Use it unless the temp path is on a faster disk.

### 1.2 What NGINX Will Cache, and for How Long
NGINX looks at the origin's response headers first, in this order:

| Priority | Header from the origin | Effect |
| :---: | :--- | :--- |
| 1 | `X-Accel-Expires: N` | Cache for N seconds. `0` means "don't cache". NGINX-only, and it overrides everything below. |
| 2 | `Cache-Control` | `max-age` / `s-maxage` set the lifetime. **`no-store`, `no-cache` and `private` mean "don't cache".** |
| 2 | `Expires` | A lifetime as a date (`Cache-Control` wins if both are present) |
| 3 | *(none of the above)* | `proxy_cache_valid`, **for the status codes it lists**. Without it, the response isn't cached at all. |

**Not cached, whatever the lifetime says**
* A response that sets a cookie (`Set-Cookie`).
* A response with `Vary: *`.
* Methods other than `GET` and `HEAD`.

**Things that surprise people**
* **No lifetime, no cache.** Browsers guess a lifetime from `Last-Modified`. NGINX doesn't: an origin that sends no caching headers is never cached until you set `proxy_cache_valid`.
* **Origin headers beat `proxy_cache_valid`,** in both directions. `max-age=2` from the origin shortens your one-minute rule. `max-age=60` on a **503** caches the error, even though `proxy_cache_valid` only lists 200.
* **Lifetimes are counted in whole seconds.** An entry with `max-age=2` expires 2 to 3 seconds after it was stored.
* `proxy_ignore_headers Cache-Control Expires Set-Cookie` tells NGINX to stop listening to the origin. Sometimes that's needed, but it's also how per-user pages end up in a shared cache.

### 1.3 The Cache Key
* **The default key is `$scheme$proxy_host$request_uri`.** `$proxy_host` is the name in `proxy_pass` (here, the `upstream` called `origin`), **not** the host the client asked for. Every host name behind this `location` shares one entry per path.
* **The `Host` the origin sees** is also `$proxy_host` by default (Sprint 2). The origin can't tell tenants apart either.
* **Fixing only one of the two is worse than fixing neither.** If the origin receives the client's `Host` but the key ignores it:
  * the first tenant's page is cached under a host-free key;
  * the second tenant then gets **the first tenant's page**.
* **Put `$host` in the key** whenever the response depends on the host name. `$host` is lowercased, so `A.Lumina.Local` and `a.lumina.local` share an entry, as they should.
* **The query string is part of `$request_uri`.** `?a=1&b=2` and `?b=2&a=1` are two entries.

### 1.4 Who Gets a Cached Answer
**NGINX ignores `Authorization`.** The HTTP caching rules (RFC 9111) say a shared cache must not reuse a response to a request that carried `Authorization`, unless the origin explicitly allows it. NGINX doesn't apply that rule:
* Alice's personalized response is stored like any other.
* The next anonymous client, or Bob, gets Alice's copy.

Two directives fix it, and they control different things:

| Directive | Controls | When its value is non-empty and not `0` |
| :--- | :--- | :--- |
| `proxy_cache_bypass` | **Reading** | Don't answer this request from cache; go to the origin (`X-Cache-Status: BYPASS`) |
| `proxy_no_cache` | **Writing** | Don't store this response |

* **Bypass alone still writes.** The origin's answer to Alice's bypassed request replaces the shared entry, and the next anonymous client gets Alice's page.
* **No-cache alone still reads.** Alice is served the anonymous copy.
* For authenticated traffic you almost always want **both**, keyed on the same variable.
* The same applies to session **cookies in the request**. NGINX ignores them too.

### 1.5 Reading the Result
`$upstream_cache_status` says what the cache did for the request:

| Value | Meaning |
| :--- | :--- |
| `MISS` | Not in cache; fetched from the origin (and stored, if cacheable) |
| `HIT` | Served from cache; the origin wasn't contacted |
| `EXPIRED` | In cache but expired; fetched again from the origin |
| `BYPASS` | `proxy_cache_bypass` matched; fetched from the origin |
| `STALE`, `UPDATING`, `REVALIDATED` | Day 2 |
| *(empty)* | No cache on this location |

* **Expose it as a response header with `always`.** Without `always`, `add_header` skips 404s, 5xx and other error statuses (Sprint 3 Day 3), and errors are exactly the responses you'll want to explain.
* **Log it.** The Day 1 config already writes `cache=$upstream_cache_status` in the access log.
* **A cache with no `$upstream_cache_status` anywhere is a cache you can't debug.**

---

## 2. Lab Setup (5 Minutes)

Sprint 4 runs NGINX in a container (`nginx:mainline`, nginx 1.31.6, OpenSSL 3.5), not on the host. `lab.sh` starts the edge and a slow, countable origin on a private Docker network. The host's NGINX stays stopped.

```bash
cd /srv/nginx-journey/sprints/sprint-4/lab
cp day1_nginx.conf nginx.conf           # edge on 8084 -> origin, no cache yet
./lab.sh up                             # origin + edge, then the ready check
source helpers.sh                       # r, rr, burst, seen, key: re-run in every new terminal
```
The ready check ends with `Sprint 4 lab ready: edge :8084 -> s4-origin:8014`. If it doesn't, fix the `[!!]` lines before going on.

**The origin** (`lab/origin.py`) answers any path with a small JSON document: the URI, the `Host` it received, and **how many times that URI has reached it** (`origin_hits`). When the edge serves from cache, that number stops moving. Query parameters make it misbehave:

| Parameter | The origin... |
| :--- | :--- |
| `?cc=max-age=60` | sends that `Cache-Control` (`no-store`, `private`, ...) |
| `?expires=60` / `?accel=60` | sends `Expires` / `X-Accel-Expires` |
| `?cookie=1` / `?vary=*` | sends `Set-Cookie` / that `Vary` |
| `?status=503` / `?delay=2` | answers with that status / waits that long |

| Command | What it does |
| :--- | :--- |
| `r PATH [curl args]` | One request, one line: `200  cache=HIT  origin_hits=1  host=...  0.00s` |
| `rr N PATH [curl args]` | The same request N times |
| `key PATH` | The cache file(s) for PATH and the `KEY:` line stored in each |
| `./lab.sh reload` | `nginx -t`, reload, wait a second for the new workers |
| `./lab.sh stats` / `./lab.sh reset` | The origin's counters / zero them |
| `./lab.sh workers` | The edge's processes as host PIDs |

---

## 3. Hands-on Guided Discovery Activities (35 Minutes)

Every activity edits `nginx.conf` (the file in `lab/`; the container sees it directly). After each edit, run `./lab.sh reload`.

### Activity 3.1: First Contact (3 min)
```bash
rr 3 /courses/1
./lab.sh stats
```
* `origin_hits` climbs 1, 2, 3: every request reaches the origin. `cache=-` means there's no `X-Cache-Status` header yet.
* The origin saw `host=origin`, not `localhost:8084`.

<details>
<summary>Why <code>origin</code>?</summary>

`proxy_pass http://origin;` names the `upstream` group, and by default NGINX sends `Host: $proxy_host`, which is that name. Concept 1.3 shows why this matters for the cache key too.
</details>

### Activity 3.2: Turn the Cache On (7 min)
Add the cache zone at `http` level, above `upstream origin`:
```nginx
proxy_cache_path cache/lumina levels=1:2 keys_zone=lumina:10m max_size=1g inactive=10m use_temp_path=off;
```
and, inside `location /` under `proxy_pass`:
```nginx
proxy_cache lumina;
add_header X-Cache-Status $upstream_cache_status always;
```
```bash
./lab.sh reload
rr 3 /courses/2
```
Predict before you run it: the origin sends no caching headers. Will the second request be a `HIT`?

<details>
<summary>Result</summary>

`MISS MISS MISS`, and `origin_hits` keeps climbing. With no lifetime from the origin and no `proxy_cache_valid`, NGINX doesn't store the response (concept 1.2).
</details>

Now let the origin say how long:
```bash
rr 2 '/courses/3?cc=max-age=60'          # MISS, then HIT with origin_hits=1
rr 2 '/courses/4?expires=60'             # same, from an Expires date
key /courses/3                           # where it lives, and the key it was stored under
./lab.sh workers                         # two workers, a cache manager, and (for its first minute or so) a cache loader
```
Then give everything else a default lifetime. Add under `proxy_cache lumina;`:
```nginx
proxy_cache_valid 200 1m;
```
```bash
./lab.sh reload
rr 2 /courses/2                          # MISS, then HIT
```

### Activity 3.3: Who Decides the Lifetime (7 min)
Predict each pair, then run it.
```bash
r '/p/1?cc=max-age=2'; sleep 4; r '/p/1?cc=max-age=2'      # a: 2 s from the origin vs your 1 m
rr 2 '/p/2?cc=max-age=60&accel=0'                         # b: two origin headers disagree
for q in cc=no-store cc=private cookie=1 'vary=*'; do echo "== $q"; rr 2 "/p/3?$q"; done   # c
rr 2 '/p/4?status=404'                                    # d: a 404 with no caching headers
rr 2 '/p/5?status=503&cc=max-age=60'                      # e: a 503 that says max-age=60
```
<details>
<summary>Results</summary>

* **a.** `MISS`, then `EXPIRED`. The origin's `max-age=2` beats `proxy_cache_valid 200 1m`.
* **b.** `MISS MISS`. `X-Accel-Expires: 0` outranks `Cache-Control: max-age=60`.
* **c.** `MISS MISS` for all four. `no-store`, `private`, `Set-Cookie` and `Vary: *` are never stored.
* **d.** `MISS MISS`. `proxy_cache_valid 200 1m` doesn't cover 404s.
* **e.** `MISS`, then **`HIT` on a 503**. The origin's header made an error cacheable, and for the next minute every client gets the cached outage. If an origin's error pages carry caching headers, use `proxy_cache_valid` and `proxy_ignore_headers` deliberately, or strip the headers at the origin.
</details>

### Activity 3.4: Host Names and the Key (7 min)
```bash
r /h/1 -H 'Host: a.lumina.local'
r /h/1 -H 'Host: b.lumina.local'
```
`b` gets a `HIT` on `a`'s entry, and both show `host=origin`. Fix only the `Host` first. Add under `proxy_pass`:
```nginx
proxy_set_header Host $host;
```
```bash
./lab.sh reload
r /h/2 -H 'Host: a.lumina.local'
r /h/2 -H 'Host: b.lumina.local'
key /h/2
```
What did `b.lumina.local` receive?

<details>
<summary>Answer</summary>

`HIT` with `host=a.lumina.local`: **tenant B was served tenant A's page.** The origin now builds per-host pages, but the key (`KEY: http://origin/h/2`) still has no host in it. That's the trap from concept 1.3, and it's worse than the default.
</details>

Now put the host in the key. Add under `proxy_cache lumina;`:
```nginx
proxy_cache_key $scheme$host$request_uri;
```
```bash
./lab.sh reload
r /h/3 -H 'Host: a.lumina.local'          # MISS, host=a
r /h/3 -H 'Host: b.lumina.local'          # MISS, host=b
r /h/3 -H 'Host: A.Lumina.Local'          # HIT, host=a: $host is lowercased
key /h/3                                  # two files, two KEY lines
r '/h/4?a=1&b=2'; r '/h/4?b=2&a=1'        # same parameters, different order: two MISSes
```

### Activity 3.5: Authorization (7 min)
```bash
r /a/1 -H 'Authorization: Bearer alice'
r /a/1                                    # anonymous
r /a/1 -H 'Authorization: Bearer bob'
```
Both later requests get a `HIT` on Alice's response (`origin_hits=1`). Add bypass only, under the cache lines:
```nginx
proxy_cache_bypass $http_authorization;
```
```bash
./lab.sh reload
r /a/2                                    # anonymous: MISS, stored
r /a/2 -H 'Authorization: Bearer alice'   # BYPASS: Alice goes to the origin
r /a/2                                    # anonymous again: whose copy is this?
```
<details>
<summary>Answer</summary>

`HIT` with `origin_hits=2`, which is **Alice's** response. Bypass only stops the cache from *answering* Alice. Her response was still *stored* and replaced the anonymous entry.
</details>

Add the write side too:
```nginx
proxy_no_cache $http_authorization;
```
```bash
./lab.sh reload
r /a/3 -H 'Authorization: Bearer alice'   # BYPASS
r /a/3                                    # MISS: nothing of Alice's was stored
r /a/3                                    # HIT
r /a/3 -H 'Authorization: Bearer alice'   # BYPASS: Alice never gets the shared copy
```

### Activity 3.6: The Zone, the Disk and a Restart (4 min)
```bash
r /courses/9                              # MISS: cached now, fresh for a minute
./lab.sh edge                             # recreate the edge container: new processes, same cache/ directory
r /courses/9                              # still a HIT
```
Now shrink the keys zone to 32 KB (`keys_zone=lumina:32k`), reload, and request 400 different URLs:
```bash
./lab.sh reload
for i in $(seq 400); do curl -s -o /dev/null "http://127.0.0.1:8084/z/$i"; done
find cache/lumina -type f | wc -l         # far fewer than 400
r /z/1                                    # evicted: MISS
r /z/400                                  # HIT
grep -ciE 'alloc|evict|forced' logs/error.log   # any warning about it?
```
<details>
<summary>What happened</summary>

* The 32 KB zone held only about 200 keys. Older entries were evicted and **their files deleted**, with `max_size=1g` nowhere near full.
* The error log has no line about it.
* The only symptom is a lower hit ratio, so size `keys_zone` for the number of objects (about 8,000 per MB), not the bytes.
</details>

Set it back to `keys_zone=lumina:10m` and reload.

---

## 4. Day 1 Concept Examination (10-Question Randomized Quiz)

```bash
cd /srv/nginx-journey && python3 -m http.server 8090
```
👉 **http://&lt;lab-host&gt;:8090/quiz.html?sprint=4&day=1**

---

## 5. Key Takeaways for Day 1
* **A cache is a keys zone in shared memory plus files on disk.** Whichever fills first evicts, silently. Size the zone by object count.
* **No lifetime, no cache.** Origin headers come first (`X-Accel-Expires`, then `Cache-Control` / `Expires`). `proxy_cache_valid` is only the fallback, and only for the statuses it lists.
* **Origin headers can make anything cacheable,** including a 503.
* **The default key has no client host in it.** Send `Host $host` *and* put `$host` in the key, or tenants share pages.
* **NGINX ignores `Authorization` and request cookies.** `proxy_cache_bypass` stops reads, `proxy_no_cache` stops writes, and you need both.
* **`X-Cache-Status` with `always`, and the cache status in the access log,** before anything else.

# Sprint 4 &bull; Day 2: The Cache Under Pressure
**Day:** 2 of 3  
**Estimated Time:** 65 Minutes (15 concepts, 3 setup, 37 lab, 10 quiz)  
**Theme:** Day 1's cache is correct, but only on a calm day. Caches fail at the edges of time: the moment an entry expires, the first second after a deploy, the minute the origin falls over. Today makes the cache protect the origin and the users at exactly those moments.

---

## 1. Concepts to Understand (15 Minutes)

### 1.1 The Thundering Herd
A popular URL expires, or the cache is cold after a deploy. Every request that arrives before the first origin answer is back is a **miss**, and every miss goes to the origin.
* 500 requests per second for a page that takes 2 seconds to render means **1,000 origin requests** for one page, at the moment the origin is least able to take them.
* **`proxy_cache_lock on`** lets **one** request per key fetch from the origin. The others wait for it and are then served from the new entry.
* **The lock only covers new entries.** When an entry **expires**, every request that finds it expired goes to the origin, lock or no lock. Collapsing refreshes is the job of `proxy_cache_use_stale updating` (1.3).

**The lock has two timers, both 5 seconds by default**
* **`proxy_cache_lock_timeout`** is how long a waiting request waits. After that it goes to the origin **itself**, and its response is **not cached**. If the origin regularly takes longer than the timeout, the lock gives you nothing.
* **`proxy_cache_lock_age`** is how long the one fetching request holds the lock before NGINX lets **one more** request go to the origin. For an origin slower than 5 seconds, both timers need raising.

**BIG-IP lens:** this is request collapsing (coalescing) at the edge. With NGINX it's opt-in, per location, and off by default.

### 1.2 Serving Stale Copies
An expired entry isn't deleted right away. It stays on disk until `inactive` passes or the cache manager evicts it (Day 1). While it's there, NGINX can serve it **stale** instead of failing or waiting.

`proxy_cache_use_stale` lists when that's allowed:

| Condition | Covers |
| :--- | :--- |
| `error` | Couldn't connect, connection reset, or the origin closed without answering |
| `timeout` | `proxy_connect_timeout` / `proxy_read_timeout` ran out |
| `http_500` `http_502` `http_503` `http_504` (also `http_403` `http_404` `http_429`) | The origin **answered**, with that status. Each one has to be listed. |
| `updating` | Another request is already refreshing this entry (1.3) |

* A **5xx response isn't an `error`.** `error` alone still passes the origin's 503 to the client.
* **Stale only helps URLs that are already in the cache.** A URL nobody requested before the outage still gets a 502.
* The client sees `X-Cache-Status: STALE` and a 200. Monitoring that counts only status codes won't notice the outage. Counting `STALE` in the access log will.

**The origin can ask for it too.** NGINX honors two `Cache-Control` extensions, with lower priority than `proxy_cache_use_stale`:
* `stale-while-revalidate=N` acts like `updating` for N seconds after expiry.
* `stale-if-error=N` acts like `error timeout` for N seconds. A 503 **response** still isn't covered.

### 1.3 Who Waits for the Refresh
`updating` only helps the **other** requests. The request that found the entry expired is the one doing the refresh, so it still waits for the origin:

| Config | First request after expiry | Requests during the refresh |
| :--- | :--- | :--- |
| Nothing (`proxy_cache_lock` doesn't apply to expired entries) | Waits for the origin (`EXPIRED`) | Also go to the origin (`EXPIRED`): a herd |
| `use_stale updating` | Waits for the origin (`EXPIRED`) | Stale copy at once (`UPDATING`) |
| `use_stale updating` + **`proxy_cache_background_update on`** | Stale copy at once (`STALE`) | Stale copy at once (`UPDATING`) |

* With background update, NGINX refreshes the entry in a **subrequest** and nobody waits for a slow origin, as long as a stale copy exists.
* Background update needs `updating` in `proxy_cache_use_stale`. On its own it does nothing.

### 1.4 Revalidation
Every 200 from the lab origin carries an `ETag` and a `Last-Modified`.
* **`proxy_cache_revalidate on`** makes the refresh of an expired entry a **conditional** request, with `If-None-Match` and `If-Modified-Since`.
* If the object hasn't changed, the origin answers **304 Not Modified**, with no body. NGINX extends the entry's life and serves the copy it already has (`REVALIDATED`).
* That saves origin CPU and bandwidth for large objects that rarely change.
* **With background update, the client never sees `REVALIDATED`.** The client got `STALE`, and the 304 happened in the subrequest, which isn't logged by default. Only the origin's counters show it.

### 1.5 Measuring It
* **`oha`** is an HTTP load generator. `./lab.sh load` runs it in a container **on the lab network**, aimed at the edge. That keeps Docker's port forwarding out of the numbers.
* **The numbers to watch:**
  * requests per second;
  * the **slowest** response (averages hide a herd);
  * how many requests the **origin** saw (`./lab.sh stats`);
  * the mix of `cache=` values in the access log.
* **A cache's worth is the ratio** between what the clients sent and what the origin saw.

---

## 2. Lab Setup (3 Minutes)

If the lab is down (`./lab.sh check` says so), start it with Day 2's config. Otherwise, swap the config in:
```bash
cd /srv/nginx-journey/sprints/sprint-4/lab
cp day2_nginx.conf nginx.conf           # Day 1's result: a correct cache, no protection under pressure
./lab.sh check >/dev/null 2>&1 && ./lab.sh reload || ./lab.sh up
source helpers.sh
```

| New today | What it does |
| :--- | :--- |
| `burst N PATH` | N requests at the same moment; prints the status codes, the wall time, and how many reached the origin |
| `seen PATH` | How many times that exact URI has reached the origin |
| `./lab.sh mode delay=3` / `status=503` / `drop=1` | Every origin answer is now slow / a 503 / a dropped connection. `./lab.sh mode` returns to normal. |
| `./lab.sh load [oha args] PATH` | Load test from inside the lab network. `-z 5s` for a duration, `-c 50` for concurrency |

> **Always end a failure experiment with `./lab.sh mode`.** Until you do, the origin keeps failing every request.

---

## 3. Hands-on Guided Discovery Activities (37 Minutes)

Every activity edits `location /` in `nginx.conf`. After each edit, run `./lab.sh reload`.

The cache keeps what earlier runs stored. If you repeat an activity, change the number in the URL (`/s/2` → `/s/12`), or an old entry changes the result.

### Activity 3.1: What the Cache Is Worth (5 min)
```bash
./lab.sh reset
./lab.sh load -z 5s -c 50 '/l/1?cc=max-age=60'                     # cacheable
seen '/l/1?cc=max-age=60'
./lab.sh load -z 5s -c 50 -H 'Authorization: Bearer x' /l/2        # bypasses the cache (Day 1)
seen /l/2
```
Compare the two runs' `Requests/sec` and the origin counts.

<details>
<summary>Typical result</summary>

About **45,000** requests per second with the origin seeing the URL **once**, against about **800** requests per second with **every** request reaching the origin. The difference is roughly 50x, and it all comes from where the answer is produced.
</details>

### Activity 3.2: The Stampede (7 min)
```bash
burst 20 '/s/1?delay=2'
```
Twenty clients, one uncached URL, a two-second origin. The origin saw it **20 times**. Add to `location /`:
```nginx
proxy_cache_lock on;
```
```bash
./lab.sh reload
burst 20 '/s/2?delay=2'                   # origin saw it once; all 20 got a 200 in about 2 s
burst 20 '/s/3?delay=7'                   # an origin slower than the lock timeout
grep -a '/s/3' logs/access.log | awk '{ print $NF }' | sort | uniq -c
```
<details>
<summary>What happened with <code>delay=7</code>?</summary>

* The origin saw it **20 times**, the burst took about 12 seconds, and all 20 log lines say `MISS`.
* The waiters gave up after `proxy_cache_lock_timeout` (5 s) and each went to the origin **itself**. Their responses aren't cached, so the lock protected nothing.
* For an origin this slow, raise **both** `proxy_cache_lock_timeout` and `proxy_cache_lock_age` above its slowest normal response. Raising only the timeout to 10 s still lets a second request through at 5 s (`lock_age`): 2 origin requests and a 12-second burst. With both at 10 s: 1 origin request and 7 seconds.
</details>

### Activity 3.3: When the Origin Fails (7 min)
```bash
r '/f/1?cc=max-age=1'; sleep 3            # cached, then expired
./lab.sh mode drop=1;     r '/f/1?cc=max-age=1'
./lab.sh mode status=503; r '/f/1?cc=max-age=1'
./lab.sh mode
```
The client gets the failure both times: a 502 when the connection drops, and the origin's 503. A perfectly good expired copy sat on disk. Add:
```nginx
proxy_cache_use_stale error timeout http_500 http_502 http_503 http_504;
```
```bash
./lab.sh reload
r '/f/2?cc=max-age=1'; sleep 3
./lab.sh mode drop=1;     r '/f/2?cc=max-age=1'      # STALE, 200
./lab.sh mode status=503; r '/f/2?cc=max-age=1'      # STALE, 200
./lab.sh mode drop=1;     r /f/never-cached          # ?
./lab.sh mode
```
<details>
<summary>The last one</summary>

`502 cache=MISS`. There's nothing stale to serve for a URL that was never cached. Stale protects popular content, not everything.
</details>

*Try it (optional):* remove `http_503` from the list, reload, and repeat the 503 case. You get the origin's 503 again: `error` doesn't cover a 5xx **answer**.

### Activity 3.4: Nobody Waits for a Slow Refresh (8 min)
**a. A slow origin, an expired entry:**
```bash
r '/u/1?cc=max-age=1'; sleep 3
./lab.sh mode delay=3
( r '/u/1?cc=max-age=1' & sleep 0.3; r '/u/1?cc=max-age=1'; wait )
./lab.sh mode
```
Both requests wait 3 seconds, and both reach the origin (`origin_hits=2` and `3`). Why didn't 3.2's lock collapse them?

<details>
<summary>Answer</summary>

`proxy_cache_lock` only applies when a **new** entry is being filled. These requests found an **expired** entry, and NGINX doesn't lock refreshes. Concept 1.3 shows what does collapse them.
</details>

**b. Add `updating`** to the end of the `proxy_cache_use_stale` list, reload, and repeat on `/u/2`:
```bash
./lab.sh reload
r '/u/2?cc=max-age=1'; sleep 3
./lab.sh mode delay=3
( r '/u/2?cc=max-age=1' & sleep 0.3; r '/u/2?cc=max-age=1'; wait )
./lab.sh mode
```
Which of the two requests still waited?

<details>
<summary>Answer</summary>

The second one gets `UPDATING` at once. The first, which **found** the entry expired and is refreshing it, still shows `EXPIRED` after 3.00 s. `updating` only helps everybody else.
</details>

**c. Refresh in the background.** Add:
```nginx
proxy_cache_background_update on;
```
```bash
./lab.sh reload
r '/u/3?cc=max-age=1'; sleep 3
./lab.sh mode delay=3
r '/u/3?cc=max-age=1'                     # STALE, 0.00s
r '/u/3?cc=max-age=1'                     # UPDATING: the refresh is still running
./lab.sh mode; sleep 3.5
r '/u/3?cc=max-age=1'                     # HIT, origin_hits=2: refreshed behind the scenes
```

### Activity 3.5: Revalidation (4 min)
Add:
```nginx
proxy_cache_revalidate on;
```
```bash
./lab.sh reload
./lab.sh reset
r '/v/1?cc=max-age=1'; sleep 3
r '/v/1?cc=max-age=1'                     # what does the client see?
./lab.sh stats                            # not_modified, and by_uri for /v/1
```
<details>
<summary>Where's the <code>REVALIDATED</code>?</summary>

* The client got `STALE`, because background update served it the old copy right away.
* The refresh was a conditional request in a subrequest, which the access log doesn't record. The origin's counters show it: `not_modified: 1`, and `by_uri` still counts **one** full response for `/v/1`.
* To see `REVALIDATED` in `X-Cache-Status`, remove `proxy_cache_background_update on;` for a moment and repeat. Put it back afterwards.
</details>

### Activity 3.6: The Herd Under Load, Before and After (6 min)
A one-second origin, a two-second lifetime, 50 clients for 10 seconds. First with today's config:
```bash
./lab.sh reset; ./lab.sh mode delay=1
./lab.sh load -z 10s -c 50 '/l/9?cc=max-age=2'
./lab.sh mode; seen '/l/9?cc=max-age=2'
grep -a '/l/9' logs/access.log | awk '{ print $NF }' | sort | uniq -c
```
Then put Day 2's starting point back and repeat on a new URL:
```bash
cp nginx.conf my_day2_nginx.conf          # keep your work
cp day2_nginx.conf nginx.conf && ./lab.sh reload
./lab.sh reset; ./lab.sh mode delay=1
./lab.sh load -z 10s -c 50 '/l/10?cc=max-age=2'
./lab.sh mode; seen '/l/10?cc=max-age=2'
grep -a '/l/10' logs/access.log | awk '{ print $NF }' | sort | uniq -c
cp my_day2_nginx.conf nginx.conf && ./lab.sh reload
```
<details>
<summary>Typical result</summary>

| | Origin saw | Slowest response | Log |
| :--- | :---: | :---: | :--- |
| Today's config | **3** | 1.5 s (the very first, cold miss) | Mostly `HIT` and `UPDATING`, one `MISS`, a couple of `STALE` |
| Day 2 start | **107** | 2.5 s | 57 `MISS` and 50 `EXPIRED` all at once |

Requests per second are close in both runs. **The difference is in the tail and at the origin,** which is why you watch the slowest response and the origin count, not the average.
</details>

---

## 4. Day 2 Concept Examination (10-Question Randomized Quiz)

👉 **http://&lt;lab-host&gt;:8090/quiz.html?sprint=4&day=2** (serve with `cd /srv/nginx-journey && python3 -m http.server 8090`)

---

## 5. Key Takeaways for Day 2
* **`proxy_cache_lock` turns a herd of misses into one origin request,** but only for new entries, and only for as long as `proxy_cache_lock_timeout`. Waiters that time out go to the origin and aren't cached. Expired entries need `updating`.
* **Expired isn't gone.** `proxy_cache_use_stale` serves the old copy on `error`/`timeout`, and on 5xx answers **only if each status is listed**.
* **Stale protects what's already cached.** A never-cached URL still fails.
* **`updating` spares everyone except the refresher.** `proxy_cache_background_update` spares the refresher too.
* **`proxy_cache_revalidate` turns refreshes into 304s.** Background refresh hides them from the access log.
* **Measure the tail and the origin,** not the average.

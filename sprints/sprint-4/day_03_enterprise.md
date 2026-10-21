# Sprint 4 &bull; Day 3 (Optional) Enterprise Side Quest: Purge on Demand, Cache Metrics
**Day:** Optional, after Day 3  
**Estimated Time:** 40 Minutes (10 concepts, 5 setup, 25 hands-on)  
**Theme:** Days 1 and 2 decided how long a copy lives. Sometimes it has to go **now**: a wrong price, a legal takedown, a broken deploy. Open source NGINX can't remove a cached object on request. NGINX Plus can, and its API reports what the cache is doing.

> **Status:** run end to end on the lab box on NGINX Plus R37.1.1 (API version 10), on scratch ports. The commands below use the lab's real ports.

---

## 1. Concepts to Understand (10 Minutes)

### 1.1 Invalidation Without NGINX Plus
Open source NGINX has no "remove this object" operation. The usual workarounds:

| Approach | How | Catch |
| :--- | :--- | :--- |
| Short lifetimes plus stale (Day 2) | `max-age` of seconds, `use_stale updating` + background update | A change still takes up to one lifetime to show |
| **Versioned URLs** | `/app.4f2c1.js`: a new deploy means a new URL, so a new key | The best answer for static assets; it doesn't help for a fixed URL like a price page |
| **Refresh through bypass** | `proxy_cache_bypass $http_x_refresh;`, then send that header for the URL | Works because bypassed responses are **stored** (Day 1, 3.5). Anyone who can send the header can push load onto your origin, so restrict it. It replaces one URL at a time, with no wildcards. |
| Delete cache files by hand | Find the file whose `KEY:` matches and remove it | Unsupported, and per node |

### 1.2 `proxy_cache_purge` (NGINX Plus)
* **What it does:** a request for which the `proxy_cache_purge` value is non-empty and not `0` **removes the entry whose key that request would have used**. The response is `204 No Content`.
* **A 204 doesn't prove anything was removed.** NGINX answers 204 even when no entry matched: a key that was never cached, or a purge sent with the wrong `Host`. The only confirmation is the next request being a `MISS`.
* **How it's usually wired:** a `map` on `$request_method` that turns the conventional `PURGE` method into `1`. `PURGE` isn't a standard HTTP method; it's a convention that caches share.
* **The key is computed from the purge request,** with the same `proxy_cache_key`. With Day 1's `$scheme$host$request_uri`, a purge sent with a different `Host`, or with the query parameters in a different order, targets a different entry.
* **Wildcards:** if the key of the purge request ends in `*`, every entry whose key starts with the part before the `*` is purged. `PURGE /courses/*` takes the whole section.
* **`purger=on`** on `proxy_cache_path` is about the **disk**. Wildcard purges take effect right away with or without it: the next request is a `MISS`. Without it, the purged files stay on disk until they're replaced or age out. With it, a background **cache purger** process walks the cache and deletes them. In the lab, the files went 20 seconds to a minute after the purge.
* **Lock it down.** Purge is a cheap way to force misses, so restrict it to management addresses or require a credential.
* **Purge is per instance.** Each NGINX node has its own cache. A fleet needs the purge sent to every node, and the cache contents aren't shared between cluster members.

**BIG-IP lens:** this is the counterpart of invalidating Web Acceleration cache content through `tmsh` or iControl REST. The difference is that the purge request goes through the **data plane**, as an HTTP request to the virtual server itself, controlled by your config.

### 1.3 Cache Metrics in the Plus API
The NGINX Plus API reports each cache zone under `/api/VERSION/http/caches/ZONE`:
* `size` and `max_size`, and `cold`, which is `true` while the cache loader is still indexing the disk after a start (about the first minute);
* counters per outcome: `hit`, `stale`, `updating`, `revalidated`, `miss`, `expired`, `bypass`, each with `responses` and `bytes`.

These are the same outcomes as `X-Cache-Status`, already counted for you. **Hit ratio** is `hit / (hit + miss + expired + bypass + ...)` over an interval. The dashboard's **Caches** tab shows the same data.

**The API reports on the cache. It doesn't purge it.** Purging is the HTTP request in 1.2.

---

## 2. Setup (5 Minutes)

### A.0 One-Time Plus Setup, per [`docs/nginx-plus-lab.md`](../../docs/nginx-plus-lab.md)
If your license has expired (`[emerg] license expired` in `docker logs`), download a new JWT from MyF5, replace `~/plus/license.jwt`, and run the `docker login` from the Plus lab doc again.

| | Open source lab | This side quest |
| :--- | :--- | :--- |
| Engine | `s4-edge` container (`nginx:mainline`) | `lumina-cache-plus` container from `$PLUS_IMAGE`, `--network host` |
| Config | `lab/nginx.conf` | `lab/plus/nginx.conf` → `/etc/nginx/nginx.conf` |
| Traffic | 8084 | **8086** |
| Origin | `s4-origin:8014` on the lab network | `127.0.0.1:8014`, the same origin, published on the host |
| API / dashboard | none | `127.0.0.1:8085` |

The Plus edge uses the same origin, so the open source lab must be up:
```bash
cd /srv/nginx-journey/sprints/sprint-4/lab
./lab.sh check >/dev/null 2>&1 || ./lab.sh up
source helpers.sh && source ~/plus/plus.env
chmod 777 plus/state
docker run -d --name lumina-cache-plus --network host \
  --mount type=bind,src="$PWD/plus/nginx.conf",dst=/etc/nginx/nginx.conf,readonly \
  --mount type=bind,src="$HOME/plus/license.jwt",dst=/etc/nginx/license.jwt,readonly \
  --mount type=bind,src="$PWD/plus/state",dst=/var/lib/nginx/state \
  "$PLUS_IMAGE"
until curl -s http://127.0.0.1:8085/api/ | grep -q '^\['; do sleep 1; done
V=$(curl -s http://127.0.0.1:8085/api/ | jq '.[-1]'); echo "Plus API version $V"
api() { curl -s "http://127.0.0.1:8085/api/$V$1" "${@:2}"; echo; }
cachestats() { api /http/caches/lumina | jq -c '{cold, size, hit: .hit.responses, miss: .miss.responses, expired: .expired.responses, bypass: .bypass.responses}'; }
export EDGE=127.0.0.1:8086                # r, rr and seen now talk to the Plus edge
```

---

## 3. Hands-on (25 Minutes)

### A.1 The Cache in the API (5 min)
```bash
cachestats
rr 3 /courses/1
rr 2 /courses/2
cachestats
api /http/caches/lumina | jq .
```
* `miss` went up by 2 and `hit` by 3. Compare that with what `r` printed.
* `cold` is `true` for about the first minute after the container starts, until the cache loader has finished. Run `cachestats` again later and it's `false`.
* Open `http://<lab-host>:8085/dashboard.html` through an SSH tunnel (the API listens on loopback only) and find the **Caches** tab.

*Journal:* which of these counters would you put on a dashboard for the origin team, and which for the edge team?

<details>
<summary>One reasonable split</summary>

* **The origin team** cares about what reaches them: `miss`, `expired` and `bypass` per second, since that's their load.
* **The edge team** cares about the hit ratio, `stale` (served from cache because the origin was failing, which is an outage the users didn't see), and `size` against `max_size`.
</details>

### A.2 Purge One URL (6 min)
```bash
r /courses/1                                                  # HIT
curl -s -o /dev/null -w '%{http_code}\n' -X PURGE http://127.0.0.1:8086/courses/1
r /courses/1                                                  # MISS, origin_hits goes up
r /courses/1                                                  # HIT again
```
Both purge requests in this activity print `204`. Now purge with a different host name, and check whether the entry is gone:
```bash
curl -s -o /dev/null -w '%{http_code}\n' -X PURGE -H 'Host: other.example' http://127.0.0.1:8086/courses/1
r /courses/1
```
<details>
<summary>Why is it still a <code>HIT</code>?</summary>

The purge request's key was `httpother.example/courses/1`. The cached entry's key is `http127.0.0.1/courses/1` (`$host` drops the port). A purge has to produce **the same key** as the requests that filled the entry, which is Day 1's key design coming back.

The purge still answered `204`. NGINX doesn't tell you whether anything matched, so check with a request afterwards.
</details>

### A.3 Purge a Section (6 min)
```bash
for i in $(seq 10); do r /courses/$i >/dev/null; r /courses/$i >/dev/null; done
rr 2 /about
docker exec lumina-cache-plus find /var/cache/nginx/lumina -type f | wc -l     # files on disk
curl -s -o /dev/null -w '%{http_code}\n' -X PURGE 'http://127.0.0.1:8086/courses/*'
r /courses/3; r /courses/7                                    # MISS
r /about                                                      # HIT: outside the wildcard
docker exec lumina-cache-plus find /var/cache/nginx/lumina -type f | wc -l     # right after the purge
```
The purged entries are gone from the cache at once, but their files are still on disk. Check the count again in a minute: the cache purger (`purger=on`) deletes them in the background. `docker logs lumina-cache-plus 2>&1 | grep purger` shows the process starting.

### A.4 Who May Purge (4 min)
The config allows `PURGE` only from `127.0.0.1`. Send one from a container on Docker's default bridge network. It reaches the host's address, and NGINX sees the container's bridge address (`172.17.0.x`) as the client:
```bash
HOST_IP=$(hostname -I | awk '{ print $1 }')
docker run --rm curlimages/curl:8.16.0 -s -o /dev/null -w '%{http_code}\n' -X PURGE "http://$HOST_IP:8086/about"
docker logs lumina-cache-plus 2>&1 | grep PURGE | tail -2
r /about                                                      # still HIT
```
<details>
<summary>What would happen without the <code>$purge_denied</code> check?</summary>

`$purge_method` would be `0` for that client, so `proxy_cache_purge` wouldn't purge. But the request would then be **proxied to the origin as a `PURGE`** (the lab origin answers `501`). Rejecting unauthorized purges explicitly keeps them away from the origin.
</details>

### A.5 Clean Up (1 min)
```bash
docker rm -f lumina-cache-plus
unset EDGE
```

---

## 4. Enterprise Quiz (Optional, 10 Questions)

👉 **http://&lt;lab-host&gt;:8090/quiz.html?sprint=4&day=3&pool=enterprise**

---

## 5. Key Takeaways
* **Open source NGINX can't purge.** Use versioned URLs for assets, short lifetimes plus stale for pages, and a protected bypass header to refresh one URL.
* **NGINX Plus `proxy_cache_purge` removes entries by the purge request's own key.** Same `Host`, same URI, or it misses. A trailing `*` purges a prefix, and `purger=on` cleans the files in the background.
* **Purge is powerful.** Restrict who can send it, reject everyone else explicitly, and remember it's per node.
* **The Plus API counts cache outcomes per zone.** Hit ratio, stale serves and origin load come straight from it. It reports; it doesn't purge.

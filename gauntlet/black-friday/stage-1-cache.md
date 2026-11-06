# Stage 1: The Cache

**Tickets 1–3** · Sprint 4's side quest: purge on demand and cache metrics, on two nodes · [War room README](README.md)

---

## Briefing (10 Minutes)

### Every Node Has Its Own Cache
Each edge keeps its cache on its own disk, with the keys in its own shared memory zone. Nothing copies an entry from edge-a to edge-b, and nothing removes it from both. So a wrong price has to be fixed on every node that cached it. A fix on one node leaves shoppers getting the old price through the other, roughly every second request through a round-robin load balancer.

This is the same as BIG-IP's RAM cache in a Web Acceleration profile: per device, and not part of config sync. Invalidating an entry on the active unit doesn't touch the standby's copy.

### What "Invalidate" Means in Each Edition
**Open source NGINX has no purge.** You choose from three things, or combine them:
* **Overwrite one entry.** With `proxy_cache_bypass`, a request that matches a condition you define skips the cache, goes to the origin, and **stores the fresh response in place of the old one**. That makes it a refresh, not a delete. The condition has to be one only trusted clients can trigger, or anyone can make the origin do work.
* **Move to new keys.** Add a "generation" to the cache key for part of the site. Changing the generation sends that part to new keys, so everything in it is a MISS once. The old entries are never served again and age out (`inactive`, `max_size`). This is how a whole section is invalidated without touching the rest. The catch: you're changing the cache key, and **the default key isn't quite what the documentation's shorthand suggests.** Write it out wrong and every entry moves, not just the section.
* **Design so you don't need it.** Fingerprinted asset URLs, short lifetimes plus stale serving (Sprint 4 Day 2). Production sites lean on this. Tonight, though, prices are cached for a day.

The third-party `ngx_cache_purge` module adds a purge location to OSS. It isn't part of NGINX or supported by F5, so it's out of scope here.

**NGINX Plus adds `proxy_cache_purge`.** A request whose purge condition is non-empty and not `"0"` removes the matching entry instead of being proxied. A `*` at the end of the URI removes every key with that prefix. Three things about it matter tonight:
* **The condition is yours to build.** The usual pattern maps the method `PURGE` to the condition, and only for trusted addresses. A `PURGE` that doesn't match the condition is just another request: without a rule that refuses it, it gets proxied to the origin.
* **The answer code doesn't prove anything.** Check the next request (`X-Cache-Status`), not the status of the purge.
* **Wildcard purges remove the keys at once,** so the next request is a MISS. The files are deleted later and only with `purger=on` in `proxy_cache_path`.

The BIG-IP analogy is deleting RAM cache entries by URI from the command line or an iRule (`CACHE::expire`). There, too, it's per device.

### Who Is "Ops"?
Tonight the ops team is one address, `10.58.0.5`, talking straight to each node. Shoppers come through the load balancer, and realip turns the last `X-Forwarded-For` entry into `$remote_addr`. Anything that decides "is this ops?" from `$remote_addr` after realip sees the real client, even if a shopper sends `X-Forwarded-For: 10.58.0.5` themselves: the load balancer appends the address it actually saw, and realip takes the last one.

That's the reason to decide on `$remote_addr` (or `geo`, which reads it), never on a header.

### Cache Numbers
Finance wants to know whether the cache is earning its keep: how many requests each node answered from cache, and how many went to the origin.
* **Plus:** the API's `/http/caches/<zone>` reports, per node and per zone, the responses and bytes for every cache result (`hit`, `stale`, `updating`, `revalidated`, `miss`, `expired`, `bypass`), plus the size and whether the loader has finished (`cold`). Those counters are what a Prometheus exporter or the dashboard reads. The API is a `location` with `api`, so you decide who can reach it, and whether it can change things (`write=on`; the next stage needs that).
* **Open source:** there are no cache counters. The data is `$upstream_cache_status`: put it in the access log and count. `stub_status` doesn't know about caches.

BIG-IP's equivalent is the Web Acceleration profile statistics, per device.

<details><summary>Question: a shopper sends <code>X-Forwarded-For: 10.58.0.5</code> through the load balancer. What does the edge see as <code>$remote_addr</code>, and why?</summary>

The shopper's own address. The load balancer passes `X-Forwarded-For: 10.58.0.5, <shopper>` (it appends what it saw), and with `real_ip_recursive off`, realip takes the last address. Only the load balancer (`set_real_ip_from 10.58.0.10`) is trusted to set it at all.
</details>

---

## Ticket 1: Wrong Price on the Doorbuster TV

> **From merchandising:** The 65" TV (`tv-65`) is showing $649. It's $599, and that's fixed at the origin. Both edges are still serving the cached $649. Get the right price out without dumping the rest of the cache, and set it up so you can do it again tonight in seconds. Only ops should be able to do this.

`./warroom.sh next` caches every catalog page on both nodes, then reprices `tv-65` at the origin.

**Requirements:**
1. Both nodes serve `tv-65` at the origin's current price.
2. The ops team (`10.58.0.5`), talking straight to a node, can invalidate one cached page so the next shopper request gets the origin's current version:
   * **Open source:** a `GET` for the page with the header `X-Refresh: 1` fetches it from the origin and stores the fresh copy.
   * **Plus:** a `PURGE` request for the page removes it from the cache.
3. Invalidating one page leaves every other cached page in place.
4. Nobody else can do it, including a shopper who goes through the load balancer and claims `X-Forwarded-For: 10.58.0.5`:
   * **Open source:** their `X-Refresh` is ignored. They get the cached copy, and the origin isn't contacted.
   * **Plus:** their `PURGE` gets `403` and never reaches the origin.

The check reprices another product (`hp-lite`) and uses your mechanism on both nodes itself.

<details><summary>Hint 1</summary>

Two decisions make up the condition: "is this ops?" (an address, so `geo`) and "is this a refresh / a purge?" (a header or the method). `map` can combine two variables into one string, such as `"$ops:$http_x_refresh"` or `"$is_purge:$ops"`, and match on that.
</details>

<details><summary>Hint 2 (Plus)</summary>

`proxy_cache_purge` only acts on requests where its condition is set. Every other `PURGE` is an ordinary request and gets proxied. Something has to refuse it before it reaches `proxy_pass`. An `if` with `return` inside a location is safe.
</details>

<details><summary>Hint 3</summary>

Requirement 1 is a one-off action, not configuration: once your mechanism works, use it for `tv-65` on **both** nodes. The `ops` command talks to one node at a time: `http://edge-a:8080/...`, then `http://edge-b:8080/...`.
</details>

<details><summary>Answer (open source)</summary>

In `http`:
```nginx
geo $ops {
    default    0;
    10.58.0.5  1;
}
map "$ops:$http_x_refresh" $refresh {
    "~^1:."    1;           # ops, and any X-Refresh value
    default    0;
}
```
In `location /catalog/`:
```nginx
proxy_cache        shop;
proxy_cache_bypass $refresh;
proxy_pass         http://origin;
```
`proxy_cache_bypass` skips the lookup, and the response is still stored (that's `proxy_no_cache`'s job, which stays unset), so the fresh copy replaces the old one.
```bash
./warroom.sh reload
./warroom.sh ops -i -H 'X-Refresh: 1' http://edge-a:8080/catalog/tvs/tv-65
./warroom.sh ops -i -H 'X-Refresh: 1' http://edge-b:8080/catalog/tvs/tv-65
./warroom.sh check
```
</details>

<details><summary>Answer (Plus)</summary>

In `http`:
```nginx
geo $ops {
    default    0;
    10.58.0.5  1;
}
map $request_method $is_purge {
    PURGE      1;
    default    0;
}
map "$is_purge:$ops" $purge_method {      # PURGE from ops
    "1:1"      1;
    default    0;
}
map "$is_purge:$ops" $purge_refused {     # PURGE from anyone else
    "1:0"      1;
    default    0;
}
```
In `location /catalog/`:
```nginx
if ($purge_refused) {
    return 403;
}
proxy_cache       shop;
proxy_cache_purge $purge_method;
proxy_pass        http://origin;
```
```bash
./warroom.sh reload
./warroom.sh ops -i -X PURGE http://edge-a:8080/catalog/tvs/tv-65
./warroom.sh ops -i -X PURGE http://edge-b:8080/catalog/tvs/tv-65
./warroom.sh check
```
</details>

---

## Ticket 2: The Whole TV Category Was Repriced

> **From merchandising:** Every TV is 10% off from now on, changed at the origin. The category page and every TV page are wrong on both edges. Laptops and headphones are fine: don't touch them, the origin is busy enough tonight.

`./warroom.sh next` caches every catalog page on both nodes, then reprices the whole `tvs` category.

**Requirements:**
1. Every page under `/catalog/tvs/` (the category page and each product) serves the origin's current prices on both nodes.
2. The other categories keep their cached copies. Their pages are still HITs on both nodes.
3. **Plus:** no reload or restart while you do it.

<details><summary>Hint 1 (open source)</summary>

Refreshing pages one at a time works for three products. It doesn't work for a category you can't list. Think about the cache key: what would make every `/catalog/tvs/` request look up a key that isn't in the cache yet, while every other request still finds its old one?
</details>

<details><summary>Hint 2 (open source)</summary>

A `map` from `$uri` to a short "generation" string that's empty by default, appended to `proxy_cache_key`. Keep the generations in their own file (`include` inside the `map`), so bumping one is a one-line edit and a reload.

Before you reload, compare your `proxy_cache_key` with the key NGINX stores. On a node, a cached file's `KEY:` line shows it: `docker exec bf-edge-a sh -c 'grep -a -m1 "^KEY" -r /var/cache/nginx/shop | head -1'`. If yours is even one character different for the default case, every category moves to new keys, not just TVs.
</details>

<details><summary>Hint 3 (Plus)</summary>

You built `PURGE` in ticket 1. Read what `proxy_cache_purge` does with a URI that ends in `*`.
</details>

<details><summary>Answer (open source)</summary>

In `http`:
```nginx
map $uri $cache_gen {
    include /lab/edge/cache_gen.conf;
    default "";
}
```
`edge/cache_gen.conf`:
```nginx
"~^/catalog/tvs/"  ":g2";
```
In `location /catalog/`:
```nginx
proxy_cache_key $scheme://$proxy_host$request_uri$cache_gen;
```
The default key is `$scheme://$proxy_host$request_uri`. Written as `$scheme$proxy_host$request_uri`, every key changes (`httporigin/...` instead of `http://origin/...`) and the whole cache starts over. That fails requirement 2.
```bash
./warroom.sh reload
./warroom.sh check
```
The next repricing of the same section bumps it to `":g3"`.
</details>

<details><summary>Answer (Plus)</summary>

No config change:
```bash
./warroom.sh ops -i -X PURGE 'http://edge-a:8080/catalog/tvs/*'
./warroom.sh ops -i -X PURGE 'http://edge-b:8080/catalog/tvs/*'
./warroom.sh check
```
Quote the URL so the shell doesn't expand the `*`.
</details>

---

## Ticket 3: Is the Cache Earning Its Keep?

> **From finance:** We're paying for these edges. Per node, how much of the catalog do they answer themselves and how much goes to the origin? We need numbers we can watch all night.

**Requirements (open source):**
1. Each node's access log records, for every request, the cache result as `cache=<result>`: `MISS`, `HIT`, and so on, or `-` when the request didn't use the cache.

**Requirements (Plus):**
1. Each node serves the NGINX Plus API on port `8085`. The ops team (`10.58.0.5`) and the lab host (`10.58.0.1`, how the host reaches the network) can read it; anyone else gets `403`.
2. The `shop` cache's counters (`/api/<version>/http/caches/shop`) follow real traffic.

<details><summary>Hint (open source)</summary>

The access log format is `log_format edge` in `http`. Which variable holds the cache result, and what does NGINX write for an empty variable?
</details>

<details><summary>Hint (Plus)</summary>

The API is a `location` with the `api` directive in a server of its own. `allow`/`deny` in that server decides who gets in. The versions it speaks are listed at `/api/`. The dashboard is a static page in the image: `location = /dashboard.html { root /usr/share/nginx/html; }`.
</details>

<details><summary>Answer (open source)</summary>

```nginx
log_format edge '$time_iso8601 $hostname $remote_addr "$request" $status $body_bytes_sent '
                'rt=$request_time member="$member" cache=$upstream_cache_status';
```
After `./warroom.sh reload`, a hit ratio for edge-a's catalog traffic:
```bash
awk '/"GET \/catalog\// { n++; if (/cache=HIT/) h++ } END { printf "%d of %d from cache (%.0f%%)\n", h, n, 100*h/n }' logs/edge-a/access.log
```
</details>

<details><summary>Answer (Plus)</summary>

A server of its own, after the shop's server:
```nginx
server {
    listen 8085;
    allow  10.58.0.5;
    allow  10.58.0.1;
    deny   all;

    location /api/ {
        api;
    }
    location = /dashboard.html {
        root /usr/share/nginx/html;
    }
}
```
```bash
./warroom.sh reload
curl -s 127.0.0.1:8085/api/                          # the versions
curl -s 127.0.0.1:8085/api/10/http/caches/shop | jq   # edge-a; edge-b is 127.0.0.1:8105
```
The dashboard is at `http://127.0.0.1:8085/dashboard.html` (an SSH tunnel to the lab box if you're not on it).
</details>

---

## Stage 1 Questions

<details><summary>1. In the open source answer to ticket 1, the ops refresh stores the new copy. What would change if you also set <code>proxy_no_cache $refresh</code>?</summary>

The refresh would fetch from the origin but not store the result, so the stale entry would stay and the next shopper would still get $649. `proxy_cache_bypass` decides whether to look in the cache; `proxy_no_cache` decides whether to store. A refresh needs the first and not the second.
</details>

<details><summary>2. Why does ticket 2's open source answer leave the old TV entries on disk, and is that a problem?</summary>

Nothing ever asks for the old keys again, so they're never served. They stay until `inactive` (a day here) or until `max_size` pushes them out with the least recently used. On a busy edge that's disk space for a while, not wrong answers. The Plus wildcard purge has a similar gap: the keys go at once, the files only with `purger=on`.
</details>

<details><summary>3. With two edges, why must every invalidation be done twice, and what would a third node mean for your runbook?</summary>

Each node's cache is its own: keys in its own shared memory, files on its own disk. There's no sync for caches (`zone_sync` is for key-value, limit and sticky zones, not cache entries). A third node means a third request. Production runbooks loop over the nodes, or keep cache lifetimes short enough that waiting is the invalidation.
</details>

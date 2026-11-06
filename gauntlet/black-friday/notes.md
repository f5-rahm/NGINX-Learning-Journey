# Black Friday War Room: Notes From Building It

What building and rehearsing the gauntlet turned up. Each clean rehearsal ran from `./warroom.sh init <edition> --force` with the guides' answer commands.

**Versions:**
* `nginx:mainline`: NGINX 1.31.6 with njs
* NGINX Plus R37.1.1: NGINX 1.31.3, API version 10
* OpenResty 1.31.8.1 on Alpine

**Result:** both editions scored 1200 of 1200.

---

## The Cache

* **The default cache key isn't the documentation's shorthand.**
  * The documented default `$scheme$proxy_host$request_uri` is stored as `KEY: http://origin/...`, with `://`.
  * Writing `proxy_cache_key $scheme$proxy_host$request_uri$cache_gen;` produced `KEY: httporigin/...`: every page moved to a new key and the whole cache started over. Ticket 2's "other categories still HITs" check caught it on the first try.
  * The key that matches the default is `$scheme://$proxy_host$request_uri`. A cached file's `KEY:` line is the way to check.
* **`proxy_cache_bypass` stores the fresh response,** so it works as a refresh in open source. `proxy_no_cache` is what would stop the store.
* **`PURGE` from ops answered 204 on Plus.** Before the purge config was loaded, the same `PURGE` was proxied to the origin, which answered 404. Without a rule refusing non-ops `PURGE`, it reaches the origin (as Sprint 4's side quest also found).
* **The wildcard `PURGE /catalog/tvs/*` worked without `purger=on`.** The next request was a MISS.
* **Realip holds against a forged header.**
  * A shopper sending `X-Forwarded-For: 10.58.0.5` through the load balancer was seen as themselves: the load balancer appends the real address and realip takes the last one.
  * `geo $ops` therefore refused them in both editions.

## Who Gets In

* **Longest prefix wins in a `type=ip` key-value zone.** `10.58.66.0/24` = `"1"` plus `10.58.66.77` = `"0"`: the partner got in and `.76` stayed refused, on both nodes, with no reload. `geo` behaves the same way.
* **`POST` of an existing key returns 409.** The war room uses `PATCH` then.
* **Adding `sync` to a running `limit_req` zone is refused on reload:**
  ```
  [emerg] the "sync" flag of shared memory zone "checkout" had previously a different state
  ```
  The master keeps the old config while `nginx -s reload` itself exits 0. `warroom.sh reload` reports it. A new zone name (`checkout_all`) reloads fine.
* **Sustained checkout at 10/s for 6 s, against 5r/s with burst 5:**

  | Setup | 200s out of 60 (the ideal is 5 × 6 + 5 = 35) |
  | :--- | :--- |
  | Per-node zones behind round robin | 60 |
  | Open source, `hash $remote_addr consistent` at the load balancer | Within 25–45 (the check passed in the build and the rehearsal; exact count not recorded) |
  | Plus, `limit_req_zone ... sync`, still round robin | 38, 37, 37 (both edges answering) |
* **Client affinity changes how "both nodes" can be tested.** With `hash $remote_addr` at the load balancer, a client only ever reaches one node. The first versions of the ticket 4, 5 and 7 checks expected to see both edges through the load balancer and failed on a correct solution. The checks now test each node directly as well as through the load balancer.
* **A node restarted on its own gets the synced data back from its peer.** `docker restart bf-edge-a`: within 1 s, its denylist was complete again (`zone_sync` `msgs_in` 4). Restarting both at once loses it: no node has a copy, and the zones have no `state=` file. `keyval_zone ... sync state=<file>` passes `nginx -t`.

## Code at the Edge

* **`keyval` can map a `js_set` variable.** `keyval $member $vip zone=vip` looks up njs's verified member ID, so the Plus answer to ticket 7 has no VIP code at all.
* **Benchmark (ticket 8), 15 s, 50 connections, a non-VIP member refused at the edge:**

  | Run | njs on edge-a | Lua on OpenResty |
  | :--- | :--- | :--- |
  | OSS build | 39,985 req/s, p99 1.83 ms | 48,859 req/s, p99 1.57 ms |
  | Plus build | 41,046 req/s, p99 1.78 ms | 47,888 req/s, p99 1.75 ms |
  | OSS rehearsal | 39,568 req/s, p99 2.17 ms | 47,629 req/s, p99 1.78 ms |
  | Plus rehearsal | 40,379 req/s, p99 2.10 ms | 47,309 req/s, p99 1.92 ms |

  * Lua was 15–22% faster every time.
  * Worker RSS was about 7–10 MB for both.
  * edge-a's config does more per request (realip, `geo`, maps, the longer log line, and in Plus a key-value lookup), so it isn't perfectly like for like.
* **The `nginx` images have no `pgrep`.** The benchmark reads worker memory from `/proc/<pid>/cmdline` and `status`.

## The Lab Itself

* **NGINX Plus looks for `license.jwt` next to the main config file.** With `-c /lab/edge/nginx.conf` that's `/lab/edge/license.jwt`: `[emerg] License file is required`. The Plus start config spells out `mgmt { license_token /etc/nginx/license.jwt; state_path /var/lib/nginx/state; }`.
* **Catalog pages are cached for a day** (`max-age=86400`, `inactive=1d`). With a 10-minute lifetime, the "still a HIT" checks would fail on their own in a long session.
* **The origin's listen backlog is set to 256** (`request_queue_size` on the server class, before bind). The finale's rush is about 4,500 requests/s through the load balancer, mostly cache hits.
* **`init --force` empties `state/` instead of removing it,** because the running client container has it mounted. Removing it left the scoreboard unwritable.

# Sprint 5 Lab: Solution Map
Each requirement in [README section 4](README.md#4-lab-specification-the-lumina-api-gateway) mapped to the lines of [`lab/solution_nginx.conf`](lab/solution_nginx.conf) that meet it, and to what [`test_sprint05.sh`](test_sprint05.sh) sends to check it. Test N checks requirement N.

The solution is built from one idea: **turn the client into a tier once, then let every limit read the tier.**

```
realip (POST_READ) ─► $remote_addr = the real client
                          │
                    geo $tier ─► internet | ops | partner | blocked
                          │
        ┌─────────────────┼──────────────────┬───────────────────┐
  map $client_key   map $origin_key   map $download_rate   if ($tier = blocked)
  (partner → "")    (partner → "")    (partner → 0)        return 403
        │                 │                  │
  api, per_client     origin zone       limit_rate
```

---

## The Requirements

| # | Requirement | Solution lines | What the test does | Why it works |
| :--- | :--- | :--- | :--- | :--- |
| 1 | **Refusals:** `429` + `Retry-After: 1` | `limit_req_status 429;` `limit_conn_status 429;` (http) · `error_page 429 @too_many;` + `location @too_many { add_header Retry-After 1 always; return 429 ...; }` (server) | 40 rapid requests (rate) and 6 slow ones held at once (concurrency) from one client; both must show `429 x N (Retry-After: 1)` | Both limits default to `503`, so each needs its own `_status`. The `error_page` catches **every** `429` in the server, whichever limit produced it, so one header rule covers both. `always` is needed because `add_header` skips error statuses without it. |
| 2 | **API rate:** 10 r/s, burst 20, no delay | `limit_req_zone $client_key zone=api:10m rate=10r/s;` · in `/api/`: `limit_req zone=api burst=20 nodelay;` | 40 rapid requests, 4 at a time, from one fresh address: expects **21–23** answered; a second client at the same time gets `200` | 1 + `burst=20` = 21 at once, plus 1–2 refilled while the run lasts. Without `nodelay` the burst is queued and released 100 ms apart, which stretches the run and changes the count. |
| 3 | **API concurrency:** 4 in progress per client | `limit_conn_zone $client_key zone=per_client:10m;` · in `/api/`: `limit_conn per_client 4;` | 8 slow (2 s) requests at once from one client: expects **4 × 200, 4 × 429** | `limit_conn` counts requests in progress (Day 2), so the slow origin keeps all 4 slots busy while the other 4 arrive. |
| 4 | **Origin protection:** 20 in progress across all clients | `map $tier $origin_key { partner ""; default $server_name; }` · `limit_conn_zone $origin_key zone=origin:1m;` · `server_name lumina;` · in `/api/`: `limit_conn origin 20;` | 10 clients × 3 slow requests (30 in total, each client under its own limit of 4): expects **20 × 200, 10 × 429**, and the origin's own counter peaking at ≤ 20 | One shared key for everybody means one counter for the whole server. **`server_name` matters:** without it `$server_name` is empty, an empty key is never counted, and the cap silently does nothing. |
| 5 | **Uploads:** ≤ 2 MB, else `413` | in `/api/`: `client_max_body_size 2m;` | 1.5 MB body → `200`; 3 MB body → `413` | Checked against `Content-Length` when the location is chosen, before the body is read. The default is 1m, so the 1.5 MB body fails without it. |
| 6 | **Login:** 5 at once, then 1 per 12 s | `limit_req_zone $binary_remote_addr zone=login:10m rate=5r/m;` · `location /api/login { proxy_pass ...; limit_req zone=login burst=4 nodelay; }` | 8 rapid attempts at the start (expects **5**), then 2 more 12.5 s later (expects **1**) | `5r/m` = one every 12 s; 1 + `burst=4` = 5 at once. Its own location (the longer prefix wins), so `/api/`'s limits **don't** stack on top: a location with its own `limit_req` drops the others (Day 1 inheritance). Keyed on the address, not `$client_key`, so login stays limited for partners too. |
| 7 | **Download speed:** 256 KB free, then 512 KB/s | `map $tier $download_rate { partner 0; default 512k; }` · in `/downloads/`: `limit_rate_after 256k; limit_rate $download_rate;` | 200 KB must take **< 0.4 s**; 1 MB must take **1.1–2.5 s** | 1 MB = 256 KB free + 768 KB at 512 KB/s ≈ 1.5 s. A 200 KB file never leaves the free part. |
| 8 | **Download concurrency:** 1 per client | `limit_conn_zone $binary_remote_addr zone=downloads:10m;` · in `/downloads/`: `limit_conn downloads 1;` | 2 × 1 MB downloads at once from one client: expects **1 × 200, 1 × 429** | Its own zone, not `per_client`: a shared zone counts across locations (Day 2), so an API call in progress would block a download. `limit_rate` is per connection, so without this, 4 parallel downloads get 4× the bandwidth. |
| 9 | **Partners:** exempt from `/api/` limits, full-speed downloads | `geo $tier { ... 10.55.20.0/24 partner; }` · `map $tier $client_key { partner ""; default $binary_remote_addr; }` (+ `$origin_key`, `$download_rate` above) | From a partner address: 40 rapid → **40/40**, 8 slow at once → **8/8**, 1 MB in **< 0.5 s**; an internet client in the same run is still refused and slowed | **An empty key is never counted** (Day 1), so one `map` line exempts partners from every zone keyed on it. `limit_rate 0` means unlimited. |
| 10 | **Admin:** ops only, others `403` | `location /admin/ { proxy_pass ...; allow 10.55.10.0/24; deny all; }` | ops → `200`, internet → `403`, partner → `403` | First match wins, so `allow` comes before `deny all`. The rules live only in `/admin/`, so no other location inherits them. |
| 11 | **Abusive network:** `403` every time | `geo $tier { ... 10.55.66.0/24 blocked; }` · at server level: `if ($tier = blocked) { return 403; }` | 30 at once to `/api/` → **30 × 403**; one request to `/downloads/` → `403` | The server-level rewrite phase runs **before** PREACCESS (limits) and ACCESS (`deny`). A `deny` in `/api/` gives 21 × 403 + 9 × 429 (your Activity 3.1 run) and doesn't cover `/downloads/`. |
| 12 | **Load balancer:** trust its `X-Forwarded-For`, nobody else's | `set_real_ip_from 10.55.0.5;` `real_ip_header X-Forwarded-For;` `real_ip_recursive on;` (http) | From the LB: XFF = a blocked address → `403`; XFF = a partner address, 40 rapid → **40/40**. From an internet client claiming a partner XFF: still **refused** some of 40 | realip rewrites `$remote_addr` in POST_READ, before `geo` reads it, so the tier comes from the real client. Only `10.55.0.5` is trusted, so the spoofer stays itself. `real_ip_recursive` isn't needed by the test (one address per header); it protects a chain of proxies. |
| 13 | **Slow clients:** headers within 10 s | `client_header_timeout 10s;` (http) | A client sends one header line every 2 s; expects a disconnect **between 8 and 13 s** | The timeout is a total for the whole header, not a gap between reads (Day 2). The default is 60 s. `limit_conn` can't help here: the request isn't counted until its header is complete. |

---

## The Traps the Test Catches
These are the near-solutions the test was checked against while building the lab: each one fails exactly one requirement.

| Near-solution | Fails | What the test prints |
| :--- | :--- | :--- |
| `Retry-After` from a `map` on `$limit_req_status` only | 1 | the concurrency `429`s arrive without `Retry-After` |
| `burst=20` without `nodelay` | 2 | an answered count outside 21–23: queued requests are spaced 100 ms apart, the run stretches out, and the rate refills more slots meanwhile |
| `deny 10.55.66.0/24` inside `/api/` instead of the server-level `if` | 11 | a mix of `403` and `429` for the flood, and `200` on `/downloads/` |
| No realip | 12 | the LB's partner gets limited (everyone behind the LB shares one bucket), the blocked client behind it gets through |

## Choices the Requirements Leave Open
* **Partners and the origin cap (4).** Requirement 9 exempts partners from "all of `/api/`'s rate and concurrency limits", so the solution exempts them from the server-wide cap too (`$origin_key`). The test's partner checks pass either way, since 8 requests stay well under 20.
* **Partners and login (6).** `/api/login` keys on `$binary_remote_addr`, so partners are limited on login. Using `$client_key` there would exempt them as well. The test doesn't check partners on login.
* **Partners and download concurrency (8).** `downloads` keys on `$binary_remote_addr`, so a partner still runs one download at a time, at full speed.

# Sprint 5: Traffic Control, Rate Limiting & Concurrency
**Cadence:** 3 sessions, any days that week  
**Milestone:** The Lumina API Gateway: per-client rate and concurrency limits, a cap that protects the origin, throttled downloads, slow-client defenses, partner and operations tiers, a blocked network, and correct client addresses behind a load balancer  
**Shape:** 3 days. The Enterprise Side Quest is an **optional** add-on to Day 3, with its own optional quiz.

---

## 1. Sprint at a Glance

| Day | Theme | Concepts (~15 min) | Lab (~35 min) | Guide |
| :--- | :--- | :--- | :--- | :--- |
| **1** | Rate limiting and the leaky bucket | `limit_req_zone` / `limit_req`, the rate as a minimum gap, the excess counter, `burst` with a queue, `nodelay` or `delay=`, keys and the empty key, stacking and inheritance, `429` and `Retry-After`, dry run, zone size | 12/s against 10/s, queue vs `nodelay`, two-stage, API keys, the inheritance trap, talking back, a zone too small to remember | [`day_01.md`](day_01.md) |
| **2** | Concurrency, bandwidth and slow clients | `limit_conn` counts requests in progress (and HTTP/2 streams), a cap for the origin, `limit_rate` per response and `limit_rate_after`, slowloris and slow POST timeouts, request buffering, body size | Requests in progress, one connection with five streams, an origin cap that caps nothing, multiplied bandwidth, slow headers vs slow bodies, `413` | [`day_02.md`](day_02.md) |
| **3** | Who gets in & the sprint lab | `allow`/`deny` and the phase order, `geo` and `map` tiers, exemption by empty key, the realip module and whom to trust, the sprint in BIG-IP terms | A blocked client that gets `429`, tiers (and a reload the master refuses), an admin allowlist, users behind a load balancer, **build the Lumina gateway**, `test_sprint05.sh` | [`day_03.md`](day_03.md) |
| *3+* | *Optional Enterprise Side Quest* | *Limits are per instance, the key-value store as a denylist, zone_sync, limit metrics in the Plus API* | *Two nodes from one config, block a network with no reload, unblock across a cluster, one limit for two nodes, restarts* | [`day_03_enterprise.md`](day_03_enterprise.md) |

---

## 2. Lab Environment

Like Sprint 4, the lab runs in **containers** (`nginx:mainline`: nginx 1.31.6). Sprint 5 adds a **client container** that can send from any address on the lab network, because every limit this week depends on who the client is. Everything runs from `/srv/nginx-journey/sprints/sprint-5/lab` through `lab.sh`.

| Address / port | Service |
| :--- | :--- |
| 8080–8084 | Earlier sprints (reserved) |
| **10.55.0.10:8095** (host **:8095**) | **Sprint 5 lab: the Lumina gateway** (container `s5-edge`) |
| 10.55.0.20:8015 (host 127.0.0.1:8015) | **The API** (container `s5-origin`) |
| 10.55.0.2 | **The client** (container `s5-client`): sends from any 10.55.x.y address you name |
| 10.55.0.31 / .32:8096, host 127.0.0.1:8085 / :8098 | Side quest: NGINX Plus nodes `s5-plus-a` / `s5-plus-b`, traffic / API and dashboard |

```bash
cd /srv/nginx-journey/sprints/sprint-5/lab
cp day1_nginx.conf nginx.conf           # or the day's config, or starter_nginx.conf for the sprint lab
./lab.sh up                             # network, origin, client, gateway, then the ready check
source helpers.sh                       # r, burst, pace, hold, slow, h2, sweep, lim: in every new terminal
./lab.sh down                           # when you're done for the day
```

**The network** (`s5-net`, 10.55.0.0/16), as named in `helpers.sh`:

| Name | Address | Who |
| :--- | :--- | :--- |
| `$ALICE`, `$BOB` | 10.55.100.11, .12 | Internet clients (the default sender is `$ALICE`) |
| `$OFFICE` | 10.55.10.10 | The operations network, 10.55.10.0/24 |
| `$PARTNER` | 10.55.20.20 | The partner network, 10.55.20.0/24 |
| `$BAD` | 10.55.66.6 | An abusive network, 10.55.66.0/24 |
| `$LB` | 10.55.0.5 | A load balancer in front of the gateway |

**`lab.sh`**
* `up`, `check`, `reload`, `t`/`T` (`nginx -t` / `-T` inside the gateway), `edge` (recreate only the gateway: fresh zones), `down`.
* `reload` also checks the error log: when the master refuses a new configuration that `nginx -t` accepted (a zone redefined with a different key, for example), it says so instead of "reloaded".
* `stats` / `reset` read and zero the origin's counters, including `inflight` and `max_inflight`. `client` opens a shell in the client container.
* The whole `lab/` directory is mounted into the gateway at `/lab`, so an edited `nginx.conf` is picked up by `./lab.sh reload`. Logs are in `lab/logs/` (gitignored).

**`helpers.sh`** (all requests come from the client container, from `--from IP`):
* `r PATH`: one request (status, time, size, speed, `Retry-After`). `--data-size N` sends a `POST` body.
* `burst N PATH [--conc C]`: N at once (or C at a time), with each status counted and when it was answered.
* `pace N RATE PATH [--alt HOST:PORT]`: N one after another at RATE per second (alternating between two gateways with `--alt`).
* `hold N SECS PATH`: N at once that the origin keeps open, for concurrency.
* `slow PATH [--every S] [--body] [--for SECS]`: a client that dribbles its headers or body.
* `h2 N PATH`: N requests over one HTTP/2 connection.
* `sweep N PATH`: one request from each of N different clients.
* `lim [N]`: the last N access log lines, with `$limit_req_status` and `$limit_conn_status`.
* Every command takes `-H 'Name: value'` and `--edge HOST:PORT` (default 10.55.0.10:8095).

**The API (`origin.py`)** answers any path with JSON that includes the `X-Forwarded-For` and `X-Real-IP` it received and how many requests it has in progress. `?delay=S` slows it down, `?status=N` sets the status, and `?size=1m` turns the answer into a download of that size.

> **Version notes (verified on nginx 1.31.6 in `nginx:mainline`):**
> * `limit_req` and `limit_conn` reject with `503` unless `limit_req_status` / `limit_conn_status` say otherwise, and log each rejection at `error`.
> * `client_header_timeout`, `client_body_timeout` and `send_timeout` default to 60 s; `client_max_body_size` to 1 MB.
> * HTTP/2 is enabled per server with `http2 on;`. On a plain-text port it's served to clients that start with HTTP/2 directly (prior knowledge).

---

## 3. Daily Detail

### Day 1: Rate Limiting and the Leaky Bucket
**Concepts:**
* `limit_req_zone` and `limit_req`: the key, the zone (about 16,000 states per MB), the rate as a minimum gap, the excess counter.
* `burst` with a queue, `nodelay`, or `delay=N`.
* Keys: per address, per credential, global; the empty key; stacking; inheritance.
* `limit_req_status 429`, `Retry-After` from a `map`, `$limit_req_status`, the error log, `limit_req_dry_run`.
* PREACCESS: what runs before and after the limits.

**Lab:**
* 20% over the rate, 50% rejected.
* A queue that paces, `nodelay` that averages, and two-stage limits.
* An API-key limit, and a tidy-up that removes the general limit.
* `429` with `Retry-After`, and a dry-run rollout.
* A 32 KB zone that forgets its clients.

### Day 2: Concurrency, Bandwidth and Slow Clients
**Concepts:**
* `limit_conn` counts requests in progress, HTTP/2 streams included. `limit_conn` vs upstream `max_conns`.
* `limit_rate` per response, `limit_rate_after`, rates from variables.
* Slowloris vs slow POST: `client_header_timeout` (total) vs `client_body_timeout` (between reads); request buffering.
* `client_max_body_size`, body buffering, header limits. Which tool for which abuse.

**Lab:**
* Two requests in progress per client, with `429` and `Retry-After` for both kinds of refusal.
* Five HTTP/2 streams on one connection.
* An origin cap keyed on an empty `$server_name`.
* Four downloads at four times the bandwidth, then one at a time.
* Slow headers cut off at 5 s, a slow body that never times out, and an origin that never sees either.
* `413` and a per-location body limit.

### Day 3: Who Gets In & the Sprint Lab
**Concepts:**
* `allow`/`deny` order, and PREACCESS before ACCESS.
* Blocking in the rewrite phase with `geo` + `if ... return`.
* `geo` and `map` tiers, exemption by empty key, rates by tier.
* The realip module: `set_real_ip_from`, `real_ip_header`, `real_ip_recursive`, `$realip_remote_addr`, the PROXY protocol.
* The sprint's tools mapped to BIG-IP.

**Lab:**
* A denied network that gets `429`s, then `403` for every request.
* Partner tiers, and a reload the master refuses.
* An admin allowlist in the wrong order.
* Users behind a load balancer sharing one bucket, then trusted, spoofed and chained headers.
* Then build the Lumina gateway (Section 4) and pass `test_sprint05.sh`.

### Day 3+ (Optional): Enterprise Side Quest
**Concepts:**
* Limits are per instance.
* A `type=ip` key-value zone as a denylist, changed through the API.
* zone_sync: `sync` zones, eventual consistency, deletes vs updates, snapshots.
* Limit metrics in the Plus API.

**Lab:**
* Two NGINX Plus nodes from one config.
* Block a /24 without a reload, and see it on both nodes.
* Unblock across the cluster (and why deleting doesn't).
* A per-node limit that doubles, and a synced one that holds.
* A node restart.

---

## 4. Lab Specification: The Lumina API Gateway

Copy `lab/starter_nginx.conf` to `lab/nginx.conf`. The gateway listens on 8095 and proxies to the `api` upstream. The networks: the load balancer at **10.55.0.5**, operations **10.55.10.0/24**, partners **10.55.20.0/24**, abusive **10.55.66.0/24**.

1. **Refusals:** requests refused by a rate or concurrency limit get `429` and a `Retry-After: 1` header.
2. **API rate:** on `/api/`, each client may make 10 requests per second, and bursts of up to 20 extra requests are answered without delay.
3. **API concurrency:** on `/api/`, each client may have at most 4 requests in progress at once.
4. **Origin protection:** on `/api/`, at most 20 requests are in progress at the origin, across all clients.
5. **Uploads:** `/api/` accepts request bodies up to 2 MB; larger ones get `413`.
6. **Login:** on `/api/login`, each client gets 5 attempts in quick succession, then one more every 12 seconds.
7. **Download speed:** on `/downloads/`, the first 256 KB of each download goes at full speed, then 512 KB/s.
8. **Download concurrency:** each client may run one download at a time.
9. **Partners:** the partner network is exempt from all of `/api/`'s rate and concurrency limits, and always downloads at full speed.
10. **Admin:** only the operations network may use `/admin/`; everyone else gets `403`.
11. **Abusive network:** every request from the abusive network gets `403`, however many it sends.
12. **Load balancer:** requests arriving from the load balancer are treated as coming from the client address it reports in `X-Forwarded-For`. `X-Forwarded-For` from anyone else is ignored.
13. **Slow clients:** a client that hasn't sent its complete request headers within 10 seconds is disconnected.

`lab/solution_nginx.conf` is the reference configuration.

---

## 5. Automated Test Suite (`test_sprint05.sh`)

```bash
cd /srv/nginx-journey/sprints/sprint-5 && ./test_sprint05.sh
```
* It runs `lab/lab.sh check` first. If the lab isn't ready, it stops with a setup message and tests nothing.
* Every run sends from fresh client addresses, so earlier runs and your own experiments don't use up its limits.
* It takes about 20 seconds: the login check waits for a refill, and a slow client runs in the background.
* Run against the untouched starter, it reports 0/13 and **`Sprint 5 start is ready to go`**.
* Override `GW` (the gateway address inside the lab network) or `ORIGIN` to point it elsewhere.

| # | Assertion (gate: 13/13) | Requirement |
| :--- | :--- | :---: |
| 1 | Rate refusals and concurrency refusals on `/api/` are `429` with `Retry-After: 1` | 1 |
| 2 | 40 rapid requests (4 at a time) from one client: 21–23 answered; another client is unaffected | 2 |
| 3 | 8 slow requests at once from one client: 4 answered, 4 refused | 3 |
| 4 | 30 slow requests from 10 clients: 20 answered, 10 refused, at most 20 in progress at the origin | 4 |
| 5 | A 1.5 MB body is accepted; a 3 MB body gets `413` | 5 |
| 6 | 8 rapid logins: 5 answered; 12.5 s later, one more of 2 | 6 |
| 7 | A 200 KB download takes under 0.4 s; a 1 MB download takes 1.1–2.5 s | 7 |
| 8 | Two downloads at once from one client: one answered, one refused | 8 |
| 9 | A partner gets 40/40 rapid requests, 8/8 at once, and 1 MB in under 0.5 s, while an internet client is limited | 9 |
| 10 | `/admin/`: operations `200`, internet `403`, partner `403` | 10 |
| 11 | 30 requests at once from the abusive network: 30 × `403`; `/downloads/` too | 11 |
| 12 | Via the load balancer, a blocked client gets `403` and a partner 40/40; a direct client claiming a partner address is still limited | 12 |
| 13 | A client sending a header line every 2 s is disconnected after 8–13 s | 13 |

---

## 6. Daily Quizzes

All pools live in [`data/quizzes.json`](../../data/quizzes.json). Each day has 20 questions (8 scenario, 6 config, 3 diagnose, 3 recall). The quiz draws 10, and 8/10 passes.

* **Day 1:** the rate as a gap, the excess counter, `burst`/`nodelay`/`delay=`, keys and the empty key, stacking and inheritance, status codes and `Retry-After`, dry run, zone sizing, the phase.
* **Day 2:** what `limit_conn` counts, HTTP/2 streams, `$server_name` keys, `limit_rate` per response, `limit_rate_after`, the slow-client timeouts, request buffering, `client_max_body_size`.
* **Day 3:** `allow`/`deny` order, PREACCESS before ACCESS, `geo` vs `map`, tiers and exemptions, zones across reloads, realip trust and `real_ip_recursive`, what the origin receives.
* **Day 3 Enterprise (optional, 10 questions, not part of graduation):** per-instance limits, the `type=ip` key-value denylist, the API, zone_sync behavior, limit metrics.

```bash
cd /srv/nginx-journey && python3 -m http.server 8090
# http://<lab-host>:8090/quiz.html?sprint=5&day=1   (day=2, day=3, and day=3&pool=enterprise)
```

---

## 7. Optional Extras

* **5.1 Limit by credential and by address.** Key one zone on `$http_x_api_key` and another on `$binary_remote_addr`, both in `/api/`. A client rotates through 50 made-up API keys. Which zone stops it?

  <details>
  <summary>Answer</summary>

  The per-address zone. Each made-up key gets its own fresh bucket in the key zone, so rotating keys defeats a credential-only limit. Keep a per-address limit as the floor, and validate keys before trusting them as a limit key (Sprint 7's `auth_request` or JWT validation).
  </details>

* **5.2 Proxy-side bandwidth.** Read about `proxy_limit_rate`. When would you limit how fast NGINX reads from the upstream, rather than how fast it sends to the client?

  <details>
  <summary>Answer</summary>

  When the upstream is the scarce resource, for example a storage backend shared with other consumers, or a WAN link to a remote origin. `proxy_limit_rate` (with `proxy_buffering on`) paces each upstream response read, so a burst of large downloads can't saturate the backend, while clients are still served from NGINX's buffers.
  </details>

* **5.3 `limit_req` for a whole route, per upstream response code.** Can a rate limit apply only to requests that **fail** (for example, failed logins)?

  <details>
  <summary>Answer</summary>

  Not with `limit_req` alone: it decides in PREACCESS, before the response exists. The usual open source approaches are a strict per-client limit on the login route itself (the lab's 5 per minute), or an `auth_request` subrequest to a service that counts failures (Sprint 7). With NGINX Plus, the application that sees the failures can add offenders to a `keyval` denylist through the API (the side quest's pattern).
  </details>

* **5.4 HTTP/2 and `limit_req`.** Does `limit_req` treat five requests on one HTTP/2 connection differently from five HTTP/1.1 connections?

  <details>
  <summary>Answer</summary>

  No. `limit_req` counts requests, whatever the connection: five streams are five requests against the key's bucket, the same as Day 2 showed for `limit_conn`. That's a difference from connection-rate limits on a load balancer, which see one connection.
  </details>

---

## 8. Tracker Sync

* **Platform milestone:** Lumina's API gateway limits every client's request rate, concurrency and bandwidth, protects the origin from overload and slow clients, gives partners and operations their own policy, refuses an abusive network outright, and sees the real client behind its load balancer.
* **Graduation:** `test_sprint05.sh` 13/13, and at least 80% on each day's quiz (the Enterprise quiz is optional).

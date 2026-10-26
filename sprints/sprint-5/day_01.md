# Sprint 5 &bull; Day 1: Rate Limiting and the Leaky Bucket
**Day:** 1 of 3  
**Estimated Time:** 65 Minutes (15 concepts, 5 setup, 35 activities, 10 quiz)  
**Theme:** On BIG-IP, request rate limits live in a DoS profile or an iRule keeping counters in `table`, and the virtual server's own rate limit counts new **connections**. NGINX has one built-in, declarative tool for request rates, `limit_req`, keyed on whatever you choose and counted per **request**. It's stricter than its one-line config suggests. Today you find out exactly how strict, and how to loosen it on purpose.

---

## 1. Concepts to Understand (15 Minutes)

### 1.1 What `limit_req` Actually Enforces
A limit has two halves:
* **`limit_req_zone`** (at `http` level) defines a **key**, a shared memory **zone** that holds one small state per key, and a **rate**.
* **`limit_req`** (in `http`, `server` or `location`) applies a zone to requests.

**The rate is a minimum gap, not an average.**
* `rate=10r/s` means one request per **100 ms** per key. NGINX tracks time in milliseconds.
* Without `burst`, a request that arrives **earlier** than 100 ms after the last accepted one is rejected, whatever the average looks like.
* So a client sending 12 requests per second, only 20% over, has **half** of them rejected: every other request is 83 ms after its predecessor.
* `r/m` works the same way: `rate=6r/m` is one request every 10 seconds.

**The "excess" counter** is how NGINX tracks a key between requests.
* Each request adds 1.
* Time drains it at the rate.
* A request is rejected when the excess would go **above `burst`**.
* With no `burst`, `burst` is 0, so any early request is over.

This is a **leaky bucket**: requests pour in, the bucket drains at the rate, and `burst` is how much the bucket holds before it overflows.

**The zone holds one state per key**, about 64 bytes each, so roughly 16,000 keys per megabyte.
* When the zone is full, NGINX **evicts the least recently used** states to make room.
* An evicted client's history is gone, so its next request is judged as if it had never been seen. A zone that's too small doesn't fail; it quietly **forgets** the clients you were limiting.
* It's the same trap as Sprint 4's keys zone, with the opposite effect: there, a small zone cost you hits; here, it lets traffic through.

### 1.2 Burst: Queue, `nodelay` and Two-Stage
`burst=N` lets the excess grow to N. What happens to the requests within the burst depends on one more parameter:

| Configuration | Requests within the burst | Requests beyond it |
| :--- | :--- | :--- |
| `burst=5` | **Queued**: answered one per gap (every 100 ms at 10r/s). The client waits; nothing fails. | Rejected at once |
| `burst=5 nodelay` | **Answered at once**. The slots still refill only at the rate. | Rejected at once |
| `burst=8 delay=3` | The first 3 extra are answered at once, the rest **queued** | Rejected at once |

* **The queue paces a client down to the rate.** A client that waits for each answer before sending the next is slowed to 10/s and never rejected.
* **`nodelay` turns the gap rule into an average.** A client 20% over the rate uses up the burst, then gets about 1 in 6 requests rejected.
* **Which to use:**
  * For APIs and pages, `nodelay` is the usual choice: a burst of legitimate requests (a page loading its assets, a retry) shouldn't add latency.
  * The plain queue suits clients that can be slowed down rather than refused.
  * `delay=` (two-stage) is the compromise: a small instant allowance, then smoothing.

### 1.3 Choosing the Key
The key decides **who** shares a bucket:

| Key | One bucket per | Notes |
| :--- | :--- | :--- |
| `$binary_remote_addr` | Client address | 4 bytes for IPv4 (16 for IPv6), smaller than `$remote_addr`'s text. Everyone behind one NAT or proxy shares it (Day 3). |
| `$http_x_api_key`, a cookie, a JWT claim | Credential | Follows the caller across addresses. Anyone can send any value, so pair it with a per-address limit. |
| `$server_name` (or any constant) | The whole server | A global cap: all clients together. Protects the origin, not fairness. |

* **An empty key is never limited.** Requests without an `X-Api-Key` header aren't counted in a zone keyed on it. That's a hole when it's an accident, and Day 3's exemption technique when it's deliberate.
* **Several `limit_req` lines in one context all apply.** A request must pass every one; the strictest wins.
* **Inheritance works like `add_header`** (Sprint 3 Day 3). A `location` with any `limit_req` of its own **drops** every `limit_req` from the `server` or `http` level. Adding a new limit to one location can silently remove the general one.

### 1.4 What the Client Sees, and What You See
* **Rejections are `503` by default.** That tells clients (and monitoring) that the service is down. Set `limit_req_status 429` (Too Many Requests), which tells the client it was them.
* **No `Retry-After` is sent.** You add it yourself, and only to rejections. A `map` on `$limit_req_status` produces a value only for `REJECTED`, and `add_header` doesn't send a header whose value is empty.
* **`$limit_req_status`** is one of `PASSED`, `DELAYED`, `REJECTED`, `DELAYED_DRY_RUN` or `REJECTED_DRY_RUN`. Put it in the access log.
* **Each rejection is logged at `error` level** (`limiting requests, excess: ... by zone "api"`), and delays one level lower. `limit_req_log_level` moves both, so a flood doesn't drown real errors.
* **`limit_req_dry_run on`** applies the limit without enforcing it. Requests pass, the log says what would have happened. It's how you roll out a new limit: measure first, then switch it on.

### 1.5 Where in the Request It Runs
`limit_req` runs in the **PREACCESS** phase (Sprint 3 Day 3's phase list):
* **after** `rewrite`, `set`, `if` and **`return`**, which run in the rewrite phases;
* **before** `allow`/`deny` and authentication (ACCESS), and before content handlers such as `proxy_pass`.

A location that answers with `return` is never rate limited. Day 3 shows why the order against `deny` matters.

### 1.6 BIG-IP Lens

| Need | BIG-IP | NGINX |
| :--- | :--- | :--- |
| Requests per second per client | DoS profile (L7 TPS-based detection) or an iRule with `table incr` + timeout | `limit_req_zone $binary_remote_addr ... rate=` + `limit_req` |
| Rate limit on the virtual server | `rate-limit`: **new connections** per second | No connection-rate limit in `http`; `limit_req` counts **requests**, so keepalive and HTTP/2 don't hide traffic |
| Tolerance for spikes | Detection thresholds and windows | `burst`, with `nodelay` or `delay=` |
| Answer to the client | iRule `HTTP::respond 429` | `limit_req_status 429` (default 503) |
| One count for the whole device | `table` entries are shared by all TMMs | The zone is shared by all workers on the box. Across boxes: Day 3's side quest. |

---

## 2. Lab Setup (5 Minutes)

Sprint 5 runs in containers like Sprint 4: a gateway (`nginx:mainline`), the Lumina API behind it, and a **client container** that can send from any address on the lab network. Rate limits are about **who** sends, so every helper sends from a real source address that you choose.

```bash
cd /srv/nginx-journey/sprints/sprint-5/lab
cp day1_nginx.conf nginx.conf           # gateway on 8095 -> the API, no limits yet
./lab.sh up                             # network, origin, client, gateway, then the ready check
source helpers.sh                       # r, burst, pace, hold, slow, h2, sweep, lim: in every new terminal
```
The first `up` builds a small client image (Python + curl), which takes a few seconds. The ready check ends with `Sprint 5 lab ready: gateway :8095 -> s5-origin:8015, clients from s5-client`.

**The network** (`s5-net`, 10.55.0.0/16). `helpers.sh` names the clients:

| Name | Address | Who |
| :--- | :--- | :--- |
| `$ALICE`, `$BOB` | 10.55.100.11, .12 | Internet clients (the helpers send as `$ALICE` unless you say `--from`) |
| `$OFFICE` | 10.55.10.10 | The operations network, 10.55.10.0/24 (Day 3) |
| `$PARTNER` | 10.55.20.20 | The partner network, 10.55.20.0/24 (Day 3) |
| `$BAD` | 10.55.66.6 | An abusive network, 10.55.66.0/24 (Day 3) |
| `$LB` | 10.55.0.5 | A load balancer in front of the gateway (Day 3) |

| Command | What it does |
| :--- | :--- |
| `r PATH [--from IP]` | One request: `200  0.00s  185 B` (plus speed and `Retry-After` when there are any) |
| `burst N PATH` | N requests at the same moment, each on its own connection: how many got each status, and when |
| `pace N RATE PATH` | N requests one after another at RATE per second, and each status in order |
| `sweep N PATH [--base IP]` | One request from each of N different clients |
| `lim [N]` | The last N access log lines, with `req=$limit_req_status` |
| `./lab.sh reload` | `nginx -t`, reload, wait a second |

`burst`, `pace` and `r` also take `-H 'Name: value'`. Each activity edits `nginx.conf` in `lab/`; after each edit, run `./lab.sh reload`.

---

## 3. Hands-on Guided Discovery Activities (35 Minutes)

### Activity 3.1: First Contact (2 min)
```bash
burst 20 /api/courses
lim 2
```
All 20 are answered at once, and the log shows `req=-`: no limit is involved yet.

### Activity 3.2: A Limit With No Burst (7 min)
Add the zone at `http` level, above `upstream api`:
```nginx
limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;
```
and in `location /api/`, under `proxy_pass`:
```nginx
limit_req zone=api;
```
```bash
./lab.sh reload
burst 20 /api/courses                    # 20 at the same moment
r /api/courses --from $BOB               # a different client, right after
pace 20 8 /api/courses                   # 8 per second, under the rate
```
Alice gets 1 answer and 19 × `503`; Bob isn't affected; 8 per second all pass. Now predict: **12 per second is 20% over the limit. How many of 20 requests are rejected?**
```bash
pace 20 12 /api/courses
lim 3
grep 'limiting' logs/error.log | tail -1
```
<details>
<summary>Answer</summary>

**Half**: `200 503 200 503 ...`. Without `burst`, the rate is a minimum gap of 100 ms. At 12/s, requests are 83 ms apart, so every request that follows an accepted one is early. The error log shows `excess: 0.170`, the 17 ms it was early, as a fraction of the gap. The status is `503` because that's the default (concept 1.4).
</details>

### Activity 3.3: Burst, Queue and `nodelay` (8 min)
Change the `limit_req` line to `limit_req zone=api burst=5;`, reload, and send the same 20 at once:
```bash
./lab.sh reload
burst 20 /api/courses
```
`200 x1 @0.0s  503 x14 @0.0s  200 x1 @0.1s ... 200 x1 @0.5s`: five requests waited in the queue and were answered 100 ms apart.

Now a client that keeps sending 12 per second for five seconds:
```bash
pace 60 12 /api/courses
```
Then change it to `burst=5 nodelay`, reload, and run both again (pacing first this time, and with a pause before the burst, so each starts with an empty bucket):
```bash
./lab.sh reload
pace 60 12 /api/courses
sleep 2; burst 20 /api/courses
```
With the queue, all 60 passed; with `nodelay`, some failed. Why the difference?

<details>
<summary>Answer</summary>

* **Queue:** `pace` waits for each answer before sending the next request, so the queue's 100 ms delays slowed Alice down to exactly 10 per second, and she was never rejected. That's what the queue is for: it paces a client instead of refusing it.
* **`nodelay`:** at 12 per second, the first 30 or so requests passed while the burst filled, and then about **1 in 6** was rejected: the 20% overrun, now averaged. The burst of 20 got 6 answers **at once**, with no waiting.

`burst` turns the strict gap of Activity 3.2 into a tolerance, and `nodelay` decides whether the requests inside the tolerance wait.
</details>

Finally, the two-stage version. Change it to `burst=8 delay=3`, reload:
```bash
./lab.sh reload
burst 20 /api/courses
```
<details>
<summary>What happened?</summary>

`200 x4 @0.0s`, then one every 100 ms up to 0.5 s, and 11 rejected. The first 4 (1 + `delay=3`) were answered at once, the next 5 were queued, and everything beyond the burst of 8 was rejected.
</details>

Set it to `limit_req zone=api burst=20 nodelay;` and reload before going on.

### Activity 3.4: Keys, Stacking and the Inheritance Trap (8 min)
Give API keys a limit of their own. At `http` level:
```nginx
limit_req_zone $http_x_api_key zone=by_key:10m rate=1r/s;
```
and in `location /api/`, under the existing `limit_req`:
```nginx
limit_req zone=by_key burst=2 nodelay;
```
```bash
./lab.sh reload
burst 10 /api/k                                          # no key
burst 10 /api/k -H 'X-Api-Key: team-a' --from $BOB       # key team-a, from Bob
burst 10 /api/k -H 'X-Api-Key: team-a' --from 10.55.100.13
```
<details>
<summary>Results</summary>

* **No key: 10 of 10.** The `by_key` key is empty, so that zone ignores the request, and 10 is within the per-address burst.
* **Bob with `team-a`: 3 of 10.** Both limits apply, and the key's (1/s, `burst=2`) is the stricter.
* **Another address with `team-a`: 0 of 10.** The key's bucket follows the key, not the address, and Bob just emptied it.
</details>

Now a tidy-up that goes wrong. The per-address limit should apply to the **whole** server, so move `limit_req zone=api burst=20 nodelay;` out of `location /api/` and up to the `server` level (under `listen 8095;`). Leave the `by_key` line in `/api/`.
```bash
./lab.sh reload
burst 40 /api/k --conc 4                       # 40 rapid requests, 4 at a time, no key
burst 40 /about --conc 4 --from $BOB           # the same, outside /api/
```
Why is `/api/` now unlimited for clients without a key?

<details>
<summary>Answer</summary>

**Inheritance.** `location /api/` has a `limit_req` of its own (`by_key`), so it inherits **none** from the server level. The server-level limit applies only to locations without their own, like `/` (21 of 40 for Bob: 1 + the burst of 20). Within `/api/`, the only limit left is keyed on a header that these requests don't send, and an empty key is never limited.

The fix: in a location with its own limits, repeat every limit it needs. Leave the server-level line where it is, and add `limit_req zone=api burst=20 nodelay;` back into `/api/` too.
</details>

Make that fix and reload.

### Activity 3.5: Talking Back (5 min)
At `http` level:
```nginx
limit_req_status 429;
map $limit_req_status $retry_after {
    REJECTED  1;
    default   "";
}
```
and at `server` level, under the `limit_req` line:
```nginx
add_header Retry-After $retry_after always;
```
```bash
./lab.sh reload
burst 30 /about
r /about --from $BOB
```
The rejections are now `429 ... (Retry-After: 1)`, and Bob's `200` carries no `Retry-After`: the empty value isn't sent. (How many of the 30 pass depends on Alice's earlier traffic: `/api/` and `/about` now share the server-level zone.)

Now roll out a limit without enforcing it. In `location /`, add `limit_req_dry_run on;`, reload, and flood it:
```bash
./lab.sh reload
burst 30 /about
lim 2
grep 'dry run' logs/error.log | tail -1
```
All 30 pass, and the log says which ones the limit **would** have rejected (`req=REJECTED_DRY_RUN`, `limiting requests, dry run`). Remove the dry-run line and reload.

### Activity 3.6: A Zone Too Small to Remember (5 min)
Add a deliberately tiny zone with a slow rate at `http` level:
```nginx
limit_req_zone $binary_remote_addr zone=tiny:32k rate=1r/m;
```
and a location for it, above `location /`:
```nginx
location /tiny/ {
    proxy_pass http://api;
    limit_req zone=tiny;
}
```
At one request per minute, each client gets one request and then has to wait. Send one request from each of 600 clients, then ask again from the first five and the last five:
```bash
./lab.sh reload
sweep 600 /tiny/
sweep 5 /tiny/                           # 10.55.110.1 - .5, the first five
sweep 5 /tiny/ --base 10.55.112.84       # the last five
grep -ciE 'alloc|no memory' logs/error.log
```
<details>
<summary>What happened?</summary>

* The **last five** get `429`: they were seen a moment ago.
* The **first five** get `200` again, well within their minute. A 32 KB zone holds a few hundred states. To make room for the newer clients, NGINX evicted the oldest ones, and with them the fact that those clients had already used their request.
* Nothing is logged about it.

A real attacker with many addresses gets the same effect. Size zones for the number of **distinct keys** you expect (about 16,000 per MB), with room to spare.
</details>

---

## 4. Day 1 Concept Examination (10-Question Randomized Quiz)

```bash
cd /srv/nginx-journey && python3 -m http.server 8090
```
👉 **http://&lt;lab-host&gt;:8090/quiz.html?sprint=5&day=1**

When you're done for the day: `./lab.sh down`.

---

## 5. Key Takeaways for Day 1
* **`rate=` is a minimum gap per key, enforced to the millisecond.** Without `burst`, 20% over the rate means 50% rejected.
* **`burst` is the tolerance; `nodelay` decides whether requests inside it wait.** A queue paces a client down to the rate. `nodelay` answers at once and turns the rule into an average. `delay=N` does both.
* **The key decides who shares a bucket.** An empty key is never limited, and several limits in one place all apply.
* **A location with its own `limit_req` inherits none.** Repeat every limit it needs.
* **Say `429`, add `Retry-After` yourself, log `$limit_req_status`,** and roll out new limits with `limit_req_dry_run`.
* **A zone that's too small forgets clients silently.** Size it for the number of keys.

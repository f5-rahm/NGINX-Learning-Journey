# Sprint 5 &bull; Day 2: Concurrency, Bandwidth and Slow Clients
**Day:** 2 of 3  
**Estimated Time:** 65 Minutes (15 concepts, 3 setup, 37 activities, 10 quiz)  
**Theme:** Day 1 limited how **often** a client may ask. Today limits how **much** it may hold at once: requests in progress, bytes per second, and the time it may spend sending a request. On BIG-IP these are a connection limit, a rate class and the idle and slow-client timeouts in the TCP and HTTP profiles. On NGINX the TCP stack is the kernel's, but those timeouts are NGINX's own timers. NGINX has a directive for each, and each counts something slightly different from what its name suggests.

---

## 1. Concepts to Understand (15 Minutes)

### 1.1 `limit_conn`: Requests in Progress
`limit_conn_zone` defines a key and a zone, and `limit_conn ZONE N` allows at most N **at the same time** per key.

**What is counted is a request in progress, not a TCP connection**, despite the name:
* A connection is counted only once NGINX has **read the whole request header** and is processing the request. An idle keepalive connection, or one still sending its headers, doesn't count.
* **HTTP/2 and HTTP/3 count every stream.** Five requests multiplexed on one TCP connection are five against the limit.
* It's released when the response is finished. A request that streams a large download holds its slot for the whole download.

**Typical keys:**
* `$binary_remote_addr`: per client. Stops one client from tying up the workers and the origin.
* `$server_name`: one counter for the whole `server`, a cap on what reaches the origin. It works only when the `server` block **sets** `server_name`. Otherwise `$server_name` is empty, and an empty key isn't limited (Day 1).

**The rest works like `limit_req`:**
* The default rejection is `503`; change it with `limit_conn_status`.
* `$limit_conn_status` gives `PASSED`, `REJECTED` or `REJECTED_DRY_RUN`, and `limit_conn_dry_run` exists.
* Several `limit_conn` lines in one place all apply.
* A location with its own `limit_conn` inherits none from above.

**`limit_conn` vs upstream `max_conns`** (Sprint 2):
* `max_conns` caps connections **to each upstream server**. When every server is full, open source NGINX answers 502 (NGINX Plus can queue).
* `limit_conn` caps by **client** (or any key) on the way in, and answers your chosen status.

### 1.2 Bandwidth: `limit_rate`
* **`limit_rate 512k`** limits how fast NGINX sends **one response** (bytes per second; `k` and `m` suffixes).
* **It's per request, not per client.** A client that opens four connections gets four times the bandwidth. Pair it with a `limit_conn` on the same location to make it a per-client limit.
* **`limit_rate_after 256k`** sends the first part at full speed and limits the rest. Small files and the first screenful of a video aren't slowed; bulk downloads are.
* **The rate can come from a variable**, for example a `map` from the client's tier to a rate, where `0` means unlimited. Day 3 builds tiers this way.
* **Related directives:**
  * `proxy_limit_rate` limits how fast NGINX **reads** from the upstream. It's off by default.
  * The `X-Accel-Limit-Rate` header lets the upstream set the rate per response.

**BIG-IP lens:** a rate class is a **shared** pipe: every flow assigned to it splits one rate. `limit_rate` is a **per-response** cap, and `limit_conn` is what keeps a client from multiplying it.

### 1.3 Slow Clients: Slowloris and Slow POST
An event-driven server doesn't run out of threads, but each open connection still costs a file descriptor and memory, and a `limit_conn` slot once the request has been read. Slow clients attack that.

| Timeout | Default | Measures | When it fires |
| :--- | :--- | :--- | :--- |
| `client_header_timeout` | 60s | **The whole request header**, from the start | NGINX logs `408` and **closes the connection without sending anything** |
| `client_body_timeout` | 60s | The gap **between two reads** of the body, not the whole upload | `408`, connection closed |
| `send_timeout` | 60s | The gap between two writes of the response to the client | Connection closed |
| `keepalive_timeout` | 75s | How long an idle keepalive connection is kept | Connection closed |

* **Slowloris** sends headers a few bytes at a time. It isn't counted by `limit_conn` (its request header isn't complete), so the defense is `client_header_timeout`. A total of 60 s per connection is generous.
* **Slow POST** sends a complete header, then the body a byte at a time. Every byte resets `client_body_timeout`, so the timeout alone never ends it. But the request **is** counted by `limit_conn`, so a per-client limit caps how many slots one client can hold this way.
* **The origin isn't involved.** `proxy_request_buffering` is on by default: NGINX reads the whole body before it opens an upstream connection, so a slow upload ties up the gateway, not the origin. BIG-IP's full proxy gives the same protection.

### 1.4 Size Limits
* **`client_max_body_size`** (default **1m**) rejects larger bodies with **413**. When the client announces the size in `Content-Length`, NGINX refuses **before** reading the body (`client intended to send too large body`). Set it per location: uploads big, everything else small. `0` turns the check off.
* Bodies larger than `client_body_buffer_size` (16k by default on 64-bit) are **written to a temp file** (a `[warn]` in the error log), which is disk I/O per upload.
* **`large_client_header_buffers`** caps header size. An oversized header line or request line gets `400` or `414` (a too-long cookie looks like `400 Request Header Or Cookie Too Large`).

### 1.5 Which Tool for Which Abuse

| Abuse | Tool | Counted per |
| :--- | :--- | :--- |
| Too many requests over time | `limit_req` (Day 1) | key, per request |
| Too many requests at once, long downloads, slow uploads | `limit_conn` | key, per request in progress |
| Too many bytes per second | `limit_rate` (+ `limit_conn`) | response |
| Headers sent slowly | `client_header_timeout` | connection, total |
| Body sent slowly | `client_body_timeout` + `limit_conn` | between reads |
| Huge uploads | `client_max_body_size` | request |

---

## 2. Lab Setup (3 Minutes)

```bash
cd /srv/nginx-journey/sprints/sprint-5/lab
cp day2_nginx.conf nginx.conf           # Day 1's rate limit on /api/, plus a /downloads/ location
./lab.sh up                             # or ./lab.sh reload if the lab is still up
source helpers.sh
```
`day2_nginx.conf` already has Day 1's per-client limit on `/api/` (10 requests/s, `burst=20 nodelay`), `limit_req_status 429` and the `Retry-After` map.

New helpers today:

| Command | What it does |
| :--- | :--- |
| `hold N SECS PATH` | N requests at once that the origin keeps open for SECS seconds: requests in progress |
| `h2 N PATH` | N requests at once over **one** HTTP/2 connection (cleartext, `--http2-prior-knowledge`) |
| `slow PATH [--every S] [--body] [--for SECS]` | A client that sends its headers (or, with `--body`, its body) one piece every S seconds, and reports when the gateway gave up on it |
| `r PATH --data-size BYTES` | A `POST` with a body of that size |
| `./lab.sh stats` | The origin's counters, including `inflight` now and `max_inflight` since the last `./lab.sh reset` |

The origin answers `?size=1m` with a 1 MB body, so `/downloads/anything?size=1m` is a download.

---

## 3. Hands-on Guided Discovery Activities (37 Minutes)

### Activity 3.1: Requests in Progress (7 min)
Add a per-client concurrency zone at `http` level, above `upstream api`:
```nginx
limit_conn_zone $binary_remote_addr zone=per_client:10m;
```
and in `location /api/`, under the `limit_req` line:
```nginx
limit_conn per_client 2;
```
```bash
./lab.sh reload
hold 5 2 /api/slow                       # 5 at once, each takes 2 s at the origin
burst 5 /api/fast                        # 5 at once that the origin answers immediately
```
Both give 2 × `200` and 3 × `503`. Even requests that take a millisecond collide when they arrive together.

The status is wrong again. Add `limit_conn_status 429;` under `limit_req_status 429;` and reload:
```bash
./lab.sh reload
hold 5 2 /api/slow
```
The rejections are `429` now, but the summary shows no `Retry-After`. Why not, and how do you fix it?

<details>
<summary>Answer</summary>

The `Retry-After` map from Day 1 looks only at `$limit_req_status`, and a `limit_conn` rejection leaves that `PASSED`. Map both variables at once:
```nginx
map $limit_req_status$limit_conn_status $retry_after {
    ~REJECTED  1;
    default    "";
}
```
The concatenated value is `PASSEDREJECTED` for a concurrency refusal and `REJECTED` for a rate refusal (the concurrency check never runs then). The regex catches both. Reload and run `hold 5 2 /api/slow` again: `429 x 3 (Retry-After: 1)`.
</details>

Make that change, reload, and look at the log:
```bash
./lab.sh reload
hold 5 2 /api/slow
lim 5
```

### Activity 3.2: One Connection, Five Requests (4 min)
Enable HTTP/2 on the server (at `server` level, under `listen 8095;`):
```nginx
http2 on;
```
Predict before you run it: five requests on **one** HTTP/2 connection, with `limit_conn per_client 2`. How many succeed?
```bash
./lab.sh reload
h2 5 '/api/slow?delay=2'
lim 1
```
<details>
<summary>Answer</summary>

`5 over HTTP/2, 1 TCP connection(s): 200 x 2, 429 x 3`. Each stream is a request in progress, so one multiplexed connection can't get around the limit, and an honest HTTP/2 browser can't be given more than its share either. The log line says `HTTP/2.0`.
</details>

### Activity 3.3: A Cap for the Origin (6 min)
Limit how many API requests reach the origin at once, across all clients. At `http` level:
```nginx
limit_conn_zone $server_name zone=origin:1m;
```
and in `location /api/`, under `limit_conn per_client 2;`:
```nginx
limit_conn origin 3;
```
Three clients each send two slow requests (six at once):
```bash
./lab.sh reload
./lab.sh reset
(hold 2 2 /api/o --from $ALICE & hold 2 2 /api/o --from $BOB & hold 2 2 /api/o --from 10.55.100.13 & wait)
./lab.sh stats | grep max_inflight
```
All six succeeded, and the origin had 6 in flight. Why didn't the cap of 3 work?

<details>
<summary>Answer</summary>

The `server` block has no `server_name`, so `$server_name` is **empty**, and requests with an empty key aren't limited (Day 1). Add `server_name lumina;` under `listen 8095;`, reload and run the same three commands again. Now 3 succeed, 3 get `429`, and `max_inflight` is 3.
</details>

Make the fix and check it.

### Activity 3.4: Bandwidth (9 min)
Limit downloads. In `location /downloads/`, under `proxy_pass`:
```nginx
limit_rate 200k;
```
```bash
./lab.sh reload
r '/downloads/big?size=1m'               # about 5 s at about 200 KB/s
burst 4 '/downloads/big?size=1m'         # four at once from the same client
```
How much bandwidth did Alice get with four downloads?

<details>
<summary>Answer</summary>

Four times as much. All four finished in about 4.9 s, the same as one: `limit_rate` applies to each response. A download manager that opens parallel connections multiplies it.
</details>

Make it per client. Add `limit_conn per_client 1;` to `/downloads/`, reload, and try again:
```bash
./lab.sh reload
burst 4 '/downloads/big?size=1m'
```
One downloads, three get `429`. The same `per_client` zone now serves two locations, with a different maximum in each. Predict: Alice has one slow API request in progress. Can she start a download?
```bash
hold 1 3 /api/slow & sleep 1; r '/downloads/small?size=1k'; wait
```
<details>
<summary>Answer</summary>

No: `429`. The zone keeps **one count per key**, and every `limit_conn` that uses the zone adds to it, in any location. Alice's API request counts against the download limit of 1, and her downloads count against the API limit of 2. Each `limit_conn` line only sets the maximum it checks the shared count against. To limit two things independently, give each its own zone.
</details>

Give downloads their own zone. At `http` level:
```nginx
limit_conn_zone $binary_remote_addr zone=downloads:10m;
```
and in `/downloads/`, change `limit_conn per_client 1;` to `limit_conn downloads 1;`:
```bash
./lab.sh reload
hold 1 3 /api/slow & sleep 1; r '/downloads/small?size=1k'; wait     # 200 now
burst 4 '/downloads/big?size=1m'                                     # still one at a time
```

Now leave small files alone. Add `limit_rate_after 500k;` above `limit_rate 200k;`:
```bash
./lab.sh reload
r '/downloads/big?size=1m'               # the first 500 KB at full speed, then 200 KB/s: about 2.5 s
r '/downloads/small?size=400k'           # not slowed at all
```

### Activity 3.5: Slow Clients (8 min)
Shorten the timeouts. At `server` level, under `server_name lumina;`:
```nginx
client_header_timeout 5s;
client_body_timeout 5s;
```
First, a **slowloris** client: it sends a header line every 2 s, and while it's dribbling, Alice sends two normal slow requests (the limit is 2 per client):
```bash
./lab.sh reload
slow /api/x --every 2 & sleep 1; hold 2 1 /api/y; wait
lim 3
```
<details>
<summary>What do the results show?</summary>

* The slow client was cut off after **5.0 s**, even though it was sending something every 2 s: `client_header_timeout` covers the whole header. The log shows `408`, but the client got nothing back ("closed the connection without an answer").
* Both normal requests succeeded. The slowloris connection didn't use one of Alice's two `limit_conn` slots, because its request was never complete. That's why the header timeout is the defense here.
</details>

Now a **slow POST**: a complete header announcing a 4 KB body, then one byte every 2 s. While it runs, Alice sends two normal requests and checks the origin:
```bash
slow /api/upload --body --every 2 --for 12 & sleep 2; hold 2 1 /api/y; ./lab.sh stats | grep '"inflight"'; wait
slow /api/upload --body --every 6 --for 12
lim 1
```
<details>
<summary>What do the results show?</summary>

* **Every 2 s, the upload is never cut off.** The client gave up after 12 s, still connected: `client_body_timeout` measures the gap between reads, and each byte resets it.
* **Alice got only one of her two requests** (`429` for the other): the slow upload **is** a request in progress, so it held one of her two slots. A per-client `limit_conn` is what limits how many of these one client can run.
* **The origin had 0 requests in flight** while the upload dribbled. NGINX buffers the whole body before contacting the upstream, so a slow client never ties up the origin.
* **Every 6 s, the upload is cut off after 5.0 s**, the first gap longer than the timeout (`408`).
</details>

### Activity 3.6: Body Size (3 min)
```bash
r /api/upload --data-size 2000000
grep 'too large' logs/error.log | tail -1
```
A 2 MB `POST` gets `413`: the default `client_max_body_size` is 1 MB, and NGINX refused it from the `Content-Length` before reading the body. Allow 2 MB on `/api/` only. In `location /api/`, add:
```nginx
client_max_body_size 2m;
```
```bash
./lab.sh reload
r /api/upload --data-size 2000000        # 200
r /api/upload --data-size 3000000        # 413
```

---

## 4. Day 2 Concept Examination (10-Question Randomized Quiz)

```bash
cd /srv/nginx-journey && python3 -m http.server 8090
```
👉 **http://&lt;lab-host&gt;:8090/quiz.html?sprint=5&day=2**

When you're done for the day: `./lab.sh down`.

---

## 5. Key Takeaways for Day 2
* **`limit_conn` counts requests in progress,** after the header is read. Every HTTP/2 stream counts; idle and half-sent connections don't.
* **A `$server_name` key needs a `server_name`.** An empty key limits nothing, without an error.
* **`limit_rate` is per response.** Add `limit_conn` to make it per client, and `limit_rate_after` to spare small files.
* **A `limit_conn` zone keeps one count per key across every location that uses it.** Separate limits need separate zones.
* **`client_header_timeout` is a total, `client_body_timeout` is between reads.** The header timeout stops slowloris; a per-client `limit_conn` caps slow uploads.
* **Request buffering keeps slow clients off the origin.** The gateway holds them, which is why its own limits matter.
* **Map both `$limit_req_status` and `$limit_conn_status`** if every refusal should carry `Retry-After`.

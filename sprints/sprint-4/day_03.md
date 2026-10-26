# Sprint 4 &bull; Day 3: Kernel and Connection Limits & the Sprint Lab
**Day:** 3 of 3  
**Estimated Time:** 85 Minutes (15 concepts, 2 setup, 23 activities, 35 Lumina build, 10 quiz)  
**Optional:** [Enterprise Side Quest](day_03_enterprise.md), 40 minutes: purge on demand and cache metrics with NGINX Plus  
**Theme:** On BIG-IP, TMM owns the TCP stack and you tune it with TCP profiles. NGINX runs on the Linux kernel's TCP stack, so some of the limits that decide whether a busy edge keeps up aren't in `nginx.conf` at all. Today finds them, overflows them on purpose, and then puts the whole sprint together.

---

## 1. Concepts to Understand (15 Minutes)

### 1.1 The Accept Queue
A new TCP connection passes through the kernel before NGINX sees it:
1. **The handshake completes in the kernel.** The connection then waits in the listening socket's **accept queue**.
2. **A worker's event loop (`epoll`) sees it** and calls `accept()`. Only now is it NGINX's connection.

**How long the queue is**
* NGINX asks for a length with `listen ... backlog=N`. On Linux the default is **511**.
* The kernel caps it at **`net.core.somaxconn`** without telling you. `backlog=4096` with `somaxconn=128` gives a queue of 128, and neither `nginx -t` nor the error log mentions it.
* A reload applies a new `backlog` to the existing socket. No restart is needed.

**When it overflows**
* The queue fills when workers stop calling `accept()` for a moment. Causes include a CPU-starved host, a blocking disk read, or a worker stuck in a slow third-party module.
* Once it's full, the kernel **drops new handshakes**. The client's TCP stack retries the SYN after 1 s, then 3 s, then 7 s. **A half-second stall becomes a 3-second wait** for whoever overflowed, and nobody sees an error.
* **The evidence is in kernel counters, not in NGINX's logs:**
  * `ss -lnt` shows a listener's queue: `Recv-Q` is the number waiting now, `Send-Q` is the limit.
  * `nstat` shows `TcpExtListenOverflows` and `TcpExtListenDrops`.

**`reuseport`** (Sprint 3 met it for QUIC) gives **each worker its own socket and its own queue**. The kernel spreads new connections across them, so one stalled worker only stalls its share.

### 1.2 File Descriptors
Everything a worker holds open is a file descriptor:
* each client connection;
* each **upstream** connection;
* each cache file being read or written;
* the log files.

**Two separate limits**
* **`worker_connections`** (`events`) is NGINX's own cap on connections per worker, client and upstream together. A proxy needs about two per active request.
* **`RLIMIT_NOFILE`** is the operating system's cap on open files per process. It has a **soft** limit (enforced) and a **hard** limit (the most the soft limit can be raised to). Docker's default is 1024 soft and 524288 hard.

**`worker_rlimit_nofile N`** makes each worker raise its own limit to N.
* NGINX warns at start if `worker_connections` is larger than the open-file limit. Nothing fails until the traffic comes.
* **When the limit is hit:**
  * `accept4() failed (24: Too many open files)` means new connections wait in the accept queue;
  * `open() ... failed (24: Too many open files)` on a cache file means the client gets a **500**.
* **It can't go above the hard limit** without a privilege that containers don't have by default. NGINX logs `setrlimit(RLIMIT_NOFILE, ...) failed (1: Operation not permitted)` and carries on with the old limit. `nginx -t` passes, and so does every health check.
* **Rule of thumb for a caching proxy:** `worker_rlimit_nofile` at least 2× `worker_connections`, plus headroom for cache files.

### 1.3 Connections to the Origin: Ports and TIME_WAIT
Each connection the edge opens to the origin uses an **ephemeral port** from `net.ipv4.ip_local_port_range`, which is 32768–60999, about 28,000 ports. One destination address and port gets at most that many connections at a time.
* **The side that closes a TCP connection first keeps it in TIME_WAIT for 60 seconds.** Its port can't be reused for that destination during that time.
* An edge that opens and closes a new connection for every origin request can sustain only about **28,000 / 60 ≈ 470 new connections per second** to one origin. Above that, `connect()` fails with **`(99: Cannot assign requested address)`** and clients get 502s.
* **`net.ipv4.tcp_tw_reuse`** lets the kernel reuse a TIME_WAIT port for a new **outgoing** connection once it's at least a second old.
  * `2`, the default, means loopback only.
  * `1` means all destinations.
  * It's relief, not a cure. `tcp_tw_recycle` is gone from Linux (4.12); ignore old guides that set it.
* **The cure is not to churn connections.** Upstream keepalive reuses a few dozen connections for thousands of requests. It's on by default since nginx 1.29.7 (Sprint 2 Day 2). Check that nothing turns it off: `keepalive 0`, a `Connection: close` header, or an origin that closes after every response.

### 1.4 Where These Settings Live

| Setting | Where it's set | Scope |
| :--- | :--- | :--- |
| `backlog=`, `reuseport`, `worker_connections`, `worker_rlimit_nofile` | `nginx.conf` | NGINX |
| `net.core.somaxconn`, `net.ipv4.ip_local_port_range`, `net.ipv4.tcp_tw_reuse` | `sysctl` | **Per network namespace.** On a host: `/etc/sysctl.d/`. In a container: `docker run --sysctl`, or the orchestrator's pod settings. |
| Open-file hard limit | systemd `LimitNOFILE=` for a packaged NGINX; `docker run --ulimit nofile=` in a container | Per process |

* A container gets its **own** network namespace, so the host's `sysctl` values don't apply inside it.
* `lab.sh` recreates the edge with `SOMAXCONN=`, `NOFILE=`, `PORTS=` and `TW_REUSE=` for exactly this reason.

### 1.5 The Event Loop Knobs You Can Leave Alone
* **`use epoll`** is chosen automatically on Linux.
* **`accept_mutex`** is off by default, and the kernel's `EPOLLEXCLUSIVE` wakes one worker per new connection.
* **`multi_accept`** (off) makes a worker accept everything waiting at once. It's rarely worth changing.

Tune `backlog`, `reuseport`, `worker_connections` and `worker_rlimit_nofile` first, and measure with `ss` and `nstat` before and after.

---

## 2. Lab Setup (2 Minutes)

Start from Day 2's finished behavior. `./lab.sh edge` **recreates** the edge container with default kernel settings, which today matters:
```bash
cd /srv/nginx-journey/sprints/sprint-4/lab
cp day3_nginx.conf nginx.conf           # Day 2's result: the full cache behavior, default capacity settings
./lab.sh check >/dev/null 2>&1 || ./lab.sh up
./lab.sh edge                           # fresh edge: somaxconn 4096, nofile 1024:524288
source helpers.sh
```

| New today | What it does |
| :--- | :--- |
| `./lab.sh ss [args]` | `ss` inside the edge's network namespace (default `-lnt`) |
| `./lab.sh nstat [args]` | Kernel counters inside it. `nstat` prints what changed since its last run, so run it once to reset. |
| `./lab.sh freeze [S]` | Pauses the edge's workers (SIGSTOP) until connections start queuing, holds them for S seconds (default 2), then resumes them: a stalled event loop |
| `SOMAXCONN=` `NOFILE=` `PORTS=` `TW_REUSE=` `./lab.sh edge` | Recreate the edge with those kernel settings. Plain `./lab.sh edge` goes back to the defaults. |

Reminder from Day 2: `./lab.sh load [oha args] /path` is `oha`, run in a container on the lab network and aimed at the edge (so it sends `Host: s4-edge`).

---

## 3. Hands-on Guided Discovery Activities (23 Minutes)

### Activity 3.1: Read the Limits (3 min)
```bash
./lab.sh ss -lnt 'sport = :8084'                           # Send-Q = the accept queue limit
docker exec s4-edge cat /proc/sys/net/core/somaxconn
for p in $(./lab.sh workers | awk '/worker process/ { print $1 }'); do grep 'open files' /proc/$p/limits; done
```
* The queue limit is **511**, NGINX's default backlog, well under the container's `somaxconn` of 4096.
* Each worker can hold **1024** files.

### Activity 3.2: A Stalled Worker and a Short Queue (8 min)
Make the queue short: change the `listen` line to `listen 8084 backlog=16;`.
```bash
./lab.sh reload
r /o/1 -H 'Host: s4-edge' >/dev/null     # cache the page under the Host oha sends (the key includes $host)
./lab.sh nstat >/dev/null                 # reset the counters
( ./lab.sh freeze 1.5 & ./lab.sh load -n 100 -c 100 --disable-keepalive /o/1; wait )
./lab.sh nstat | grep -i listen
```
The workers stall for 1.5 seconds while 100 clients connect. Look at `Fastest`, `Slowest` and the response time histogram.

<details>
<summary>What happened</summary>

* `freeze` reports `17 waiting, limit 16`. The queue was full, and `TcpExtListenOverflows` counted every dropped handshake (each client retries, so the count is more than 100).
* The 17 queued connections were answered at about **1.5 s**, right after the stall.
* Everyone else waited for their SYN retry and was answered at about **3.2 s**. A 1.5-second stall cost them twice that.
</details>

Now give the queue room: `listen 8084 backlog=4096;`
```bash
./lab.sh reload
./lab.sh nstat >/dev/null
( ./lab.sh freeze 1.5 & ./lab.sh load -n 100 -c 100 --disable-keepalive /o/1; wait )
./lab.sh nstat | grep -i listen           # nothing: no overflows
```
All 100 are answered at about 1.5 s. Then shrink the kernel's cap below it:
```bash
SOMAXCONN=128 ./lab.sh edge
./lab.sh ss -lnt 'sport = :8084'
grep -ci backlog logs/error.log
./lab.sh edge                             # back to the default somaxconn
```
<details>
<summary>What does the queue limit show?</summary>

`128`. The kernel silently capped `backlog=4096` at `somaxconn`, and the error log says nothing. A `backlog` in `nginx.conf` is a request, not a guarantee.
</details>

### Activity 3.3: Out of File Descriptors (6 min)
Raise NGINX's connection cap, but not the file limit: `events { worker_connections 8192; }`
```bash
./lab.sh reload
grep -a 'exceed' logs/error.log | tail -1
./lab.sh load -z 6s -c 3000 /o/1          # 3,000 connections, about 1,500 per worker
grep -a 'Too many open files' logs/error.log | sed -E 's/^.*\[(crit|alert)\] [0-9#]+: (\*[0-9]+ )?//; s/"[^"]*"/"..."/; s/(, client| while).*//' | sort | uniq -c
```
Look at the status code lines in `oha`'s output, and the error log summary.

<details>
<summary>What happened</summary>

* At reload, NGINX warned `8192 worker_connections exceed open file resource limit: 1024`.
* Under load, a few hundred clients got **500**: `open() ... failed (24: Too many open files)` on the **cached file** they asked for.
* A few `accept4() failed (24: ...)` lines mean some connections waited in the accept queue until a descriptor freed up. That's where the multi-second slowest response came from.
</details>

Add at the top level, above `events`:
```nginx
worker_rlimit_nofile 16384;
```
```bash
./lab.sh reload
for p in $(./lab.sh workers | awk '/worker process/ { print $1 }'); do grep 'open files' /proc/$p/limits; done
./lab.sh load -z 6s -c 3000 /o/1          # all 200
```
Now take the headroom away at the container level:
```bash
NOFILE=1024 ./lab.sh edge                 # hard limit 1024
grep -a setrlimit logs/error.log | tail -1
for p in $(./lab.sh workers | awk '/worker process/ { print $1 }'); do grep 'open files' /proc/$p/limits; done
./lab.sh edge                             # back to the default limits
```
<details>
<summary>What does the edge report?</summary>

* The ready check is green and `nginx -t` passes.
* The error log has `[alert] setrlimit(RLIMIT_NOFILE, 16384) failed (1: Operation not permitted)`, and the workers are still at 1024.
* The directive is only as good as the hard limit the platform allows.
</details>

### Activity 3.4: Running Out of Ports (6 min)
Shrink the edge's port range to 1,000 ports so you can reach the limit in seconds:
```bash
PORTS="40000 40999" ./lab.sh edge
./lab.sh reset
./lab.sh load -z 8s -c 20 -H 'Authorization: x' /k/1    # every request goes to the origin (Day 1)
./lab.sh stats | grep connections
```
Every request reached the origin, all 200, over a few dozen TCP connections: keepalive. Now turn keepalive off. In `upstream origin`, add `keepalive 0;`:
```bash
./lab.sh reload
./lab.sh load -z 8s -c 20 -H 'Authorization: x' /k/2
grep -ac 'Cannot assign requested address' logs/error.log
./lab.sh ss -Htan state time-wait | wc -l
```
<details>
<summary>What happened</summary>

* About 1,000 requests succeeded. Then nearly every request got a **502**: `connect() ... failed (99: Cannot assign requested address)`.
* About 1,000 sockets sit in TIME_WAIT on the **edge**, which closed each connection first.
</details>

Try the kernel's relief valve, still without keepalive:
```bash
PORTS="40000 40999" TW_REUSE=1 ./lab.sh edge
./lab.sh load -z 8s -c 20 -H 'Authorization: x' /k/3
```
Better, but still thousands of 502s: `tcp_tw_reuse` only reuses ports that have been in TIME_WAIT for a second. Remove `keepalive 0;`, then go back to default kernel settings:
```bash
./lab.sh edge
```

---

## 4. Sprint Lab: The Lumina Edge Accelerator (35 Minutes)

Requirements: [README Section 4](README.md#4-lab-specification-the-lumina-edge-accelerator).

**First, the baseline.** Load the untouched starter and run the test. It should load cleanly and fail every requirement:
```bash
cd /srv/nginx-journey/sprints/sprint-4/lab
cp nginx.conf my_day3_nginx.conf          # keep your activity work
cp starter_nginx.conf nginx.conf
./lab.sh edge                             # a fresh edge with default kernel settings
cd .. && ./test_sprint04.sh
```
Expect `Requirements: 0 / 10 passed` and **`Sprint 4 start is ready to go`**. If the preflight fails instead, that's a setup problem: fix the `[!!]` lines first.

**Then build it.** Every TODO in `lab/nginx.conf` is a requirement. Days 1–3 have the how.
```bash
cd lab && ./lab.sh reload                 # after each round of edits
cd .. && ./test_sprint04.sh               # gate: 10/10
```
* The test uses fresh URLs every run, so earlier activities don't affect it.
* Tests 7 and 8 briefly switch the origin into failure and slow modes, and switch it back.
* Tests 9 and 10 read the edge's network namespace and `/proc`, so run the test as root.
* `lab/solution_nginx.conf` is the reference. Try the test first.

---

## 5. Day 3 Concept Examination (10-Question Randomized Quiz)

👉 **http://&lt;lab-host&gt;:8090/quiz.html?sprint=4&day=3** (serve with `cd /srv/nginx-journey && python3 -m http.server 8090`)

The optional Enterprise Side Quest has its own 10-question quiz. It doesn't count toward graduation.

---

## 6. Key Takeaways for Day 3
* **The accept queue is `min(backlog, somaxconn)`,** and the kernel caps it silently. Overflows show up only in `ss` and `nstat`, as clients waiting for SYN retries.
* **`reuseport` gives each worker its own queue,** so one stalled worker stalls only its share.
* **Every connection and every open cache file is a descriptor.** `worker_rlimit_nofile` has to cover `worker_connections` (about twice, for a proxy), and it can't exceed the hard limit the platform sets.
* **Running out shows up as 500s and slow accepts,** and only under load: health checks and `nginx -t` stay green.
* **Ephemeral ports run out when the edge churns connections to the origin.** `tcp_tw_reuse` buys a little; keepalive fixes it.
* **Kernel settings are per network namespace.** In containers they belong to the container's run settings, not the host's `sysctl.conf`.

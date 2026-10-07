# Sprint 2 &bull; Day 2: Upstream Pools, Balancing & Connection Reuse
**Date:** Wednesday, Oct 7  
**Estimated Time:** 60 Minutes (15 concepts, 5 setup, 35 lab, 10 quiz)  
**Theme:** Which backend gets the next request is a policy decision. Learn each policy's failure mode by watching it happen.

---

## 1. Concepts to Understand (15 Minutes)

### 1.1 The `upstream` Block
```nginx
upstream lumina_api_nodes {
    least_conn;                                   # balancing method (default: round-robin)
    server 127.0.0.1:8001 weight=3;               # gets ~3x the share
    server 127.0.0.1:8002;
    server 127.0.0.1:8004 backup;                 # only when all primaries are unavailable
    server 127.0.0.1:8005 down;                   # permanently out (keeps ip_hash mapping stable)
}
```

**Parameters covered on other days**
* `max_fails` / `fail_timeout`: Day 3.
* `drain`, `resolve`, `slow_start`: Day 4.

### 1.2 Per-Worker State and the `zone` Directive
```nginx
upstream lumina_api_nodes {
    zone lumina_api_nodes 64k;    # name + shared memory size
    least_conn;
    server 127.0.0.1:8001;
    server 127.0.0.1:8002;
}
```
**The problem it solves**
* Workers are separate processes that share nothing by default.
* Without a `zone`, every worker holds its **own private copy** of each upstream (inherited from the master) and keeps its own runtime state.
* NGINX therefore runs `worker_processes` independent load balancers that never compare notes.

| Upstream state | Without `zone` | With `zone` |
| :--- | :--- | :--- |
| Round-robin position | Per worker | Shared |
| Active connections (`least_conn`) | Per worker: a worker sees only its own in-flight requests | Shared: true totals |
| Failure counts and "unavailable" marks (`max_fails` / `fail_timeout`) | Per worker: a dead server is retried until **each** worker has seen `max_fails` failures | Shared: marked down once, for everyone |
| Response-time averages (`least_time`) | Per worker | Shared |
| Idle keepalive connections | Per worker | **Still per worker.** Sockets belong to a process; `zone` doesn't change that. |

**What you'll see when there's no zone**
* `least_conn` sends new work to a node that's already busy. You'll measure this in Activity 3.3.
* Recovery after a failure is inconsistent: some workers still treat a node as down while others use it. You'll see this in Activity 3.5.
* A dead node gets hit more times than `max_fails` before it's skipped. Day 3 measures this.
* The more workers you run (`worker_processes auto` on a 32-core box), the worse all three get.

**What requires a zone**
* `server ... resolve` refuses to load without one.
* The NGINX Plus API and `state` files (Day 4) also need it.

**Cost:** a small fixed block of shared memory (`64k` is the usual starting size in the docs) and brief locking when state is updated. Nearly every production upstream should have one.

*BIG-IP lens:* don't assume BIG-IP-style box-wide member status. In NGINX OSS, even passively learned "this server is down" is private to each worker unless the upstream has a `zone`.

### 1.3 Balancing Methods and How Each Goes Wrong

| Method | How it picks | Best for | Failure mode |
| :--- | :--- | :--- | :--- |
| *(default)* round-robin | Smooth weighted rotation | Uniform, short requests | Ignores how busy a node is. Slow requests pile up on whichever node got them. |
| `least_conn` | Fewest active connections (weighted), round-robin on ties | Variable-duration work: LLM streams, reports, uploads | Without a `zone`, each worker only counts its own connections (1.2). |
| `ip_hash` | First **three octets** of the IPv4 client (whole IPv6 address) | Legacy stateful apps without cookies | Everyone behind one NAT, corporate proxy, CDN, or `/24` lands on one node. |
| `hash $key` | `hash(key) mod N` | Routing by tenant, user, or URI | Adding or removing a node remaps **most** keys. |
| `hash $key consistent` | Ketama ring (160 points per server) | Caches and sharded data | Adding one node moves only about 1/N of keys, all onto the new node. |

Also available, and covered in the quizzes rather than the lab:
* `random [two [least_conn]]`: "power of two choices".
* `least_time`: open source since 1.31.0, previously Plus-only.
* `sticky`: cookie-based session affinity, open source since 1.29.6 (Day 4).

### 1.4 Restrictions Worth Memorizing
* **`backup`** can't be combined with `hash`, `ip_hash`, or `random`. `nginx -t` fails with `balancing method does not support parameter "backup"`.
* **`slow_start`** has the same restriction in NGINX Plus. In open source, `nginx -t` rejects it outright as an `invalid parameter`, because it is still Plus-only (Day 4).
* **With `ip_hash`, take a node out using `down`, never by deleting the line.** Deleting it changes N and reshuffles every client.

### 1.5 Upstream Keepalive: Connection Reuse
**Why reuse matters**
* Without reuse, every proxied request costs a TCP handshake to the backend.
* Every closed connection then leaves a socket in `TIME_WAIT` (60 s on Linux) on **whichever side closed first**.
  * With the old HTTP/1.0 default, the backend closes after answering, so `TIME_WAIT` piles up on the app servers.
  * When NGINX closes first (for example, when its idle pool is full), the NGINX host holds them. At thousands of new connections per second to one `ip:port`, those exhaust NGINX's ephemeral port range (Side Quest 2.3).

**How the pool works**
* `keepalive N` sets how many idle connections **each worker** caches per upstream group.
* It is not a limit on total connections.

**What changed in nginx 1.29.7**

| | Before 1.29.7 (and most distro packages) | 1.29.7+ (the lab's 1.31.6) |
| :--- | :--- | :--- |
| `keepalive` in `upstream` | Off unless set | **On: `keepalive 32 local`** |
| `proxy_http_version` | `1.0` | **`1.1`** |
| `Connection` header to the backend | `close` | **Not sent** |
| What you must write | `keepalive 16;` + `proxy_http_version 1.1;` + `proxy_set_header Connection "";` | Nothing |

* `local` means cached connections aren't shared between different `location` blocks, even when they point at the same server.
* On the old recipe, leaving out **any one** of the three lines silently disables reuse.

---

## 2. Lab Setup (5 Minutes)

```bash
cd /srv/nginx-journey/sprints/sprint-2/lab
./mocks.sh start && ./mocks.sh start 8004         # api-node-1/2, chat-ws, plus api-node-3 on 8004
cp day2_nginx.conf nginx.conf
ngx -t && ngx -s reload 2>/dev/null || ngx       # reload if running, start otherwise
```

Helper to count which node answered:
```bash
tally() {   # tally <path> [count]
  for i in $(seq "${2:-100}"); do
    curl -s -H 'Host: lumina.local' "localhost:8082$1" | jq -r .node
  done | sort | uniq -c
}
```

---

## 3. Hands-on Guided Discovery Activities (35 Minutes)

### Activity 3.1: Round-Robin and Weights (4 min)
```bash
tally /rr/x
tally /weighted/x
```
* Expect about 50/50, then about 75/25.
* Even with two workers balancing independently, the totals come out right.

### Activity 3.2: The `ip_hash` NAT Problem (4 min)
```bash
tally /sticky/x
```
* 100% lands on one node. Every request comes from `127.0.0.1`, so the hash key (`127.0.0`) never changes.
* In production, the same thing happens to an entire office behind one NAT address, or to all traffic arriving through a CDN or load balancer whose addresses share a `/24`.

*Journal:* how would you get stickiness that survives NAT? Look ahead to `sticky cookie` (Day 4) or `hash $cookie_session consistent`.

### Activity 3.3: `least_conn` and Why `zone` Matters (8 min)
Hold one slow request open (6 s), then send 20 fast ones while it runs. Do it three times:
```bash
for loc in rr lc lcz; do
  curl -s "localhost:8082/$loc/slow?delay=6" -o /dev/null & sleep 0.5
  echo "== /$loc/ with one slow request in flight"; tally /$loc/fast 20
  wait
done
```
Results on the lab box (yours will be similar):

| Location | Pool | Fast requests sent to the busy node |
| :--- | :--- | :--- |
| `/rr/` | round-robin | 10 of 20. Round-robin doesn't care. |
| `/lc/` | `least_conn`, no zone | ~6 of 20. The *other* worker can't see the busy connection. |
| `/lcz/` | `least_conn` + `zone` | **0 of 20** |

*Why:* without a `zone`, active-connection counts live in each worker's private memory. With 2 workers, about half the fast requests land on a worker that thinks both nodes are idle. **Production rule:** give every non-trivial upstream a `zone`.

### Activity 3.4: Hash Remapping, Modulo vs Ring (8 min)
Record where 200 different URIs land:
```bash
map_keys() { for i in $(seq 200); do echo "$i $(curl -s localhost:8082/$1/item-$i | jq -r .node)"; done; }
map_keys ring > ring.before; map_keys modulo > modulo.before
```
Now add `server 127.0.0.1:8004;` to **both** `ring_pool` and `modulo_pool` in `nginx.conf`, then:
```bash
ngx -t && ngx -s reload && sleep 1
map_keys ring > ring.after; map_keys modulo > modulo.after
echo "ring:   $(paste ring.before ring.after | awk '$2!=$4' | wc -l)/200 moved"
echo "modulo: $(paste modulo.before modulo.after | awk '$2!=$4' | wc -l)/200 moved"
paste ring.before ring.after | awk '$2!=$4 {print $4}' | sort | uniq -c    # where did ring keys go?
```
On the lab box, the ring moved **79/200** keys (ideal is 1/3 ≈ 67), and every one of them went to the new node. Modulo moved **136/200**, shuffling keys between the *old* nodes too. For a cache tier, every moved key is a cache miss.

### Activity 3.5: `backup` and Recovery Timing (5 min)
```bash
tally /backup/x 10                       # node-1 and node-2 only
./mocks.sh stop 8001;      tally /backup/x 10   # node-2 takes everything; backup still idle
./mocks.sh stop 8002;      tally /backup/x 10   # all primaries down: node-3 (backup) serves
./mocks.sh start 8001 8002; tally /backup/x 10  # immediately after recovery...
sleep 11;                  tally /backup/x 10   # ...and after fail_timeout expires
```
Expected counts per 10-request tally (measured on the lab box over several runs):

| Step | Expected | Why |
| :--- | :--- | :--- |
| Baseline | ~5 node-1 / ~5 node-2 (4/6 is normal) | Round-robin; the backup is idle |
| 8001 stopped | 10 node-2 | 8001 fails once per worker and is marked unavailable there. The retry on node-2 hides the failure from the client. |
| 8002 stopped | 10 node-3 | No primary is available, so the backup serves |
| Right after recovery | **Varies: 10 node-3, 8 node-2 + 2 node-3, 6 + 4, or 10 node-2** | Both primaries are healthy, but still marked unavailable for `fail_timeout` (10 s by default) |
| After 11 s | ~5 / ~5 again, backup idle | `fail_timeout` expired |

**Why "right after recovery" varies:** `backup_pool` has no `zone`, so each worker keeps its own failure marks (1.2). A worker that saw 8002 fail still treats it as down; a worker that didn't uses it. How the 10 requests split between workers decides the count.

*Try it:* add `zone backup_pool 64k;` to `backup_pool`, reload, and repeat the sequence. Compare the "right after recovery" step.

**Takeaways**
* Passive health checks only learn about recovery when `fail_timeout` expires, even if the node is already healthy.
* Day 3 tunes `max_fails` and `fail_timeout`. Active health checks, which probe nodes instead of waiting for a client to fail, are in Sprint 12.

### Activity 3.6: Measuring Connection Reuse (6 min)
The mock reports `conn_requests`: how many requests the TCP connection it arrived on has carried.
```bash
for i in $(seq 8); do curl -s localhost:8082/rr/x | jq -c '{node, conn_requests, http_version}'; done
for i in $(seq 4); do curl -s localhost:8082/no-reuse/x | jq -c '{node, conn_requests, http_version}'; done
```
* Through `/rr/`, `conn_requests` climbs. It starts at 1 only when a pooled connection is brand new, for example right after a mock restart.
* Through `/no-reuse/`, it is always 1.

Now count `TIME_WAIT` sockets on **both** ends of the backend connections:
```bash
tw() { echo "nginx side: $(ss -Htan state time-wait '( dport = :8001 or dport = :8002 )' | wc -l)" \
            "  backend side: $(ss -Htan state time-wait '( sport = :8001 or sport = :8002 )' | wc -l)"; }
tw; for i in $(seq 200); do curl -s -o /dev/null localhost:8082/rr/x; done;       tw
    for i in $(seq 200); do curl -s -o /dev/null localhost:8082/no-reuse/x; done; tw
```
* On the lab box, 200 requests through `/rr/` added **0** `TIME_WAIT` sockets on either side, with about 50 requests per connection.
* 200 through `/no-reuse/` added **200 on the backend side**. An HTTP/1.0 backend closes after responding, so the backend holds `TIME_WAIT`. In production, that's your app servers' port and memory budget.
* `ss -tanp state established '( dport = :8001 )'` shows the pooled connections, owned by worker PIDs.

**Trap:** don't judge reuse by the `peer` port. On loopback, Linux reuses ephemeral ports immediately (`net.ipv4.tcp_tw_reuse = 2`), so a repeating port proves nothing. That's why the mock reports `conn_requests`.

*Try it:* add `keepalive 0;` to `rr_pool`, reload, and repeat. Zero disables the cache. `keepalive off;` is a syntax error.

---

## 4. Day 2 Concept Examination (10-Question Randomized Quiz)

👉 **http://&lt;lab-host&gt;:8090/quiz.html?sprint=2&day=2** (serve with `cd /srv/nginx-journey && python3 -m http.server 8090`)

---

## 5. Key Takeaways for Day 2
* **Every method optimizes for something and fails somewhere.**
  * Round-robin ignores load.
  * `ip_hash` collapses behind NAT.
  * Plain `hash` reshuffles on scale events.
  * `least_conn` is only as good as its counters.
* **Give upstreams a `zone`.** Without one, NGINX runs one independent load balancer per worker: `least_conn` can't see other workers' load, failure marks aren't shared, and recovery is inconsistent.
* **Consistent hashing moves about 1/N of keys, and only onto the new node.** Plain hashing moves most of them.
* **Backups and recovered nodes follow `fail_timeout`.** A healthy node can sit idle until its timer expires.
* **Keepalive is on by default since 1.29.7.** On older builds you need all three lines (`keepalive`, `proxy_http_version 1.1`, `Connection ""`).
* **Measure reuse by requests per connection or by `TIME_WAIT` counts, never by port numbers on loopback.** And check both ends: the side that closes first holds `TIME_WAIT`.

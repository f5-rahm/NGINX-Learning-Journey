# Sprint 5 &bull; Day 3 (Optional) Enterprise Side Quest: A Live Denylist and Cluster-Wide Limits
**Day:** Optional, after Day 3  
**Estimated Time:** 45 Minutes (10 concepts, 5 setup, 30 hands-on)  
**Theme:** Everything this week lived in one NGINX instance's shared memory, and every change to who is blocked meant a config edit and a reload. Production gateways run as several nodes, and denylists change while attacks are underway. NGINX Plus adds two things: a key-value store you change through its API without a reload, and **zone_sync**, which shares rate-limit and key-value state between the nodes of a cluster.

> **Status:** run end to end on the lab box on NGINX Plus R37.1.1 (API version 10), with the commands below.

---

## 1. Concepts to Understand (10 Minutes)

### 1.1 Limits Are Per Instance
* A `limit_req` zone lives in one instance's shared memory. Behind a load balancer that spreads one client over **N** gateways, that client gets **N times** the limit.
* **The open source workarounds:**
  * Divide the configured rate by the number of nodes. That's wrong whenever a node is down or the spread is uneven.
  * Make the load balancer keep each client on one node (source-address persistence). That's right until a node fails.
* Neither shares a denylist: adding an address means editing and reloading every node.

### 1.2 The Key-Value Store as a Denylist
* **`keyval_zone zone=denylist:1m type=ip;`** creates a store in shared memory whose keys are **IP addresses or CIDR ranges**. With `type=ip`, a lookup of `10.55.66.6` matches a key of `10.55.66.0/24`.
* **`keyval $remote_addr $denied zone=denylist;`** looks the client up, and `if ($denied) { return 403; }` refuses it in the rewrite phase (Day 3, 1.1).
* **The API changes the store while traffic flows:**
  * `POST` adds keys, `PATCH` changes or (with `null`) removes them, and `DELETE` empties the zone.
  * There's no reload: the workers, their connections and the configuration `generation` stay the same.
* **`timeout=`** expires entries after a while. That's useful for temporary blocks and required for syncing (1.3).
* **`state=`** would persist the store to a file across restarts.

**BIG-IP lens:** closer to AFM's IP intelligence / shun lists or a data group updated through iControl REST than to a config change. The data plane picks up the change without anything being redeployed.

### 1.3 `zone_sync`: State Shared Across a Cluster
* **Setup:** a `stream` server with `zone_sync;` and the list of cluster members in `zone_sync_server`. Every node can list all members including itself: a node that connects to itself notices and ignores that connection.
* **What's synced:** zones whose definition says **`sync`**. In this lab:
  * `keyval_zone ... timeout=1h sync` (a synced keyval zone must have a `timeout`);
  * `limit_req_zone ... sync`.
  * Configuration is **not** synced. Each node still has its own `nginx.conf`.
* **It's eventually consistent.** Changes are pushed every `zone_sync_interval` (1 s by default).
  * A sustained rate converges across the cluster.
  * A burst that hits all nodes in the same instant still gets each node's burst.
* **Deletes don't travel.** Removing a key on one node leaves it on the others until its `timeout`. Changing a value **does** travel, so to unblock across a cluster, set the value to `"0"` instead of deleting it.
* **A restarted node catches up** with a snapshot from its peers. If every node restarts at once, a store without `state=` is empty.
* **In production, secure the sync channel** (`zone_sync_ssl` with client certificates). It carries your denylist and client addresses.

**BIG-IP lens:**
* A device group's ConfigSync carries **configuration**; mirroring carries some connection and persistence **state**.
* zone_sync is neither: it carries the **runtime state** of the zones you mark, and nothing else.

### 1.4 Limits in the Plus API
* `/api/VERSION/http/limit_reqs/ZONE` reports `passed`, `delayed`, `rejected` and the two dry-run counters. `/http/limit_conns/ZONE` does the same for `limit_conn`.
* **The counters are per node,** even for a synced zone. Only the limit's **state** is shared, not its statistics. A cluster view means asking every node.
* That's the visibility Day 1 got from the access log, already counted per zone, and a much better signal for a `limit_req_dry_run` rollout.

---

## 2. Setup (5 Minutes)

### A.0 One-Time Plus Setup, per [`docs/nginx-plus-lab.md`](../../docs/nginx-plus-lab.md)
If your license has expired (`[emerg] license expired` in `docker logs`), download a new JWT from MyF5, replace `~/plus/license.jwt`, and run the `docker login` from the Plus lab doc again.

**One difference from the usual convention:** the Plus nodes join the **lab network** (`s5-net`) instead of `--network host`. Rate limits key on the client's address, so the nodes must see the lab clients directly. Both nodes also run on the same ports with **one** config file.

| | Open source lab | This side quest |
| :--- | :--- | :--- |
| Engine | `s5-edge` (`nginx:mainline`), 10.55.0.10 | `s5-plus-a` 10.55.0.31 and `s5-plus-b` 10.55.0.32, from `$PLUS_IMAGE` |
| Config | `lab/nginx.conf` | `lab/plus/nginx.conf`, the same file in both nodes |
| Traffic | `10.55.0.10:8095` (and the host's :8095) | `10.55.0.31:8096` and `10.55.0.32:8096`, from the client container |
| Origin | `s5-origin:8015` | the same |
| API / dashboard | none | node A on `127.0.0.1:8085`, node B on `127.0.0.1:8098` |
| Cluster sync | none | port 9000 between the nodes |

The Plus nodes use the lab's network, origin and client container, so the open source lab must be up:
```bash
cd /srv/nginx-journey/sprints/sprint-5/lab
./lab.sh check >/dev/null 2>&1 || ./lab.sh up
source helpers.sh && source ~/plus/plus.env
for n in a b; do
  ip=$([ $n = a ] && echo 31 || echo 32); api=$([ $n = a ] && echo 8085 || echo 8098)
  docker run -d --name s5-plus-$n --network s5-net --ip 10.55.0.$ip -p 127.0.0.1:$api:8085 \
    --mount type=bind,src="$PWD/plus/nginx.conf",dst=/etc/nginx/nginx.conf,readonly \
    --mount type=bind,src="$HOME/plus/license.jwt",dst=/etc/nginx/license.jwt,readonly \
    "$PLUS_IMAGE"
done
until curl -s http://127.0.0.1:8098/api/ | grep -q '^\['; do sleep 1; done
V=$(curl -s http://127.0.0.1:8085/api/ | jq '.[-1]'); echo "Plus API version $V"
apia() { curl -s "http://127.0.0.1:8085/api/$V$1" "${@:2}"; echo; }     # node A's API
apib() { curl -s "http://127.0.0.1:8098/api/$V$1" "${@:2}"; echo; }     # node B's API
A=10.55.0.31:8096; B=10.55.0.32:8096                                    # their traffic ports
```
The helpers take `--edge` to send to a Plus node: `r /api/x --edge $A`.

Read `lab/plus/nginx.conf` before going on. It's short: a `stream` block for zone_sync, a synced denylist, and two copies of the same rate limit, one per node (`per_node`, used by `/legacy/`) and one synced (`cluster`, used by `/api/`), both at 2 requests/s with `burst=2 nodelay`.

---

## 3. Hands-on (30 Minutes)

### A.1 Two Nodes, One Config (3 min)
```bash
apia /stream/zone_sync | jq .status
apib /stream/zone_sync | jq .zones
docker logs s5-plus-a 2>&1 | grep -E 'online|ignore self'
```
* Each node reports `nodes_online: 1`: its peer.
* Both zones marked `sync` are listed.
* Each node also connected to itself, noticed it (`ignore self`), and dropped that connection, which is why one file can list every member.

### A.2 Block a Network Without a Reload (7 min)
```bash
r /api/x --from $BAD --edge $A                                           # 200
apia /nginx | jq '{generation, load_timestamp}'
apia /http/keyvals/denylist -X POST -d '{"10.55.66.0/24":"1"}'
r /api/x --from $BAD --edge $A                                           # 403
r /api/x --from 10.55.66.200 --edge $A                                   # 403: the whole range
r /api/x --edge $A                                                       # Alice: 200
apia /nginx | jq '{generation, load_timestamp}'                          # unchanged: no reload
sleep 1; r /api/x --from $BAD --edge $B                                  # node B blocks it too
apib /http/keyvals/denylist
```
*Journal:* the block reached node B without anyone calling node B's API. What would you have had to do with open source NGINX to block this range on two nodes?

<details>
<summary>One answer</summary>

Edit the `geo` (or `deny` list) in each node's config and reload each node: a config deployment, with every node's change made and checked separately, during an attack. The key-value store turns the block into a data change on one node's API, which zone_sync then carries to the rest of the cluster.
</details>

### A.3 Unblocking a Cluster (5 min)
Lift the block by deleting the key on node A:
```bash
apia /http/keyvals/denylist -X PATCH -d '{"10.55.66.0/24":null}'
sleep 2
r /api/x --from $BAD --edge $A
r /api/x --from $BAD --edge $B
apia /http/keyvals/denylist; apib /http/keyvals/denylist
```
Node A lets the client through, and node B still blocks it. Why, and how do you unblock the range everywhere?

<details>
<summary>Answer</summary>

**Deletes aren't synced**, only additions and changes. Node B keeps the key until the zone's `timeout` (1 hour here). Unblock by **changing the value** instead, so the change travels like any other: `if` treats `"0"` as false. In a synced store, "unblock" means "set to 0", and the timeout cleans up.
</details>

Node A no longer has the key, so add it back on node A with the value `"0"`:
```bash
apia /http/keyvals/denylist -X POST -d '{"10.55.66.0/24":"0"}'
sleep 2
r /api/x --from $BAD --edge $B                                           # 200
apib /http/keyvals/denylist                                              # "0" on node B too
```

### A.4 Limits in the API (4 min)
```bash
burst 10 /api/m --edge $A
apia /http/limit_reqs | jq .
apib /http/limit_reqs/cluster
```
* Node A's `cluster` zone shows the 7 rejections from this burst. Its `passed` also includes the requests node A let through in A.2 and A.3.
* Node B's counters show only the one request it handled itself. The zone's state is shared, but each node counts only its own requests.

*Journal:* on a dashboard, how do you show the rejection rate for the whole cluster?

<details>
<summary>One answer</summary>

Scrape every node and add them up: the sum of `rejected` across nodes, per interval, divided by the sum of `passed + delayed + rejected`. That's the same pattern as Sprint 4's cache counters. In Sprint 11, the Prometheus exporter does the scraping, and the dashboard sums across instances.
</details>

### A.5 One Limit, Two Nodes (8 min)
A client that alternates between the two nodes at 4 requests per second, twice the 2/s limit. First the per-node zone, then the synced one:
```bash
pace 40 4 /legacy/s --edge $A --alt $B
pace 40 4 /api/s --from $BOB --edge $A --alt $B
pace 20 4 /api/s --from 10.55.100.13 --edge $A                          # the same rate against one node only
```
<details>
<summary>What do the results show?</summary>

* **`/legacy/` (per node): 40 of 40.** Each node saw only 2 requests per second, so the cluster allowed twice the limit.
* **`/api/` (synced): about 22 of 40,** with the rejections in clumps. That's close to the single node's 12 of 20, so the limit holds across the cluster. The clumps come from the sync interval: each node learns about the other's requests up to a second late.
</details>

Now a burst that hits both nodes in the same instant:
```bash
(burst 10 /api/b --from 10.55.100.14 --edge $A & burst 10 /api/b --from 10.55.100.14 --edge $B & wait)
```
Each node answered 3 (1 + `burst=2`): 6 in total, against a cluster-wide burst of 3. Sync bounds **sustained** rates, not instant spikes, so set bursts with the number of nodes in mind.

### A.6 Restarts (3 min)
```bash
apia /http/keyvals/denylist -X PATCH -d '{"10.55.66.0/24":"1"}'          # block it again
sleep 2; docker restart s5-plus-b >/dev/null
until curl -s http://127.0.0.1:8098/api/ | grep -q '^\['; do sleep 1; done; sleep 2
apib /http/keyvals/denylist
docker logs s5-plus-b 2>&1 | grep snapshot | tail -2
```
Node B came back with the denylist: its peer sent it a snapshot.

*Journal:* what happens to the denylist if both nodes restart at the same time, and what would you change for production?

<details>
<summary>Answer</summary>

It's empty: no node has a copy to send, and the zone has no `state=` file. Either persist it (`state=` on each node, which then also has to be protected like any data at rest), or treat NGINX as a cache of a list that lives somewhere else and have the controller that owns the list push it again after every start. Readiness checks should then stay red until it has.
</details>

### A.7 Clean Up (1 min)
```bash
docker rm -f s5-plus-a s5-plus-b
```

---

## 4. Enterprise Quiz (Optional, 10 Questions)

👉 **http://&lt;lab-host&gt;:8090/quiz.html?sprint=5&day=3&pool=enterprise**

---

## 5. Key Takeaways
* **Open source limits are per instance.** N nodes behind a load balancer can mean N times the limit.
* **A `type=ip` key-value zone is a denylist you change through the API:** CIDR keys, no reload, the same configuration generation.
* **zone_sync shares the state of zones marked `sync`,** not configuration. It's eventually consistent on a one-second interval: sustained rates converge, simultaneous bursts don't.
* **Deletes don't sync. Set values to `"0"` to unblock across a cluster,** and let `timeout` clean up.
* **Limit counters in the API are per node.** Add them up for the cluster.
* **A restarted node recovers from its peers; a fully restarted cluster doesn't** without `state=` or a controller that re-pushes.

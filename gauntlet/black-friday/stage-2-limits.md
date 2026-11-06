# Stage 2: Who Gets In

**Tickets 4–6** · Sprint 5's side quest: a live denylist and cluster-wide limits, on two nodes · [War room README](README.md)

---

## Briefing (10 Minutes)

### Lists You Change in the Middle of the Night
A list of refused networks is easy in configuration: `geo` maps the client address to a value, most specific network first, and a server-level `if` refuses the matches. The cost is how the list changes: edit the file, reload every node. A reload is graceful, so no request fails. But it starts new workers and retires the old ones, and every in-flight request, keepalive connection and long-lived stream stays on an old worker until it finishes. On a night of bot waves, a list that changes every few minutes means a reload every few minutes, on every node.

Keeping the list in its own file (`include`) at least keeps the change small and reviewable: one line, never a hand edit of `nginx.conf`.

**NGINX Plus moves the list into shared memory.**
* **`keyval_zone`** holds key-value pairs. **`keyval`** maps a variable (`$remote_addr`) to a looked-up value (`$denied`), so the rest of the config uses `$denied` like any other variable.
* With **`type=ip`**, keys are addresses or CIDR ranges, and a lookup finds the most specific match.
* **The API changes the data.** Add, update or delete through `/http/keyvals/<zone>`: `POST` adds (and refuses a key that exists), `PATCH` updates or deletes (a `null` value).
* **No reload.** The next request sees the change.

BIG-IP equivalent: an address data group or AFM address list, changed over iControl REST while traffic flows, and matched with `class match` in an iRule.

### Two Nodes, One List
Each node has its own shared memory. A list in shared memory is still per node, until **`zone_sync`** connects them:
* A `stream` server on each node joins the cluster.
* Zones marked **`sync`** replicate their changes to the other nodes.
* One config file can serve every node: each lists all the members, and a node ignores itself.

Three things about it matter tonight:
* **It's eventually consistent.** Changes travel on an interval (`zone_sync_interval`, 1 s by default). For a second or two, one node may answer with the old value.
* **Updates sync, but deleting a key doesn't.** A key deleted on one node stays on the others until the zone's `timeout` removes it. In a synced list, "unblock" means setting the value to `"0"` (and `if ($denied)` treats `"0"` as false), not deleting.
* **A zone can't change its `sync` flag on a reload.** The master refuses the new config (`[emerg]` in the error log) and keeps running the old one. A zone becomes synced by restarting, or by defining a new zone with `sync` and using that one.

BIG-IP equivalent: config sync across a device group, except that `zone_sync` replicates runtime data, not configuration. The configuration itself still has to be the same on every node; that's your deployment's job.

### One Limit, Two Nodes
`limit_req` counts per zone, and a zone is per node. Behind a round-robin load balancer, each of two nodes sees half of a client's requests, so a client gets about twice the limit before either node refuses. Two ways to make one limit hold:
* **Send each client to one node.** Client affinity at the load balancer: hash on the client address, `consistent` so that adding or removing a node moves as few clients as possible. Each node's count is then the client's whole count. The cost is that load follows clients, not requests, and a node failure moves its clients (and resets their counts).
* **Share the count. Plus:** `limit_req_zone ... sync`. Each node adds the others' counts to its own on the sync interval. Because of that interval, **sync bounds sustained rates, not instant spikes**: a burst that hits both nodes in the same instant gets each node's `burst` before the counts meet.

BIG-IP equivalent: L7 DoS and iRule `table` rate limits are per device too. Device groups don't share those counters.

<details><summary>Question: the denylist has <code>10.58.66.0/24</code> as <code>"1"</code>. Through edge-a's API you delete the key. What do shoppers from that range see over the next minutes?</summary>

On edge-a they get in at once. On edge-b they're still refused, because the delete doesn't sync, until the zone's `timeout` expires the key there. Through a round-robin load balancer, that's every second request refused. Setting the value to `"0"` instead reaches both nodes within a second or two.
</details>

---

## Ticket 4: Scalper Bots on Checkout

> **From the fraud team:** `10.58.66.0/24` is hammering `/checkout` and scraping the doorbusters. Refuse that whole network, on every path, on both nodes. And it won't be the last network tonight: changing the list has to be quick.

**Requirements:**
1. Every request from `10.58.66.0/24` gets `403`, on every path, on both nodes and through the load balancer.
2. Shoppers are unaffected.
3. **Open source:** the list lives in its own file, `edge/denylist.conf`, separate from `nginx.conf`. A reload applies a change.
4. **Plus:**
   * The list is a key-value zone named `denylist` with `type=ip`. Keys are addresses or ranges; `"1"` refuses, `"0"` lets in.
   * The ops team changes it through either node's API, and a change reaches both nodes within 3 s with no reload. The check adds and removes a test range through edge-b and watches edge-a.

<details><summary>Hint 1</summary>

Where you refuse matters. Sprint 5 Day 3 showed what happens to a `deny` inside a location: it misses every other location. Refuse at the server level, before any location runs.
</details>

<details><summary>Hint 2 (Plus)</summary>

You need four things:
* a `stream` server for `zone_sync` on each node, the same lines on both
* a `keyval_zone ... type=ip ... sync` and a `keyval` that maps `$remote_addr`
* the API's `write=on`
* a reload, once, to build it all

After that, blocking is data, not config.
</details>

<details><summary>Answer (open source)</summary>

In `http`:
```nginx
geo $denied {
    default 0;
    include /lab/edge/denylist.conf;
}
```
`edge/denylist.conf`:
```nginx
10.58.66.0/24    1;   # scalper bots
```
In `server`, before the locations:
```nginx
if ($denied) {
    return 403;
}
```
`geo` reads `$remote_addr` after realip, so it sees the bot's address, not the load balancer's.
```bash
./warroom.sh reload && ./warroom.sh check
```
</details>

<details><summary>Answer (Plus)</summary>

At the top level, next to `http`:
```nginx
stream {
    server {
        listen 9000;
        zone_sync;
        zone_sync_server 10.58.0.11:9000;
        zone_sync_server 10.58.0.12:9000;
    }
}
```
In `http`:
```nginx
keyval_zone zone=denylist:1m type=ip timeout=1d sync;
keyval      $remote_addr $denied zone=denylist;
```
In the shop's `server`, before the locations: `if ($denied) { return 403; }`. In the API server: `api write=on;`.
```bash
./warroom.sh reload
curl -s -X POST -d '{"10.58.66.0/24":"1"}' 127.0.0.1:8085/api/10/http/keyvals/denylist
curl -s 127.0.0.1:8105/api/10/http/keyvals/denylist        # edge-b has it a moment later
./warroom.sh check
```
</details>

---

## Ticket 5: A Partner Caught in the Block

> **From partnerships:** Our price-comparison partner runs its crawler from `10.58.66.77`, inside the range you just blocked. They're calling. Let them in. The rest of that network stays out.

**Requirements:**
1. `10.58.66.77` gets in on both nodes and through the load balancer.
2. The rest of `10.58.66.0/24` is still refused.
3. **Plus:** no reload or restart while you do it.

<details><summary>Hint</summary>

Both `geo` and a `type=ip` key-value zone pick the **most specific** match for an address. What's more specific than a /24?
</details>

<details><summary>Answer (open source)</summary>

Add to `edge/denylist.conf`:
```nginx
10.58.66.77      0;   # price-comparison partner
```
```bash
./warroom.sh reload && ./warroom.sh check
```
</details>

<details><summary>Answer (Plus)</summary>

```bash
curl -s -X POST -d '{"10.58.66.77":"0"}' 127.0.0.1:8085/api/10/http/keyvals/denylist
./warroom.sh check
```
A `/32` set to `"0"` beats the `/24` set to `"1"`, on both nodes once it has synced.
</details>

---

## Ticket 6: Two Nodes, Double the Limit

> **From the payments team:** `/checkout` is supposed to allow 5 requests a second per shopper, burst 5, to protect the payment provider. A shopper's script just did nearly 10 a second for a minute. Each edge is enforcing its own 5. Make it 5 for the whole site.

**Requirements:**
1. A shopper gets about 5 checkouts a second (burst 5) for the whole site. Sending 10 a second for 6 seconds through the load balancer, between 25 and 45 of the 60 succeed.
2. Other shoppers are unaffected.
3. **Open source:** you may change the load balancer (`lb/nginx.conf`).
4. **Plus:** leave the load balancer alone: shoppers stay spread across both nodes.

<details><summary>Hint 1 (open source)</summary>

If both nodes can't share a count, make sure only one node ever counts a given shopper. The load balancer knows the shopper's address.
</details>

<details><summary>Hint 2 (Plus)</summary>

`sync` on the zone. Then read what `./warroom.sh reload` tells you, carefully.
</details>

<details><summary>Answer (open source)</summary>

In `lb/nginx.conf`, `upstream edges`:
```nginx
hash $remote_addr consistent;
```
```bash
./warroom.sh reload && ./warroom.sh check
```
Each shopper now always reaches the same edge, which sees all of their requests. The checks for tickets 4, 5 and 7 still pass, because they test each node directly as well as through the load balancer.
</details>

<details><summary>Answer (Plus)</summary>

Adding `sync` to the existing `checkout` zone is refused on reload:
```
[emerg] the "sync" flag of shared memory zone "checkout" had previously a different state
```
The master keeps the old config running. Define a new zone and use it:
```nginx
limit_req_zone $binary_remote_addr zone=checkout_all:1m rate=5r/s sync;
```
```nginx
location = /checkout {
    limit_req  zone=checkout_all burst=5 nodelay;
    proxy_pass http://origin;
}
```
```bash
./warroom.sh reload && ./warroom.sh check
```
`./warroom.sh restart` would also accept the original zone with `sync`. But it restarts both nodes at once, which empties both caches, every count and the key-value zones: the denylist is gone, because no node kept a copy and the zone has no `state=` file. Restarting nodes one at a time lets a restarted node get the synced data back from its peer.
</details>

---

## Stage 2 Questions

<details><summary>1. The open source affinity answer and the Plus sync answer both pass ticket 6. Name one failure each handles differently.</summary>

When edge-a fails, the load balancer moves edge-a's shoppers to edge-b:
* **With affinity,** they arrive with no history on edge-b, so for a moment each gets a fresh limit.
* **With sync,** edge-b already had their counts.

The other way around, affinity concentrates a heavy shopper (or a whole office behind one NAT address) on one node, while sync spreads it.
</details>

<details><summary>2. Why does ticket 6's check send 10 requests a second for 6 seconds, instead of 60 requests at once?</summary>

Because sync bounds sustained rates, not spikes. Sixty requests in the same instant would reach both nodes before either had heard from the other, and each would allow its own `burst`. A sustained rate gives the sync interval time to bring the counts together, which is what the requirement is about.
</details>

<details><summary>3. In the open source edition, ticket 4 means a reload per new bot network. What does a reload actually cost the shoppers who are mid-checkout?</summary>

Nothing fails. The master starts new workers with the new config, the old workers stop accepting and finish what they have, then exit. The cost is time and memory: two sets of workers at once, and connections with long requests or streams keep old workers alive. Many reloads in a short time stack those up. That's the argument for the API-driven list.
</details>

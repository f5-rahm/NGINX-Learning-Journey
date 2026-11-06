# Stage 3: Code at the Edge

**Tickets 7–8** · Sprint 6's side quest: njs with live data, and njs compared with Lua on OpenResty · [War room README](README.md)

---

## Briefing (15 Minutes)

### Who Is This, and Are They Allowed In?
Ticket 7 needs two answers for every doorbuster request:
* **Who is this?** The member cookie is signed. `shop.js` already checks the HMAC and the expiry and sets `$member` to the verified ID, or to empty. That's the part of the logic that needs code: no directive verifies a custom HMAC cookie.
* **Is this member a VIP right now?** That's data. Marketing changes it all night, on both nodes, without anyone editing config.

Keep those two apart and each edition has a natural shape:
* **Plus:** njs answers "who", and a key-value zone keyed by `$member` answers "VIP?". `keyval $member $vip zone=vip` is one line, the lookup happens in NGINX, and the zone syncs across nodes and changes through the API. The code never touches the list.
* **Open source:** the data has to live where code can reach it: a `js_shared_dict_zone`, shared by one node's workers. Changing it needs an endpoint, written in njs, that only the ops team can reach. Nothing replicates a shared dictionary across nodes in open source, so the ops team updates each node, the same per-node pattern as Stage 1's cache.

BIG-IP equivalent: an iRule that checks a signed cookie (`CRYPTO::verify`) and then looks the member up in a data group changed over iControl REST (the Plus shape), or in a `table` that another iRule fills (the open source shape, and `table` is per device too).

### The Admin Endpoint Is an Attack Surface
In the open source shape, `/ops/vip/<id>` is a write API you wrote yourself. It's on the same port as the shop, so the only thing between a shopper and "make me a VIP" is your access rule. It needs the same care as Stage 1's refresh:
* decide on `$remote_addr` after realip, never on a header
* refuse everyone else
* validate the ID before it goes into shared memory

### njs or Lua?
The platform team asks whether the edge logic would be better on OpenResty, NGINX with LuaJIT and a large Lua library built in. Ticket 8 measures one thing: requests per second for the same work. That's one input among several:

| | njs (NGINX JavaScript) | Lua on OpenResty |
| :--- | :--- | :--- |
| **What it is** | An NGINX module. It ships with NGINX open source and NGINX Plus, and F5 supports it in Plus. | A separate distribution: an NGINX core plus LuaJIT and the `lua-nginx-module`, with its own releases and NGINX version. |
| **Engine and state** | Default engine: a fresh, cheap VM per request, so nothing survives between requests. QuickJS engine: contexts reused per worker. Shared state goes through `js_shared_dict_zone` or variables. | One LuaJIT VM per worker; each request runs as a coroutine. Module-level Lua state lives as long as the worker, which is handy for caches and easy to leak per-request data into. |
| **Where it runs** | `js_set`, `js_content`, header and body filters, `js_preread` and friends in `stream`, `js_periodic`. | Nearly every phase: init, rewrite, access, content, filters, log, balancer, TLS certificate selection, timers. |
| **Talking to other systems** | `ngx.fetch` (HTTP), subrequests. | Cosockets: non-blocking TCP and UDP from Lua, with libraries for Redis, MySQL, DNS and more. |
| **Reach into the system** | No raw sockets, no processes. A `fs` module reads and writes files as the worker user. | `io` and `os` (including `os.execute`) unless you remove them, and the FFI: call any C function, read any memory. A wrong FFI call crashes the worker. |
| **Blocking** | A long computation stalls the worker (Sprint 6 Day 3). | The same, plus blocking calls (`io`, `os.execute`, non-cosocket libraries) that stall the worker. |

Speed isn't the only question. Both handle tens of thousands of requests a second on one small node. The bigger questions are:
* **What the code is allowed to reach,** which is your attack surface.
* **Who supports the build you run.**
* **Whether the rest of your configuration stays the NGINX you know.**

The BIG-IP parallel is iRules vs iRules LX: Tcl inside TMM with a narrow API, vs Node.js in a separate process with the whole npm ecosystem.

<details><summary>Question: in the Plus answer to ticket 7, which part of the VIP logic is code, and which is configuration and data?</summary>

Only the cookie check is code (`shop.member`, set as `$member`). The VIP lookup is configuration (`keyval $member $vip zone=vip`), the refusal is configuration (`if ($vip != "1") { return 403; }`), and the list itself is data in a synced zone changed through the API. The code doesn't know there is a VIP list.
</details>

---

## Ticket 7: VIP Early Access

> **From marketing:** Until midnight, `/doorbuster/` is for VIP members only. Everyone else gets refused. We'll be adding and removing VIPs all night as customers call in, and it has to work on both edges within seconds. Nobody touches the config for that.

**Requirements:**
1. `/doorbuster/` requires a verified member cookie **and** a member on the VIP list. Otherwise it's `403`: no cookie, not a VIP, a forged signature, or an expired cookie.
2. The origin still receives `X-Member` with the verified member ID.
3. Adding or removing a VIP takes effect on both nodes within 3 s, with no reload.
4. **Open source:**
   * `POST /ops/vip/<id>` adds a VIP and `DELETE /ops/vip/<id>` removes one, on each node at `:8080`.
   * Only the ops team (`10.58.0.5`) can use them. Anyone else gets `403`, including a shopper through the load balancer claiming `X-Forwarded-For: 10.58.0.5`.
5. **Plus:**
   * The list is a key-value zone named `vip`: keys are member IDs, `"1"` is a VIP, `"0"` isn't.
   * The ops team changes it through either node's API. The check adds a VIP through edge-a and removes one through edge-b.

<details><summary>Hint 1</summary>

Requirement 1 is two lookups in order: `$member` (already there), then "is `$member` a VIP?" as another variable. The location refuses unless that second variable is `"1"`. An empty `$member` must never count as a VIP.
</details>

<details><summary>Hint 2 (open source)</summary>

You need three things in `shop.js`, plus the config around them:
* a `js_shared_dict_zone` for the list
* a `js_set` function that returns `"1"` when `ngx.shared.<zone>.get(member)` says so
* a `js_content` handler for `/ops/vip/` that reads the ID from `r.uri` and calls `set` or `delete` depending on `r.method`

Add the new functions to `export default`; a missing export passes `nginx -t` and fails at request time (Sprint 6 Day 1). The location for `/ops/vip/` gets its own `allow`/`deny`.
</details>

<details><summary>Hint 3 (Plus)</summary>

`keyval` can map any variable, including one set by `js_set`. Removing a VIP: remember Stage 2's lesson about deleting keys in a synced zone.
</details>

<details><summary>Answer (open source)</summary>

`shop.js`, before `export default`:
```js
// js_set $vip: "1" when the verified member is a VIP
function vip(r) {
    var id = r.variables.member;
    return id && ngx.shared.vip.get(id) === '1' ? '1' : '';
}

// js_content for /ops/vip/<id>: POST adds a VIP, DELETE removes one
function vipAdmin(r) {
    var id = r.uri.split('/')[3] || '';
    if (!ID.test(id)) {
        return r.return(400, 'bad member ID\n');
    }
    if (r.method === 'POST') {
        ngx.shared.vip.set(id, '1');
        return r.return(204);
    }
    if (r.method === 'DELETE') {
        ngx.shared.vip.delete(id);
        return r.return(204);
    }
    r.return(405);
}

export default { member, vip, vipAdmin };
```
`nginx.conf`, in `http` after `js_set $member`:
```nginx
js_shared_dict_zone zone=vip:1m;
js_set    $vip shop.vip;
```
In the server:
```nginx
location /doorbuster/ {
    if ($vip != "1") {
        return 403;
    }
    proxy_set_header X-Member $member;
    proxy_pass http://origin;
}

location /ops/vip/ {
    allow 10.58.0.5;
    deny  all;
    js_content shop.vipAdmin;
}
```
```bash
./warroom.sh reload
./warroom.sh ops -i -X POST http://edge-a:8080/ops/vip/alice
./warroom.sh ops -i -X POST http://edge-b:8080/ops/vip/alice
./warroom.sh shop -i -b "nw_member=$(./warroom.sh token alice)" /doorbuster/tv-65
./warroom.sh check
```
</details>

<details><summary>Answer (Plus)</summary>

In `http` after `js_set $member`:
```nginx
keyval_zone zone=vip:1m timeout=1d sync;
keyval      $member $vip zone=vip;
```
In the server:
```nginx
location /doorbuster/ {
    if ($vip != "1") {
        return 403;
    }
    proxy_set_header X-Member $member;
    proxy_pass http://origin;
}
```
```bash
./warroom.sh reload
curl -s -X POST  -d '{"alice":"1"}' 127.0.0.1:8085/api/10/http/keyvals/vip     # add, through edge-a
curl -s -X PATCH -d '{"alice":"0"}' 127.0.0.1:8105/api/10/http/keyvals/vip     # remove, through edge-b: "0", not a delete
./warroom.sh check
```
</details>

---

## Ticket 8: Should We Move to OpenResty?

> **From the platform team:** Before next Black Friday we're deciding whether edge logic like the VIP gate should be Lua on OpenResty. Give us a number: same logic, same box, which one handles more?

`lab/openresty/` already has ticket 7's logic in Lua: `shop.lua` verifies the cookie with `resty.openssl.hmac`, keeps VIPs in a `lua_shared_dict`, and has the same `/ops/vip/` endpoint. You don't edit it. Read it next to your `shop.js`.

`./warroom.sh bench`:
* starts OpenResty (`bf-lua`)
* makes sure both engines refuse a member who isn't a VIP
* runs `oha` for 15 s with 50 connections against edge-a, then against OpenResty, using that member's cookie

Each request is: verify the HMAC cookie, look the member up in shared memory, refuse with `403`, log it. No origin is involved, so the numbers measure the edge logic. It also reports each worker's memory.

**Requirements:**
1. Run the benchmark.
2. `./warroom.sh answer njs` or `./warroom.sh answer lua`: which handled more requests per second in your run?

<details><summary>Questions for the platform team (answer them for yourself)</summary>

1. **Is the difference big enough to matter?** Compare it with the origin's capacity: the doorbuster page goes to a Python origin that answers a few thousand requests a second at most.
2. **What does your edge-a config do per request that the OpenResty config doesn't?**
3. **Which of the two can open a TCP connection to a database from the access phase?** Which can run a shell command? Which would you rather expose to a code review?
</details>

<details><summary>Answers</summary>

1. In the build rehearsals, Lua handled about 15–20% more requests per second (around 48,000 vs 40,000 on a small lab box), with similar p99 latency and similar worker memory (about 8–10 MB each). Both are an order of magnitude beyond what the origin behind them can take, so at this scale the deciding factors are the others in the briefing table.
2. Whatever your earlier tickets added: realip, the denylist lookup, the cache maps, `X-Edge` and `X-Cache-Status` headers, and in the Plus edition a key-value lookup and a longer log line. Small costs, but the comparison isn't perfectly like for like. Benchmarks rarely are.
3. Lua on OpenResty, both: cosockets for the database, `os.execute` for the shell. njs has neither. That's capability for Lua and attack surface for a reviewer.

`./warroom.sh lua down` removes OpenResty when you're done.
</details>

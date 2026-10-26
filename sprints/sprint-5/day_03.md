# Sprint 5 &bull; Day 3: Who Gets In: Access Control, Tiers and the Real Client & the Sprint Lab
**Day:** 3 of 3  
**Estimated Time:** 90 Minutes (15 concepts, 2 setup, 25 activities, 38 Lumina build, 10 quiz)  
**Optional:** [Enterprise Side Quest](day_03_enterprise.md), 45 minutes: a denylist that changes without a reload, and rate limits shared by a two-node NGINX Plus cluster  
**Theme:** Days 1 and 2 treated every client the same. Real gateways don't: partners get more, operations staff get the admin pages, an abusive network gets nothing, and the "client" is often a load balancer standing in front of thousands of users. On BIG-IP you'd reach for address data groups, an iRule, and the HTTP profile's `X-Forwarded-For`. Today builds the same with `allow`/`deny`, `geo`, `map` and the realip module, and then puts the sprint together.

---

## 1. Concepts to Understand (15 Minutes)

### 1.1 `allow` and `deny`
* They run in the **ACCESS** phase and are checked **in order**: the first rule that matches the client's address decides. `deny all; allow 10.55.10.0/24;` refuses everyone, the allowed network included.
* A refusal is `403`.
* **Inheritance replaces, as usual.** A location with its own `allow`/`deny` rules ignores the server's.

**The phase order matters** (Sprint 3 Day 3's list): `limit_req` and `limit_conn` run in **PREACCESS**, before `allow`/`deny`.
* A denied client that sends many requests is counted by the limits first.
* Once over its burst, it's answered **`429`** (by the limit), not `403` (by the deny).
* It also uses a state in your limit zones, so a blocked network can still fill them.

To refuse a client **before** any limit sees it, decide in the **rewrite** phase: `if ($var) { return 403; }` at `server` level, where `$var` comes from a `geo` lookup. (`if` has a bad reputation, but `return` is one of the few things that's safe inside it.)

### 1.2 `geo` and `map`: From an Address to a Policy
* **`geo $var { ... }`** matches the client address against **CIDR ranges**. The most specific match wins, regardless of order. `default` covers the rest.
  * It looks at `$remote_addr` (after realip, 1.3), or at any variable you name: `geo $arg_ip $var`.
  * `ranges` mode takes `10.0.0.1-10.0.0.200` style ranges instead.
* **`map $src $var { ... }`** matches **strings**: exact values, or regexes with `~`.
* Both are evaluated **only when the variable is used**, so a large table costs nothing on requests that don't look at it.
* **Chain them into tiers.** `geo` turns an address into a name (`partner`, `ops`, `blocked`, `internet`), and `map`s turn the name into policy:
  * **A limit key:** the partner tier maps to `""`, which no limit counts (Day 1), and everyone else maps to `$binary_remote_addr`. That one line exempts a whole network from every limit using that key.
  * **A rate for `limit_rate`:** `0` for partners (unlimited), `512k` for the rest.
  * **A yes/no for the `if ... return 403`** above.

**BIG-IP lens:** `geo` is an address-type data group plus `class match`, evaluated by NGINX itself; `map` is a string data group. The config holds the policy, and an iRule isn't needed to apply it.

### 1.3 The Real Client Address
Behind a load balancer, every connection comes from the load balancer. `$binary_remote_addr` then puts **all users in one bucket**, and `geo` sees one address. The real client is in a header the load balancer adds, usually `X-Forwarded-For`.

**The realip module** replaces the client address early, in the **POST_READ** phase, so `geo`, the limits, `allow`/`deny` and the logs all see the real client:
* **`set_real_ip_from 10.55.0.5;`** says whose header to believe. Only connections from these addresses (or CIDR ranges) are rewritten. Anyone else's `X-Forwarded-For` is ignored, because any client can send one.
* **`real_ip_header X-Forwarded-For;`** says which header to use. `X-Real-IP` and `proxy_protocol` are the other common choices.
* **`real_ip_recursive`** decides which address in a list counts:
  * Off (the default): the **last** address in the header.
  * On: the **last one that isn't trusted**, walking from the right.
  * It only matters when a trusted proxy also appears **inside** the header, as in a chain of proxies. Addresses a client puts at the left end are never used either way.
* **`$realip_remote_addr`** keeps the original peer address for your logs.

**What the origin receives is up to you.**
* NGINX passes the client's `X-Forwarded-For` through **unchanged**, including anything a client invented. Set it, or `X-Real-IP $remote_addr`, deliberately.
* **A load balancer working at L4** can send the address with the **PROXY protocol** instead of a header (`listen ... proxy_protocol;` plus `real_ip_header proxy_protocol;`).

**BIG-IP lens:**
* This is the receiving end of the HTTP profile's **Insert X-Forwarded-For**.
* The same caution applies as on BIG-IP when it sits behind a CDN: trust the header only from the hops you control.

### 1.4 The Sprint in BIG-IP Terms

| Need | BIG-IP | NGINX |
| :--- | :--- | :--- |
| Requests per second per client | L7 DoS profile, iRule + `table` | `limit_req` (Day 1) |
| Concurrent requests per client | iRule counting, connection limit (per virtual or member) | `limit_conn` (Day 2) |
| Bandwidth | Rate class (a shared pipe) | `limit_rate` per response, plus `limit_conn` (Day 2) |
| Slow clients | TCP/HTTP profile timeouts, DoS slow-request detection | `client_header_timeout`, `client_body_timeout`, `limit_conn` (Day 2) |
| Network allow/deny | Address data group, AFM rules, iRule | `allow`/`deny`, `geo` + `return 403` |
| Tiers and exemptions | Data groups + iRule logic | `geo` → `map` → limit keys and rates |
| Real client behind a proxy | HTTP profile XFF insertion (sending side) | realip module (receiving side) |
| Changing a denylist live | AFM / IP intelligence, iControl | NGINX Plus key-value store + API ([side quest](day_03_enterprise.md)) |

---

## 2. Lab Setup (2 Minutes)

```bash
cd /srv/nginx-journey/sprints/sprint-5/lab
cp day3_nginx.conf nginx.conf           # Days 1 and 2 put together, plus an /admin/ location
./lab.sh up                             # or ./lab.sh reload if the lab is still up
source helpers.sh
```
`day3_nginx.conf` has Day 1's rate limit and Day 2's concurrency, download, timeout and body-size limits, with `429` and `Retry-After` for every refusal. Today's clients: `$OFFICE` (10.55.10.10), `$PARTNER` (10.55.20.20), `$BAD` (10.55.66.6) and the load balancer `$LB` (10.55.0.5).

---

## 3. Hands-on Guided Discovery Activities (25 Minutes)

### Activity 3.1: Blocking a Network (6 min)
Block the abusive network the obvious way. In `location /api/`, above the `limit_req` line:
```nginx
deny 10.55.66.0/24;
```
```bash
./lab.sh reload
burst 30 /api/x --from $BAD
burst 30 /api/x --from $BAD --conc 4
lim 2
```
The client is denied. Why does it get mostly `429`, and not `403`?

<details>
<summary>Answer</summary>

`limit_req` and `limit_conn` run in PREACCESS, **before** `deny` (ACCESS). Every request is first counted against the limits, and only those that pass reach the `deny`. Once the blocked client is over its burst, the limits answer first, with `429` and an invitation to retry. The log shows `req=REJECTED` for them. The blocked network is also using states in your limit zones.
</details>

Refuse it in the rewrite phase instead. Remove the `deny` line, and add a `geo` at `http` level, above `upstream api`:
```nginx
geo $tier {
    default        internet;
    10.55.10.0/24  ops;
    10.55.20.0/24  partner;
    10.55.66.0/24  blocked;
}
```
and at `server` level, under the `add_header` line:
```nginx
if ($tier = blocked) {
    return 403;
}
```
```bash
./lab.sh reload
burst 30 /api/x --from $BAD               # 403 x 30
r '/downloads/f?size=1k' --from $BAD      # 403 everywhere, not only /api/
r /api/x                                  # Alice is unaffected
```

### Activity 3.2: Tiers (8 min)
Partners should be exempt from the API limits and download at full speed. Right now they aren't:
```bash
hold 6 1 /api/p --from $PARTNER           # 4 of 6: the per-client concurrency limit
burst 40 /api/p --from $PARTNER --conc 4  # 21 of 40: the rate limit
```
Turn the tier into policy. At `http` level, below the `geo`:
```nginx
map $tier $client_key {
    partner  "";
    default  $binary_remote_addr;
}
map $tier $download_rate {
    partner  0;
    default  512k;
}
```
Then use them:
* change the key of `limit_req_zone ... zone=api` from `$binary_remote_addr` to `$client_key`;
* do the same for `limit_conn_zone ... zone=per_client`;
* in `/downloads/`, change `limit_rate 512k;` to `limit_rate $download_rate;`.
```bash
./lab.sh reload
```
`nginx -t` passed, so why didn't the reload work?

<details>
<summary>Answer</summary>

The master refused the new configuration and kept the old one:
```
[emerg] limit_req "api" uses the "$client_key" key while previously it used the "$binary_remote_addr" key
```
A zone lives in shared memory and survives reloads, together with its key. `nginx -t` checks the new file on its own, so it can't know what the running zones look like. `nginx -s reload` only sends a signal, so it reports success either way. Only the error log tells you. (`lab.sh reload` checks the log for you; a plain `nginx -s reload` wouldn't.)

Changing a zone's **size** or **rate** reloads fine. For a new **key**, either give the zone a new name (and update every `limit_req` that uses it), or restart NGINX so that all zones are created fresh.
</details>

Restart the gateway (zones and their counters start empty), then try again:
```bash
./lab.sh edge
hold 6 1 /api/p --from $PARTNER           # 6 of 6
burst 40 /api/p --from $PARTNER --conc 4  # 40 of 40
burst 40 /api/p --from $OFFICE --conc 4   # 21 of 40: operations isn't exempt
r '/downloads/f?size=1m' --from $PARTNER  # full speed
r '/downloads/f?size=1m'                  # Alice: about 1.4 s
```

### Activity 3.3: An Admin Allowlist (3 min)
In `location /admin/`, under `proxy_pass`:
```nginx
deny  all;
allow 10.55.10.0/24;
```
```bash
./lab.sh reload
r /admin/ --from $OFFICE
```
<details>
<summary>Why is the operations network refused?</summary>

`allow` and `deny` are checked in order and the first match wins. `deny all` matches every address, so the `allow` line is never reached. Swap the two lines.
</details>

Swap them, reload, and check every tier:
```bash
./lab.sh reload
r /admin/ --from $OFFICE; r /admin/; r /admin/ --from $PARTNER; r /admin/ --from $BAD
```
`200`, then three `403`s. The last one comes from the `if` at server level, before the location's rules are even consulted.

### Activity 3.4: Behind the Load Balancer (8 min)
Make the log show both addresses: in `log_format gw`, change `'$remote_addr "$request"` to `'$remote_addr via=$realip_remote_addr "$request"`, and reload.

The load balancer forwards two different users at the same time, then a user from the abusive network:
```bash
./lab.sh reload
(burst 15 /api/lb --from $LB --conc 4 -H 'X-Forwarded-For: 10.55.100.50' & burst 15 /api/lb --from $LB --conc 4 -H 'X-Forwarded-For: 10.55.100.51' & wait)
burst 20 /api/lb --from $LB -H "X-Forwarded-For: $BAD" | head -1
lim 1
```
<details>
<summary>What went wrong?</summary>

* The two users shared **one** bucket: together they got well under 30 answers. To the gateway, both are `10.55.0.5`, so they share its rate limit **and** its 4 requests in progress.
* The abusive user wasn't blocked: `geo` saw the load balancer's address, too.

Every user behind the load balancer is one client, so one heavy user can lock out everybody else.
</details>

Trust the load balancer. At `http` level, above the `geo`:
```nginx
set_real_ip_from  10.55.0.5;
real_ip_header    X-Forwarded-For;
```
```bash
./lab.sh reload
(burst 15 /api/lb --from $LB --conc 4 -H 'X-Forwarded-For: 10.55.100.50' & burst 15 /api/lb --from $LB --conc 4 -H 'X-Forwarded-For: 10.55.100.51' & wait)
burst 20 /api/lb --from $LB -H "X-Forwarded-For: $BAD" | head -1
burst 40 /api/lb --from $LB --conc 4 -H "X-Forwarded-For: $PARTNER" | head -1
lim 1
```
Each user now has its own bucket (15 of 15 each), the abusive user gets `403`, the partner is exempt, and the log shows `10.55.20.20 via=10.55.0.5`.

Can Bob claim to be a partner by sending the header himself?
```bash
burst 40 /api/sp --from $BOB --conc 4 -H "X-Forwarded-For: $PARTNER" | head -1
```
<details>
<summary>Answer</summary>

No: 21 of 40, Bob's normal limit. His connection doesn't come from a `set_real_ip_from` address, so his header is ignored.
</details>

Last, a chain: the load balancer itself appears in the header (another trusted hop added it). Compare the default with `real_ip_recursive on;` (add it under `real_ip_header`):
```bash
r /api/c --from $LB -H "X-Forwarded-For: 10.55.100.70, 10.55.0.5"; lim 1
# add real_ip_recursive on; then
./lab.sh reload
r /api/c --from $LB -H "X-Forwarded-For: 10.55.100.70, 10.55.0.5"; lim 1
```
<details>
<summary>Results</summary>

* Without `recursive`, the client is `10.55.0.5`: the last address in the header, even though that's your own load balancer.
* With `recursive`, NGINX skips trusted addresses from the right and uses `10.55.100.70`.

A forged address at the left end (`10.55.20.1, 10.55.100.70`) is never used either way.
</details>

---

## 4. The Sprint Lab: The Lumina API Gateway (38 Minutes)

The requirements are in [`README.md` section 4](README.md#4-lab-specification-the-lumina-api-gateway). Start from the starter, which loads but enforces nothing:
```bash
cd /srv/nginx-journey/sprints/sprint-5/lab
cp starter_nginx.conf nginx.conf
./lab.sh edge                           # a fresh gateway: no zones left over from the activities
cd .. && ./test_sprint05.sh
```
The baseline run takes about 20 seconds. Every requirement fails, and the run ends with **`Sprint 5 start is ready to go`**: the lab is up, the config loads, and nothing is built yet. If it stops at the preflight instead, fix the `[!!]` items first.

Now complete the TODOs in `lab/nginx.conf`, reload with `./lab.sh reload` (or `./lab.sh edge` if a reload is refused), and run `./test_sprint05.sh` until it reports **`13 / 13`** and **`Sprint 5 lab gate PASSED`**.
* The test sends from fresh addresses every run, so earlier runs don't use up its limits.
* Each failure prints what it measured. Compare that with the requirement before changing the config.

---

## 5. Day 3 Concept Examination (10-Question Randomized Quiz)

```bash
cd /srv/nginx-journey && python3 -m http.server 8090
```
👉 **http://&lt;lab-host&gt;:8090/quiz.html?sprint=5&day=3**

Optional: [Enterprise Side Quest](day_03_enterprise.md) and its quiz. When you're done: `./lab.sh down`.

---

## 6. Key Takeaways for Day 3
* **Limits run before `deny`.** Refuse blocked clients in the rewrite phase (`geo` + `if ... return 403`), or they get `429`s and use your zones.
* **`allow`/`deny` stop at the first match.** Order them from specific to general.
* **`geo` turns addresses into tiers, and `map`s turn tiers into policy:** an empty key for exemptions, a rate for `limit_rate`.
* **A zone's key can't change on reload.** `nginx -t` passes and the reload signal succeeds, but the master refuses; check the error log, then restart or rename the zone.
* **Behind a load balancer, trust its header and only its header.** `set_real_ip_from` + `real_ip_header`, and `real_ip_recursive on` for chains of trusted proxies.

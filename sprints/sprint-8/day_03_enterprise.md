# Sprint 8 &bull; Day 3 (Optional) Enterprise Side Quest: F5 NGINX Ingress Controller with NGINX Plus

**Day:** Optional, after Day 3  
**Estimated Time:** 60 Minutes (10 concepts, 5 setup, 45 hands-on)  
**Theme:** All week, open source NGINX reloaded for every pod that came or went, a half-broken pod could only be found with real user requests, and a canary's weights meant a new configuration. The same controller built with **NGINX Plus** changes upstreams and split weights through the Plus API without reloading. It probes pods itself and keeps a sick one out until it recovers, eases it back in, queues a surge instead of failing it, rate-limits partners by the tier written in their token, and (new in 5.8) decides who may call an API from the claims in that token. You run it **next to** the open source controller in the same cluster, on the same host name, and compare them side by side.

> **Status:** run end to end on the lab box with F5 NGINX Ingress Controller 5.8.0 (NGINX Plus R37.3, nginx 1.31.8), Helm chart 2.9.0, on the kind cluster from the main lab.

---

## 1. Concepts to Understand (10 Minutes)

### 1.1 What Plus Changes Inside the Controller
* **Endpoints without reloads.** When pods come and go, the controller updates the upstream's servers through the **Plus API** (and still rewrites the file, so a later reload agrees). Open source NGINX reloads every time.
* **Split weights without reloads** (`controller.enableWeightChangesDynamicReload`). The controller pre-generates a `split_clients` block for every possible weight pair and picks the active one through a **key-value store** (`keyval`), so changing weights is a keyval update. For many two-way splits, the ConfigMap's `map`/`variables` hash sizes may need raising.
* **The Plus API and dashboard** in the controller pod (port 8080, `allow 127.0.0.1` only): live peers, their state, requests, health-check results, queue overflows.
* **Licensing in Kubernetes:** the license JWT is a Secret (`controller.mgmt.licenseTokenSecretName`), and the same JWT is the username of the image pull Secret for `private-registry.nginx.com`. The controller logs `license accepted ... expires in N days` at start.

### 1.2 Circuit Breaking, Built From Parts
There's no object called "circuit breaker". The behavior comes from upstream fields:

| Part | What it does | Open source equivalent |
| :--- | :--- | :--- |
| `healthCheck` (Plus) | NGINX probes each pod on a path of your choice (`path`, `interval`, `fails`, `passes`, `statusMatch`). A pod that fails is **ejected**, and comes back only after `passes` successes. | Passive only: `max-fails` / `fail-timeout`, counting the failures `next-upstream` lists, found by real requests |
| `mandatory: true` | A **new** pod gets no traffic until it passes the check | The Kubernetes readiness probe (which checks what the *app* says, not the path NGINX uses) |
| `persistent: true` | After a reload, a pod that was healthy stays up instead of being re-checked from zero | n/a |
| `slow-start` (Plus) | A pod returning to service ramps from weight 0 to full over this time. **Not compatible with the controller's default `random two least_conn`**: set `lb-method`. | None |
| `max-conns` + `queue` (queue is Plus) | At most N connections per pod. Excess requests **wait in a queue** (`size`, `timeout`) instead of failing. | `max-conns` alone: excess requests fail at once with 502 |

**Check the real path, not `/healthz`.** A half-broken pod answers `/healthz` happily: that's why Kubernetes still calls it ready. The health check should ask for something the users ask for.

### 1.3 JWT Tiers and Claim Authorization
* **The `jwt` Policy (Plus)** validates bearer tokens (a local JWK Secret of type `nginx.org/jwk`, or a remote JWKS) and makes claims available as `$jwt_claim_*`.
* **Rate-limit tiers:** several `rateLimit` Policies on one route, each with `condition.jwt` (`claim`, `match`). The one marked `default: true` applies when no tier matches. The controller turns the claim into a `map` that picks one limit zone per request.
* **Claim authorization (new in 5.8):** `jwt.authorization.rules[].claims[]` with `match` (`Exact`, `Regex`, `Contains`, `Present`), `negate`, `require` (`All`/`Any`) per rule and across rules, `errorCode` for a refused claim (authentication failures are always 401), and `proxySetHeader` to send a claim to the upstream as a header. Before 5.8 this needed snippets or njs.

### 1.4 Open Source vs Plus

| Need | Open source controller | Plus controller |
| :--- | :--- | :--- |
| Pods come and go | A reload per batch | Plus API, no reload |
| Change canary weights | A reload | keyval, no reload |
| Find a half-broken pod | Real requests fail, are retried (`http_500` in `next-upstream`), bench it for `fail-timeout`, then try again with a real request | Active check ejects it within `interval` × `fails`; it returns after `passes` |
| Bring a pod back gently | n/a | `slow-start` |
| Surge above capacity | `max-conns`: 502 for the excess | `max-conns` + `queue`: wait up to `timeout` |
| See what's happening | Prometheus metrics, logs | Plus API and dashboard, per peer |
| Bearer tokens, tiers by claim, claim authorization | `externalAuth` Policy to a validator, or snippets/njs | `jwt` Policy, `condition.jwt`, `authorization.rules` |

### 1.5 BIG-IP Lens
Health monitor on a pool = `healthCheck`; **Slow Ramp Time** = `slow-start`; a member **Connection Limit** with the pool's **Request Queuing** (queue depth and time limit) = `max-conns` + `queue`; APM's OAuth resource server with a per-request policy branching on claims = the `jwt` Policy with `authorization` rules; an iRule or LTM policy choosing a rate-limit class by claim ≈ `rateLimit` tiers.

---

## 2. Lab Setup (5 Minutes)

This side quest follows the [NGINX Plus lab convention](../../docs/nginx-plus-lab.md): the license is `~/plus/license.jwt` on the host (the Kubernetes section of that page explains how it becomes Secrets). It runs in the **same cluster** as the main lab, next to the open source controller.

```bash
# host, any directory
cd /srv/nginx-journey/sprints/sprint-8/lab
./lab.sh up                 # if the cluster isn't running (installs the open source controller too)
source helpers.sh
```
**The open source side, for comparisons:** if your sprint lab passes 10/10, keep it. Otherwise load the reference:
```bash
# host, lab/
./lab.sh reset && solution/apply.sh
```
Then install the Plus controller and open its API:
```bash
# host, lab/
cat plus/nic-plus-values.yaml
./lab.sh plus up
./lab.sh plus api
```
* `plus up` creates namespace `nginx-plus`, the Secrets `nplus-license` (the license) and `regcred` (the image pull secret: the license JWT as username), then installs the chart with `plus/nic-plus-values.yaml`: image `nginx-plus-ingress:5.8.0`, IngressClass **`nginx-plus`**, NodePorts 30086/30087 (host **8086/8087**), and dynamic weight changes on.
* `plus api` runs a `kubectl port-forward` in the background from **127.0.0.1:8085** to the controller pod's API port. If 8085 is taken (Sprint 7's `s7-plus` container uses it), stop that first (`cd ../../sprint-7/lab && ./lab.sh plus down`), or use another port: `export PLUS_API_PORT=8095` before both `./lab.sh plus api` and `papi`.

New helpers: `pt` / `ptc` / `pwho` (like `t` / `tc` / `who`, but to the **Plus** controller on 8087), `papi /PATH` (the Plus API, version 9), `preloads` (the Plus controller's reload counters), `burst N MS [plus]` (N requests at once), `token SUB TIER [ROLES]` (a lab JWT signed with `lab/secrets/jwt.key`). Everything still runs on the **host, in `lab/`**.

---

## 3. Hands-on Activities (45 Minutes)

### Activity 3.1: Two Controllers, One Cluster (5 min)
```bash
# host, lab/
kubectl get ingressclass
./lab.sh plus logs 50 | grep 'license accepted'
./lab.sh conf
./lab.sh plus conf
```
Two classes, `nginx` and `nginx-plus`, **both with controller `nginx.org/ingress-controller`**. Your `transit` VirtualServer (class `nginx`) is in the open source controller's `conf.d` and not in the Plus one's.

<details>
<summary>What would happen to a VirtualServer with no <code>ingressClassName</code> now?</summary>

Both controllers would configure it: each handles resources of its own class *and* resources without one. You'd have the same host served by both, with different behavior depending on which port the client reached, and both writing the resource's status. Check it with a throwaway VirtualServer for `noclass.copperline.test` without `ingressClassName`: `./lab.sh conf` and `./lab.sh plus conf` both list it. Delete it afterwards. This is why every resource this week named its class.
</details>

### Activity 3.2: The Canary on Plus, and the Reload Counters (8 min)
Create a VirtualServer for the **same host**, served by the Plus controller:
```yaml
# file: lab/work/sq-plus-vs.yaml
apiVersion: k8s.nginx.org/v1
kind: VirtualServer
metadata:
  name: transit-plus                   # a second VirtualServer for the same host...
  namespace: transit
spec:
  ingressClassName: nginx-plus         # ...handled only by the Plus controller (host ports 8086/8087)
  host: transit.copperline.test
  tls:
    secret: transit-tls
  upstreams:
  - name: arrivals-v1
    service: arrivals
    port: 80
  - name: arrivals-v2
    service: arrivals-v2
    port: 80
  routes:
  - path: /arrivals
    splits:
    - weight: 90
      action:
        pass: arrivals-v1
    - weight: 10
      action:
        pass: arrivals-v2
```
```bash
# host, lab/
kubectl apply -f work/sq-plus-vs.yaml
kubectl -n transit get virtualservers
pwho 20 /arrivals/x | awk '{n[$2]+=$1} END {for (v in n) print n[v], v}'
papi /http/upstreams | jq -c 'to_entries[] | {upstream: .key, peers: [.value.peers[] | {server, state}]}'
```
Two VirtualServers, both `Valid`, same host, different controllers. The Plus API lists each upstream's pods and their state.

Now scale arrivals and compare the two controllers' reload counters:
```bash
# host, lab/
reloads; preloads
kubectl -n transit scale deployment arrivals-v1 --replicas=5
kubectl -n transit rollout status deployment arrivals-v1
sleep 5
kubectl -n transit scale deployment arrivals-v1 --replicas=3
sleep 12
reloads; preloads
papi /http/upstreams/vs_transit_transit-plus_arrivals-v1 | jq '.peers | length'
```
In the lab runs, the open source controller's `reason="endpoints"` counter went up by **7 or 8**. The Plus controller's stayed at **0**, yet its peer list followed the pods.

Change the weights on **both** controllers, then compare again:
```bash
# host, lab/
kubectl -n transit patch vs transit-plus --type=json \
  -p '[{"op":"replace","path":"/spec/routes/0/splits/0/weight","value":50},{"op":"replace","path":"/spec/routes/0/splits/1/weight","value":50}]'
sleep 3; reloads; preloads
pwho 40 /arrivals/x | awk '{n[$2]+=$1} END {for (v in n) print n[v], v}'
papi /http/keyvals | jq .
./lab.sh plus conf vs_transit_transit-plus.conf | grep -c '^split_clients'
```
For the open source side, change the weights in your own VirtualServer file (the `/arrivals` route's splits), apply it, and run `reloads` again: `reason="other"` goes up by one. The Plus controller's counters don't move. Its keyval now holds `..._50_50`, the name of one of the **101** pre-built `split_clients` blocks.

<details>
<summary>Why does a reload matter if it's graceful?</summary>

Each reload starts a new set of workers, and the old set lives until its connections finish: long-lived connections (WebSockets, gRPC streams, slow downloads) keep old workers and their memory around, and with frequent reloads several generations pile up. Health-check state, the keepalive pool and per-worker caches start fresh in the new workers. In a cluster that autoscales, "every pod change is a reload" can mean a reload every few seconds at peak. Plus removes the reload from the endpoint path entirely.
</details>

### Activity 3.3: Active Health Checks, the Circuit Breaker (10 min)
In **`lab/work/sq-plus-vs.yaml`**, replace the `arrivals-v1` upstream (the four lines from `- name: arrivals-v1` to `port: 80`) with:
```yaml
  - name: arrivals-v1
    service: arrivals
    port: 80
    lb-method: least_conn              # slow-start doesn't work with the default random two least_conn
    slow-start: 30s
    healthCheck:
      enable: true
      path: /arrivals/health           # a real application path, not /healthz
      interval: 1s
      fails: 1
      passes: 2
      statusMatch: "200"
      mandatory: true
      persistent: true
```
```bash
# host, lab/
kubectl apply -f work/sq-plus-vs.yaml
sleep 3; kubectl -n transit get vs transit-plus
```

<details>
<summary>If you leave out <code>lb-method</code>, what does the controller do with <code>slow-start</code>?</summary>

It applies the VirtualServer with a `Warning`: `Slow start will be disabled for upstream arrivals-v1 because lb method 'random two least_conn' is incompatible with slow start`. NGINX's `slow_start` doesn't work with `random`, `hash` or `ip_hash`, and the controller's default is `random two least_conn`. Always read the STATE after an apply.
</details>

Define a small function for this activity (it only lives in this terminal) and break one pod:
```bash
# host, lab/
peers() { papi /http/upstreams/vs_transit_transit-plus_arrivals-v1 | jq -c '[.peers[] | {ip: (.server|split(":")[0]), state, requests, hc_fails: .health_checks.fails}]'; }
peers
pod-fail arrivals on v1
sleep 2; peers
for i in $(seq 30); do ptc /arrivals/x; done | sort | uniq -c
peers
kubectl -n transit get pods -l app=arrivals,version=v1
```
Within two seconds the failing pod is `unhealthy`. All 30 requests get `200`, and the failing pod's `requests` counter **doesn't move**: no user request reached it, not even the first one. Kubernetes still shows it `1/1 Ready`.

<details>
<summary>Compare with Day 3's open source fix (<code>http_500</code> in <code>next-upstream</code>, <code>fail-timeout: 30s</code>). What's different for the users?</summary>

In open source, the broken pod is found by a user's request: it fails, NGINX retries it on another pod (so that user waits for two responses), and the pod is benched for 30 seconds, after which another user's request finds out whether it's still broken. With an active check, NGINX's own probes find it, users never reach it, and it stays out for as long as it's broken. It comes back only after two passing probes, not after a timer.
</details>

Now repair it and watch it come back slowly:
```bash
# host, lab/
pod-fail arrivals off v1
sleep 3; peers
for w in 1 2 3; do
  before=$(papi /http/upstreams/vs_transit_transit-plus_arrivals-v1 | jq -c '[.peers[].requests]')
  for i in $(seq 40); do ptc /arrivals/x >/dev/null; done
  echo "window $w: requests per pod $before -> $(papi /http/upstreams/vs_transit_transit-plus_arrivals-v1 | jq -c '[.peers[].requests]')"
  sleep 6
done
```
It's `up` again after two passing checks. In the lab run, the recovered pod took about 2 of the first ~36 requests, then 4, then 7, ramping toward its full third over the 30 seconds of `slow-start`. (The peers are listed in the same order each time, so compare the same position.)

<details>
<summary>What do <code>mandatory</code> and <code>persistent</code> add here, when Kubernetes already has a readiness probe?</summary>

`mandatory`: a newly added pod (scale-up, rollout) gets no traffic from NGINX until it passes **NGINX's** check on the path you chose, not just the app's own `/healthz`. `persistent`: after a reload, pods that were healthy stay up instead of all being treated as new and re-checked, so a configuration change doesn't briefly empty the pool. Without `persistent`, every reload with `mandatory` would pause traffic until the first checks pass.
</details>

### Activity 3.4: A Queue Instead of a 502 (6 min)
First the open source behavior, through your open source VirtualServer. Add `max-conns: 2` to its `arrivals-v1` upstream (in your sprint-lab file, or `solution/transit-vs.yaml` if you loaded the reference; same indentation as `port:`), apply it, and send 12 one-second requests at once:
```bash
# host, lab/
burst 12 1000
```
In the lab run: `200 x 6   502 x 6`. Three pods × 2 connections, and the other six fail **at once** (`no live upstreams` in `nlogs`). Remove `max-conns` again and apply.

On Plus, add a queue. In **`lab/work/sq-plus-vs.yaml`**, in the `arrivals-v1` upstream, add below `slow-start: 30s`:
```yaml
    max-conns: 2
    queue:
      size: 10
      timeout: 3s
```
```bash
# host, lab/
kubectl apply -f work/sq-plus-vs.yaml
sleep 3
burst 12 1000 plus
burst 30 2000 plus
papi /http/upstreams/vs_transit_transit-plus_arrivals-v1 | jq -c '{queue}'
./lab.sh plus logs 80 | grep -oE 'upstream queue is full|upstream queue timeout' | sort | uniq -c
```
Twelve at once: all `200`, the slowest after about 2 seconds (six waited in the queue for a free slot). Thirty requests of 2 seconds each: the lab run got 15 × `200` and 15 × `502`. Some were refused because the queue (10) was full, and the rest waited past its 3-second `timeout`. The API counts `overflows`.

<details>
<summary>When is a queue the wrong answer?</summary>

When the excess isn't a brief spike. A queue turns overload into latency: every queued request waits, holding a client connection and an NGINX connection, and if demand stays above capacity the queue just fills and times out, adding the wait to the failure. Keep the queue short and its timeout below the clients' own timeout, and pair it with rate limits or autoscaling for sustained load. It's the same reasoning as BIG-IP's request queuing depth and time limit.
</details>

### Activity 3.5: Partner Tiers From the Token (8 min)
Copperline sells its arrivals feed to journey-planner partners. Gold partners get 10 requests per second, everyone else 1. Each partner's tier is a claim in its token. The tokens are signed with the lab's key: store it as a JWK Secret, which is what the `jwt` Policy reads:
```bash
# host, lab/
python3 tools.py jwk | jq .
kubectl -n transit create secret generic copperline-jwk --type=nginx.org/jwk --from-literal=jwk="$(python3 tools.py jwk)"
token acme gold | cut -c1-40; decode "$(token acme gold)"
```
```yaml
# file: lab/work/sq-plus-policies.yaml
apiVersion: k8s.nginx.org/v1
kind: Policy
metadata:
  name: partner-token
  namespace: transit
spec:
  jwt:
    realm: Copperline Partners
    secret: copperline-jwk
---
apiVersion: k8s.nginx.org/v1
kind: Policy
metadata:
  name: partner-gold
  namespace: transit
spec:
  rateLimit:
    rate: 10r/s
    burst: 20
    noDelay: true
    key: ${jwt_claim_sub}              # per partner, not per address
    zoneSize: 1M
    rejectCode: 429
    condition:
      jwt:
        claim: tier
        match: gold
---
apiVersion: k8s.nginx.org/v1
kind: Policy
metadata:
  name: partner-free
  namespace: transit
spec:
  rateLimit:
    rate: 1r/s
    burst: 2
    noDelay: true
    key: ${jwt_claim_sub}
    zoneSize: 1M
    rejectCode: 429
    condition:
      jwt:
        claim: tier
        match: free
      default: true                    # also for tokens with no tier, or an unknown one
```
In **`lab/work/sq-plus-vs.yaml`**, add a `dispatch` upstream at the end of `spec.upstreams` (needed in 3.6), and a `/partner` route at the end of `spec.routes`:
```yaml
  - name: dispatch                     # at the end of spec.upstreams
    service: dispatch
    port: 80
```
```yaml
  - path: /partner                     # at the end of spec.routes
    policies:
    - name: partner-token
    - name: partner-gold
    - name: partner-free
    action:
      pass: arrivals-v2
```
```bash
# host, lab/
kubectl apply -f work/sq-plus-policies.yaml -f work/sq-plus-vs.yaml
sleep 3; kubectl -n transit get vs transit-plus
ptc /partner/feed
GOLD=$(token acme gold); FREE=$(token planner-bob free)
for i in $(seq 25); do ptc /partner/feed -H "Authorization: Bearer $GOLD"; done | sort | uniq -c
for i in $(seq 25); do ptc /partner/feed -H "Authorization: Bearer $FREE"; done | sort | uniq -c
./lab.sh plus conf vs_transit_transit-plus.conf | grep -E 'auth_jwt_claim_set|limit_req_zone'
```
No token: `401`. Gold: 23 of 25 `200` in the lab run (10/s plus a burst of 20). Free: 3 `200`, then `429`. One route, two limits, chosen per request by a `map` on the `tier` claim.

<details>
<summary>A partner edits its token's payload to say <code>"tier": "gold"</code>. What happens?</summary>

`401`. The signature covers the payload, so an edited token no longer verifies against the JWK, and `auth_jwt` refuses it before any rate-limit tier is chosen. The tier can be trusted because it comes from a validated token, the same rule as Sprint 7: identity and attributes come from something verified, never from what the client says about itself.
</details>

### Activity 3.6: Who May Dispatch: Claim Authorization, New in 5.8 (6 min)
Dispatchers carry `roles: [dispatcher]` in their token. The dispatch console should only let them in, and should know who they are:
```yaml
# file: lab/work/sq-plus-dispatch.yaml
apiVersion: k8s.nginx.org/v1
kind: Policy
metadata:
  name: dispatchers-jwt
  namespace: transit
spec:
  jwt:
    realm: Copperline Dispatch
    secret: copperline-jwk
    authorization:
      errorCode: 403                   # a valid token without the right claims
      rules:
      - require: All
        claims:
        - name: roles
          match: Contains
          values: [dispatcher]
        - name: sub
          match: Present
          proxySetHeader: X-User       # the token's sub, sent to the app as X-User
```
In **`lab/work/sq-plus-vs.yaml`**, add at the end of `spec.routes`:
```yaml
  - path: /dispatch
    policies:
    - name: dispatchers-jwt
    action:
      pass: dispatch
```
```bash
# host, lab/
kubectl apply -f work/sq-plus-dispatch.yaml -f work/sq-plus-vs.yaml
sleep 3; kubectl -n transit get vs transit-plus
ptc /dispatch/board
ptc /dispatch/board -H "Authorization: Bearer $(token carol free rider)"
pt /dispatch/board -H "Authorization: Bearer $(token alice gold dispatcher,staff)" -H 'X-User: mallory' | jq -c '{app, user: .headers."X-User"}'
./lab.sh plus conf vs_transit_transit-plus.conf | grep -c '^map .*jwt_authz'
./lab.sh plus conf vs_transit_transit-plus.conf | grep -E 'auth_jwt_claim_set|auth_jwt_require'
```
No token `401`, a rider `403`, alice gets in, and the app sees `X-User: alice`, not the `mallory` she sent. The rules became `auth_jwt_claim_set`, a chain of `map`s, and `auth_jwt_require ... error=403`.

<details>
<summary>What would this take on the open source controller?</summary>

There's no `jwt` Policy in open source. You'd send every request to an external validator with the `externalAuth` Policy (Sprint 7 Day 2's `auth_request` pattern: one extra call per request, or cached), and have the validator return the user and the decision. Or you'd turn on snippets and write njs to verify the signature and check claims. Both work, and both are code and infrastructure you own. In the Plus controller it's one Policy, checked in-process, with the claim forwarded by name.
</details>

When you're done:
```bash
# host, lab/
./lab.sh plus down          # removes the Plus controller and its namespace; the open source lab keeps running
```

---

## 4. Side Quest Quiz

```bash
# host, any directory (a second terminal)
cd /srv/nginx-journey && python3 -m http.server 8090
```
👉 **http://&lt;lab-host&gt;:8090/quiz.html?sprint=8&day=3&pool=enterprise**

---

## 5. Key Takeaways
* **Plus takes reloads off the endpoint path:** pods come and go and canary weights change through the Plus API and keyval, while open source reloads each time.
* **Circuit breaking is parts:** an active `healthCheck` on a real path (with `mandatory` and `persistent`), `slow-start` (set `lb-method`, the default is incompatible), and `max-conns` with a `queue`.
* **Users never meet a pod the health check has ejected.** Open source can only find it with their requests.
* **A queue trades failures for latency.** Keep it short.
* **Tiers and authorization come from verified claims:** `rateLimit` with `condition.jwt` and a `default`, and 5.8's `jwt.authorization` rules with `proxySetHeader`.
* **Two controllers can share a cluster.** Name the class on every resource, since both claim resources that have none.

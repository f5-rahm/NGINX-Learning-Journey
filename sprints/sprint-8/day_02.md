# Sprint 8 &bull; Day 2: Annotations, the Migration, and F5's Custom Resources
**Day:** 2 of 3  
**Estimated Time:** 90 Minutes (15 concepts, 5 setup, 60 activities, 10 quiz)  
**Theme:** The standard Ingress object can say "this host and path go to that Service" and little else. Everything else (rewrites, timeouts, rate limits, allow-lists) gets bolted on as **annotations**: free-form strings that only one controller understands. That's why moving off the retired community Ingress-NGINX is harder than it looks. Its manifests still *apply* to F5 NGINX Ingress Controller, but much of what they meant silently stops happening. Today you run that migration on a real manifest, then move to F5's **VirtualServer**, **VirtualServerRoute** and **Policy** resources: typed, validated, and delegatable to other teams. You also follow Copperline's TLS private key from your laptop to the node's disk.

---

## 1. Concepts to Understand (15 Minutes)

### 1.1 What the Ingress Object Can't Say
The `networking.k8s.io/v1` Ingress has hosts, paths (`Exact`, `Prefix`, or `ImplementationSpecific`), a backend Service per path, and TLS Secrets per host. That's the whole schema, and the Ingress API is feature-frozen. Everything else is an **annotation** in `metadata.annotations`:
* **Strings, read by one controller.** The API server stores any annotation without checking it. A controller reads the keys it knows (`nginx.org/*` for F5's) and **ignores every other key, without a warning**.
* **Values are validated only when a controller knows the key.** F5's controller rejects a bad `nginx.org/*` value (the Ingress gets a `Rejected` event), but it can't reject what it doesn't recognize.

### 1.2 Migrating From Ingress-NGINX
The community controller's annotations (`nginx.ingress.kubernetes.io/*`) don't exist for F5's controller. A migrated Ingress needs each one translated, and some translate to a different kind of object:

| Ingress-NGINX annotation | F5 NGINX Ingress Controller |
| :--- | :--- |
| `use-regex: "true"` | `nginx.org/path-regex: case_sensitive` (or `case_insensitive`, `exact`) |
| `rewrite-target: /$2` | `nginx.org/rewrite-target: /$2` (with `path-regex`), or `nginx.org/rewrites` |
| `proxy-read-timeout: "5"` | `nginx.org/proxy-read-timeout: "5s"` |
| `ssl-redirect` | `nginx.org/ssl-redirect` (on by default when the Ingress has TLS) |
| `limit-rps` | On an Ingress: `nginx.org/limit-req-rate` and friends. On a VirtualServer: a `rateLimit` **Policy**. |
| `whitelist-source-range` | An `accessControl` **Policy**, attached with `nginx.org/policies` |
| `canary`, `canary-weight`, `canary-by-header` | VirtualServer **`splits`** and **`matches`** (Day 3) |
| `auth-url` | An `externalAuth` **Policy** (since 5.5) |
| `configuration-snippet`, `server-snippet` | `nginx.org/location-snippets`, `nginx.org/server-snippets`, **only if snippets are enabled on the controller**. They're off by default. |

Features built on Ingress-NGINX's Lua modules may have no direct equivalent. The test that matters is how the traffic behaves, not whether `kubectl apply` succeeded.

**Why snippets are off by default.** A snippet is raw NGINX configuration typed into an annotation. Anyone allowed to create an Ingress could then change the controller's configuration for every host, and that kind of annotation injection was at the root of the 2025 "IngressNightmare" vulnerabilities in Ingress-NGINX (CVE-2025-1974). F5's controller refuses an Ingress that has a snippet annotation unless the operator turned snippets on (`controller.enableSnippets`).

### 1.3 VirtualServer and VirtualServerRoute
F5's custom resources (`k8s.nginx.org/v1`) replace annotation strings with typed fields:
* **`VirtualServer`**: one host. It has `tls` (Secret, redirect), `upstreams` (a Service plus per-upstream settings: `lb-method`, timeouts, `max-fails`, `fail-timeout`, `next-upstream`, `keepalive`...), and `routes`, each with an **action**: `pass` (to an upstream), `proxy` (pass while changing request or response headers or rewriting the path), `redirect`, or `return`. Routes can also hold `matches` and `splits` (Day 3) and `policies`.
* **`VirtualServerRoute`**: **delegation.** A VirtualServer route can hand a path to a VirtualServerRoute, `route: fares/fares` (namespace/name). The other team owns that object in its own namespace, with its own upstreams and policies. Every subroute must stay under the delegated path, and the host must match.
* **`ingressClassName`** works the same as on an Ingress. Always set it. A resource without it may be picked up by every F5 controller in the cluster.

**Validated twice:**
1. **By the API server, against the CRD's schema**, when you apply: wrong types and unknown fields are refused, and nothing is stored.
2. **By the controller**, after it's stored: references (an upstream name, a Secret, a Policy, a delegated route) and their contents. The result is the resource's **STATE** (`Valid`, `Warning`, `Invalid`) with a message and an **Event**. `Warning` means it was applied with something missing. `Invalid` means it wasn't applied, and **the host's previous configuration is removed too**, not kept.

### 1.4 Policies
A **Policy** is a reusable object referenced from a VirtualServer, a route, or a VirtualServerRoute subroute (some types also work on an Ingress, through `nginx.org/policies`):

| Open source and Plus | NGINX Plus only |
| :--- | :--- |
| `accessControl`, `rateLimit`, `connectionLimit` (new in 5.8), `basicAuth`, `apiKey`, `ingressMTLS`, `egressMTLS`, `externalAuth`, `cors`, `hsts`, `cache` | `jwt` (with claim-based authorization, new in 5.8), `oidc`, `waf`, `rateLimit` tiers keyed on JWT claims |

**A route that references a missing or invalid Policy answers `500`.** It fails closed, and other routes keep working. A `rateLimit` Policy attached to an Ingress isn't supported: the controller warns, and the **whole host** answers 500.

### 1.5 TLS Secrets, and Where the Private Key Goes
* **A `kubernetes.io/tls` Secret** holds `tls.crt` and `tls.key`, **base64-encoded**. That's an encoding, not encryption.
* **etcd stores it as given** unless the cluster is configured with encryption at rest (an `EncryptionConfiguration`, ideally with a KMS provider). Many clusters, and this lab's, aren't.
* **Anyone who can `get` Secrets in the namespace can read the key.** The controller's ServiceAccount can read Secrets in **every namespace** by default. Narrowing what it watches (`controller.watchSecretNamespace`) adds a namespaced Role but doesn't remove that cluster-wide permission.
* **The controller writes the certificate and key into one PEM file** in its pod (`/etc/nginx/secrets/`, mode 0600, owned by the `nginx` user), which lives on the **node's disk**.

What to do about it in production:
* The source of truth is a secrets manager (Vault, a cloud KMS or HSM) or an issuer (cert-manager with ACME or an internal CA), so no human handles keys. Note that tools like External Secrets Operator still end up writing a Kubernetes Secret: they move where the master copy lives, not what the cluster stores.
* Turn on etcd encryption at rest with KMS, and limit who can `get`/`list` Secrets (RBAC).
* Never put a key in git, a Helm values file, or an unencrypted backup.
* Treat the controller pod and its node as a key-holding tier, like the BIG-IP itself: encrypted node disks, few people with node or `exec` access.

### 1.6 BIG-IP Lens

| Need | BIG-IP | F5 NGINX Ingress Controller |
| :--- | :--- | :--- |
| Settings for one virtual server | Profiles and settings, validated by tmsh | Ingress annotations (strings) or VirtualServer fields (typed) |
| An invalid change | Refused; the running config stays | Schema errors are refused at `apply`. A semantic error (`Invalid`) **removes the host's config**. |
| Reusable behavior | Profiles, iRules, LTM policies | `Policy` resources |
| Another team owns part of the site | Partitions, route domains, iApp/AS3 tenants | VirtualServerRoute in the team's namespace, delegated by path |
| Private keys | `/config/filestore` on the device; FIPS card or NetHSM to keep keys out of software | Kubernetes Secret in etcd, then a PEM file in the controller pod on the node's disk |
| Who can read keys | Admin roles, root, iControl REST access | RBAC `get secrets`, the controller's ServiceAccount, node root, `kubectl exec` into the controller |

---

## 2. Lab Setup (5 Minutes)

Day 2 starts from a lab with the controller installed and none of Day 1's objects. Pick the line that matches your lab:
```bash
# host, any directory
cd /srv/nginx-journey/sprints/sprint-8/lab
./lab.sh reset      # if the cluster is still up from Day 1: removes your Ingress, restores apps and controller settings
./lab.sh up         # if you ran ./lab.sh down: starts the cluster AND installs the controller (no --no-nic this time)
source helpers.sh
```
Both end with `Lab ready` and `NGINX Ingress Controller pod Ready`. As on Day 1, every block below runs on the **host in `lab/`** unless it says otherwise, and files go in `lab/work/`.

New today: **HTTPS on port 8099.** `t PATH` sends `https://transit.copperline.test:8099/PATH` to the controller and trusts the lab CA (`certs/ca.crt`). `th` shows the headers, `tc` only the status code, `who N PATH` counts which pods answered. For other hosts, `hreq HOST PATH` still uses plain HTTP on 8098.

---

## 3. Hands-on Guided Discovery Activities (60 Minutes)

### Activity 3.1: The Migration Drill (8 min)
`lab/k8s/legacy-ingress.yaml` is an Ingress written for the retired Ingress-NGINX: regex path with a rewrite, an office-only allow-list, 2 requests per second, a 5-second timeout, and a snippet. Read its comments, then apply it to F5's controller unchanged:
```bash
# host, lab/
cat k8s/legacy-ingress.yaml
kubectl apply -f k8s/legacy-ingress.yaml
kubectl -n transit describe ingress legacy | sed -n '/Events/,$p'
```

<details>
<summary>Before you test: the event says <code>Normal AddedOrUpdated</code>. Which of the five intentions do you expect to work?</summary>

None of them. F5's controller ignores every `nginx.ingress.kubernetes.io/*` key (it doesn't know them), so there's no warning. The path is `ImplementationSpecific` without `nginx.org/path-regex`, so the regex is treated as a literal prefix.
</details>

```bash
# host, lab/
hreq legacy.copperline.test /api/next | head -1
hreq legacy.copperline.test '/api(/|$)(.*)' | sed -n '1p;/"path"/p;/X-Legacy/p'
for i in $(seq 8); do curl -s -o /dev/null -w '%{http_code} ' -H 'Host: legacy.copperline.test' 'http://127.0.0.1:8098/api(/|$)(.*)'; done; echo
nconf transit-legacy.conf | grep -E 'location|rewrite|limit_req|allow|deny|read_timeout'
```
`/api/next` is a `404`, and only the literal string `/api(/|$)(.*)` reaches arrivals, unrewritten. Eight quick requests all get `200`, from your host, which isn't in `192.0.2.0/24`. There's no `X-Legacy` header. The generated `location` is the literal string, and `proxy_read_timeout` is the default `60s`.

### Activity 3.2: Translate It (12 min)
Create the translated Ingress:
```yaml
# file: lab/work/day2-legacy-nic.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: legacy                         # same name: applying it replaces the drill's Ingress
  namespace: transit
  annotations:
    nginx.org/path-regex: "case_sensitive"
    nginx.org/rewrite-target: "/$2"
    nginx.org/proxy-read-timeout: "5s"
    nginx.org/limit-req-rate: "2r/s"
    nginx.org/limit-req-key: "${binary_remote_addr}"
    nginx.org/limit-req-burst: "10"
    nginx.org/limit-req-reject-code: "429"
spec:
  ingressClassName: nginx
  rules:
  - host: legacy.copperline.test
    http:
      paths:
      - path: /api(/|$)(.*)
        pathType: ImplementationSpecific
        backend:
          service:
            name: arrivals
            port:
              number: 80
```
```bash
# host, lab/
kubectl apply -f work/day2-legacy-nic.yaml
hreq legacy.copperline.test /api/next | sed -n '1p;/"path"/p'
for i in $(seq 16); do curl -s -o /dev/null -w '%{http_code} ' -H 'Host: legacy.copperline.test' http://127.0.0.1:8098/api/next; done; echo
nconf transit-legacy.conf | grep -E 'location|rewrite|limit_req |read_timeout'
```
Now `/api/next` reaches arrivals as `/next`, and the location is a regex (`location ~ "^/api(/|$)(.*)"`) with a `rewrite`.

<details>
<summary>All 16 quick requests got 200, with a limit of 2 per second. Is the limit broken?</summary>

No. `limit_req ... burst=10` without `nodelay` **queues** requests above the rate and releases them at 2 per second (Sprint 5). Your sequential curls simply waited. Add `nginx.org/limit-req-no-delay: "true"` under the other `limit-req` annotations, apply, and run the loop again: about 11 answers `200` (1 plus the burst of 10), then `429`. Ingress-NGINX's `limit-rps` also came with a burst (5 times the rate by default, `limit-burst-multiplier`). After a migration, set the burst and delay on purpose instead of inheriting either default.
</details>

**The office allow-list** becomes an `accessControl` Policy:
```yaml
# file: lab/work/day2-office-only.yaml
apiVersion: k8s.nginx.org/v1
kind: Policy
metadata:
  name: office-only
  namespace: transit
spec:
  accessControl:
    allow: ["192.0.2.0/24"]
```
```bash
# host, lab/
kubectl apply -f work/day2-office-only.yaml
kubectl -n transit annotate ingress legacy nginx.org/policies=office-only
sleep 2; hreq legacy.copperline.test /api/next | head -1
nconf transit-legacy.conf | grep -E 'allow|deny'
```
`403 Forbidden`: you're not in the office network. (`kubectl annotate` adds one annotation to a live object, the same as adding it to the file and applying.)

**The trap: a rate-limit Policy on an Ingress.** Someone tidies up and moves the rate limit into a Policy too:
```yaml
# file: lab/work/day2-legacy-rate.yaml
apiVersion: k8s.nginx.org/v1
kind: Policy
metadata:
  name: legacy-rate
  namespace: transit
spec:
  rateLimit:
    rate: 2r/s
    key: ${binary_remote_addr}
    zoneSize: 1M
```
```bash
# host, lab/
kubectl apply -f work/day2-legacy-rate.yaml
kubectl -n transit annotate ingress legacy nginx.org/policies=office-only,legacy-rate --overwrite
sleep 2
kubectl -n transit describe ingress legacy | sed -n '/Events/,$p' | tail -1
hreq legacy.copperline.test /api/next | head -1
nconf transit-legacy.conf | grep -n 'return 500'
```

<details>
<summary>What happened, and what's the lesson for a migration runbook?</summary>

`Policy transit/legacy-rate is not supported on Ingress resources` (a `Warning` event), and the controller put `return 500;` at the top of the host's `server` block. **Every** path on `legacy.copperline.test` now fails, not only the rate limit. Rate-limit Policies need a VirtualServer. On an Ingress, use the `nginx.org/limit-req-*` annotations. The runbook lesson: after every apply, read the **events** (`kubectl describe`) and test the traffic. "Applied" means stored, not working.
</details>

Remove the policies from the Ingress before moving on:
```bash
# host, lab/
kubectl -n transit annotate ingress legacy nginx.org/policies-
sleep 2; hreq legacy.copperline.test /api/next | head -1
```
(The `-` after the key removes the annotation.) It's back to `200`. The snippet's `X-Legacy` header is the one intention left untranslated: with snippets off you'd do it with a VirtualServer `proxy` action's `responseHeaders` instead.

### Activity 3.3: A VirtualServer With TLS (10 min)
Store Copperline's certificate and key (made by `lab.sh` in `lab/certs/`) as a TLS Secret:
```bash
# host, lab/
kubectl -n transit create secret tls transit-tls --cert=certs/transit.crt --key=certs/transit.key
kubectl -n transit get secrets
```
Then write the VirtualServer for `transit.copperline.test`:
```yaml
# file: lab/work/day2-vs.yaml
apiVersion: k8s.nginx.org/v1
kind: VirtualServer
metadata:
  name: transit
  namespace: transit
spec:
  ingressClassName: nginx
  host: transit.copperline.test
  tls:
    secret: transit-tls
    redirect:
      enable: true
      code: 301
  upstreams:
  - name: web
    service: web
    port: 80
  - name: arrivals
    service: arrivals
    port: 80
  - name: dispatch
    service: dispatch
    port: 80
  routes:
  - path: /
    action:
      pass: web
  - path: /arrivals
    action:
      pass: arrivals
  - path: /dispatch
    action:
      pass: dispatch
```
```bash
# host, lab/
kubectl apply -f work/day2-vs.yaml
kubectl -n transit get virtualservers
t /arrivals/next | jq -c '{app, pod, proto: .headers."X-Forwarded-Proto"}'
th / | head -2
hreq transit.copperline.test /arrivals/next | grep -iE '^HTTP|^location'
who 6 /arrivals/x
```
`STATE Valid`. HTTPS works with the lab CA, and plain HTTP gets `301` to `https://transit.copperline.test/arrivals/next`. (In the lab that redirect drops the `:8099`, because the controller builds it from the host name and its own port 443. Behind a real load balancer on 443, it's right.)
```bash
# host, lab/
nconf
nconf vs_transit_transit.conf | grep -E '^upstream|listen|ssl_certificate|return 301|location'
```
The file is `vs_<namespace>_<name>.conf`. The HTTP-to-HTTPS redirect is an `if ($scheme = 'http')` in the server block, and both `ssl_certificate` and `ssl_certificate_key` point at the same file, `ssl_keypair_transit_transit-tls.pem` (3.7).

### Activity 3.4: Two Kinds of Validation (8 min)
**Refused by the API server.** Make a broken copy with a string where the schema wants a number:
```bash
# host, lab/
sed '0,/port: 80$/s//port: eighty/' work/day2-vs.yaml > work/day2-vs-broken.yaml
grep -n eighty work/day2-vs-broken.yaml
kubectl apply -f work/day2-vs-broken.yaml
```
`The VirtualServer "transit" is invalid: spec.upstreams[0].port ... must be of type integer`. Nothing was stored, and the site keeps running.

**Accepted, then rejected by the controller.** Now a typo in a reference: `dispatcher` instead of `dispatch`:
```bash
# host, lab/
sed 's/      pass: dispatch/      pass: dispatcher/' work/day2-vs.yaml > work/day2-vs-broken.yaml
kubectl apply -f work/day2-vs-broken.yaml
sleep 2
kubectl -n transit get vs transit
kubectl -n transit describe vs transit | sed -n '/Events/,$p' | tail -1
tc /arrivals/x
hreq transit.copperline.test /arrivals/x | head -1
```

<details>
<summary>The typo is in the <code>/dispatch</code> route. Why are <code>/arrivals</code> and HTTPS down too?</summary>

`STATE Invalid`: `spec.routes[2].action.pass: Not found: "dispatcher"`. An invalid VirtualServer isn't applied, and the controller **removes the host's configuration instead of keeping the last good one**. HTTPS now fails at the handshake (`000`: the default server refuses TLS for unknown names), and HTTP gets the default server's 404. On BIG-IP an invalid change is refused and the running config stays. Here the bad version replaced the good one in the API server, so the only "last good config" is whatever you have in git. Validate before you apply (`kubectl apply --dry-run=server` checks only the schema; a staging controller or CI that applies first catches the rest).
</details>

**Applied with a warning.** Fix the typo, then point the TLS at a Secret that doesn't exist (say, next year's, not created yet):
```bash
# host, lab/
kubectl apply -f work/day2-vs.yaml
sed 's/secret: transit-tls/secret: transit-tls-2027/' work/day2-vs.yaml > work/day2-vs-broken.yaml
kubectl apply -f work/day2-vs-broken.yaml
sleep 2
kubectl -n transit get vs transit -o jsonpath='{.status.state}: {.status.message}{"\n"}'
tc /arrivals/x; echo "curl exit code: $?"
hreq transit.copperline.test /arrivals/x | grep -iE '^HTTP|^location'
```
`Warning`, with the reason in the message. HTTPS for this host is refused at the handshake (curl exit 35, `unrecognized name`), while HTTP still redirects clients to the HTTPS that no longer works. Put it right:
```bash
# host, lab/
kubectl apply -f work/day2-vs.yaml
rm work/day2-vs-broken.yaml
sleep 2; tc /arrivals/x
```

### Activity 3.5: Delegate /fares to the Fares Team (8 min)
The fares team owns namespace `fares`. They write their own route object:
```yaml
# file: lab/work/day2-fares-vsr.yaml
apiVersion: k8s.nginx.org/v1
kind: VirtualServerRoute
metadata:
  name: fares
  namespace: fares                     # the fares team's namespace
spec:
  ingressClassName: nginx
  host: transit.copperline.test        # must match the VirtualServer's host
  upstreams:
  - name: fares
    service: fares                     # a Service in THEIR namespace
    port: 80
  subroutes:
  - path: /fares
    action:
      pass: fares
```
```bash
# host, lab/
kubectl apply -f work/day2-fares-vsr.yaml
sleep 2
kubectl -n fares get virtualserverroutes
kubectl -n fares describe vsr fares | sed -n '/Events/,$p' | tail -1
t /fares/zones | jq -r .app
```

<details>
<summary>It's <code>Warning</code>, and <code>/fares/zones</code> is answered by <code>web</code>. What's missing?</summary>

The other half of the handshake. A VirtualServerRoute is only used when the host's VirtualServer delegates a path to it, so the fares team can't attach themselves to Copperline's host on their own. Until then the VirtualServer "ignores" it, and `/fares/zones` matches the `/` route.
</details>

Delegate it. In **`lab/work/day2-vs.yaml`**, add this route at the end of `spec.routes` (after the `/dispatch` route, same indentation):
```yaml
  - path: /fares
    route: fares/fares                 # namespace/name of the VirtualServerRoute
```
```bash
# host, lab/
kubectl apply -f work/day2-vs.yaml
sleep 2
kubectl get vs,vsr -A
t /fares/zones | jq -c '{app, pod}'
nconf vs_transit_transit.conf | grep -A4 'location "/fares"' | grep resource_
```
Both `Valid`, and the fares app answers. The generated location is tagged with `$resource_type "virtualserverroute"` and namespace `fares`.

Now the fares team adds an admin page. Append to **`lab/work/day2-fares-vsr.yaml`**, under `subroutes` (after the `/fares` subroute):
```yaml
  - path: /admin
    action:
      pass: fares
```
```bash
# host, lab/
kubectl apply -f work/day2-fares-vsr.yaml
sleep 2
kubectl get vs,vsr -A
kubectl -n transit get vs transit -o jsonpath='{.status.message}{"\n"}'
t /fares/zones | jq -r .app
```

<details>
<summary>The fares team got <code>/admin</code> wrong. What happened to <code>/fares</code>, and is that a good failure mode?</summary>

`spec.subroutes[1].path: Invalid value: "/admin": must start with '/fares'`. The whole VirtualServerRoute was ignored, not only the bad subroute, so `/fares/zones` falls through to Copperline's `/` route and `web` answers. A team can't grab paths outside what it was delegated (good), but one bad line takes its whole delegated path offline and sends its traffic to another app (worth knowing). Keep a catch-all route that answers clearly, or none at all, rather than one that quietly serves the wrong app.
</details>

Remove the `/admin` subroute (the three lines you added) from `lab/work/day2-fares-vsr.yaml`, then:
```bash
# host, lab/
kubectl apply -f work/day2-fares-vsr.yaml
sleep 2; t /fares/zones | jq -r .app
```

### Activity 3.6: Policies (8 min)
Two policies: at most 2 requests in progress per client on `/arrivals` (the **ConnectionLimit** Policy is new in 5.8), and HTTP Basic sign-in for `/dispatch`. Basic auth reads its users from a Secret of type `nginx.org/htpasswd`. `lab.sh` made the file (`lab/secrets/htpasswd`, user `dispatcher`, password `radio-check`):
```bash
# host, lab/
kubectl -n transit create secret generic dispatch-users --type=nginx.org/htpasswd --from-file=htpasswd=secrets/htpasswd
```
```yaml
# file: lab/work/day2-policies.yaml
apiVersion: k8s.nginx.org/v1
kind: Policy
metadata:
  name: two-at-a-time
  namespace: transit
spec:
  connectionLimit:
    connections: 2
    rejectCode: 429
---
apiVersion: k8s.nginx.org/v1
kind: Policy
metadata:
  name: dispatchers
  namespace: transit
spec:
  basicAuth:
    realm: Copperline Dispatch
    secret: dispatch-users
```
In **`lab/work/day2-vs.yaml`**, attach them to their routes. Replace the `/arrivals` and `/dispatch` routes with:
```yaml
  - path: /arrivals
    policies:
    - name: two-at-a-time
    action:
      pass: arrivals
  - path: /dispatch
    policies:
    - name: dispatchers
    action:
      pass: dispatch
```
```bash
# host, lab/
kubectl apply -f work/day2-policies.yaml -f work/day2-vs.yaml
sleep 2; kubectl -n transit get vs transit
( for i in 1 2 3 4 5; do tc '/arrivals/slow?ms=1500' & done; wait )
tc /dispatch/board
tc /dispatch/board -u dispatcher:wrong
t /dispatch/board -u dispatcher:radio-check | jq -c '{app, auth: .headers.Authorization}'
nconf vs_transit_transit.conf | grep -E 'auth_basic|limit_conn '
```
Five slow requests at once: two `200`, three `429`. Dispatch: `401`, `401`, then in. The policies became `limit_conn` and `auth_basic` / `auth_basic_user_file` in the generated config.

<details>
<summary>Look at what the dispatch app received. Why is that a problem, and where would you fix it?</summary>

`"auth": "Basic ZGlzcGF0Y2hlcjpyYWRpby1jaGVjaw=="`: the dispatcher's password, base64-encoded, delivered to an application that doesn't need it and might log it. The edge did the checking, so the credentials should stop at the edge. A VirtualServer route can use a `proxy` action instead of `pass`, and the `proxy` action can set request headers on the way to the upstream, including setting `Authorization` to empty. That's part of the sprint lab.
</details>

**A missing Policy.** Delete the connection limit and look at both routes:
```bash
# host, lab/
kubectl -n transit delete policy two-at-a-time
sleep 2
kubectl -n transit get vs transit
tc /arrivals/x; tc /
kubectl apply -f work/day2-policies.yaml
```
`Warning`, `/arrivals` answers `500`, `/` still `200`. A route whose Policy is missing fails closed, and the rest of the host carries on.

### Activity 3.7: Follow the Private Key (8 min)
You created `transit-tls` from a key file on your host. Find every copy:
```bash
# host, lab/
kubectl -n transit get secret transit-tls -o yaml | head -6 | cut -c1-80
kubectl -n transit get secret transit-tls -o jsonpath='{.data.tls\.key}' | base64 -d | head -1
```
Base64 decodes straight back to the key. Next, check who is allowed to read it:
```bash
# host, lab/
kubectl auth can-i list secrets --all-namespaces --as=system:serviceaccount:nginx-ingress:nic-nginx-ingress
kubectl get clusterrole nic-nginx-ingress -o jsonpath='{range .rules[*]}{.resources}{" "}{.verbs}{"\n"}{end}' | grep secrets
```
The controller's ServiceAccount (`--as` impersonates it) can list Secrets in every namespace, through a ClusterRole. Now inside the controller pod (`kubectl exec` runs `ls` in the controller's container), and then on the node's disk (`docker exec` runs `find` inside the `s8-control-plane` node container):
```bash
# host, lab/
kubectl -n nginx-ingress exec deploy/nic-nginx-ingress-controller -- ls -l /etc/nginx/secrets
docker exec s8-control-plane sh -c 'find /var/lib/containerd -name "ssl_keypair_transit_transit-tls.pem"'
```
Last, etcd itself. This runs `etcdctl` inside the etcd pod, with etcd's own client certificate:
```bash
# host, lab/
kubectl -n kube-system exec etcd-s8-control-plane -- etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/transit/transit-tls | grep -a 'PRIVATE KEY'
docker exec s8-control-plane grep -c encryption-provider-config /etc/kubernetes/manifests/kube-apiserver.yaml
```

<details>
<summary>List every place this private key now exists, and who can read each one.</summary>

1. `lab/certs/transit.key` on the host: root (it's mode 600 in a 700 directory).
2. **etcd**, in plain text: `BEGIN PRIVATE KEY` is readable in the raw record, because the API server has no `--encryption-provider-config` (the count is `0`). Anyone with etcd's client certificate, or a copy of etcd's data or its backups, has it.
3. **The Secret through the API**: anyone with `get secrets` in `transit`, plus the controller's ServiceAccount, which has it cluster-wide.
4. **The controller pod**: `/etc/nginx/secrets/ssl_keypair_transit_transit-tls.pem`, mode 600, owned by `nginx`. Anyone who can `kubectl exec` into the controller can read it.
5. **The node's disk**: the same file inside containerd's snapshot directory, readable by root on the node and by anything that backs up the node's disk.

The basic-auth file is in the same directory with mode `644`. The production list in concept 1.5 is about shrinking each of these: a key source that isn't a person, encrypted etcd, narrow RBAC, encrypted nodes, few `exec` rights.
</details>

---

## 4. Day 2 Concept Examination (10-Question Randomized Quiz)

```bash
# host, any directory (a second terminal)
cd /srv/nginx-journey && python3 -m http.server 8090
```
👉 **http://&lt;lab-host&gt;:8090/quiz.html?sprint=8&day=2**

Leave the cluster up for Day 3, or `./lab.sh down` (from `lab/`). Day 3 starts with `./lab.sh reset` or `./lab.sh up`.

---

## 5. Key Takeaways for Day 2
* **Annotations are strings that only one controller reads.** Ingress-NGINX's `nginx.ingress.kubernetes.io/*` keys are silently ignored by F5's controller, so "applied" says nothing about behavior.
* **Translate deliberately:** `path-regex` + `rewrite-target`, `limit-req-*` with an explicit burst and delay, an `accessControl` Policy for allow-lists, VirtualServer splits for canaries. Snippets are refused unless the controller enables them.
* **VirtualServer fields are typed and validated twice:** the schema at `apply`, then the controller's STATE and events. `Invalid` removes the host's configuration. It doesn't keep the last good one.
* **VirtualServerRoute delegates a path to another namespace.** It needs the VirtualServer's `route:` reference, and one bad subroute ignores the whole route object.
* **Policies fail closed:** a missing Policy makes its route answer 500, and a rate-limit Policy on an Ingress breaks the whole host.
* **A TLS Secret is base64, not encryption.** Without etcd encryption the key is plain text in etcd, readable by the controller in every namespace, and written to the node's disk.

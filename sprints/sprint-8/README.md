# Sprint 8: Modern Kubernetes Ingress
**Cadence:** 3 sessions, any days that week  
**Milestone:** Copperline Transit's edge on Kubernetes: one HTTPS host on F5 NGINX Ingress Controller, the fares team running their own path from their own namespace with their own rate limit, a canary of the arrivals API for testers and 10% of riders, dispatchers signed in without their password reaching the app, a 5-second answer guarantee, rolling restarts that don't fail a single request, and a half-broken pod that riders never notice  
**Shape:** 3 days, then an optional NGINX Plus side quest (the same controller with NGINX Plus).

> **Which NGINX ingress?** Everything here runs on **F5 NGINX Ingress Controller** (`github.com/nginx/kubernetes-ingress`, image `nginx/nginx-ingress`, annotations `nginx.org/*`, custom resources `k8s.nginx.org`), version 5.8.0. The community **Ingress-NGINX** (`github.com/kubernetes/ingress-nginx`) is a separate project that was retired and archived in March 2026. It's not installed anywhere in this sprint. It appears only as a manifest to migrate *from* (Day 2).

---

## 1. Sprint at a Glance

| Day | Theme | Concepts (~15–20 min) | Lab | Guide |
| :--- | :--- | :--- | :--- | :--- |
| **1** | Kubernetes networking & your first Ingress | The cluster in BIG-IP words, pod IPs and the CNI, Services as DNAT rules, EndpointSlices and readiness, NodePort and `externalTrafficPolicy`, what an ingress controller does, the two "NGINX ingress" projects | Pods that come and go, a ClusterIP that only works inside, iptables rules on a node, readiness deciding membership, installing NIC with Helm, a first Ingress and its generated config, reloads per endpoint change, prefix and client-IP edges | [`day_01.md`](day_01.md) |
| **2** | Annotations, the migration, and F5's resources | What Ingress can't say, Ingress-NGINX → NIC annotation map, snippets, `VirtualServer` / `VirtualServerRoute`, two validation layers, Policies, TLS Secrets and where the private key goes | The migration drill, translating it (and a rate-limit Policy that breaks the host), a VirtualServer with TLS, invalid vs warning, delegating `/fares`, ConnectionLimit and BasicAuth, following the key into etcd and onto the node | [`day_02.md`](day_02.md) |
| **3** | Canaries, zero-downtime updates & the sprint lab | `splits` and `matches`, the life of an endpoint, what NGINX retries (and doesn't), passive health and the half-broken pod, what a reload costs | Weighted and header/cookie canaries, a rolling restart broken and fixed step by step, the half-broken pod, a 5-second timeout that took 15, **build Copperline's edge**, `test_sprint08.sh` | [`day_03.md`](day_03.md) |
| **Side quest** | NGINX Plus | Endpoints and weights without reloads, circuit breaking from parts, JWT tiers and claim authorization | Two controllers in one cluster, reload counters side by side, active health checks and slow start, a queue instead of a 502, partner tiers from the token, dispatchers by claim | [`day_03_enterprise.md`](day_03_enterprise.md) |

---

## 2. Lab Environment

The lab is a **kind** cluster (Kubernetes in Docker) named `s8`: one control-plane node and two workers, each a Docker container. Everything is driven from `/srv/nginx-journey/sprints/sprint-8/lab` by `lab.sh`. It needs `kind`, `kubectl` and `helm` (the top README's one-time setup, step 5).

| Host port | Goes to |
| :--- | :--- |
| 8081–8097 | Earlier sprints (reserved) |
| **8098** / **8099** | F5 NGINX Ingress Controller (open source), HTTP / HTTPS: kind maps them to NodePorts 30080 / 30443 on `s8-control-plane`, where the controller runs |
| **8086** / **8087** | The NGINX Plus controller (side quest), HTTP / HTTPS (NodePorts 30086 / 30087) |
| 127.0.0.1:**8085** | The Plus API and dashboard, through `./lab.sh plus api` (a `kubectl port-forward`) |
| random 127.0.0.1 port | The Kubernetes API server (kubectl's context `kind-s8`) |

| Namespace | What's in it |
| :--- | :--- |
| `transit` | Copperline's apps: `web` (2 pods, with a readiness probe), `arrivals` v1 (3 pods: 3 s to start, no probe, exits on SIGTERM), `arrivals-v2` (1), `dispatch` (1), and a `client` pod with curl |
| `fares` | The fares team's `fares` app (2 pods) |
| `nginx-ingress` | F5 NGINX Ingress Controller 5.8.0 (Helm release `nic`, values `lab/nic-values.yaml`, IngressClass `nginx`) |
| `nginx-plus` | The side quest's Plus controller (release `nicplus`, values `lab/plus/nic-plus-values.yaml`, IngressClass `nginx-plus`) |

Every app is the same Python program (`lab/app.py`, mounted from a ConfigMap into `python:3.12-alpine`). It answers with JSON naming the app, version, pod and node, and the headers it received. It can be switched (only from inside its pod) to answer 500, or to fail its readiness check.

```bash
# host, any directory
cd /srv/nginx-journey/sprints/sprint-8/lab
./lab.sh up                  # cluster, certificates, apps, controller, then the ready check (Day 1: ./lab.sh up --no-nic)
source helpers.sh            # in every new terminal
./lab.sh reset               # between days: removes your Ingresses/VirtualServers/Policies/Secrets, restores apps and controller
./lab.sh down                # deletes the cluster
```

**Memory:** about 1.5 GB for the three nodes with the open source controller, a little more with the Plus controller.

**Generated on the first `up` (owner-only, not in git):** `lab/certs/` (the **Copperline Lab CA** and a certificate for `transit.copperline.test` and `*.copperline.test`, ECDSA P-256), `lab/secrets/htpasswd` (user `dispatcher`, password `radio-check`) and `lab/secrets/jwt.key` (the side quest's token signing key). Your own manifests go in **`lab/work/`**, which git ignores.

**`lab.sh`**
* `up [--no-nic]`, `check` (nodes, apps, pod network across nodes, controller, default server), `nic`, `reset`, `down`.
* `conf [FILE|-T]`: the controller's generated files in `/etc/nginx/conf.d/`, one file, or `nginx -T`. `reloads`: reload counters by reason (`endpoints`, `other`), from the controller's Prometheus metrics. `logs [N]`.
* `pki`, `plus up|down|api|api-stop|reloads|conf|logs`.

**`helpers.sh`** (all run on the host)
* To the open source controller: `t PATH` (HTTPS to `transit.copperline.test:8099`, body), `th` (headers), `tc` (status code), `who N PATH`, `load SECS WORKERS PATH [curl options]`, `burst N MS`; plain HTTP to any host: `hreq HOST PATH`, `hwho N HOST PATH`.
* In the cluster: `incluster URL` (curl from the `client` pod), `pod-fail` / `pod-unready APP on|off [VERSION]`, `pod-stats APP [VERSION]`.
* The controller: `nconf`, `reloads`, `nlogs`.
* Side quest: `pt`, `ptc`, `pwho`, `burst N MS plus`, `token SUB TIER [ROLES]`, `decode`, `papi /PATH`, `preloads`.

**After the host or Docker restarts**, kind's pod network can come back broken: `./lab.sh check` reports pods unreachable from the client pod. Recreate the cluster with `./lab.sh down && ./lab.sh up`.

> **Version notes (verified with F5 NGINX Ingress Controller 5.8.0, Helm chart 2.9.0, nginx 1.31.9; NGINX Plus R37.3 / nginx 1.31.8; Kubernetes 1.37.0 on kind 0.33.0):**
> * The controller's upstreams list **pod IPs** from EndpointSlices (no ClusterIP, no kube-proxy), with `random two least_conn` and `max_fails=1 fail_timeout=10s` by default, and `proxy_next_upstream error timeout` with **unlimited tries**.
> * A `Prefix` path `/arrivals` becomes `location "/arrivals"`, which also matches `/arrivalsboard`.
> * An **Invalid** VirtualServer removes the host's configuration; it doesn't keep the last good one.
> * A resource without `ingressClassName` is configured by **every** F5 controller in the cluster.
> * `slow-start` is disabled (with a `Warning`) under the default `random two least_conn`.

---

## 3. Daily Detail

### Day 1: Kubernetes Networking for a BIG-IP Engineer
**Concepts:**
* Cluster, node, pod, Deployment, labels, namespaces, manifests; declarative reconciliation.
* Pod IPs from per-node ranges, the CNI, no NAT between pods.
* Services: ClusterIP as DNAT rules on every node; EndpointSlices; readiness probes.
* NodePort, LoadBalancer, `externalTrafficPolicy`.
* What an ingress controller is; F5 NGINX Ingress Controller vs the retired Ingress-NGINX.

**Lab:**
* Nodes as containers, pod ranges, a deleted pod replaced.
* A ClusterIP from the host (timeout) and from a pod; the iptables rules in a node.
* An unready web pod leaves the EndpointSlice; arrivals, with no probe, can't.
* Install NIC 5.8 with Helm; IngressClass, CRDs, the default server.
* A first Ingress; the generated upstream of pod IPs; reloads on scaling.
* `/arrivalsboard`, the client's address, and `externalTrafficPolicy: Local` on nodes without the controller.

### Day 2: Annotations, the Migration, and F5's Custom Resources
**Concepts:**
* The Ingress schema's limits; annotations as strings.
* The Ingress-NGINX → NIC annotation map; why snippets are off.
* `VirtualServer`, `VirtualServerRoute`, `Policy`; schema vs controller validation; STATE.
* TLS Secrets: base64, etcd, RBAC, the controller's copy on the node's disk; production practice.

**Lab:**
* An Ingress-NGINX manifest applied unchanged: nothing it meant happens.
* The translation: `path-regex`, `rewrite-target`, `limit-req-*` (and the burst that queued), an `accessControl` Policy, and a `rateLimit` Policy that sets the whole host to 500.
* A VirtualServer with TLS and redirect; refused, invalid and warning versions of it.
* Delegating `/fares` to the fares team, and a subroute outside it.
* ConnectionLimit (new in 5.8), BasicAuth, a missing Policy.
* Every copy of the private key.

### Day 3: Canaries, Zero-Downtime Endpoint Updates & the Sprint Lab
**Concepts:**
* `splits` (`split_clients $request_id`) and `matches` (maps, first match wins).
* The life of an endpoint: readiness, termination, `preStop`, grace period.
* What NGINX retries; non-idempotent requests; timeouts × pods.
* `max-fails`, `fail-timeout` and `http_500`: the half-broken pod.
* Reloads and long-lived connections.

**Lab:**
* A weighted canary that doesn't stick; header and cookie canaries.
* A rolling restart under POSTs: no protection, a readiness probe, then `preStop`.
* A pod that answers 500 but stays ready.
* A 5-second `read-timeout` that took 15.
* Then build Copperline's edge (Section 4) and pass `test_sprint08.sh`.

---

## 4. Lab Specification: Copperline Transit's Edge

Start from a reset lab, copy `lab/starter/` to `lab/work/sprint/`, and apply it (`kubectl apply -f work/sprint/`). The starter is a VirtualServer `transit` for `transit.copperline.test` with no routes, and a copy of the arrivals v1 Deployment. Add files and objects as you need them. Secrets and the controller setting in requirement 10 are made with commands (`kubectl create secret`, `helm upgrade`), not files in `work/sprint/`.

**Requirements:**
1. **HTTPS with Copperline's certificate.** `transit.copperline.test` is served over HTTPS with the certificate and key in `lab/certs/transit.crt` / `transit.key`, stored in a Secret named `transit-tls` in namespace `transit`. Plain HTTP requests get a `301` to HTTPS.
2. **One VirtualServer.** The host is served by a VirtualServer named `transit` in namespace `transit` that names its ingress class (`nginx`) explicitly and is `Valid`. `/` goes to `web`, `/arrivals` to the arrivals API, and `/dispatch` to `dispatch`.
3. **The fares team's path.** `/fares` is defined by the fares team: a VirtualServerRoute in namespace `fares`, delegated from the `transit` VirtualServer, reaching the `fares` service.
4. **Fares rate limit.** Each client may make 5 requests per second to `/fares`, plus a burst of up to 10 that is served without delay; requests beyond that get `429`. Other paths aren't limited.
5. **The arrivals canary.** Requests with the header `X-Canary: always`, or the cookie `canary=always`, always go to arrivals v2 (`arrivals-v2` service). Other requests to `/arrivals` go to v2 about 10% of the time and to v1 (`arrivals` service) otherwise.
6. **Dispatch sign-in.** `/dispatch` requires HTTP Basic sign-in with the users in `lab/secrets/htpasswd` (`dispatcher` / `radio-check`); anything else gets `401`. The dispatch app never receives the credentials (no `Authorization` header).
7. **Five seconds.** NGINX waits at most 5 seconds for either arrivals version to answer, and the client has its `504` within about 5 seconds.
8. **Zero-downtime restarts.** A rolling restart of `arrivals-v1` under steady traffic, including POSTs, doesn't fail a single request.
9. **A half-broken pod.** When one arrivals v1 pod answers `500` to every request (while its readiness check still passes), clients' GET requests to `/arrivals` still get `200`, and that pod is left alone for at least 30 seconds.
10. **No version on display.** The `Server` header says `nginx` without a version, for every host the controller serves.

`lab/solution/` is the reference; `lab/solution/apply.sh` applies it to a reset lab.

---

## 5. Automated Test Suite (`test_sprint08.sh`)

```bash
# host
cd /srv/nginx-journey/sprints/sprint-8 && ./test_sprint08.sh
```
* It runs `lab/lab.sh check` first. If the lab isn't ready, it stops with a setup message and tests nothing.
* It takes about 70 seconds: test 8 does a real rolling restart of `arrivals-v1` under load, and test 9 makes one arrivals pod fail, waits 15 seconds, then repairs the pod.
* Run against the untouched starter, it reports 0/10 and **`Sprint 8 start is ready to go`**. HTTPS checks show status `000` there: without a certificate, the controller refuses the TLS handshake.
* Override `HTTP_PORT` / `HTTPS_PORT` to point it elsewhere. It uses the kubectl context `kind-s8`.

| # | Assertion (gate: 10/10) | Requirement |
| :--- | :--- | :---: |
| 1 | Secret `transit/transit-tls` is `kubernetes.io/tls`; the certificate served on 8099 is `lab/certs/transit.crt`; HTTP on 8098 answers `301` to `https://transit.copperline.test...` | 1 |
| 2 | VirtualServer `transit/transit` has `ingressClassName: nginx` and is `Valid`; `/` → web, `/arrivals` → arrivals, `/dispatch` (signed in) → dispatch | 2 |
| 3 | `/fares` → the fares app; a `Valid` VirtualServerRoute for the host in `fares`; the VirtualServer has a `/fares` route to `fares/...` | 3 |
| 4 | 30 quick `/fares` requests: 10–20 × `200`, at least 8 × `429`, nothing else, in under 1.5 s; 30 quick `/arrivals` requests: no `429`; `/fares` answers `200` again 3 s later | 4 |
| 5 | `X-Canary: always` → v2 10/10; cookie `canary=always` → v2 10/10; 200 plain requests: 6–40 to v2, the rest to v1 | 5 |
| 6 | `/dispatch`: `401` without credentials and with a wrong password; `dispatcher` / `radio-check` gets the dispatch app, which received no `Authorization` header | 6 |
| 7 | `/arrivals/slow?ms=9000` answers `504` after 4.5–7.5 s, for v1 and for v2 (`X-Canary: always`) | 7 |
| 8 | Three loops of slow POSTs to `/arrivals` during `kubectl rollout restart deploy/arrivals-v1`: every response `200` (at least 30), and the pods were replaced | 8 |
| 9 | One ready arrivals v1 pod switched to answer 500: 30 GETs, a 15 s pause, 30 more GETs, all `200`; the failing pod received at most 1 of them | 9 |
| 10 | `Server: nginx` (no version) on `transit.copperline.test` and on the default server | 10 |

---

## 6. Daily Quizzes

All pools live in [`data/quizzes.json`](../../data/quizzes.json). Each day has 20 questions (8 scenario, 6 config, 3 diagnose, 3 recall). The quiz draws 10, and 8/10 passes.

* **Day 1:** pods and their IPs, ClusterIP and kube-proxy, EndpointSlices and readiness, NodePort and `externalTrafficPolicy`, the controller's architecture and defaults, IngressClass and the two projects.
* **Day 2:** annotations, the Ingress-NGINX migration, snippets, VirtualServer/VirtualServerRoute, validation and STATE, Policies, TLS Secrets and key storage.
* **Day 3:** splits and matches, readiness and `preStop`, retries and non-idempotent requests, `max-fails` and `http_500`, timeouts and retries, reloads.
* **Enterprise:** endpoints and weights without reloads, active health checks, `mandatory`/`persistent`, `slow-start`, queues, JWT tiers, claim authorization, two controllers in one cluster.

```bash
# host
cd /srv/nginx-journey && python3 -m http.server 8090
# http://<lab-host>:8090/quiz.html?sprint=8&day=1   (day=2, day=3, and day=3&pool=enterprise)
```

---

## 7. Optional Extras

* **8.1 The keepalive trap.** Set `ANNOUNCE_CLOSE=0` on the arrivals v1 Deployment (`kubectl -n transit set env deploy/arrivals-v1 ANNOUNCE_CLOSE=0`) and run `load 20 4 /arrivals/x -H 'X-Canary: no'` against a VirtualServer without `keepalive` on that upstream. Then add `keepalive: 16` to the upstream and run it again. What's going on?

  <details>
  <summary>Answer</summary>

  With `ANNOUNCE_CLOSE=0` the app closes the connection after each response without saying `Connection: close`. The controller sends `Connection: close` upstream (its default, `keepalive` 0), but nginx 1.29.7 and later keep upstream connections alive by default, and a response without `Connection: close` looks reusable. Under load, NGINX reuses a socket the app already closed: `upstream prematurely closed connection`. With `max_fails=1` that benches the pod, and soon every pod: `no live upstreams`: a third or more of all requests answered `502` in the lab runs, with no deployment happening at all. Real servers announce the close (the app's default, `ANNOUNCE_CLOSE=1`). Setting `keepalive` on the upstream makes the controller stop sending `Connection: close`, and connections are reused properly. Details in `recap_notes.md`.
  </details>

* **8.2 `use-cluster-ip`.** What would `use-cluster-ip: true` on an upstream change, and when would you want it?

  <details>
  <summary>Answer</summary>

  NGINX would send to the Service's ClusterIP instead of the pod IPs, so kube-proxy picks the pod (random, per connection). The controller's load-balancing method, `max-fails`, `next-upstream` retries to another pod, and endpoint reloads stop mattering, because NGINX sees one server. You'd want it when something else must own pod selection (a service mesh's sidecar policy, for instance) or to avoid reloads in a very busy open source cluster. The price is the L7 behavior this sprint relied on.
  </details>

* **8.3 cert-manager.** Day 2's key was made by `lab.sh` and typed into a Secret by you. How would cert-manager change that, and what wouldn't it change?

  <details>
  <summary>Answer</summary>

  cert-manager generates the key inside the cluster, gets the certificate signed (ACME or an internal CA issuer), writes the Secret, and renews it before it expires, so no person handles the key and expiry stops being a calendar task (F5 NGINX Ingress Controller can request certificates for a VirtualServer's `tls.cert-manager` fields). It doesn't change where the key ends up: still a Secret in etcd, readable by the controller cluster-wide, and a PEM file on the node. Encryption at rest, RBAC and node hardening still apply.
  </details>

* **8.4 Two controllers, one IngressClass name.** A cluster that still runs the retired Ingress-NGINX (class `nginx`) gets F5 NGINX Ingress Controller installed with the chart's defaults. What breaks, and how do you migrate one application at a time?

  <details>
  <summary>Answer</summary>

  Both default to an IngressClass named `nginx`, and the second install collides with the first (the chart can't create a class that exists, or someone overwrites it, changing its `controller` field). Install F5's controller with a different class name (`controller.ingressClass.name`, for example `nginx-f5`), then move applications one at a time by changing their `ingressClassName` and translating their annotations, testing behavior each time. Expose the new controller on its own address so DNS can move per host.
  </details>

---

## 8. Tracker Sync

* **Platform milestone:** Copperline Transit's edge runs on F5 NGINX Ingress Controller: HTTPS for one host with a properly handled key, a delegated and rate-limited path for the fares team, a header/cookie/weight canary for arrivals, dispatch behind sign-in without leaking credentials, a bounded response time, rolling restarts without a failed request, and a broken pod kept away from riders.
* **Graduation:** `test_sprint08.sh` 10/10, and at least 80% on each day's quiz.

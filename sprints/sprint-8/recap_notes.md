# Sprint 8 Recap Notes (working file)
Raw findings and clarifications collected during the sprint, to be shaped into the recap. Everything here was verified on F5 NGINX Ingress Controller 5.8.0 (Helm chart 2.9.0, nginx 1.31.9), the Plus build of 5.8.0 (NGINX Plus R37.3, nginx 1.31.8), Kubernetes 1.37.0 on kind 0.33.0 (3 nodes, kindnet, kube-proxy in iptables mode), unless marked otherwise.

---

## Findings From Building the Sprint

### The two "NGINX ingress" projects
* **Community Ingress-NGINX** (`kubernetes/ingress-nginx`): retirement announced 11 Nov 2025, repository archived 24 Mar 2026, final release v1.15.1 (19 Mar 2026). No fixes after that, security fixes included.
* **F5 NGINX Ingress Controller** (`nginx/kubernetes-ingress`): 5.7.0 (14 Oct 2026), 5.7.1 (5 Nov), **5.8.0 (18 Nov 2026)**; an LTS line since June 2026. 5.8 added the ConnectionLimit Policy, ExternalAuth auth response headers, JWT claim authorization (Plus), variables in `nginx.org/proxy-set-headers`, a 2-second reload batch window (`-batch-reload-window`), and fewer Plus reloads.
* Both default to an IngressClass **named `nginx`**. The difference is `spec.controller`: `nginx.org/ingress-controller` vs `k8s.io/ingress-nginx`.

### The controller's generated configuration (Day 1)
* Ingress → `/etc/nginx/conf.d/<namespace>-<name>.conf`; VirtualServer → `vs_<namespace>_<name>.conf`. The image has no `curl`, `wget` or `ps`.
* **Upstreams are pod IPs** from EndpointSlices (no ClusterIP, no kube-proxy). Defaults: `random two least_conn`, `max_fails=1 fail_timeout=10s max_conns=0`, `zone ... 256k`, `server_tokens on`, `proxy_next_upstream error timeout` with `proxy_next_upstream_tries 0` and `_timeout 0s` (unlimited).
* `Prefix` `/arrivals` → `location "/arrivals"`: **`/arrivalsboard` matches too**, although the Kubernetes spec defines Prefix element-wise.
* **Reloads, measured:** scaling arrivals 3 → 5 = 2 endpoint reloads, 5 → 3 = 4; one rolling restart of 3 pods ≈ 9–13. The metric is `nginx_ingress_controller_nginx_reloads_total{reason="endpoints"|"other"}` on :9113, readable without a port-forward through the API server proxy (`kubectl get --raw /api/v1/namespaces/nginx-ingress/pods/<pod>:9113/proxy/metrics`).
* `externalTrafficPolicy: Cluster` → the app's `X-Real-IP` is `10.244.0.1` (SNAT). `Local` → `172.19.0.1` (the Docker network gateway = the host), but the NodePort on worker nodes (no controller pod) times out.
* kube-proxy's rules for a 3-pod Service: `statistic --mode random --probability 0.33333333349`, then `0.5`, then the rest.
* A pod without a readiness probe is `1/1 Ready` while its app is still sleeping through its start; `pod-unready` on arrivals changed nothing in the EndpointSlice.

### Annotations and the migration (Day 2)
* **The Ingress-NGINX manifest applied cleanly** (`Normal AddedOrUpdated`, no warning). Every `nginx.ingress.kubernetes.io/*` key was ignored: the regex path became a literal prefix location (`/api/next` → 404, only `/api(/|$)(.*)` literally reached the app), no allow-list (200 from outside `192.0.2.0/24`), no rate limit, `proxy_read_timeout 60s`, no snippet.
* Translation that worked: `nginx.org/path-regex: case_sensitive` + `nginx.org/rewrite-target: /$2` (→ `location ~ "^/api(/|$)(.*)"` + `rewrite ... break`), `nginx.org/proxy-read-timeout: 5s`, `nginx.org/limit-req-rate/-key/-burst/-reject-code`, and an `accessControl` Policy via `nginx.org/policies` (403).
* `limit-req-burst: 10` without `nginx.org/limit-req-no-delay: "true"` queued everything: 16 quick requests all `200`. With no-delay: 11 × `200`, then `429`. The annotation names came from the controller binary: `limit-req-rate`, `-key`, `-burst`, `-delay`, `-no-delay`, `-dry-run`, `-log-level`, `-reject-code`, `-scale`, `-zone-size`.
* **A `rateLimit` Policy on an Ingress:** `Warning ... Policy transit/legacy-rate is not supported on Ingress resources`, and `return 500;` at the top of the **server** block: the whole host fails.
* **Snippet annotations with snippets disabled are rejected**, not ignored: `annotations.nginx.org/location-snippets: Forbidden: snippet specified but snippets feature is not enabled` (the Ingress isn't applied; its host 404s).

### VirtualServer, VirtualServerRoute, Policy (Day 2)
* Schema errors are refused by the API server: `spec.upstreams[0].port in body must be of type integer`, `strict decoding error: unknown field "spec.routes[0].colour"`.
* **Invalid** (`spec.routes[2].action.pass: Not found: "dispatcher"`) **removes the host's configuration**: HTTPS fails at the handshake (curl `000`), HTTP gets the default server's 404. It doesn't keep the last good version.
* Missing TLS Secret → `Warning` (`TLS secret transit-tls-2027 is invalid: secret ... doesn't exist`) and `ssl_reject_handshake on` for that host (curl exit 35, `unrecognized name`), while HTTP still 301s to the dead HTTPS.
* Missing Policy → `Warning`, that route `500`, the other routes fine. Policies are copied into every internal split location.
* An Ingress and a VirtualServer for the same host: the newer one is `Rejected`, `Host is taken by another resource`.
* VirtualServerRoute without the VirtualServer's `route:` → `Warning`, `VirtualServer transit/transit ignores VirtualServerRoute`. A subroute outside the delegated path (`/admin` under `/fares`) → `must start with '/fares'` and **the whole VSR is ignored**: `/fares/zones` fell through to the parent's `/` route (web).
* ConnectionLimit (5.8): 5 parallel 1.5 s requests with `connections: 2` → 2 × 200, 3 × 429.
* BasicAuth forwards the `Authorization` header to the app (`Basic ZGlzcGF0Y2hlcjpyYWRpby1jaGVjaw==`); `action.proxy.requestHeaders.set` with `Authorization: ""` removes it.
* `tls.redirect` builds `https://$host$request_uri`: in the lab it drops `:8099`.

### Where the private key goes (Day 2)
* The Secret is base64. **etcd held it in plain text**: `etcdctl get /registry/secrets/transit/transit-tls` showed `BEGIN PRIVATE KEY`, and the API server has no `--encryption-provider-config`.
* The controller's ClusterRole: `configmaps, namespaces, pods, secrets: get, list, watch`. `kubectl auth can-i list secrets --all-namespaces --as=system:serviceaccount:nginx-ingress:nic-nginx-ingress` → yes. `controller.watchSecretNamespace` renders an extra namespaced Role, but the ClusterRole keeps `secrets`.
* `/etc/nginx/secrets/ssl_keypair_transit_transit-tls.pem` (certificate + key, one file) is 0600 `nginx:nginx` (uid 101, the same user as the controller and workers); `basic_auth_transit_dispatch-users` is **0644**. The PEM is on the node's disk under `/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/<n>/fs/etc/nginx/secrets/`. With `readOnlyRootFilesystem: true` the chart mounts emptyDirs (disk, no `medium: Memory`).
* Production notes are in Day 2 concept 1.5 (KMS encryption at rest, RBAC, issuance without humans, encrypted nodes). They connect to Sprint 3's A.5 findings and come back in Sprints 11 and 14.

### Rollouts and retries (Day 3)
* **Rolling restart of 3 arrivals pods (3 s start, exits on SIGTERM) under 3 loops of 200 ms POSTs:** no probes ≈ 488 × 502 of ~1000; readiness probe only: GETs clean (retried), POSTs 2–5 × 502; readiness + `preStop` sleep 5: **0 errors** (628/628, 321/321 in the test). Each run with readiness only also had one request with no answer within 5 s: in flight when its pod's network disappeared, so no reset, and NGINX waits up to `proxy_read_timeout` (60 s).
* **`read-timeout: 5s` → 504 after 15 s** (three `upstream timed out` lines): unlimited `next-upstream` tries, `timeout` included. `next-upstream-tries: 2` + `next-upstream-timeout: 5s` → 5.0 s.
* Half-broken pod (500 on everything but `/healthz`): 8 × 500 in 30 requests with defaults; with `next-upstream: "error timeout http_500"`, `max-fails: 1`, `fail-timeout: 30s` → 60/60 × 200, the pod received 1 request (the first, retried).
* `max-conns: 2` on open source, 12 parallel 1 s requests over 3 pods → 6 × 200, 6 × 502 at once (`no live upstreams`).

### The keepalive trap (found while building; Extra 8.1)
* The first version of the demo app (Python `http.server`, HTTP/1.1) gave **~35–58% `502`s at steady state**, no deployment involved. Errors: a few `upstream prematurely closed connection while reading response header`, then hundreds of `no live upstreams`.
* Cause: since nginx 1.29.7, `keepalive` is on in upstream blocks by default (Sprint 7 recap). The controller still sets `Connection: close` upstream when an upstream has no `keepalive`. Python closes after a `Connection: close` request **without saying so in its response**, so NGINX treats the connection as reusable and parks it. Under load the next request grabs the socket before the FIN is processed → "prematurely closed" → `max_fails=1` benches the pod for 10 s → soon all pods → "no live upstreams". Evidence: with a silent close, the controller held no sockets afterwards (the app closed first); with the app announcing `Connection: close`, NGINX closed first (6 sockets in TIME_WAIT on the controller side for 6 requests).
* Fixes, each measured clean: the app sends `Connection: close` (the lab app's default, `ANNOUNCE_CLOSE=1`), or `keepalive: 16` on the upstream (the controller then drops the `Connection: close`: 1043/1043).
* RFC 9112 §9.6: a client that sends `close` must not send further requests on that connection. A reverse proxy that both sets `Connection: close` and keeps the connection is arguably wrong; worth raising with the NIC team.
* Also on the way: Python's `ThreadingHTTPServer` listen backlog is 5 by default (raised to 512 in the app).

### NGINX Plus controller (side quest)
* Install: Secrets `nplus-license` (generic, `license.jwt`) and `regcred` (docker-registry, the JWT as username), values `nginxplus: true`, image `private-registry.nginx.com/nginx-ic/nginx-plus-ingress:5.8.0`. Ready in about 9 s. Log: `license accepted from "/etc/nginx/secrets/license.jwt"; expires in 15 days; reporting exempt`.
* **Both controllers configure resources without `ingressClassName`** (a throwaway `noclass` VirtualServer showed up in both `conf.d` directories).
* Scaling 3 → 5 → 3: open source +7 to +8 endpoint reloads, Plus **0**, while its API peer list followed the pods. Changing split weights: open source +1 reload, Plus 0. Plus pre-generates **101** `split_clients` blocks (`..._0_100` to `..._100_0`) and selects one with a keyval (`..._50_50`).
* `slow-start` with the default `random two least_conn` → `Warning: Slow start will be disabled for upstream arrivals-v1 because lb method 'random two least_conn' is incompatible with slow start`.
* Health check on `/arrivals/health` (interval 1 s, fails 1, passes 2, `mandatory`, `persistent`): the half-broken pod was `unhealthy` within 2 s and got **0 user requests** (the API's `requests` counter stayed put) while Kubernetes showed it `1/1 Ready`. After repair: `up` after two passes, then slow start: 2, 4, 7 of each ~36 requests in three windows 6 s apart.
* `max-conns: 2` + `queue {size: 10, timeout: 3s}`: 12 parallel 1 s requests → 12 × 200 (slowest 2 s); 30 parallel 2 s requests → 15 × 200, 15 × 502 (11 `upstream queue is full`, 4 `upstream queue timeout`); the API counts `overflows: 11`.
* JWT tiers: gold (10 r/s, burst 20, no delay) 23/25 × 200; free (1 r/s, burst 2) 3/25. A free token edited to say `gold` → 401 (signature).
* JWT claim authorization (5.8): no token 401, `roles: [rider]` 403, `roles: [dispatcher, staff]` 200 with `X-User: alice` overwriting a spoofed `X-User: mallory`. It compiles to `auth_jwt_claim_set`, chained `map`s, and `auth_jwt_require ... error=403`.

### Lab mechanics
* `kind load docker-image` failed on Docker 29 (`ctr: content digest ... not found`); the nodes pull images from Docker Hub instead.
* With all nodes not yet Ready, the first apply put every pod on one worker; `lab.sh up` now waits for all three.
* After the host restarted, the cluster came back but some pods on one worker were unreachable from the other (routes looked right; restarting kindnet fixed part of it). `lab.sh check` now tests every app pod from the client pod; the fix is `./lab.sh down && ./lab.sh up`.

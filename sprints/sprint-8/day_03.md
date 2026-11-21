# Sprint 8 &bull; Day 3: Canaries, Zero-Downtime Endpoint Updates & the Sprint Lab
**Day:** 3 of 3  
**Estimated Time:** 100 Minutes (15 concepts, 5 setup, 40 activities, 30 sprint lab, 10 quiz)  
**Theme:** On BIG-IP, a deployment is something the operator does to a pool: disable a member, let connections drain, swap it, enable it. In Kubernetes nobody asks the load balancer. Pods are replaced on their own schedule, and the ingress controller finds out after the fact. Whether users notice depends on timing that the application's manifest controls: when a new pod is declared ready, how long an old one keeps serving after it's told to stop, and what NGINX retries in between. Today you split traffic between two versions of Copperline's arrivals API, then break a rolling restart on purpose and fix it until not one request fails. Then you build the whole Copperline edge from the starter.

---

## 1. Concepts to Understand (15 Minutes)

### 1.1 Splits and Matches
A VirtualServer route can carry, instead of one `action`:
* **`splits`**: weighted actions (`weight` 0–100, summing to 100). The controller generates `split_clients $request_id`, so the choice is **random per request**. The same user can get v1, then v2, then v1.
* **`matches`**: a list of `conditions` (`header`, `cookie`, `argument`, or `variable`, compared with a `value`) and the action or splits for requests that meet them. Conditions inside one match must **all** hold. **The first match in the list wins**, and requests that match nothing fall back to the route's own `action` or `splits`. The controller generates `map` blocks for them (Sprint 2's `map`).

A canary that sticks to a user is a match on something the user carries (a cookie or a header), not a weight. Ingress-NGINX's canary annotations checked header, then cookie, then weight, and a migrated route should keep that order in `matches`.

### 1.2 The Life of an Endpoint
**A pod starting:** container starts → readiness probe passes (or, with no probe, immediately) → EndpointSlice marks it ready → the controller sees the change → after the batch window (up to 2 s), new config and **a reload** (open source) → NGINX sends it traffic.

**A pod stopping** has two things happening **at the same time**:
* **The kubelet** runs the container's `preStop` hook, if there is one, then sends **SIGTERM**. After `terminationGracePeriodSeconds` (default 30 s), it sends SIGKILL.
* **The control plane** marks the endpoint terminating (not ready), and the controller removes it from the upstream and reloads.

If the application exits on SIGTERM before NGINX has reloaded without it, NGINX is still sending requests to a dead address. The fixes:

| Gap | Fix |
| :--- | :--- |
| New pod gets traffic before it listens | A **readiness probe** |
| Old pod exits before NGINX stops using it | A **`preStop` sleep** (a few seconds longer than the controller needs to reload), and an app that finishes in-flight requests on SIGTERM |
| Grace period too short for both | `terminationGracePeriodSeconds` > preStop + drain |

### 1.3 What NGINX Retries, and What It Can't
The controller's default is `proxy_next_upstream error timeout` with **no limit on tries**:
* **A connection refused, or a timeout, is retried on another pod**, silently. That hides a lot of rollout damage for GETs.
* **A non-idempotent request (POST, PATCH...) is not retried** once it was sent (NGINX's rule, `non_idempotent` not set). POSTs show the failures that GETs hide.
* **A timeout is retried on every pod in turn.** `read-timeout: 5s` with three pods can take 15 s before the client gets its 504. Bound it with `next-upstream-tries` or `next-upstream-timeout`.
* **An HTTP 500 is passed to the client** unless `http_500` is in `next-upstream`.

### 1.4 Passive Health: max_fails, and the Half-Broken Pod
`max-fails` and `fail-timeout` (default 1 and 10 s) take a pod out of rotation after failed attempts, but only for what `next-upstream` counts as failure. A pod whose readiness probe passes but whose real requests fail with 500 is **half-broken**: Kubernetes keeps it in the EndpointSlice, and NGINX keeps sending it requests. Adding `http_500` to `next-upstream` makes NGINX retry the request on another pod *and* count the failure, so the pod is benched for `fail-timeout`, then tried again with one real request. That's a passive circuit breaker, built from real traffic. NGINX Plus adds active health checks (the side quest).

### 1.5 What a Reload Costs
Each reload starts new worker processes with the new configuration. The old workers stop accepting, finish their requests, and exit. Long-lived connections (WebSockets, streaming) keep old workers alive until they close, or until the ConfigMap's `worker-shutdown-timeout` cuts them. In open source NGINX every endpoint change is a reload, and a rolling restart of three pods is a dozen or more. NGINX Plus updates upstream servers through its API instead.

### 1.6 BIG-IP Lens

| Need | BIG-IP | Kubernetes + F5 NGINX Ingress Controller |
| :--- | :--- | :--- |
| Take a member out gracefully | Disable (persistent and active connections continue) or force offline | Pod terminating → endpoint not ready → controller reload. The `preStop` sleep is the drain time. |
| New member gets traffic only when healthy | Monitor must pass first; slow ramp time | Readiness probe; slow start needs NGINX Plus (side quest) |
| Retry a failed request on another member | Not by default: an iRule (`LB::reselect`, `HTTP::retry`), or Action On Service Down = Reselect for connections | `next-upstream` (connection errors and timeouts by default; 5xx only if listed) |
| Weighted canary | Ratio on pools via an LTM policy or iRule | `splits` |
| Canary by header or cookie | LTM policy rule or iRule `HTTP::header` / `HTTP::cookie` → `pool` | `matches` |

---

## 2. Lab Setup (5 Minutes)

```bash
# host, any directory
cd /srv/nginx-journey/sprints/sprint-8/lab
./lab.sh reset      # if the cluster is up from Day 2: removes your VirtualServers, Policies and Secrets, restores the apps
./lab.sh up         # if you ran ./lab.sh down
source helpers.sh
kubectl -n transit create secret tls transit-tls --cert=certs/transit.crt --key=certs/transit.key
```
As before, every block runs on the **host in `lab/`**, and files go in **`lab/work/`**. `reset` deletes Secrets, which is why the TLS Secret is created again.

Two new helpers: `load SECONDS WORKERS PATH [curl options]` sends requests over HTTPS from several loops at once and counts the status codes (`curl-exit-28` means no answer within 5 s). `pod-fail` / `pod-stats APP on|off [VERSION]` switch and read one pod of an app.

---

## 3. Hands-on Guided Discovery Activities (40 Minutes)

### Activity 3.1: A Weighted Canary (5 min)
```yaml
# file: lab/work/day3-vs.yaml
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
  upstreams:
  - name: web
    service: web
    port: 80
  - name: arrivals-v1
    service: arrivals                  # the Service that selects version v1
    port: 80
  - name: arrivals-v2
    service: arrivals-v2
    port: 80
  routes:
  - path: /
    action:
      pass: web
  - path: /arrivals
    splits:
    - weight: 80
      action:
        pass: arrivals-v1
    - weight: 20
      action:
        pass: arrivals-v2
```
```bash
# host, lab/
kubectl apply -f work/day3-vs.yaml
who 100 /arrivals/next | awk '{n[$2]+=$1} END {for (v in n) print n[v], v}'
nconf vs_transit_transit.conf | grep -A3 split_clients
for i in $(seq 10); do t /arrivals/next -H 'Cookie: session=alice' | jq -r .version; done | tr '\n' ' '; echo
```
Roughly 80/20. Alice, sending the same cookie every time, still gets a mix.

<details>
<summary>Why doesn't alice stay on one version, and what would make her?</summary>

The split is `split_clients $request_id`, and `$request_id` is random for every request. Nothing about alice goes into the choice. To keep a user on one version, route on something the user carries: a `matches` condition on a cookie (next activity). The application or a first response can set that cookie. Or split on a different key with your own `split_clients`, which needs snippets.
</details>

### Activity 3.2: Canary by Header and by Cookie (5 min)
Testers send `X-Canary: always`. Beta users carry the cookie `canary=always`. In **`lab/work/day3-vs.yaml`**, replace the whole `/arrivals` route with:
```yaml
  - path: /arrivals
    matches:
    - conditions:
      - header: X-Canary
        value: always
      action:
        pass: arrivals-v2
    - conditions:
      - cookie: canary
        value: always
      action:
        pass: arrivals-v2
    splits:
    - weight: 80
      action:
        pass: arrivals-v1
    - weight: 20
      action:
        pass: arrivals-v2
```
```bash
# host, lab/
kubectl apply -f work/day3-vs.yaml
who 10 /arrivals/next -H 'X-Canary: always' | awk '{print $1, $2}'
who 10 /arrivals/next -H 'Cookie: canary=always' | awk '{print $1, $2}'
who 10 /arrivals/next -H 'X-Canary: yes' | awk '{n[$2]+=$1} END {for (v in n) print n[v], v}'
nconf vs_transit_transit.conf | grep -E '^map|"always"'
```
Header and cookie: 10/10 on v2. `X-Canary: yes` isn't `always`, so it falls through to the 80/20 split. Each condition became a `map` from `$http_X_Canary` or `$cookie_canary`.

### Activity 3.3: A Rolling Restart With No Protection (6 min)
For the rest of the day you change the arrivals v1 Deployment, so make your own copy. `starter/arrivals-v1.yaml` is the same Deployment as in `k8s/transit.yaml` (its TODO comment is for the sprint lab; ignore it):
```bash
# host, lab/
cp starter/arrivals-v1.yaml work/day3-arrivals-v1.yaml
grep -nE 'STARTUP_DELAY|readinessProbe|preStop' work/day3-arrivals-v1.yaml
```
Only `STARTUP_DELAY: 3`: no probe and no hook, and the app exits as soon as it gets SIGTERM. Now restart it under traffic. This one block starts the restart in the background 3 seconds in (`( ... ) &`), and meanwhile sends 40 seconds of slow POSTs from 3 loops. `X-Canary: no` keeps the requests on the 80/20 split, so most of them go to v1:
```bash
# host, lab/
reloads | grep endpoints
( sleep 3; kubectl -n transit rollout restart deployment arrivals-v1 >/dev/null ) & \
load 40 3 '/arrivals/slow?ms=200' -X POST -d trip=42 -H 'X-Canary: no'; wait
reloads | grep endpoints
```
`kubectl rollout restart` replaces every pod of the Deployment, one at a time, the same way a new image version would. Expect hundreds of `502`s: close to half the requests.

<details>
<summary>Two different gaps produce those 502s. What are they?</summary>

At the front: each new pod counts as ready the moment its container starts, while the app is still sleeping through its 3-second start. NGINX connects, gets "connection refused", and after retries runs out of pods to try. At the back: each old pod exits on SIGTERM immediately, while NGINX still has it in its upstream until the controller's next reload. And POSTs aren't retried at all. The endpoint-reload counter went up by around ten for one restart.
</details>

### Activity 3.4: Add a Readiness Probe (7 min)
In **`lab/work/day3-arrivals-v1.yaml`**, inside the container (under `- name: app`), add a `readinessProbe` at the same indentation as `ports:` and `env:`. Put it right before `volumeMounts:`:
```yaml
        readinessProbe:
          httpGet:
            path: /healthz
            port: http
          periodSeconds: 1
          failureThreshold: 1
        volumeMounts:                  # already there: this line shows where the probe goes
```
```bash
# host, lab/
kubectl apply -f work/day3-arrivals-v1.yaml
kubectl -n transit rollout status deployment arrivals-v1
sleep 5
( sleep 3; kubectl -n transit rollout restart deployment arrivals-v1 >/dev/null ) & \
load 40 3 '/arrivals/slow?ms=200' -H 'X-Canary: no'; wait
sleep 5
( sleep 3; kubectl -n transit rollout restart deployment arrivals-v1 >/dev/null ) & \
load 40 3 '/arrivals/slow?ms=200' -X POST -d trip=42 -H 'X-Canary: no'; wait
```
The first run is GETs, the second POSTs. Applying the changed Deployment is itself a rolling update, so the probe is in place before the tests start.

<details>
<summary>GETs come through almost clean, but POSTs still show a few <code>502</code>s and maybe a <code>curl-exit-28</code>. Why the difference, and what's the 28?</summary>

The front gap is closed: new pods only get traffic once `/healthz` answers. The back gap is still open. When an old pod exits mid-stream, a GET that hits it is retried on another pod (`proxy_next_upstream error timeout`) and the client never knows. A POST that was already sent isn't retried, because NGINX can't know whether the app acted on it, so the client gets the 502. A `curl-exit-28` (no answer within 5 s) is a request that was in flight when its pod's network disappeared: no reset ever came back, so NGINX waits for its read timeout (60 s by default here). GET-only testing would have told you the rollout was fine.
</details>

### Activity 3.5: Add a preStop Sleep (5 min)
In **`lab/work/day3-arrivals-v1.yaml`**, add a `lifecycle` block right after the `readinessProbe` you added (same indentation, before `volumeMounts:`):
```yaml
        lifecycle:
          preStop:
            sleep:
              seconds: 5
```
```bash
# host, lab/
kubectl apply -f work/day3-arrivals-v1.yaml
kubectl -n transit rollout status deployment arrivals-v1
sleep 8
( sleep 3; kubectl -n transit rollout restart deployment arrivals-v1 >/dev/null ) & \
load 45 3 '/arrivals/slow?ms=200' -X POST -d trip=42 -H 'X-Canary: no'; wait
reloads | grep endpoints
```
Every request answers `200`.

<details>
<summary>The app still exits the instant it gets SIGTERM. Why does a 5-second sleep <em>before</em> SIGTERM fix it?</summary>

Because the kubelet runs `preStop` first and sends SIGTERM only after it finishes, while the endpoint is already marked terminating. Those 5 seconds are enough for the EndpointSlice change, the controller's batch window and the reload, so by the time the app exits NGINX has stopped sending to it. It's BIG-IP's "disable the member, wait for connections to drain, then take it down", with the wait written into the pod spec. An app that finishes its in-flight requests on SIGTERM is better still, but the sleep covers the routing delay that the app can't see. (The `sleep` action is built into Kubernetes since 1.30, so the image needs no `sleep` binary.)
</details>

### Activity 3.6: The Half-Broken Pod (6 min)
`pod-fail` makes one v1 pod answer `500` to everything except `/healthz`, so its readiness probe still passes:
```bash
# host, lab/
pod-fail arrivals on v1
kubectl -n transit get pods -l app=arrivals,version=v1
for i in $(seq 30); do tc /arrivals/x -H 'X-Canary: no'; done | sort | uniq -c
```
All pods `1/1 Ready`, and around a quarter of the answers are `500`.

<details>
<summary>Why didn't <code>max_fails=1</code> take that pod out after its first 500?</summary>

Because a 500 isn't a failure to NGINX unless `next-upstream` says so. The default `error timeout` only counts connection errors and timeouts. The pod answered, so as far as NGINX is concerned it worked. And Kubernetes sees a passing readiness probe. Nobody in the path considers the pod broken.
</details>

In **`lab/work/day3-vs.yaml`**, in the `arrivals-v1` upstream (under `port: 80`, same indentation), add:
```yaml
    next-upstream: "error timeout http_500"
    max-fails: 1
    fail-timeout: 30s
```
```bash
# host, lab/
kubectl apply -f work/day3-vs.yaml
s0=$(pod-stats arrivals v1 | jq .served)
for i in $(seq 30); do tc /arrivals/x -H 'X-Canary: no'; done | sort | uniq -c
sleep 12
for i in $(seq 30); do tc /arrivals/x -H 'X-Canary: no'; done | sort | uniq -c
echo "the failing pod received $(( $(pod-stats arrivals v1 | jq .served) - s0 )) requests"
pod-fail arrivals off v1
```
60 × `200`, and the failing pod got **one** request: the first, which failed, was retried on a healthy pod, and benched the failing pod for 30 seconds. (`pod-stats` reads the same pod that `pod-fail` switched.)

<details>
<summary>With the default <code>fail-timeout</code> of 10 s, what would the second batch (after <code>sleep 12</code>) have done?</summary>

The failing pod would have been back in rotation after 10 s, so the second batch would have sent it one more real request, which failed, got retried, and benched it again. Clients still see 200, but every `fail-timeout` the broken pod costs one request a retry and its latency. This passive breaker uses real user requests as the probe. An active health check (NGINX Plus) probes the path itself and keeps the pod out until it passes again.
</details>

### Activity 3.7: The 5-Second Timeout That Took 15 (6 min)
Copperline wants an answer from arrivals within 5 seconds. In **`lab/work/day3-vs.yaml`**, in the `arrivals-v1` upstream, add one more line below `fail-timeout: 30s`:
```yaml
    read-timeout: 5s
```
```bash
# host, lab/
kubectl apply -f work/day3-vs.yaml
time tc '/arrivals/slow?ms=9000' -H 'X-Canary: no'
nlogs 30 | grep -c 'upstream timed out'
nconf vs_transit_transit.conf | grep -E 'proxy_next_upstream_(tries|timeout)' | sort -u
```
A `504`, after **15 seconds**, and three `upstream timed out` lines.

<details>
<summary>Why 15, and which upstream fields would hold it to 5?</summary>

`timeout` is in `next-upstream` (it's in the default too), and the controller sets `proxy_next_upstream_tries 0` and `proxy_next_upstream_timeout 0s`, which mean unlimited. So the request timed out on one pod after 5 s, was retried on the second, then the third: 3 × 5 s. To hold the client to about 5 s, bound the retries with `next-upstream-tries` (`1` or `2`) and/or `next-upstream-timeout: 5s`, or drop `timeout` from `next-upstream` so only connection errors are retried. (A slow answer is rarely fixed by asking another copy of the same app.)
</details>

---

## 4. The Sprint Lab: Copperline Transit's Edge (30 Minutes)

Build Copperline's edge from the starter: the requirements are in [`README.md` section 4](README.md#4-lab-specification-copperline-transits-edge). You may reuse anything from this week's `work/` files.

**Start from a clean lab, then take the baseline.** The starter applies cleanly and every requirement fails:
```bash
# host, lab/
./lab.sh reset
rm -rf work/sprint && cp -r starter work/sprint
kubectl apply -f work/sprint/
cd .. && ./test_sprint08.sh; cd lab
```
The run ends with `Requirements: 0 / 10 passed` and **`Sprint 8 start is ready to go`**. The HTTPS checks show status `000` because there's no certificate yet: the controller refuses the TLS handshake.

**Then build.** Edit and add files in **`lab/work/sprint/`**, and apply the folder with `kubectl apply -f work/sprint/` as often as you like. Some requirements need a command instead of a file: Secrets (`kubectl create secret ...`, as on Day 2), and requirement 10, which is a controller setting managed through Helm:
```bash
# host, lab/ (requirement 10: your setting goes in work/nic-settings.yaml, a second Helm values file)
helm upgrade nic oci://ghcr.io/nginx/charts/nginx-ingress --version 2.9.0 -n nginx-ingress \
  -f nic-values.yaml -f work/nic-settings.yaml --wait
```
Keep `nic-settings.yaml` in `work/`, **not** in `work/sprint/`: it's a Helm values file, not a Kubernetes object, so `kubectl apply -f work/sprint/` would fail on it. `lab/nic-values.yaml` stays unchanged as the first `-f`, so the lab's own settings (image, ports, node) are kept.

Run the test from `sprints/sprint-8` (`cd .. && ./test_sprint08.sh; cd lab`). It takes about 70 seconds, because requirement 8 does a real rolling restart under load and requirement 9 waits 15 seconds. Each failure says what it sent and what came back.

<details>
<summary>Hints, if you're stuck (one per requirement, no YAML)</summary>

1. **HTTPS:** the Secret must be named `transit-tls`, in `transit`. And what does a VirtualServer need to send HTTP users to HTTPS?
2. **One VirtualServer:** the test reads `spec.ingressClassName`.
3. **Fares:** two objects, two namespaces, and they must point at each other.
4. **Fares rate limit:** where does a policy for a delegated path live? And the burst must be served at once.
5. **Canary:** order matters, and the test checks that about 10% of plain requests reach v2.
6. **Dispatch:** a Secret of the right type, a Policy, and a route action that can change request headers.
7. **Five seconds:** both arrivals upstreams. Activity 3.7.
8. **Zero downtime:** your copy of `arrivals-v1.yaml`. The test uses slow POSTs.
9. **Half-broken pod:** what counts as a failure, and for how long is a failed pod left alone?
10. **Server header:** a controller-wide setting, in the controller's ConfigMap (`controller.config.entries` in Helm values). The key's name is in the ConfigMap documentation for F5 NGINX Ingress Controller.
</details>

`lab/solution/` is the reference (`lab/solution/apply.sh` applies it to a reset lab).

---

## 5. Day 3 Concept Examination (10-Question Randomized Quiz)

```bash
# host, any directory (a second terminal)
cd /srv/nginx-journey && python3 -m http.server 8090
```
👉 **http://&lt;lab-host&gt;:8090/quiz.html?sprint=8&day=3**

**Enterprise side quest (optional):** [F5 NGINX Ingress Controller with NGINX Plus](day_03_enterprise.md): reloads you don't need, active health checks as a circuit breaker, slow start, queues, JWT tiers, and claim-based authorization, with its quiz at `quiz.html?sprint=8&day=3&pool=enterprise`.

When you're done: `./lab.sh down` (from `lab/`).

---

## 6. Key Takeaways for Day 3
* **`splits` are random per request** (`split_clients $request_id`). A canary that sticks to a user needs a `matches` condition on a header or cookie. The first match wins.
* **Zero downtime is a pod-spec property:** a readiness probe for the start, a `preStop` sleep for the stop, and a grace period long enough for both.
* **Test rollouts with POSTs.** NGINX silently retries failed GETs, so GET-only tests hide the damage.
* **A 500 isn't a failure to NGINX** unless `next-upstream` lists `http_500`. Then `max-fails` and `fail-timeout` make a passive circuit breaker.
* **Retries multiply timeouts.** The controller's unlimited `next-upstream` tries turn a 5 s `read-timeout` into 5 s × the number of pods.
* **Open source NGINX reloads for every endpoint change.** A rolling restart is a dozen reloads.

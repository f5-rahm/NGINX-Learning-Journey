# Sprint 2 &bull; Day 4 (Enterprise Side Quest): NGINX Plus Upstreams
**Date:** Friday, Oct 9  
**Estimated Time:** 60–75 Minutes (15 concepts, 10 OSS contrast, 10 Plus setup, 25 API lab, 10 quiz)  
**Theme:** Changing a pool in open source means editing config and reloading. NGINX Plus changes it in shared memory through an API. Learn what each costs, and what open source has quietly gained.

> **Status:** The open-source sections were run on the lab box (nginx 1.31.6). The NGINX Plus sections follow current F5 docs (API version 10, R33+ licensing) but have **not yet been run end to end** in this repo, because no license was on the box when this was written. Expect to adjust image tags or output details on your first run, and note them in your journal.

**Before the day:** download `license.jwt` from MyF5 (a trial is fine) and copy it to `~/plus/license.jwt` on the lab box. Pulling the image (4.1) takes a few minutes, so you can do it the evening before.

---

## 1. Concepts to Understand (15 Minutes)

### 1.1 What Changing a Pool Costs in Open Source
Adding, removing, or re-weighting a server in OSS means **edit the config, then reload**.
* **New config, new workers.** The master re-reads the config and starts new workers. Old workers stop accepting new connections and **keep serving existing ones** until they finish.
* **Long-lived connections pin old workers.** WebSockets, gRPC streams and long downloads keep old workers, and their memory, alive until those connections close or `worker_shutdown_timeout` fires. Frequent reloads (an autoscaler adding pods every minute) stack up generations of old workers.
* **Runtime state resets.** Per-worker state, such as balancing position and failure counts without a zone, starts fresh in the new workers.

**The OSS control API (1.31.5+, `--with-control-api`)**
* Started with `nginx -l unix:/path/control.sock`.
* `/1/control/processes` shows workers, including `"exiting": true` for draining ones.
* `GET /1/control/config` dumps the running config.
* `PATCH /1/control/config` **triggers a reload** and returns any `emerg` messages.
* It makes reloads observable and scriptable. **It does not change upstream membership without a reload.**

### 1.2 What Open Source Has Gained (Formerly Plus-Only)

| Feature | In OSS since | What it does |
| :--- | :--- | :--- |
| `zone` (shared upstream state) | 1.9.0 | Workers share balancing and failure state. Required by everything below. |
| `server ... resolve` + `resolver` in `upstream` | 1.27.3 | Re-resolves DNS at runtime, honoring TTL or `valid=`. No reload when IPs change. |
| `service=` (DNS SRV) | 1.27.3 | Discovers servers and ports from SRV records |
| `sticky cookie` / `route` / `learn`, `server ... drain` | 1.29.6 | Session affinity, and draining a server in config |
| `keepalive` on by default | 1.29.7 | Day 2 |
| `least_time header \| last_byte` | 1.31.0 | Picks by lowest average response time and fewest active connections |
| Control API | 1.31.5 | Reload and inspect processes over a socket (1.1) |

### 1.3 What Is Still NGINX Plus

| Plus capability | Why it matters |
| :--- | :--- |
| **REST API (`api write=on`)** to add, modify (`weight`, `max_fails`, `drain`, `down`, `slow_start`...) and delete upstream servers | Pool changes apply in shared memory **with no reload**, so long-lived connections and old workers are unaffected |
| **`state` file** | API changes survive restarts. Can't be combined with `server` lines in the same upstream. |
| **`slow_start=`** | A recovered server's weight ramps from 0 to nominal, so a cold JVM/Node instance isn't stampeded. OSS rejects it as `invalid parameter`. |
| **Live metrics** (`/api/10/http/upstreams/...`, dashboard) | Per-peer `state`, `active`, `requests`, `responses`, `fails`, `downtime`, `response_time` |
| `queue`, `ntlm` | Hold requests when every server is at `max_conns`; NTLM connection affinity |
| **Active health checks** (`health_check`, `match`) | Probe before users hit a failure. **Sprint 12.** |

**API essentials (version 10)**
```
GET    /api/                                            → supported versions, e.g. [1,...,10]
GET    /api/10/http/upstreams/<name>/servers            → configured servers (with ids)
POST   /api/10/http/upstreams/<name>/servers            → add   {"server":"127.0.0.1:8004", ...} → 201
PATCH  /api/10/http/upstreams/<name>/servers/<id>       → modify {"drain":true} | {"down":true} | {"weight":3}
DELETE /api/10/http/upstreams/<name>/servers/<id>       → remove → 200
GET    /api/10/http/upstreams/<name>                    → live peer stats
GET    /api/10/license                                  → license / usage-report status
```
* An upstream **without a `zone`** can't be changed: `400 UpstreamStatic`.
* `drain` means only requests *bound* to the server (by `sticky`) still go there. Everything else stops, and in-flight requests finish.

### 1.4 Licensing (R33+)
* Every NGINX Plus instance needs `license.jwt`. The default path is `/etc/nginx/license.jwt`.
* It must report usage to `product.connect.nginx.com` (HTTPS).
* **With the default `enforce_initial_report on`, NGINX Plus refuses traffic until the first report succeeds.** If you see 502/503-style refusals on a brand-new instance, check `docker logs` for licensing messages before debugging your config.

---

## 2. OSS Contrast: The Cost of a Reload (10 Minutes)

Use your Day 3 Lumina gateway (or `solution_nginx.conf`), restarted with a control socket:
```bash
cd /srv/nginx-journey/sprints/sprint-2/lab
./mocks.sh start && ./mocks.sh start 8004
ngx -s quit; sleep 1
ngx -l unix:$PWD/run/control.sock
ctl() { curl -s --unix-socket "$PWD/run/control.sock" "http://localhost$1" "${@:2}"; echo; }
ctl /1/nginx
ctl /1/control/processes
```
Open a long-lived chat in the background, then "scale out" the OSS way:
```bash
./ws_client.py ws://localhost:8082/ws/chat hello --idle 30 &      # holds a tunnel for 30 s
sleep 1
sed -i 's|server 127.0.0.1:8002 max_fails=2 fail_timeout=5s;|&\n        server 127.0.0.1:8004 max_fails=2 fail_timeout=5s;|' nginx.conf
ctl /1/control/config -X PATCH                                      # reload; prints {"logs":[]} on success
ctl /1/control/processes | jq -c '.[]'                              # one worker "exiting": true
ps -o pid,args --ppid "$(cat logs/nginx.pid)"                       # "worker process is shutting down"
wait; sleep 1; ctl /1/control/processes | jq -c '.[]'               # gone once the tunnel closes
```
**What happens**
* The new node took traffic only after a reload, and an old worker stayed alive as long as the WebSocket did.
* Reload with a typo (try `weight=x`): `PATCH` returns the `emerg` text in `logs`, and the old config keeps running.
* *Try it:* change the 8004 line to end in `drain;` and `PATCH` again. OSS 1.29.6+ accepts it, and node-3 stops receiving new requests. It's the same effect as Plus's drain, delivered by a reload.

*Journal:* with an autoscaler adding a node every minute and chats lasting an hour, how many worker generations could be alive at once?

---

## 3. NGINX Plus Setup (10 Minutes)

```bash
mkdir -p ~/plus && ls -l ~/plus/license.jwt                         # from MyF5
docker login private-registry.nginx.com --username="$(cat ~/plus/license.jwt)" --password=none
PLUS_TAG=r37-debian       # F5 tags look like rNN-debian / rNN-alpine; use the newest your license can pull
docker pull private-registry.nginx.com/nginx-plus/base:$PLUS_TAG
```
Then run it with host networking, so the container reaches the mocks on 127.0.0.1:
```bash
cd /srv/nginx-journey/sprints/sprint-2/lab
chmod 777 plus/state && touch plus/state/lumina_api_nodes.state && chmod 666 plus/state/lumina_api_nodes.state
docker run -d --name lumina-plus --network host \
  -v "$PWD/plus/nginx.conf:/etc/nginx/nginx.conf:ro" \
  -v "$HOME/plus/license.jwt:/etc/nginx/license.jwt:ro" \
  -v "$PWD/plus/state:/var/lib/nginx/state" \
  private-registry.nginx.com/nginx-plus/base:$PLUS_TAG
docker logs lumina-plus 2>&1 | tail -20                             # look for license / usage report lines
api() { curl -s "http://127.0.0.1:8085/api/10$1" "${@:2}"; echo; }
curl -s http://127.0.0.1:8085/api/                                  # supported versions; confirm 10 is listed
api /nginx | jq '{version, build}'
api /license | jq .
```
**Ports:** Plus traffic on **8084**, and the API and dashboard on **127.0.0.1:8085**. The OSS lab stays on 8082.

**Dashboard:** `http://127.0.0.1:8085/dashboard.html`. From your workstation, use `ssh -L 8085:127.0.0.1:8085 <lab-host>`.

---

## 4. Hands-on: Managing the Pool with the API (25 Minutes)

```bash
tally() { for i in $(seq "${2:-20}"); do curl -s -H 'Host: lumina.local' "localhost:8084$1" | jq -r .node; done | sort | uniq -c; }
U=/http/upstreams/lumina_api_nodes
```

### Activity 4.1: Start From an Empty Pool (5 min)
```bash
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: lumina.local' localhost:8084/api/v1/x   # 502: no servers yet
for p in 8001 8002; do
  api $U/servers -X POST -H 'Content-Type: application/json' \
    -d "{\"server\":\"127.0.0.1:$p\",\"max_fails\":2,\"fail_timeout\":\"5s\"}" | jq -c .
done
api $U/servers | jq -c '.[] | {id, server}'
tally /api/v1/x
cat plus/state/lumina_api_nodes.state                               # written by NGINX Plus
```
* `201 Created` responses, then traffic splits across both nodes.
* The `state` file now lists two `server` lines.
* No reload happened. Compare `docker top lumina-plus` worker PIDs before and after.

### Activity 4.2: Scale Out With No Reload (4 min)
```bash
docker top lumina-plus | grep worker                                # note the PIDs
api $U/servers -X POST -H 'Content-Type: application/json' \
  -d '{"server":"127.0.0.1:8004","max_fails":2,"fail_timeout":"5s"}' | jq -c .
tally /api/v1/x 30                                                  # api-node-3 now appears
docker top lumina-plus | grep worker                                # same PIDs
```

### Activity 4.3: Drain, Then Remove (8 min)
Start three slow requests so each node has one in flight (`least_conn` spreads them), then drain node-3:
```bash
for i in 1 2 3; do curl -s -H 'Host: lumina.local' 'localhost:8084/api/v1/long?delay=20' -o /dev/null & done; sleep 1
ID=$(api $U/servers | jq '.[] | select(.server=="127.0.0.1:8004") | .id')
api $U/servers/$ID -X PATCH -H 'Content-Type: application/json' -d '{"drain":true}' | jq -c .
api $U | jq -c '.peers[] | {server, state, active, requests}'      # 8004: state "draining", active 1
tally /api/v1/x 20                                                  # no new requests to api-node-3
wait
api $U | jq -c '.peers[] | {server, state, active}'                 # 8004: active 0
api $U/servers/$ID -X DELETE | jq -c '.[] | {id, server}'
```
**Contrast:** OSS 1.29.6+ also has `drain`, but only as a config parameter, which means a reload. Plus flips it on a live pool in one call.

### Activity 4.4: Persistence Through a Restart (3 min)
```bash
docker restart lumina-plus && sleep 3
api $U/servers | jq -c '.[] | {id, server}'                         # same membership, read back from the state file
```
* The state file is the source of truth for this upstream.
* Changes made **during** a reload or binary upgrade can be lost, so don't script API writes while reloading.

### Activity 4.5 (Stretch): `slow_start` for a Recovering Node (5 min)
```bash
ID1=$(api $U/servers | jq '.[] | select(.server=="127.0.0.1:8001") | .id')
api $U/servers/$ID1 -X PATCH -H 'Content-Type: application/json' -d '{"slow_start":"30s"}' | jq -c .
./mocks.sh stop 8001; tally /api/v1/x 10                            # 8001 marked unavailable
./mocks.sh start 8001; sleep 6                                      # past fail_timeout
for t in 1 2 3 4 5 6; do echo "--- t+$((t*5))s"; tally /api/v1/x 20; sleep 5; done
```
Expect api-node-1's share to **climb gradually** over about 30 s instead of jumping straight back to a third.

`slow_start` applies when a server **recovers**: unavailable to available, or unhealthy to healthy with active checks. It doesn't apply when a server is first added.

### Cleanup
```bash
docker rm -f lumina-plus
```

---

## 5. Day 4 Concept Examination (10-Question Randomized Quiz)

👉 **http://&lt;lab-host&gt;:8090/quiz.html?sprint=2&day=4** (serve with `cd /srv/nginx-journey && python3 -m http.server 8090`)

---

## 6. Key Takeaways for Day 4
* **OSS changes a pool by reloading.** It's safe and graceful, but long-lived connections pin old workers, and every change is a config deployment.
* **The OSS control API makes reloads scriptable and observable.** It doesn't make pool changes reload-free.
* **Open source has absorbed a lot:** `resolve`, `service=`, `sticky`, `drain`, `least_time`, and keepalive by default. Re-check feature matrices against the current version before assuming something is Plus-only.
* **Still Plus:**
  * The write API for upstream membership and parameters, applied in shared memory with no reload.
  * `state` persistence and `slow_start`.
  * Live per-peer metrics, `queue`.
  * Active health checks (Sprint 12).
* **Every API-managed upstream needs a `zone`.** Without one: `400 UpstreamStatic`.
* **R33+ licensing is operational:** `license.jwt` plus a successful first usage report, or the instance won't serve traffic.

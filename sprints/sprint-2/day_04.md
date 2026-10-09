# Sprint 2 &bull; Day 4 (Enterprise Side Quest): NGINX Plus Upstreams
**Date:** Friday, Oct 9  
**Estimated Time:** 60–75 Minutes (15 concepts, 10 setup, 40 hands-on, 10 quiz)  
**Theme:** Changing a pool in open source means editing config and reloading. NGINX Plus changes it in shared memory through an API. Learn what each costs, and what open source has quietly gained.

> **Status:** The open-source activity was run on the lab box (nginx 1.31.6). The NGINX Plus activities are being run for the first time on R36 (`nginx-plus-r36-p8`, built on open source 1.29.3). Setup through Activity 3.2 is confirmed. The later activities follow F5 docs, so expect small output differences and note them in your journal.

---

## 1. Concepts to Understand (15 Minutes)

### 1.1 What Changing a Pool Costs in Open Source
In open source, the upstream pool is part of the configuration. Adding, removing, or re-weighting a server means **editing the config, then reloading**.
* **New config, new workers.** The master re-reads the config and starts new workers. Old workers stop accepting new connections and **keep serving existing ones** until they finish.
* **Long-lived connections pin old workers.** WebSockets, gRPC streams and long downloads keep old workers, and their memory, alive until those connections close or `worker_shutdown_timeout` fires. Frequent reloads (an autoscaler adding pods every minute) stack up generations of old workers.
* **Runtime state resets.** Per-worker state, such as balancing position and failure counts without a zone, starts fresh in the new workers.
* **BIG-IP lens:** adding a pool member on BIG-IP changes a running object, and nothing restarts. Open source NGINX has no equivalent. The running config can't be changed in place, so every change creates a new generation of workers.

### 1.2 The OSS Control API
Since 1.31.5, open source NGINX can be built with a control API (`--with-control-api`), served on a local Unix socket.
* **What it can do:** report the running version and the worker processes (including old ones that are still draining), return the running config, and trigger a reload that reports any config errors back to the caller.
* **What it can't do:** change upstream membership without a reload. Every write is still a reload.
* Think of it as a scriptable, observable `nginx -s reload`, not a pool API.

### 1.3 What Open Source Has Gained (Formerly Plus-Only)

| Feature | In OSS since | What it does |
| :--- | :--- | :--- |
| `zone` (shared upstream state) | 1.9.0 | Workers share balancing and failure state. Required by everything below. |
| `server ... resolve` + `resolver` in `upstream` | 1.27.3 | Re-resolves DNS at runtime, honoring TTL or `valid=`. No reload when IPs change. |
| `service=` (DNS SRV) | 1.27.3 | Discovers servers and ports from SRV records |
| `sticky cookie` / `route` / `learn`, `server ... drain` | 1.29.6 | Session affinity, and draining a server in config |
| `keepalive` on by default | 1.29.7 | Day 2 |
| `least_time header \| last_byte` | 1.31.0 | Picks by lowest average response time and fewest active connections |
| Control API | 1.31.5 | Reload and inspect processes over a socket (1.2) |

### 1.4 What Is Still NGINX Plus

| Plus capability | Why it matters |
| :--- | :--- |
| **REST API with write access** to add, modify (`weight`, `max_fails`, `drain`, `down`, `slow_start`...) and delete upstream servers | Pool changes apply in shared memory **with no reload**, so long-lived connections and old workers are unaffected |
| **`state` file** | API changes survive restarts. Can't be combined with `server` lines in the same upstream. |
| **`slow_start=`** | A recovered server's weight ramps from 0 to nominal, so a cold JVM/Node instance isn't stampeded. OSS rejects it as `invalid parameter`. |
| **Live metrics** (API and dashboard) | Per-peer `state`, `active`, `requests`, `responses`, `fails`, `downtime`, `response_time` |
| `queue`, `ntlm` | Hold requests when every server is at `max_conns`; NTLM connection affinity |
| **Active health checks** (`health_check`, `match`) | Probe before users hit a failure. **Sprint 12.** |

### 1.5 How the Plus API Models a Pool
* **An upstream is a resource, and each server in it is a sub-resource with a numeric id.** You add a server, change its parameters, or delete it, and the change lands in the upstream's shared memory zone. Every worker sees it at once. No new workers start.
* **No zone, no API.** An upstream without a `zone` is static. The API refuses to change it.
* **Without a `state` file, API changes live only in memory.** A restart rebuilds the pool from the config. With a `state` file, NGINX Plus writes every change to disk and reads it back at startup, so the file becomes the source of truth for that upstream.
* **Write access is opt-in.** The API is read-only unless write access is turned on, and it belongs on a management-only listener, never on the traffic port.
* **The API is versioned in the URL, and each release supports a range.** Asking the instance which versions it serves is part of the API. The nginx.org docs describe version 10, but R36 serves only 1 to 9. Scripts should ask the instance instead of hard-coding a version.

**BIG-IP lens**

| NGINX Plus | Closest BIG-IP equivalent | Difference |
| :--- | :--- | :--- |
| Upstream API | iControl REST on pool members | Changes go straight into the running data plane. There's no separate config save. |
| `drain` | Member **Disabled** | Only requests *bound* to the server by `sticky` still go there. In-flight requests finish. |
| `down` | Member **Forced Offline** | No new requests. In-flight requests finish. |
| `slow_start` | Slow ramp time | Set per server, not per pool. Applies only when a server *recovers*, not when it's first added. |
| `state` file | Saved config (`tmsh save sys config`) | Written automatically on every API change. |

### 1.6 Licensing (R33+)
* **Every NGINX Plus instance needs `license.jwt`.** NGINX Plus looks for it at its default path, `/etc/nginx/license.jwt`, unless the `mgmt` block points somewhere else.
* **Usage reporting is required.** The instance reports usage to `product.connect.nginx.com` over HTTPS.
* **With the default `enforce_initial_report on`, NGINX Plus refuses traffic until the first report succeeds.** On a brand-new instance that rejects requests, check the logs for licensing messages before you debug your config.
* **The same JWT is your registry credential.** It's how you log in to F5's private registry to pull Plus images.
* Where your copy of the file lives in the lab, and how it reaches that default path, is a lab setup detail. See 2.1.

---

## 2. Lab Setup (10 Minutes)

### 2.1 How OSS and Plus Run in This Lab
This is the standing convention for every NGINX Plus side quest. The full version is [`docs/nginx-plus-lab.md`](../../docs/nginx-plus-lab.md).

| | NGINX OSS | NGINX Plus |
| :--- | :--- | :--- |
| **Runs as** | Host binary (`ngx`, as on Days 1–3) | Container `lumina-plus` from F5's private registry |
| **Config** | `lab/nginx.conf` (your Day 3 Lumina gateway) | `lab/plus/nginx.conf`, mounted at `/etc/nginx/nginx.conf` |
| **License** | None | `~/plus/license.jwt` on the host, mounted at `/etc/nginx/license.jwt`, the default path from 1.6 |
| **Traffic** | **8082** | **8084** |
| **Management** | Control socket `lab/run/control.sock` | API and dashboard on **127.0.0.1:8085** |
| **Logs** | `lab/logs/` | `docker logs lumina-plus` |
| **Reload** | `ngx -s reload` | `docker exec lumina-plus nginx -s reload` |

The container uses host networking, so it reaches the same mocks on `127.0.0.1:800x` as the OSS instance.

### 2.2 One-Time NGINX Plus Setup (Skip If Already Done on This Box)
The license stays outside the repo and is reused by every side quest.
```bash
mkdir -p -m 700 ~/plus
cp /path/to/license.jwt ~/plus/license.jwt && chmod 600 ~/plus/license.jwt
docker login private-registry.nginx.com --username="$(cat ~/plus/license.jwt)" --password=none
echo 'PLUS_IMAGE=private-registry.nginx.com/nginx-plus/base:r36-debian' > ~/plus/plus.env
source ~/plus/plus.env && docker pull "$PLUS_IMAGE"
```
R36 was the newest release on Oct 9, 2026. To see what your license can pull, use the tag listing in [`docs/nginx-plus-lab.md`](../../docs/nginx-plus-lab.md).

### 2.3 Start Both Engines
```bash
cd /srv/nginx-journey/sprints/sprint-2/lab
./mocks.sh start && ./mocks.sh start 8004

# OSS: restart the Lumina gateway with a control socket
ngx -s quit; sleep 1
ngx -l unix:$PWD/run/control.sock

# Plus: start the container
source ~/plus/plus.env
chmod 777 plus/state && touch plus/state/lumina_api_nodes.state && chmod 666 plus/state/lumina_api_nodes.state
docker run -d --name lumina-plus --network host \
  --mount type=bind,src="$PWD/plus/nginx.conf",dst=/etc/nginx/nginx.conf,readonly \
  --mount type=bind,src="$HOME/plus/license.jwt",dst=/etc/nginx/license.jwt,readonly \
  --mount type=bind,src="$PWD/plus/state",dst=/var/lib/nginx/state \
  "$PLUS_IMAGE"
```
Shell helpers for the activities:
```bash
ctl() { curl -s --unix-socket "$PWD/run/control.sock" "http://localhost$1" "${@:2}"; echo; }   # OSS control API
V=$(curl -s http://127.0.0.1:8085/api/ | jq '.[-1]'); echo "Plus API version $V"              # newest version this instance serves
api() { curl -s "http://127.0.0.1:8085/api/$V$1" "${@:2}"; echo; }                              # Plus API
U=/http/upstreams/lumina_api_nodes
tally() { for i in $(seq "${2:-20}"); do curl -s -H 'Host: lumina.local' "localhost:8084${1:-/api/v1/x}" | jq -r .node; done | sort | uniq -c; }   # Plus gateway
otally() { for i in $(seq "${1:-20}"); do curl -s -H 'Host: lumina.local' localhost:8082/api/v1/x | jq -r .node; done | sort | uniq -c; }   # OSS gateway
```

---

## 3. Hands-on Guided Discovery Activities (40 Minutes)

**Plus API quick reference** (`<v>` is the newest version from `GET /api/`: 9 on R36)
```
GET    /api/                                            → supported versions, e.g. [1,...,9]
GET    /api/<v>/nginx                                   → version and build
GET    /api/<v>/license                                 → license / usage-report status
GET    /api/<v>/http/upstreams/<name>                   → live peer stats
GET    /api/<v>/http/upstreams/<name>/servers           → configured servers (with ids)
POST   /api/<v>/http/upstreams/<name>/servers           → add   {"server":"127.0.0.1:8004", ...} → 201
PATCH  /api/<v>/http/upstreams/<name>/servers/<id>      → modify {"drain":true} | {"down":true} | {"weight":3}
DELETE /api/<v>/http/upstreams/<name>/servers/<id>      → remove → 200
```
**Dashboard:** `http://127.0.0.1:8085/dashboard.html`. From your workstation, use `ssh -L 8085:127.0.0.1:8085 <lab-host>`.

### Activity 3.1 (OSS): The Cost of a Reload (10 min)
**a. Before:** look at the running instance and where traffic goes.
```bash
ctl /1/nginx
ctl /1/control/processes | jq -c '.[]'                              # two workers, "exiting": false
otally                                                              # api-node-1 and api-node-2 only
```

**b. Scale out the OSS way** while a long-lived chat is open:
```bash
./ws_client.py ws://localhost:8082/ws/chat hello --idle 30 &      # holds a tunnel for 30 s
sleep 1
sed -i 's|server 127.0.0.1:8002 max_fails=2 fail_timeout=5s;|&\n        server 127.0.0.1:8004 max_fails=2 fail_timeout=5s;|' nginx.conf
grep -c 8004 nginx.conf                                             # must be 1; this sed adds a line every time it runs
ctl /1/control/config -X PATCH                                      # reload; prints {"logs":[]} on success
ctl /1/control/processes | jq -c '.[]'
ps -o pid,args --ppid "$(cat logs/nginx.pid)"
otally                                                              # api-node-3 now appears
wait; sleep 1; ctl /1/control/processes | jq -c '.[]'               # after the chat closes
```
**What you'll see**
* **Every old worker is marked `"exiting": true`**, and two new workers start.
* In `ps`, the old worker holding the chat shows `worker process is shutting down`. An old worker with no open connections exits right away and may briefly show as `[nginx]` until the master cleans it up.
* api-node-3 takes traffic only after the reload.
* When the chat closes, the last old worker exits, and only the two new workers are left.

**c. Drain node-3 with a reload:** change the *existing* 8004 line instead of adding one. No chat is needed for c and d. They're about where traffic goes. (Optional: start the chat first, and you'll see the drain also leaves an old worker shutting down, because it's still a reload.)
```bash
sed -i 's|\(server 127.0.0.1:8004 max_fails=2 fail_timeout=5s\);|\1 drain;|' nginx.conf
grep -n 8004 nginx.conf                                             # exactly one line, ending in "drain;"
ctl /1/control/config -X PATCH
sleep 1; otally                                                     # no api-node-3
```
* Without the `sleep`, a request or two can still reach api-node-3. For a few milliseconds after `PATCH` returns, old workers running the old config may still accept connections. A reload isn't instant.
* OSS 1.29.6+ accepts `drain`, with or without a `zone`. It's the same effect as Plus's drain, delivered by a reload.
* Two lines for the same address count as two separate servers, and NGINX doesn't warn about it. A plain duplicate line keeps taking traffic while its `drain` twin sits idle.

**d. Break it on purpose:** a reload with an invalid config.
```bash
sed -i 's| drain;| weight=x;|' nginx.conf && grep -n 8004 nginx.conf     # now ends in "weight=x;"
ctl /1/control/config -X PATCH                                            # "logs" carries the [emerg] text
otally                                                                    # still no api-node-3: the old config keeps serving
sed -i 's| weight=x;| drain;|' nginx.conf && ctl /1/control/config -X PATCH   # restore: {"logs":[]}
```

*Journal:* with an autoscaler adding a node every minute and chats lasting an hour, how many worker generations could be alive at once?

### Activity 3.2 (Plus): Is the License Working? (3 min)
```bash
docker logs lumina-plus 2>&1 | grep -E 'nginx/|emerg|crit|license'   # startup banner, any license errors
curl -s http://127.0.0.1:8085/api/; echo                            # supported versions: [1,...,9] on R36
curl -s http://127.0.0.1:8085/api/10/nginx; echo                    # what a hard-coded newer version gets
api /nginx | jq '{version, build}'
api /license | jq .
```
**What you'll see**
* **The logs say nothing about the usage report when it succeeds.** NGINX Plus logs licensing only when something is wrong, such as `License file is required`. The API is where you confirm it.
* `/api/10/...` returns `404 UnknownVersion` on R36, even though the nginx.org docs describe version 10. That's why the `api` helper asks the instance for its newest version.
* `/license` shows `reporting.healthy: true` and `fails: 0` once the first report went through. `eval: true` marks a trial, `active_till` is the expiry as a Unix time (`date -d @<value>`), and `grace` is how long, in seconds, the instance keeps serving if reporting later fails.
* *Journal:* which open source version is this Plus release built on? Compare it with the host's 1.31.6. Which Day 2 defaults does that change?

### Activity 3.3: Start From an Empty Pool (5 min)
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

### Activity 3.4: Scale Out With No Reload (4 min)
```bash
docker top lumina-plus | grep worker                                # note the PIDs
api $U/servers -X POST -H 'Content-Type: application/json' \
  -d '{"server":"127.0.0.1:8004","max_fails":2,"fail_timeout":"5s"}' | jq -c .
tally /api/v1/x 30                                                  # api-node-3 now appears
docker top lumina-plus | grep worker                                # same PIDs
```

### Activity 3.5: Drain, Then Remove (8 min)
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

### Activity 3.6: Persistence Through a Restart (3 min)
```bash
docker restart lumina-plus && sleep 3
api $U/servers | jq -c '.[] | {id, server}'                         # same membership, read back from the state file
```
* The state file is the source of truth for this upstream.
* Changes made **during** a reload or binary upgrade can be lost, so don't script API writes while reloading.

### Activity 3.7 (Stretch): `slow_start` for a Recovering Node (5 min)
```bash
ID1=$(api $U/servers | jq '.[] | select(.server=="127.0.0.1:8001") | .id')
api $U/servers/$ID1 -X PATCH -H 'Content-Type: application/json' -d '{"slow_start":"30s"}' | jq -c .
./mocks.sh stop 8001; tally /api/v1/x 10                            # 8001 marked unavailable
./mocks.sh start 8001; sleep 6                                      # past fail_timeout
for t in 1 2 3 4 5 6; do echo "--- t+$((t*5))s"; tally /api/v1/x 20; sleep 5; done
```
Expect api-node-1's share to **climb gradually** over about 30 s instead of jumping straight back to a third.

### Cleanup
```bash
docker rm -f lumina-plus
```

---

## 4. Day 4 Concept Examination (10-Question Randomized Quiz)

👉 **http://&lt;lab-host&gt;:8090/quiz.html?sprint=2&day=4** (serve with `cd /srv/nginx-journey && python3 -m http.server 8090`)

---

## 5. Key Takeaways for Day 4
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

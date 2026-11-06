# NGINX Learning Journey
**Timeframe:** FY27 Q1 (October 1 – December 31)  
**Target Cadence:** 14 Sprints, one per week. From Sprint 3 on, each sprint is **3 sessions**, scheduled on whichever days of the week suit (Sprints 1–2 ran 2 and 4 days). Enterprise side quests are optional add-ons to Day 3.  
**Primary Engine:** Open Source NGINX (OSS)  
**Side Quests: Enterprise Trail:** NGINX Plus, F5 App Protect WAF, F5 NGINX Ingress Controller, and NGINX Gateway Fabric  

---

## Getting Started

Do this once per lab box, then start with [Sprint 1, Day 1](sprints/sprint-1/day_01.md).

### System Requirements

| Need | Details |
| :--- | :--- |
| **Host** | One Ubuntu machine (a VM or cloud instance is fine) with 4 vCPU, 8 GB RAM and 20 GB of free disk. |
| **Access** | Root (`sudo -i`). The labs signal NGINX processes, read container network namespaces and bind low-numbered ports. |
| **Network** | Outbound internet for packages and container images. Reach the lab ports (8081–8098, 8443 TCP+UDP, 8090) from your browser if you want to use the quiz page from a workstation. |
| **NGINX** | Mainline from the nginx.org repository, not Ubuntu's package. It's current, and it includes the `nginx-debug` binary used in Sprint 1. Sprints 1–3 run it on the host. |
| **Docker Engine** | Required from Sprint 3 (the HTTP/3 checks) and for every lab from Sprint 4 on, which run NGINX and their backends in containers. Also used by every NGINX Plus side quest. |
| **Host tools** | `git`, `curl`, `openssl`, `python3` (standard library only, nothing to `pip install`), `jq`, `iproute2` (`ss`, `nstat`) and `procps` (`ps`, `sysctl`), and the trace tools `strace`, `sysstat`, `tcpdump`, `lsof`. Most Ubuntu installs already have `iproute2` and `procps`; minimal images don't. |
| **Repo path** | Clone to **`/srv/nginx-journey`**. Guides, helper scripts and a few lab configs use that absolute path, and the `nginx` worker user can't read files under a home directory (mode 750 on Ubuntu). |
| **Optional** | An NGINX Plus license (`license.jwt` from MyF5, a trial is fine) for the enterprise side quests; see [`docs/nginx-plus-lab.md`](docs/nginx-plus-lab.md). Kubernetes tools (`kind`, `kubectl`, `helm`) are introduced in Sprint 8. |

### One-Time Setup

Run as root:

```bash
# 1. Host tools
apt update
apt install -y git curl ca-certificates gnupg openssl python3 jq iproute2 procps strace sysstat tcpdump lsof

# 2. NGINX mainline from nginx.org (https://nginx.org/en/linux_packages.html#Ubuntu)
curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/mainline/ubuntu $(. /etc/os-release; echo $VERSION_CODENAME) nginx" \
  > /etc/apt/sources.list.d/nginx.list
printf 'Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n' > /etc/apt/preferences.d/99nginx
apt update && apt install -y nginx
systemctl disable --now nginx          # the labs start their own instances; keep port 80 free
nginx -v && ls /usr/sbin/nginx-debug

# 3. Docker Engine (https://docs.docker.com/engine/install/ubuntu/; the convenience script suits a lab box)
curl -fsSL https://get.docker.com | sh
docker run --rm hello-world

# 4. The repo
git clone https://github.com/f5-rahm/NGINX-Learning-Journey.git /srv/nginx-journey
```

Then:
* **Each sprint's README** has that sprint's port map and its lab setup (`mocks.sh`, `make_certs.sh`, or `lab.sh up`). Logs, temp files, caches, certificates and keys are created by those steps, never committed.
* **The quizzes** run from the repo: `cd /srv/nginx-journey && python3 -m http.server 8090`, then open `http://<lab-host>:8090/quiz.html?sprint=1&day=1`.
* **The NGINX Plus side quests** need the one-time license setup in [`docs/nginx-plus-lab.md`](docs/nginx-plus-lab.md).
* **Each sprint's test** (`test_sprintNN.sh`) fails its checks against the starter config. That's expected, because the lab is to make them pass. From Sprint 4 on, the test also prints a "ready to go" banner when the lab is up and the starter loads.
* **To check a new lab box or a change to these steps**, [`docs/fresh-clone-test/`](docs/fresh-clone-test/README.md) runs this setup and every sprint lab in a clean Ubuntu container.

---

## 1. Executive Summary & Educational Vision

### 1.1 The Objective
To evolve from treating NGINX as a "black-box configuration utility" to mastering it as a high-performance network execution engine, edge security gateway, and Kubernetes traffic fabric. 

By the conclusion of this 14-week journey, the engineer will possess deep, low-level competency spanning:
1. **Linux Kernel & Process Mechanics:** Non-blocking I/O (`epoll`/`kqueue`), zero-copy socket transfers (`sendfile`/`tcp_nopush`), least-privilege master/worker separation, and zero-downtime Unix signal operations (`SIGUSR2` binary hot-swapping).
2. **Edge Traffic Engineering:** Deterministic location matching, Layer 7 reverse proxying, connection reuse (`keepalive`), dynamic upstreams, rate limiting, and dual-layer caching.
3. **Enterprise Edge Security:** Hardened TLS 1.3, mTLS mutual authentication, JWT/OIDC validation, and F5 App Protect WAF policy enforcement (DataGuard, User-Defined Signatures).
4. **Cloud-Native Traffic Control:** Kubernetes Ingress (F5 `VirtualServer` CRDs), the next-generation Kubernetes Gateway API (NGINX Gateway Fabric `HTTPRoute`/`GRPCRoute`), GenAI LLM inference routing extensions, and F5 BIG-IP CIS GatewayLink hybrid connectivity.

### 1.2 The Dual-Track Curriculum Model
* **The OSS Baseline (Primary Track):** Built entirely on free, open-source software (NGINX OSS, Linux kernel tools, standard Docker, and local `kind` Kubernetes clusters). Every core sprint is 100% executable without commercial licenses.
* **The Enterprise Side Quests (Opt-In Paid Track):** Mapped directly from official training decks (`NGINX Full Training.pptx`, 81 slides) and hands-on lab repositories (`NGINX-Ingress-Controller-Lab-main`, `NGINX-Gateway-Fabric-Lab-main`). These quests clearly demonstrate where enterprise capabilities (active health monitoring, on-the-fly upstream APIs, WAF inspection engines, GenAI inference extensions, and BIG-IP CIS integration) either replace complex OSS workarounds or unlock capabilities unavailable in pure OSS.
  * **How NGINX Plus runs in the lab:** OSS stays on the host; NGINX Plus runs in a container with the license mounted from `~/plus/`. Every side quest follows [`docs/nginx-plus-lab.md`](docs/nginx-plus-lab.md).

---

## 2. The Daily Discovery Format & Learning Engine

Each sprint day is engineered as a focused, high-impact **45 to 60-minute hands-on discovery session** (Day 3 runs longer because it carries the lab build). From Sprint 3 on, a sprint is three such sessions per week, on whichever days fit around normal duties. Rather than passive reading, learning is driven by a 4-phase pedagogical loop:

```
┌────────────────────────────────────────────────────────────────────────┐
│                      THE 45–60 MINUTE DAILY LOOP                       │
└────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │ 1. Core Architectural Concepts (15 Minutes)                      │
  │    - The "Why" behind the mechanics                              │
  │    - Socket state machines, memory buffers, directive precedence │
  └─────────────────────────────────┬────────────────────────────────┘
                                    │
                                    ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │ 2. Guided Hands-On Discovery (30 Minutes)                        │
  │    - Step-by-step terminal execution (`DAY_XX.md`)               │
  │    - Live verification via `curl`, `ps aux`, `lsof`, `ss`        │
  │    - Intentionally triggering failures to inspect error logs     │
  └─────────────────────────────────┬────────────────────────────────┘
                                    │
                                    ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │ 3. Daily Concept Examination (10–15 Minutes)                     │
  │    - Interactive, day-appropriate web exam (`quiz.html`)         │
  │    - 10 randomized scenario questions from a 20-question pool    │
  │    - Instant scoring, mistake highlighting & full rationale      │
  │    - Passing target: 80% (8 of 10)                               │
  └─────────────────────────────────┬────────────────────────────────┘
                                    │
                                    ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │ 4. Weekly Lab Challenge & Automated Test Suite (Sprint Finale)   │
  │    - Objective scenario challenge with starter template          │
  │    - Bash test runner (`test_sprintXX.sh`)                       │
  │    - Must achieve 100% green pass rate to graduate sprint        │
  └──────────────────────────────────────────────────────────────────┘
```

### Daily Components Defined
1. **Dedicated Daily Guide (`DAY_XX.md`):** Standalone markdown document containing concise architectural diagrams, exact terminal commands, code snippets, and observation prompts.
2. **Curated 20-Question Pools ([`data/quizzes.json`](data/quizzes.json)):** One file holding every pool, organized by sprint, then by day. Each question is tagged with a `type`. From Sprint 2 on, each pool targets 8 `scenario`, 6 `config` (read a config, predict the result), 3 `diagnose` (symptom or log line to cause), and 3 `recall` questions.
3. **Quiz Engine ([`quiz.html`](quiz.html)):** One page for every quiz (`quiz.html?sprint=2&day=1`). It draws 10 of 20 at random and shows explanations immediately. It reads `data/quizzes.json`, so serve the repo over HTTP (`python3 -m http.server 8090`).
4. **Objective Test Suite (`test_sprintXX.sh`):** Zero-ambiguity assertion script checking HTTP status codes, headers, response payloads, and security boundaries.

---

## 3. The 14-Week Master Sprint Roadmap

### Calendar Schedule Overview (FY27 Q1)
* **Start Date:** Thursday, October 1
* **End Date:** Thursday, December 31
* **Holiday Blackouts:**
  * Thanksgiving: Thursday, Nov 26 & Friday, Nov 27 (Sprint 9's three sessions fit Nov 23–25).
  * Christmas: Thursday, Dec 24 & Friday, Dec 25 (Sprint 13's three sessions fit Dec 21–23).

```
OCTOBER                                NOVEMBER                               DECEMBER
S01: Oct 1-2   (2d - Web Serving)     S06: Nov 2-6   (3d - Programmability)  S10: Nov 30-Dec 4 (3d - Advanced Ingress)
S02: Oct 6-9   (4d - Reverse Proxy)   S07: Nov 9-13  (3d - Security/JWT)     S11: Dec 7-11     (3d - Observability)
S03: Oct 12-16 (3d - TLS & HTTP/3)    S08: Nov 16-20 (3d - K8s Ingress CRDs) S12: Dec 14-18    (3d - High Availability)
S04: Oct 19-23 (3d - Performance)     S09: Nov 23-25 (3d - Gateway API)      S13: Dec 21-23    (3d - Edge WAF)
S05: Oct 26-30 (3d - Rate Limiting)   [Nov 26-27: Thanksgiving Break]        [Dec 24-25: Christmas Break]
                                                                             S14: Dec 28-31    (3d - Capstone)
```

---

### Sprint Master Matrix

| Sprint | Dates | Days | Core Focus & Architecture | Lab Challenge Target | Enterprise / F5 Side Quest |
| :--- | :--- | :---: | :--- | :--- | :--- |
| **01** | Oct 1–2 | 2 | **Web Serving & Core Engine:** Master/worker model, Unix signals (`HUP`, `QUIT`), `epoll` loop, 5-step location precedence, `root` vs `alias`, SPA `try_files`. | Northwind Static Web Tier (`test_sprint01.sh`) | **Zero-Downtime Hot-Upgrade:** Live binary swap via `SIGUSR2` & `nginx.pid.oldbin` (Deck: Slides 10–13). |
| **02** | Oct 6–9 | 4 | **Reverse Proxy & Load Balancing:** Trailing slash URI rules, header forwarding (`X-Forwarded-*`), balancing algorithms, passive health checks (`max_fails`), WebSocket proxying. | Multi-tier Load Balancer with WebSocket Relay (`test_sprint02.sh`) | **NGINX Plus Upstream API:** Real-time pool add/drain/remove without reload, `state` persistence, `slow_start` (Deck: Slide 54). Active probes: Sprint 12. |
| **03** | Oct 12–16 | 3 | **TLS Termination & Edge Hardening:** TLS 1.3 cipher suites, dual RSA/ECDSA certificates, SNI, session resumption, ALPN, HTTP/2 multiplexing, HTTP/3 (QUIC/UDP), strict security headers. | Lumina Zero-Trust Edge (`test_sprint03.sh`) | **Certificates Without Reloads or Humans:** NGINX Plus key-value certificates rotated via API, and ACME issuance with `nginx-module-acme` against a Pebble test CA. |
| **04** | Oct 19–23 | 3 | **Performance, Caching & Kernel:** Dual-tier micro-caching (`proxy_cache`), cache locks, stale serving on error, Linux `sysctl` socket tuning (`somaxconn`, `tcp_tw_reuse`). | High-Throughput Cached API Gateway | **NGINX Plus Live Cache Purging:** Instant selective cache purge API without disk clearing. |
| **05** | Oct 26–30 | 3 | **Traffic Shaping & Rate Limiting:** Leaky bucket rate limiting (`limit_req`), burst handling, two-stage delay, concurrency limits (`limit_conn`), bandwidth (`limit_rate`), slow-client timeouts, IP allowlists/denylists and tiers, real client addresses behind a load balancer. | Lumina API Gateway (`test_sprint05.sh`) | **A Live Denylist and Cluster-Wide Limits:** NGINX Plus key-value denylist changed through the API with no reload, and `zone_sync` sharing limits across a two-node cluster. |
| **06** | Nov 2–6 | 3 | **Programmability & Extensibility:** JavaScript scripting via NGINX JavaScript (`njs`), custom header enrichment, dynamic URI rewriting, conditional upstream routing. | Smart Routing Proxy with njs Validation | **Native Lua / OpenResty vs. njs:** Memory model, safety boundaries, and C-module extensions. |
| **07** | Nov 9–13 | 3 | **Security Hardening & Modern Auth:** Mutual TLS (mTLS), client certificate verification, subrequest authentication (`auth_request`), OAuth2 proxy integration. | Zero-Trust Perimeter Gateway with mTLS | **NGINX Plus Native JWT & OIDC:** In-engine cryptographic JWT signature validation & Keycloak OIDC (NIC Lab 3). |
| **08** | Nov 16–20 | 3 | **Kubernetes Ingress Architecture:** Ingress controllers vs NodePorts, F5 NGINX Ingress Controller (NIC), `VirtualServer` / `VirtualServerRoute` CRDs, traffic splitting. | Multi-Tenant Microservices Ingress | **Enterprise VirtualServer Policies:** Rate limiting, circuit breaking, and blue/green splits (NIC Labs 1, 2, 4). |
| **09** | Nov 23–25 | 3 | **Next-Gen K8s Gateway API:** Gateway API evolution, `GatewayClass`, `Gateway`, `HTTPRoute`, `GRPCRoute`, header-based routing, cross-namespace routing. | Gateway Fabric Multi-Route Service | **GenAI LLM Inference Extensions:** Prompt routing and model endpoint load balancing (NGF Lab 10). |
| **10** | Nov 30–Dec 4 | 3 | **Hybrid & Advanced Enterprise Ingress:** Multi-cluster routing, gRPC microservice streaming, header transformations, ExternalDNS automation. | End-to-End gRPC & HTTP/2 Microservices Fabric | **BIG-IP CIS + GatewayLink:** External BIG-IP hardware driving traffic to internal Gateway Fabric (NGF Lab 13). |
| **11** | Dec 7–11 | 3 | **Production Observability & Telemetry:** Custom structured JSON logging, distributed tracing (OpenTelemetry / W3C `traceparent`), Prometheus metrics exporter, plus `node_exporter` so host/kernel counters share the dashboard. | Full-Stack Observability Pipeline | **NGINX Plus Live Monitoring Dashboard & NGINX One Console:** Real-time HTTP/TCP stats console and JSON telemetry API for one instance, then fleet-level visibility and config management through NGINX One. |
| **12** | Dec 14–18 | 3 | **High Availability & Fault Resilience:** Keepalived VRRP active/passive pairing, passive failover tuning, upstream keepalive pooling, graceful error masking. | Resilient Dual-Node Edge Cluster | **Active Application Health Checks:** Proactive periodic synthetic probing with custom string validation (Deck: Slide 54). |
| **13** | Dec 21–23 | 3 | **Edge Security & Web App Firewalls:** OWASP Top 10 mitigation via NGINX, ModSecurity OSS engine integration, SQLi/XSS inspection, request body inspection limits. | Hardened Security Gateway with Signature Rules | **F5 App Protect WAF:** High-performance compiled WAF engine, DataGuard PII masking, custom attack signatures (NIC Labs 6, 7). |
| **14** | Dec 28–31 | 3 | **Capstone Architecture & Production Deployment:** Production packaging (distroless containers, Helm charts), automated CI/CD config validation, disaster recovery. | Fully Packaged Cloud-Native Production Platform | **The Enterprise Review:** End-to-end architecture review presentation for technical peers and leadership. |

---

## 4. Deep-Dive Sprint Summaries

### Sprint 1: Web Serving Mastery & Core Architecture (Oct 1–2, 2 Days)
* **Focus:** Demystify the event loop and process hierarchy before touching reverse proxying.
* **Daily Structure:**
  * **Day 1:** Master/Worker least-privilege architecture, Unix signals (`HUP`, `QUIT`, `TERM`, `USR1`), `nginx -V`/`-t`/`-T`, zero-downtime hot-swap (`SIGUSR2`). Quiz: [Day 1 Quiz](quiz.html?sprint=1&day=1).
  * **Day 2:** 5-step location precedence (`=`, `^~`, `~*`, prefix fallback), `root` vs `alias` path math, SPA `try_files` routing, dotfile blocking, `server_tokens off`. Quiz: [Day 2 Quiz](quiz.html?sprint=1&day=2).
* **Lab:** Northwind Static Foundation validated by [`test_sprint01.sh`](sprints/sprint-1/test_sprint01.sh) (12 assertions).

### Sprint 2: Reverse Proxying & Load Balancing (Oct 6–9, 4 Days)
* **Focus:** Layer 7 request routing, header management, upstream connection pooling, and balancing.
* **Key Topics:** The trailing slash proxy rule (`proxy_pass http://backend/` vs `http://backend`), `proxy_set_header` inheritance gotchas, load balancing algorithms (`round_robin`, `least_conn`, `ip_hash`, `hash $request_uri consistent`), passive failover (`max_fails`, `fail_timeout`), upstream keepalive pooling, and WebSocket proxying (`Upgrade` / `Connection` hop-by-hop headers).
* **Daily Structure:**
  * **Day 1:** How `proxy_pass` builds the request: URI mapping, header rewriting, `proxy_set_header` inheritance.
  * **Day 2:** Upstream pools, balancing algorithms, keepalive pooling (on by default since nginx 1.29.7).
  * **Day 3:** Passive health checks, timeouts, retries & idempotency, WebSockets; Lumina lab completed.
  * **Day 4 (Enterprise):** NGINX Plus upstream API (runtime add/drain/remove, `zone`, `slow_start`, `state` files). Active probes are deferred to Sprint 12.
* **Lab:** Multi-tier load balancer proxying 3 mock backends with WebSocket streaming (`test_sprint02.sh`, 8 core assertions). Details: [`sprints/sprint-2/README.md`](sprints/sprint-2/README.md).

### Sprint 3: TLS Termination, HTTP/2, HTTP/3 & Edge Security (Week of Oct 12, 3 Days)
* **Focus:** Cryptographic termination, modern protocols, and browser-facing security policy, layered onto the Sprint 2 Lumina gateway.
* **Daily Structure:**
  * **Day 1:** TLS termination. The client SSL profile mapped onto `ssl_*`, the two cipher knobs (`ssl_ciphers` vs `ssl_conf_command Ciphersuites`), dual RSA/ECDSA certificates, SNI and `ssl_reject_handshake`, session cache vs tickets across reloads. Quiz: [Day 1 Quiz](quiz.html?sprint=3&day=1).
  * **Day 2:** ALPN and `http2 on`, multiplexing and HPACK measured in the access log, client vs upstream protocol, HTTP/3 over QUIC with `reuseport` and `Alt-Svc`, per-socket default servers. Quiz: [Day 2 Quiz](quiz.html?sprint=3&day=2).
  * **Day 3:** Security headers (HSTS, `nosniff`, framing, CSP), `add_header ... always` and inheritance, hiding leaks, then the sprint lab. Quiz: [Day 3 Quiz](quiz.html?sprint=3&day=3).
* **Enterprise Side Quest (optional, Day 3):** NGINX Plus key-value certificates rotated through the API with no reload, and ACME issuance with `nginx-module-acme` against a Pebble test CA. Optional quiz: [Enterprise Quiz](quiz.html?sprint=3&day=3&pool=enterprise).
* **Lab:** Lumina Zero-Trust Edge validated by `test_sprint03.sh` (13 assertions). Details: [`sprints/sprint-3/README.md`](sprints/sprint-3/README.md).

### Sprint 4: Performance Engineering, Caching & Kernel Tuning (Oct 19–23, 3 Days)
* **Focus:** Maximizing throughput and minimizing origin latency through caching and kernel tuning.
* **Key Topics:** `proxy_cache_path` memory keys zones vs disk storage, cache keys (`$scheme$proxy_host$request_uri`), `proxy_cache_use_stale updating error timeout`, `proxy_cache_lock` to eliminate cache stampedes, Linux `sysctl` socket tuning (`net.core.somaxconn`, `net.ipv4.tcp_tw_reuse`, `epoll` socket limits).
* **Daily Structure:**
  * **Day 1:** The edge cache. Keys zone vs disk, which origin headers decide the lifetime, the cache key and `Host`, `Authorization` with `proxy_cache_bypass` vs `proxy_no_cache`, `$upstream_cache_status`. Quiz: [Day 1 Quiz](quiz.html?sprint=4&day=1).
  * **Day 2:** The cache under pressure. `proxy_cache_lock` and its limits, `proxy_cache_use_stale`, background update, revalidation, measuring the tail and the origin with `oha`. Quiz: [Day 2 Quiz](quiz.html?sprint=4&day=2).
  * **Day 3:** Kernel and connection limits. Accept queue (`backlog`, `somaxconn`, overflows), `reuseport`, `worker_rlimit_nofile`, ephemeral ports, TIME_WAIT and `tcp_tw_reuse`, then the sprint lab. Quiz: [Day 3 Quiz](quiz.html?sprint=4&day=3).
* **Enterprise Side Quest (optional, Day 3):** NGINX Plus cache purging with `proxy_cache_purge` (a `PURGE` request on the data plane, including wildcards), and cache metrics from the Plus API. Optional quiz: [Enterprise Quiz](quiz.html?sprint=4&day=3&pool=enterprise).
* **Lab:** Lumina Edge Accelerator, in containers, validated by `test_sprint04.sh` (10 assertions). Details: [`sprints/sprint-4/README.md`](sprints/sprint-4/README.md).

### Sprint 5: Traffic Control, Rate Limiting & Concurrency (Oct 26–30, 3 Days)
* **Focus:** Edge protection against traffic spikes, abusive clients, slow clients and denial-of-service, with policy that depends on who the client really is.
* **Daily Structure:**
  * **Day 1:** Rate limiting and the leaky bucket. `limit_req_zone` / `limit_req`, the rate as a minimum gap, `burst` with a queue, `nodelay` or `delay=`, keys and the empty key, stacking and inheritance, `limit_req_status 429` and `Retry-After`, dry run, zone sizing. Quiz: [Day 1 Quiz](quiz.html?sprint=5&day=1).
  * **Day 2:** Concurrency, bandwidth and slow clients. `limit_conn` (requests in progress, HTTP/2 streams), a cap for the origin, `limit_rate` and `limit_rate_after`, slowloris vs slow POST timeouts, request buffering, `client_max_body_size`. Quiz: [Day 2 Quiz](quiz.html?sprint=5&day=2).
  * **Day 3:** Who gets in. `allow`/`deny` and the phase order, `geo` and `map` tiers, exemption by empty key, the realip module behind a load balancer, then the sprint lab. Quiz: [Day 3 Quiz](quiz.html?sprint=5&day=3).
* **Enterprise Side Quest (optional, Day 3):** a two-node NGINX Plus cluster. A `type=ip` key-value denylist changed through the API with no reload, and `zone_sync` sharing the denylist and a rate limit between the nodes. Optional quiz: [Enterprise Quiz](quiz.html?sprint=5&day=3&pool=enterprise). (Bandwidth throttling, first planned as the side quest, is open source and moved into Day 2.)
* **Lab:** Lumina API Gateway, in containers with a client that sends from any lab address, validated by `test_sprint05.sh` (13 assertions). Details: [`sprints/sprint-5/README.md`](sprints/sprint-5/README.md).

### Sprint 6: Programmability & Extensibility (Nov 2–6, 3 Days)
* **Focus:** Custom business logic at the edge with the NGINX JavaScript engine (njs 1.0.1), and knowing when a native directive is the better tool.
* **Daily Structure:**
  * **Day 1:** How njs runs. A module inside the worker, compiled at configuration load; `js_content`, `js_set` (once per request, only when used), the two engines (`njs`: a fresh context per request; QuickJS: reused contexts, globals per worker), the JavaScript the default engine supports, exceptions as `500`, decoding vs verifying. Quiz: [Day 1 Quiz](quiz.html?sprint=6&day=1).
  * **Day 2:** Signatures, bodies and shared state. HMAC/JWT checks with a key passed through `env`, `secure_link` vs njs signed links, `X-User` and spoofing, `js_header_filter`/`js_body_filter` and `Content-Length`, request-body validation with `internalRedirect`, `ngx.fetch` + `js_periodic` + `js_shared_dict_zone` as a revocation feed. Quiz: [Day 2 Quiz](quiz.html?sprint=6&day=2).
  * **Day 3:** Routing on a verified cookie claim (`proxy_pass http://$pool`), stream njs (`js_preread`, `preread_timeout`, native `ssl_preread`), what a blocking script costs, native vs script, then the sprint lab. Quiz: [Day 3 Quiz](quiz.html?sprint=6&day=3).
* **Enterprise Side Quest:** moves to the **Side Quest Gauntlet** below: njs with the NGINX Plus key-value store and API, and njs compared with OpenResty/Lua (performance, memory footprints, and security attack surfaces).
* **Lab:** Lumina Edge Functions, in containers, validated by `test_sprint06.sh` (10 assertions). Details: [`sprints/sprint-6/README.md`](sprints/sprint-6/README.md).

### Side Quest Gauntlet: Sprints 4–6 (after Sprint 6)
* **Format:** [The Black Friday War Room](gauntlet/black-friday/README.md): one long session (about 2–2.5 hours) that combines the Sprint 4, 5 and 6 enterprise side quests. Northwind's storefront runs on two edge nodes behind a load balancer. Incidents arrive as nine tickets, each checked automatically and scored on a scoreboard (no clock). It's self-contained, so it can be released as a community challenge and written up as a blog post.
* **Stages:**
  * **The Cache (Sprint 4):** invalidating one page and a whole section on both nodes, and cache metrics.
  * **Who Gets In (Sprint 5):** a denylist that changes all night, an exception inside it, and one rate limit for two nodes.
  * **Code at the Edge (Sprint 6):** njs verifying a signed cookie with a VIP list that changes live, then njs vs Lua on OpenResty in a benchmark.
  * **Midnight:** every fix again, under load.
* **Editions:** both are public. The open source edition solves every ticket with OSS tools (cache-key generations, `geo` files, client affinity, njs shared memory). The NGINX Plus edition, for anyone with a trial or full license, uses `proxy_cache_purge`, the API, `keyval` and `zone_sync`.
* **Quiz:** [Gauntlet Quiz](quiz.html?sprint=6&day=3&pool=gauntlet), 20 questions across both editions.

### Sprint 7: Security Hardening & Zero Trust (Nov 9–13, 3 Days)
* **Focus:** Identity at the edge: who a partner, a tool user and a staff member is, and who decides what they may do.
* **Daily Structure:**
  * **Day 1:** Mutual TLS, both ways. `ssl_client_certificate` and `ssl_verify_client` (`on`, `optional`, `optional_no_ca`, and the 495/496 refusals), certificate variables into headers (and the missing SAN variable), identity only from a verified certificate, CRLs that need a reload and expire, and the edge as a TLS client (`proxy_ssl_certificate`, `proxy_ssl_verify`, `proxy_ssl_name`) against an impostor upstream. Quiz: [Day 1 Quiz](quiz.html?sprint=7&day=1).
  * **Day 2:** Subrequest authorization with `auth_request`. Status handling, `auth_request_set`, what the authorization service actually sees (pass the method), failing closed, caching decisions with a key that holds every input, and `satisfy any`. Quiz: [Day 2 Quiz](quiz.html?sprint=7&day=2).
  * **Day 3:** Single sign-on with OAuth2 Proxy and Keycloak. The OIDC code flow with PKCE, one issuer reached through two channels, OAuth2 Proxy behind `auth_request`, username vs `sub`, the session cookie kept from the application, group checks, and a sign-out that isn't one; then the sprint lab. Quiz: [Day 3 Quiz](quiz.html?sprint=7&day=3).
* **Enterprise Side Quest:** NGINX Plus native JWT validation (`auth_jwt` with Keycloak's JWKS, audience and group checks) and native OpenID Connect (`oidc_provider`, `auth_oidc`) replacing OAuth2 Proxy: [guide](sprints/sprint-7/day_03_enterprise.md), [Enterprise Quiz](quiz.html?sprint=7&day=3&pool=enterprise).
* **Lab:** The Tidewater Edge, in containers with Keycloak 26 and OAuth2 Proxy 7, validated by `test_sprint07.sh` (10 assertions). Details: [`sprints/sprint-7/README.md`](sprints/sprint-7/README.md).

### Sprint 8: Modern Kubernetes Ingress (Nov 16–20, 3 Days)
* **Focus:** Bridging NGINX into Kubernetes container networking.
* **Key Topics:** Kubernetes networking fundamentals (Services, Endpoints, CNI), Ingress Controller architecture, standard community Ingress vs. F5 NGINX Ingress Controller (NIC), F5 CRDs (`VirtualServer`, `VirtualServerRoute`), traffic splitting, and zero-downtime pod endpoint updates.
* **Enterprise Side Quest:** F5 NIC Enterprise policies: rate limiting CRDs, active circuit breaking, and canary deployments.

### Sprint 9: Next-Gen Kubernetes Gateway API (Nov 23–25, 3 Days - Thanksgiving Week)
* **Focus:** The successor to Kubernetes Ingress: the official Kubernetes Gateway API.
* **Key Topics:** Role-oriented API architecture (Infrastructure Provider $\to$ Cluster Operator $\to$ Application Developer), `GatewayClass`, `Gateway`, `HTTPRoute`, `GRPCRoute`, cross-namespace routing, and NGINX Gateway Fabric (NGF) architecture.
* **Enterprise Side Quest:** GenAI LLM Inference Extensions: routing prompts across multiple LLM backends based on model parameters and latency.

### Sprint 10: Advanced Microservices & Enterprise Ingress (Nov 30–Dec 4, 3 Days)
* **Focus:** High-throughput microservice communication and hybrid infrastructure connectivity.
* **Key Topics:** End-to-end gRPC streaming through NGINX (`grpc_pass`), HTTP/2 upstream multiplexing, header rewriting at scale, and external DNS automation.
* **Enterprise Side Quest:** F5 BIG-IP CIS + GatewayLink: combining external F5 BIG-IP hardware load balancers with internal NGINX Gateway Fabric for automated end-to-end traffic delivery.

### Sprint 11: Production Observability & Telemetry (Dec 7–11, 3 Days)
* **Focus:** Deep visibility into network traffic, latencies, and distributed requests.
* **Key Topics:** Custom JSON access logging with high-resolution timing (`$request_time`, `$upstream_connect_time`, `$upstream_response_time`), OpenTelemetry distributed tracing module, injecting W3C `traceparent` headers, and Prometheus metric exporters. Host and kernel metrics through `node_exporter` (accept queue overflows, TIME_WAIT, open file descriptors from Sprint 4 Day 3) on the same Grafana dashboard as the NGINX metrics.
* **Enterprise Side Quest:** NGINX Plus Live Activity Monitoring and the NGINX One Console.
  * **One instance:** the real-time graphical dashboard and live JSON metrics feed.
  * **The fleet:** NGINX One Console connected through the NGINX Agent (`nginx-plus/agent` image plus a data plane key): instance inventory, config drift, CVE and certificate status, and pushing config centrally. The closest NGINX analog to BIG-IQ.

### Sprint 12: High Availability & Fault Resilience (Dec 14–18, 3 Days)
* **Focus:** Eliminating single points of failure and engineering self-healing systems.
* **Key Topics:** Active/passive failover using Keepalived and Virtual Router Redundancy Protocol (VRRP), shared floating virtual IPs (VIP), tuning connection timeouts (`proxy_connect_timeout`), handling backend connection resets gracefully, and error masking.
* **Enterprise Side Quest:** NGINX Plus active health checks: periodic out-of-band application probes with custom response body pattern matching.

### Sprint 13: Edge Security & Web Application Firewalls (Dec 21–23, 3 Days - Christmas Week)
* **Focus:** Layer 7 application protection, payload inspection, and vulnerability mitigation.
* **Key Topics:** OWASP Top 10 threat modeling, ModSecurity OSS engine integration with Core Rule Set (CRS), request body inspection limits, and tuning false positives.
* **Enterprise Side Quest:** F5 App Protect WAF: high-performance native compiled engine, DataGuard credit card/SSN masking, and precompiled policy deployment.

### Sprint 14: Capstone Architecture & Production Packaging (Dec 28–31, 3 Days)
* **Focus:** Consolidating all 13 sprints into a production-grade, shareable learning platform and deployment artifact.
* **Key Topics:** Multi-stage Docker builds, distroless minimal container images, writing a complete Helm chart with production values, automated configuration validation in CI/CD, and disaster recovery procedures.
* **Enterprise Side Quest:** The Executive Review: presenting the journey outcomes, architectural lessons, and ROI comparison between NGINX OSS and NGINX Plus to technical peers.

---

## 5. Assessment & Graduation Criteria

To maintain rigor, advancement through the journey requires passing two objective benchmarks:

```
                          GRADUATION CRITERIA
  ┌──────────────────────────────────────────────────────────────────┐
  │ 1. Continuous Concept Mastery                                    │
  │    Score >= 80% on each day's 10-question randomized concept     │
  │    examination before concluding the sprint.                     │
  ├──────────────────────────────────────────────────────────────────┤
  │ 2. Automated Lab Verification                                    │
  │    Execute the sprint's `test_sprintXX.sh` script against your   │
  │    running configuration and achieve 100% green pass rate across │
  │    all curl/network assertions.                                  │
  ├──────────────────────────────────────────────────────────────────┤
  │ 3. Engineering Journal                                           │
  │    Record key production gotchas, syntax rules, and architectural│
  │    discoveries in your sprint markdown notes.                    │
  └──────────────────────────────────────────────────────────────────┘
```

---

## 6. Execution Environment & Lab Topology

The entire 14-week journey is engineered to run seamlessly on a **single 4 vCPU / 8 GB RAM Ubuntu instance** (e.g., AWS `c5.large` or an F5 UDF virtual machine):

```
[ Engineer Workstation / Browser ]
       │
       ├────► Ports 8081–8098 ─► Sprint labs
       │                        - Sprints 1–3: host NGINX, run from each sprint's lab/
       │                        - Sprint 4 on: NGINX and backends in containers (lab.sh)
       │
       ├────► Port 8090 ──────► Quiz page (python3 -m http.server)
       │
       └────► Port 80/443 ────► Ephemeral `kind` Cluster (Kubernetes Lab Sandboxes)
                                - NGINX Ingress Controller / Gateway Fabric
                                - Can be torn down and rebuilt (`kind delete cluster`)
```

* **Memory Budget:**
  * Host OS & Docker Daemon: ~1.2 GB
  * Sprint lab containers (Sprints 4–6): well under 0.5 GB; Sprint 7 adds Keycloak, about 0.7 GB in all
  * Ephemeral `kind` Node (Sprints 8–10): ~2.5 GB
  * **Free Headroom:** ~4.0 GB (plus recommended 4 GB swapfile for buffer safety).

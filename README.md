# NGINX Learning Journey
**Timeframe:** FY27 Q1 (October 1 – December 31)  
**Target Cadence:** 14 Sprints, roughly one per week (days per sprint flex with the calendar)  
**Primary Engine:** Open Source NGINX (OSS)  
**Side Quests: Enterprise Trail:** NGINX Plus, F5 App Protect WAF, F5 NGINX Ingress Controller, and NGINX Gateway Fabric  

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

Each sprint day is engineered as a focused, high-impact **45 to 60-minute hands-on discovery session**. Rather than passive reading, learning is driven by a 4-phase pedagogical loop:

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
3. **Quiz Engine ([`quiz.html`](quiz.html)):** One page for every quiz (`quiz.html?sprint=2&day=1`). It draws 10 of 20 at random and shows explanations immediately. It reads `data/quizzes.json`, so serve the repo over HTTP (`python3 -m http.server 8090`). The learning dashboard will take this over.
4. **Objective Test Suite (`test_sprintXX.sh`):** Zero-ambiguity assertion script checking HTTP status codes, headers, response payloads, and security boundaries.

---

## 3. The 14-Week Master Sprint Roadmap

### Calendar Schedule Overview (FY27 Q1)
* **Start Date:** Thursday, October 1
* **End Date:** Thursday, December 31
* **Holiday Blackouts:**
  * Thanksgiving: Thursday, Nov 26 & Friday, Nov 27 (Sprint 9 adjusted to 3 business days).
  * Christmas: Thursday, Dec 24 & Friday, Dec 25 (Sprint 13 adjusted to 3 business days).

```
OCTOBER                                NOVEMBER                               DECEMBER
S01: Oct 1-2   (2d - Web Serving)     S06: Nov 2-6   (5d - Programmability)  S10: Nov 30-Dec 4 (5d - Advanced Ingress)
S02: Oct 6-9   (4d - Reverse Proxy)   S07: Nov 9-13  (5d - Security/JWT)     S11: Dec 7-11     (5d - Observability)
S03: Oct 12-16 (5d - TLS & HTTP/3)    S08: Nov 16-20 (5d - K8s Ingress CRDs) S12: Dec 14-18    (5d - High Availability)
S04: Oct 19-23 (5d - Performance)     S09: Nov 23-25 (3d - Gateway API)      S13: Dec 21-23    (3d - Edge WAF)
S05: Oct 26-30 (5d - Rate Limiting)   [Nov 26-27: Thanksgiving Break]        [Dec 24-25: Christmas Break]
                                                                             S14: Dec 28-31    (4d - Capstone)
```

---

### Sprint Master Matrix

| Sprint | Dates | Days | Core Focus & Architecture | Lab Challenge Target | Enterprise / F5 Side Quest |
| :--- | :--- | :---: | :--- | :--- | :--- |
| **01** | Oct 1–2 | 2 | **Web Serving & Core Engine:** Master/worker model, Unix signals (`HUP`, `QUIT`), `epoll` loop, 5-step location precedence, `root` vs `alias`, SPA `try_files`. | Northwind Static Web Tier (`test_sprint01.sh`) | **Zero-Downtime Hot-Upgrade:** Live binary swap via `SIGUSR2` & `nginx.pid.oldbin` (Deck: Slides 10–13). |
| **02** | Oct 6–9 | 4 | **Reverse Proxy & Load Balancing:** Trailing slash URI rules, header forwarding (`X-Forwarded-*`), balancing algorithms, passive health checks (`max_fails`), WebSocket proxying. | Multi-tier Load Balancer with WebSocket Relay (`test_sprint02.sh`) | **NGINX Plus Upstream API:** Real-time pool add/drain/remove without reload, `state` persistence, `slow_start` (Deck: Slide 54). Active probes: Sprint 12. |
| **03** | Oct 12–16 | 5 | **TLS Termination & Edge Hardening:** TLS 1.3 cipher suites, session resumption, ALPN, HTTP/2 multiplexing, HTTP/3 (QUIC/UDP), strict security headers. | Zero-Trust TLS 1.3 / HTTP/3 Edge Gateway | **Automated Cert Management:** ACME vault integration & dual RSA/ECC cipher deployment. |
| **04** | Oct 19–23 | 5 | **Performance, Caching & Kernel:** Dual-tier micro-caching (`proxy_cache`), cache locks, stale serving on error, Linux `sysctl` socket tuning (`somaxconn`, `tcp_tw_reuse`). | High-Throughput Cached API Gateway | **NGINX Plus Live Cache Purging:** Instant selective cache purge API without disk clearing. |
| **05** | Oct 26–30 | 5 | **Traffic Shaping & Rate Limiting:** Leaky bucket rate limiting (`limit_req`), burst handling, two-stage delay, concurrency limits (`limit_conn`), IP allowlists/denylists. | DDoS-Resilient API Rate-Limiter | **Dynamic Bandwidth Control:** Client bandwidth slicing and progressive download throttling. |
| **06** | Nov 2–6 | 5 | **Programmability & Extensibility:** JavaScript scripting via NGINX JavaScript (`njs`), custom header enrichment, dynamic URI rewriting, conditional upstream routing. | Smart Routing Proxy with njs Validation | **Native Lua / OpenResty vs. njs:** Memory model, safety boundaries, and C-module extensions. |
| **07** | Nov 9–13 | 5 | **Security Hardening & Modern Auth:** Mutual TLS (mTLS), client certificate verification, subrequest authentication (`auth_request`), OAuth2 proxy integration. | Zero-Trust Perimeter Gateway with mTLS | **NGINX Plus Native JWT & OIDC:** In-engine cryptographic JWT signature validation & Keycloak OIDC (NIC Lab 3). |
| **08** | Nov 16–20 | 5 | **Kubernetes Ingress Architecture:** Ingress controllers vs NodePorts, F5 NGINX Ingress Controller (NIC), `VirtualServer` / `VirtualServerRoute` CRDs, traffic splitting. | Multi-Tenant Microservices Ingress | **Enterprise VirtualServer Policies:** Rate limiting, circuit breaking, and blue/green splits (NIC Labs 1, 2, 4). |
| **09** | Nov 23–25 | 3 | **Next-Gen K8s Gateway API:** Gateway API evolution, `GatewayClass`, `Gateway`, `HTTPRoute`, `GRPCRoute`, header-based routing, cross-namespace routing. | Gateway Fabric Multi-Route Service | **GenAI LLM Inference Extensions:** Prompt routing and model endpoint load balancing (NGF Lab 10). |
| **10** | Nov 30–Dec 4 | 5 | **Hybrid & Advanced Enterprise Ingress:** Multi-cluster routing, gRPC microservice streaming, header transformations, ExternalDNS automation. | End-to-End gRPC & HTTP/2 Microservices Fabric | **BIG-IP CIS + GatewayLink:** External BIG-IP hardware driving traffic to internal Gateway Fabric (NGF Lab 13). |
| **11** | Dec 7–11 | 5 | **Production Observability & Telemetry:** Custom structured JSON logging, distributed tracing (OpenTelemetry / W3C `traceparent`), Prometheus metrics exporter. | Full-Stack Observability Pipeline | **NGINX Plus Live Monitoring Dashboard:** Real-time HTTP/TCP visual stats console & JSON telemetry API. |
| **12** | Dec 14–18 | 5 | **High Availability & Fault Resilience:** Keepalived VRRP active/passive pairing, passive failover tuning, upstream keepalive pooling, graceful error masking. | Resilient Dual-Node Edge Cluster | **Active Application Health Checks:** Proactive periodic synthetic probing with custom string validation (Deck: Slide 54). |
| **13** | Dec 21–23 | 3 | **Edge Security & Web App Firewalls:** OWASP Top 10 mitigation via NGINX, ModSecurity OSS engine integration, SQLi/XSS inspection, request body inspection limits. | Hardened Security Gateway with Signature Rules | **F5 App Protect WAF:** High-performance compiled WAF engine, DataGuard PII masking, custom attack signatures (NIC Labs 6, 7). |
| **14** | Dec 28–31 | 4 | **Capstone Architecture & Production Deployment:** Production packaging (distroless containers, Helm charts), automated CI/CD config validation, disaster recovery. | Fully Packaged Cloud-Native Production Platform | **The Enterprise Review:** End-to-end architecture review presentation for technical peers and leadership. |

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

### Sprint 3: TLS Termination, HTTP/2, HTTP/3 & Edge Security (Oct 12–16, 5 Days)
* **Focus:** Cryptographic termination, modern protocols, and transport layer security.
* **Key Topics:** TLS 1.3 cipher suite configuration, session resumption (tickets vs cache), ALPN negotiation, HTTP/2 stream multiplexing and HPACK header compression, HTTP/3 (QUIC over UDP) with `listen 443 quic reuseport`, and security headers (HSTS, CSP, X-Frame-Options).
* **Enterprise Side Quest:** Automated enterprise certificate lifecycle management and dual RSA/ECC cert delivery.

### Sprint 4: Performance Engineering, Caching & Kernel Tuning (Oct 19–23, 5 Days)
* **Focus:** Maximizing throughput and minimizing origin latency through caching and kernel tuning.
* **Key Topics:** `proxy_cache_path` memory keys zones vs disk storage, cache keys (`$scheme$proxy_host$request_uri`), `proxy_cache_use_stale updating error timeout`, `proxy_cache_lock` to eliminate cache stampedes, Linux `sysctl` socket tuning (`net.core.somaxconn`, `net.ipv4.tcp_tw_reuse`, `epoll` socket limits).
* **Enterprise Side Quest:** NGINX Plus programmatic cache purging via REST API (`PURGE /api/cache/...`).

### Sprint 5: Traffic Control, Rate Limiting & Concurrency (Oct 26–30, 5 Days)
* **Focus:** Edge protection against traffic spikes, abusive clients, and denial-of-service.
* **Key Topics:** Leaky bucket algorithm via `limit_req_zone`, burst handling and smoothing with `nodelay` and `delay`, concurrent connection limiting (`limit_conn_zone`), dynamic status code configuration (`limit_req_status 429`), and GeoIP/CIDR allowlists.
* **Enterprise Side Quest:** Advanced client bandwidth slicing and media streaming progressive download rate limits.

### Sprint 6: Programmability & Extensibility (Nov 2–6, 5 Days)
* **Focus:** Custom business logic at the edge using the NGINX JavaScript (`njs`) engine.
* **Key Topics:** The `njs` execution model (synchronous, VM-per-request, memory safety), `js_import` and `js_set`, inspecting request/response headers and bodies, generating dynamic HMAC signatures, and conditional upstream routing based on cookie claims.
* **Enterprise Side Quest:** Comparing `njs` with native OpenResty/Lua: performance, memory footprints, and security attack surfaces.

### Sprint 7: Security Hardening & Zero Trust (Nov 9–13, 5 Days)
* **Focus:** Identity verification, client authentication, and access control.
* **Key Topics:** Mutual TLS (mTLS) with `ssl_client_certificate` and `ssl_verify_client on`, extracting client certificate CN/SAN attributes into headers, subrequest authentication with `auth_request`, and integrating OAuth2 Proxy.
* **Enterprise Side Quest:** NGINX Plus native JWT validation (`auth_jwt`) and OpenID Connect (OIDC) integration against Keycloak / Okta.

### Sprint 8: Modern Kubernetes Ingress (Nov 16–20, 5 Days)
* **Focus:** Bridging NGINX into Kubernetes container networking.
* **Key Topics:** Kubernetes networking fundamentals (Services, Endpoints, CNI), Ingress Controller architecture, standard community Ingress vs. F5 NGINX Ingress Controller (NIC), F5 CRDs (`VirtualServer`, `VirtualServerRoute`), traffic splitting, and zero-downtime pod endpoint updates.
* **Enterprise Side Quest:** F5 NIC Enterprise policies: rate limiting CRDs, active circuit breaking, and canary deployments.

### Sprint 9: Next-Gen Kubernetes Gateway API (Nov 23–25, 3 Days - Thanksgiving Week)
* **Focus:** The successor to Kubernetes Ingress: the official Kubernetes Gateway API.
* **Key Topics:** Role-oriented API architecture (Infrastructure Provider $\to$ Cluster Operator $\to$ Application Developer), `GatewayClass`, `Gateway`, `HTTPRoute`, `GRPCRoute`, cross-namespace routing, and NGINX Gateway Fabric (NGF) architecture.
* **Enterprise Side Quest:** GenAI LLM Inference Extensions: routing prompts across multiple LLM backends based on model parameters and latency.

### Sprint 10: Advanced Microservices & Enterprise Ingress (Nov 30–Dec 4, 5 Days)
* **Focus:** High-throughput microservice communication and hybrid infrastructure connectivity.
* **Key Topics:** End-to-end gRPC streaming through NGINX (`grpc_pass`), HTTP/2 upstream multiplexing, header rewriting at scale, and external DNS automation.
* **Enterprise Side Quest:** F5 BIG-IP CIS + GatewayLink: combining external F5 BIG-IP hardware load balancers with internal NGINX Gateway Fabric for automated end-to-end traffic delivery.

### Sprint 11: Production Observability & Telemetry (Dec 7–11, 5 Days)
* **Focus:** Deep visibility into network traffic, latencies, and distributed requests.
* **Key Topics:** Custom JSON access logging with high-resolution timing (`$request_time`, `$upstream_connect_time`, `$upstream_response_time`), OpenTelemetry distributed tracing module, injecting W3C `traceparent` headers, and Prometheus metric exporters.
* **Enterprise Side Quest:** NGINX Plus Live Activity Monitoring: real-time graphical dashboard and live JSON metrics feed.

### Sprint 12: High Availability & Fault Resilience (Dec 14–18, 5 Days)
* **Focus:** Eliminating single points of failure and engineering self-healing systems.
* **Key Topics:** Active/passive failover using Keepalived and Virtual Router Redundancy Protocol (VRRP), shared floating virtual IPs (VIP), tuning connection timeouts (`proxy_connect_timeout`), handling backend connection resets gracefully, and error masking.
* **Enterprise Side Quest:** NGINX Plus active health checks: periodic out-of-band application probes with custom response body pattern matching.

### Sprint 13: Edge Security & Web Application Firewalls (Dec 21–23, 3 Days - Christmas Week)
* **Focus:** Layer 7 application protection, payload inspection, and vulnerability mitigation.
* **Key Topics:** OWASP Top 10 threat modeling, ModSecurity OSS engine integration with Core Rule Set (CRS), request body inspection limits, and tuning false positives.
* **Enterprise Side Quest:** F5 App Protect WAF: high-performance native compiled engine, DataGuard credit card/SSN masking, and precompiled policy deployment.

### Sprint 14: Capstone Architecture & Production Packaging (Dec 28–31, 4 Days)
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
       ├────► Port 8080 ──► Host Docker Stack: Learning Dashboard & Test Runner
       │                    - Always-online curriculum, quiz engine, and notes
       │                    - Zero impact when Kubernetes clusters are recreated
       │
       └────► Port 80/443 ─► Ephemeral `kind` Cluster (Kubernetes Lab Sandboxes)
                            - NGINX Ingress Controller / Gateway Fabric
                            - Can be torn down and rebuilt (`kind delete cluster`)
```

* **Memory Budget:**
  * Host OS & Docker Daemon: ~1.2 GB
  * Learning Platform Stack: ~0.3 GB
  * Ephemeral `kind` Node (Sprints 8–10): ~2.5 GB
  * **Free Headroom:** ~4.0 GB (plus recommended 4 GB swapfile for buffer safety).

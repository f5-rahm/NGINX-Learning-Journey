# Recap Video: Sprints 1–4, From BIG-IP to NGINX

**Length:** about 2:30–2:45 (about 330 words of voiceover at a relaxed 125 words a minute, with pauses for the images).
**Format:** talking head or voiceover, with the sprint diagrams on screen. Each segment names the image to show.

---

## Script

| Time | On screen | Voiceover |
| :--- | :--- | :--- |
| 0:00–0:15 | You, or a title card: "4 sprints, BIG-IP → NGINX" | I've spent years on F5 BIG-IP, and for the last four sprints I've been learning NGINX the hands-on way. Here's what stuck, and where my BIG-IP habits gave me the wrong answer. |
| 0:15–0:40 | `sprint-1/nginx-process-hierarchy.png` | **Sprint 1: architecture.** NGINX workers map closely to TMMs: one event loop per core. The master never touches traffic. It reads the config, binds the ports and supervises. If a worker crashes, the master starts a new one, and only that worker's connections are lost. |
| 0:40–1:15 | `sprint-2/zone-per-worker-state.png`, then `sprint-2/retry-decision-flow.png` | **Sprint 2: reverse proxy and load balancing.** This was home turf, and that was the risk. Workers share nothing unless you give the pool a shared memory zone. Without one, you're running a separate load balancer per worker. Open source has no health monitors. It finds a dead server when a real request fails, so the real question is who pays for that failure, and the retry rules decide. And connection reuse, NGINX's OneConnect, is finally on by default. |
| 1:15–1:50 | `sprint-3/response-path.png` | **Sprint 3: TLS, HTTP/2 and HTTP/3.** NGINX has no crypto stack of its own. It uses the system's OpenSSL, so patching the host *is* patching NGINX's TLS. And a reload doesn't pick up the patched library. A binary upgrade does, without dropping a connection. Security headers looked like one-liners, until I learned that a single `add_header` in a location quietly drops every header it would have inherited. |
| 1:50–2:30 | `sprint-4/host-and-cache-key.md` diagram, then `sprint-4/kernel-limits.png` | **Sprint 4: caching.** The rule I'm keeping: the cache key must include everything the origin uses to build the response, or someone gets someone else's page. By default NGINX even caches authenticated responses, on purpose. Then the limits under NGINX: the accept queue, file descriptors, ephemeral ports. They're set by the kernel and the platform, and every one of them fails quietly, with green health checks. |
| 2:30–2:45 | Title card with the three lessons | Three lessons across all four sprints. One: NGINX shares nothing unless you tell it to. Two: NGINX trusts the system underneath it, for crypto and for TCP. Three: the dangerous failures are the quiet ones, so measure. Next up: rate limiting. |

---

## Shot list

* `sprints/sprint-1/nginx-process-hierarchy.png`
* `sprints/sprint-2/zone-per-worker-state.png`
* `sprints/sprint-2/retry-decision-flow.png`
* `sprints/sprint-3/response-path.png`
* `sprints/sprint-4/host-and-cache-key.md` (screenshot of the rendered Mermaid diagram)
* `sprints/sprint-4/kernel-limits.png`

## If you need to cut to 2:00

Drop the retry sentence in Sprint 2 and the security headers sentence in Sprint 3. The three lessons at the end carry the story on their own.

---

## Raw material for your own script

### BIG-IP vs NGINX: the important differences
* **Workers are like TMMs, but share nothing by default.** Without a shared memory `zone`, every worker is its own load balancer: its own connection counts, its own `max_fails` tally, its own view of which server is down.
* **The master never touches traffic.** A crashed worker gets replaced by the master and only loses its own connections. That's not a TMM core.
* **Config is one text file, applied by reload.** Every pool change in open source is an edit plus a reload, and a reload retires every worker. NGINX Plus changes pools through an API, like iControl, with no reload.
* **No active monitors in open source.** NGINX finds a dead server when a real request fails, then retries on the next one. Active health checks are an NGINX Plus feature.
* **Methods are modules.** The load balancing method is a bare directive (`least_conn;`), not a setting. Features don't combine freely: `hash`, `ip_hash` and `random` reject `backup`.
* **`backup` isn't a priority group.** It's on or off, with no minimum active members, and it can kick in for a single request.
* **`least_conn` counts busy connections, not idle pooled ones.** That's closer to Fastest than to Least Connections.
* **OneConnect is `keepalive`,** per worker. It's on by default only since nginx 1.29.7.
* **`Host` handling is the opposite.** BIG-IP forwards the client's `Host` unchanged. NGINX sends the upstream name unless you set `proxy_set_header Host $host`.
* **No iRule events.** Directives run in fixed phases, wherever they sit in the file. `return` runs before access checks.
* **No crypto stack of its own.** TLS is the system's OpenSSL. Patching the host patches NGINX's TLS, and only a binary upgrade (`USR2`), not a reload, loads the patched library.
* **No TCP stack of its own.** TCP profile settings live in the kernel (`sysctl`, per network namespace) and the platform (file limits), not in `nginx.conf`.
* **Caching follows the operator, not the RFC.** NGINX caches responses to authenticated requests by default, on purpose: the config is the policy.
* **No purge in open source.** Invalidation is a design decision in the config (versioned URLs, short lifetimes, a key generation), not a management-plane button. NGINX Plus adds purge.
* **NGINX always answers with a status.** BIG-IP with no available members resets the connection. NGINX sends a 502 or 504, and the code tells you which kind of failure it was.

### What confused, surprised or tripped me up
* **Sprint 1:** where a `location` block is allowed; `USR2` vs `HUP`; `nginx -s reload` from a lab directory reading the wrong PID file; the name "upstream" (pools and members is better, I said what I said).
* **Sprint 2, URI mapping:** the trailing slash rules in `proxy_pass`, `$uri` vs `$request_uri`, and a regex location losing the query string unless you add `$is_args$args`. I scored 7/10 on the first quiz.
* **Sprint 2, home turf was the trap:** my BIG-IP intuition on `backup`, `least_conn`, weights and box-wide member status was wrong in ways that pass `nginx -t`.
* **Sprint 2, failures:** worst-case latency isn't 3n+1, it's tries × timeouts. Timeouts measure gaps, not totals. 502 vs 504 depends on whether a timer ran out, and the same dead host can give either one. WebSocket `Upgrade` (the request) vs `101` (the response).
* **Sprint 2, syntax:** I missed 5 semicolons, and `nginx -t` points to the line *after* the missing one. Time values take units, counts don't, and I got it wrong both ways.
* **Sprint 2, reloads:** a `sed` that ran twice added the same server twice. NGINX accepted both, so `drain` did nothing. A long-lived WebSocket pins an old worker for up to an hour after a reload.
* **Sprint 3, patching:** the OpenSSL version string never changes on Ubuntu (backports), so the real patch level is the package revision. `(deleted)` in `/proc/PID/maps` also matches NGINX's normal shared memory.
* **Sprint 3, `add_header`:** without `always`, error responses get no security headers. One `add_header` in a location drops everything inherited. Adding `Server` gives you two `Server` headers, not one.
* **Sprint 3, the box hang:** one HTTP/3 test client retrying a refused handshake took down the whole lab host. Test tools need resource limits too.
* **Sprint 3, the lab:** my first run passed 8 of 13 checks.
* **Sprint 4, caching:** a keys zone that's too small evicts silently and looks like a poor hit ratio. `proxy_cache_bypass` alone still stores the response. `Host $host` alone, my BIG-IP reflex, is the cross-tenant leak case.
* **Sprint 4, under pressure:** the most rule-dense day, and three quiz attempts (6, 7, 8). The lock doesn't cover expired entries. A 503 is an answer, not an `error`. Two kinds of `STALE` look identical in the log. The flowchart is what made it stick.
* **Sprint 4, kernel limits:** `somaxconn` caps `backlog` without a word. A file limit that's too low turns cached pages into 500s while health checks stay green. My own load test fell into the Day 1 cache key trap, two days later.
* **Across all four sprints:** most first-attempt quiz misses were defaults and inheritance, the things NGINX does when you *don't* write a directive.

# Recap Video: Halfway, Six Sprints from BIG-IP to NGINX

**Length:** about 4:30 (about 610 words of voiceover at 135 words a minute, plus short pauses for the images). A 3:00 cut is at the end.
**Format:** talking head or voiceover, with the sprint diagrams on screen. Each segment names the image to show.
**Shape:** not sprint by sprint. Three things about how NGINX is built, two about how I've been learning it, the Black Friday War Room, KubeCon, and what's next.

---

## Script

| Time | On screen | Voiceover |
| :--- | :--- | :--- |
| 0:00–0:20 | You, or a title card: "Halfway: 6 sprints, BIG-IP → NGINX" | I've spent years on F5 BIG-IP, and I'm six sprints into learning NGINX the hands-on way. That's halfway. So instead of going sprint by sprint, here are three things about how NGINX is built, two about how I've been learning it, and a game I built for you. |
| 0:20–0:55 | `sprint-2/zone-per-worker-state.png`, then the War Room diagram (`gauntlet/black-friday/README.md`, section 3) | **One: state lives where you put it.** Each NGINX worker is a single-threaded event loop, and by default everything it knows is its own: which servers are down, connection counts, rate-limit buckets, even a JavaScript global. Give it a shared memory zone and it's per node. Put two nodes behind a load balancer, and a limit of ten a second is quietly twenty. So for every feature I now ask: is this per worker, per node, or per cluster? |
| 0:55–1:35 | `sprint-5/control-points.png` | **Two: the order is the policy.** NGINX doesn't run directives in the order you write them. Every request walks through fixed phases. I blocked a network, flooded the API from it, and expected a wall of 403s. I got 403s *and* 429s. The rate limiter runs before the access check, so a banned client was told "slow down and try again". Moving the refusal one phase earlier fixed it. There are no iRule events to choose from. Learn the phases, and half the design is done. |
| 1:35–2:15 | `sprint-4/kernel-limits.png`, then `sprint-6/code-and-config.png` | **Three: NGINX does one job, and borrows the rest.** Its TLS is the system's OpenSSL. Its TCP is the kernel's, and the kernel's limits fail quietly, behind green health checks. Its secrets come from the platform. And because a worker is one thread, a slow script stalls everything on it: two bad requests on a two-worker edge, and every request took nearly three seconds for a millisecond of work. A BIG-IP is an appliance. NGINX is a process, and the system under it is part of the design. |
| 2:15–2:45 | `sprint-6/where-mistakes-show.png` | **Now the learning.** Most of my first-attempt quiz misses weren't syntax. They were defaults and inheritance: what NGINX does when you *don't* write a directive. One header in a location drops every inherited one. A rejected client gets a 503 that says you're down. And every mistake that really hurt passed `nginx -t`. So: be explicit, and after every reload, send one good request, one bad one, and read the error log. |
| 2:45–3:05 | `sprint-5/burst-and-nodelay.png` | **And home turf was the trap.** Load balancing and scripting were where my BIG-IP instincts gave the most confident wrong answers. What worked was breaking things on purpose, and drawing them. After one bad quiz I drew this diagram, and the retake went from six to nine. |
| 3:05–3:50 | The War Room diagram, then a screen recording of `./warroom.sh board` | **Which brings me to the game.** The Black Friday War Room. It's the night before Black Friday: two NGINX edges behind a load balancer, and the tickets roll in. A wrong price stuck in the cache, scalper bots, a partner caught in the block, limits that don't hold across nodes, a VIP sale marketing keeps changing. At midnight the doors open and every fix has to hold under load. There's a scoreboard, a free open source edition and an NGINX Plus edition. Play both, and you'll see exactly what Plus changes. Link below. |
| 3:50–4:00 | Title card: "KubeCon + CloudNativeCon North America, Salt Lake City" | A shout-out to everyone at KubeCon in Salt Lake City this week, because Kubernetes is exactly where this journey goes next. |
| 4:00–4:20 | `README.md` roadmap (section 3), scrolling Sprints 7–14 | Sprint 7 is identity at the edge: mutual TLS, `auth_request`, and OAuth2 Proxy with Keycloak. Then Kubernetes: the NGINX Ingress Controller, the Gateway API with NGINX Gateway Fabric, AI inference routing, and BIG-IP working alongside Gateway Fabric. Then observability, high availability, a web application firewall, and a capstone. |
| 4:20–4:30 | Title card with the three questions | So, three questions I now ask of any NGINX config: where does this state live, which phase runs it, and what does NGINX do if I don't say? See you in Kubernetes. |

---

## Shot list

* `sprints/sprint-2/zone-per-worker-state.png`
* `sprints/sprint-5/control-points.png`
* `sprints/sprint-4/kernel-limits.png`
* `sprints/sprint-6/code-and-config.png`
* `sprints/sprint-6/where-mistakes-show.png`
* `sprints/sprint-5/burst-and-nodelay.png`
* `gauntlet/black-friday/README.md`, section 3 (screenshot of the rendered Mermaid diagram)
* A short screen recording of `./warroom.sh board` (or `next` and `check` on ticket 1)
* `README.md`, section 3 (the roadmap), for the preview

## If you need to cut to 3:00

* **Topic 1:** drop "even a JavaScript global".
* **Topic 3:** drop the two-worker numbers; keep "a slow script stalls everything on it".
* **Learning:** merge the two segments. Keep "defaults and inheritance", "every mistake that hurt passed `nginx -t`", and "home turf was the trap". Drop the quiz score.
* **Preview:** "Next: identity at the edge, then Kubernetes, observability, high availability, a WAF and a capstone."

## Swaps, if a topic doesn't land on camera

* **Topic 2 alternate (outbound):** "Same on the way out. By the time a response filter sees the body, the headers have already left. I masked card numbers, the body grew three bytes, and the old `Content-Length` cut the JSON short. No error anywhere." (Image: `sprint-6/filters-and-content.png`.)
* **Topic 3 alternate (patching):** "Patching the host *is* patching NGINX's TLS, and a reload won't load the patched library. A binary upgrade will, without dropping a connection." (Image: `sprint-3/response-path.png`.)
* **War Room alternate line:** "There's even a benchmark of njs against Lua on OpenResty, and the answer isn't just the number."

## Fact check

* **KubeCon + CloudNativeCon North America 2026:** November 9–12, Salt Palace Convention Center, Salt Lake City. This year's program added an AI inference and agentic track, which is a natural hook for Sprint 9's inference-routing side quest if you want one more line.
* **Quiz score in the learning segment:** Sprint 5 Day 1, 6/10 then 9/10, after drawing the burst and `nodelay` diagram.
* **War Room:** 9 tickets in 3 stages plus a finale under load, 1200 points, both editions.

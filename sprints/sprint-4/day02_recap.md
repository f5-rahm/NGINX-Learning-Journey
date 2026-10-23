# NGINX Learning Journey, Sprint 4 Day 2: The Cache Under Pressure

Day 1 made the Lumina edge cache correct. Day 2 asked what it does on a bad day: the second a popular entry expires, the first minute after a deploy, the moment the origin falls over. A cache that's only correct on a calm day doesn't protect much. This was the most rule-dense day of the journey so far, and it took me three quiz attempts.

## The thundering herd, and why the lock isn't enough

A cold or expired URL under load means every request that arrives before the first origin answer goes to the origin too. Twenty clients and a two-second page meant twenty origin requests for one page.

`proxy_cache_lock` collapses that to one: one request fetches, the rest wait and get a `HIT` from the new entry. Two details make it less simple than it sounds:

- **Two 5-second timers.** `proxy_cache_lock_timeout` is how long waiters wait. After that, each one fetches for itself and its response isn't cached. `proxy_cache_lock_age` is how long the fetcher holds the lock before one more request is let through. For an origin slower than 5 seconds, both have to be raised, or the lock protects nothing.
- **The lock only covers entries that don't exist yet.** I proved this by accident: I re-ran a test on URLs I'd already cached, and after a minute every request was `EXPIRED` and went straight to the origin, lock or no lock.

Coming from BIG-IP, this is request coalescing, but opt-in, per location, and off by default. The waiters also recheck on a 500 ms timer instead of being handed the response when it arrives.

## Expired isn't gone

An expired entry stays on disk until `inactive` or eviction removes it, and `proxy_cache_use_stale` lets NGINX serve it instead of failing. The fine print is where I lost quiz points:

- `error` means the origin couldn't be reached or didn't answer. **A 503 is an answer**, so each 5xx status has to be listed separately.
- Stale only protects what's already cached. A URL nobody requested before the outage still gets a 502.
- The client sees a 200 with `X-Cache-Status: STALE`. Status-code monitoring won't notice the outage at all.

The origin can opt in too, with `stale-while-revalidate` and `stale-if-error`, but `stale-if-error` doesn't cover a 503 answer either.

## Who waits for the refresh

This is the part that made it click for me:

- `use_stale updating` spares everyone **except** the request that found the entry expired. That one still waits on the origin.
- `proxy_cache_background_update` spares that request too: it gets the stale copy at once and the refresh runs in a subrequest. It only works together with `updating`.

With both on, a slow origin and a short lifetime under 50 concurrent clients went from 107 origin requests and a 2.5-second tail to 3 origin requests, and the only slow response was the very first cold miss.

## Revalidation you can't see

`proxy_cache_revalidate` turns refreshes into conditional requests, so an unchanged object comes back as a 304 with no body. With background update on, the client never sees `REVALIDATED`, because the 304 happens in the subrequest and subrequests aren't logged by default. Only the origin's counters showed it. `log_subrequest on` brings the line back.

That has a monitoring consequence I didn't expect: with background update on, there are two ways to get `STALE`, a normal refresh and a real outage, and they look the same in the log. An outage is a *sustained* `STALE` rate alongside origin errors, not `STALE` showing up at all. And in open source NGINX there are no cache counters to graph. `stub_status` only knows connections, so the access log is the metric source. NGINX Plus has per-zone cache counters in its API.

## Measuring it

The cache's worth showed up in one load test: about 45,000 requests per second for a cached URL against about 800 when every request reached the origin. The lesson from the load tests was where to look. Averages barely moved between configs. The **slowest response** and **how many requests reached the origin** told the whole story.

## Lab and quiz

I drew all of today's rules as one decision flowchart: lookup, lock, expiry, refresh, origin answer, and the `X-Cache-Status` each path ends in. That turned a list of rules into a map I can actually remember. *(Diagrams: [Cache Under Pressure](cache-under-pressure.html), the decision flow plus a client/edge/origin sequence for each configuration.)*

Quiz: 6/10, then 7/10, then 8/10. There's no single weak spot, just a lot of rules that each depend on another one. Next up, Day 3: kernel and connection limits, where the cache stops being the bottleneck.

#NGINX #F5 #Caching #WebPerformance #LearningInPublic #DevOps

# NGINX Learning Journey, Sprint 4 Day 1: The Edge Cache

Sprint 4 turns the Lumina edge into a cache. Day 1 covered the basics: where the cache lives, what NGINX decides to store and for how long, the cache key, and who gets a cached answer. It's also the first sprint where the lab runs entirely in containers. Caching rewired my brain more than TLS did. Most of the surprises came from what NGINX *doesn't* do by default.

## The zone is the real size limit

An NGINX cache has two parts: files on disk, and a keys zone in shared memory that every worker reads. The zone holds one small node per entry, about 8,000 per MB. When it fills, NGINX evicts the least recently used entries, deletes their files, and logs nothing, even with the disk almost empty. A `keys_zone=...:1m` with `max_size=50g` tops out around 8,000 objects and never gets near 50 GB. A zone that's too small looks exactly like a low hit ratio. That one cost me a quiz question.

LRU is the same idea as Python's `@lru_cache` from Advent of Code. The speedup there is really memoization. The LRU part only matters once memory is capped, and an edge cache is always capped.

## The origin decides lifetimes, unless you tell NGINX otherwise

NGINX caches nothing without a lifetime. Browsers guess one from `Last-Modified`. NGINX doesn't, so an origin that sends no caching headers is never cached until you set `proxy_cache_valid`. Origin headers then beat your config in both directions. `max-age=2` shortens a one-minute rule, and `max-age=60` on a 503 caches the error. `X-Accel-Expires` is NGINX's own override, above `Cache-Control`.

Only `GET` and `HEAD` are cached by default. `POST` is opt-in and needs the body in the key. The new HTTP `QUERY` method can't be cached at all: NGINX proxies it, but `proxy_cache_methods` rejects it.

## Host and the key: fixing one is worse than fixing neither

The edge makes two separate decisions about the host name: which `Host` the origin sees, and whether the key includes it. NGINX's default for both is the `proxy_pass` name, not the client's host.

- **Neither fixed:** both tenants get the same generic page. It's wrong, but the cache and the origin agree, so you notice immediately.
- **Host only:** the origin builds tenant A's page, the cache stores it under a key with no host, and tenant B gets A's page. Every response is a 200, and which tenant leaks depends on who asked first.
- **Both fixed:** correct.

The rule I'm keeping: **the cache key must include everything the origin uses to build the response.** If the key has more than the origin uses, it only costs disk and misses. If the origin uses more than the key, someone gets someone else's answer.

Coming from BIG-IP, that one is personal. BIG-IP passes `Host` through untouched, so my reflex on NGINX is `proxy_set_header Host $host`. On a caching location, that reflex alone is the leak case. *(Diagrams: [Host and the Cache Key](host-and-cache-key.md).)*

## NGINX ignores the RFC rule for `Authorization`, on purpose

RFC 9111 says a shared cache must not reuse a response to an authenticated request unless the response allows it. NGINX doesn't apply that rule. By default, Alice's personalized page is cached and served to anonymous users and to Bob. This goes back to a 2009 mailing-list thread: the NGINX developers' position was that the cache does what the config says, and Igor Sysoev wanted the behavior configurable, not hard-coded, partly because anyone could force misses with a dummy header. The RFC calls a reverse proxy a gateway that "acts as an origin server for the outbound connection", and NGINX's design follows that idea: the cache is part of the origin, and the operator's config is the policy.

The fix takes two directives, because each covers one direction:

- `proxy_cache_bypass $http_authorization` stops **reading** from the cache. The bypassed response is still **stored**, so the next anonymous client got Alice's copy.
- `proxy_no_cache $http_authorization` stops **writing**. Used alone, Alice gets the anonymous copy.

That two-sided trap was my other quiz miss.

## No purge button in open source

Open source NGINX can't remove a single object on request. That's an NGINX Plus feature, and it's on Day 3's side quest. Production setups get around it by design: versioned asset URLs (a deploy means new keys), short lifetimes with stale serving for HTML, a restricted bypass header that overwrites one entry, or a version variable in the key that you change with a reload. Coming from BIG-IP, where invalidation is a management-plane operation, it's an adjustment. In NGINX, cache control is a design decision you make in the config.

## Lab notes

- The lab now runs `nginx:mainline` (1.31.6, OpenSSL 3.5) and a countable origin in containers. The origin's per-URI hit counter makes every cache decision visible: when the edge serves from cache, the number stops moving.
- The cache survived recreating the container. The first request after a restart was a `HIT` before the cache loader had even run.

Quiz: 7/10 on the first attempt and 8/10 on the second. The misses were zone sizing and the `Authorization` defaults. Next up, Day 2: the cache under pressure, with locks, stale serving and background updates.

#NGINX #F5 #Caching #WebPerformance #LearningInPublic #DevOps

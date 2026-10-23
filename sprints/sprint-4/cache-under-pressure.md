# Cache Under Pressure

**Sprint 4 · Day 2.** Which path a request takes through `proxy_cache` when entries are missing, expiring or failing, what the client, NGINX and the origin each do, and the `X-Cache-Status` each path ends in.

* [Part 1: Decision flow](#part-1-decision-flow)
* [Part 2: Who does what, by configuration](#part-2-who-does-what-by-configuration)

---

## Part 1: Decision Flow

Green outcomes answer the client from a cached copy with no origin wait. Amber outcomes waited on an origin round trip. Red outcomes pass an origin error to the client.

### 1. Lookup, and What Happens on a Miss

```mermaid
flowchart TD
    R(["Request reaches a cached location"]) --> B{"Does proxy_cache_bypass fire?<br/>any value not empty and not 0"}
    B -- yes --> BY(["BYPASS<br/>the origin answers the client"])
    B -- no --> K{"Is the key in the cache,<br/>and still fresh?"}
    K -- fresh --> HIT1(["HIT<br/>served from the cache"])
    K -- expired --> EXP[["Expired entry:<br/>continues in Figure 2"]]
    K -- not cached --> L{"Is proxy_cache_lock on?<br/>off by default"}
    L -- no --> M1(["MISS<br/>every concurrent miss fetches<br/>from the origin: a herd"])
    L -- yes --> F{"Is another request<br/>fetching this key?"}
    F -- no --> M2(["MISS<br/>takes the lock, fetches, stores"])
    F -. "holder slower than<br/>proxy_cache_lock_age (5s)" .-> AGE["one more request also<br/>fetches from the origin"]
    F -- yes --> W["Wait for that entry<br/>proxy_cache_lock_timeout 5s"]
    W --> T{"Filled before<br/>the timeout?"}
    T -- yes --> HIT2(["HIT<br/>served from the new entry"])
    T -- no --> M3(["MISS<br/>fetches itself, response not cached"])

    classDef cache fill:#e3f4ec,stroke:#1f7a55,color:#1b2230
    classDef origin fill:#fbeedd,stroke:#a35a00,color:#1b2230
    classDef dec fill:#e9eef8,stroke:#4a6fb5,color:#1b2230
    class HIT1,HIT2 cache
    class BY,M1,M2,M3 origin
    class B,K,L,F,T dec
```

The lock only collapses requests for entries that don't exist yet. A bypassed response can still be stored unless `proxy_no_cache` also fires, which is why Day 1 paired the two for `Authorization`. On every miss there is nothing stale to fall back on, so an origin failure here reaches the client.

### 2. An Expired Entry

```mermaid
flowchart TD
    E(["Entry found, but expired"]) --> R{"Is it already being refreshed<br/>by another request?"}
    R -- yes --> U{"Is updating allowed?<br/>proxy_cache_use_stale updating"}
    U -- yes --> UPD(["UPDATING<br/>the old copy, no wait"])
    U -- no --> TOO["This request fetches too<br/>the lock skips expired entries"]
    R -- "no: this request refreshes it" --> BG{"Is background update on?<br/>proxy_cache_background_update"}
    BG -- yes --> ST1(["STALE<br/>the client gets the old copy now"])
    ST1 -. "a subrequest does the fetch" .-> FETCH
    BG -- no --> WAIT["The client waits on this fetch<br/>others: UPDATING, if allowed"]
    WAIT --> FETCH
    TOO --> FETCH["Fetch from the origin<br/>conditional if proxy_cache_revalidate on"]
    FETCH --> A{"What does<br/>the origin send?"}
    A -- "304 Not Modified" --> REV(["REVALIDATED<br/>entry extended, body kept"])
    A -- 200 --> NEW(["EXPIRED<br/>new copy stored and served"])
    A -- "error · timeout · 5xx" --> LS{"Listed in proxy_cache_use_stale?<br/>each 5xx must be named"}
    LS -- yes --> ST2(["STALE<br/>the old copy, with status 200"])
    LS -- no --> ERR(["EXPIRED<br/>the origin's error reaches the client"])

    classDef cache fill:#e3f4ec,stroke:#1f7a55,color:#1b2230
    classDef origin fill:#fbeedd,stroke:#a35a00,color:#1b2230
    classDef err fill:#fbe5e3,stroke:#b3261e,color:#1b2230
    classDef dec fill:#e9eef8,stroke:#4a6fb5,color:#1b2230
    class UPD,ST1,ST2 cache
    class REV,NEW origin
    class ERR err
    class R,U,BG,A,LS dec
```

`updating` spares the other requests and background update spares the refresher too, so with both on, nobody waits on a slow origin while a stale copy exists. The origin can switch on the same branches with `stale-while-revalidate` (as `updating`) and `stale-if-error` (as `error timeout`, never a 503 answer), at lower priority than your config. Background update does nothing unless `updating` is listed. In a background refresh, the origin's answer only changes the stored entry: the client already left with `STALE`, and `REVALIDATED` is logged only with `log_subrequest on`.

### Reading X-Cache-Status

| Status | Path that produced it | Origin contacted for this request? |
| :--- | :--- | :--- |
| `HIT` | Fresh entry, or filled while waiting on the lock | No |
| `UPDATING` | Expired entry that another request is refreshing; `updating` allowed | No |
| `STALE` | Background update served the old copy, or the origin failed with a listed condition | No wait for the client. A background subrequest may be fetching. |
| `MISS` | No entry: no lock, the lock holder, or a waiter that timed out | Yes |
| `EXPIRED` | Expired entry refreshed in the foreground, with a new 200 or a passed-through error | Yes |
| `REVALIDATED` | Conditional refresh answered 304 | Yes, with no body |
| `BYPASS` | `proxy_cache_bypass` fired | Yes |

### What to Watch in Monitoring

* A burst of `MISS` or `EXPIRED` for one key right after expiry or a deploy is the herd. The lock fixes the `MISS` burst and `updating` fixes the `EXPIRED` burst.
* With background update on, `STALE` also appears in normal operation, on the first request after every expiry. An outage looks like a sustained `STALE` rate while `$upstream_status` shows errors.
* A slowest response near 5 seconds for a key that should collapse means waiters are hitting `proxy_cache_lock_timeout`. That's when the origin is slower than the lock.

---

## Part 2: Who Does What, by Configuration

The same rules as sequences. Each diagram adds one directive to the one before it, except the failure cases at the end. Time runs down the page; the notes on the left say when each answer arrives. Dashed arrows are answers; a `Bg` arrow is NGINX's background subrequest.

| Scenario | Origin requests | Who waits | Log shows |
| :--- | :--- | :--- | :--- |
| [1. No protection](#1-no-protection) | 20 | All 20, full origin time | `20 MISS` |
| [2. Lock, fast origin](#2-lock-origin-faster-than-the-lock) | 1 | All 20, about the origin time | `1 MISS, 19 HIT` |
| [3. Lock, origin slower than 5 s](#3-lock-origin-slower-than-the-lock) | 20 | 1 for 7 s, 19 for 12 s | `20 MISS` |
| [4. Expired, lock only](#4-expired-entry-lock-only) | 20 | All 20 | `20 EXPIRED` |
| [5. + use_stale updating](#5-stale-while-one-request-refreshes) | 1 | Only the refresher | `1 EXPIRED, 19 UPDATING` |
| [6. + background_update](#6-nobody-waits) | 1 (subrequest) | Nobody | `1 STALE, 19 UPDATING` |
| [7. + revalidate](#7-revalidation) | 1, a 304 with no body | Nobody | `STALE` |
| [8. Origin 503, not listed](#8-origin-fails-condition-not-listed) | 1 | Client, then gets the 503 | `EXPIRED`, 503 |
| [9. Origin 503, listed](#9-origin-fails-condition-listed) | 1 | Client, until the origin fails | `STALE`, 200 |

### 1. No Protection

```nginx
proxy_cache lumina;   # nothing else (Day 1 config)
```
A URL nobody has requested yet, 20 clients at once, a 2-second origin.

```mermaid
sequenceDiagram
    participant C as Clients
    participant N as NGINX
    participant O as Origin
    Note left of C: 0 s
    C->>N: 20 x GET /s/1, same moment
    Note over N: no entry, no lock: every request is a miss
    N->>O: 20 fetches
    Note over O: renders the page 20 times, in parallel
    Note left of C: 2 s
    O-->>N: 20 x 200
    Note over N: stores the response
    N-->>C: 20 x 200 MISS
```

**Origin:** 20 requests for one page. **Waits:** all 20, the full origin time. **Log:** 20 `MISS`.

### 2. Lock, Origin Faster Than the Lock

```nginx
proxy_cache_lock on;   # timers: 5 s
```
Same burst, a new URL, a 2-second origin.

```mermaid
sequenceDiagram
    participant C as Clients
    participant N as NGINX
    participant O as Origin
    Note left of C: 0 s
    C->>N: 20 x GET /s/2
    Note over N: request 1 takes the lock for the key<br/>19 wait, rechecking every 500 ms
    N->>O: 1 fetch
    Note left of C: 2 s
    O-->>N: 200
    Note over N: stores the entry, releases the lock
    N-->>C: request 1: 200 MISS
    Note left of C: 2-2.5 s
    N-->>C: 19 x 200 HIT, at the next recheck
```

**Origin:** 1 request. **Waits:** all 20, about the origin time. **Log:** 1 `MISS`, 19 `HIT`.

### 3. Lock, Origin Slower Than the Lock

```nginx
proxy_cache_lock on;   # lock_timeout 5s, lock_age 5s
```
Same burst, a new URL, a 7-second origin.

```mermaid
sequenceDiagram
    participant C as Clients
    participant N as NGINX
    participant O as Origin
    Note left of C: 0 s
    C->>N: 20 x GET /s/3
    Note over N: request 1 takes the lock, 19 wait
    N->>O: 1 fetch
    Note left of C: 5 s
    rect rgba(179, 38, 30, 0.15)
    Note over N: proxy_cache_lock_timeout runs out: the 19 stop waiting
    N->>O: 19 more fetches, responses not cached
    end
    Note left of C: 7 s
    O-->>N: 200 for request 1
    N-->>C: request 1: 200 MISS
    Note left of C: 12 s
    O-->>N: 19 x 200
    N-->>C: 19 x 200 MISS
```

**Origin:** 20 requests: the lock protected nothing. **Waits:** 1 for 7 s, 19 for 12 s. **Log:** 20 `MISS`.

Raise both timers above the slowest normal response. Raising only `proxy_cache_lock_timeout` to 10 s still sends one more request to the origin at 5 s (`proxy_cache_lock_age`): 2 origin requests. With both at 10 s: 1 request, 7 s.

### 4. Expired Entry, Lock Only

```nginx
proxy_cache_lock on;   # no proxy_cache_use_stale
```
The URL was cached a minute ago and has just expired. 20 clients, a 2-second origin.

```mermaid
sequenceDiagram
    participant C as Clients
    participant N as NGINX
    participant O as Origin
    Note left of C: 0 s
    C->>N: 20 x GET /s/2
    rect rgba(179, 38, 30, 0.15)
    Note over N: entry found, but expired: the lock does not apply
    end
    N->>O: 20 fetches
    Note left of C: 2 s
    O-->>N: 20 x 200
    N-->>C: 20 x 200 EXPIRED
```

**Origin:** 20 requests, every expiry. **Waits:** all 20. **Log:** 20 `EXPIRED`.

This is the herd that comes back at every expiry of a popular URL, even with the lock on. Your first Activity 3.2 rerun was this case.

### 5. Stale While One Request Refreshes

```nginx
proxy_cache_use_stale updating;
```
Same expired entry, 20 clients, a 2-second origin.

```mermaid
sequenceDiagram
    participant C as Clients
    participant N as NGINX
    participant O as Origin
    Note left of C: 0 s
    C->>N: 20 x GET /s/2
    Note over N: request 1 starts the refresh<br/>and marks the entry updating
    N->>O: 1 fetch
    N-->>C: 19 x 200 UPDATING (old copy)
    Note left of C: 2 s
    O-->>N: 200
    Note over N: replaces the entry
    N-->>C: request 1: 200 EXPIRED
```

**Origin:** 1 request. **Waits:** only the request that found it expired. **Log:** 1 `EXPIRED`, 19 `UPDATING`.

### 6. Nobody Waits

```nginx
proxy_cache_use_stale updating;
proxy_cache_background_update on;
```
Same expired entry, 20 clients, a 2-second origin.

```mermaid
sequenceDiagram
    participant C as Clients
    participant N as NGINX
    participant Bg as NGINX subrequest
    participant O as Origin
    Note left of C: 0 s
    C->>N: 20 x GET /s/2
    N-->>C: request 1: 200 STALE (old copy)
    N-->>C: 19 x 200 UPDATING (old copy)
    N->>Bg: start the refresh
    Bg->>O: fetch
    Note left of C: 2 s
    O-->>Bg: 200
    Note over Bg: replaces the entry, not logged
    Note left of C: later
    C->>N: next request
    N-->>C: 200 HIT
```

**Origin:** 1 request, in the background. **Waits:** nobody, while a stale copy exists. **Log:** 1 `STALE`, 19 `UPDATING`.

Background update does nothing without `updating` in `proxy_cache_use_stale`.

### 7. Revalidation

```nginx
proxy_cache_revalidate on;   # with background update
```
An expired entry whose object hasn't changed. One client.

```mermaid
sequenceDiagram
    participant C as Clients
    participant N as NGINX
    participant Bg as NGINX subrequest
    participant O as Origin
    Note left of C: 0 s
    C->>N: GET /v/1
    N-->>C: 200 STALE (old copy)
    N->>Bg: start the refresh
    Bg->>O: If-None-Match, If-Modified-Since
    Note over O: unchanged: no body to render or send
    O-->>Bg: 304 Not Modified
    Note over Bg: extends the entry, keeps the body<br/>REVALIDATED, but not logged
```

**Origin:** 1 conditional request, 304 with no body. **Waits:** nobody. **Log:** `STALE` (`REVALIDATED` shows only with `log_subrequest on`).

Without background update, the client's own request makes the conditional request, waits for the 304, and is logged `REVALIDATED`.

### 8. Origin Fails, Condition Not Listed

```nginx
proxy_cache_use_stale error timeout;   # no http_503
```
An expired entry, and the origin answers every request with a 503.

```mermaid
sequenceDiagram
    participant C as Clients
    participant N as NGINX
    participant O as Origin
    Note left of C: 0 s
    C->>N: GET /s/7
    Note over N: entry expired: fetch it
    N->>O: fetch
    O-->>N: 503
    rect rgba(179, 38, 30, 0.15)
    Note over N: a 503 is an answer, not an error,<br/>and http_503 isn't listed
    N-->>C: 503 EXPIRED
    end
```

**Origin:** 1 request. **Waits:** the client, and then it gets the error. **Log:** `EXPIRED` with status 503.

### 9. Origin Fails, Condition Listed

```nginx
proxy_cache_use_stale error timeout http_500 http_502
                      http_503 http_504 updating;
```
Same expired entry and the same failing origin.

```mermaid
sequenceDiagram
    participant C as Clients
    participant N as NGINX
    participant O as Origin
    Note left of C: 0 s
    C->>N: GET /s/7
    N->>O: fetch
    O-->>N: 503 (or connection refused, or a drop)
    Note over N: http_503 is listed: serve the old copy instead
    N-->>C: 200 STALE
```

**Origin:** 1 request, failing. **Waits:** the client, for as long as the origin takes to fail. **Log:** `STALE` with status 200.

The client sees a normal 200, so status-code monitoring misses the outage. A URL that was never cached still gets the error: there is no copy to serve. With `timeout`, a hung origin holds the client for `proxy_read_timeout` (60 s by default) before the stale copy, unless background update already answered it.

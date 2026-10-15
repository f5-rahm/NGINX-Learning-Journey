# Sprint 3 &bull; Day 2: ALPN, HTTP/2 and HTTP/3
**Day:** 2 of 3  
**Estimated Time:** 65 Minutes (15 concepts, 5 setup, 35 lab, 10 quiz)  
**Theme:** The client's protocol and the backend's protocol are separate decisions. Learn how NGINX negotiates HTTP/2 inside TLS, how it advertises HTTP/3 over UDP, and what each one changes on the wire.

---

## 1. Concepts to Understand (15 Minutes)

### 1.1 ALPN: Choosing the Protocol Inside the Handshake
HTTP/2 over TLS (`h2`) is negotiated in the TLS handshake itself. The client lists the protocols it speaks in the ALPN extension, and the server picks one.
* No extra round trip, and no `Upgrade` dance like WebSockets.
* NGINX offers `h2` only on a `server` where **`http2 on;`** is set. Otherwise it picks `http/1.1`.
* The old form, `listen 443 ssl http2;`, has been deprecated since 1.25.1 and only warns. `http2` is now a per-server switch.
* **SNI and ALPN arrive together.** The `server` chosen by SNI decides which protocols are on offer.
* Plain-text HTTP/2 (`h2c`) has no ALPN. It works only with clients that assume HTTP/2 up front ("prior knowledge"). Browsers never do.

### 1.2 What HTTP/2 Changes

| | HTTP/1.1 | HTTP/2 |
| :--- | :--- | :--- |
| Requests per connection at once | One. Concurrency means opening more connections; browsers allow about 6 per host. | Many **streams** multiplexed on one connection (`http2_max_concurrent_streams`, default 128) |
| Header encoding | Plain text, repeated in full on every request | **HPACK**: Huffman coding plus a per-connection table of headers already sent. A repeat costs a few bytes. |
| Head-of-line blocking | Per connection: a slow response blocks the next request on it | Gone at the HTTP layer. **Still there at the TCP layer**: one lost packet stalls every stream until it's retransmitted. |
| In NGINX's log | `$connection_requests` counts sequential requests | The same variable counts streams on the connection; `$request_length` shows the compressed header size |

**BIG-IP lens:** this is the HTTP/2 profile on the client side of a full proxy. NGINX does the same translation: streams in, one request per upstream exchange out.

### 1.3 The Backend Is a Separate Decision
NGINX terminates the client's HTTP/2 or HTTP/3. What it sends upstream is chosen by `proxy_http_version`, independently.
* **The default upstream protocol is HTTP/1.1** with keepalive (Sprint 2 Day 2). The backend sees HTTP/1.1 no matter what the client spoke.
* Newer NGINX versions (the lab's 1.31.6 included) also accept **`proxy_http_version 2`** to talk HTTP/2 to backends that support it. The Sprint 2 mocks speak only HTTP/1.1. gRPC has its own `grpc_pass` (Sprint 10).
* `X-Forwarded-Proto` still says `https`, because that is the scheme, not the HTTP version.

### 1.4 HTTP/3 and QUIC
HTTP/3 runs over **QUIC**, a transport on **UDP** that has TLS 1.3 built in.

| Property | What it means |
| :--- | :--- |
| Streams are independent at the transport | A lost packet stalls only its own stream. That fixes HTTP/2's TCP head-of-line problem. |
| Handshake | Transport and TLS 1.3 together: 1 round trip, or 0 with early data. 0-RTT needs `ssl_early_data`, and it is **not available** when NGINX is built against plain OpenSSL (the lab's case), which uses a compatibility layer without early data. |
| Connection IDs | A connection survives a client IP change (Wi-Fi to cellular) |
| UDP | Firewalls and security groups need **UDP** opened on the port, and many middleboxes are less friendly to it |

**How NGINX listens**
* `listen 8443 quic;` opens a UDP socket next to the TCP `listen 8443 ssl;`.
* **`reuseport`**: with several workers, it lets the kernel give each worker its own socket, so packets of one QUIC connection keep reaching the same worker. It may appear **once per `address:port`**. A second server on the port that also sets it fails `nginx -t` with `duplicate listen options`.
* `http3 on` is the default once a `quic` listener exists.

**How clients find it**
* Browsers never try HTTP/3 first. They learn about it from an **`Alt-Svc: h3=":8443"`** response header sent over HTTP/1.1 or HTTP/2, cache that for `ma` seconds, and use HTTP/3 on later connections.
* No `Alt-Svc`, no HTTP/3, even though the UDP listener is up.
* (HTTPS DNS records can advertise it too. That's outside this lab.)

### 1.5 The Default Server Is Per Socket
TCP and UDP sockets on the same port number are **different sockets**, each with its own default server.
* A catch-all with `ssl_reject_handshake` (Day 1) that only has `listen 8443 ssl` protects **TCP only**.
* Over QUIC, the `lumina.local` server is the only one on UDP 8443, so it becomes the default and **serves unknown SNI names**.
* The catch-all needs its own `listen 8443 quic reuseport default_server;`. (`reuseport` moves to it, because it can only appear once.)

---

## 2. Lab Setup (5 Minutes)

```bash
cd /srv/nginx-journey/sprints/sprint-3/lab
../../sprint-2/lab/mocks.sh start          # api-node-1 :8001, api-node-2 :8002, chat-ws :8003
cp day2_nginx.conf nginx.conf
ngx -t && (ngx -s reload 2>/dev/null || ngx)
source helpers.sh
docker pull -q alpine/curl-http3:8.11.0    # HTTP/3 client; the host curl 7.81 has no HTTP/3
```
* `day2_nginx.conf` is Day 1's result with the TLS policy at `http` level, plus an `/api/` location to the Sprint 2 mocks.
* HTTP/2 starts **off** so you can turn it on.
* The access log shows `proto`, `alpn`, `conn` (connection serial), `reqs` (requests so far on that connection) and `len` (`$request_length`).
* New helpers: `h3 [curl args] URL` runs curl with HTTP/3 in a container, and `h3alt` makes two requests from one client that remembers `Alt-Svc`.

---

## 3. Hands-on Guided Discovery Activities (35 Minutes)

### Activity 3.1: ALPN (5 min)
```bash
c -o /dev/null -w 'HTTP/%{http_version}\n' https://lumina.local:8443/
hs -alpn h2,http/1.1
```
The client offered `h2`, but NGINX chose `http/1.1`. Add `http2 on;` to the lumina.local server, then:
```bash
ngx -t && ngx -s reload
c -o /dev/null -w 'HTTP/%{http_version}\n' https://lumina.local:8443/                  # HTTP/2
hs -alpn h2,http/1.1                                                                     # alpn=h2
c --http1.1 -o /dev/null -w 'HTTP/%{http_version}\n' https://lumina.local:8443/        # a 1.1-only client still works
```

### Activity 3.2: Multiplexing (8 min)
Three requests that each take 2 seconds, sent at the same time:
```bash
U=https://lumina.local:8443/api
: > logs/access.log
time c --parallel -o /dev/null -o /dev/null -o /dev/null "$U/a?delay=2" "$U/b?delay=2" "$U/c?delay=2"
time c --http1.1 --parallel -o /dev/null -o /dev/null -o /dev/null "$U/a?delay=2" "$U/b?delay=2" "$U/c?delay=2"
time c --http1.1 --parallel --parallel-max 1 -o /dev/null -o /dev/null -o /dev/null "$U/a?delay=2" "$U/b?delay=2" "$U/c?delay=2"
cat logs/access.log
```

| Run | Time | Access log |
| :--- | :--- | :--- |
| HTTP/2 | ~2 s | One `conn` value, `reqs=1,2,3` |
| HTTP/1.1, parallel | ~2 s | **Three** `conn` values, each `reqs=1` |
| HTTP/1.1, one connection | ~6 s | One `conn`, `reqs=1,2,3`, one after another |

* HTTP/2 gets HTTP/1.1's parallelism from a single TCP and TLS connection.
* *Journal:* a page loads 80 assets. Roughly how many TLS handshakes does a browser make with HTTP/1.1 (6 connections per host) vs HTTP/2?

### Activity 3.3: HPACK in the Access Log (5 min)
Send the same 600-byte header twice on one connection:
```bash
BIG="X-Trace: $(printf 'a%.0s' $(seq 600))"
: > logs/access.log
c -H "$BIG" -o /dev/null -o /dev/null https://lumina.local:8443/one https://lumina.local:8443/two
c --http1.1 -H "$BIG" -o /dev/null -o /dev/null https://lumina.local:8443/one https://lumina.local:8443/two
cat logs/access.log
```
* **HTTP/2:** `len=422` for the first request (Huffman-coded), then **`len=11`** for the second. The whole header set was already in the connection's HPACK table.
* **HTTP/1.1:** `len=695` both times.
* *Journal:* cookies and auth tokens repeat on every request. Who benefits most from HPACK: a mobile client on a slow uplink, or a server-to-server API call?

### Activity 3.4: What the Backend Sees (3 min)
```bash
c https://lumina.local:8443/api/v1/x | jq '{http_version, xfp: .headers["X-Forwarded-Proto"], conn_requests}'
```
* The backend sees HTTP/1.1 and `X-Forwarded-Proto: https`.
* `conn_requests` climbs across calls: upstream keepalive (Sprint 2) works the same whatever protocol the client used.

### Activity 3.5: HTTP/3 (9 min)
Add to the lumina.local server, under `http2 on;`:
```nginx
listen 8443 quic reuseport;
add_header Alt-Svc 'h3=":8443"; ma=86400' always;
```
```bash
ngx -t && ngx -s reload
ss -lunp | grep 8443                                       # UDP sockets now, one per worker
h3 --http3-only https://lumina.local:8443/                 # "Lumina over HTTP/3.0"
h3 --http3-only https://lumina.local:8443/api/v1/x | jq .http_version   # the backend still gets HTTP/1.1
c -sI https://lumina.local:8443/ | grep -i alt-svc         # the advertisement, sent over HTTP/2
h3alt                                                      # request 1: HTTP/2, request 2: HTTP/3
tail -3 logs/access.log
```
* `h3alt` behaves like a browser: the first request goes over TCP and learns `Alt-Svc`, and the next one uses QUIC.
* *Try it:* comment out the `add_header Alt-Svc` line, reload, and run `h3alt`. Both requests stay on HTTP/2, even though UDP 8443 is still listening. Put it back.

### Activity 3.6: QUIC and the Default Server (5 min)
Day 1's catch-all refuses unknown names over TCP. Try the same over QUIC:
```bash
SNI=evil.example hs                                                                  # TCP: FAILED (112)
h3 --http3-only -k --resolve evil.example:8443:127.0.0.1 -o /dev/null -w '%{http_code}\n' https://evil.example:8443/
```
Predict, then run.

<details>
<summary>Result</summary>

* TCP is refused.
* Over QUIC, the unknown name gets an **HTTP response**: the handshake succeeded, with the Lumina certificate, because the catch-all has no UDP listener.
</details>

Fix it: give the catch-all its own QUIC listener and move `reuseport` there.
```nginx
server {
    listen 8443 ssl default_server;
    listen 8443 quic reuseport default_server;
    ssl_reject_handshake on;
}
# ... and in the lumina.local server:
listen 8443 quic;
```
```bash
ngx -t && ngx -s reload
h3 --http3-only -k --max-time 5 --resolve evil.example:8443:127.0.0.1 -o /dev/null -w '%{http_code}\n' https://evil.example:8443/   # 000: refused
h3 --http3-only -o /dev/null -w 'HTTP/%{http_version}\n' https://lumina.local:8443/                                               # HTTP/3
```
* The `000` takes the full 5 seconds. **Keep the time limit:** this quiche curl retries a refused QUIC handshake in a tight loop and keeps allocating memory. The `h3` helper sets `--max-time 5` and a 1 GB container memory limit by default. Re-`source helpers.sh` if your terminal loaded an older copy.

*Try it:* leave `reuseport` on **both** QUIC listeners and run `ngx -t`. That's the `duplicate listen options` error from concept 1.4.

---

## 4. Day 2 Concept Examination (10-Question Randomized Quiz)

👉 **http://&lt;lab-host&gt;:8090/quiz.html?sprint=3&day=2** (serve with `cd /srv/nginx-journey && python3 -m http.server 8090`)

---

## 5. Key Takeaways for Day 2
* **ALPN picks the protocol inside the TLS handshake.** NGINX offers `h2` only where `http2 on;` is set.
* **HTTP/2 multiplexes:** one connection, many streams. `$connection_requests` counts them, and `$request_length` exposes HPACK at work.
* **The client protocol and the upstream protocol are independent.** HTTP/1.1 upstream is the default, and the backend can't tell what the client spoke.
* **HTTP/3 is UDP plus `Alt-Svc`.** Without the header, clients never find the QUIC listener.
* **`reuseport` appears once per address:port**, and each socket (TCP, UDP) has its own default server. Protect both.
* **0-RTT needs a QUIC-capable TLS library.** With plain OpenSSL, NGINX's compatibility layer runs HTTP/3 without early data.

# Sprint 2 &bull; Day 1: How `proxy_pass` Builds the Request
**Date:** Tuesday, Oct 6  
**Estimated Time:** 60 Minutes (15 concepts, 5 setup, 35 lab, 10 quiz)  
**Theme:** A reverse proxy doesn't forward requests; it writes new ones. Learn exactly what NGINX writes.

---

## 1. Concepts to Understand (15 Minutes)

### 1.1 Two Connections, One Fresh Request
```
client ──TCP#1──► NGINX :8082 ──TCP#2──► backend :8001
         HTTP/2 or 1.1         HTTP/1.1 (proxy_http_version)
```
NGINX terminates the client's connection, picks a location, and then **writes a brand-new request** on a separate connection.
* **Request line:** built from the location and the `proxy_pass` URI rules (1.2).
* **Headers:**
  * Most client headers (`User-Agent`, `Cookie`, `Accept`...) are copied.
  * `Host` is **replaced** with `$proxy_host`.
  * Hop-by-hop headers (`Connection`, `Upgrade`, `Keep-Alive`, `TE`) are not forwarded.
  * Nothing about the client's IP is added.
* **The backend's view:** every request comes from NGINX's IP, and the backend has no idea the client used HTTPS.
* **Version note:** on nginx **1.29.7+** (the lab runs 1.31.6), the upstream side defaults to HTTP/1.1 with keepalive. Older builds default to HTTP/1.0 and `Connection: close`. More on Day 2.

### 1.2 `proxy_pass` URI Mapping Rules
The only question is: **does `proxy_pass` have a URI part** (anything after `host:port`, even a single `/`)?

| Form | Rule | `location /api/` + `GET /api/v1/x?p=2` |
| :--- | :--- | :--- |
| `proxy_pass http://b;` | **No URI.** Original request URI passed through unchanged. | `/api/v1/x?p=2` |
| `proxy_pass http://b/;` | **URI present.** The matched location prefix is replaced by the URI. | `/v1/x?p=2` |
| `proxy_pass http://b/v2/;` | Same: prefix replaced. | `/v2/v1/x?p=2` |

**It is string replacement, so slashes matter on both sides:**
* `location /api` + `proxy_pass http://b/;` turns `/api/v1/x` into **`//v1/x`**. It also matches `/apiary`, which becomes `/ary`, the same prefix trap as Sprint 1 Day 2.
* `location /api/` + `proxy_pass http://b/v2;` turns `/api/users` into **`/v2users`**.

**Where there is no prefix to replace:**
* **Regex locations, named locations, `if` and `limit_except`** can't have a literal URI in `proxy_pass` (`nginx -t` fails).
  * Build the URI from captures instead: `proxy_pass http://b/$1;`.
  * Regex matching ignores the query string, so `$1` doesn't contain it. Append `$is_args$args` or it's lost.
* **Variables in `proxy_pass`** turn prefix replacement off. If you specify a URI with variables, it **replaces the entire original URI**.
  * `proxy_pass http://$be/;` sends every request to `/`.
  * To strip a prefix with a variable backend, use `rewrite ^/api/(.*)$ /$1 break;` and `proxy_pass http://$be;` (no URI).
  * A *hostname* in a variable needs a `resolver`. A literal hostname is resolved once at config load and never again until reload.

### 1.3 Header Rewriting: What the Backend Needs to Know
```nginx
proxy_set_header Host              $host;                       # client-facing name, not $proxy_host
proxy_set_header X-Real-IP         $remote_addr;                # the TCP peer NGINX saw
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;  # incoming chain + ", $remote_addr"
proxy_set_header X-Forwarded-Proto $scheme;                     # http / https, for redirects & cookies
```

**`$host` vs `$http_host`**
* `$host` is lowercased, has no port, and falls back to `server_name` when the client sent no `Host`.
* `$http_host` is the raw header. It may carry a port, or be empty.

**Trusting `X-Forwarded-For`**
* `$proxy_add_x_forwarded_for` **appends**, so the leftmost entry is whatever the client sent.
* Never make a security decision on the leftmost XFF entry.
* At the edge, trust `$remote_addr`. Behind a CDN or load balancer, use the realip module (`set_real_ip_from`).

**Removing and dropped headers**
* An empty value removes a header: `proxy_set_header Authorization "";`
* Header *names* containing underscores (`X_Tenant_Id`) are silently dropped by default (`underscores_in_headers off`).

### 1.4 The Inheritance Trap, Again
`proxy_set_header` follows the same rule as `add_header` (Sprint 1 Day 2): a level inherits from its parent **only if it defines none of its own**.
* One `proxy_set_header X-Request-ID $request_id;` inside a location silently discards every header set at `server`/`http` level.
* `Host` falls back to `$proxy_host`.
* There is no `proxy_set_header` equivalent of `add_header_inherit merge`.
* The production fix is a shared snippet file, `include`d in every location that adds its own headers.

---

## 2. Lab Setup (5 Minutes)

```bash
cd /srv/nginx-journey/sprints/sprint-2/lab
mkdir -p logs temp/{client,proxy,fastcgi,uwsgi,scgi}
export MOCK_BIND=0.0.0.0                # mocks on all interfaces (default: loopback only)
./mocks.sh start                        # api-node-1 :8001, api-node-2 :8002, chat-ws :8003
cp day1_nginx.conf nginx.conf
ngx -t && ngx                           # ngx helper from Sprint 1 Day 1; listens on 8082
```
`MOCK_BIND=0.0.0.0` makes the mocks reachable from off the box, so you can hit them directly as well as through NGINX. It's exported because later `./mocks.sh start` and `restart` commands (Day 2 stops and restarts nodes) read it too. If you open a new shell, export it again or the nodes come back on loopback only. Your security group still has to allow 8001-8003.

Paste this helper into your terminal. It shows exactly what the backend received. It only lasts for the current shell, so paste it again if you open a new terminal. It's only used today, so it doesn't need to go in `~/.bashrc`.
```bash
peek() {   # peek <path> [extra curl args...]
  curl -s -H 'Host: lumina.local' "${@:2}" "localhost:8082$1" | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except ValueError:                      # not from the mock: NGINX error page, etc.
    print("NOT FROM BACKEND:", " ".join(raw.split())[:100]); sys.exit()
print(d["method"], d["path"], d["http_version"], " <- from", d["peer"])
for k, v in d["headers"].items(): print(f"    {k}: {v}")'
}
peek /a/hello
```
The mock backend echoes the raw request line, so URI mistakes like `//v1/x` are visible, not normalized away.

---

## 3. Hands-on Guided Discovery Activities (35 Minutes)

### Activity 3.1: The URI Mapping Drill (12 min)
`nginx.conf` has eight locations pointing at the same backend (`grep location nginx.conf` shows them all). Apply the rules from 1.2 and **write down your prediction for every row first**, then check each with `peek`.

Stuck after checking? [`day_01_uri_surgery.html`](day_01_uri_surgery.html) walks through every row visually. Open it in a browser; GitHub shows it as source.

| # | Location | `proxy_pass` | Request | Your prediction |
| :--- | :--- | :--- | :--- | :--- |
| a | `/a/` | `http://127.0.0.1:8001` | `/a/v1/stats?page=2` | |
| b | `/b/` | `http://127.0.0.1:8001/` | `/b/v1/stats` | |
| c | `/c` | `http://127.0.0.1:8001/` | `/c/v1/stats` | |
| c2 | `/c` | `http://127.0.0.1:8001/` | `/catalog` | |
| d | `/d/` | `http://127.0.0.1:8001/v2` | `/d/users` | |
| e | `/e/` | `http://127.0.0.1:8001/v2/` | `/e/users` | |
| f | `~ ^/f/(.*)$` | `http://127.0.0.1:8001/$1` | `/f/v1/items?page=2` | |
| g | `/g/` | `set $be 127.0.0.1:8001;`<br>`proxy_pass http://$be/;` | `/g/v1/stats` | |
| h | `/h/` | `set $be 127.0.0.1:8001;`<br>`rewrite ^/h/(.*)$ /$1 break;`<br>`proxy_pass http://$be;` | `/h/v1/items?page=2` | |

```bash
for p in '/a/v1/stats?page=2' /b/v1/stats /c/v1/stats /catalog /d/users /e/users \
         '/f/v1/items?page=2' /g/v1/stats '/h/v1/items?page=2'; do
  printf '%-22s -> ' "$p"; peek "$p" | head -1
done
```

<details>
<summary>Answers (check only after predicting)</summary>

| # | Backend receives | Why |
| :--- | :--- | :--- |
| a | `/a/v1/stats?page=2` | No URI: passed through unchanged |
| b | `/v1/stats` | `/b/` replaced by `/` |
| c | `//v1/stats` | `/c` replaced by `/`, and the remainder keeps its slash |
| c2 | `/atalog` | Prefixes match characters, not path segments |
| d | `/v2users` | `/d/` replaced by `/v2`, with no slash in between |
| e | `/v2/users` | Symmetric slashes |
| f | `/v1/items` | Query string lost; needs `$is_args$args` |
| g | `/` | Variable + URI: the URI replaces everything |
| h | `/v1/items?page=2` | Rewritten URI (with args) passed, because there is no URI in `proxy_pass` |
</details>

**Break it on purpose:** change location `f` to `proxy_pass http://127.0.0.1:8001/;` and run `ngx -t`. Read the `emerg` message, then revert it.

---

### Activity 3.2: What Crosses by Default (8 min)
`/api/` has only `proxy_pass http://lumina_api_nodes;`, with no headers configured.
```bash
peek /api/hello
```
Observe:
1. **`Host: lumina_api_nodes`**. That's `$proxy_host`, the upstream *group name*. A name-based virtual-hosting backend would serve its default site.
2. **`User-Agent` and `Accept`** came through untouched.
3. **`peer`** is 127.0.0.1 on a random port: NGINX's own connection. No header carries the client's address.

Now probe the edge cases:
```bash
peek /api/hello -H 'X-Tenant-Id: 42' -H 'X_Tenant_Id: 42'   # which one arrives?
peek /api/hello -H 'Authorization: Bearer abc'              # passed through by default
```

---

### Activity 3.3: Forwarding Headers & the XFF Chain (8 min)
Add the four forwarding headers at the **server** level (above the locations) and reload:
```nginx
proxy_set_header Host              $host;
proxy_set_header X-Real-IP         $remote_addr;
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
```
```bash
ngx -t && ngx -s reload
peek /api/hello
peek /api/hello -H 'X-Forwarded-For: 6.6.6.6'               # spoofed chain: who's leftmost?
curl -s -H 'Host: Lumina.LOCAL:8082' localhost:8082/api/hello | grep '"Host"'   # $host normalizes
curl -s --http1.0 -H 'Host:' localhost:8082/api/hello | grep '"Host"'           # no Host at all
```
*Questions to answer in your journal:*
* What did `X-Forwarded-For` look like with the spoofed header?
* Which entry would a naive rate limiter key on?
* With no `Host` from the client, where did the value come from?

*Try it:* temporarily switch to `Host $http_host` and repeat the last two curls. Revert before moving on.

---

### Activity 3.4: The Inheritance Trap (7 min)
Add a request ID header **inside** `location /api/` and reload:
```nginx
location /api/ {
    proxy_pass http://lumina_api_nodes;
    proxy_set_header X-Request-ID $request_id;
}
```
```bash
ngx -t && ngx -s reload && peek /api/hello
```
* `X-Request-ID` arrived.
* `Host` is back to `lumina_api_nodes`.
* `X-Real-IP`, `X-Forwarded-For` and `X-Forwarded-Proto` are gone.
* `nginx -t` said nothing.

**Fix it the production way:** move the four forwarding headers into a snippet and include it wherever a location sets its own headers:
```bash
cat > proxy_headers.conf <<'EOF'
proxy_set_header Host              $host;
proxy_set_header X-Real-IP         $remote_addr;
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
EOF
```
```nginx
location /api/ {
    proxy_pass http://lumina_api_nodes;
    include proxy_headers.conf;               # relative to the config file's directory
    proxy_set_header X-Request-ID $request_id;
}
```
```bash
ngx -t && ngx -s reload && peek /api/hello    # all five headers present
ngx -T | grep -n proxy_set_header             # -T dumps every file, snippets included: audit where headers are set
```

---

## 4. Day 1 Concept Examination (10-Question Randomized Quiz)

```bash
cd /srv/nginx-journey && python3 -m http.server 8090
```
👉 **http://&lt;lab-host&gt;:8090/quiz.html?sprint=2&day=1**
* 10 random questions from a 20-question pool: 8 scenario, 6 read-the-config, 3 diagnose, 3 recall.
* Answer order is shuffled on every attempt. Passing score: **80% (8 of 10)**.

---

## 5. Key Takeaways for Day 1
* **A proxy writes a new request.** Anything the backend needs to know about the client (name, IP, scheme) is your job to send.
* **One question decides URI mapping:** is there a URI part in `proxy_pass`? None means pass through unchanged. Present means replace the matched prefix. It's string replacement, so keep slashes symmetric.
* **Regex and variables change the rules.** Captures drop the query string unless you add `$is_args$args`. A URI with variables replaces the whole original URI.
* **`Host` defaults to `$proxy_host`.** Set `Host $host` unless you have a reason not to.
* **XFF's leftmost entry is client-controlled.** Trust only hops you add or explicitly trust.
* **`proxy_set_header` is all-or-nothing per level,** just like `add_header`. Use an `include` snippet, and verify with `nginx -T`.
* **Literal hostnames in `proxy_pass` resolve once.** DNS changes need a reload, or a `resolver` with a variable (Day 4 revisits this with `resolve`).

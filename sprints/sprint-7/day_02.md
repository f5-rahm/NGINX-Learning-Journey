# Sprint 7 &bull; Day 2: Asking Someone Else: `auth_request`
**Day:** 2 of 3  
**Estimated Time:** 70 Minutes (15 concepts, 5 setup, 40 activities, 10 quiz)  
**Theme:** Yesterday the edge decided by itself, from a certificate. Most access decisions need information the edge doesn't have: who owns this token, what role they have, whether they may do this. On BIG-IP that's an APM access policy, or an iRule doing an `HTTP::callout` (or sideband) to an authorization service. NGINX's tool is **`auth_request`**: before serving a request, ask another HTTP service, and let its status code decide. Today you put Tidewater's ops tool behind its authorization service, and meet the module's surprises: what the service actually sees, what happens when it fails, and how caching decisions can quietly hand out the wrong one.

---

## 1. Concepts to Understand (15 Minutes)

### 1.1 How `auth_request` Works
* `auth_request /_authz;` in a location makes NGINX send a **subrequest** to the URI `/_authz` before the request is proxied. The subrequest is handled inside NGINX by another location, usually an `internal` one that `proxy_pass`es to the authorization service.
* **Only the status code matters:**

  | The service answers | The client gets |
  | :--- | :--- |
  | `2xx` | The request goes on |
  | `401` | `401`, with the service's `WWW-Authenticate` header copied over |
  | `403` | `403` |
  | Anything else (`404`, `302`, `500`, a timeout) | **`500`**, and `auth request unexpected status` in the error log |

* The response body is thrown away. To get anything else out of the answer, read its **headers**: `auth_request_set $var $upstream_http_<header>;` copies one into a variable for the main request, for example to pass it on with `proxy_set_header`.
* `auth_request` runs in the **access phase**, with `allow`/`deny`. After the rewrite phase, so a `return` in the same location wins without asking (Sprint 5's lesson).

### 1.2 What the Service Sees
The subrequest isn't a copy of the client's request:
* **It inherits the request headers** (`Authorization`, `Cookie` and the rest), which is how the service sees the credential.
* **The URI is the auth location's**, not the client's. Pass the original as a header: `proxy_set_header X-Original-URI $request_uri;`.
* **The method:** in the lab, a client's `POST` arrived at the service as a `GET` (Activity 3.4). Whatever your service bases a decision on, check that it actually receives it, and pass the original method explicitly (`X-Original-Method $request_method`).
* **The body:** a subrequest would pass it, but the service doesn't need it. `proxy_pass_request_body off;` and `proxy_set_header Content-Length "";` are the standard pair.

### 1.3 Failing Closed
Every request now depends on the authorization service:
* A service that's down, slow or misrouted gives `500`, not a free pass. That's correct for security, and it means the service's availability is the application's.
* **`proxy_read_timeout`, `proxy_connect_timeout`** in the auth location decide how long a request waits. The defaults are 60 seconds.
* Keep the auth location **`internal`**, so clients can't call the service through the edge.

### 1.4 Caching Decisions
One extra round trip per request is the price. With a busy API, the authorization service sees the edge's whole request rate. `proxy_cache` works in the auth location like anywhere else:
* **The cache key decides whose answer is reused.** It must contain everything the decision depends on: the credential, and anything else the service looks at (the method, the URI if decisions differ per path). A key that's missing an input hands one request's decision to another.
* **Cache negative answers too** (`proxy_cache_valid 200 401 403 30s;`), or one client with a bad token can make the service answer the same question all day.
* **The lifetime is a revocation delay.** A token removed from the service keeps working until its cached `200` expires.

### 1.5 `satisfy`: Combining Checks
`allow`/`deny`, `auth_basic` and `auth_request` all run in the access phase:
* **`satisfy all`** (the default): every one of them must pass.
* **`satisfy any`:** one is enough. `satisfy any; allow 10.57.0.5; deny all; auth_request /_authz;` means "the office, or a valid token". Requests that match `allow` never call the service.

### 1.6 BIG-IP Lens

| Need | BIG-IP | NGINX |
| :--- | :--- | :--- |
| Ask an external service per request | APM per-request policy (HTTP connector), or an iRule with `HTTP::callout` / sideband | `auth_request` + an `internal` location |
| Read the service's answer | Session variables, the callout response | `auth_request_set $v $upstream_http_<name>` |
| Pass identity to the server | `HTTP::header replace` | `proxy_set_header` |
| Cache the decision | `table set -subtable authz $token $verdict 30` | `proxy_cache` in the auth location |
| Office network or token | Policy branch on IP, then a token check | `satisfy any` + `allow` + `auth_request` |
| Service down | Your iRule decides (and `catch` matters) | Always `500` |

---

## 2. Lab Setup (5 Minutes)

```bash
cd /srv/nginx-journey/sprints/sprint-7/lab
cp day2_nginx.conf nginx.conf           # Day 1's finished partner API; the ops tool is still open
./lab.sh up                             # or ./lab.sh reload if the lab is still up from Day 1
source helpers.sh
```
The ready check ends with `Sprint 7 lab ready: ...`. Today's port is **:8091**, the ops tool under `/ops/`.

| Piece | What it is |
| :--- | :--- |
| `/ops/` on :8091 | The ops tool (`s7-apps:9002`). It answers with JSON: the `ops_user` and `ops_role` it received, whether it got a token (`token_received`) and the request body's size. |
| The authz service (`s7-apps:9100`, `GET /check`) | Reads `Authorization: Bearer <token>`. An unknown or missing token: `401` with `WWW-Authenticate`. A known one: `200` with `X-Ops-User` and `X-Ops-Role`. **Viewers may only read** (`GET`, `HEAD`): anything else is `403`. The method it judges is `X-Original-Method` if present, otherwise the method of the check itself. |
| Ops tokens | In `lab/secrets/ops_tokens.json`: one for **carol** (viewer) and one for **dave** (admin) |
| The head office | 10.57.0.5 on the lab network |

| Command | What it does |
| :--- | :--- |
| `ops WHO PATH [curl options]` | One request to :8091 as `viewer`, `admin`, `bogus` (a made-up token) or `none` |
| `office PATH [curl options]` | One request to :8091 from the head office's address |
| `r PATH` / `rh PATH` | One request to :8091 with no token (`rh` shows the headers) |
| `astats` / `areset` | The apps' counters, including `authz.calls` and the last check the service saw (`authz.last`) / zero them |
| `elog [N]` / `alog [N]` | The edge's error log / access log |

---

## 3. Hands-on Guided Discovery Activities (40 Minutes)

### Activity 3.1: Ask Before Serving (7 min)
```bash
areset
ops none /ops/fleet | grep -E '<-|ops_|token'
```
`200` for anyone. In the `:8091` server, replace `location /ops/ { ... }` with:
```nginx
location /ops/ {
    auth_request /_authz;
    proxy_pass http://ops;
}

location = /_authz {
    internal;
    proxy_pass http://authz/check;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
}
```
```bash
./lab.sh reload
for w in none bogus viewer; do echo "== $w"; ops $w /ops/fleet | grep -E '<-|ops_|token|title'; done
rh /ops/fleet | grep -iE '^HTTP|www-auth'
r /_authz | head -1
astats | grep -A8 '"authz"'
```
* `none` and `bogus`: `401`, with `WWW-Authenticate: Bearer realm="tidewater-ops"` copied from the service.
* `viewer`: `200`, but `ops_user` and `ops_role` are `null`, and `token_received` is `true`.
* `/_authz` from outside: `404`, because it's `internal`.

<details>
<summary>The service answered with <code>X-Ops-User: carol</code>. Why didn't the ops tool get it?</summary>

Those are headers of the **subrequest's** response. NGINX uses its status and then discards it. Nothing reaches the main request unless you copy it with `auth_request_set` (next activity).
</details>

### Activity 3.2: Passing the Answer On (5 min)
In `location /ops/`, after `auth_request`:
```nginx
auth_request_set $ops_user $upstream_http_x_ops_user;
auth_request_set $ops_role $upstream_http_x_ops_role;
proxy_set_header X-Ops-User $ops_user;
proxy_set_header X-Ops-Role $ops_role;
proxy_set_header Authorization "";
```
```bash
./lab.sh reload
ops viewer /ops/fleet -H 'X-Ops-Role: admin' | grep -E 'ops_|token'
```
`"ops_user": "carol"`, `"ops_role": "viewer"` (not the `admin` the client claimed), `"token_received": false`.

<details>
<summary>Why remove the <code>Authorization</code> header on the way to the ops tool?</summary>

The edge has already checked it, and the tool now gets a verified user and role instead. Forwarding the token gives every backend (and its logs, and its bugs) a credential it can replay elsewhere. Pass what the backend needs: the identity, not the secret.
</details>

### Activity 3.3: The Method Trap (6 min)
Carol is a viewer. Viewers can't change things:
```bash
ops viewer /ops/fleet -X POST -d 'truck=7' | grep -E '<-|method|role|body'
ops viewer /ops/fleet -X DELETE | head -1
astats | grep -A6 '"last"'
```
<details>
<summary>Both got <code>200</code>. What did the authz service see?</summary>

`"method_seen": "GET"` and `"x_original_method": null`. The subrequest reached the service as a `GET`, whatever the client sent, so the service judged a read and allowed it. The body went to the ops tool (`body_bytes: 7`), so the change happened.
</details>

Tell the service what the client is really doing. In `location = /_authz`:
```nginx
proxy_set_header X-Original-Method $request_method;
proxy_set_header X-Original-URI    $request_uri;
```
```bash
./lab.sh reload
ops viewer /ops/fleet -X POST -d 'truck=7' | head -1
ops admin  /ops/fleet -X POST -d 'truck=7' | grep -E '<-|body'
astats | grep -A6 '"last"'
```
`403` for carol; `200` for dave with `body_bytes: 7`. The service now sees `x_original_method: POST`. Inside the auth location, `$request_method` is still the client's method.

### Activity 3.4: When the Service Misbehaves (5 min)
A typo in the service's path. In `location = /_authz`, change `/check` to `/chek`:
```bash
./lab.sh reload
ops viewer /ops/fleet | head -1; elog 1
```
`500`, and `auth request unexpected status: 404`. Now a slow service: change `/chek` to `/slow` (it takes 3 seconds) and add `proxy_read_timeout 1s;` to the location:
```bash
./lab.sh reload
time (ops viewer /ops/fleet | head -1); elog 2
```
`500` after one second: `upstream timed out`, then `auth request unexpected status: 504`.

<details>
<summary>Is "every request gets a <code>500</code> when the authorization service is down" a bug?</summary>

No, it's failing closed, which is what you want from an access check. The alternative ("if authz is down, let everyone in") turns an outage of a small service into a security incident. What you control is how long a request waits (timeouts), how often the service is asked (caching, next), and the service's own availability.
</details>

Put it back: `/check`, and remove `proxy_read_timeout 1s;`. Reload.

### Activity 3.5: Fewer Questions, Not Wrong Answers (10 min)
```bash
areset; for i in 1 2 3 4 5; do ops viewer /ops/fleet >/dev/null; done; astats | grep '"calls"'
```
Five requests, five calls. Cache the answers. In `http`, before the servers:
```nginx
proxy_cache_path temp/cache/authz keys_zone=authz:1m max_size=10m inactive=1m;
```
In `location = /_authz`:
```nginx
proxy_cache       authz;
proxy_cache_key   $http_authorization;
proxy_cache_valid 200 401 403 30s;
```
And to see the cache at work, in `location /ops/` and in the `log_format`:
```nginx
auth_request_set $authz_cache $upstream_cache_status;
```
```nginx
log_format edge '$remote_addr "$request" $status ssl_verify=$ssl_client_verify partner="$partner" '
                'ops="$ops_user" authz_cache=$authz_cache';
```
```bash
./lab.sh reload
areset; for i in 1 2 3 4 5; do ops viewer /ops/fleet >/dev/null; done; astats | grep '"calls"'; alog 5
```
One call: the log shows `authz_cache=MISS`, then `HIT`. Now carol tries a change again:
```bash
ops viewer /ops/fleet -X POST -d 'truck=7' | grep -E '<-|role'
```
<details>
<summary>Carol's <code>POST</code> is allowed again. What went wrong?</summary>

The cache key is the token only. Carol's `GET` was judged `200` and cached under her token, and her `POST` has the same token, so the cached `200` answered it without asking the service. The key must include every input of the decision: here the token **and** the method.
</details>

```nginx
proxy_cache_key   "$http_authorization $request_method";
```
```bash
./lab.sh reload
ops viewer /ops/fleet -X POST -d 'truck=7' | head -1
ops viewer /ops/fleet | head -1
```
`403`, then `200`.

<details>
<summary>Dave's token is stolen and removed from the service. How long can the thief keep using it?</summary>

Up to 30 seconds (`proxy_cache_valid 200 ... 30s`): the edge keeps answering from its cached `200`. That's the trade between load on the service and how fast a revocation takes effect. Pick the lifetime as a security decision, not a performance one.
</details>

<details>
<summary>Why does <code>$upstream_cache_status</code> in the <code>log_format</code> alone show <code>-</code>?</summary>

In the access log, `$upstream_*` variables describe the **main** request's upstream (the ops tool), which isn't cached. The authz cache belongs to the subrequest. `auth_request_set` copies the subrequest's value into a variable the main request can log.
</details>

### Activity 3.6: The Office Doesn't Need a Token (7 min)
The head office's wall screen shows `/ops/status` and has no token. In the `:8091` server, add:
```nginx
location = /ops/status {
    satisfy any;
    allow 10.57.0.5;
    deny  all;
    auth_request     /_authz;
    auth_request_set $ops_user $upstream_http_x_ops_user;
    auth_request_set $ops_role $upstream_http_x_ops_role;
    auth_request_set $authz_cache $upstream_cache_status;
    proxy_set_header X-Ops-User $ops_user;
    proxy_set_header X-Ops-Role $ops_role;
    proxy_set_header Authorization "";
    proxy_pass http://ops;
}
```
```bash
./lab.sh reload
office /ops/status | head -1
r /ops/status | head -1
ops viewer /ops/status | grep -E '<-|ops_user'
office /ops/fleet | head -1
alog 4
```
* The office: `200` for `/ops/status`. The log shows `ops="-"`: the authz service was never asked.
* The host without a token: `401`. With carol's token: `200` as carol.
* The office on `/ops/fleet`: `401`. The exception is only for the status page.

<details>
<summary>What if the wall screen's address were in <code>allow</code> but the location kept <code>satisfy all</code> (the default)?</summary>

Then both checks must pass: the office would need a token too, and everyone else would be refused by `deny all` even with a token. `satisfy any` turns the access checks into alternatives.
</details>

---

## 4. Day 2 Concept Examination (10-Question Randomized Quiz)

```bash
cd /srv/nginx-journey && python3 -m http.server 8090
```
👉 **http://&lt;lab-host&gt;:8090/quiz.html?sprint=7&day=2**

When you're done for the day: `./lab.sh down`.

---

## 5. Key Takeaways for Day 2
* **`auth_request` delegates the decision, by status code:** `2xx` passes, `401`/`403` are passed on, anything else is a `500`.
* **The service sees a subrequest, not the client's request.** Pass `X-Original-Method` and `X-Original-URI`; turn off the body.
* **`auth_request_set` + `proxy_set_header`** carry the answer to the backend, and overwrite what the client claimed. Don't forward the credential itself.
* **It fails closed.** Set timeouts in the auth location, and keep it `internal`.
* **Cache decisions with a key that holds every input** (credential and method here), cache refusals too, and treat the lifetime as a revocation delay.
* **`satisfy any`** combines `allow` and `auth_request` as alternatives.

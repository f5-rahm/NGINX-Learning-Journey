# Sprint 6 &bull; Day 2: Signatures, Bodies and Shared State
**Day:** 2 of 3  
**Estimated Time:** 70 Minutes (15 concepts, 5 setup, 40 activities, 10 quiz)  
**Theme:** Day 1 ended with an edge that believes any token it can decode. Today it learns to check signatures with a key it never writes down, signs its own download links, edits responses as they stream past, refuses bad orders before the application sees them, and keeps a revocation list that every worker shares. In BIG-IP terms: `CRYPTO::sign`, `HTTP::payload`, `HTTP::collect` and `table`, without TCL.

---

## 1. Concepts to Understand (15 Minutes)

### 1.1 Signatures With HMAC, and Where the Key Lives
* **An HMAC** is a hash of a message mixed with a secret key. Only someone with the key can produce the right value, and changing one byte of the message changes all of it. njs computes it with the `crypto` module: `crypto.createHmac('sha256', key).update(message).digest('hex')` (or `'base64url'`).
* **A session token (JWT, HS256)** is `header.claims.signature`, where the signature is the HMAC of `header.claims`. Verifying means computing that HMAC with your key and comparing; decoding the claims (Day 1) proves nothing.
* **Check more than the signature:**
  * The **algorithm** in the header must be the one you expect. Never let the token choose.
  * **Expiry** (`exp`, Unix seconds) must be in the future.
  * The session mustn't be **revoked** (concept 1.5).
* **The key belongs in the environment, not in a file.** NGINX starts its workers with an **empty environment** apart from `TZ`. The `env LUMINA_KEY;` directive (main context) passes that one variable through, and the script reads `process.env.LUMINA_KEY`. Without it, `process.env` is empty and every check fails closed.
* **What the environment protects against, and what it doesn't:**
  * It keeps the key out of `nginx.conf`, the script, git, and `nginx -T` output.
  * It doesn't hide the key from anyone who can run `docker inspect` or read `/proc` on the host. In production it comes from a secrets manager or vault, injected at start (Sprint 8 covers Kubernetes Secrets).
  * BIG-IP's parallel: keys in the FIPS/NetHSM store versus a key pasted into an iRule.

### 1.2 Signed Links: Native or Script
A signed link grants access to one URL until a time, without a session: `/downloads/report.pdf?expires=1793736107&sig=...`.

| | Native `secure_link` | njs |
| :--- | :--- | :--- |
| Hash | **MD5** of an expression you build (`secure_link_md5`) | Anything `crypto` offers: HMAC-SHA256 here |
| Secret | **Written in the expression in `nginx.conf`** | `process.env`, from outside the configuration |
| Result | `$secure_link`: empty = bad, `0` = expired, `1` = good | Whatever the function decides |
| Cost | No script, can't throw | A script per request |

Native is the right answer when MD5 is acceptable and the secret can live in the configuration. MD5 is broken for collisions, and an MD5 of "secret + data" isn't an HMAC. When policy says SHA-256 and the secret stays outside the file, njs earns its place.

### 1.3 Changing Responses: Header and Body Filters
* **`js_header_filter`** runs once, when the upstream's headers arrive. It can add, change or delete `r.headersOut`.
* **`js_body_filter`** runs for **every piece** of the body as it streams through, with `(r, data, flags)`. It passes on what it wants with `r.sendBuffer(data, flags)`; `flags.last` marks the final piece.
* **If the body changes size, the length must go.** The origin's `Content-Length` arrives with the headers, before the filter has seen a byte. Keep it and NGINX sends the old length with a longer body: the client stops reading early, and on a keepalive connection the leftover bytes can be misread as the start of the next response. Delete it in the header filter, and NGINX switches to chunked encoding (or closes the connection for HTTP/1.0).
* **Pieces have edges.** A pattern split across two pieces isn't matched. Small JSON responses arrive in one piece; for large ones, buffer or design the pattern around it.
* BIG-IP: `HTTP::collect` + `HTTP::payload replace` in `HTTP_RESPONSE_DATA`, or a Stream profile.

### 1.4 Reading Request Bodies, and Getting Another Opinion
* **In a `js_content` handler, the body is read before the function runs**, so `r.requestText` holds it. Bodies larger than the buffer are spooled to a temporary file and njs reads them back. `client_max_body_size` still applies first.
* **Having decided, the handler can pass the request on:**
  * `r.internalRedirect('@app')` hands the **same** request (method, headers, body) to another location, for example one that proxies.
  * `r.subrequest('/uri', options)` makes a **separate** internal request through NGINX's own locations, waits, and lets the script use the answer.
  * `ngx.fetch('http://...')` is an HTTP client inside the worker: it bypasses your locations and upstreams, needs a `resolver` for names, and has its own timeouts and size limits.
* **`js_set` handlers must be synchronous.** An `await` inside one fails with `async operation inside "..." variable handler` and an empty value.

### 1.5 Shared State and Background Work
* **`js_shared_dict_zone zone=name:1m`** (http level) is a key-value store in shared memory, visible to every worker as `ngx.shared.name`: `get`, `set`, `has`, `delete`, `keys`, `incr`. Values are strings or numbers. An entry can expire (`timeout=`), and the zone can evict the oldest entries when full (`evict`).
* **`js_periodic function interval=2s`** (in a location, never reached by requests) runs a function on a timer, with no request. By default it runs **on worker 0 only**, so only one worker does the work; the shared dictionary carries the result to all of them.
* Together they make a **pull-based policy feed**: every few seconds, fetch a list (revoked sessions, blocked keys, feature flags) and put it where every request can check it in microseconds.
* If the fetch fails, keep the last list and log. Whether that's the right failure mode (fail open on stale data, or fail closed) is a policy decision. Write it down.
* BIG-IP: `table` for the store, `after -periodic` or an iCall script for the timer, `HTTP::sideband` or an iCall-pushed data group for the fetch.

### 1.6 BIG-IP Lens

| Need | BIG-IP | NGINX |
| :--- | :--- | :--- |
| Verify a signature | `CRYPTO::verify` / `CRYPTO::sign` in an iRule | `crypto.createHmac` in njs |
| A secret outside the config | FIPS / NetHSM key store, iFile | `env` + `process.env`, injected by the platform |
| Signed URLs | iRule (or APM) | `secure_link` (MD5) or njs (any hash) |
| Rewrite response bodies | Stream profile, `HTTP::payload replace` | `js_header_filter` + `js_body_filter` |
| Inspect request bodies | `HTTP::collect` in `HTTP_REQUEST_DATA` | `r.requestText` in `js_content` |
| Call another service | `HTTP::sideband` / `SIDEBAND::` | `ngx.fetch`, `r.subrequest` |
| Device-wide state | `table` | `js_shared_dict_zone` |
| Timers | `after -periodic`, iCall | `js_periodic` |

---

## 2. Lab Setup (5 Minutes)

```bash
cd /srv/nginx-journey/sprints/sprint-6/lab
cp day2_nginx.conf nginx.conf           # Day 1's edge: hello, count, client_lang, /edge/info
cp day2_lumina.js lumina.js             # the script as Day 1 left it
./lab.sh up                             # or ./lab.sh reload if the lab is still up
source helpers.sh
```
New helpers today:

| Command | What it does |
| :--- | :--- |
| `link PATH [--ttl S] [--key K]` | A download link signed with the lab key: `PATH?expires=...&sig=...` (`--ttl -10`: already expired) |
| `revoke ID` / `unrevoke [ID]` | Put a session ID on the application's revocation list, or take it off |
| `ostats` / `./lab.sh reset` | The application's counters: requests per pool and URI, the last `X-User` it saw |

The application has two new paths: `/api/account` returns an account record with **card numbers** in it, and `/_revoked` lists revoked session IDs.

---

## 3. Hands-on Guided Discovery Activities (40 Minutes)

### Activity 3.1: Verify the Signature (10 min)
At the top of `lumina.js`, under the two comment lines:
```js
import crypto from 'crypto';
```
Above `// GET /edge/info`, a function that only returns claims it can trust:
```js
// The session's claims if its signature is Lumina's and it hasn't expired; null otherwise
function session(r) {
    var token = r.variables.cookie_lumina_session;
    var key = process.env.LUMINA_KEY;
    if (!token || !key) {
        return null;
    }
    var parts = token.split('.');
    if (parts.length != 3) {
        return null;
    }
    var expected = crypto.createHmac('sha256', key).update(parts[0] + '.' + parts[1]).digest('base64url');
    if (expected != parts[2]) {
        return null;
    }
    var c = claims(r);
    if (!c || typeof c.exp != 'number' || c.exp <= Date.now() / 1000) {
        return null;
    }
    return c;
}
```
In `info`, replace the `session: claims(r)` line with three lines (note the commas):
```js
        session: claims(r),
        verified: session(r),
        env: Object.keys(process.env)
```
```bash
./lab.sh reload
r /edge/info -b "lumina_session=$(token alice --plan beta)"
```
<details>
<summary>Why is a token signed with the right key "verified": null?</summary>

`"env":[]`: the worker can't see `LUMINA_KEY`. The container has it, but NGINX starts its workers with an empty environment (apart from `TZ`), so `process.env.LUMINA_KEY` is `undefined` and `session()` fails closed. Without that guard, `createHmac` with an undefined key would have thrown, and every request with a cookie would get a `500`.
</details>

Pass the variable through. In `nginx.conf`, in the main context above `events`:
```nginx
env LUMINA_KEY;                     # pass this one variable through to the workers
```
```bash
./lab.sh reload
r /edge/info -b "lumina_session=$(token alice --plan beta)" | grep -o '"verified".*'
r /edge/info -b "lumina_session=$(token mallory --plan beta --key guess)" | grep -o '"verified".*'
r /edge/info -b "lumina_session=$(token alice --plan beta --ttl -60)" | grep -o '"verified".*'
```
Alice is verified (`"env":["LUMINA_KEY"]`); Mallory's guessed key and Alice's expired token are `null`. Day 1's forgery is closed.

Now tell the application who the user is. Add this function above `// GET /edge/info`, and `user` to the export list:
```js
// js_set $session_user: the sub of a valid session, or empty
function user(r) {
    var s = session(r);
    return s ? String(s.sub) : '';
}
```
In `nginx.conf`, at `http` level under the other `js_set`:
```nginx
js_set $session_user lumina.user;
```
and in `location /api/`:
```nginx
proxy_set_header X-User $session_user;
```
```bash
./lab.sh reload
r /api/me -b "lumina_session=$(token alice)" | grep x_user
r /api/me -H 'X-User: admin' | grep x_user
r /api/me -H 'X-User: admin' -b "lumina_session=$(token mallory --key guess)" | grep x_user
r /me -H 'X-User: admin' | grep x_user
```
<details>
<summary>Three of these are right. Which one isn't, and why?</summary>

* `/api/me`: Alice's session gives `"x_user": "alice"`, and a client's own `X-User: admin` becomes `null`, with or without a forged session. `proxy_set_header X-User $session_user` **replaces** whatever the client sent, and an empty value means the header isn't sent at all.
* `/me` goes through `location /`, which has no `proxy_set_header X-User`, so the client's `X-User: admin` reaches the application untouched. Any location that proxies to an application that trusts `X-User` must set it (or clear it). Put the line at `server` level, or in every location (it's inherited only by locations with no `proxy_set_header` of their own, like `add_header`).
</details>

### Activity 3.2: Signed Links, Native and Scripted (8 min)
First the native module. In `nginx.conf`, above `location /api/`:
```nginx
location /files/ {
    secure_link     $arg_md5,$arg_expires;
    secure_link_md5 "$secure_link_expires$uri lumina-native-secret";
    if ($secure_link = "")  { return 403; }
    if ($secure_link = "0") { return 410; }
    proxy_pass http://stable;
}
```
Sign a link the way the module expects (base64url of the binary MD5), and try it:
```bash
./lab.sh reload
E=$(( $(date +%s) + 300 ))
M=$(echo -n "$E/files/report.pdf lumina-native-secret" | openssl md5 -binary | base64 | tr +/ -_ | tr -d =)
r "/files/report.pdf?md5=$M&expires=$E" | head -1
r "/files/report.pdf" | head -1
r "/files/other.pdf?md5=$M&expires=$E" | head -1
```
`200`, `403`, `403`. It works, with no script. Now look at the configuration you just wrote and answer: **where is the secret?**

<details>
<summary>Answer</summary>

In `nginx.conf`, in plain text: in git, in backups, in every `nginx -T` dump and support bundle. And the hash is MD5 of a concatenation, not an HMAC. For many uses (expiring media links, low-value content) that's acceptable, and native wins. When the policy requires SHA-256 and a secret kept outside the configuration, that's the script's job.
</details>

The scripted version. Above `// GET /edge/info`, and `download` in the export list:
```js
// /downloads/: serve only links signed with HMAC-SHA256 over "<path>:<expires>"
function download(r) {
    var expires = r.args.expires;
    var sig = r.args.sig;
    var key = process.env.LUMINA_KEY;
    if (!key || !expires || !sig) {
        r.return(403);
        return;
    }
    var expected = crypto.createHmac('sha256', key).update(r.uri + ':' + expires).digest('hex');
    if (expected != sig) {
        r.return(403);
        return;
    }
    if (Number(expires) < Date.now() / 1000) {
        r.return(410);
        return;
    }
    r.internalRedirect('@files');
}
```
In `nginx.conf`, above `location /api/`:
```nginx
location /downloads/ {
    js_content lumina.download;
}

location @files {
    proxy_pass http://stable;
}
```
```bash
./lab.sh reload; ./lab.sh reset
L=$(link /downloads/report.pdf); echo "$L"
r "$L" | head -2
r /downloads/report.pdf | head -1
r "${L/report/other}" | head -1
r "$(link /downloads/report.pdf --ttl -10)" | head -1
r "$(link /downloads/report.pdf --key guess)" | head -1
ostats | grep -A2 by_uri
```
`200` (and the file), then `403`, `403`, `410`, `403`. The application saw **one** request: the refusals never left the edge. The signature check comes before the expiry check, so nobody learns anything from a forged link's expiry.

### Activity 3.3: Masking Card Numbers (8 min)
```bash
r /api/account
```
Two card numbers and a third in free text. Mask them on the way out. Above `// GET /edge/info`, and `maskCards` in the export list:
```js
// js_body_filter: replace card numbers with their last four digits
function maskCards(r, data, flags) {
    r.sendBuffer(data.replace(/\b(?:\d{4}[ -]?){3}(\d{4})\b/g, '****-****-****-$1'), flags);
}
```
In `location /api/`:
```nginx
js_body_filter lumina.maskCards;
```
```bash
./lab.sh reload
r /api/account
rh /api/account | grep -i content-length
```
<details>
<summary>The cards are masked. What else is wrong?</summary>

The response ends at `"x_user": null`: the closing `}` is gone, so it isn't valid JSON any more. `Content-Length: 229` is the application's length. Masking `4012888888881881` (16 characters) produced 19, so the body grew by 3 bytes, but the client stopped reading after 229. On a keepalive connection those 3 bytes would be read as the start of the next response.
</details>

Drop the length when the body changes. Above `maskCards`, and `dropLength` in the export list:
```js
// js_header_filter: the body is about to change size, so drop the origin's length
function dropLength(r) {
    delete r.headersOut['Content-Length'];
}
```
In `location /api/`, above the body filter:
```nginx
js_header_filter lumina.dropLength;
```
```bash
./lab.sh reload
r /api/account | tail -3
rh /api/account | grep -iE 'content-length|transfer-encoding'
```
The closing `}` is back, and the response is `Transfer-Encoding: chunked`. `order 1234567890` is untouched: the pattern needs 16 digits.

### Activity 3.4: Refusing Bad Orders at the Edge (6 min)
Above `// GET /edge/info`, and `orders` in the export list:
```js
// POST /api/orders: only a JSON object with an integer qty from 1 to 100 gets through
function orders(r) {
    var order = null;
    try {
        order = JSON.parse(r.requestText);
    } catch (e) {
        r.warn('order is not JSON: ' + e.message);
    }
    if (!order || typeof order != 'object' || !Number.isInteger(order.qty) || order.qty < 1 || order.qty > 100) {
        r.return(400, 'an order is a JSON object with an integer qty from 1 to 100\n');
        return;
    }
    r.internalRedirect('@app');
}
```
In `nginx.conf`, above `location /api/`:
```nginx
location = /api/orders {
    js_content lumina.orders;
}

location @app {
    proxy_pass http://stable;
    proxy_set_header X-User $session_user;
}
```
```bash
./lab.sh reload; ./lab.sh reset
r /api/orders -d '{"qty": 3, "sku": "LUM-1"}' -b "lumina_session=$(token alice)" | grep -E '<-|method|x_user|body_bytes'
r /api/orders -d '{"qty": 500}'
r /api/orders -d 'qty=3'
r /api/orders -d '[{"qty": 3}]'
ostats | grep -A2 by_uri
```
The good order reaches the application as a `POST` with its 26-byte body and `X-User: alice`; the other three get `400` from the edge, and the application counts one request.

<details>
<summary>Why internalRedirect and not r.subrequest here?</summary>

`internalRedirect` hands the **original** request (method, headers, the body already read) to `@app`, and the application's response goes straight back to the client. A `subrequest` would build a second request, wait for it, and leave the script to copy the status, headers and body back by hand. Use `subrequest` when the script needs the answer to decide something (an authorization check, combining two calls), and `internalRedirect` when it just needs to let the request through.
</details>

### Activity 3.5: A Revocation List Every Worker Shares (8 min)
A signed session is valid until it expires, even after the user logs out or an account is locked. The application keeps a list of revoked session IDs (`jti`) at `/_revoked`. Bring it to the edge every 2 seconds.

In `nginx.conf`, at `http` level under the `js_set` lines:
```nginx
js_shared_dict_zone zone=revoked:1m;     # one copy for all workers
```
and in the `server`, above `location = /edge/hello`:
```nginx
location @refresh {
    js_periodic lumina.refreshRevoked interval=2s;
}
```
In `lumina.js`, above `// GET /edge/info`, and `refreshRevoked` in the export list:
```js
// js_periodic: copy the application's revocation list into the shared dictionary
async function refreshRevoked(s) {
    var list;
    try {
        var reply = await ngx.fetch('http://s6-origin:8016/_revoked');
        list = (await reply.json()).revoked;
    } catch (e) {
        ngx.log(ngx.WARN, 'revocation list not refreshed: ' + e.message);
        return;
    }
    var dict = ngx.shared.revoked;
    var listed = {};
    list.forEach(function (jti) {
        listed[jti] = true;
        dict.set(String(jti), '1');
    });
    dict.keys().forEach(function (k) {
        if (!listed[k]) {
            dict.delete(k);
        }
    });
}
```
In `session()`, just above the final `return c;`:
```js
    if (c.jti && ngx.shared.revoked.has(String(c.jti))) {
        return null;
    }
```
And in `info`, replace the `env: Object.keys(process.env)` line with:
```js
        revoked: ngx.shared.revoked.keys(),
        worker: ngx.worker_id
```
```bash
./lab.sh reload; sleep 3
elog 1
```
<details>
<summary>Why didn't it refresh?</summary>

`revocation list not refreshed: no resolver defined`. `ngx.fetch` is its own HTTP client: it doesn't use the `upstream` blocks (which NGINX resolved when it loaded the configuration), so a hostname needs a `resolver`. Add it at `http` level:
```nginx
resolver 127.0.0.11 valid=10s;           # Docker's DNS: ngx.fetch needs a resolver for names
```
</details>

Add the resolver, then:
```bash
./lab.sh reload
T=$(token bob --jti s-42)
r /api/me -b "lumina_session=$T" | grep x_user
revoke s-42; sleep 2.5
r /api/me -b "lumina_session=$T" | grep x_user
r /edge/info -b "lumina_session=$T" | grep -oE '"verified".*'
unrevoke s-42; sleep 2.5
r /api/me -b "lumina_session=$T" | grep x_user
```
Bob is `bob`, then `null` within one refresh of being revoked (`"revoked":["s-42"]` in `/edge/info`), then `bob` again after `unrevoke`. No reload, no restart.

<details>
<summary>Only worker 0 runs the timer. How does worker 1 know?</summary>

The list is in the **shared dictionary**, not in a script variable. `js_periodic` runs on worker 0 by default (so the application gets one fetch every 2 seconds, not one per worker), and writes into shared memory that every worker reads. A global variable would have updated only worker 0's copy, and with the default engine not even that beyond the one call.
</details>

---

## 4. Day 2 Concept Examination (10-Question Randomized Quiz)

```bash
cd /srv/nginx-journey && python3 -m http.server 8090
```
👉 **http://&lt;lab-host&gt;:8090/quiz.html?sprint=6&day=2**

When you're done for the day: `./lab.sh down`.

---

## 5. Key Takeaways for Day 2
* **Verify, then trust:** signature (HMAC with your key), the algorithm you expect, expiry, revocation. Fail closed when the key is missing.
* **`env NAME;` passes a variable to the workers.** NGINX clears the environment otherwise. The key stays out of every file, but not out of reach of whoever runs the container.
* **`secure_link` is native but MD5 with the secret in `nginx.conf`.** njs gives you HMAC-SHA256 with the key outside it.
* **`proxy_set_header X-User $var` replaces the client's header,** and an empty value removes it. Every location that proxies must set it.
* **A body filter that changes the size must drop `Content-Length`** in a header filter, or responses are cut short.
* **`r.requestText` + `internalRedirect`** validates a body at the edge and passes the original request on.
* **`ngx.fetch` needs a `resolver`, bypasses your upstreams, and can't be used from `js_set`.**
* **`js_periodic` + `js_shared_dict_zone`** is a policy feed: one worker fetches, every worker reads.

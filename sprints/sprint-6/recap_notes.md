# Sprint 6 Recap Notes (working file)
Raw findings and clarifications collected during the sprint, to be shaped into the recap. Everything here was verified on nginx 1.31.6 with njs 1.0.1 in the `nginx:mainline` container, unless marked otherwise.

---

## Findings From Building the Sprint

### The engine and the language (Day 1)
* **`nginx:mainline` already ships njs:** `nginx-module-njs 1.31.6+1.0.1`, with `ngx_http_js_module.so` and `ngx_stream_js_module.so` (and `-debug` builds) in `/usr/lib/nginx/modules/`, plus the `njs` shell in `/usr/bin`. With `nginx -p /lab/`, `load_module` needs the absolute path.
* **"VM per request" is only half true in njs 1.0.** The default engine (`njs.engine` = `njs`) gave a global counter `1, 1, 1, 1`. With `js_engine qjs` (`njs.engine` = `QuickJS`) it went `1, 2, 3, ...`, separately per worker (worker 0 reached 10 while worker 1 was at 2). Eight parallel requests all landed on worker 0 and continued its count. `js_context_reuse 2` didn't change sequential behavior: it caps how many contexts are kept for reuse, not how often one is reused.
* `js_engine` works per location: `/edge/count` used QuickJS while the rest stayed on njs.
* **What the default engine lacks** (njs shell, `-n njs`): `class` (`Token "class" not supported in this version`), destructuring, spread (`...`), generators (`Unexpected token "*"`), `Map` (`"Map" is not defined`), BigInt (`10n`). All work with `-n QuickJS`. Both have arrow functions, template strings, `?.`, `??`, `let`/`const`, `async`/`await`, `Buffer` with `base64url`, `String.prototype.replaceAll`.
* **QuickJS has no `require`** (`typeof require` = `undefined`); njs has it. In the shell, `ngx` and `fetch` are undefined in both (they exist only inside nginx, as `ngx.fetch`). `eval` isn't available in either engine inside nginx (`Not implemented` / `'eval' is not defined`).
* `console.log(a, b)` in the njs shell prints each argument on its own line; join first for one line.
* **Scripts compile at configuration load.** An edit isn't seen until the reload. A syntax error fails `nginx -t` (`[emerg] SyntaxError: Unexpected token ";" at /lab/lumina.js:15`), the reload is refused, and the old script keeps running.
* **A run-time exception is a 500** for that request only: `js exception: TypeError: first argument undefined is not a string or Buffer-like object` for `lumina_session=garbage` (`Buffer.from(undefined)`). QuickJS words it differently: `js call exception: TypeError: cannot set property 'y' of undefined`.
* **`js_set` is computed once per request and only when used.** Used in `add_header` and `log_format` → one call per request. A request whose location and log line don't use it → no call. (`js_set $v f nocache` with three uses in one `return` also logged one call; not explored further.)

### Signatures, bodies and shared state (Day 2)
* **NGINX clears the workers' environment.** With `-e LUMINA_KEY=...` on the container and no `env` directive, `Object.keys(process.env)` was `[]`; with `env LUMINA_KEY;` it was `["LUMINA_KEY"]` and nothing else (another container variable, `OTHER`, wasn't visible).
* `crypto.createHmac('sha256', undefined)` throws `key is not a string or Buffer-like object`, so a missing key must be checked first, or every request with a cookie would be a 500.
* `crypto.createHmac(...).digest('base64url')` works, so an HS256 JWT signature compares directly against the token's third part.
* **Native `secure_link`** worked as documented: base64url of the binary MD5 of `"$secure_link_expires$uri secret"`; good → 200, missing → 403, other path → 403, past expiry → 410 (`$secure_link` = `0`). The secret is in `nginx.conf`.
* **A body filter that changes the size truncates the response** unless `Content-Length` is deleted. The origin's 229-byte `/api/account` became 232 bytes after masking (`4012888888881881` → `****-****-****-1881`, +3), the edge still sent `Content-Length: 229`, and curl received 229 bytes: the closing `}` was missing and the JSON didn't parse. curl didn't complain. Deleting the header in `js_header_filter` gave `Transfer-Encoding: chunked` (HTTP/1.0: `Connection: close`). Note: same-length replacements (`4111 1111 1111 1111` → `****-****-****-1111`, both 19) hide the bug.
* **`r.requestText` in `js_content`:** the body is read before the handler. A 300 KB order was spooled to `temp/client` (`a client request body is buffered to a temporary file`, then `http js reading request body from a temporary file`) and still validated.
* `r.internalRedirect('@app')` after reading the body passed the `POST` and its body (26 bytes) to the proxied location.
* **`ngx.fetch` to a hostname needs a resolver:** `no resolver defined` from `js_periodic`, logged at `warn` by the script's `catch`. `resolver 127.0.0.11` (Docker's DNS) fixed it. The `upstream` blocks don't help: they're resolved at load time and `ngx.fetch` doesn't use them.
* **`js_periodic` runs on worker 0 only** by default: with three workers, every tick was logged by worker 0.
* **An async `js_set` handler fails:** `async operation inside "f.slowset" variable handler` and `pending events while closing request`; the variable was empty and the request still got 200.
* At startup, the first `js_periodic` fetch can run before the origin is up: `connect failed`, then the next tick succeeds. Keep-the-last-list handles it.
* The revocation feed was effective within one 2-second tick in both directions (test: under 2.5 s).

### Routing, TCP and cost (Day 3)
* `proxy_pass http://$pool` with `$pool` = `beta`/`stable` selected the upstream blocks of those names.
* A `map` on `$cookie_lumina_plan` routes anyone who sets the cookie; `js_set $pool` on the verified session routed a forged beta token (other key), an expired one and a revoked one to stable.
* **The named location skips the routing** unless it uses `$pool` too: an order from a beta session reached stable through `@app` (`proxy_pass http://stable`).
* **Stream njs:** `s.on('upload')` received the greeting, `s.allow()` forwarded it (the intake answered `ACK 40`, the bytes read so far), `s.deny()` closed the connection with nothing sent to the intake (intake counter unchanged). The stream block needs its own `js_import`.
* **A silent TCP client** was still open after 10 s with the default `preread_timeout` (30 s); with `preread_timeout 5s` it was closed at 5.0 s and the intake was never contacted. Without njs, the plain proxy connected the silent client to the intake, which closed it after its own 2 s timeout.
* **A blocking script blocks its worker:** one 3-second CPU loop on a 2-worker edge didn't slow other requests (the free worker accepted new connections); two loops (one per worker) made every `/api/ping` take ~2.7 s.
* The throughput comparison (`return` vs `js_content` vs QuickJS, with `oha`) wasn't run while building: running the `oha` container was blocked in the authoring session. A candidate measurement for the recap.

### The lab
* The test's negatives each fail exactly one requirement: key written in the script (T1), no `try`/`catch` (T3), a `map` on the cookie payload for routing (T4), body filter without the header filter (T9: the JSON was incomplete, caught by parsing it), no `preread_timeout` (T10).

---

## BIG-IP Mapping (for the recap)
* iRule events → njs directives: `HTTP_REQUEST` → `js_content`/`js_set`, `HTTP_RESPONSE_DATA` → `js_body_filter`, `CLIENT_DATA` → `js_preread`.
* `table` → `js_shared_dict_zone`; `after -periodic` / iCall → `js_periodic`; `HTTP::sideband` → `ngx.fetch`; `CRYPTO::sign` → `crypto.createHmac`; `static::` → constants, NGINX variables, `process.env`.
* Both run on the data path's thread (TMM, worker): keep them short.

---

## Day 1

## Day 2

## Day 3

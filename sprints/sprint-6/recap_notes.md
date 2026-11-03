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
* **Q: why are some ES5 things missing?** They're sloppy-mode features; both engines run strict mode only (njs shell, both `-n njs` and `-n QuickJS`): an undeclared assignment `x = 1` is a `ReferenceError`, `010` is a `SyntaxError`, `with` is refused, `arguments.callee` throws. ES5 strict features (getters, `Object.keys`, `JSON`) work in both. Regex lookbehind works in both.
* **Running code from strings:** `eval` fails in both (`Not implemented` / `'eval' is not defined`). `new Function("return 1")` worked in the njs shell, but QuickJS has no `Function` global at all (`'Function' is not defined`).
* **Why the njs engine is shaped this way:** it was written for NGINX, around a cheap context per request whose memory is released with the request (hence a fresh context each time, and no long-lived garbage to collect). Language features were added as configuration scripting needed them. QuickJS was added as a second engine for full modern JavaScript, at the cost of reusing contexts (`js_context_reuse`).
* **Validating before going live:** `nginx -t` compiles the script, so syntax errors are caught before the reload, and a refused reload leaves the old script running. It doesn't catch run-time errors (the junk cookie → 500 passed `nginx -t`). BIG-IP also refuses an iRule with a syntax error when it's saved, but a saved iRule that's attached to a virtual server applies to new connections right away, with no separate test-then-apply step. Run-time Tcl errors abort the connection (a reset).
* **Q: can it all be in code, like an iRule?** Mostly not, by design: the config is the program and njs is a library it calls. iRule events fire by name and commands steer the traffic (`pool`, `HTTP::header insert`). In NGINX each hook is a directive, and choosing the upstream or adding a header to the proxied request always takes one (`proxy_pass http://$pool`, `proxy_set_header X-User $session_user`). The closest to an iRule is one `js_content` handler that decides and then hands off with `r.internalRedirect('@app')`. Proxying with `ngx.fetch` would really be all code, but it loses upstream balancing, keepalive, buffering, caching and retries. To keep the extra wiring safe, compute each decision once (one `js_set`) and use that variable in every proxying location. The upside: `grep js_` shows every place a script runs.
* **A `js_set` function that isn't exported passes `nginx -t`.** With `lang` missing from `export default`, the reload succeeded. Each request using `$client_lang` logged `js function "lumina.lang" not found` and still got 200. The variable was empty, and `add_header` with an empty value sends no header, so the only sign was in `error.log`.
* **Native vs script, my rule:** use native config when it covers the job (`map` for `$client_lang`: no script, can't throw) and code when it's required. My exception: when *all* the logic for a feature can live in code, keep it there, so I don't have to analyze, feature by feature, which parts belong in config. The trade-off: every decision in code is one more place a run-time error can turn into a 500 or an empty variable.
* **Logging bad input at scale: count everything, sample the details.** Verified in an isolated test: 1000 garbage cookies. A `js_shared_dict_zone ... type=number` counter with `incr('bad_cookie', 1, 0)` read exactly 1000 (all workers). The script set a `js_var $bad_session`, and a native `access_log ... if=$log_bad` with `split_clients $request_id` at 10% wrote 105 lines to a separate log. The script only flags and counts, and NGINX does the sampling and logging. Sampling alone can hide a slow, targeted probe; the counter can't. BIG-IP comparison: `rand()` sampling in an iRule and `HSL::send` for volume.
* **BIG-IP mapping:** njs context per request ≈ iRule variables scoped to the connection; QuickJS globals persisting per worker ≈ changing `static::` at run time, which only changes that TMM's copy.

### Day 1: Activity 3.4 (user's run)
* The first check showed no `X-Lang` and a count of 0: `lang` had been added to `nginx.conf` but not to `export default` in `lumina.js`. That gave the missing-export finding above.
* The `log_format` change (the activity's second half) was already in place on the rerun, so the count was **3**, not 2: the log line made `/edge/hello` call `lang()` too.
* **Guide fix:** the expected results after the first check are now a block (`X-Lang: fr`, `X-Lang: en`, `2`), with a line per result and a pointer to `./lab.sh logs` if `X-Lang` is missing.

### Day 1: Infographic
* `where-mistakes-show.svg` / `.png`: five Day 1 mistakes (syntax error, missing export, uncaught bad input, caught bad input, per-request data in a QuickJS global), each with what `nginx -t`, the client and `error.log` show, colored by where you first find out. Generated from a script, rendered like Sprint 5's (rsvg-convert in alpine:3.22, Lato from google/fonts, DejaVu Sans Mono, 1.5×).

### Day 1: Quiz
* **9/10.** The miss was a `js_set` question on what gets read when: the function runs only when something reads the variable, and once per request however many times it's used (questions "js_set Evaluation" / "Lazy js_set").
* Recap written: `day01_recap.md`.

## Day 2

## Day 3

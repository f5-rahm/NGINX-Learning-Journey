# Sprint 6 &bull; Day 1: How njs Runs
**Day:** 1 of 3  
**Estimated Time:** 65 Minutes (15 concepts, 5 setup, 35 activities, 10 quiz)  
**Theme:** On BIG-IP, custom logic is an iRule: TCL attached to events, compiled when it's loaded, with per-connection variables and `static::` globals. NGINX's equivalent is **njs**, a JavaScript engine built into NGINX. It isn't Node.js and it isn't a browser. It's a small engine that NGINX calls at chosen points in a request, with a deliberately short life. Today you learn where njs runs, how long its state lasts, and how much of JavaScript you actually get.

---

## 1. Concepts to Understand (15 Minutes)

### 1.1 What njs Is (and Isn't)
* **njs is a dynamic module.** `nginx:mainline` ships it (`ngx_http_js_module` for HTTP, `ngx_stream_js_module` for TCP/UDP), and `load_module` switches it on. Plus has the same module, with support.
* **It runs inside the worker**, on the worker's event loop, between NGINX's own steps. There is no separate script server, no network hop and no IPC. That makes it fast, and it means a slow script slows **everything** that worker is serving (Day 3).
* **Scripts are compiled when the configuration loads.** `nginx -t` compiles every imported script, so a syntax error fails the test and the reload, like a typo in `nginx.conf`. Editing a script does nothing until you reload.
* **It isn't Node.js.** There's no npm, no `require('express')`, no event loop of your own, and no file you can leave open between requests. The built-in modules are small: `crypto`, `fs`, `querystring`, `buffer`, `zlib`, `xml`, plus the `ngx` object for NGINX itself.

### 1.2 The Request Object and the Handlers
NGINX calls a script's function and passes it the request, `r`. What you can do depends on **where** in the configuration the function is hooked in:

| Directive | Called when | The function's job | iRule analog |
| :--- | :--- | :--- | :--- |
| `js_content` | The content phase, instead of `proxy_pass` or a file | Produce the response: `r.return(status, body)`, or hand the request on | `HTTP_REQUEST` + `HTTP::respond` |
| `js_set $var` | When `$var` is first **used** in that request | Return a string; NGINX caches it for the rest of the request | A `set` in `HTTP_REQUEST` used later |
| `js_header_filter` / `js_body_filter` | As the response passes through (Day 2) | Change headers or body | `HTTP_RESPONSE` / `HTTP_RESPONSE_DATA` |
| `js_periodic` | On a timer, with no request (Day 2) | Housekeeping | `after -periodic` |
| `js_preread` / `js_access` (stream) | When a TCP connection's first bytes arrive (Day 3) | Inspect, then allow or deny | `CLIENT_DATA` |

What a function reads from `r`:
* `r.method`, `r.uri`, `r.args` (the query, as an object), `r.remoteAddress`
* `r.headersIn['Name']` for request headers, `r.headersOut['Name']` for response headers
* `r.variables.name` for **any NGINX variable**: `r.variables.cookie_lumina_session` is NGINX parsing the cookie for you
* `r.requestText` for the request body (Day 2)

And `r.log()`, `r.warn()`, `r.error()` write to the error log, tagged with the request.

### 1.3 How Long State Lives: Two Engines
njs 1.0 ships **two JavaScript engines**, chosen with `js_engine` (in `http`, `server` or `location`):

| | `njs` (the default) | `qjs` (QuickJS) |
| :--- | :--- | :--- |
| Context per request | **A fresh one every request** (cloned from a prepared copy, so it's cheap) | **Reused**: kept in a pool and handed to the next request |
| A global `var` | Starts from its initial value every request | **Keeps its value** across requests on that worker |
| Language | ES5 plus a selection of later features | Close to the full modern standard |

* The README's line "VM-per-request" describes the default engine. With QuickJS, a global is shared by every request that gets that context, which is a cache you didn't ask for and a leak between users if you store anything per user in it.
* **Neither engine shares globals across workers.** Each worker has its own. State that must be the same for all requests and all workers belongs in a **shared dictionary** (Day 2), like a BIG-IP `table` rather than a `static::` variable.

### 1.4 The JavaScript You Get
Coming from little or no JavaScript, these are the parts you need this sprint:
* **Variables and functions:** `var x = 1;`, `function name(r) { ... }`. Strings join with `+`. `if`, `for`, `try { } catch (e) { }` look like C.
* **Objects and arrays:** `{ client: '10.0.0.1', user: null }` and `[1, 2, 3]`. `JSON.parse(text)` turns text into an object and **throws** on bad input; `JSON.stringify(obj)` turns an object into text.
* **Modules:** a script ends with `export default { hello, count };`, and `js_import lumina from lumina.js;` makes those functions available as `lumina.hello`.

Where the **default njs engine** differs from what JavaScript tutorials show:
* **Missing:** `class`, destructuring (`var [a, b] = ...`), spread (`...obj`), generators, `Map`/`Set`, and BigInt. They fail with `SyntaxError: ... not supported in this version` or `ReferenceError`.
* **Present:** arrow functions, template strings, `let`/`const`, `async`/`await`, Promises, `?.` and `??`, and `Buffer` (with `base64url`).
* **Different:** no `fetch()` (it's `ngx.fetch()`), no `require()` in QuickJS (use `import`), and `process.env` contains only the variables NGINX passes through with the `env` directive (Day 2).

The safe habit is to write plain, older-style JavaScript, which runs on both engines. The `njs` command-line shell, shipped in the image, tells you in a second whether something parses.

### 1.5 When the Script Fails
* **A syntax error** is caught by `nginx -t`: the reload is refused and the running configuration carries on.
* **An exception at run time** (calling a method on `undefined`, `JSON.parse` on garbage) ends that request with **`500`**, and the error log gets `js exception: TypeError: ...`. Nothing else is affected.
* **The input is the attacker's.** Cookies, headers, arguments and bodies can hold anything. Every parse of client input belongs in `try`/`catch`, with a safe default.

### 1.6 BIG-IP Lens

| Need | BIG-IP iRules | NGINX njs |
| :--- | :--- | :--- |
| Where the logic attaches | Events: `HTTP_REQUEST`, `HTTP_RESPONSE`, `CLIENT_DATA` | Directives: `js_content`, `js_set`, filters, `js_preread` |
| Language | TCL, compiled when the iRule is saved | JavaScript, compiled when the configuration loads |
| Per-request state | Local variables | Local variables, and globals in the default engine |
| Device-wide state | `table` (shared by all TMMs) | `js_shared_dict_zone` (shared by all workers) |
| Read-only config values | `static::` set in `RULE_INIT` | Constants in the script, NGINX variables, `process.env` |
| Errors | TCL error: connection reset, logged in `/var/log/ltm` | `js exception`: `500` for that request, logged in the error log |
| Test before deploying | Syntax check on save | `nginx -t`, and the `njs` shell |

---

## 2. Lab Setup (5 Minutes)

Sprint 6 runs in containers like Sprints 4 and 5: the Lumina **edge** (`nginx:mainline` with njs) and the Lumina **application** behind it in two pools, **stable** and **beta**. This week you talk to the edge directly from the host: there's no client container, because nothing today depends on the client's address.

```bash
cd /srv/nginx-journey/sprints/sprint-6/lab
cp day1_nginx.conf nginx.conf           # the edge on 8096 with two njs functions
cp day1_lumina.js lumina.js             # the script it imports
./lab.sh up                             # network, origin, edge, then the ready check
source helpers.sh                       # r, rh, token, link, tel, decode, ...: in every new terminal
```
The first `up` creates a random signing key in `lab/secrets/lumina.key` (owner-only, not in git) and gives it to the edge as the `LUMINA_KEY` environment variable. The ready check ends with `Sprint 6 lab ready: edge :8096 -> s6-origin (stable :8016, beta :8026)`.

| Address / port | Service |
| :--- | :--- |
| 8081–8095 | Earlier sprints (reserved) |
| **:8096** (container `s6-edge`, 10.56.0.10) | **Sprint 6 lab: the Lumina edge**, HTTP |
| :8097 | The edge's telemetry port, TCP (Day 3) |
| 127.0.0.1:8016 (container `s6-origin`, 10.56.0.20) | **The application**: stable pool :8016, beta pool :8026, telemetry intake :8036 |

| Command | What it does |
| :--- | :--- |
| `r PATH [curl options]` | One request to the edge: `<- 200`, then the body |
| `rh PATH [curl options]` | The same, with the response headers |
| `token SUB [--plan P] [--ttl S] [--key K]` | A Lumina session token signed with the lab key (`--key` signs with another one) |
| `decode TOKEN` | A token's header and payload, unchecked |
| `elog [N]` | The last N lines of the edge's error log |
| `./lab.sh reload` | `nginx -t`, reload, wait a second |
| `./lab.sh njs [-n QuickJS] -c 'code'` | The njs shell, with either engine |

The application answers any path with JSON: which **pool** answered, the URI, and the `X-User` header it received. Each activity edits `nginx.conf` or `lumina.js` in `lab/`; after each edit, run `./lab.sh reload`.

---

## 3. Hands-on Guided Discovery Activities (35 Minutes)

### Activity 3.1: First Contact (4 min)
```bash
r /edge/hello
r /api/ping
```
`/edge/hello` is answered by the script (`Hello from njs 1.0.1: GET /edge/hello from 10.56.0.1`) and never reaches the application; `/api/ping` is proxied as usual. Open `lumina.js` and find `hello`: it sets a header in `r.headersOut` and answers with `r.return()`.

Change `'Hello from '` to `'Hi from '` in `lumina.js` and save. Then:
```bash
r /edge/hello
./lab.sh reload
r /edge/hello
```
The first answer still says "Hello": the script was compiled when the configuration loaded, and the edit means nothing until the reload.

Now break it on purpose. In `count`, change `calls++;` to `calls++ +;`:
```bash
./lab.sh reload
r /edge/count
```
<details>
<summary>What happened?</summary>

`nginx -t` fails with `[emerg] SyntaxError: Unexpected token ";" at /lab/lumina.js:15`, so the reload never happens, and `/edge/count` keeps working with the last good script. A script is part of the configuration: the same test protects both.
</details>

Put `calls++;` back and reload.

### Activity 3.2: How Long Does a Global Live? (7 min)
`count` adds one to a global variable, `calls`, and reports it with the worker's number:
```bash
for i in 1 2 3 4; do r /edge/count; done
```
Every answer says `calls=1`. Now give that one location the other engine. In `location = /edge/count`, above `js_content`:
```nginx
js_engine qjs;
```
```bash
./lab.sh reload
for i in 1 2 3 4; do r /edge/count; done
(for i in $(seq 8); do curl -s localhost:8096/edge/count & done; wait) | sort
```
<details>
<summary>What do the numbers say?</summary>

* **Default engine: `calls=1` every time.** Each request gets a fresh copy of the script's context, so the global starts at 0 again.
* **QuickJS: the count grows**, and separately per worker: `calls=1 worker=1`, then `calls=2 worker=0`, `calls=3 worker=0`, and the eight at once carry on from there on worker 0. The context is reused from request to request, so the global survives. Each worker has its own.

So a global is neither per-request (with QuickJS) nor shared (across workers). Never keep per-user data in one, and don't count on one for shared state: that's what Day 2's shared dictionary is for.
</details>

Leave `js_engine qjs;` there; it only affects `/edge/count`.

### Activity 3.3: What JavaScript Is This? (5 min)
The image includes the `njs` shell. Try a few lines a JavaScript tutorial would use, first with the default engine, then with QuickJS:
```bash
./lab.sh njs -q -c 'class Session {}'
./lab.sh njs -q -c 'var [a, b] = [1, 2]'
./lab.sh njs -q -c 'var m = new Map()'
./lab.sh njs -q -n QuickJS -c 'class Session {}; var [a, b] = [1, 2]; var m = new Map(); console.log("fine")'
./lab.sh njs -q -c 'console.log(["ok", [1, 2].map(x => x * 2), `t=${1 + 1}`, null ?? "default"].join(" "))'
```
<details>
<summary>What did you learn?</summary>

* The default engine rejects `class` (`Token "class" not supported in this version`), destructuring and `Map` (`"Map" is not defined`). QuickJS accepts all three.
* Arrow functions, template strings and `??` work in both: `ok 2,4 t=2 default`.

Write for the default engine (plain functions, `var`, objects and arrays) and the script runs on either. When an example from the web fails, the shell tells you which line, before `nginx -t` does.
</details>

### Activity 3.4: A Variable Computed by a Script (8 min)
Give the application the client's preferred language. Add a function to `lumina.js`, above the `export` line, and add `lang` to the export list (`export default { hello, count, lang };`):
```js
// js_set $client_lang: the first language the client asks for, or "en"
function lang(r) {
    ngx.log(ngx.WARN, 'lang() called for ' + r.uri);
    var header = r.headersIn['Accept-Language'] || '';
    var first = header.split(',')[0].trim().toLowerCase().slice(0, 2);
    return /^[a-z]{2}$/.test(first) ? first : 'en';
}
```
In `nginx.conf`, at `http` level under `js_import`:
```nginx
js_set $client_lang lumina.lang;
```
and in `location /api/`, under `proxy_pass` (a response header, so you can see it):
```nginx
add_header X-Lang $client_lang;
```
```bash
./lab.sh reload
rh /api/ping -H 'Accept-Language: fr-CA,fr;q=0.9,en;q=0.5' | grep -i x-lang
rh /api/ping | grep -i x-lang
r /edge/hello > /dev/null
grep -c 'lang() called' logs/error.log
```
You should see three results, one per check:
```
X-Lang: fr
X-Lang: en
2
```
* The French request gets `fr`, and the request with no `Accept-Language` gets the default `en`.
* `lang()` logged **2** calls for 3 requests: `/edge/hello` never used `$client_lang`, so the function never ran for it.
* No `X-Lang` at all? Check `./lab.sh logs` for an error.

Now use the variable twice in one request. Add `lang=$client_lang` to the end of the `log_format edge` line, so it reads `'$remote_addr "$request" $status rt=$request_time lang=$client_lang'`:
```bash
./lab.sh reload
rh /api/ping -H 'Accept-Language: de' | grep -i x-lang
r /edge/hello > /dev/null
tail -2 logs/access.log
grep 'lang() called' logs/error.log | tail -2
```
<details>
<summary>How many times did lang() run?</summary>

**Once per request.** `/api/ping` uses `$client_lang` twice (the header and the log line), but the function ran once and NGINX reused the value. `/edge/hello` now runs it too, because the log line asks for it. A `js_set` variable costs nothing until something reads it, then costs one call per request.

The same result needs no script at all:
```nginx
map $http_accept_language $client_lang_map {
    ~^(?<l>[a-z]{2})  $l;
    default           en;
}
```
`map` is native, can't throw, and is the better tool here (it differs only on capital letters, which the regex could also match with `~*`). Keep njs for what `map` can't do, like checking a signature (Day 2).
</details>

### Activity 3.5: Reading the Request and a Session (7 min)
Lumina's sessions are a cookie, `lumina_session`, holding a token: three base64url parts separated by dots (a header, the claims, a signature).
```bash
T=$(token alice --plan beta)
echo "$T"
decode "$T"
```
Add a function that shows what the edge can read, and one that decodes the session. Above the `export` line:
```js
// The session cookie's claims, decoded (not verified!)
function claims(r) {
    var token = r.variables.cookie_lumina_session;
    if (!token) {
        return null;
    }
    var payload = token.split('.')[1];
    return JSON.parse(Buffer.from(payload, 'base64url').toString());
}

// GET /edge/info: what the edge knows about this request
function info(r) {
    r.headersOut['Content-Type'] = 'application/json';
    r.return(200, JSON.stringify({
        client: r.remoteAddress,
        method: r.method,
        args: r.args,
        cookie_header: r.headersIn.Cookie || null,
        session: claims(r)
    }) + '\n');
}
```
Add `info` to the export list (`claims` is a helper that nginx.conf doesn't call, so it stays out). In `nginx.conf`, above `location /api/`:
```nginx
location = /edge/info {
    js_content lumina.info;
}
```
```bash
./lab.sh reload
r '/edge/info?page=2&sort=new'
r /edge/info -b "lumina_session=$T; theme=dark"
r /edge/info -b "lumina_session=$(token mallory --plan beta --key guess)"
```
<details>
<summary>What's wrong with the last answer?</summary>

* The first two show what the edge reads: `args` as an object (`{"page":"2","sort":"new"}`), the raw `Cookie` header, and the session's claims (`{"sub":"alice","plan":"beta",...}`), picked out of the cookie by NGINX's own `$cookie_lumina_session`.
* The last token was signed with a key Mallory **guessed**, and the edge shows `"sub":"mallory","plan":"beta"` just the same. **Decoding isn't verifying.** Anyone can write a token with any claims; only the signature proves Lumina issued it. Routing or identity based on this function would hand the beta pool, or anyone's identity, to whoever asks. Day 2 checks the signature.
</details>

### Activity 3.6: When the Script Throws (4 min)
```bash
r /edge/info -b 'lumina_session=garbage'
grep 'js exception' logs/error.log | tail -1
```
A `500`, and `js exception: TypeError: first argument undefined is not a string or Buffer-like object`: `garbage` has no second part, so `Buffer.from(undefined)` threw, and the request died with it. A client chose to make your edge return a `500`.

Wrap the parsing in `claims` so a bad cookie is just "no session":
```js
    try {
        var payload = token.split('.')[1];
        return JSON.parse(Buffer.from(payload, 'base64url').toString());
    } catch (e) {
        r.warn('unreadable session cookie: ' + e.message);
        return null;
    }
```
```bash
./lab.sh reload
r /edge/info -b 'lumina_session=garbage'
r /edge/info -b 'lumina_session=a.bm90IGpzb24.c'
elog 2
```
Both are `200` with `"session":null`, and the error log has a warning instead of an exception (the second one decodes to `not json`: `Unexpected token at position 0`).

<details>
<summary>Why warn and not ignore silently?</summary>

A steady stream of unreadable cookies is a signal: a broken client release, or someone probing. A warning tagged with the request keeps that visible without failing the request. At high volume, log it at a lower level or count it instead.
</details>

---

## 4. Day 1 Concept Examination (10-Question Randomized Quiz)

```bash
cd /srv/nginx-journey && python3 -m http.server 8090
```
👉 **http://&lt;lab-host&gt;:8090/quiz.html?sprint=6&day=1**

When you're done for the day: `./lab.sh down`.

---

## 5. Key Takeaways for Day 1
* **njs runs inside the worker, compiled at configuration load.** `nginx -t` checks scripts; edits need a reload.
* **The directive decides the job:** `js_content` answers, `js_set` computes a variable (once per request, only when used), filters change responses, `js_preread` inspects connections.
* **The default engine gives every request a fresh context; QuickJS reuses them.** Globals are never shared across workers. Shared state goes in a shared dictionary.
* **The default engine is ES5 and then some.** No `class`, destructuring, `Map`. Write plain JavaScript and check it in the `njs` shell.
* **Decoding a token isn't verifying it.** Claims are only as trustworthy as the signature check.
* **A run-time exception is a `500`.** Treat every byte of client input as hostile: parse in `try`/`catch`, fall back to a safe default.
* **Prefer native directives when they can do the job.** `map` beat `js_set` for the language header.

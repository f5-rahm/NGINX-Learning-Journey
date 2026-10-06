# NGINX Learning Journey, Sprint 2 Day 1: Reverse proxy fundamentals

Sprint 2 starts the reverse proxy work. Day 1 covered how `proxy_pass` builds the request to the backend, and which headers have to be set so the backend knows who the client really is. Most of my questions were about mapping NGINX to iRules, so that's where the notes start.

## `proxy_pass` and `upstream`

The question that matters is whether `proxy_pass` has anything after `host:port`, even one `/`. With no URI, the request goes through unchanged. With a URI, the matched location prefix is cut and replaced by that URI. "Stripping" a prefix is the same rule, just replacing it with `/`.

The `b` in the doc's `proxy_pass http://b;` examples is only a placeholder name. In a real config it's either an `upstream` block name, which NGINX checks first, or a hostname that gets resolved once when the config loads. A failed lookup fails `nginx -t`.

I briefly had it backwards that `upstream` is what makes something a proxy. It's `proxy_pass` that makes a location proxy. `upstream` is optional, and an unreferenced one does nothing. It's the pool, and `server` lines inside it are the pool members. Still the better names, still saying it.

## BIG-IP to NGINX, as far as I got today

| BIG-IP | NGINX | Catch |
| :--- | :--- | :--- |
| `HTTP::uri` | `$request_uri` | Raw, as sent. Rewrites don't change it. |
| `HTTP::path` | `$uri` | `$uri` is decoded and normalized, and changes after a `rewrite`. `HTTP::path` is raw. |
| `HTTP::query` | `$args` | No `?`. `$is_args` is `?` only when there's a query, so `$is_args$args` rebuilds it safely. |
| `regexp` / `string range` on `HTTP::path` | `$1` | A regex capture, usually only part of the path. Not the path itself. |
| `HTTP::host` | `$http_host` | Raw header, port and case included, empty if absent. |
| *(roughly `string tolower` + `getfield`)* | `$host` | Normalized. See below. |
| `IP::client_addr` / `IP::remote_addr` | `$remote_addr` | The TCP peer. BIG-IP may add a `%N` route domain suffix. |
| `HTTP::header` logic in `HTTP_REQUEST` | `$proxy_add_x_forwarded_for` | Appends the client IP to whatever XFF came in. The HTTP profile's Insert XFF adds a separate header instead. |
| Flag set in `CLIENTSSL_HANDSHAKE` | `$scheme`, `$https` | NGINX knows from the listener, so no event is needed. |

On `X-Forwarded-Proto`, my first thought was to work out https from a TLS event. That's right, but the event is `CLIENTSSL_HANDSHAKE`, not a "hello", and you need a default of `http` set in `CLIENT_ACCEPTED`. `PROFILE::exists clientssl` looked like a shortcut, but it gives false positives. A virtual can have the profile attached and still call `SSL::disable` for some connections, such as port 80 on a multi-port virtual. Tracking the real handshake avoids that. NGINX doesn't have this problem, because `$scheme` and `$https` come from the connection itself.

Another default difference: BIG-IP forwards the client's `Host` unchanged. NGINX replaces it with `$proxy_host` (the upstream name) unless you set `proxy_set_header Host $host;`.

## `$host` vs `$http_host`

`$http_host` is the raw `Host` header. `$host` takes the first one of these that exists, then lowercases it and removes the port:

1. The hostname in an absolute request line (`GET http://abs.example/...`)
2. The `Host` header
3. The `server_name` of the server block that handled the request

From the lab:

| Client sends | `$http_host` | `$host` |
| :--- | :--- | :--- |
| `Host: Lumina.LOCAL:8082` | `Lumina.LOCAL:8082` | `lumina.local` |
| no `Host` (HTTP/1.0) | empty | `lumina.local`, from `server_name` |
| `GET http://Abs.Example/...` + `Host: lumina.local` | `lumina.local` | `abs.example` |

The "Try it" step in 3.3 had a good surprise. With `Host $http_host` and no client `Host`, the backend got `lumina_api_nodes`. An empty `proxy_set_header` value drops the header, and NGINX falls back to `$proxy_host` because it always has to send a `Host`.

## The URI mapping drill (Activity 3.1)

I got a and b right and the rest wrong. The idea that finally clicked: **NGINX does text cut-and-paste, not path handling.** It cuts exactly the characters of the location string and pastes exactly the characters after the host. Nothing more.

| Row | Location → `proxy_pass` | Request | Backend gets | Why |
| :--- | :--- | :--- | :--- | :--- |
| a | `/a/` → `:8001` | `/a/v1/stats?page=2` | `/a/v1/stats?page=2` | No URI: passed through |
| b | `/b/` → `:8001/` | `/b/v1/stats` | `/v1/stats` | Clean strip |
| c | `/c` → `:8001/` | `/c/v1/stats` | `//v1/stats` | Remainder keeps its slash, and `/` adds another |
| c2 | `/c` → `:8001/` | `/catalog` | `/atalog` | Prefixes match characters, not segments |
| d | `/d/` → `:8001/v2` | `/d/users` | `/v2users` | Slash was cut and not put back |
| e | `/e/` → `:8001/v2/` | `/e/users` | `/v2/users` | Symmetric slashes |
| f | `~ ^/f/(.*)$` → `:8001/$1` | `/f/v1/items?page=2` | `/v1/items` | Regex sees only the path, so the query is lost without `$is_args$args` |
| g | `/g/` → `http://$be/` | `/g/v1/stats` | `/` | A variable turns prefix replacement off, and the URI replaces everything |
| h | `/h/` → `rewrite` + `http://$be` | `/h/v1/items?page=2` | `/v1/items?page=2` | `rewrite` does the cut, and no URI means it's passed as-is |

Rule of thumb: if the location ends in `/`, the `proxy_pass` URI should too. The order of questions to ask: is it a regex location? Does `proxy_pass` have a variable? Is there a URI after the host? The visual walkthrough is in [`day_01_uri_surgery.html`](day_01_uri_surgery.html).

## Forwarding headers and includes

- A naive rate limiter keys on the **leftmost** `X-Forwarded-For` entry. That's text the client sent (`6.6.6.6` in the lab), so an attacker can change it on every request. Key on `$remote_addr`, or use the realip module behind trusted proxies.
- `include` snippets for the proxy headers cut a lot of repetition, but `include` is plain text substitution, not a scoped macro. Include the snippet at the server level and add one `proxy_set_header` in a location, and the inheritance trap is back. Debian and Ubuntu ship `/etc/nginx/proxy_params` for the same reason.

## Lab notes

- `peek` is a helper you paste into the terminal, not something for `~/.bashrc`.
- Quote URLs with `?` in bash (`peek '/a/v1/stats?page=2'`). `?` is a glob character.
- The Python mocks listen on loopback by default. I added `MOCK_BIND` to `mocks.sh` so I can reach them from off the box: `export MOCK_BIND=0.0.0.0` before `./mocks.sh start`.
- Fixed a few lab guide gaps on the way: the `peek` setup wording, the full `set`/`rewrite` lines for drill rows g and h, and what "apply the rules" meant in 3.1. The guide could still say more plainly that you predict the result and don't edit the config.

I scored 7 out of 10 on the quiz the first time and 9 out of 10 on the retake. The URI mapping rules took the most work today, and Tomorrow (Day 2) moves to the `upstream` side: pools, balancing, and connection reuse.

#NGINX #F5 #LearningInPublic #DevOps

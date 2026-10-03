# Sprint 1 &bull; Day 2: Web Server Construction, Location Precedence & Hardening
**Estimated Time:** 60–75 Minutes of Guided Hands-on Discovery  
**Theme:** Build a production static web server, master location matching mechanics, and harden the edge.

---

## 1. Concepts to Understand (15 Minutes)

### 1.1 The 5-Step Location Matching Algorithm
NGINX does **not** evaluate location blocks purely top-to-bottom. It follows a deterministic 5-step hierarchy:
1. **Exact Match (`=`):** Highest priority. If URI exactly matches (`location = /healthz`), evaluation stops immediately.
2. **Preferential Prefix (`^~`):** NGINX searches all prefix locations. If the **longest** matching prefix has `^~` (`location ^~ /images/`), NGINX selects it and **deliberately skips all regular expressions**. A `^~` on a shorter prefix has no effect when a longer standard prefix also matches.
3. **Standard Prefix Candidate:** NGINX records the longest matching standard prefix (`location /app/`). File order does not matter for prefixes.
4. **Regular Expressions (`~` case-sensitive, `~*` case-insensitive):** Evaluated in **strictly top-to-bottom file order**. The **first** matching regex wins.
5. **Fallback:** If no regex matches, the longest standard prefix recorded in Step 3 is used.

*Prefix gotcha:* Prefixes match characters, not path segments. `location /test` (no trailing slash) also matches `/testing` and `/test123`.

### 1.2 Path Resolution: `root` vs. `alias`
* **`root`:** Appends the entire client request URI to the root directory path:
  ```nginx
  location /static/ {
      root /var/www;
  }
  # GET /static/css/main.css -> /var/www/static/css/main.css
  ```
* **`alias`:** Strips the matched location prefix and replaces it with the alias path:
  ```nginx
  location /assets/ {
      alias /var/www/shared/;
  }
  # GET /assets/css/main.css -> /var/www/shared/css/main.css
  # (/assets/ is stripped!)
  ```
  *Critical Gotcha:* If `location` ends with a trailing slash (`/assets/`), `alias` **must** also end with a trailing slash (`alias /var/www/shared/;`). Otherwise the remaining path is glued straight onto the alias: `/var/www/sharedcss/main.css`.
* *Rule of thumb:* Use `alias` only when the URI prefix and the directory name differ. When the location matches the last part of the path (`location /app/` serving `www/app/`), use `root www;` instead. It is simpler and avoids `alias` quirks with `try_files`.
* *Relative paths:* In the lab, `root www;` and `alias www/media/;` resolve against the `-p` prefix, so error logs show the full path (`/srv/nginx-journey/sprints/sprint-1/lab/www/...`).

### 1.3 Single Page Application (SPA) Routing & `try_files`
Client-side frameworks (React, Vue, Angular) simulate navigation in the browser without real server directories. If a user reloads on `/app/orders/123`, the server returns 404 unless configured with `try_files`:
```nginx
location /app/ {
    root www;                               # www/app/... ; root, not alias
    try_files $uri $uri/ /app/index.html;
}
```
*Mechanics:* NGINX checks if `$uri` exists as a file. If not, it checks `$uri/` as a directory. If both fail, it performs an **internal redirect** to the last argument, `/app/index.html`, which runs through location matching again (and lands back in `/app/`).

### 1.4 Context Inheritance & The `add_header` Trap
In NGINX, array directives like `add_header`, `proxy_set_header`, and `access_log` do **not** merge across nested blocks. They are inherited from the parent level **only if the current level defines none of its own**. If a child `location` defines even a single `add_header`, **all parent headers from `server` and `http` are completely discarded** for that location unless re-declared!
* **Fix (NGINX 1.29.3+ mainline):** `add_header_inherit merge;` in the child keeps the parent's headers and adds its own. On older versions, repeat the parent's headers in every block that adds any.
* **Status codes:** Without the `always` parameter, `add_header` only applies to 2xx and 3xx responses. Security headers you need on 403s and 404s require `always`.
* **In this lab:** The server sets `add_header X-Worker-PID $pid always;`. Watch it disappear in Activity 2.3.

---

## 2. Lab Setup (5 Minutes)

Run from `/srv/nginx-journey/sprints/sprint-1/lab`. This assumes the Day 1 setup and the `ngx` helper.

1. Stop the Day 1 instance and swap in the Day 2 starter config (keep Day 1's for reference):
   ```bash
   ngx -s quit
   mv nginx.conf day1_nginx.conf
   cp starter_nginx.conf nginx.conf
   ```
2. Create the Northwind content, including decoy secrets the dotfile rule must hide:
   ```bash
   mkdir -p www/media www/app www/.git
   echo '<h1>Northwind Storefront</h1>' > www/index.html
   echo '<h1>Northwind App Shell</h1><div id="root"></div>' > www/app/index.html
   echo 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=' \
     | base64 -d > www/media/logo.png
   echo 'DB_PASSWORD=do-not-serve-me' > www/.env
   printf '[core]\n\trepositoryformatversion = 0\n' > www/.git/config
   echo 'hidden asset' > www/media/.secret
   ```
3. Start and confirm:
   ```bash
   ngx -t && ngx
   curl -s localhost:8081/healthz
   ```

After every config change in the activities below: `ngx -t && ngx -s reload`.

---

## 3. Hands-on Guided Discovery Activities (45 Minutes)

### Activity 3.1: The Location Precedence Showdown (10 min)
The starter config already contains these competing locations:
```nginx
location = /test        { return 200 "Exact match wins\n"; }
location ^~ /test/      { return 200 "Preferential prefix ^~ wins\n"; }
location ~* \.png$      { return 200 "Regex wins\n"; }
location /test/images/  { return 200 "Longest standard prefix wins\n"; }
```
Predict each answer before you run it:
1. `curl localhost:8081/test` $\to$ `Exact match wins` (Step 1).
2. `curl localhost:8081/test/logo.png` $\to$ `Preferential prefix ^~ wins` (Step 2 overrides the Step 4 regex).
3. `curl localhost:8081/other/logo.png` $\to$ `Regex wins` (Step 4).
4. `curl localhost:8081/test/images/logo.png` $\to$ `Regex wins`. **Surprise:** the longest prefix is now the standard `/test/images/`, not `^~ /test/`, so the regex check still runs and `\.png$` wins.
5. `curl localhost:8081/test/images/logo.txt` $\to$ `Longest standard prefix wins` (no regex matches, so Step 5 falls back to it).

*Insight:* As written, the fourth location can never win for a `.png`. `^~` only shields the requests whose longest prefix carries it.

**Optional: watch NGINX decide.** Run the debug binary with debug logging for your own client only:
```bash
ngx -s quit
sed -i 's/events { worker_connections 1024; }/events { worker_connections 1024; debug_connection 127.0.0.1; }/' nginx.conf
/usr/sbin/nginx-debug -p $PWD -c $PWD/nginx.conf -e logs/error.log
curl -s localhost:8081/test/images/logo.png >/dev/null
grep -E 'test location|using configuration' logs/error.log | tail -8
```
You will see NGINX walk the prefix tree (`"/"`, `"test"`, `"test/"`, `"images/"`), then test the regex (`~ "\.png$"`), then report `using configuration "\.png$"`. When done: `kill -QUIT $(cat logs/nginx.pid)`, remove `debug_connection` from `nginx.conf`, and restart with `ngx`.

---

### Activity 3.2: The `root` vs `alias` Laboratory (10 min)
1. In `nginx.conf`, add the shared media alias inside the `server` block:
   ```nginx
   location /assets/media/ {
       alias www/media/;
       autoindex off;
   }
   ```
2. Reload and fetch the logo:
   ```bash
   curl -s localhost:8081/assets/media/logo.png
   ```
   **Surprise:** it prints `Regex wins`, not image bytes. The showdown regex `~* \.png$` beats the standard prefix (Step 4 over Step 5). Even `curl -I` shows `200` and `Content-Type: image/png`, because NGINX sets the type from the extension. A status code alone can lie.
3. Shield the asset folder from regex evaluation with `^~`:
   ```nginx
   location ^~ /assets/media/ {
   ```
   Reload and confirm the real file: `curl -s localhost:8081/assets/media/logo.png | head -c 4 | od -c` shows `211 P N G`.
4. Break it on purpose: remove the trailing slash, `alias www/media;`, and reload.
5. `curl -I localhost:8081/assets/media/logo.png` returns `404`.
6. Check `tail -n 3 logs/error.log` for the path-munging error: `open() "/srv/nginx-journey/sprints/sprint-1/lab/www/medialogo.png" failed`.
7. Re-add the trailing slash and verify the PNG again.

---

### Activity 3.3: SPA Routing & Edge Hardening (15 min)
1. Implement the SPA fallback (with `root`, since `/app/` matches the directory name):
   ```nginx
   location /app/ {
       index index.html;
       try_files $uri $uri/ /app/index.html;
   }
   ```
   `curl localhost:8081/app/orders/history` returns the app shell.
2. Strip NGINX version leakage in HTTP headers and error pages. Place it in the `http` block (it also works in `server` or `location`):
   ```nginx
   server_tokens off;
   ```
3. Deny access to hidden dotfiles (like `.git` and `.env`), but keep `/.well-known/` reachable for ACME certificate validation in Sprint 3:
   ```nginx
   location ~ /\.(?!well-known) {
       deny all;
       access_log off;
       log_not_found off;
   }
   ```
   `curl -I localhost:8081/.env` returns `403`.
4. **The `^~` security trap:** `curl -s localhost:8081/assets/media/.secret` still returns `hidden asset`. The `^~` from Activity 3.2 skips **every** regex, including your deny rule. Nest the deny inside the shielded location:
   ```nginx
   location ^~ /assets/media/ {
       alias www/media/;
       autoindex off;
       location ~ /\. { deny all; }
   }
   ```
   Reload: `/assets/media/.secret` now returns `403`.
5. Add a permanent 301 redirect for the legacy route:
   ```nginx
   location = /legacy {
       return 301 /app/;
   }
   ```
   `curl -I localhost:8081/legacy` shows `Location: http://localhost:8081/app/`. NGINX builds an absolute URL from the host and port, which matters behind proxies (`absolute_redirect`, Sprint 2).
6. **The `add_header` trap:** add one header to the SPA location and reload:
   ```nginx
   location /app/ {
       index index.html;
       try_files $uri $uri/ /app/index.html;
       add_header Cache-Control "no-cache";
   }
   ```
   `curl -sI localhost:8081/app/x | grep -iE 'x-worker|cache-control'` shows only `Cache-Control`. The server-level `X-Worker-PID` is gone. Fix it with `add_header_inherit merge;` in the location (NGINX 1.29.3+), confirm both headers return, then remove the experiment.

---

### Activity 3.4: Automated Lab Verification (10 min)
Run the automated test runner to verify that all 12 acceptance criteria pass:
```bash
cd /srv/nginx-journey/sprints/sprint-1
./test_sprint01.sh
```
* The suite targets `http://127.0.0.1:8081` with `Host: shop.northwind.local`. Override with `NGINX_TARGET=http://127.0.0.1:<port> ./test_sprint01.sh`.
* Test 5 checks the PNG file signature, not just the status, so the regex hijack from Activity 3.2 fails it.
* Three **stretch** assertions report separately and do not affect the gate: dotfiles inside the `^~` media location, `/.well-known/` left reachable, and `X-Worker-PID` surviving on SPA responses.
* Stuck? `lab/solution_nginx.conf` is a reference configuration that passes 12/12 core and 3/3 stretch.

---

## 4. Day 2 Concept Examination (10-Question Randomized Quiz)

To verify today's learning, launch the **Day 2 Concept Quiz**:
* Samples **10 random questions** from our 20-question Day 2 pool.
* Passing score: **80% (8 of 10)**.

👉 **[Launch Day 2 Concept Examination (`day02_quiz.html`)](day02_quiz.html)**

---

## 5. Key Takeaways for Day 2
* **`^~` is your regex shield, and it cuts both ways:** Use `^~` on static asset folders (like `/static/` or `/assets/`) to skip regex evaluation, but remember it also skips regex-based security rules. Nest those rules inside the `^~` location.
* **`^~` only works on the longest matching prefix:** A longer standard prefix underneath it re-enables regex evaluation.
* **Always match trailing slashes on `alias`:** `location /dir/` requires `alias /path/dir/;`. Prefer `root` when the location matches the directory name.
* **Mind `add_header` inheritance:** Defining `add_header` inside a `location` clears all outer headers. Use `add_header_inherit merge;` on 1.29.3+, and `always` for headers that must appear on errors.
* **Don't trust a status code alone:** A regex location can answer 200 with the right `Content-Type` and still not serve your file. Verify content.

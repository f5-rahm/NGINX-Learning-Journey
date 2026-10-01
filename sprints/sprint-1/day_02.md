# Sprint 1 &bull; Day 2: Web Server Construction, Location Precedence & Hardening
**Estimated Time:** 45–60 Minutes of Guided Hands-on Discovery  
**Theme:** Build a production static web server, master location matching mechanics, and harden the edge.

---

## 1. Concepts to Understand (15 Minutes)

### 1.1 The 5-Step Location Matching Algorithm
NGINX does **not** evaluate location blocks purely top-to-bottom. It follows a deterministic 5-step hierarchy:
1. **Exact Match (`=`):** Highest priority. If URI exactly matches (`location = /healthz`), evaluation stops immediately.
2. **Preferential Prefix (`^~`):** NGINX searches all prefix locations. If the longest matching prefix has `^~` (`location ^~ /images/`), NGINX selects it and **deliberately skips all regular expressions**.
3. **Standard Prefix Candidate:** NGINX records the longest matching standard prefix (`location /app/`).
4. **Regular Expressions (`~` case-sensitive, `~*` case-insensitive):** Evaluated in **strictly top-to-bottom file order**. The **first** matching regex wins.
5. **Fallback:** If no regex matches, the longest standard prefix recorded in Step 3 is used.

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
  *Critical Gotcha:* If `location` ends with a trailing slash (`/assets/`), `alias` **must** also end with a trailing slash (`alias /var/www/shared/;`).

### 1.3 Single Page Application (SPA) Routing & `try_files`
Client-side frameworks (React, Vue, Angular) simulate navigation in the browser without real server directories. If a user reloads on `/app/orders/123`, the server returns 404 unless configured with `try_files`:
```nginx
location /app/ {
    alias /var/www/app/;
    try_files $uri $uri/ /app/index.html;
}
```
*Mechanics:* NGINX checks if `$uri` exists as a file. If not, it checks `$uri/` as a directory. If both fail, it performs an internal rewrite to `/app/index.html`.

### 1.4 Context Inheritance & The `add_header` Trap
In NGINX, array directives like `add_header`, `proxy_set_header`, and `access_log` do **not** merge across nested blocks. If a child `location` defines even a single `add_header`, **all parent headers from `server` and `http` are completely discarded** for that location unless re-declared!

---

## 2. Hands-on Guided Discovery Activities (30 Minutes)

### Activity 2.1: The Location Precedence Showdown (8 min)
Review how NGINX resolves competing location blocks:
```nginx
location = /test { return 200 "Exact match wins\n"; }
location ^~ /test/ { return 200 "Preferential prefix ^~ wins\n"; }
location ~* \.png$ { return 200 "Regex wins\n"; }
location /test/images/ { return 200 "Longest standard prefix wins\n"; }
```
Test with curl against your server:
1. `curl http://localhost:8080/test` $\to$ Returns: `"Exact match wins"` (Step 1).
2. `curl http://localhost:8080/test/logo.png` $\to$ Returns: `"Preferential prefix ^~ wins"` (Step 2 overrides Step 4 regex!).
3. `curl http://localhost:8080/other/logo.png` $\to$ Returns: `"Regex wins"` (Step 4).

---

### Activity 2.2: The `root` vs `alias` Laboratory (7 min)
1. Open [`starter_nginx.conf`](lab/starter_nginx.conf) in your editor.
2. Configure the shared media alias:
   ```nginx
   location /assets/media/ {
       alias www/media/;
       autoindex off;
   }
   ```
3. Test removing the trailing slash: change `alias www/media;`.
4. Fire a curl: `curl -I http://localhost:8080/assets/media/logo.png`.
5. Check `logs/error.log` to see the resulting path-munging error (`open() "www/medialogo.png" failed`).
6. Re-add the trailing slash and verify HTTP 200.

---

### Activity 2.3: SPA Routing & Edge Hardening (8 min)
1. In [`starter_nginx.conf`](lab/starter_nginx.conf), implement SPA fallback:
   ```nginx
   location /app/ {
       alias www/app/;
       index index.html;
       try_files $uri $uri/ /app/index.html;
   }
   ```
2. Strip NGINX version leakage in HTTP headers:
   ```nginx
   server_tokens off;
   ```
3. Deny access to all hidden dotfiles (like `.git` and `.env`):
   ```nginx
   location ~ /\. {
       deny all;
       access_log off;
       log_not_found off;
   }
   ```
4. Add permanent 301 redirect for legacy routes:
   ```nginx
   location = /legacy {
       return 301 /app/;
   }
   ```

---

### Activity 2.4: Automated Lab Verification (7 min)
Run the automated test runner to verify that all 12 acceptance criteria pass:
```bash
cd /Users/j.rahm/.gemini/antigravity/scratch/nginx-journey/sprints/sprint-01
./test_sprint01.sh
```

---

## 3. Day 2 Concept Examination (10-Question Randomized Quiz)

To verify today's learning, launch the **Day 2 Concept Quiz**:
* Samples **10 random questions** from our 20-question Day 2 pool.
* Passing score: **80% (8 of 10)**.

👉 **[Launch Day 2 Concept Examination (`day02_quiz.html`)](day02_quiz.html)**

---

## 4. Key Takeaways for Day 2
* **`^~` is your regex shield:** Use `^~` on static asset folders (like `/static/` or `/assets/`) to prevent expensive regex evaluations on every request.
* **Always match trailing slashes on `alias`:** `location /dir/` requires `alias /path/dir/;`.
* **Mind `add_header` inheritance:** Defining `add_header` inside a `location` clears all outer headers.

# Sprint 3 &bull; Day 1: TLS Termination at the Edge
**Day:** 1 of 3  
**Estimated Time:** 65 Minutes (15 concepts, 5 setup, 35 lab, 10 quiz)  
**Theme:** On BIG-IP, a client SSL profile holds the whole TLS policy. In NGINX the same policy is a handful of `ssl_*` directives spread across `http` and `server`, and where you put each one changes what it does.

---

## 1. Concepts to Understand (15 Minutes)

### 1.1 Where the TLS Policy Lives

| BIG-IP client SSL profile | NGINX | Notes |
| :--- | :--- | :--- |
| Profile attached to a virtual server | `listen ... ssl` plus `ssl_*` directives in that `server` (or inherited from `http`) | No named profile object. Policy is inherited like any other directive. |
| Cert-key-chain (one RSA + one ECDSA) | Two `ssl_certificate` / `ssl_certificate_key` pairs in one `server` | NGINX picks per handshake, from what the client says it can verify (1.3) |
| Options: No TLSv1.1, etc. | `ssl_protocols` | A list of what is **allowed** |
| Ciphers string / cipher rules | `ssl_ciphers` (TLS 1.2 and below) **and** `ssl_conf_command Ciphersuites` (TLS 1.3) | Two separate knobs (1.2) |
| SNI default profile, Server Name | `default_server` on the `listen`, and `server_name` | 1.4 |
| Cache size / timeout, session ticket | `ssl_session_cache`, `ssl_session_timeout`, `ssl_session_tickets` | Placement matters (1.5) |
| Server SSL profile (re-encrypt to pool) | `proxy_ssl_*` in the proxying location | Sprint 7 (mTLS) |

**The default is already strict.** On the lab's nginx 1.31.6:
* `ssl_protocols` defaults to TLS 1.2 and 1.3 only.
* Ubuntu's OpenSSL runs at security level 2, a **second gate** that refuses TLS 1.0/1.1 even if NGINX allowed them.

Older NGINX releases defaulted to TLS 1.0 and up. Configs copied from old blogs often turn that back on.

### 1.2 Two Cipher Knobs, Not One
TLS 1.3 redesigned cipher suites, and OpenSSL configures them through a different API.

| | TLS 1.2 | TLS 1.3 |
| :--- | :--- | :--- |
| Suite names | `ECDHE-ECDSA-AES128-GCM-SHA256` (key exchange, auth, cipher, MAC all in one name) | `TLS_AES_128_GCM_SHA256` (cipher and hash only; key exchange and auth negotiated separately) |
| NGINX directive | `ssl_ciphers` (OpenSSL cipher-string syntax) | `ssl_conf_command Ciphersuites` (passed straight to OpenSSL) |
| Default in the lab | `HIGH:!aNULL:!MD5`, which **still allows CBC suites** | All five TLS 1.3 suites (all are AEAD) |

* **`ssl_ciphers` never affects TLS 1.3.** A config that "removes AES-128" with `ssl_ciphers` alone still negotiates `TLS_AES_128_GCM_SHA256` with any TLS 1.3 client.
* `ssl_prefer_server_ciphers` (default `off`) decides whose order wins for TLS 1.2. With an all-AEAD list it matters little.
* **Key exchange** is a separate negotiation: the "group" (`X25519` here). `ssl_ecdh_curve` controls it. Post-quantum hybrids (`X25519MLKEM768`) need OpenSSL 3.5. The lab's OpenSSL 3.0.2 doesn't have them.

### 1.3 Dual Certificates: RSA and ECDSA
One `server` can hold one certificate per key type. During the handshake, OpenSSL picks one the client can verify.
* **TLS 1.3:** the client's `signature_algorithms` list decides. Modern clients list ECDSA first, so they get ECDSA. An RSA-only client gets RSA.
* **TLS 1.2:** the cipher suite decides. `ECDHE-ECDSA-*` needs the ECDSA cert, and `ECDHE-RSA-*` needs the RSA cert.
* **Why bother:** ECDSA P-256 handshakes are smaller and faster. RSA is kept for old clients and some appliances.
* **Failure is a handshake alert, not an HTTP error.** A client NGINX can't satisfy gets alert 40 (`handshake failure`). The reason (`no shared cipher`, `no suitable signature algorithm`) is logged only at `error_log ... info`.

### 1.4 SNI and the Default Server
The client names the site it wants in the TLS ClientHello (SNI), before any HTTP is sent.

**How NGINX picks the server**
* NGINX matches SNI against `server_name` to choose the `server`, and therefore the certificate.
* No SNI, or a name nobody claims, lands on the **default server** for that `address:port`: the first one, or the one marked `default_server`.
* Without a deliberate default, an unknown name gets **your** certificate, with a hostname mismatch. Scanners use this to map which names live on an IP.

**Refusing instead**
* `ssl_reject_handshake on` in a catch-all default server refuses the handshake with alert 112 (`unrecognized_name`). No certificate is sent.
* **Clients that connect by IP address send no SNI** (an IP isn't allowed in SNI). Monitors, scripts, and `curl https://10.1.1.4` get refused too. Decide whether that is what you want.

**BIG-IP lens:** the SNI default profile on BIG-IP *serves* a cert for unmatched names. `ssl_reject_handshake` is closer to an iRule that rejects on `SSL::extensions` before any cert goes out.

### 1.5 Session Resumption
A full handshake costs asymmetric crypto. Resumption lets a returning client skip it.

| Mechanism | Where the state lives | NGINX directive |
| :--- | :--- | :--- |
| Session cache (session IDs; stateful TLS 1.3 tickets) | Server memory: `builtin` is per worker, `shared:NAME:SIZE` is shared by all workers | `ssl_session_cache` (default: `none`) |
| Session tickets (stateless) | Encrypted in the ticket the client keeps; the server holds only the ticket **key** | `ssl_session_tickets` (default: `on`) |

**What decides whether resumption survives**
* **Ticket keys.** Without a shared cache or `ssl_session_ticket_key` files, NGINX generates random ticket keys **at every config load**. Every ticket issued before a reload becomes useless.
* **A shared cache** keeps sessions *and* NGINX's ticket keys in shared memory, which survives reloads.
* **Placement.** Resumption runs in the context of the **default server** of the listening socket, before SNI has switched to your `server`. A cache configured only inside `server lumina.local`, behind a separate default server, doesn't help. Put session settings at `http` level so every server on the port shares them. You'll prove this in Activity 3.6.
* **Several NGINX nodes behind a load balancer** need the same ticket keys on all nodes (`ssl_session_ticket_key` files, rotated together). Otherwise a client resuming on another node pays a full handshake. It's the same problem as BIG-IP session ticket keys across a device group.

### 1.6 HTTP to HTTPS
A plain-HTTP `server` that only redirects.
* **`301`/`302`** let clients change `POST` to `GET` on the redirect.
* **`307`/`308`** preserve the method and body.
* For a site that only serves `GET` on port 80, `301` is normal.
* The redirect is the client's **first, unencrypted** request. HSTS (Day 3) tells browsers to skip it next time.

---

## 2. Lab Setup (5 Minutes)

```bash
cd /srv/nginx-journey/sprints/sprint-3/lab
mkdir -p logs temp/{client,proxy,fastcgi,uwsgi,scgi}
./make_certs.sh                  # Lumina Lab CA + lumina-ecdsa + lumina-rsa in certs/ (gitignored)
cp day1_nginx.conf nginx.conf
ngx -t && ngx                    # 8083 (HTTP) and 8443 (HTTPS)
source helpers.sh                # c, hs, resume, h3: re-run in every new terminal
```

| Helper | What it does |
| :--- | :--- |
| `c [curl args] URL` | `curl` that trusts the Lumina Lab CA and resolves `lumina.local` to 127.0.0.1 |
| `hs [s_client args]` | One handshake to 8443, summarized: `New TLSv1.3 cipher=... sig=ECDSA kx=X25519`, or `FAILED <alert>`. A failed certificate check adds `VERIFY FAILED: <reason>` |
| `SNI=name hs`, `SNI= hs` | Send another SNI name, or none |
| `resume [--reload] [args]` | Save a session, optionally reload NGINX, then reconnect 4 times: `Reused` or `New` |

Port **8443** is new for Sprint 3. Sprint 2's 8082 lab can keep running.

---

## 3. Hands-on Guided Discovery Activities (35 Minutes)

Every activity edits `nginx.conf`. After each edit, run `ngx -t && ngx -s reload`.

### Activity 3.1: First Contact (4 min)
```bash
./make_certs.sh show
c https://lumina.local:8443/
curl -sI -H 'Host: lumina.local' 'http://localhost:8083/courses?id=7' | grep -iE '^(HTTP|location)'
hs
tail -2 logs/access.log
```
* The redirect keeps the path and query.
* `hs` shows TLS 1.3, `TLS_AES_256_GCM_SHA384`, an ECDSA signature, and X25519 key exchange. Nothing in the config asked for any of that. These are the defaults.
* The access log records the same facts per request (`$ssl_protocol`, `$ssl_cipher`, `$ssl_curve`).

### Activity 3.2: The Protocol Floor (6 min)
```bash
hs -tls1_2
hs -tls1_1
hs -tls1_1 -cipher 'DEFAULT@SECLEVEL=0'
```
* `hs -tls1_1` fails **on the client**: `CLIENT refused: no protocols available`. Your own OpenSSL won't even offer TLS 1.1 at security level 2.
* With the client's security level lowered, the request reaches NGINX and gets **`alert protocol version (70)`**. That's NGINX's default `ssl_protocols` refusing it.

*Try it (2 min, optional):* add `ssl_protocols TLSv1 TLSv1.1 TLSv1.2 TLSv1.3;` to the 8443 server and retry the last command. It still fails. Now also add `ssl_ciphers DEFAULT@SECLEVEL=0;`. Only with **both** gates opened does TLS 1.1 succeed. Remove both lines again.

*Journal:* a scanner reports "TLS 1.0 enabled" on an NGINX box. Which two things would you check?

### Activity 3.3: Cipher Policy, Both Knobs (8 min)
**a. The TLS 1.2 default allows CBC:**
```bash
hs -tls1_2 -cipher ECDHE-ECDSA-AES128-SHA          # accepted: CBC, not AEAD
```
**b. Restrict TLS 1.2 to ECDHE with AEAD ciphers.** Add to the 8443 server, under `ssl_certificate_key`:
```nginx
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers   ECDHE+AESGCM:ECDHE+CHACHA20;
```
```bash
ngx -t && ngx -s reload
hs -tls1_2 -cipher ECDHE-ECDSA-AES128-SHA          # now refused
hs -ciphersuites TLS_AES_128_GCM_SHA256            # TLS 1.3 with AES-128: what happens?
```
Predict the last result before you run it.

<details>
<summary>Result</summary>

* The CBC suite now gets **`alert handshake failure (40)`**.
* The TLS 1.3 AES-128 handshake **still succeeds**. `ssl_ciphers` doesn't touch TLS 1.3.
</details>

**c. Restrict TLS 1.3 too** (for example, a policy that wants 256-bit suites only):
```nginx
ssl_conf_command Ciphersuites TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256;
```
```bash
ngx -t && ngx -s reload
hs -ciphersuites TLS_AES_128_GCM_SHA256            # refused now
hs                                                 # normal clients are unaffected
grep -a 'no shared cipher' logs/error.log | tail -1
```
The failure reason is in the error log only because Day 1's config logs at `info`. At the usual `notice`, failed handshakes are invisible.

### Activity 3.4: Dual Certificates (6 min)
Act as a client that can only verify RSA:
```bash
hs -sigalgs rsa_pss_rsae_sha256:rsa_pkcs1_sha256   # TLS 1.3, RSA-only client
hs -tls1_2 -cipher ECDHE-RSA-AES128-GCM-SHA256     # TLS 1.2, RSA suite only
```
Both fail with alert 40, because the server only has an ECDSA certificate. Add the RSA pair next to the ECDSA one:
```nginx
ssl_certificate     certs/lumina-rsa.crt;
ssl_certificate_key certs/lumina-rsa.key;
```
```bash
ngx -t && ngx -s reload
hs -sigalgs rsa_pss_rsae_sha256:rsa_pkcs1_sha256   # sig=RSA-PSS
hs -tls1_2 -cipher ECDHE-RSA-AES128-GCM-SHA256     # sig=RSA-PSS
hs                                                 # sig=ECDSA: modern clients still get ECDSA
```

### Activity 3.5: SNI and the Default Server (6 min)
```bash
SNI=evil.example hs                                # unknown name
SNI= hs                                            # no SNI at all
SNI=evil.example hs -verify_hostname evil.example
```
Right now `lumina.local` is the only server on 8443, so it's the default. Both handshakes **succeed** and present the Lumina certificate. With hostname verification, `hs` adds `VERIFY FAILED: hostname mismatch`. `s_client` only reports a failed check and still finishes the handshake; a browser or `curl` would abort. Either way, the server sent a certificate to someone who asked for a different site.

Add a catch-all **above** the lumina server:
```nginx
server {
    listen 8443 ssl default_server;
    ssl_reject_handshake on;
}
```
```bash
ngx -t && ngx -s reload
SNI=evil.example hs                                # FAILED  tlsv1 unrecognized name (112)
SNI= hs                                            # same
hs                                                 # lumina.local still works
c -o /dev/null -w '%{http_code}\n' https://127.0.0.1:8443/; echo "curl exit $?"   # by IP: no SNI
```
* The rejecting server needs **no certificate**.
* Connecting by IP now fails too (`000`, exit 35). An IP-based health monitor would mark this node down.

### Activity 3.6: Session Resumption and Reloads (5 min)
```bash
resume                  # Reused x4: tickets work with zero config
resume --reload         # what happens across a reload?
```
<details>
<summary>Result</summary>

`New New New New` after the reload. With no shared cache, the ticket keys were regenerated when the config reloaded.
</details>

Add a shared cache **inside the lumina.local server**, next to the cipher lines:
```nginx
ssl_session_cache   shared:SSL:10m;
ssl_session_timeout 4h;
```
```bash
ngx -t && ngx -s reload
resume --reload
resume --reload -tls1_2
```
Still `New` after a reload, for both TLS 1.3 and 1.2. **Why?** Reread concept 1.5 before opening the answer.

<details>
<summary>Answer</summary>

The handshake, including the resumption lookup, starts in the **default server** for `*:8443`. That's now the `ssl_reject_handshake` catch-all from 3.5, which has no cache, so it still uses per-reload ticket keys. Move the two session lines (and, while you're at it, `ssl_protocols`, `ssl_ciphers` and `ssl_conf_command`) up to the **`http` block** so every server on the port shares them:
```bash
ngx -t && ngx -s reload
resume --reload             # Reused x4
resume --reload -tls1_2     # Reused x4
```
</details>

```bash
grep -c 'reused=r' logs/access.log      # requests that rode a resumed session
```

---

## 4. Day 1 Concept Examination (10-Question Randomized Quiz)

```bash
cd /srv/nginx-journey && python3 -m http.server 8090
```
👉 **http://&lt;lab-host&gt;:8090/quiz.html?sprint=3&day=1**

---

## 5. Key Takeaways for Day 1
* **A client SSL profile becomes `ssl_*` directives.** Put shared policy at `http` level and certificates in each `server`.
* **Two cipher knobs:**
  * `ssl_ciphers` governs TLS 1.2 and below.
  * `ssl_conf_command Ciphersuites` governs TLS 1.3.
  * Checking only one leaves the other wide open.
* **The 1.31 default already refuses TLS 1.0/1.1,** and OpenSSL's security level is a second gate.
* **Dual certificates are two `ssl_certificate` pairs.** The client's signature algorithms (TLS 1.3) or cipher suite (TLS 1.2) picks one.
* **Decide what unknown SNI gets.** `ssl_reject_handshake` refuses it (alert 112), and IP-only clients are refused with it.
* **Resumption survives reloads only with a shared cache** (or ticket key files), and only where the **default server** can see it.
* **Handshake failures are `info`-level log lines.** Turn the level up while debugging TLS.

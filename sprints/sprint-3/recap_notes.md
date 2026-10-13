# Sprint 3 Recap Notes (working file)
Raw findings and clarifications collected during the sprint, to be shaped into the recap. Everything here was verified on the lab's nginx 1.31.6 (OpenSSL 3.0.2) unless marked otherwise.

---

## Findings From Building the Sprint

### TLS (Day 1)
* **Two gates in front of TLS 1.0/1.1.** The 1.31.6 default `ssl_protocols` excludes them (alert 70), and Ubuntu's OpenSSL `SECLEVEL=2` refuses them too. TLS 1.1 only worked with *both* `ssl_protocols TLSv1 TLSv1.1 ...` and `ssl_ciphers DEFAULT@SECLEVEL=0`. Even the client needs `-cipher DEFAULT@SECLEVEL=0`, or it fails locally with `no protocols available`.
* **The default `ssl_ciphers` (`HIGH:!aNULL:!MD5`) still allows CBC in TLS 1.2.** `ssl_ciphers` never touches TLS 1.3: with `ssl_ciphers` restricted, `TLS_AES_128_GCM_SHA256` still negotiated until `ssl_conf_command Ciphersuites` was set.
* **Dual certificates:** a modern client gets ECDSA. RSA-only sigalgs (TLS 1.3) or an `ECDHE-RSA` suite (TLS 1.2) get RSA. With only an ECDSA certificate, both RSA-only clients got alert 40, logged at `info` only (`no suitable signature algorithm`, `no shared cipher`).
* **SNI:** connecting by IP sends no SNI, so a `ssl_reject_handshake` default server refuses it (alert 112).
* **Resumption matrix** (2 workers, `s_client -sess_out/-sess_in`):

  | Config | Resumes | After reload |
  | :--- | :--- | :--- |
  | Defaults (tickets on, cache `none`) | Yes | No |
  | `ssl_session_tickets off`, no cache | No | No |
  | `shared` cache (tickets on or off) | Yes | Yes |
  | `builtin` cache, tickets off | Mostly (the first reconnect missed: per worker) | No |

* **Placement matters:** a shared cache only inside `server lumina.local`, behind a separate `ssl_reject_handshake` default server, did **not** survive reloads. Moving it to `http` level (or into the default server too) fixed it. Resumption happens in the default server's context.
* **TLS 1.3 tickets arrive after the handshake.** `echo | openssl s_client -sess_out` closes too early and saves nothing. The helpers keep the connection open with `(sleep 0.3) |`.
* **`s_client` prints `Verify return code: 0 (ok)` even when the handshake failed.** Don't grep for it to detect success; check for a cipher other than `(NONE)`.
* **`s_client`'s `New, TLSv1.0, Cipher is ...` line shows the cipher's spec version, not the negotiated protocol.** The `Protocol :` line in the session block is the real one.

### HTTP/2 and HTTP/3 (Day 2)
* Three parallel 2 s requests: one connection with `reqs=1,2,3` over HTTP/2, three connections over HTTP/1.1 (both ~2 s), and ~6 s with one HTTP/1.1 connection.
* **HPACK is visible in `$request_length`:** a 600-byte header cost 422 bytes, then 11 bytes on the repeat (HTTP/2). HTTP/1.1 paid 695 both times.
* **The upstream protocol is independent:** mocks saw HTTP/1.1 for h1, h2 and h3 clients. `proxy_http_version 2` exists on 1.31.6 and worked against an h2c NGINX backend.
* **HTTP/3 client:** the host's curl 7.81, `curlimages/curl:8.16.0` and Alpine 3.22's curl all lack HTTP/3. `alpine/curl-http3:8.11.0` (quiche) works.
* **QUIC SNI gap:** a TCP-only `ssl_reject_handshake` default server leaves UDP unprotected. An unknown SNI got a 200 over HTTP/3. Fix: `listen 8443 quic reuseport default_server;` on the catch-all, plain `listen 8443 quic;` on lumina. Two `reuseport`s on one port: `[emerg] duplicate listen options`.
* The `quic fixed bit is not set` lines at `info` level come from the quiche client and are harmless.

### Headers (Day 3)
* `add_header_inherit merge` exists on 1.31.6 and restores inherited headers in a child that adds its own.
* Without `always`, proxied 404/502 responses had none of the security headers. `always` covers them, over HTTP/3 too.

### Side Quest A (NGINX Plus R37.1)
* `ssl_certificate data:$var` from `keyval`: an empty store means alert 80 and `cannot load certificate "data:"`.
* **The API updates one key per PATCH** (`only one key can be updated`, 400). Cert and key under separate keys gave a window of failed handshakes (`SSL_use_PrivateKey` error). One key holding key + cert as one PEM bundle, used by both directives, rotated under a 40-handshake loop with 0 failures and unchanged worker PIDs.
* `ssl_certificate_key data:` with a bundle works in either PEM order. (An earlier "fails" result was the stale-mount trap below.)
* **Single-file bind mount trap:** `sed -i` on `plus/nginx.conf` replaced the inode, and the container kept serving the old config through `nginx -s reload`. Added to `docs/nginx-plus-lab.md`.
* The state file (`lumina_certs.json`) restored the certificate after `docker restart`.
* `$HOME` was empty in a non-login shell again. `--mount` refused to start (`bind source path does not exist: /plus/license.jwt`) instead of creating a directory, which is exactly why the convention uses `--mount`.

### Side Quest B (`nginx-module-acme` 0.4.1 + Pebble 2.8.0)
* `nginx-module-acme` installs from the nginx.org apt repo as a dynamic module (`load_module`).
* **A relative `state_path` resolves under `/var/cache/nginx`,** not the `-p` prefix: `mkdir() "/var/cache/nginx/state/pebble" failed`. Use an absolute path.
* The module creates `state_path` itself (`nginx:root`, mode 700). The `.crt`/`.key` inside are mode 666, so the directory is the only protection. A first test under `/root` failed to persist (`writing certificate to state directory failed`) only because `/root` isn't traversable by the `nginx` user.
* **HTTP-01 succeeded on a server whose only directive was `return 301`.** The module answers challenges before the rewrite phase. Pebble made 3 validation requests (multi-perspective).
* Pebble issued a **6-day** certificate with an empty subject (SAN only), and the module logged the CA's ARI renewal window.
* A restart reused the stored certificate (same serial). Before the first issuance, handshakes fail with alert 80.
* Pebble's image is distroless (no `cat`): copy `pebble.minica.pem` out with `docker create` + `docker cp`.

---

## Day 1
* **Q: Can Ubuntu be made to allow TLS 1.0/1.1? Does NGINX have its own crypto?** Verified on 8088:
  * NGINX has no TLS or crypto stack of its own. The package links `libssl.so.3`/`libcrypto.so.3` dynamically (`ldd`), so the handshake, ciphers and certificate checks all belong to the system OpenSSL. NGINX owns policy and plumbing: directives → `SSL_CTX` calls, SNI → `server` selection, ALPN choice, the shared session cache, ticket keys, OCSP fetching, and the QUIC transport (TLS inside QUIC is still OpenSSL, via the compat layer).
  * The handoff runs in layers: Ubuntu compiles in a floor (`-DOPENSSL_TLS_SECURITY_LEVEL=2`). NGINX loads `openssl.cnf` at startup (`system_default`: `CipherString = DEFAULT:@SECLEVEL=2`), then applies its own directives to each `SSL_CTX`, and whatever is set last wins. A plain `ssl_ciphers` without `@SECLEVEL` keeps the inherited level.
  * With `ssl_protocols TLSv1 TLSv1.1 ...` alone: alert 70, logged as `unsupported protocol`. Any one of these unlocks both versions: `ssl_ciphers DEFAULT@SECLEVEL=0`, `ssl_conf_command CipherString DEFAULT@SECLEVEL=0`, or (system side, no NGINX change) an `openssl.cnf` whose `system_default` sets `@SECLEVEL=0`, pointed to with `OPENSSL_CONF`. Editing `/etc/ssl/openssl.cnf` itself would lower the floor for every OpenSSL app on the host.
  * BIG-IP delta: no equivalent of a vendor-owned TLS stack. The crypto library's version and distro patches are part of NGINX's behavior. Other builds can link BoringSSL, AWS-LC, LibreSSL or quictls instead.

* **Q: Patching OpenSSL under a running NGINX.** Walked through on the Day 1 lab (`libssl3` `3.0.2-0ubuntu1.10` → `1.30`):
  * **The version string never changes.** `openssl version` and `nginx -V` both still say `3.0.2 15 Mar 2022` after the upgrade. Ubuntu backports fixes into the release's upstream version, so the package revision (`dpkg -l libssl3`, `apt changelog libssl3`) is the real patch level. `nginx -V` is build-time information anyway. The box had been ~20 security revisions (≈3 years) behind while NGINX itself was current.
  * **After `apt`, the running NGINX keeps the old library:** `/proc/<pid>/maps` shows `libssl.so.3 (deleted)`.
  * **`nginx -s reload` doesn't fix it.** The new workers are copies of the old master and still had the deleted library loaded.
  * **`kill -USR2` fixes it with zero downtime.** The new master re-executes `/usr/sbin/nginx` and loads the patched library, and both generations serve until `WINCH` (old workers drain) and `QUIT` (old master exits). Until `QUIT`, `HUP` to the `.oldbin` master is the rollback. Right after `USR2`, `nginx.pid` briefly doesn't exist yet. The nginx.org package's `/etc/init.d/nginx upgrade` scripts the same sequence, and `systemctl restart` is the version with a gap.
  * **Detection:** `/proc/<pid>/maps` is the ground truth, but grep for `lib(ssl|crypto).*(deleted)`. A bare `(deleted)` also matches NGINX's shared memory zones (`/dev/zero (deleted)`) and each worker's `/[aio] (deleted)`, which are normal. `lsof +L1` misses mapped libraries; use `lsof -nP | grep DEL`. `needrestart` flagged `systemd-logind` and `cloud-final` but **not** the lab NGINX started from a shell, so don't count on it for processes outside systemd.
  * BIG-IP delta: a TLS stack fix there is an F5 hotfix image and a reboot. Here the package manager swaps the library under a running process, and you choose when NGINX picks it up. SBOM view: packaged NGINX inherits the host's `libssl3`, a container image carries its own (rebuild/re-pull), and a `--with-openssl=` build compiles it in (rebuild; package scanners may miss it).

* **Q: Can this box get OpenSSL 3.5 for post-quantum hybrids?** Not from `apt`: Ubuntu 22.04 stays on 3.0.2 (backports only), and 24.04 is on 3.0.13. 26.04 ships `3.5.5`. Replacing the system `libssl3` by hand would break apt-managed software, and a custom `--with-openssl=` NGINX build takes you off the packages. The cheap path is the official `nginx:mainline` image (Debian 13, nginx 1.31.6, `built with OpenSSL 3.5.6 ... (running with OpenSSL 3.5.7)`, another build-vs-runtime example). Verified on 8089 with the lab ECDSA cert and **no NGINX PQ config**: a 3.5 client negotiated `X25519MLKEM768` by default, and the host's 3.0.2 client fell back to `X25519`. The hybrid key shares are 1216 bytes (client) and 1120 bytes (server) versus 32 for X25519, so the ClientHello can exceed one packet. The certificate (authentication) is still classical; only key exchange is PQ.

* **Quiz:** 9/10 on the first attempt. Day 1 recap written: `day01_recap.md`.
* **Recap asset:** `aead-vs-cbc.png` (+ `.svg` source, Lato, rendered with resvg at 2x): MAC-then-encrypt vs AEAD record protection, the CBC/RC4 attack timeline (padding oracle 2002 → Zombie POODLE/GOLDENDOODLE 2019, incl. BIG-IP CVE-2014-8730), what AEAD doesn't fix, and the `ssl_ciphers` vs `Ciphersuites` split.

* **Q: Do `ssl_protocols` and `ssl_ciphers` have to be set together?** No, they're independent filters and a handshake needs a protocol *and* a suite valid for it. `ssl_ciphers ECDHE+AESGCM` alone, with default protocols: TLS 1.0 still gets alert 70 from `ssl_protocols`. Two real couplings: `@SECLEVEL` inside the `ssl_ciphers` string gates protocols (Activity 3.2), and an AEAD-only TLS 1.2 list leaves TLS 1.0/1.1 with no usable suite. Activity 3.3's `ssl_protocols TLSv1.2 TLSv1.3` only restates the 1.31.6 default; it's pinning policy so a config doesn't depend on version defaults (older NGINX enabled TLS 1.0/1.1).
* **`ssl_conf_command` behavior** (8088):
  * A typo is caught by `nginx -t`: `[emerg] SSL_CONF_cmd("Ciphersuites", ...) failed ... no cipher match`.
  * It is applied after the native directives: `ssl_conf_command CipherString ECDHE+AESGCM` beat `ssl_ciphers HIGH:!aNULL` in either file order.
  * **Inheritance trap (like `add_header`):** `Ciphersuites` at `http` plus *any* `ssl_conf_command` in the `server` (e.g. `Options PrioritizeChaCha`) dropped the inherited TLS 1.3 policy and AES-128 was accepted again. Only at `http` = enforced.
  * Keeping policy coherent: one `tls-policy.conf` snippet included at `http`, never `ssl_conf_command` at lower levels; or system-wide via `openssl.cnf` (`Ciphersuites` under `system_default`), which `nginx -T` doesn't show.
* **`grep: logs/error.log: binary file matches`:** a client whose own OpenSSL refuses TLS 1.1 still opens TCP and sends a TLS alert 70 (`15 03 03 00 02 02 46`, captured with `nc`). Sent to the plain-HTTP 8083 server, NGINX logged it as the request line (`client sent invalid method ... request: "\x15\x03..."`, access log `400 sni=-`). GNU grep then treats the whole log as binary. Use `grep -a`.

## Day 2

## Day 3

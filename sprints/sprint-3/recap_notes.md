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

## Day 2

## Day 3

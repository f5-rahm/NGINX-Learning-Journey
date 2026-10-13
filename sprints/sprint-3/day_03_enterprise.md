# Sprint 3 &bull; Day 3 (Optional) Enterprise Side Quest: Certificates Without Reloads, Certificates Without Humans
**Week of:** Oct 12 (optional, after Day 3)  
**Estimated Time:** 45 Minutes (10 concepts, 5 setup, 2 × 15 hands-on). Part A and Part B are independent: do either or both.  
**Theme:** Day 1 loaded certificates from files, so changing one means a reload. Part A changes them through the NGINX Plus API with no reload. Part B has NGINX get and renew them by itself over ACME.

> **Status:** Both parts were run end to end on the lab box (Part A on NGINX Plus R37.1, Part B on nginx 1.31.6 with `nginx-module-acme` 0.4.1 and Pebble 2.8.0), on scratch ports. The commands below use the lab's real ports.

---

## 1. Concepts to Understand (10 Minutes)

### 1.1 Why Certificate Changes Are Becoming Constant
* **Public certificate lifetimes are shrinking by industry rule** (CA/Browser Forum ballot SC-081):
  * 200 days maximum since March 2026.
  * 100 days from March 2027.
  * 47 days from March 2029.
  * Let's Encrypt also offers 6-day certificates.
* Renewal turns from a yearly change window into a weekly or daily background job.
* **Two problems follow:**
  * **Where the certificate comes from:** issuance and renewal (Part B, ACME).
  * **How it gets into the running proxy:** a file plus a reload, or something live (Part A).

### 1.2 Part A: Certificates From the Key-Value Store (NGINX Plus)
What open source already has, and what NGINX Plus adds:

| Capability | Where | What it means |
| :--- | :--- | :--- |
| Variables in `ssl_certificate` (`$ssl_server_name.crt`) | OSS (since 1.15.9) | Pick a **file** per handshake, for many names without many `server` blocks |
| `data:` prefix | OSS | The value **is** the PEM, not a path |
| `keyval_zone` / `keyval` + **write API** | **NGINX Plus** | A key-value store in shared memory, written through the REST API, optionally persisted to a `state` file |

Put them together, `ssl_certificate data:$value_from_keyval`, and a certificate becomes **data in shared memory** instead of a file in the config.
* Writing a new value through the API changes the certificate for the **next handshake**, in every worker, with no reload. The worker PIDs don't change.
* **One key holds the private key and the certificate together as one PEM bundle.** The API changes **one key per `PATCH`**. With the cert and key under two separate keys, there's a moment where the new certificate meets the old key and every handshake fails. A single bundle makes the rotation atomic.
* **An empty or missing key is a failed handshake** (alert 80, `internal error`), not a fallback to some other certificate.

**BIG-IP lens**
* Updating an SSL profile's cert/key on BIG-IP is a live config change with no restart. This brings NGINX to the same place.
* At fleet scale, pushing certificates to many instances is a management-plane job (NGINX One / Instance Manager, Sprint 11), much like BIG-IQ.

### 1.3 Part B: ACME, In-Process
ACME (RFC 8555) is the protocol behind Let's Encrypt and most automated public CAs:
* create an account;
* place an **order** for names;
* prove control of each name with a **challenge**;
* **finalize** with a CSR;
* download the certificate;
* renew before expiry.

**Challenge types**

| Challenge | Proof | Fits |
| :--- | :--- | :--- |
| HTTP-01 | Serve a token at `http://<name>/.well-known/acme-challenge/<token>` **on port 80** | A public web edge (the lab points Pebble at 8087 instead) |
| TLS-ALPN-01 | Answer a special TLS handshake on port 443 | Edges without port 80 |
| DNS-01 | Publish a TXT record | Wildcards, internal names |

**`nginx-module-acme`** is F5's open source ACME client, built as an NGINX module (`ngx_http_acme_module`). It runs inside NGINX, for open source NGINX and NGINX Plus alike. The whole job lives in the config:
* `acme_issuer` declares the CA.
* `acme_certificate` in a `server` requests a certificate for its `server_name`.
* `$acme_certificate` / `$acme_certificate_key` feed `ssl_certificate`.

**How it behaves**
* The module answers HTTP-01 challenges **itself**, before the rewrite phase. A blanket `return 301` to HTTPS on port 80 doesn't block validation.
* Issued certificates are kept under `state_path`. A restart reuses them instead of placing a new order.
* Renewal follows the CA's suggested window (ACME Renewal Information) when the CA offers it.
* **Until the first certificate is issued, HTTPS handshakes fail** (alert 80). Plan the first start.

**BIG-IP lens:** ACME on BIG-IP has usually meant an external client (for example, a `dehydrated`-based script) creating certificates and pushing them through iControl. Here the client is the proxy.

**Pebble** is Let's Encrypt's ACME **test** server. It speaks the real protocol, issues from a throwaway CA, and needs no public DNS. That makes it ideal for a private lab box.

---

## Part A: NGINX Plus Key-Value Certificates (15 Minutes)

### A.0 Setup (one-time Plus setup per [`docs/nginx-plus-lab.md`](../../docs/nginx-plus-lab.md))

| | Value |
| :--- | :--- |
| Container | `lumina-tls-plus`, from `$PLUS_IMAGE` |
| Config | `lab/plus/nginx.conf` → `/etc/nginx/nginx.conf` |
| Traffic | **8444** (TLS, certificate from the key-value store) |
| API | `127.0.0.1:8085` |
| State | `lab/plus/state/`: `lumina_certs.json` is written here |

```bash
cd /srv/nginx-journey/sprints/sprint-3/lab
source helpers.sh && source ~/plus/plus.env
chmod 777 plus/state
cp ../../sprint-2/lab/plus/state/nginx-mgmt-state plus/state/ 2>/dev/null   # keep Sprint 2's licensing identity (optional)
docker run -d --name lumina-tls-plus --network host \
  --mount type=bind,src="$PWD/plus/nginx.conf",dst=/etc/nginx/nginx.conf,readonly \
  --mount type=bind,src="$HOME/plus/license.jwt",dst=/etc/nginx/license.jwt,readonly \
  --mount type=bind,src="$PWD/plus/state",dst=/var/lib/nginx/state \
  "$PLUS_IMAGE"
until curl -s http://127.0.0.1:8085/api/ | grep -q '^\['; do sleep 1; done    # the first start takes a few seconds
V=$(curl -s http://127.0.0.1:8085/api/ | jq '.[-1]'); echo "Plus API version $V"
api() { curl -s "http://127.0.0.1:8085/api/$V$1" "${@:2}"; echo; }
K=/http/keyvals/lumina_certs
bundle() { jq -n --rawfile k "certs/$1.key" --rawfile c "certs/$1.crt" '{"lumina.local": ($k + $c)}'; }   # key + cert, one value
served() { PORT=8444 _sclient 2>/dev/null | openssl x509 -noout -serial -enddate 2>/dev/null | tr '\n' ' '; echo; }
```
`bundle NAME` builds the JSON for one key. `served` prints the serial and expiry of whatever 8444 is presenting right now.

### A.1 An Empty Store (2 min)
```bash
served                                                        # nothing: the handshake failed
PORT=8444 hs                                                  # FAILED  tlsv1 alert internal error (80)
docker logs lumina-tls-plus 2>&1 | grep 'cannot load certificate' | tail -1
```
`ssl_certificate data:$lumina_pem` evaluated to `data:` with nothing after it.

### A.2 Load a Certificate Through the API (3 min)
```bash
api $K -X POST -d "$(bundle lumina-ecdsa)" -o /dev/null -w '%{http_code}'   # 201
served                                                        # serial of certs/lumina-ecdsa.crt
openssl x509 -in certs/lumina-ecdsa.crt -noout -serial
api $K | jq 'keys'                                            # ["lumina.local"]
```

### A.3 Rotate Under Load, With No Reload (6 min)
Issue a replacement (short-lived, as in 1.1), then swap it in while a client keeps handshaking:
```bash
./make_certs.sh issue lumina-v2 30 ec
docker top lumina-tls-plus | awk '/worker/{print $2}'          # note the worker PIDs
( fails=0; for i in $(seq 40); do [ -z "$(served | tr -d ' ')" ] && fails=$((fails+1)); sleep 0.05; done; echo "failed handshakes: $fails" ) &
sleep 0.5; api $K -X PATCH -d "$(bundle lumina-v2)" -o /dev/null -w '%{http_code}'   # 204
wait
served                                                        # new serial, expiry ~30 days out
docker top lumina-tls-plus | awk '/worker/{print $2}'          # same PIDs
```
* **0 failed handshakes**, a new certificate, the same workers.
* A reload would have started new workers and, as Sprint 2 Day 4 showed, left old ones serving their long-lived connections with the old certificate.

### A.4 Why One Key (2 min)
```bash
api $K -X PATCH -d '{"lumina.local":"x","lumina.local.key":"y"}' | jq -c .error
```
`only one key can be updated`. If the certificate and key lived under two keys, a rotation would be two `PATCH` calls, with failing handshakes in between: a new certificate paired with the old key. The bundle avoids that.

### A.5 Persistence (2 min)
```bash
docker restart lumina-tls-plus; until curl -s http://127.0.0.1:8085/api/ | grep -q '^\['; do sleep 1; done
served                                                        # still lumina-v2: read back from plus/state/lumina_certs.json
```
*Journal:* the state file holds a **private key**. Where would you keep it in production, and who can read it?

> **Lab trap:** `plus/nginx.conf` is bind-mounted as a single file. Editors and `sed -i` replace the file with a new one, and the container keeps seeing the **old** file. After editing it, run `docker restart lumina-tls-plus`, not `nginx -s reload` inside the container.

**Cleanup:** `docker rm -f lumina-tls-plus`

---

## Part B: ACME With `nginx-module-acme` and Pebble (15 Minutes)

### B.0 Setup

| | Value |
| :--- | :--- |
| NGINX | A second **open source** instance from `lab/acme/` (`ngx`), config `lab/acme/nginx.conf` |
| Ports | **8087** HTTP (challenges + redirect), **8447** HTTPS |
| Pebble | Container `lumina-pebble`: ACME directory `https://localhost:14000/dir`, management `:15000`, validates HTTP-01 on **8087** |
| Name | Pebble resolves `lumina.local` to 127.0.0.1 (`--add-host`) |

```bash
sudo apt-get install -y nginx-module-acme       # already installed on the lab box; harmless to rerun
cd /srv/nginx-journey/sprints/sprint-3/lab/acme
source ../helpers.sh                            # hs, _sclient (skip if Part A already loaded them)
mkdir -p logs temp/{client,proxy} pebble
docker pull -q ghcr.io/letsencrypt/pebble:2.8.0
id=$(docker create ghcr.io/letsencrypt/pebble:2.8.0)                   # the image has no shell: copy its CA out
docker cp "$id":/test/certs/pebble.minica.pem pebble/ && docker rm "$id"
docker run -d --name lumina-pebble --network host --add-host lumina.local:127.0.0.1 -e PEBBLE_VA_NOSLEEP=1 \
  --mount type=bind,src="$PWD/pebble-config.json",dst=/test/config/pebble-config.json,readonly \
  ghcr.io/letsencrypt/pebble:2.8.0
```
* `pebble.minica.pem` is the CA of Pebble's **API** certificate, which NGINX must trust to talk ACME (`ssl_trusted_certificate`).
* The certificates Pebble *issues* chain to a different root, generated fresh at every Pebble start (B.2).

### B.1 Start NGINX and Watch the Order (5 min)
Read `nginx.conf` first: `acme_issuer`, `acme_certificate`, and the two `$acme_*` variables. There's no certificate file anywhere.
```bash
PORT=8447 hs                                    # before NGINX starts: nothing listening
ngx -t && ngx
PORT=8447 hs                                    # right after start: FAILED (80) until the first issuance completes
sleep 8
grep -E 'acme' logs/error.log | cut -c1-170     # account created ... certificate issued, renewal scheduled at ...
cat logs/access.log                             # Pebble's validation requests
```
* **Three `GET /.well-known/acme-challenge/...` requests answered `200`** on the server whose only line is `return 301`. The module served the challenge before the rewrite phase ran.
* Pebble validates from several "perspectives", like Let's Encrypt.

### B.2 Inspect What Was Issued (5 min)
```bash
PORT=8447 _sclient 2>/dev/null | openssl x509 -noout -issuer -subject -dates -ext subjectAltName
curl -s --cacert pebble/pebble.minica.pem https://localhost:15000/roots/0 > pebble/root.pem   # this run's issuing root
curl -s --cacert pebble/root.pem --resolve lumina.local:8447:127.0.0.1 https://lumina.local:8447/
ls -la state/
```
* **Issuer** `Pebble Intermediate CA ...`, **empty subject, SAN only**, and roughly **6 days** of validity. Short-lived certificates are where public CAs are heading (1.1).
* `state/` belongs to the `nginx` user, mode `700`: the module created it. The `.key` file inside is mode `666`, so the directory's `700` is the only protection.

### B.3 Restart and Renewal (5 min)
```bash
PORT=8447 _sclient 2>/dev/null | openssl x509 -noout -serial
ngx -s quit; sleep 1; : > logs/error.log; ngx; sleep 4
PORT=8447 _sclient 2>/dev/null | openssl x509 -noout -serial     # the same serial: reused from state/, no new order
grep -E 'renewal' logs/error.log | cut -c1-170                   # the CA's suggested renewal window
```
*Journal:*
* Compare this with Part A. Which one gives you the certificate, and which one changes the running certificate without a reload?
* Could the two be combined?

**Cleanup:**
```bash
ngx -s quit
docker rm -f lumina-pebble
```

---

## 2. Side Quest Quiz (Optional, 10 Questions)

👉 **http://&lt;lab-host&gt;:8090/quiz.html?sprint=3&day=3&pool=enterprise**

---

## 3. Key Takeaways
* **Certificate lifetimes are shrinking toward weeks,** so issuance and installation both need automation.
* **NGINX Plus key-value certificates** (`keyval` + `ssl_certificate data:$var` + the write API) change certificates live, with no reload. Store the key and certificate as **one bundle**, because the API changes one key per call.
* **`nginx-module-acme` puts the ACME client inside NGINX** (open source or Plus): it answers HTTP-01 before any rewrite, keeps state across restarts, and renews on the CA's schedule.
* **No certificate yet means failed handshakes, not a default certificate,** in both approaches. Plan first starts and empty stores.

# Running NGINX Plus in the Lab (Side Quest Convention)

Every Enterprise Side Quest that needs NGINX Plus runs it the same way. Open source NGINX stays on the host, and NGINX Plus runs in a container next to it. Day guides link here instead of re-explaining the setup.

---

## 1. Two Engines, One Box

| | NGINX OSS (core track) | NGINX Plus (side quests) |
| :--- | :--- | :--- |
| **Runs as** | Host binary `/usr/sbin/nginx`, started from the sprint's `lab/` directory | Docker container from `private-registry.nginx.com/nginx-plus/base` |
| **Start** | `ngx` (shell function: `-p $PWD -c $PWD/nginx.conf`) | `docker run -d --name <lab>-plus ...` (template in 3) |
| **Config** | `lab/nginx.conf` | `lab/plus/nginx.conf`, mounted read-only at `/etc/nginx/nginx.conf` |
| **License** | None | `~/plus/license.jwt` on the host, mounted read-only at `/etc/nginx/license.jwt` |
| **Test / reload** | `ngx -t` / `ngx -s reload` | `docker exec <lab>-plus nginx -t` / `docker exec <lab>-plus nginx -s reload` |
| **Logs** | `lab/logs/` | `docker logs <lab>-plus` (Plus configs log to stdout/stderr) |
| **Persistent state** | n/a | `lab/plus/state/`, mounted at `/var/lib/nginx/state` |
| **Network** | Host | `--network host`, so the container reaches the mocks on `127.0.0.1:800x` |
| **Stop** | `ngx -s quit` | `docker rm -f <lab>-plus` |

**Ports:** each sprint picks its Plus traffic port (never the OSS lab's port). The Plus API and dashboard are always on **`127.0.0.1:8085`**.

**Why a container:** the OSS install on the host is never touched, the license only exists inside the Plus process, and changing Plus versions means changing one image tag.

---

## 2. One-Time Setup (Once per Lab Box)

The license file stays **outside the repo**, so it can never be committed. All side quests reuse it.

```bash
mkdir -p -m 700 ~/plus
cp /path/to/downloaded/license.jwt ~/plus/license.jwt     # from MyF5 (a trial is fine)
chmod 600 ~/plus/license.jwt

# The same JWT is your registry credential
docker login private-registry.nginx.com --username="$(cat ~/plus/license.jwt)" --password=none

# Pin the image once; every side quest sources this file
echo 'PLUS_IMAGE=private-registry.nginx.com/nginx-plus/base:r37.1-debian' > ~/plus/plus.env
source ~/plus/plus.env && docker pull "$PLUS_IMAGE"
```
* **Pin a release tag.** Up to R36, tags were `rNN-debian` (`r36-debian`). From R37 on, releases have a point number: `r37.1-debian`, with an identical alias `nginx-plus-r37.1-debian`. There's no plain `r37`. Release tags are rebuilt with OS patches but never change release.
* **Avoid floating tags** (`debian`, `alpine`, `nginx-plus`, `nginx-plus-YYYYMMDD`). They jump to the next release on your next pull and can silently change the NGINX base and the API version under a guide.
* **Use `nginx-plus/base`, not `nginx-plus/agent`.** The `agent` image adds the NGINX Agent for NGINX One / Instance Manager. The labs don't use a management plane.
* List the release tags your license can pull, then update `plus.env` when you move to a new release:
  ```bash
  curl -s -u "$(cat ~/plus/license.jwt):none" https://private-registry.nginx.com/v2/nginx-plus/base/tags/list \
    | jq -r '.tags[]' | grep -E '^r[0-9]+(\.[0-9]+)?-(debian|alpine)$' | sort -V | tail -6
  ```
* Check what an image contains without a license: `docker run --rm --entrypoint nginx "$PLUS_IMAGE" -v`.
* The pull takes a few minutes, so you can do it ahead of time.
* `docker login` warns about `--password` on the command line and about unencrypted storage. On a single-user lab box both are fine: the password is literally `none`, and `/root/.docker/config.json` is `600` root, the same protection as the license file. You only need to be logged in to **pull**, so `docker logout private-registry.nginx.com` afterward removes the stored token.

| Host path | What it is | In git? |
| :--- | :--- | :--- |
| `~/plus/license.jwt` | Your license and registry credential | **Never** |
| `~/plus/plus.env` | `PLUS_IMAGE=...`, the pinned image | No |
| `sprints/sprint-N/lab/plus/nginx.conf` | That side quest's Plus config | Yes |
| `sprints/sprint-N/lab/plus/state/` | Upstream `state` files and Plus licensing state written at runtime | Only `.gitkeep` |

---

## 3. Starting a Side Quest Container

From the sprint's `lab/` directory:
```bash
source ~/plus/plus.env
chmod 777 plus/state                                    # the container's nginx user writes here
docker run -d --name <lab>-plus --network host \
  --mount type=bind,src="$PWD/plus/nginx.conf",dst=/etc/nginx/nginx.conf,readonly \
  --mount type=bind,src="$HOME/plus/license.jwt",dst=/etc/nginx/license.jwt,readonly \
  --mount type=bind,src="$PWD/plus/state",dst=/var/lib/nginx/state \
  "$PLUS_IMAGE"
docker logs <lab>-plus 2>&1 | tail -20                  # licensing / usage report lines
curl -s http://127.0.0.1:8085/api/                      # API answers: Plus is up
```
`/etc/nginx/license.jwt` is NGINX Plus's default `license_token` path, so the Plus configs don't need an `mgmt` block.

Use `--mount`, not `-v`. If a `-v` source path doesn't exist (for example, `$HOME` is empty in that shell), Docker silently creates it as a **directory** and mounts that. NGINX Plus then fails with `pread() "/etc/nginx/license.jwt" failed (21: Is a directory)` and `License file is required`. `--mount` refuses to start with `bind source path does not exist`.

---

## 4. When Something Is Wrong

| Symptom | Check |
| :--- | :--- |
| `docker login` or `pull` fails | The JWT is expired or for a different product. Download it again from MyF5. |
| Container exits right away | `docker logs <lab>-plus`. A config error, or a missing license file. `license.jwt failed (21: Is a directory)` means a `-v` mount pointed at a path that didn't exist. |
| Container runs, but traffic is refused | First usage report hasn't succeeded (`enforce_initial_report on` is the default). Look for licensing lines in `docker logs`, and check outbound HTTPS to `product.connect.nginx.com`. |
| `port already in use` | The OSS instance or another container holds the port. `ss -ltnp \| grep <port>`. |
| API answers, but writes fail with `UpstreamStatic` | The upstream has no `zone`. |

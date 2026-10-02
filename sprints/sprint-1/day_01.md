# Sprint 1 &bull; Day 1: Architecture, Process Lifecycle & Signals
**Estimated Time:** 60–75 Minutes of Guided Hands-on Discovery  
**Theme:** Master the execution engine, process hierarchy, and Unix signals before writing web server configs.

---

## 1. Concepts to Understand (15 Minutes)

### 1.1 The C10K Problem & Event-Driven I/O
Traditional web servers (like Apache MPM prefork) spawn a dedicated OS thread or process for every concurrent connection. Under thousands of connections, this causes severe memory exhaustion (2MB–8MB stack per thread) and constant CPU context-switching thrashing.
* **NGINX’s Solution:** A single master process with a small pool of single-threaded worker processes.
* **The Asynchronous Event Loop:** Workers use non-blocking I/O multiplexers (`epoll` on Linux, `kqueue` on macOS/BSD; one or the other per OS, not both). Idle connections consume zero CPU cycles and only a few kilobytes of socket buffer RAM. A single worker can handle 50,000+ concurrent idle connections once `worker_connections` (default 512) and the open-file limit are raised.

```
                  ┌──────────────────────────────────────────────┐
                  │          Master Process (Root)               │
                  │  - Reads & validates configuration           │
                  │  - Binds low-numbered ports (80, 443)        │
                  │  - Manages worker lifecycle & signals        │
                  └──────────────┬───────────────────────────────┘
                                 │ forks & monitors
                 ┌───────────────┴───────────────┐
                 ▼                               ▼
  ┌─────────────────────────────┐ ┌─────────────────────────────┐
  │ Worker Process 1 (nginx)    │ │ Worker Process 2 (nginx)    │
  │ - epoll non-blocking loop   │ │ - epoll non-blocking loop   │
  │ - zero-copy sendfile        │ │ - zero-copy sendfile        │
  │ - handles client traffic    │ │ - handles client traffic    │
  └─────────────────────────────┘ └─────────────────────────────┘
```

### 1.2 Privilege Separation: Why Master Runs as Root
* The **master process** requires elevated root privileges solely to:
  1. Read restricted configuration files (like private SSL keys).
  2. Bind privileged network ports (< 1024, such as 80 and 443).
  3. Open root-owned log files.
* Once sockets are bound, the master forks unprivileged **worker processes** that drop privileges to the `nginx` or `nobody` system user.
* This only happens when the master itself starts as root. Started as a normal user, NGINX ignores the `user` directive and the workers run as that same user.
* If an attacker exploits an HTTP parsing vulnerability, their shell access is strictly confined to the unprivileged worker user and cannot tamper with system binaries, read `/etc/shadow`, or bind new network services.
* If a worker crashes, the master logs it and forks a replacement. Only that worker's connections are lost.

### 1.3 Unix Signal Architecture
In production, you never "restart" NGINX—you signal it. Signals always go to a master process; the master manages its workers.
| Command | Equivalent Unix Signal | Target | Action Taken |
| :--- | :--- | :--- | :--- |
| `nginx -s reload` | `kill -HUP <master_pid>` | Master | Validates config; spawns new workers; gracefully retires old workers |
| `nginx -s quit` | `kill -QUIT <master_pid>` | Master | Graceful shutdown: finishes in-flight requests, then terminates |
| `nginx -s stop` | `kill -TERM <master_pid>` | Master | Abrupt shutdown: immediately terminates connections and exits |
| `nginx -s reopen` | `kill -USR1 <master_pid>` | Master | Reopens all log files (used by `logrotate`) |
| *(Binary Upgrade)* | `kill -USR2 <master_pid>` | Master | Renames PID file to `nginx.pid.oldbin`, starts a new master from the new binary |
| *(Retire Old Workers)* | `kill -WINCH <old_master_pid>` | Old Master | Gracefully stops old workers, keeps old master on standby for rollback |
| *(Roll Back)* | `kill -HUP <old_master_pid>` | Old Master | Respawns old workers on the old binary (then `QUIT` the new master) |

*Safety net:* If the new configuration fails validation on `HUP`, the master logs the error and the old workers keep serving the old configuration.

*`nginx -s` gotcha:* `nginx -s <signal>` starts a new `nginx` process that reads a config to find the PID file. It must use the same `-p`/`-c` as the running instance, or it signals the wrong master (or fails with `invalid PID number`).

---

## 2. Lab Prerequisites (One-Time Setup)

The lab runs natively on the Ubuntu lab box, using NGINX mainline from the nginx.org repository (which includes the `nginx-debug` binary used in Activity 1.4). Port plan: 8080 is reserved for the learning dashboard, so Sprint 1 labs listen on **8081**.

1. Install NGINX from the nginx.org mainline repo (see [nginx.org Linux packages](https://nginx.org/en/linux_packages.html)), then disable the packaged service so it never claims port 80:
   ```bash
   sudo systemctl disable --now nginx
   ls -l /usr/sbin/nginx /usr/sbin/nginx-debug
   ```
2. Install trace tools:
   ```bash
   sudo apt install strace sysstat tcpdump lsof
   ```
3. Clone the repo to `/srv` (Ubuntu home directories are mode 750, so the `nginx` worker user can't read files there):
   ```bash
   sudo mkdir -p /srv/nginx-journey && sudo chown $USER: /srv/nginx-journey
   git clone https://github.com/f5-rahm/NGINX-Learning-Journey.git /srv/nginx-journey
   cd /srv/nginx-journey/sprints/sprint-1 && mkdir -p lab/{html,logs,temp,cache}
   echo '<h1>Sprint 1 lab</h1>' > lab/html/index.html
   ```
4. Create `lab/nginx.conf`:
   ```nginx
   user  nginx;                 # nginx.org packages create this user (Ubuntu's package uses www-data)
   worker_processes  2;         # explicit, easier to watch than auto
   pid   logs/nginx.pid;        # relative paths resolve against -p
   error_log  logs/error.log notice;

   events { worker_connections 1024; }

   http {
       include       /etc/nginx/mime.types;
       default_type  text/plain;
       access_log    logs/access.log;

       # compiled-in temp paths point at /var/cache/nginx; keep them in the lab
       client_body_temp_path temp/client;
       proxy_temp_path       temp/proxy;
       fastcgi_temp_path     temp/fastcgi;
       uwsgi_temp_path       temp/uwsgi;
       scgi_temp_path        temp/scgi;

       server {
           listen 8081;
           add_header X-Worker-PID $pid always;

           location = /healthz { return 200 "ok\n"; }
           location / { root html; }
       }
   }
   ```
5. Add the `ngx` helper to `~/.bashrc` so every command targets the current lab directory's instance. Run the lab as root (`sudo -i`), or put `sudo` in front of the function body:
   ```bash
   ngx() { /usr/sbin/nginx -p "$PWD" -c "$PWD/nginx.conf" -e logs/error.log "$@"; }
   ```
   * The absolute binary path matters: `USR2` re-executes the path the master was started with.
   * `-e` keeps startup errors in the lab instead of `/var/log/nginx`.

All activities below run from `/srv/nginx-journey/sprints/sprint-1/lab`.

---

## 3. Hands-on Guided Discovery Activities (40 Minutes)

### Activity 1.1: Binary Inspection & Syntax Verification (8 min)
1. Inspect compiled-in modules, compiler flags, and file paths:
   ```bash
   nginx -V
   ```
   *Notice:* Look for `--prefix`, `--conf-path`, `--user=nginx`, and modules like `--with-http_ssl_module`.
2. Compare the debug build shipped in the same package:
   ```bash
   /usr/sbin/nginx -V 2>&1 | grep -o -- '--with-debug'        # prints nothing
   /usr/sbin/nginx-debug -V 2>&1 | grep -o -- '--with-debug'  # prints --with-debug
   ```
3. Test configuration syntax:
   ```bash
   ngx -t
   ```
4. Test syntax and dump the entire merged configuration tree to stdout:
   ```bash
   ngx -T | less
   ```
   *Pro-Tip:* In production with dozens of included files in `conf.d/`, `nginx -T` lets you search the exact merged runtime state without guessing which file took precedence.

---

### Activity 1.2: Process Inspection & Socket Handover (10 min)
1. Start the lab instance (as root, so workers can drop privileges):
   ```bash
   ngx
   curl -sI localhost:8081/ | grep -i x-worker-pid
   ```
2. Inspect the process tree:
   ```bash
   ps -o pid,ppid,user,etime,cmd -C nginx --forest
   ```
   *Notice:*
   - Exactly one **master process** running as root.
   - Worker processes running as the unprivileged `nginx` user, children of the master.
3. Check open listening sockets:
   ```bash
   sudo ss -tlnp | grep 8081      # users:(("nginx",...)) shows the process name, not the account
   sudo lsof -nP -i :8081         # real USER column; -nP shows port numbers instead of /etc/services names
   ```
   *Notice:* Every NGINX process holds the same file descriptor with the same DEVICE/NODE: one listening socket, opened by the master and inherited by the workers through fork. The `511` on the `ss` LISTEN line is NGINX's default listen backlog on Linux.
4. *Optional extension:*
   ```bash
   sudo strace -p $(cat logs/nginx.pid)                    # master idles in rt_sigsuspend; Ctrl-C to exit
   sudo ls -l /proc/$(cat logs/nginx.pid)/fd               # master: listeners and logs
   sudo ls -l /proc/<worker_pid>/fd                        # worker: same, plus anon_inode:[eventpoll]
   sudo kill -9 <worker_pid>; ps -o pid,ppid,cmd -C nginx  # master respawns the worker
   tail -n 5 logs/error.log                                # "worker process ... exited on signal 9"
   ```

---

### Activity 1.3: Live Traffic & Zero-Downtime Reload (8 min)
1. In Terminal 1, initiate a continuous client polling loop:
   ```bash
   while true; do curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8081/healthz; sleep 0.1; done
   ```
2. In Terminal 2, note the master and worker PIDs and uptimes:
   ```bash
   ps -o pid,ppid,etime,cmd -C nginx --forest
   ```
3. Trigger a live configuration reload:
   ```bash
   ngx -s reload            # equivalent: kill -HUP $(cat logs/nginx.pid)
   ```
4. Observe the PIDs again and check the master's log:
   ```bash
   ps -o pid,ppid,etime,cmd -C nginx --forest
   tail -n 5 logs/error.log
   ```
   *Observation:* The master PID and uptime are unchanged, but the worker PIDs changed and their uptimes reset. The error log shows `signal 1 (SIGHUP) received ... reconfiguring`. The continuous curl loop in Terminal 1 did not experience a single dropped connection or non-200 status code.

---

### Activity 1.4: Zero-Downtime Binary Upgrade (core OSS) (14 min)
*Reference: `NGINX Full Training.pptx` Slides 10–13. This is core open source NGINX functionality, not an enterprise feature.*

The nginx.org package ships a second binary, `nginx-debug`; use it as the "new" version so the upgrade has a visible result.

1. Keep the Activity 1.3 polling loop running.
2. Back up and replace the binary on disk (`cp` over a running binary fails with "Text file busy"; `install` replaces it safely):
   ```bash
   sudo cp /usr/sbin/nginx /usr/sbin/nginx.orig
   sudo install -m 755 /usr/sbin/nginx-debug /usr/sbin/nginx
   ```
3. Send `USR2` to the running master:
   ```bash
   kill -USR2 $(cat logs/nginx.pid)
   ps -o pid,ppid,etime,cmd -C nginx --forest
   ```
   *What happens:* The old master renames its PID file to `logs/nginx.pid.oldbin` and executes the new binary. The new master inherits the existing listening sockets and forks new workers. You will see two masters and two sets of workers serving traffic concurrently.
4. Retire the old workers but keep the old master as a rollback point:
   ```bash
   kill -WINCH $(cat logs/nginx.pid.oldbin)
   ```
5. Verify the swap:
   ```bash
   ls -l /proc/$(cat logs/nginx.pid.oldbin)/exe                       # old master's binary shows (deleted)
   /proc/$(cat logs/nginx.pid)/exe -V 2>&1 | grep -o -- '--with-debug' # new master is the debug build
   ```
6. Practice the rollback, then repeat steps 3 and 4:
   ```bash
   kill -HUP $(cat logs/nginx.pid.oldbin)   # old master respawns its workers
   kill -QUIT $(cat logs/nginx.pid)         # retire the new master
   ```
7. Commit the upgrade by retiring the old master:
   ```bash
   kill -QUIT $(cat logs/nginx.pid.oldbin)
   ```
8. Restore the regular binary on disk (any `apt upgrade` of nginx would overwrite it anyway):
   ```bash
   sudo install -m 755 /usr/sbin/nginx.orig /usr/sbin/nginx
   ```
   The polling loop should print only 200s throughout. The upgrade is complete with 0 dropped connections.

---

## 4. Day 1 Concept Examination (10-Question Randomized Quiz)

To verify today's learning, launch the **Day 1 Concept Quiz**:
* Samples **10 random questions** from our 20-question Day 1 pool.
* Passing score: **80% (8 of 10)**.

👉 **[Launch Day 1 Concept Examination (`day01_quiz.html`)](day01_quiz.html)**

---

## 5. Key Takeaways for Day 1
* **Never kill NGINX abruptly in production:** Use `SIGHUP` for config updates, `SIGQUIT` for graceful shutdowns, and `SIGUSR1` for log rotation.
* **Signal the right master:** `nginx -s` must use the same `-p`/`-c` as the running instance; otherwise use `kill` with the correct PID file.
* **Binary upgrades are core OSS:** `USR2`, then `WINCH`, verify, then `QUIT` the old master, or roll back with `HUP`.
* **Worker count:** Set `worker_processes auto;` (1 worker per CPU core) to prevent context-switching thrashing. The compiled-in default is 1; packaged configs set `auto`.
* **Syntax debugging:** Always run `nginx -t` before reloading, and `nginx -T` when troubleshooting complex multi-file configurations.

# Sprint 1 &bull; Day 1: Architecture, Process Lifecycle & Signals
**Estimated Time:** 45–60 Minutes of Guided Hands-on Discovery  
**Theme:** Master the execution engine, process hierarchy, and Unix signals before writing web server configs.

---

## 1. Concepts to Understand (15 Minutes)

### 1.1 The C10K Problem & Event-Driven I/O
Traditional web servers (like Apache MPM prefork) spawn a dedicated OS thread or process for every concurrent connection. Under thousands of connections, this causes severe memory exhaustion (2MB–8MB stack per thread) and constant CPU context-switching thrashing.
* **NGINX’s Solution:** A single master process with a small pool of single-threaded worker processes.
* **The Asynchronous Event Loop:** Workers use non-blocking I/O multiplexers (`epoll` on Linux, `kqueue` on macOS/BSD). Idle connections consume zero CPU cycles and only a few kilobytes of socket buffer RAM. A single worker can handle 50,000+ concurrent idle connections.

```
                  ┌──────────────────────────────────────────────┐
                  │          Master Process (Root)               │
                  │  - Reads & validates configuration          │
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
* If an attacker exploits an HTTP parsing vulnerability, their shell access is strictly confined to the unprivileged worker user and cannot tamper with system binaries, read `/etc/shadow`, or bind new network services.

### 1.3 Unix Signal Architecture
In production, you never "restart" NGINX—you signal it:
| Command | Equivalent Unix Signal | Target | Action Taken |
| :--- | :--- | :--- | :--- |
| `nginx -s reload` | `kill -HUP <master_pid>` | Master | Validates config; spawns new workers; gracefully retires old workers |
| `nginx -s quit` | `kill -QUIT <master_pid>` | Master / Worker | Graceful shutdown: finishes in-flight requests, then terminates |
| `nginx -s stop` | `kill -TERM <master_pid>` | Master / Worker | Abrupt shutdown: immediately terminates connections and exits |
| `nginx -s reopen` | `kill -USR1 <master_pid>` | Master | Reopens all log files (used by `logrotate`) |
| *(Hot Upgrade)* | `kill -USR2 <master_pid>` | Master | Renames PID to `oldbin`, spawns new master with new binary |
| *(Retire Old)* | `kill -WINCH <master_pid>` | Old Master | Gracefully stops old workers, keeps old master on standby |

---

## 2. Hands-on Guided Discovery Activities (30 Minutes)

### Activity 1.1: Binary Inspection & Syntax Verification (8 min)
1. Inspect compiled-in modules, compiler flags, and file paths:
   ```bash
   nginx -V
   ```
   *Notice:* Look for `--prefix`, `--conf-path`, `--user=nginx`, and modules like `--with-http_ssl_module`.
2. Test configuration syntax:
   ```bash
   nginx -t
   ```
3. Test syntax and dump the entire merged configuration tree to stdout:
   ```bash
   nginx -T | less
   ```
   *Pro-Tip:* In production with dozens of included files in `conf.d/`, `nginx -T` lets you search the exact merged runtime state without guessing which file took precedence.

---

### Activity 1.2: Process Inspection & Socket Handover (7 min)
1. Start an NGINX instance with our minimal test configuration:
   ```bash
   nginx -c $PWD/solution_nginx.conf -p $PWD -g "daemon off;" &
   ```
2. In a second terminal, inspect the process tree:
   ```bash
   ps aux | grep nginx
   ```
   *Notice:*
   - Exactly one **master process** running under your user/root.
   - Worker processes running as unprivileged workers.
3. Check open listening sockets:
   ```bash
   # On macOS:
   lsof -i :8080
   # On Linux:
   ss -tulpn | grep 8080
   ```
   *Notice:* The listening socket was opened by the master and inherited by the workers.

---

### Activity 1.3: Live Traffic & Zero-Downtime Reload (8 min)
1. In Terminal 1, initiate a continuous client polling loop:
   ```bash
   while true; do curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/healthz; sleep 0.1; done
   ```
2. In Terminal 2, note the PID of the worker process:
   ```bash
   ps -ef | grep "nginx: worker"
   ```
3. Trigger a live configuration reload:
   ```bash
   kill -HUP $(cat lab/logs/nginx.pid)
   ```
4. Observe the worker PIDs again:
   *Observation:* The master PID remained unchanged, but the worker PID changed! The continuous curl loop in Terminal 1 did not experience a single dropped connection or non-200 status code.

---

### Activity 1.4: Enterprise Hot-Swap — Zero-Downtime Binary Upgrade (7 min)
*Reference: `NGINX Full Training.pptx` Slides 10–13*
When upgrading the NGINX executable binary itself without dropping active client connections:
1. Replace the binary on disk (`cp /new/nginx /usr/sbin/nginx`).
2. Send `SIGUSR2` to the running master:
   ```bash
   kill -s SIGUSR2 <old_master_pid>
   ```
   *What happens:* The old master renames its PID file to `nginx.pid.oldbin` and executes the new binary. The new master starts, binds to the existing socket descriptors, and forks new worker processes.
3. Check running processes: You will see two master processes and two sets of workers running concurrently!
4. Finalize the upgrade: Send `SIGQUIT` to the old master:
   ```bash
   kill -s SIGQUIT <old_master_pid>
   ```
   The old master gracefully terminates its old workers and exits. The upgrade is complete with 0 dropped sockets.

---

## 3. Day 1 Concept Examination (10-Question Randomized Quiz)

To verify today's learning, launch the **Day 1 Concept Quiz**:
* Samples **10 random questions** from our 20-question Day 1 pool.
* Passing score: **80% (8 of 10)**.

👉 **[Launch Day 1 Concept Examination (`day01_quiz.html`)](day01_quiz.html)**

---

## 4. Key Takeaways for Day 1
* **Never kill NGINX abruptly in production:** Use `SIGHUP` for config updates, `SIGQUIT` for graceful shutdowns, and `SIGUSR1` for log rotation.
* **Worker count:** Default to `worker_processes auto;` (1 worker per CPU core) to prevent context-switching thrashing.
* **Syntax debugging:** Always run `nginx -t` before reloading, and `nginx -T` when troubleshooting complex multi-file configurations.

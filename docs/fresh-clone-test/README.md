# Fresh-Clone Test

Checks that someone with a clean Ubuntu box can follow the README's [Getting Started](../../README.md#getting-started), clone the repo, and run every sprint lab. Rerun it after moving to a new lab box, or after changing Getting Started or a lab's setup.

## What It Does

[`run.sh`](run.sh) starts one privileged Ubuntu container with its own Docker daemon, so nothing on the machine running it changes: no lab ports, no lab containers, no host NGINX. Inside it:

1. **Runs the README's One-Time Setup block**, extracted from the README itself, so the test can't drift from the documented steps. There are only two container changes, both because the container has no systemd. `systemctl disable --now nginx` loses `--now`, and `dockerd` is started by hand before `docker run --rm hello-world`.
2. **Clones the repo from GitHub** to `/srv/nginx-journey`, so it tests what's pushed, not your working tree.
3. **Runs [`sprints.sh`](sprints.sh) for each sprint.** It sets up the lab the way that sprint's guide does, then runs the sprint's test twice:
   * **Starter:** the config loads (except Sprint 3; see below) and the gate checks are open.
   * **Solution:** the gate passes.

```bash
docs/fresh-clone-test/run.sh                 # ubuntu:24.04
docs/fresh-clone-test/run.sh ubuntu:22.04    # or any Ubuntu image
```

It takes about 10 minutes. Full logs go to `./fresh-clone-results-<timestamp>/`.

**It doesn't cover:**
* **The NGINX Plus side quests.** They need a license, which never goes into a test container.
* **The day-guide activities.** Only each sprint's lab setup and test run.
* **The quiz page.**

## Results

**Run:** 2026-11-06, `ubuntu:24.04` (24.04.5 LTS), NGINX 1.31.8 from nginx.org mainline, Docker Engine 29 from `get.docker.com`, repo at `9ae484f`.

| Sprint | Starter | Solution |
| :--- | :--- | :--- |
| 1 | Loads; 4/12 core (the parts NGINX does by default) | **12/12**, stretch 3/3 |
| 2 | Loads; 0/8 | **8/8**, stretch 2/2 |
| 3 | Doesn't load (no certificate configured yet, by design of that starter) | **13/13** |
| 4 | Loads; ready banner, 0/10 | **10/10** |
| 5 | Loads; ready banner, 0/13 | **13/13** |
| 6 | Loads; ready banner, 0/10 | **10/10** |

## What the Test Found

* **Missing from the docs:** `iproute2` (`ss`, `nstat`) and `procps` (`ps`, `sysctl`). Sprint 4's test reads the accept queue with `ss`, and failed on the minimal image without it. Most Ubuntu installs already have both, but they're now listed in Getting Started.
* **Docker wasn't documented anywhere** before Getting Started, though Sprint 3's HTTP/3 checks and every lab from Sprint 4 on need it.
* **The Sprint 3 starter doesn't load until certificates are configured.** That sprint was written before the convention that a bare starter loads. Its test says NGINX isn't answering HTTPS and stops, which is correct for that starter.
* **A test-harness quirk, not a lab issue.** Docker inside a container on cgroup v2 can't apply `--memory` limits, which Sprint 3's HTTP/3 curl container uses, until the nested cgroups are set up. `run.sh` does that setup the way the official `docker:dind` image does. On a real lab box, Docker runs on the host and this doesn't come up.

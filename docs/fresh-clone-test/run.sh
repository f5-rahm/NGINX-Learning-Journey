#!/usr/bin/env bash
# Fresh-clone test: does the README's Getting Started, followed on a clean Ubuntu,
# give a box where every sprint lab works?
#
# Usage:   docs/fresh-clone-test/run.sh [ubuntu-image]     (default ubuntu:24.04)
# Needs:   Docker on the machine running it. Run as root (or a docker-group user).
# Results: a summary on stdout; full logs in ./fresh-clone-results-<timestamp>/
#
# Everything happens inside one privileged container with its own network namespace
# and its own Docker daemon, so the labs, ports and containers on this machine are
# never touched. The container clones the repo from GitHub, so it tests what's pushed;
# the setup steps come from the README in this checkout.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
README="$HERE/../../README.md"
IMAGE="${1:-ubuntu:24.04}"
NAME=fresh-clone-test
OUT="$PWD/fresh-clone-results-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

# The README's One-Time Setup block, verbatim
awk '/^### One-Time Setup/{s=1} s&&/^```bash/{p=1;next} p&&/^```/{exit} p' "$README" > "$OUT/setup_from_readme.sh"
[ -s "$OUT/setup_from_readme.sh" ] || { echo "no One-Time Setup block found in $README"; exit 1; }

# Two container-only changes, because the container has no systemd:
#  * the packaged nginx service can't be disabled with --now (nothing is running anyway)
#  * dockerd is started by hand before the hello-world check
sed -e 's|^systemctl disable --now nginx .*|systemctl disable nginx 2>/dev/null; true   # container: no systemd|' \
    -e 's|^docker run --rm hello-world|(dockerd >/var/log/dockerd.log 2>\&1 \&); for i in $(seq 60); do docker info >/dev/null 2>\&1 \&\& break; sleep 1; done\ndocker run --rm hello-world|' \
    "$OUT/setup_from_readme.sh" > "$OUT/setup.sh"
echo "== Setup steps used (diff from the README):"
diff "$OUT/setup_from_readme.sh" "$OUT/setup.sh" || true

docker rm -fv "$NAME" >/dev/null 2>&1 || true
echo "== Running in $IMAGE (takes about 10 minutes)"
docker run --name "$NAME" --privileged --hostname "$NAME" \
  --mount type=volume,dst=/var/lib/docker \
  -v "$OUT/setup.sh:/setup.sh:ro" -v "$HERE/sprints.sh:/sprints.sh:ro" -v "$OUT:/results" \
  "$IMAGE" bash -c '
    export DEBIAN_FRONTEND=noninteractive
    # Nested Docker on cgroup v2 (what docker:dind does): move this shell out of the
    # root cgroup and enable the controllers, so containers can have --memory limits
    if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
        mkdir -p /sys/fs/cgroup/init
        xargs -rn1 < /sys/fs/cgroup/cgroup.procs > /sys/fs/cgroup/init/cgroup.procs 2>/dev/null || true
        sed -e "s/ / +/g" -e "s/^/+/" < /sys/fs/cgroup/cgroup.controllers > /sys/fs/cgroup/cgroup.subtree_control
    fi
    grep PRETTY_NAME /etc/os-release
    bash -ex /setup.sh > /results/setup.log 2>&1 || { echo "SETUP FAILED"; tail -15 /results/setup.log; exit 1; }
    echo "setup OK: $(nginx -v 2>&1), $(docker --version)"
    bash /sprints.sh' 2>&1 | tee "$OUT/summary.log" | grep -E "PRETTY|setup|SETUP|####|passed|PASSED|ready to go|SUCCESS|INCOMPLETE|not yet|exit [1-9]"
docker rm -fv "$NAME" >/dev/null
echo "== Logs: $OUT"

#!/usr/bin/env bash
# Sprint 4 lab: the Lumina edge (nginx:mainline) and a slow, countable origin, in containers.
#
#   ./lab.sh up                  # network + origin + edge (uses ./nginx.conf), then the ready check
#   ./lab.sh check               # ready check: config loads, edge and origin answer, edge reaches origin
#   ./lab.sh reload              # nginx -t, then reload, inside the edge container
#   ./lab.sh t | T               # nginx -t / nginx -T inside the edge container
#   ./lab.sh edge                # recreate only the edge (picks up SOMAXCONN / NOFILE, see below)
#   ./lab.sh down                # remove both containers and the network
#
#   ./lab.sh stats               # the origin's counters: requests per URI, 304s, TCP connections
#   ./lab.sh reset               # zero the origin's counters
#   ./lab.sh mode status=503     # every origin answer is now a 503 (also delay=3); "./lab.sh mode" = normal
#   ./lab.sh load [oha args] /path   # oha load test from inside the lab network, aimed at the edge
#   ./lab.sh ss [args]           # ss inside the edge's network namespace (default: -lnt)
#   ./lab.sh nstat [args]        # nstat inside the edge's network namespace
#   ./lab.sh workers             # host PIDs of the edge's master and workers
#   ./lab.sh logs [edge|origin]  # follow container output
#
# Environment for "up" and "edge":
#   SOMAXCONN=128   the edge's net.core.somaxconn (container default: 4096)
#   NOFILE=1024     the edge's open-files limit, soft:hard or one number (Docker default 1024:524288)
set -u

LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET=s4-net
EDGE=s4-edge
ORIGIN=s4-origin
EDGE_PORT=8084
ORIGIN_PORT=8014
NGINX_IMAGE="${NGINX_IMAGE:-nginx:mainline}"
PY_IMAGE="${PY_IMAGE:-python:3.12-alpine}"
OHA_IMAGE="${OHA_IMAGE:-ghcr.io/hatoo/oha:1.14.0}"
NGX=(nginx -p /lab/ -c nginx.conf -e logs/error.log)

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}[ok]${NC} $*"; }
bad()  { echo -e "  ${RED}[!!]${NC} $*"; }

running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }
edge_pid() { docker inspect -f '{{.State.Pid}}' "$EDGE"; }

net_up() { docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null; }

origin_up() {
    running "$ORIGIN" && return 0
    docker rm -f "$ORIGIN" >/dev/null 2>&1
    docker run -d --name "$ORIGIN" --network "$NET" -p "127.0.0.1:$ORIGIN_PORT:$ORIGIN_PORT" \
        -v "$LAB/origin.py:/origin.py:ro" "$PY_IMAGE" python3 -u /origin.py --port "$ORIGIN_PORT" >/dev/null
}

edge_up() {
    [ -f "$LAB/nginx.conf" ] || { bad "no nginx.conf in $LAB: copy a dayN_nginx.conf or starter_nginx.conf first"; return 1; }
    mkdir -p "$LAB"/{logs,cache} "$LAB"/temp/{client,proxy,fastcgi,uwsgi,scgi}
    local opts=()
    [ -n "${SOMAXCONN:-}" ] && opts+=(--sysctl "net.core.somaxconn=$SOMAXCONN")
    if [ -n "${NOFILE:-}" ]; then
        [[ "$NOFILE" == *:* ]] && opts+=(--ulimit "nofile=$NOFILE") || opts+=(--ulimit "nofile=$NOFILE:$NOFILE")
    fi
    docker rm -f "$EDGE" >/dev/null 2>&1
    # The whole lab directory is mounted, so edits to nginx.conf are seen by a reload (no single-file inode trap)
    docker run -d --name "$EDGE" --network "$NET" -p "$EDGE_PORT:$EDGE_PORT" "${opts[@]}" \
        -v "$LAB:/lab" "$NGINX_IMAGE" "${NGX[@]}" -g 'daemon off;' >/dev/null
    sleep 0.5
    running "$EDGE" || { bad "the edge exited at start:"; docker logs "$EDGE" 2>&1 | tail -5; return 1; }
}

wait_port() {
    for _ in $(seq 30); do
        curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$1/_stats" && return 0
        sleep 0.2
    done
    return 1
}

# Ready check. Exit 0 only if the lab is usable: this is also the test script's preflight.
check() {
    local fail=0 out
    if running "$ORIGIN" && wait_port "$ORIGIN_PORT"; then ok "origin answers on 127.0.0.1:$ORIGIN_PORT"
    else bad "origin is not answering (./lab.sh up)"; fail=1; fi
    if ! running "$EDGE"; then
        bad "edge container is not running (./lab.sh up)"; return 1
    fi
    if out=$(docker exec "$EDGE" "${NGX[@]}" -t 2>&1); then ok "nginx.conf passes nginx -t ($(docker exec "$EDGE" nginx -v 2>&1 | cut -d/ -f2))"
    else bad "nginx -t fails:"; echo "$out" | sed 's/^/       /'; fail=1; fi
    if curl -s --max-time 3 "http://127.0.0.1:$EDGE_PORT/_stats" | grep -q '"by_uri"'; then
        ok "edge answers on :$EDGE_PORT and reaches the origin"
    else bad "edge on :$EDGE_PORT does not proxy to the origin (curl -i http://127.0.0.1:$EDGE_PORT/_stats)"; fail=1; fi
    if [ "$fail" = 0 ]; then
        echo -e "${GREEN}Sprint 4 lab ready${NC}: edge :$EDGE_PORT -> $ORIGIN:$ORIGIN_PORT"
    else
        echo -e "${RED}Sprint 4 lab NOT ready${NC}: fix the items marked [!!]"
    fi
    return "$fail"
}

cmd="${1:-}"; shift || true
case "$cmd" in
    up)      net_up && origin_up && edge_up && check ;;
    edge)    net_up && edge_up && check ;;
    check)   check ;;
    down)    docker rm -f "$EDGE" "$ORIGIN" >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1; echo "Sprint 4 lab removed" ;;
    reload)  docker exec "$EDGE" "${NGX[@]}" -t && docker exec "$EDGE" "${NGX[@]}" -s reload && echo "reloaded" ;;
    t)       docker exec "$EDGE" "${NGX[@]}" -t ;;
    T)       docker exec "$EDGE" "${NGX[@]}" -T ;;
    stats)   curl -s "http://127.0.0.1:$ORIGIN_PORT/_stats" ;;
    reset)   curl -s "http://127.0.0.1:$ORIGIN_PORT/_stats/reset" >/dev/null && echo "origin counters reset" ;;
    mode)    q=$(IFS='&'; echo "$*"); curl -s "http://127.0.0.1:$ORIGIN_PORT/_mode?$q" ;;
    load)    args=("$@"); last=$((${#args[@]} - 1))
             [ "$last" -ge 0 ] && [[ "${args[$last]}" == /* ]] && args[$last]="http://$EDGE:$EDGE_PORT${args[$last]}"
             docker run --rm --network "$NET" "$OHA_IMAGE" --no-tui "${args[@]}" ;;
    ss)      [ $# -eq 0 ] && set -- -lnt; nsenter -t "$(edge_pid)" -n ss "$@" ;;
    nstat)   nsenter -t "$(edge_pid)" -n nstat "$@" ;;
    workers) ps -o pid,user,args --ppid "$(edge_pid)" --pid "$(edge_pid)" ;;
    logs)    docker logs -f "$([ "${1:-edge}" = origin ] && echo "$ORIGIN" || echo "$EDGE")" ;;
    *)       sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac

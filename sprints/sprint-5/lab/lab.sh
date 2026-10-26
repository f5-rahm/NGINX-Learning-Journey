#!/usr/bin/env bash
# Sprint 5 lab: the Lumina API gateway (nginx:mainline), the API behind it, and a client
# container that can send from any address in the lab network.
#
#   ./lab.sh up                  # network + origin + client + gateway (uses ./nginx.conf), then the ready check
#   ./lab.sh check               # ready check: config loads, gateway and origin answer, gateway reaches origin
#   ./lab.sh reload              # nginx -t, then reload, inside the gateway container
#   ./lab.sh t | T               # nginx -t / nginx -T inside the gateway container
#   ./lab.sh edge                # recreate only the gateway
#   ./lab.sh down                # remove the containers and the network
#
#   ./lab.sh stats               # the origin's counters: requests per URI, in flight, most in flight at once
#   ./lab.sh reset               # zero the origin's counters
#   ./lab.sh client              # a shell in the client container
#   ./lab.sh logs [edge|origin]  # follow container output
#
# The network (s5-net, 10.55.0.0/16):
#   10.55.0.10  s5-edge    the gateway, :8095 (published on the host as :8095)
#   10.55.0.20  s5-origin  the API, :8015 (published on the host as 127.0.0.1:8015)
#   10.55.0.2   s5-client  sends from any 10.55.x.y address you name (helpers.sh: --from)
set -u

LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET=s5-net
SUBNET=10.55.0.0/16
EDGE=s5-edge
ORIGIN=s5-origin
CLIENT=s5-client
EDGE_IP=10.55.0.10
ORIGIN_IP=10.55.0.20
CLIENT_IP=10.55.0.2
EDGE_PORT=8095
ORIGIN_PORT=8015
NGINX_IMAGE="${NGINX_IMAGE:-nginx:mainline}"
PY_IMAGE="${PY_IMAGE:-python:3.12-alpine}"
CLIENT_IMAGE=s5-client:local
NGX=(nginx -p /lab/ -c nginx.conf -e logs/error.log)

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}[ok]${NC} $*"; }
bad()  { echo -e "  ${RED}[!!]${NC} $*"; }

running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }

net_up() {
    docker network inspect "$NET" >/dev/null 2>&1 || docker network create --subnet "$SUBNET" "$NET" >/dev/null
}

origin_up() {
    running "$ORIGIN" && return 0
    docker rm -f "$ORIGIN" >/dev/null 2>&1
    docker run -d --name "$ORIGIN" --network "$NET" --ip "$ORIGIN_IP" -p "127.0.0.1:$ORIGIN_PORT:$ORIGIN_PORT" \
        -v "$LAB/origin.py:/origin.py:ro" "$PY_IMAGE" python3 -u /origin.py --port "$ORIGIN_PORT" >/dev/null
}

client_up() {
    running "$CLIENT" && return 0
    if ! docker image inspect "$CLIENT_IMAGE" >/dev/null 2>&1; then
        echo "building $CLIENT_IMAGE (python + curl, once)"
        printf 'FROM %s\nRUN apk add --no-cache curl\n' "$PY_IMAGE" | docker build -q -t "$CLIENT_IMAGE" - >/dev/null || return 1
    fi
    docker rm -f "$CLIENT" >/dev/null 2>&1
    # NET_ADMIN lets client.py add the source addresses it is asked to send from
    docker run -d --name "$CLIENT" --network "$NET" --ip "$CLIENT_IP" --cap-add NET_ADMIN \
        --ulimit nofile=65536:65536 -e EDGE="$EDGE_IP:$EDGE_PORT" -v "$LAB:/lab:ro" "$CLIENT_IMAGE" sleep infinity >/dev/null
}

edge_up() {
    [ -f "$LAB/nginx.conf" ] || { bad "no nginx.conf in $LAB: copy a dayN_nginx.conf or starter_nginx.conf first"; return 1; }
    mkdir -p "$LAB/logs" "$LAB"/temp/{client,proxy,fastcgi,uwsgi,scgi}
    docker rm -f "$EDGE" >/dev/null 2>&1
    # The whole lab directory is mounted, so edits to nginx.conf are seen by a reload (no single-file inode trap)
    docker run -d --name "$EDGE" --network "$NET" --ip "$EDGE_IP" -p "$EDGE_PORT:$EDGE_PORT" \
        -v "$LAB:/lab" "$NGINX_IMAGE" "${NGX[@]}" -g 'daemon off;' >/dev/null
    sleep 0.5
    running "$EDGE" || { bad "the gateway exited at start:"; docker logs "$EDGE" 2>&1 | tail -5; return 1; }
}

wait_origin() {
    for _ in $(seq 30); do
        curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$ORIGIN_PORT/_stats" && return 0
        sleep 0.2
    done
    return 1
}

# Ready check. Exit 0 only if the lab is usable: this is also the test script's preflight.
check() {
    local fail=0 out
    if running "$ORIGIN" && wait_origin; then ok "origin answers on 127.0.0.1:$ORIGIN_PORT"
    else bad "origin is not answering (./lab.sh up)"; fail=1; fi
    if running "$CLIENT"; then ok "client container is running"
    else bad "client container is not running (./lab.sh up)"; fail=1; fi
    if ! running "$EDGE"; then
        bad "gateway container is not running (./lab.sh up)"; return 1
    fi
    if out=$(docker exec "$EDGE" "${NGX[@]}" -t 2>&1); then ok "nginx.conf passes nginx -t ($(docker exec "$EDGE" nginx -v 2>&1 | cut -d/ -f2))"
    else bad "nginx -t fails:"; echo "$out" | sed 's/^/       /'; fail=1; fi
    if running "$CLIENT" && docker exec "$CLIENT" curl -s --max-time 3 "http://$EDGE_IP:$EDGE_PORT/_stats" | grep -q '"by_uri"'; then
        ok "gateway answers on :$EDGE_PORT and reaches the origin"
    else bad "gateway on :$EDGE_PORT does not proxy /_stats to the origin (curl -i http://127.0.0.1:$EDGE_PORT/_stats)"; fail=1; fi
    if [ "$fail" = 0 ]; then
        echo -e "${GREEN}Sprint 5 lab ready${NC}: gateway :$EDGE_PORT -> $ORIGIN:$ORIGIN_PORT, clients from $CLIENT"
    else
        echo -e "${RED}Sprint 5 lab NOT ready${NC}: fix the items marked [!!]"
    fi
    return "$fail"
}

# nginx -t can't see everything: the master can still refuse the new config (for example a shared
# memory zone redefined with a different key or size). It then logs [emerg] and keeps the old config,
# while "nginx -s reload" itself succeeds. Report that instead of "reloaded".
reload() {
    local before
    docker exec "$EDGE" "${NGX[@]}" -t || return 1
    before=$(wc -l < "$LAB/logs/error.log" 2>/dev/null || echo 0)
    docker exec "$EDGE" "${NGX[@]}" -s reload || return 1
    sleep 1
    if tail -n +"$((before + 1))" "$LAB/logs/error.log" | grep -q '\[emerg\]'; then
        bad "reload REFUSED by the master, the old configuration is still running:"
        tail -n +"$((before + 1))" "$LAB/logs/error.log" | grep '\[emerg\]' | sed 's/^/       /'
        return 1
    fi
    echo "reloaded"
}

cmd="${1:-}"; shift || true
case "$cmd" in
    up)      net_up && origin_up && client_up && edge_up && check ;;
    edge)    net_up && edge_up && check ;;
    check)   check ;;
    down)    docker rm -f "$EDGE" "$ORIGIN" "$CLIENT" >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1; echo "Sprint 5 lab removed" ;;
    reload)  reload ;;
    t)       docker exec "$EDGE" "${NGX[@]}" -t ;;
    T)       docker exec "$EDGE" "${NGX[@]}" -T ;;
    stats)   curl -s "http://127.0.0.1:$ORIGIN_PORT/_stats" ;;
    reset)   curl -s "http://127.0.0.1:$ORIGIN_PORT/_stats/reset" >/dev/null && echo "origin counters reset" ;;
    client)  docker exec -it "$CLIENT" sh ;;
    logs)    docker logs -f "$([ "${1:-edge}" = origin ] && echo "$ORIGIN" || echo "$EDGE")" ;;
    *)       awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 1 ;;
esac

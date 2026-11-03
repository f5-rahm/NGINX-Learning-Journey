#!/usr/bin/env bash
# Sprint 6 lab: the Lumina edge (nginx:mainline with njs) and the application behind it.
#
#   ./lab.sh up                  # network + origin + edge (uses ./nginx.conf), then the ready check
#   ./lab.sh check               # ready check: config loads, edge and origin answer, edge reaches origin
#   ./lab.sh reload              # nginx -t, then reload, inside the edge container
#   ./lab.sh t | T               # nginx -t / nginx -T inside the edge container
#   ./lab.sh edge                # recreate only the edge (fresh shared memory, fresh njs contexts)
#   ./lab.sh down                # remove the containers and the network
#
#   ./lab.sh njs [args]          # the njs command-line shell inside the edge image (-n QuickJS for the other engine)
#   ./lab.sh stats               # the origin's counters: requests per pool and URI, last X-User, telemetry
#   ./lab.sh reset               # zero the origin's counters
#   ./lab.sh logs [edge|origin]  # follow container output
#
# The network (s6-net, 10.56.0.0/16):
#   10.56.0.10  s6-edge    HTTP :8096 (host :8096), TCP telemetry :8097 (host :8097)
#   10.56.0.20  s6-origin  stable pool :8016 (host 127.0.0.1:8016), beta pool :8026, telemetry intake :8036
#
# The signing key lives in lab/secrets/lumina.key (created on the first up, mode 600, not in git)
# and reaches the edge as the LUMINA_KEY environment variable.
set -u

LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET=s6-net
SUBNET=10.56.0.0/16
EDGE=s6-edge
ORIGIN=s6-origin
EDGE_IP=10.56.0.10
ORIGIN_IP=10.56.0.20
EDGE_PORT=8096
TEL_PORT=8097
ORIGIN_PORT=8016
NGINX_IMAGE="${NGINX_IMAGE:-nginx:mainline}"
PY_IMAGE="${PY_IMAGE:-python:3.12-alpine}"
KEY_FILE="$LAB/secrets/lumina.key"
NGX=(nginx -p /lab/ -c nginx.conf -e logs/error.log)

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}[ok]${NC} $*"; }
bad()  { echo -e "  ${RED}[!!]${NC} $*"; }

running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }

net_up() {
    docker network inspect "$NET" >/dev/null 2>&1 || docker network create --subnet "$SUBNET" "$NET" >/dev/null
}

key_up() {
    [ -s "$KEY_FILE" ] && return 0
    mkdir -p "$LAB/secrets" && chmod 700 "$LAB/secrets"
    (umask 077; head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$KEY_FILE")
    echo "created a new signing key in secrets/lumina.key"
}

origin_up() {
    running "$ORIGIN" && return 0
    docker rm -f "$ORIGIN" >/dev/null 2>&1
    docker run -d --name "$ORIGIN" --network "$NET" --ip "$ORIGIN_IP" -p "127.0.0.1:$ORIGIN_PORT:$ORIGIN_PORT" \
        -v "$LAB/origin.py:/origin.py:ro" "$PY_IMAGE" python3 -u /origin.py >/dev/null
}

edge_up() {
    [ -f "$LAB/nginx.conf" ] || { bad "no nginx.conf in $LAB: copy a dayN_nginx.conf or starter_nginx.conf first"; return 1; }
    mkdir -p "$LAB/logs" "$LAB"/temp/{client,proxy,fastcgi,uwsgi,scgi}
    docker rm -f "$EDGE" >/dev/null 2>&1
    # The whole lab directory is mounted, so edits to nginx.conf and lumina.js are seen by a reload
    docker run -d --name "$EDGE" --network "$NET" --ip "$EDGE_IP" \
        -p "$EDGE_PORT:$EDGE_PORT" -p "$TEL_PORT:$TEL_PORT" \
        -e LUMINA_KEY="$(cat "$KEY_FILE")" -v "$LAB:/lab" "$NGINX_IMAGE" "${NGX[@]}" -g 'daemon off;' >/dev/null
    sleep 0.5
    running "$EDGE" || { bad "the edge exited at start:"; docker logs "$EDGE" 2>&1 | tail -5; return 1; }
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
    if ! running "$EDGE"; then
        bad "edge container is not running (./lab.sh up)"; return 1
    fi
    if out=$(docker exec "$EDGE" "${NGX[@]}" -t 2>&1); then
        ok "nginx.conf passes nginx -t ($(docker exec "$EDGE" nginx -v 2>&1 | cut -d/ -f2), njs $(docker exec "$EDGE" njs -v 2>/dev/null))"
    else bad "nginx -t fails:"; echo "$out" | sed 's/^/       /'; fail=1; fi
    if curl -s --max-time 3 "http://127.0.0.1:$EDGE_PORT/api/ping" | grep -q '"origin": "lumina-app"'; then
        ok "edge answers on :$EDGE_PORT and reaches the origin"
    else bad "edge on :$EDGE_PORT does not proxy /api/ping to the origin (curl -i http://127.0.0.1:$EDGE_PORT/api/ping)"; fail=1; fi
    if grep -qE '^[^#]*listen[[:space:]]+'"$TEL_PORT" "$LAB/nginx.conf"; then
        if (exec 3<>"/dev/tcp/127.0.0.1/$TEL_PORT") 2>/dev/null; then ok "telemetry port :$TEL_PORT accepts connections"
        else bad "nothing accepts connections on :$TEL_PORT"; fail=1; fi
    fi
    if [ "$fail" = 0 ]; then
        echo -e "${GREEN}Sprint 6 lab ready${NC}: edge :$EDGE_PORT -> $ORIGIN (stable :8016, beta :8026)"
    else
        echo -e "${RED}Sprint 6 lab NOT ready${NC}: fix the items marked [!!]"
    fi
    return "$fail"
}

# nginx -t can't see everything: the master can still refuse the new config (for example a shared
# memory zone redefined with a different size). It then logs [emerg] and keeps the old config,
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
    up)      key_up && net_up && origin_up && edge_up && check ;;
    edge)    key_up && net_up && edge_up && check ;;
    check)   check ;;
    down)    docker rm -f "$EDGE" "$ORIGIN" >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1; echo "Sprint 6 lab removed" ;;
    reload)  reload ;;
    t)       docker exec "$EDGE" "${NGX[@]}" -t ;;
    T)       docker exec "$EDGE" "${NGX[@]}" -T ;;
    njs)     docker run --rm -i -v "$LAB:/lab:ro" -w /lab "$NGINX_IMAGE" njs "$@" ;;
    stats)   curl -s "http://127.0.0.1:$ORIGIN_PORT/_stats" ;;
    reset)   curl -s "http://127.0.0.1:$ORIGIN_PORT/_stats/reset" >/dev/null && echo "origin counters reset" ;;
    logs)    docker logs -f "$([ "${1:-edge}" = origin ] && echo "$ORIGIN" || echo "$EDGE")" ;;
    *)       awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 1 ;;
esac

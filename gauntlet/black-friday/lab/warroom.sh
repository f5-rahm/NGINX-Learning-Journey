#!/usr/bin/env bash
# Black Friday war room: the Northwind storefront's edge tier, its load balancer, the origin,
# and the war room's own client (tickets, checks and the scoreboard).
#
#   ./warroom.sh init oss|plus [--force]   pick the edition: copy its start files to edge/ and lb/, new scoreboard
#   ./warroom.sh up                         network, origin, client, both edges, load balancer, then the ready check
#   ./warroom.sh status                     ready check
#   ./warroom.sh reload                     nginx -t, then reload both edges and the load balancer
#   ./warroom.sh t | T                      nginx -t / nginx -T in edge-a
#   ./warroom.sh restart                    recreate the edges and the load balancer (a restart, not a reload)
#   ./warroom.sh down                       remove everything (your edge/ and lb/ files stay)
#
#   ./warroom.sh next                       open the next ticket
#   ./warroom.sh check                      check the open ticket, and that solved ones still hold
#   ./warroom.sh board                      the scoreboard
#   ./warroom.sh answer VALUE               answer the open ticket's question (ticket 8)
#   ./warroom.sh skip                       give up on the open ticket (no points) and move on
#
#   ./warroom.sh shop [curl args] PATH      curl through the load balancer as a shopper (10.58.100.7)
#   ./warroom.sh ops  [curl args] URL       curl as the ops team (10.58.0.5), e.g. http://edge-a:8080/...
#   ./warroom.sh from IP [curl args] URL    curl from any 10.58.x.y address
#   ./warroom.sh token ID [TTL]             a member cookie value for member ID (the lab key, TTL seconds)
#   ./warroom.sh api edge-a|edge-b PATH [curl args]
#                                           NGINX Plus: curl a node's API as ops (http://edge-X:8085PATH)
#   ./warroom.sh prices | stats [PREFIX]    the origin's current prices / requests per URI
#   ./warroom.sh logs edge-a|edge-b|lb|origin   follow a container's error log or output
#   ./warroom.sh lua up|down                the OpenResty comparison node (ticket 8)
#   ./warroom.sh bench                      ticket 8's benchmark: njs on edge-a vs Lua on OpenResty
#
# The network (bf-net, 10.58.0.0/16):
#   10.58.0.10  bf-lb      load balancer, :8100 (published on the host as :8100)
#   10.58.0.11  bf-edge-a  edge node "edge-a", :8080   (Plus API :8085, on the host as 127.0.0.1:8085)
#   10.58.0.12  bf-edge-b  edge node "edge-b", :8080   (Plus API :8085, on the host as 127.0.0.1:8105)
#   10.58.0.20  bf-origin  the storefront, :8020 (on the host as 127.0.0.1:8020)
#   10.58.0.30  bf-lua     OpenResty, :8080 (ticket 8 only)
#   10.58.0.2   bf-client  the war room: sends from any address (ops is 10.58.0.5)
set -u

LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET=bf-net
SUBNET=10.58.0.0/16
NGINX_IMAGE="${NGINX_IMAGE:-nginx:mainline}"
PY_IMAGE="${PY_IMAGE:-python:3.12-alpine}"
LUA_IMAGE="${LUA_IMAGE:-openresty/openresty:alpine}"
OHA_IMAGE="${OHA_IMAGE:-ghcr.io/hatoo/oha:1.14.0}"
CLIENT_IMAGE=bf-client:local
HOME="${HOME:-$(getent passwd "$(id -u)" | cut -d: -f6)}"
PLUS_ENV="${PLUS_ENV:-$HOME/plus/plus.env}"
LICENSE="${LICENSE:-$HOME/plus/license.jwt}"
EDGES=(edge-a edge-b)
declare -A IP=([lb]=10.58.0.10 [edge-a]=10.58.0.11 [edge-b]=10.58.0.12 [origin]=10.58.0.20 [lua]=10.58.0.30 [client]=10.58.0.2)
declare -A API_PORT=([edge-a]=8085 [edge-b]=8105)

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}[ok]${NC} $*"; }
bad()  { echo -e "  ${RED}[!!]${NC} $*"; }

running() { [ "$(docker inspect -f '{{.State.Running}}' "bf-$1" 2>/dev/null)" = true ]; }
edition() { cat "$LAB/.edition" 2>/dev/null; }

need_edition() {
    case "$(edition)" in
        oss) ;;
        plus)
            [ -f "$PLUS_ENV" ] || { bad "no $PLUS_ENV: do the one-time NGINX Plus setup first (README)"; return 1; }
            [ -f "$LICENSE" ] || { bad "no $LICENSE: do the one-time NGINX Plus setup first (README)"; return 1; }
            # shellcheck disable=SC1090
            source "$PLUS_ENV"
            [ -n "${PLUS_IMAGE:-}" ] || { bad "PLUS_IMAGE is not set in $PLUS_ENV"; return 1; } ;;
        *)  bad "no edition chosen: ./warroom.sh init oss   (or: init plus)"; return 1 ;;
    esac
}

edge_image() { [ "$(edition)" = plus ] && echo "$PLUS_IMAGE" || echo "$NGINX_IMAGE"; }

init() {
    local ed="${1:-}" force="${2:-}"
    case "$ed" in oss|plus) ;; *) echo "usage: ./warroom.sh init oss|plus [--force]"; return 1 ;; esac
    if [ -d "$LAB/edge" ] && [ "$force" != --force ]; then
        bad "edge/ already exists ($(edition) edition). ./warroom.sh init $ed --force replaces edge/ and lb/ and starts a new scoreboard."
        return 1
    fi
    # Empty state/ rather than remove it: a running client container has it mounted
    rm -rf "$LAB/edge" "$LAB/lb" "$LAB/logs"
    mkdir -p "$LAB/edge" "$LAB/lb" "$LAB/state"
    find "$LAB/state" -mindepth 1 -delete
    cp "$LAB/start/$ed/nginx.conf" "$LAB/start/$ed/shop.js" "$LAB/edge/"
    cp "$LAB/start/$ed/lb.conf" "$LAB/lb/nginx.conf"
    echo "$ed" > "$LAB/.edition"
    ok "edition: $ed. Your files: edge/nginx.conf, edge/shop.js (both edges) and lb/nginx.conf (the load balancer)"
    echo "     Next: ./warroom.sh up"
}

net_up() {
    docker network inspect "$NET" >/dev/null 2>&1 || docker network create --subnet "$SUBNET" "$NET" >/dev/null
}

key_up() {
    if [ ! -s "$LAB/secrets/shop.key" ]; then
        mkdir -p "$LAB/secrets" && chmod 700 "$LAB/secrets"
        (umask 077; head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$LAB/secrets/shop.key")
        echo "created a new member-cookie key in secrets/shop.key"
    fi
}

origin_up() {
    running origin && return 0
    docker rm -f bf-origin >/dev/null 2>&1
    docker run -d --name bf-origin --network "$NET" --ip "${IP[origin]}" -p 127.0.0.1:8020:8020 \
        -v "$LAB/origin.py:/origin.py:ro" "$PY_IMAGE" python3 -u /origin.py --port 8020 >/dev/null
}

client_up() {
    running client && return 0
    if ! docker image inspect "$CLIENT_IMAGE" >/dev/null 2>&1; then
        echo "building $CLIENT_IMAGE (python + curl, once)"
        printf 'FROM %s\nRUN apk add --no-cache curl\n' "$PY_IMAGE" | docker build -q -t "$CLIENT_IMAGE" - >/dev/null || return 1
    fi
    docker rm -f bf-client >/dev/null 2>&1
    # NET_ADMIN: the client adds the source addresses it sends from (shoppers, bots, ops)
    docker run -d --name bf-client --network "$NET" --ip "${IP[client]}" --cap-add NET_ADMIN \
        --ulimit nofile=65536:65536 -v "$LAB:/lab:ro" -v "$LAB/state:/state" "$CLIENT_IMAGE" sleep infinity >/dev/null
    docker exec bf-client ip addr add 10.58.0.5/16 dev eth0 2>/dev/null
    return 0
}

edge_up() {
    local node="$1" extra=()
    docker rm -f "bf-$node" >/dev/null 2>&1
    mkdir -p "$LAB/logs/$node"
    if [ "$(edition)" = plus ]; then
        mkdir -p "$LAB/state/$node"
        extra=(-v "$LICENSE:/etc/nginx/license.jwt:ro" -v "$LAB/state/$node:/var/lib/nginx/state"
               -p "127.0.0.1:${API_PORT[$node]}:8085")
    fi
    docker run -d --name "bf-$node" --hostname "$node" --network "$NET" --network-alias "$node" --ip "${IP[$node]}" \
        --ulimit nofile=65536:65536 \
        -e SHOP_KEY="$(cat "$LAB/secrets/shop.key")" -v "$LAB/edge:/lab/edge:ro" -v "$LAB/logs/$node:/var/log/edge" \
        "${extra[@]}" "$(edge_image)" nginx -c /lab/edge/nginx.conf -g 'daemon off;' >/dev/null
}

lb_up() {
    docker rm -f bf-lb >/dev/null 2>&1
    mkdir -p "$LAB/logs/lb"
    docker run -d --name bf-lb --hostname lb --network "$NET" --ip "${IP[lb]}" -p 8100:8100 --ulimit nofile=65536:65536 \
        -v "$LAB/lb:/lab/lb:ro" -v "$LAB/logs/lb:/var/log/lb" "$NGINX_IMAGE" nginx -c /lab/lb/nginx.conf -g 'daemon off;' >/dev/null
}

front_up() {
    local n
    for n in "${EDGES[@]}"; do edge_up "$n"; done
    lb_up
    sleep 1
    for n in "${EDGES[@]}" lb; do
        running "$n" || { bad "bf-$n exited at start:"; docker logs "bf-$n" 2>&1 | tail -3 | sed 's/^/       /'; }
    done
}

up() {
    need_edition || return 1
    [ -f "$LAB/edge/nginx.conf" ] || { bad "no edge/nginx.conf: ./warroom.sh init $(edition) --force"; return 1; }
    net_up && key_up && origin_up && client_up && front_up
    wait_ready
    status
}

wait_ready() {
    for _ in $(seq 40); do
        docker exec bf-client curl -s -o /dev/null --max-time 1 "http://${IP[lb]}:8100/healthz" 2>/dev/null && return 0
        sleep 0.25
    done
}

# Ready check: the war room's preflight. Exit 0 only if the lab is usable.
status() {
    local fail=0 n out seen
    for n in origin client; do
        if running "$n"; then ok "bf-$n is running"; else bad "bf-$n is not running (./warroom.sh up)"; fail=1; fi
    done
    for n in "${EDGES[@]}"; do
        if ! running "$n"; then bad "bf-$n is not running (./warroom.sh up, then ./warroom.sh logs $n)"; fail=1; continue; fi
        if out=$(docker exec "bf-$n" nginx -t -c /lab/edge/nginx.conf 2>&1); then
            ok "$n: edge/nginx.conf loads ($(docker exec "bf-$n" nginx -v 2>&1 | sed 's/.*version: //'))"
        else bad "$n: nginx -t fails:"; echo "$out" | sed 's/^/       /'; fail=1; fi
    done
    if running lb; then ok "bf-lb is running"; else bad "bf-lb is not running"; fail=1; fi
    if running client && running lb; then
        seen=$(for _ in 1 2 3 4; do docker exec bf-client curl -s -o /dev/null -w '%{http_code}:' -D - --max-time 3 \
                   "http://${IP[lb]}:8100/catalog/headphones/" 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1)=="x-edge"{print $2}'; done | sort -u | tr '\n' ' ')
        if [ "$seen" = "edge-a edge-b " ]; then ok "the load balancer reaches both edges, and they reach the origin"
        else bad "shoppers through :8100 should reach both edges and the origin (saw X-Edge: ${seen:-none})"; fail=1; fi
    fi
    if [ "$fail" = 0 ]; then
        echo -e "${GREEN}War room ready${NC} ($(edition) edition): shoppers on :8100, ./warroom.sh next opens a ticket"
    else
        echo -e "${RED}War room NOT ready${NC}: fix the items marked [!!]"
    fi
    return "$fail"
}

# nginx -t can't see everything: the master can refuse a new config (a shared zone redefined with another
# key or size) and keep the old one while "nginx -s reload" succeeds. Report that instead of "reloaded".
reload_one() {
    local n="$1" conf="$2" log="$3" before out
    docker exec "bf-$n" nginx -t -q -c "$conf" || { bad "$n: nginx -t failed, nothing reloaded"; return 1; }
    before=$(wc -l < "$log" 2>/dev/null || echo 0)
    out=$(docker exec "bf-$n" nginx -c "$conf" -s reload 2>&1) || { echo "$out"; return 1; }
    echo "$out" | grep -v -e 'signal process started' -e '^$'
    sleep 1
    if tail -n +"$((before + 1))" "$log" | grep -q '\[emerg\]'; then
        bad "$n: reload REFUSED by the master, the old configuration is still running:"
        tail -n +"$((before + 1))" "$log" | grep '\[emerg\]' | sed 's/^/       /'
        return 1
    fi
    ok "$n reloaded"
}

reload() {
    local n fail=0
    for n in "${EDGES[@]}"; do
        docker exec "bf-$n" nginx -t -q -c /lab/edge/nginx.conf || { bad "$n: nginx -t failed, nothing reloaded"; return 1; }
    done
    for n in "${EDGES[@]}"; do reload_one "$n" /lab/edge/nginx.conf "$LAB/logs/$n/error.log" || fail=1; done
    reload_one lb /lab/lb/nginx.conf "$LAB/logs/lb/error.log" || fail=1
    return "$fail"
}

as_from() {
    local ip="$1"; shift
    docker exec bf-client sh -c 'ip -o -4 addr show dev eth0 | grep -q " $0/" || ip addr add "$0/16" dev eth0 2>/dev/null; exec curl -sS --interface "$0" "$@"' "$ip" "$@"
}

warroom_py() {
    local starts=""
    running client || { bad "the war room isn't up: ./warroom.sh up"; return 1; }
    starts="$(for n in "${EDGES[@]}" lb; do echo -n "$n=$(docker inspect -f '{{.State.StartedAt}}' "bf-$n" 2>/dev/null) "; done)"
    docker exec -e EDITION="$(edition)" -e STARTS="$starts" bf-client python3 -u /lab/warroom.py "$@"
}

lua() {
    case "${1:-}" in
        up)
            docker rm -f bf-lua >/dev/null 2>&1
            mkdir -p "$LAB/logs/lua"
            docker run -d --name bf-lua --hostname lua --network "$NET" --network-alias lua --ip "${IP[lua]}" --ulimit nofile=65536:65536 \
                -e SHOP_KEY="$(cat "$LAB/secrets/shop.key")" -v "$LAB/openresty:/lab/openresty:ro" -v "$LAB/logs/lua:/var/log/edge" \
                "$LUA_IMAGE" openresty -c /lab/openresty/nginx.conf -g 'daemon off;' >/dev/null
            sleep 1
            if running lua; then ok "bf-lua (OpenResty $(docker exec bf-lua openresty -v 2>&1 | sed 's/.*openresty\///')) on lua:8080"
            else bad "bf-lua exited:"; docker logs bf-lua 2>&1 | tail -5; tail -5 "$LAB/logs/lua/error.log" 2>/dev/null; return 1; fi ;;
        down) docker rm -f bf-lua >/dev/null 2>&1; ok "bf-lua removed" ;;
        *) echo "usage: ./warroom.sh lua up|down"; return 1 ;;
    esac
}

cmd="${1:-}"; shift || true
case "$cmd" in
    init)    init "$@" ;;
    up)      up ;;
    status)  status ;;
    reload)  reload ;;
    restart) need_edition && front_up && wait_ready && status ;;
    t)       docker exec bf-edge-a nginx -t -c /lab/edge/nginx.conf ;;
    T)       docker exec bf-edge-a nginx -T -c /lab/edge/nginx.conf ;;
    down)    docker rm -f bf-lb bf-edge-a bf-edge-b bf-origin bf-client bf-lua >/dev/null 2>&1
             docker network rm "$NET" >/dev/null 2>&1; echo "war room removed (edge/, lb/, state/ and logs/ kept)" ;;
    next|check|board|answer|skip|bench_report)
             warroom_py "$cmd" "$@" ;;
    bench)   running lua || lua up || exit 1
             warroom_py bench_prepare && \
             for target in edge-a lua; do
                 echo "== $target: 15 s, 50 connections, a member who is not a VIP asks for a doorbuster (refused at the edge)"
                 docker run --rm --network "$NET" --ulimit nofile=65536:65536 "$OHA_IMAGE" -z 15s -c 50 --no-tui --output-format json \
                     -H "Cookie: nw_member=$(cat "$LAB/state/bench.cookie")" "http://$target:8080/doorbuster/tv-65" > "$LAB/state/bench-$target.json"
                 docker exec "bf-$target" sh -c 'for d in /proc/[0-9]*; do case "$(tr "\0" " " < $d/cmdline 2>/dev/null)" in
                     "nginx: worker process"*) awk "/VmRSS/ { print \$2 }" $d/status ;; esac; done' \
                     > "$LAB/state/bench-$target.rss"
             done && warroom_py bench_report ;;
    shop)    as_from 10.58.100.7 "${@:1:$#-1}" "http://${IP[lb]}:8100${@: -1}" ;;
    ops)     as_from 10.58.0.5 "$@" ;;
    from)    ip="$1"; shift; as_from "$ip" "$@" ;;
    token)   warroom_py token "$@" ;;
    api)     node="$1"; path="$2"; shift 2; as_from 10.58.0.5 "$@" "http://$node:8085$path" ;;
    prices)  curl -s http://127.0.0.1:8020/_ops/prices ;;
    stats)   curl -s "http://127.0.0.1:8020/_ops/stats?prefix=${1:-}" ;;
    lua)     lua "$@" ;;
    logs)    case "${1:-edge-a}" in
                 origin) docker logs -f bf-origin ;;
                 edge-a|edge-b|lb|lua) tail -F "$LAB/logs/$1/error.log" ;;
                 *) echo "usage: ./warroom.sh logs edge-a|edge-b|lb|lua|origin" ;;
             esac ;;
    *)       awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 1 ;;
esac

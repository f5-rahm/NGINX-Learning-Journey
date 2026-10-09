#!/usr/bin/env bash
# ==============================================================================
# Sprint 2 Lab Verification Test Suite: Lumina multi-service gateway
#
# Usage:   ./test_sprint02.sh
# Target:  override with NGINX_TARGET, e.g. NGINX_TARGET=http://127.0.0.1:8083 ./test_sprint02.sh
#
# Starts the mock backends (lab/mocks.sh) if they aren't running, and stops the
# ones it started when it exits. Test 8 briefly stops node 8001.
# ==============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOCKS="$SCRIPT_DIR/lab/mocks.sh"
TARGET="${NGINX_TARGET:-http://127.0.0.1:8082}"
HOST="Host: lumina.local"
PASSED=0
TOTAL=0
STRETCH_PASSED=0
STRETCH_TOTAL=0
STARTED_MOCKS=()

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

record() {
    local tier="$1" ok="$2" msg="$3" detail="${4:-}"
    if [ "$tier" = "core" ]; then
        TOTAL=$((TOTAL + 1)); [ "$ok" = 1 ] && PASSED=$((PASSED + 1))
        local label="Test $TOTAL"
    else
        STRETCH_TOTAL=$((STRETCH_TOTAL + 1)); [ "$ok" = 1 ] && STRETCH_PASSED=$((STRETCH_PASSED + 1))
        local label="Stretch $STRETCH_TOTAL"
    fi
    if [ "$ok" = 1 ]; then
        echo -e "  ${GREEN}[PASS] $label: $msg${NC}"
    else
        echo -e "  ${RED}[FAIL] $label: $msg${NC}"
        [ -n "$detail" ] && echo -e "         ${YELLOW}$detail${NC}"
    fi
}

cleanup() {
    "$MOCKS" start 8001 >/dev/null 2>&1   # test 8 may have left it down
    if [ ${#STARTED_MOCKS[@]} -gt 0 ]; then
        echo -e "\n${BLUE}[*] Stopping mock backends this run started: ${STARTED_MOCKS[*]}${NC}"
        "$MOCKS" stop "${STARTED_MOCKS[@]}" >/dev/null
    fi
}
trap cleanup EXIT

# Pull one JSON field out of a mock backend response
field() { python3 -c 'import json,sys
try: print(json.load(sys.stdin)'"$1"')
except Exception: print("")'; }

echo -e "${BOLD}================================================================${NC}"
echo -e "${BOLD}   Sprint 2: Reverse Proxy & Load Balancing Test Runner${NC}"
echo -e "${BOLD}================================================================${NC}"

for port in 8001 8002 8003; do
    if ! "$MOCKS" status "$port" | grep -q UP; then
        "$MOCKS" start "$port" >/dev/null && STARTED_MOCKS+=("$port")
    fi
done
[ ${#STARTED_MOCKS[@]} -gt 0 ] && echo -e "${BLUE}[*] Started mock backends: ${STARTED_MOCKS[*]}${NC}"

if ! curl -s -o /dev/null --max-time 3 "$TARGET/healthz"; then
    echo -e "${RED}[ERROR] NGINX is not reachable at $TARGET${NC}"
    echo -e "  cd $SCRIPT_DIR/lab && ngx -t && ngx"
    exit 1
fi

echo -e "\n${BLUE}--- Edge health ---${NC}"
RESP=$(curl -s -w '\n%{http_code}' -H "$HOST" "$TARGET/healthz")
if [ "$(tail -n1 <<<"$RESP")" = 200 ] && [ "$(sed '$d' <<<"$RESP" | field '["status"]')" = healthy ]; then
    record core 1 "/healthz answered by NGINX with 200 JSON, status healthy"
else
    record core 0 "/healthz should return 200 JSON from NGINX with \"status\": \"healthy\"" "Got: $RESP"
fi

echo -e "\n${BLUE}--- Routing & URI mapping ---${NC}"
BODY=$(curl -s -H "$HOST" "$TARGET/api/v1/healthz")
NODE=$(field '["node"]' <<<"$BODY")
if [[ "$NODE" == api-node-* ]]; then
    record core 1 "/api/v1/ reaches the upstream pool ($NODE)"
else
    record core 0 "/api/v1/ should reach an api node" "Got: $BODY"
fi

PATH_SEEN=$(curl -s -H "$HOST" "$TARGET/api/v1/verify_path?x=1" | field '["path"]')
if [ "$PATH_SEEN" = "/api/v1/verify_path?x=1" ]; then
    record core 1 "URI and query string forwarded verbatim"
else
    record core 0 "Backend should receive /api/v1/verify_path?x=1" "Backend received: ${PATH_SEEN:-nothing}"
fi

echo -e "\n${BLUE}--- Header forwarding ---${NC}"
HDRS=$(curl -s -H "$HOST" "$TARGET/api/v1/headers")
H_HOST=$(field '["headers"].get("Host")' <<<"$HDRS")
H_RIP=$(field '["headers"].get("X-Real-IP")' <<<"$HDRS")
H_PROTO=$(field '["headers"].get("X-Forwarded-Proto")' <<<"$HDRS")
if [ "$H_HOST" = lumina.local ] && [ "$H_RIP" = 127.0.0.1 ] && [ "$H_PROTO" = http ]; then
    record core 1 "Host, X-Real-IP and X-Forwarded-Proto set for the backend"
else
    record core 0 "Backend should see Host=lumina.local, X-Real-IP=127.0.0.1, X-Forwarded-Proto=http" \
        "Saw Host=${H_HOST:-none} X-Real-IP=${H_RIP:-none} X-Forwarded-Proto=${H_PROTO:-none}"
fi

XFF=$(curl -s -H "$HOST" -H "X-Forwarded-For: 203.0.113.9" "$TARGET/api/v1/xff" | field '["headers"].get("X-Forwarded-For")')
if [ "$XFF" = "203.0.113.9, 127.0.0.1" ]; then
    record core 1 "X-Forwarded-For chain appended (203.0.113.9, 127.0.0.1)"
else
    record core 0 "X-Forwarded-For should append the client IP to the incoming chain" "Backend saw: ${XFF:-none}"
fi

echo -e "\n${BLUE}--- Load balancing ---${NC}"
declare -A SEEN=()
for _ in $(seq 10); do
    N=$(curl -s -H "$HOST" "$TARGET/api/v1/lb" | field '["node"]')
    [ -n "$N" ] && SEEN[$N]=1
done
if [ ${#SEEN[@]} -ge 2 ]; then
    record core 1 "10 requests spread across both nodes (${!SEEN[*]})"
else
    record core 0 "Requests should reach both api nodes" "Only saw: ${!SEEN[*]:-none}"
fi

echo -e "\n${BLUE}--- WebSocket relay ---${NC}"
# RFC 6455 sample key; the correct accept value is s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
WS=$(curl -s -i -N --http1.1 --max-time 2 -H "$HOST" \
    -H "Connection: Upgrade" -H "Upgrade: websocket" \
    -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" \
    "$TARGET/ws/chat" | tr -d '\r')
if grep -q "101 Switching Protocols" <<<"$WS" && grep -q "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" <<<"$WS" \
   && grep -q "welcome from chat-ws" <<<"$WS"; then
    record core 1 "/ws/chat upgrades (101) and relays frames after the handshake"
else
    record core 0 "/ws/chat should return 101 and relay the backend's welcome frame" \
        "Response: $(head -n1 <<<"$WS")  (backend log: lab/logs/mock-8003.log)"
fi

echo -e "\n${BLUE}--- Failover (node 8001 stopped) ---${NC}"
"$MOCKS" stop 8001 >/dev/null
OK=0; NODES=""
for _ in $(seq 10); do
    R=$(curl -s -w '\n%{http_code}' -H "$HOST" "$TARGET/api/v1/resilience")
    [ "$(tail -n1 <<<"$R")" = 200 ] && OK=$((OK + 1))
    NODES+="$(sed '$d' <<<"$R" | field '["node"]') "
done
"$MOCKS" start 8001 >/dev/null
if [ "$OK" = 10 ]; then
    record core 1 "10/10 requests succeeded with node 8001 down"
else
    record core 0 "Every request should succeed while 8001 is down" "$OK/10 returned 200; nodes: $NODES"
fi

echo -e "\n${BLUE}--- Stretch (not part of the gate) ---${NC}"
# The mock reports how many requests each backend TCP connection has carried.
# Peer ports are no proof: on loopback Linux reuses ports immediately (tcp_tw_reuse=2).
sleep 6   # let fail_timeout expire so 8001 rejoins the pool
MAXREQ=$(for _ in $(seq 20); do curl -s -H "$HOST" "$TARGET/api/v1/ka" | field '["conn_requests"]'; done | sort -n | tail -n1)
if [ "${MAXREQ:-0}" -gt 1 ] 2>/dev/null; then
    record stretch 1 "Upstream keepalive: backend connections reused (up to $MAXREQ requests each)"
else
    record stretch 0 "Upstream keepalive: every request opened a new backend connection" \
        "Default since nginx 1.29.7; on older builds add keepalive to the upstream, proxy_http_version 1.1 and Connection \"\""
fi

SPA=$(curl -s -H "$HOST" "$TARGET/courses/42")
if grep -q "Lumina Learning Platform" <<<"$SPA"; then
    record stretch 1 "SPA fallback: /courses/42 serves index.html"
else
    record stretch 0 "SPA fallback: /courses/42 should serve html/index.html"
fi

echo -e "\n${BOLD}================================================================${NC}"
echo -e "${BOLD}   Core: $PASSED / $TOTAL passed    Stretch: $STRETCH_PASSED / $STRETCH_TOTAL${NC}"
echo -e "${BOLD}================================================================${NC}"
[ "$PASSED" = "$TOTAL" ] && echo -e "${GREEN}Sprint 2 lab gate PASSED${NC}" || echo -e "${RED}Sprint 2 lab gate not yet passed${NC}"
[ "$PASSED" = "$TOTAL" ]

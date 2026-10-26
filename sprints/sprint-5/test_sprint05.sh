#!/usr/bin/env bash
# ==============================================================================
# Sprint 5 Lab Verification Test Suite: the Lumina API Gateway
#
# Usage:   ./test_sprint05.sh
# Targets: the gateway at 10.55.0.10:8095 on the lab network, driven from the
#          s5-client container, and the origin's counters on 127.0.0.1:8015,
#          all started by lab/lab.sh up.
#
# Every run sends from fresh client addresses, so earlier runs and your own
# experiments don't use up its limits. Runtime: about 20 seconds (the login
# refill check waits 12.5 seconds, and the slow-client check up to 15).
# ==============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB="$SCRIPT_DIR/lab"
ORIGIN="${ORIGIN:-127.0.0.1:8015}"
GW="${GW:-10.55.0.10:8095}"
PASSED=0
TOTAL=0
TMP=$(mktemp -d)

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

record() {
    local ok="$1" msg="$2" detail="${3:-}"
    TOTAL=$((TOTAL + 1)); [ "$ok" = 1 ] && PASSED=$((PASSED + 1))
    if [ "$ok" = 1 ]; then
        echo -e "  ${GREEN}[PASS] Test $TOTAL: $msg${NC}"
    else
        echo -e "  ${RED}[FAIL] Test $TOTAL: $msg${NC}"
        [ -n "$detail" ] && echo -e "         ${YELLOW}$detail${NC}"
    fi
}
cleanup() { pkill -P $$ 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

# Fresh addresses for this run: 10.55.<run>.<n> for internet clients, and a fresh host
# number inside each special network
# (a new set every 20 s, the length of a run, so back-to-back runs never share limit state)
RUN=$(( $(date +%s) / 20 % 100 + 130 )); H=$(( $(date +%s) / 20 % 200 + 20 ))
ip_new() { echo "10.55.$RUN.$1"; }
PARTNER_IP="10.55.20.$H"; OPS_IP="10.55.10.$H"; BLOCKED_IP="10.55.66.$H"; LB=10.55.0.5

c() { docker exec -e EDGE="$GW" s5-client python3 /lab/client.py "$@"; }
# n STATUS OUTPUT: how many responses had that status in a client.py summary line
n() { echo "$2" | head -1 | grep -oE "\b$1 x [0-9]+" | awk '{ s += $3 } END { print s + 0 }'; }
secs() { echo "$1" | head -1 | grep -oE '[0-9.]+s' | head -1 | tr -d s; }
lt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a < b) }'; }

echo -e "${BOLD}Sprint 5 lab: the Lumina API Gateway${NC}"
echo -e "\n${BLUE}--- Preflight (not scored): lab/lab.sh check ---${NC}"
if ! "$LAB/lab.sh" check; then
    echo -e "\n${RED}${BOLD}Setup problem: the lab isn't ready, so no requirement was tested.${NC}"
    echo -e "${RED}Fix the [!!] items above (start with: cd lab && ./lab.sh up) and run again.${NC}"
    exit 2
fi

# Started now, checked at the end: a slow client, and the first half of the login check
( c slow --from "$(ip_new 13)" --every 2 --for 15 / > "$TMP/slow" 2>&1 ) &
LOGIN1=$(c burst 8 --from "$(ip_new 3)" /api/login)
LOGIN_T0=$(date +%s.%N)

echo -e "\n${BLUE}--- Limits ---${NC}"
rate=$(c burst 40 --conc 4 --from "$(ip_new 1)" /api/t1)
conn=$(c hold 6 2 --from "$(ip_new 21)" /api/t1)
if echo "$rate" | head -1 | grep -q '429 x [0-9]* (Retry-After: 1)' && echo "$conn" | head -1 | grep -q '429 x [0-9]* (Retry-After: 1)'; then
    record 1 "Rate and concurrency refusals are 429 with Retry-After: 1"
else
    record 0 "Requests refused by a rate or concurrency limit should get 429 and Retry-After: 1" \
        "Over the rate:$(echo "$rate" | head -1 | cut -d: -f2-) | over the concurrency limit:$(echo "$conn" | head -1 | cut -d: -f2-)"
fi

out=$(c burst 40 --conc 4 --from "$(ip_new 2)" /api/t2); ok2=$(n 200 "$out"); other=$(c get --from "$(ip_new 22)" /api/t2 | awk '{ print $1 }')
if [ "$ok2" -ge 21 ] && [ "$ok2" -le 23 ] && [ "$other" = 200 ]; then
    record 1 "/api/: 40 rapid requests from one client, $ok2 answered (10/s + 20 burst), another client unaffected"
else
    record 0 "/api/ should allow each client 10 requests/s plus a burst of 20 extra, answered without delay" \
        "40 rapid requests (4 at a time) from one client: $ok2 answered, expected 21-23 | another client at the same time: $other"
fi

out=$(c hold 8 2 --from "$(ip_new 4)" /api/t4); ok4=$(n 200 "$out"); no4=$(n 429 "$out")
if [ "$ok4" = 4 ] && [ "$no4" = 4 ]; then
    record 1 "/api/: 8 requests in progress at once from one client, 4 answered"
else
    record 0 "/api/ should allow each client at most 4 requests in progress at once" \
        "8 slow requests at once from one client: $(echo "$out" | head -1 | cut -d: -f2-)"
fi

curl -s --max-time 2 "http://$ORIGIN/_stats/reset" >/dev/null
pids=()
for i in $(seq 10); do c hold 3 2 --from "$(ip_new $((40 + i)))" /api/t5 > "$TMP/o.$i" & pids+=($!); done
wait "${pids[@]}"
ok5=0; no5=0
for i in $(seq 10); do o=$(cat "$TMP/o.$i"); ok5=$((ok5 + $(n 200 "$o"))); no5=$((no5 + $(n 429 "$o"))); done
peak=$(curl -s --max-time 2 "http://$ORIGIN/_stats" | python3 -c 'import json,sys; print(json.load(sys.stdin)["max_inflight"])' 2>/dev/null)
if [ "${peak:-99}" -le 20 ] && [ "$ok5" = 20 ] && [ "$no5" = 10 ]; then
    record 1 "/api/: 30 slow requests from 10 clients, at most $peak in progress at the origin"
else
    record 0 "/api/ should have at most 20 requests in progress at the origin, across all clients" \
        "30 slow requests from 10 clients: $ok5 answered, $no5 refused, origin peak in flight: ${peak:-?}"
fi

small=$(c get --from "$(ip_new 6)" --data-size 1500000 /api/upload | awk '{ print $1 }')
big=$(c get --from "$(ip_new 6)" --data-size 3000000 /api/upload | awk '{ print $1 }')
if [ "$small" = 200 ] && [ "$big" = 413 ]; then
    record 1 "/api/: a 1.5 MB body is accepted, a 3 MB body gets 413"
else
    record 0 "/api/ should accept request bodies up to 2 MB and answer 413 to larger ones" \
        "1.5 MB body: $small | 3 MB body: $big"
fi

echo -e "\n${BLUE}--- Login ---${NC}"
left=$(awk -v t0="$LOGIN_T0" -v now="$(date +%s.%N)" 'BEGIN { s = 12.5 - (now - t0); print (s > 0 ? s : 0) }')
sleep "$left"
LOGIN2=$(c burst 2 --from "$(ip_new 3)" /api/login)
a=$(n 200 "$LOGIN1"); b=$(n 200 "$LOGIN2")
if [ "$a" = 5 ] && [ "$b" = 1 ]; then
    record 1 "/api/login: 5 of 8 rapid attempts answered, and one more 12.5 s later"
else
    record 0 "/api/login should allow each client 5 attempts in quick succession, then one more every 12 seconds" \
        "8 rapid attempts: $a answered | 2 more after 12.5 s: $b answered"
fi

echo -e "\n${BLUE}--- Downloads ---${NC}"
s_small=$(secs "$(c get --from "$(ip_new 7)" '/downloads/t7?size=200k')")
s_big=$(secs "$(c get --from "$(ip_new 7)" '/downloads/t7?size=1m')")
if lt "$s_small" 0.4 && lt 1.1 "$s_big" && lt "$s_big" 2.5; then
    record 1 "/downloads/: 200 KB in ${s_small}s, 1 MB in ${s_big}s (256 KB at full speed, then 512 KB/s)"
else
    record 0 "/downloads/ should send the first 256 KB at full speed, then 512 KB/s" \
        "200 KB took ${s_small}s (expected < 0.4) | 1 MB took ${s_big}s (expected 1.1-2.5)"
fi

out=$(c burst 2 --from "$(ip_new 8)" '/downloads/t8?size=1m')
if [ "$(n 200 "$out")" = 1 ] && [ "$(n 429 "$out")" = 1 ]; then
    record 1 "/downloads/: two downloads at once from one client, one refused"
else
    record 0 "/downloads/ should let each client run one download at a time" \
        "Two downloads at once from one client: $(echo "$out" | head -1 | cut -d: -f2-)"
fi

echo -e "\n${BLUE}--- Networks ---${NC}"
p_rate=$(c burst 40 --conc 4 --from "$PARTNER_IP" /api/t9); p_conn=$(c hold 8 1 --from "$PARTNER_IP" /api/t9)
p_dl=$(secs "$(c get --from "$PARTNER_IP" '/downloads/t9?size=1m')")
i_rate=$(c burst 40 --conc 4 --from "$(ip_new 9)" /api/t9); i_dl=$(secs "$(c get --from "$(ip_new 9)" '/downloads/t9?size=1m')")
if [ "$(n 200 "$p_rate")" = 40 ] && [ "$(n 200 "$p_conn")" = 8 ] && lt "$p_dl" 0.5 \
   && [ "$(n 429 "$i_rate")" -gt 0 ] && lt 1 "$i_dl"; then
    record 1 "The partner network is exempt (40/40 rapid, 8/8 at once, 1 MB in ${p_dl}s); others are limited"
else
    record 0 "The partner network should be exempt from the /api/ limits and download at full speed, while others stay limited" \
        "Partner: $(n 200 "$p_rate")/40 rapid, $(n 200 "$p_conn")/8 at once, 1 MB in ${p_dl}s | internet client: $(n 429 "$i_rate") refused of 40, 1 MB in ${i_dl}s"
fi

ops=$(c get --from "$OPS_IP" /admin/t10 | awk '{ print $1 }'); inet=$(c get --from "$(ip_new 10)" /admin/t10 | awk '{ print $1 }')
part=$(c get --from "$PARTNER_IP" /admin/t10 | awk '{ print $1 }')
if [ "$ops" = 200 ] && [ "$inet" = 403 ] && [ "$part" = 403 ]; then
    record 1 "/admin/: operations 200, internet 403, partner 403"
else
    record 0 "Only the operations network should use /admin/; everyone else gets 403" \
        "Operations: $ops | internet: $inet | partner: $part"
fi

out=$(c burst 30 --from "$BLOCKED_IP" /api/t11); dl=$(c get --from "$BLOCKED_IP" '/downloads/t11?size=1k' | awk '{ print $1 }')
if [ "$(n 403 "$out")" = 30 ] && [ "$dl" = 403 ]; then
    record 1 "The abusive network gets 403 for all 30 requests in a flood, and on /downloads/"
else
    record 0 "Every request from the abusive network should get 403, however many it sends" \
        "30 at once to /api/: $(echo "$out" | head -1 | cut -d: -f2-) | /downloads/: $dl"
fi

echo -e "\n${BLUE}--- Behind the load balancer ---${NC}"
lb_blocked=$(c get --from "$LB" -H "X-Forwarded-For: $BLOCKED_IP" /api/t12 | awk '{ print $1 }')
lb_partner=$(c burst 40 --conc 4 --from "$LB" -H "X-Forwarded-For: $PARTNER_IP" /api/t12)
spoof=$(c burst 40 --conc 4 --from "$(ip_new 12)" -H "X-Forwarded-For: $PARTNER_IP" /api/t12)
if [ "$lb_blocked" = 403 ] && [ "$(n 200 "$lb_partner")" = 40 ] && [ "$(n 429 "$spoof")" -gt 0 ]; then
    record 1 "Via the load balancer, the X-Forwarded-For client counts (blocked 403, partner 40/40); spoofed headers are ignored"
else
    record 0 "Requests from the load balancer should be treated as the X-Forwarded-For client, and nobody else's X-Forwarded-For trusted" \
        "LB for a blocked client: $lb_blocked | LB for a partner: $(n 200 "$lb_partner")/40 | direct client claiming a partner address: $(n 429 "$spoof") refused of 40"
fi

echo -e "\n${BLUE}--- Slow clients ---${NC}"
wait
slow=$(cat "$TMP/slow")
ss=$(echo "$slow" | grep -oE 'after [0-9.]+s' | grep -oE '[0-9.]+')
if [ -n "$ss" ] && lt 8 "$ss" && lt "$ss" 13; then
    record 1 "A client dribbling its headers was disconnected after ${ss}s"
else
    record 0 "A client that hasn't sent its complete request headers within 10 seconds should be disconnected" \
        "${slow:-no result from the slow client}"
fi

echo -e "\n${BOLD}================================================================${NC}"
echo -e "${BOLD}   Requirements: $PASSED / $TOTAL passed${NC}"
echo -e "${BOLD}================================================================${NC}"
if [ "$PASSED" = "$TOTAL" ]; then
    echo -e "${GREEN}${BOLD}Sprint 5 lab gate PASSED${NC}"
elif [ "$PASSED" = 0 ]; then
    echo -e "${GREEN}${BOLD}Sprint 5 start is ready to go:${NC} the lab is up, the config loads, and all $TOTAL requirements are still open."
else
    echo -e "${YELLOW}Sprint 5 lab gate not yet passed: $((TOTAL - PASSED)) requirement(s) to go${NC}"
fi
[ "$PASSED" = "$TOTAL" ]

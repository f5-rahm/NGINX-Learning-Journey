#!/usr/bin/env bash
# ==============================================================================
# Sprint 4 Lab Verification Test Suite: the Lumina Edge Accelerator
#
# Usage:   ./test_sprint04.sh            (as root: tests 9 and 10 read the edge's
#                                         network namespace and /proc limits)
# Targets: the edge on EDGE (127.0.0.1:8084), the origin's counters on ORIGIN
#          (127.0.0.1:8014), both started by lab/lab.sh up.
#
# Every test uses fresh URLs, so earlier runs and your own experiments don't
# matter. Tests 7 and 8 briefly switch the origin into failure / slow modes and
# switch it back. Runtime: about 20 seconds.
# ==============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB="$SCRIPT_DIR/lab"
EDGE="${EDGE:-127.0.0.1:8084}"
ORIGIN="${ORIGIN:-127.0.0.1:8014}"
RID="r$$-$RANDOM"
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

mode() { curl -s --max-time 2 "http://$ORIGIN/_mode?$1" >/dev/null; }
cleanup() { mode ""; rm -rf "$TMP"; }
trap cleanup EXIT

# get NAME PATH [curl args...]: one request to the edge. Sets NAME_code, NAME_cache, NAME_hits, NAME_host.
get() {
    local name="$1" path="$2"; shift 2
    local code cache hits host
    code=$(curl -s --max-time 6 -D "$TMP/h" -o "$TMP/b" -w '%{http_code}' "$@" "http://$EDGE$path")
    cache=$(tr -d '\r' < "$TMP/h" | awk -F': ' 'tolower($1) == "x-cache-status" { print $2 }')
    hits=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("origin_hits",""))' "$TMP/b" 2>/dev/null)
    host=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("host",""))' "$TMP/b" 2>/dev/null)
    printf -v "${name}_code" '%s' "$code"; printf -v "${name}_cache" '%s' "${cache:-none}"
    printf -v "${name}_hits" '%s' "$hits"; printf -v "${name}_host" '%s' "$host"
}

# origin_count URI: how many times this exact URI reached the origin
origin_count() {
    curl -s --max-time 2 "http://$ORIGIN/_stats" | python3 -c \
        'import json,sys; print(json.load(sys.stdin)["by_uri"].get(sys.argv[1], 0))' "$1"
}
echo -e "${BOLD}Sprint 4 lab: the Lumina Edge Accelerator${NC}"
echo -e "\n${BLUE}--- Preflight (not scored): lab/lab.sh check ---${NC}"
if ! "$LAB/lab.sh" check; then
    echo -e "\n${RED}${BOLD}Setup problem: the lab isn't ready, so no requirement was tested.${NC}"
    echo -e "${RED}Fix the [!!] items above (start with: cd lab && ./lab.sh up) and run again.${NC}"
    exit 2
fi

echo -e "\n${BLUE}--- Caching ---${NC}"
get a "/t1/$RID"
if [[ "$a_cache" =~ ^(MISS|HIT|BYPASS|EXPIRED|STALE|UPDATING|REVALIDATED)$ ]]; then
    record 1 "Responses carry X-Cache-Status ($a_cache)"
else
    record 0 "Every response should carry X-Cache-Status with the cache result" "X-Cache-Status: $a_cache"
fi

get a "/t2/$RID"; get b "/t2/$RID"; n=$(origin_count "/t2/$RID")
if [ "$b_cache" = HIT ] && [ "$n" = 1 ]; then
    record 1 "A repeat request for a response with no caching headers is a HIT (origin saw it once)"
else
    record 0 "A response with no caching headers should be cached: the repeat should be a HIT" \
        "First: $a_cache | repeat: $b_cache | origin saw it $n times"
fi

detail=""
for q in "nostore?cc=no-store" "private?cc=private" "cookie?cookie=1"; do
    u="/t3/$RID/$q"; get a "$u"; get b "$u"; n=$(origin_count "$u")
    if [ "$b_cache" = none ] || [ "$b_cache" = HIT ] || [ "$n" != 2 ]; then
        detail+="$q: repeat $b_cache, origin saw it $n times. "
    fi
done
if [ -z "$detail" ]; then
    record 1 "no-store, private and Set-Cookie responses are never served from cache"
else
    record 0 "Responses marked no-store or private, or that set a cookie, must never be served from cache" "$detail"
fi

u="/t4/$RID"
get a "$u" -H "Host: a.lumina.local"; get b "$u" -H "Host: b.lumina.local"; get c "$u" -H "Host: a.lumina.local"
if [ "$a_host" = a.lumina.local ] && [ "$b_host" = b.lumina.local ] && [ "$b_cache" = MISS ] \
   && [ "$c_cache" = HIT ] && [ "$c_host" = a.lumina.local ]; then
    record 1 "The origin sees the client's Host, and a.lumina.local / b.lumina.local get separate entries"
else
    record 0 "The origin should receive the client's Host, and different hosts must not share an entry" \
        "a: host=${a_host:-?} $a_cache | b: host=${b_host:-?} $b_cache | a again: host=${c_host:-?} $c_cache"
fi

u="/t5/$RID"
get a "$u" -H "Authorization: Bearer alice"; get b "$u" -H "Authorization: Bearer alice"; n=$(origin_count "$u")
get c "$u"
u="/t5/$RID/cached"
get d "$u"; get e "$u" -H "Authorization: Bearer alice"; m=$(origin_count "$u")
if [ "$a_cache" != none ] && [ "$b_cache" != HIT ] && [ "$n" = 2 ] && [ "$c_cache" != none ] && [ "$c_cache" != HIT ] \
   && [ "$e_cache" != HIT ] && [ "$m" = 2 ]; then
    record 1 "Authorization requests always reach the origin, and an anonymous client never gets their copy"
else
    record 0 "Requests with Authorization must always reach the origin, and their responses must never be stored" \
        "With Authorization: $a_cache, $b_cache (origin saw $n of 2) | then anonymous: $c_cache | Authorization on a cached URL: $e_cache"
fi

echo -e "\n${BLUE}--- Under pressure ---${NC}"
u="/t6/$RID?delay=2"
for i in $(seq 20); do curl -s -o /dev/null --max-time 8 -w '%{http_code}\n' "http://$EDGE$u" > "$TMP/burst.$i" & done
wait
oks=$(cat "$TMP"/burst.* | grep -c '^200$'); n=$(origin_count "$u")
if [ "$oks" = 20 ] && [ "$n" = 1 ]; then
    record 1 "20 concurrent requests for an uncached URL reached the origin once"
else
    record 0 "A burst of concurrent requests for an uncached URL should reach the origin once" \
        "$oks of 20 got 200 | origin saw it $n times"
fi

ua="/t7/$RID/a?cc=max-age=1"; ub="/t7/$RID/b?cc=max-age=1"
get p "$ua"; get p "$ub"; sleep 2
mode "drop=1";     get a "$ua"
mode "status=503"; get b "$ub"
mode ""
if [ "$a_code" = 200 ] && [ "$a_hits" = 1 ] && [ "$b_code" = 200 ] && [ "$b_hits" = 1 ]; then
    record 1 "Expired copies are served when the origin fails ($a_cache) and when it answers 503 ($b_cache)"
else
    record 0 "When the origin fails or answers 5xx, clients should get the expired cached copy" \
        "Origin dropping connections: $a_code $a_cache | origin answering 503: $b_code $b_cache"
fi

u="/t8/$RID?cc=max-age=1"
get p "$u"; sleep 2
mode "delay=3"
t0=$(date +%s.%N); get a "$u"; t1=$(date +%s.%N)
mode ""
secs=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.2f", b - a }')
sleep 3.5; n=$(origin_count "$u")
if [ "$a_code" = 200 ] && awk -v s="$secs" 'BEGIN { exit !(s < 1) }' && [ "$n" = 2 ]; then
    record 1 "An expired entry was answered in ${secs}s ($a_cache) and refreshed in the background"
else
    record 0 "Refreshing an expired entry should not make the client wait for a slow origin" \
        "Answered $a_code ($a_cache) in ${secs}s with the origin taking 3s | origin refreshed it: $([ "$n" = 2 ] && echo yes || echo no)"
fi

echo -e "\n${BLUE}--- Capacity ---${NC}"
MASTER=$(docker inspect -f '{{.State.Pid}}' s4-edge 2>/dev/null)
backlog=$(nsenter -t "$MASTER" -n ss -Hlnt 'sport = :8084' 2>/dev/null | awk '{ print $3; exit }')
if [ -n "$backlog" ] && [ "$backlog" -ge 4096 ]; then
    record 1 "Port 8084's accept queue holds $backlog connections"
else
    record 0 "Port 8084's accept queue should hold at least 4096 connections" "Accept queue size (ss Send-Q): ${backlog:-unreadable, run as root}"
fi

low=""
for w in $(pgrep -P "$MASTER" -f 'worker process'); do
    soft=$(awk '/^Max open files/ { print $4 }' "/proc/$w/limits" 2>/dev/null)
    [ -z "$soft" ] || [ "$soft" -lt 16384 ] && low+="pid $w: ${soft:-unreadable} "
done
workers=$(pgrep -P "$MASTER" -fc 'worker process')
if [ "$workers" -gt 0 ] && [ -z "$low" ]; then
    record 1 "All $workers workers can open at least 16384 files"
else
    record 0 "Each worker should be able to open at least 16384 files" "Open-file limit: ${low:-no workers found}"
fi

echo -e "\n${BOLD}================================================================${NC}"
echo -e "${BOLD}   Requirements: $PASSED / $TOTAL passed${NC}"
echo -e "${BOLD}================================================================${NC}"
if [ "$PASSED" = "$TOTAL" ]; then
    echo -e "${GREEN}${BOLD}Sprint 4 lab gate PASSED${NC}"
elif [ "$PASSED" = 0 ]; then
    echo -e "${GREEN}${BOLD}Sprint 4 start is ready to go:${NC} the lab is up, the config loads, and all $TOTAL requirements are still open."
else
    echo -e "${YELLOW}Sprint 4 lab gate not yet passed: $((TOTAL - PASSED)) requirement(s) to go${NC}"
fi
[ "$PASSED" = "$TOTAL" ]

#!/usr/bin/env bash
# ==============================================================================
# Sprint 6 Lab Verification Test Suite: Lumina Edge Functions
#
# Usage:   ./test_sprint06.sh
# Targets: the edge on 127.0.0.1:8096 (HTTP) and :8097 (telemetry), and the
#          origin's counters on 127.0.0.1:8016, all started by lab/lab.sh up.
#          Tokens, links and telemetry greetings are signed with the lab key in
#          lab/secrets/lumina.key (lab/tools.py).
#
# Runtime: about 15 seconds (the revocation check waits for the edge to notice,
# and a silent telemetry client waits to be closed).
# ==============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB="$SCRIPT_DIR/lab"
EDGE="${EDGE:-127.0.0.1:8096}"
ORIGIN="${ORIGIN:-127.0.0.1:8016}"
PASSED=0
TOTAL=0
TMP=$(mktemp -d)
RUN=$(date +%s)

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

tools() { python3 "$LAB/tools.py" "$@"; }
sess()  { echo "lumina_session=$(tools token "$@")"; }
# code PATH [curl options]: the status; body PATH [curl options]: the body
code()  { local p="$1"; shift; curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@" "http://$EDGE$p"; }
body()  { local p="$1"; shift; curl -s --max-time 5 "$@" "http://$EDGE$p"; }
# field JSON NAME: a top-level field of a JSON document ("ERR" if it isn't JSON)
field() { echo "$1" | python3 -c 'import json,sys
try: v = json.load(sys.stdin).get(sys.argv[1], "MISSING"); print("null" if v is None else v)
except Exception: print("ERR")' "$2"; }
# seen URI: how many times the origin answered this exact URI (both pools)
seen()  { curl -s --max-time 2 "http://$ORIGIN/_stats" | python3 -c 'import json,sys
s = json.load(sys.stdin)["by_uri"]; print(s.get("stable " + sys.argv[1], 0) + s.get("beta " + sys.argv[1], 0))' "$1"; }
# seenp PREFIX: how many requests the origin answered whose URI starts with PREFIX
seenp() { curl -s --max-time 2 "http://$ORIGIN/_stats" | python3 -c 'import json,sys
s = json.load(sys.stdin)["by_uri"]; print(sum(v for k, v in s.items() if k.split(" ", 1)[1].startswith(sys.argv[1])))' "$1"; }
telem() { curl -s --max-time 2 "http://$ORIGIN/_stats" | python3 -c 'import json,sys; print(json.load(sys.stdin)["telemetry"])'; }

echo -e "${BOLD}Sprint 6 lab: Lumina Edge Functions${NC}"
echo -e "\n${BLUE}--- Preflight (not scored): lab/lab.sh check ---${NC}"
if ! "$LAB/lab.sh" check; then
    echo -e "\n${RED}${BOLD}Setup problem: the lab isn't ready, so no requirement was tested.${NC}"
    echo -e "${RED}Fix the [!!] items above (start with: cd lab && ./lab.sh up) and run again.${NC}"
    exit 2
fi
KEY=$(cat "$LAB/secrets/lumina.key")
GW_IP=$(docker network inspect s6-net -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null)

# Started now, checked at the end: a telemetry client that connects and sends nothing
TEL0=$(telem)
( tools tel quiet-$RUN --silent > "$TMP/silent" 2>&1 ) &

echo -e "\n${BLUE}--- Sessions ---${NC}"
ok_user=$(field "$(body "/api/t1-$RUN" -b "$(sess alice-$RUN)")" x_user)
no_user=$(field "$(body "/api/t1-$RUN" -b "$(sess alice-$RUN --key not-the-key)")" x_user)
ok_link=$(code "$(tools link "/downloads/t1-$RUN.bin")")
no_link=$(code "$(tools link "/downloads/t1-$RUN.bin" --key not-the-key)")
in_files=$(grep -rlF --include='*.conf' --include='*.js' --include='*.json' -e "$KEY" "$LAB" 2>/dev/null | head -3 | tr '\n' ' ')
if [ -z "$in_files" ] && { { [ "$ok_user" = "alice-$RUN" ] && [ "$no_user" = null ]; } || { [ "$ok_link" = 200 ] && [ "$no_link" = 403 ]; }; }; then
    record 1 "Signatures are checked with the LUMINA_KEY key, and the key is in no config or script file"
else
    record 0 "Signatures should be checked with the key from the LUMINA_KEY environment variable, never written in a file" \
        "Key found in: ${in_files:-no file} | X-User for a session signed with the key: $ok_user, with another key: $no_user | link signed with the key: $ok_link, with another key: $no_link"
fi

with=$(field "$(body "/api/t2-$RUN" -b "$(sess bob-$RUN)")" x_user)
spoof=$(field "$(body "/api/t2-$RUN" -H 'X-User: mallory')" x_user)
both=$(field "$(body "/api/t2-$RUN" -H 'X-User: mallory' -b "$(sess carol-$RUN)")" x_user)
if [ "$with" = "bob-$RUN" ] && [ "$spoof" = null ] && [ "$both" = "carol-$RUN" ]; then
    record 1 "A valid session reaches the origin as X-User; a client's own X-User never does"
else
    record 0 "Requests with a valid session should reach the origin with X-User: <sub>, and no other X-User should get through" \
        "Valid session: X-User $with | no session, client sent X-User: mallory: $spoof | both: $both"
fi

bad=""
for c in "garbage" "a.b.c" "x.!!!.y" "eyJhbGciOiJIUzI1NiJ9.e30" "...."; do
    i=$(code /edge/info -b "lumina_session=$c"); u=$(field "$(body /edge/info -b "lumina_session=$c")" user)
    a=$(code "/api/t3-$RUN" -b "lumina_session=$c")
    [ "$i" = 200 ] && [ "$u" = null ] && [ "$a" = 200 ] || bad="$bad [$c: /edge/info $i user=$u, /api/ $a]"
done
if [ -z "$bad" ]; then
    record 1 "Five malformed session cookies are treated as no session (no errors)"
else
    record 0 "A malformed session cookie should be treated as no session, never as an error" "$bad"
fi

p_beta=$(field "$(body "/api/t4-$RUN" -b "$(sess dana-$RUN --plan beta)")" pool)
p_std=$(field "$(body "/api/t4-$RUN" -b "$(sess dana-$RUN --plan standard)")" pool)
p_none=$(field "$(body "/api/t4-$RUN")" pool)
p_forged=$(field "$(body "/api/t4-$RUN" -b "$(sess dana-$RUN --plan beta --key not-the-key)")" pool)
p_old=$(field "$(body "/api/t4-$RUN" -b "$(sess dana-$RUN --plan beta --ttl -30)")" pool)
if [ "$p_beta" = beta ] && [ "$p_std" = stable ] && [ "$p_none" = stable ] && [ "$p_forged" = stable ] && [ "$p_old" = stable ]; then
    record 1 "Valid beta sessions go to the beta pool; standard, none, forged and expired go to stable"
else
    record 0 "A valid session with plan \"beta\" should go to the beta pool, everything else to stable" \
        "Valid beta: $p_beta | valid standard: $p_std | no session: $p_none | beta signed with another key: $p_forged | expired beta: $p_old"
fi

JTI="t5-$RUN"; S5=$(sess erin-$RUN --jti "$JTI")
before=$(field "$(body "/api/t5-$RUN" -b "$S5")" x_user)
curl -s --max-time 2 "http://$ORIGIN/_revoke?jti=$JTI" >/dev/null
gone=""; t0=$(date +%s.%N)
for _ in $(seq 12); do
    sleep 0.5
    [ "$(field "$(body "/api/t5-$RUN" -b "$S5")" x_user)" = null ] && { gone=$(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN { printf "%.1f", b - a }'); break; }
done
curl -s --max-time 2 "http://$ORIGIN/_unrevoke?jti=$JTI" >/dev/null
back=""; t0=$(date +%s.%N)
if [ -n "$gone" ]; then
    for _ in $(seq 12); do
        sleep 0.5
        [ "$(field "$(body "/api/t5-$RUN" -b "$S5")" x_user)" = "erin-$RUN" ] && { back=$(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN { printf "%.1f", b - a }'); break; }
    done
fi
if [ "$before" = "erin-$RUN" ] && [ -n "$gone" ] && [ -n "$back" ]; then
    record 1 "A revoked session stopped working ${gone}s after listing and came back ${back}s after removal"
else
    record 0 "A session on the origin's revocation list should stop being valid within 5 s, and be valid again within 5 s of removal" \
        "Before: X-User $before | after listing: $([ -n "$gone" ] && echo "invalid after ${gone}s" || echo "still valid after 6 s") | after removal: $([ -n "$back" ] && echo "valid after ${back}s" || echo "not valid again within 6 s")"
fi

echo -e "\n${BLUE}--- Edge functions ---${NC}"
n0=$(seen /edge/info)
anon=$(body /edge/info); signed=$(body /edge/info -b "$(sess frank-$RUN)")
ctype=$(curl -s -o /dev/null -w '%{content_type}' --max-time 5 "http://$EDGE/edge/info")
n1=$(seen /edge/info)
if [ "$(field "$anon" client)" = "$GW_IP" ] && [ "$(field "$anon" user)" = null ] && [ "$(field "$signed" user)" = "frank-$RUN" ] \
   && [ "$n0" = "$n1" ] && echo "$ctype" | grep -q json; then
    record 1 "/edge/info is answered by the edge: client $GW_IP, user null or the session's sub"
else
    record 0 "GET /edge/info should be answered by the edge with JSON: client (the client's address) and user (sub or null)" \
        "Without a session: $(echo "$anon" | head -c 120) | with one: $(echo "$signed" | head -c 120) | Content-Type: $ctype | origin answered it $((n1 - n0)) time(s)"
fi

P="/downloads/t7-$RUN.bin"
good=$(code "$(tools link "$P")")
none=$(code "$P")
L=$(tools link "$P"); wrong=$(code "${L%?}$( [ "${L: -1}" = 0 ] && echo 1 || echo 0)")
moved=$(code "$(echo "$L" | sed "s#$P#/downloads/t7-$RUN-other.bin#")")
otherkey=$(code "$(tools link "$P" --key not-the-key)")
expired=$(code "$(tools link "$P" --ttl -60)")
hits=$(seenp "/downloads/t7-$RUN")
if [ "$good" = 200 ] && [ "$none" = 403 ] && [ "$wrong" = 403 ] && [ "$moved" = 403 ] && [ "$otherkey" = 403 ] && [ "$expired" = 410 ] && [ "$hits" = 1 ]; then
    record 1 "Signed links: valid 200; missing, wrong, moved or other-key 403; expired 410"
else
    record 0 "/downloads/ should serve only valid signed links: bad or missing signature 403, expired 410" \
        "Valid: $good | no signature: $none | wrong signature: $wrong | other path: $moved | other key: $otherkey | expired: $expired | origin received $hits of the 6 (expected 1)"
fi

o0=$(seen /api/orders)
v=$(code /api/orders -H 'Content-Type: application/json' -d '{"qty": 5, "sku": "LUM-1"}')
codes=""
for b in 'not json' '[1, 2]' '{"qty": 0}' '{"qty": 101}' '{"qty": "5"}' '{"qty": 2.5}' '{"sku": "LUM-1"}' ''; do
    codes="$codes $(code /api/orders -H 'Content-Type: application/json' -d "$b")"
done
o1=$(seen /api/orders)
if [ "$v" = 200 ] && [ "$codes" = " 400 400 400 400 400 400 400 400" ] && [ $((o1 - o0)) = 1 ]; then
    record 1 "/api/orders: a valid order reaches the origin; 8 invalid bodies get 400 at the edge"
else
    record 0 "POST /api/orders should accept only a JSON object with an integer qty from 1 to 100; anything else 400 at the edge" \
        "Valid order: $v | invalid ones:$codes (expected 400 x8) | origin received $((o1 - o0)) of them (expected 1)"
fi

acct=$(body /api/account -b "$(sess grace-$RUN)")
left=$(echo "$acct" | grep -oE '([0-9]{4}[ -]?){3}[0-9]{4}' | head -3 | tr '\n' ' ')
masked=$(echo "$acct" | grep -oE '\*\*\*\*-\*\*\*\*-\*\*\*\*-[0-9]{4}' | tr '\n' ' ')
whole=$(field "$acct" x_user)
if [ -z "$left" ] && [ "$masked" = "****-****-****-1111 ****-****-****-0004 ****-****-****-1881 " ] && echo "$acct" | grep -q 'order 1234567890' \
   && [ "$whole" = "grace-$RUN" ]; then
    record 1 "/api/account: three card numbers masked to their last four digits, the response complete"
else
    record 0 "No response under /api/ should carry a full card number (each becomes ****-****-****-<last four>), and responses stay complete" \
        "Unmasked: ${left:-none} | masked: ${masked:-none} | complete JSON: $([ "$whole" = ERR ] && echo no || echo yes) | body: $(echo "$acct" | tr -d '\n ' | tail -c 120)"
fi

echo -e "\n${BLUE}--- Telemetry (TCP :8097) ---${NC}"
t_ok=$(tools tel "dev-t10-$RUN"); t_bad=$(tools tel "dev-t10-$RUN" --sig 0123456789abcdef)
# another device's valid signature, borrowed
t_other=$(tools tel "dev-t10b-$RUN" --sig "$(python3 -c 'import hmac,hashlib,sys; print(hmac.new(sys.argv[1].encode(), sys.argv[2].encode(), hashlib.sha256).hexdigest()[:16])' "$KEY" "dev-t10-$RUN")")
wait
silent=$(cat "$TMP/silent"); ss=$(echo "$silent" | grep -oE 'after [0-9.]+s' | grep -oE '[0-9.]+')
TEL1=$(telem)
if echo "$t_ok" | grep -q '^ACK' && echo "$t_bad" | grep -q '^closed' && echo "$t_other" | grep -q '^closed' \
   && echo "$silent" | grep -q '^closed' && [ -n "$ss" ] && awk -v s="$ss" 'BEGIN { exit !(s <= 6) }' && [ $((TEL1 - TEL0)) = 1 ]; then
    record 1 "Telemetry: a signed HELLO is forwarded; wrong or borrowed signatures and silence (${ss}s) are closed at the edge"
else
    record 0 "Only connections starting with a valid HELLO should reach the telemetry intake; silent clients closed within 5 s" \
        "Valid: $t_ok | wrong sig: $t_bad | another device's sig: $t_other | silent: ${silent:-no result} | intake connections: $((TEL1 - TEL0)) (expected 1)"
fi

echo -e "\n${BOLD}================================================================${NC}"
echo -e "${BOLD}   Requirements: $PASSED / $TOTAL passed${NC}"
echo -e "${BOLD}================================================================${NC}"
if [ "$PASSED" = "$TOTAL" ]; then
    echo -e "${GREEN}${BOLD}Sprint 6 lab gate PASSED${NC}"
elif [ "$PASSED" = 0 ]; then
    echo -e "${GREEN}${BOLD}Sprint 6 start is ready to go:${NC} the lab is up, the config loads, and all $TOTAL requirements are still open."
else
    echo -e "${YELLOW}Sprint 6 lab gate not yet passed: $((TOTAL - PASSED)) requirement(s) to go${NC}"
fi
[ "$PASSED" = "$TOTAL" ]

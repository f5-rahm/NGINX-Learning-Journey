#!/usr/bin/env bash
# ==============================================================================
# Sprint 7 Lab Verification Test Suite: The Tidewater Edge
#
# Usage:   ./test_sprint07.sh
# Targets: the edge on https://localhost:8091 (portal, ops tool) and :8092 (partner
#          API), the apps' counters on 127.0.0.1:8017, and the office address
#          10.57.0.5 on s7-net, all started by lab/lab.sh up.
#
# Runtime: about 15 seconds (two sign-ins through Keycloak).
# ==============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB="$SCRIPT_DIR/lab"
EDGE="${EDGE:-https://localhost:8091}"
PARTNER="${PARTNER:-https://localhost:8092}"
CONTROL="${CONTROL:-http://127.0.0.1:8017}"
CA="$LAB/certs/internal-ca.crt"
PASSED=0
TOTAL=0
TMP=$(mktemp -d)
RUN=$(date +%s)$$

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
cleanup() {
    curl -s -o /dev/null --max-time 2 "$CONTROL/_ledger/impostor?on=0"
    [ -n "${VIEWER:-}" ] && tokens_edit remove
    rm -rf "$TMP"
}
trap cleanup EXIT

# req URL [curl options]: "STATUS BODY" with the body on one line; the body is also in $TMP/body
req() {
    local url="$1"; shift
    local code
    code=$(curl -s --max-time 10 --cacert "$CA" -o "$TMP/body" -w '%{http_code}' "$@" "$url")
    echo "$code $(tr -d '\n' < "$TMP/body")"
}
# pcert NAME: curl options for a partner's client certificate
pcert() { echo "--cert $LAB/certs/$1.crt --key $LAB/certs/$1.key"; }
# field NAME: a top-level field of the JSON in $TMP/body ("ERR" if it isn't JSON)
field() { python3 -c 'import json,sys
try:
    v = json.load(open(sys.argv[1])).get(sys.argv[2], "MISSING")
    print("null" if v is None else (" ".join(v) if isinstance(v, list) else v))
except Exception: print("ERR")' "$TMP/body" "$1"; }
isjson() { python3 -c 'import json,sys; d = json.load(open(sys.argv[1])); sys.exit(0 if isinstance(d, dict) and "error" in d else 1)' "$TMP/body" 2>/dev/null; }
# seen SERVICE METHOD PATH: how many times the apps answered it
seen() { curl -s --max-time 2 "$CONTROL/_stats" | python3 -c 'import json,sys
print(json.load(sys.stdin)["requests"].get(" ".join(sys.argv[1:4]), 0))' "$1" "$2" "$3"; }
authz_calls() { curl -s --max-time 2 "$CONTROL/_stats" | python3 -c 'import json,sys; print(json.load(sys.stdin)["authz"]["calls"])'; }
# tokens_edit add|remove: this run's own ops tokens (a viewer and an admin), so no decision the
# edge cached in an earlier run can answer for them. The authz service rereads the file per call.
tokens_edit() { python3 -c 'import json, os, sys
f, action, viewer, admin = sys.argv[1:5]
t = json.load(open(f))
if action == "add":
    t[viewer] = {"user": "carol", "role": "viewer"}; t[admin] = {"user": "dave", "role": "admin"}
else:
    t.pop(viewer, None); t.pop(admin, None)
tmp = f + ".tmp"
with open(tmp, "w") as out: json.dump(t, out, indent=1)
os.chmod(tmp, 0o600); os.replace(tmp, f)' "$LAB/secrets/ops_tokens.json" "$1" "$VIEWER" "$ADMIN"; }
office() { # PATH: the status code of a request from 10.57.0.5
    docker run --rm --network s7-net --ip 10.57.0.5 -v "$LAB/certs:/certs:ro" curlimages/curl:8.16.0 \
        -s -o /dev/null --max-time 10 --cacert /certs/internal-ca.crt -w '%{http_code}' "https://s7-edge:8091$1" 2>/dev/null
}
# signin USER: walk the sign-in with curl, leaving the session in $TMP/USER.jar; prints where it ended
signin() {
    local jar="$TMP/$1.jar" page action
    page=$(curl -s -L --max-time 10 --cacert "$CA" -c "$jar" -b "$jar" "$EDGE/portal/t10-$RUN")
    action=$(printf '%s' "$page" | grep -o 'action="[^"]*"' | head -1 | sed 's/^action="//; s/"$//; s/&amp;/\&/g')
    [ -n "$action" ] || { echo "no Keycloak login form"; return 1; }
    curl -s -L --max-time 10 --cacert "$CA" -c "$jar" -b "$jar" -o /dev/null -w '%{http_code} %{url_effective}' \
        --data-urlencode "username=$1" --data-urlencode "password=$1-pass" "$action" | sed 's/?.*//'
}

echo -e "${BOLD}Sprint 7 lab: the Tidewater edge${NC}"
echo -e "\n${BLUE}--- Preflight (not scored): lab/lab.sh check ---${NC}"
if ! "$LAB/lab.sh" check; then
    echo -e "\n${RED}${BOLD}Setup problem: the lab isn't ready, so no requirement was tested.${NC}"
    echo -e "${RED}Fix the [!!] items above (start with: cd lab && ./lab.sh up) and run again.${NC}"
    exit 2
fi
curl -s -o /dev/null --max-time 2 "$CONTROL/_ledger/impostor?on=0"
VIEWER="tw-test-view-$RUN"; ADMIN="tw-test-admin-$RUN"
tokens_edit add

echo -e "\n${BLUE}--- Partner API (:8092) ---${NC}"
r=$(req "$PARTNER/t1-$RUN")
if [ "${r%% *}" = 401 ] && isjson && [ "$(seen partners GET "/t1-$RUN")" = 0 ]; then
    record 1 "No client certificate: 401 with a JSON error, and the partner API never sees it"
else
    record 0 "A request without a client certificate should get 401 with a JSON body {\"error\": ...} and never reach the partner API" \
        "got: ${r:0:120} (partner API saw it $(seen partners GET "/t1-$RUN") times)"
fi

rf=$(req "$PARTNER/t2-$RUN" $(pcert fake-acme)); ri=$(req "$PARTNER/t2-$RUN" $(pcert initech))
rf_json=0; req "$PARTNER/t2-$RUN" $(pcert fake-acme) >/dev/null; isjson && rf_json=1
ri_json=0; req "$PARTNER/t2-$RUN" $(pcert initech) >/dev/null; isjson && ri_json=1
rg=$(req "$PARTNER/t2-$RUN" $(pcert globex))
if [ "${rf%% *}" = 403 ] && [ "${ri%% *}" = 403 ] && [ $rf_json = 1 ] && [ $ri_json = 1 ] && [ "${rg%% *}" = 200 ] \
   && [ "$(seen partners GET "/t2-$RUN")" = 1 ]; then
    record 1 "A certificate from another CA and a revoked one: 403 with a JSON error; a valid one is served"
else
    record 0 "Certificates from an untrusted CA (fake-acme) and revoked ones (initech) should get 403 with a JSON error and never reach the API" \
        "fake-acme: ${rf:0:80} | initech: ${ri:0:80} | globex: ${rg%% *} | the API saw /t2 $(seen partners GET "/t2-$RUN") times (expected 1, globex's)"
fi

req "$PARTNER/t3-$RUN" $(pcert acme) -H 'X-Partner: globex' >/dev/null
p_acme=$(field partner); names=$(field partner_cert_names)
req "$PARTNER/t3-$RUN" $(pcert globex) >/dev/null; p_globex=$(field partner)
if [ "$p_acme" = acme ] && [ "$p_globex" = globex ] && [[ "$names" == *"URI:spiffe://partners.tidewater/acme"* ]]; then
    record 1 "The API receives X-Partner (the certificate's CN) and the certificate itself; a client's own X-Partner is ignored"
else
    record 0 "The API should receive X-Partner = the verified certificate's CN, and X-Partner-Cert = the certificate (URL-escaped PEM), whatever the client sent" \
        "acme sending X-Partner: globex -> partner=$p_acme; globex -> partner=$p_globex; names read from X-Partner-Cert: $names"
fi

r1=$(req "$PARTNER/ledger/t4-$RUN" $(pcert acme)); c1=$(field client_certificate); s1=$(field served_as)
curl -s -o /dev/null --max-time 2 "$CONTROL/_ledger/impostor?on=1"
r2=$(req "$PARTNER/ledger/t4-$RUN" $(pcert acme)); s2=$(field served_as)
curl -s -o /dev/null --max-time 2 "$CONTROL/_ledger/impostor?on=0"
r3=$(req "$PARTNER/ledger/t4-$RUN" $(pcert acme))
if [ "${r1%% *}" = 200 ] && [[ "$c1" == *tidewater-edge* ]] && [ "$s1" = ledger ] \
   && [ "${r2%% *}" = 502 ] && [ "${r3%% *}" = 200 ]; then
    record 1 "/ledger/ reaches the ledger with the edge's client certificate, and the edge refuses an impostor ledger"
else
    record 0 "/ledger/ should reach the ledger over TLS with certs/edge-client.crt, and verify the ledger's certificate (internal CA, name ledger.internal)" \
        "real ledger: ${r1%% *} (client cert it saw: $c1) | impostor: ${r2%% *} (served by: $s2, expected 502) | real again: ${r3%% *}"
fi

echo -e "\n${BLUE}--- Ops tool (:8091/ops/) ---${NC}"
n_none=$(req "$EDGE/ops/t5-$RUN" -H 'X-Ops-User: dave' -H 'X-Ops-Role: admin')
n_bogus=$(req "$EDGE/ops/t5-$RUN" -H "Authorization: Bearer tw-made-up-$RUN")
req "$EDGE/ops/t5-$RUN" -H "Authorization: Bearer $VIEWER" -H 'X-Ops-User: dave' -H 'X-Ops-Role: admin' >/dev/null
v_user=$(field ops_user); v_role=$(field ops_role); v_tok=$(field token_received)
req "$EDGE/ops/t5-$RUN" -H "Authorization: Bearer $ADMIN" >/dev/null; a_user=$(field ops_user); a_role=$(field ops_role)
if [ "${n_none%% *}" = 401 ] && [ "${n_bogus%% *}" = 401 ] && [ "$v_user" = carol ] && [ "$v_role" = viewer ] \
   && [ "$a_user" = dave ] && [ "$a_role" = admin ] && [ "$v_tok" = False ] && [ "$(seen ops GET "/ops/t5-$RUN")" = 2 ]; then
    record 1 "/ops/ needs a valid token (401 otherwise); the tool gets X-Ops-User/Role from authz, never the client or the token"
else
    record 0 "/ops/ should ask the authz service (auth_request), pass its X-Ops-User and X-Ops-Role on, and not forward the token" \
        "no token: ${n_none%% *} | made-up token: ${n_bogus%% *} | viewer -> user=$v_user role=$v_role token_received=$v_tok | admin -> user=$a_user role=$a_role | tool saw /t5 $(seen ops GET "/ops/t5-$RUN") times (expected 2)"
fi

vp=$(req "$EDGE/ops/t6-$RUN" -X POST -d 'truck=7' -H "Authorization: Bearer $VIEWER")
vd=$(req "$EDGE/ops/t6-$RUN" -X DELETE -H "Authorization: Bearer $VIEWER")
ap=$(req "$EDGE/ops/t6-$RUN" -X POST -d 'truck=7' -H "Authorization: Bearer $ADMIN"); ab=$(field body_bytes)
if [ "${vp%% *}" = 403 ] && [ "${vd%% *}" = 403 ] && [ "${ap%% *}" = 200 ] && [ "$ab" = 7 ] \
   && [ "$(seen ops POST "/ops/t6-$RUN")" = 1 ] && [ "$(seen ops DELETE "/ops/t6-$RUN")" = 0 ]; then
    record 1 "Viewers can read but not change (POST/DELETE: 403); an admin's POST reaches the tool with its body"
else
    record 0 "A viewer's POST and DELETE should get 403 from authz (it needs the original method), and an admin's POST should arrive with its body" \
        "viewer POST: ${vp%% *} | viewer DELETE: ${vd%% *} | admin POST: ${ap%% *} (body bytes the tool got: $ab, sent 7)"
fi

c0=$(authz_calls); codes=""
for _ in 1 2 3 4 5; do r=$(req "$EDGE/ops/t7-$RUN" -H "Authorization: Bearer tw-made-up-again-$RUN"); codes="$codes${r%% *} "; done
c1=$(authz_calls)
for _ in 1 2 3 4 5; do r=$(req "$EDGE/ops/t7-$RUN" -H "Authorization: Bearer $VIEWER"); codes="$codes${r%% *} "; done
c2=$(authz_calls)
after=$(req "$EDGE/ops/t7-$RUN" -X POST -H "Authorization: Bearer $VIEWER"); other=$(req "$EDGE/ops/t7-$RUN" -H "Authorization: Bearer tw-third-$RUN")
if [ "$codes" = "401 401 401 401 401 200 200 200 200 200 " ] && [ $((c1 - c0)) = 1 ] && [ $((c2 - c1)) = 0 ] \
   && [ "${after%% *}" = 403 ] && [ "${other%% *}" = 401 ]; then
    record 1 "Decisions are cached per token and method: 5 + 5 requests cost 1 authz call, and nothing leaks between them"
else
    record 0 "Cache authz's answers per credential and method for 30 s: repeats shouldn't call authz again, and one token's answer must never apply to another token or method" \
        "statuses: $codes| authz calls: made-up token x5 -> $((c1 - c0)) (expected 1), viewer x5 -> $((c2 - c1)) (expected 0: already asked in test 5) | viewer POST after: ${after%% *} (expected 403) | another made-up token: ${other%% *} (expected 401)"
fi

o_status=$(office /ops/status); h_status=$(req "$EDGE/ops/status"); o_other=$(office "/ops/t8-$RUN")
t_status=$(req "$EDGE/ops/status" -H "Authorization: Bearer $VIEWER")
if [ "$o_status" = 200 ] && [ "${h_status%% *}" = 401 ] && [ "$o_other" = 401 ] && [ "${t_status%% *}" = 200 ]; then
    record 1 "The head office (10.57.0.5) reads /ops/status without a token; elsewhere it needs one, and so does the rest of /ops/"
else
    record 0 "/ops/status should be open to 10.57.0.5 without a token, and need a token from anywhere else; the rest of /ops/ always needs one" \
        "office /ops/status: $o_status | host, no token: ${h_status%% *} | host with viewer token: ${t_status%% *} | office /ops/t8: $o_other"
fi

echo -e "\n${BLUE}--- Staff portal (:8091/portal/) ---${NC}"
anon=$(curl -s -o /dev/null --max-time 10 --cacert "$CA" -L -w '%{http_code} %{url_effective}' "$EDGE/portal/t9-$RUN" | sed 's/?.*//')
end_bob=$(signin bob)
req "$EDGE/portal/t9-$RUN" -b "$TMP/bob.jar" -H 'X-User: alice' -H 'X-Groups: admins' >/dev/null
u=$(field user); g=$(field groups); ck=$(field cookies_received)
if [ "$anon" = "200 $EDGE/realms/tidewater/protocol/openid-connect/auth" ] && [ "$u" = bob ] && [ "$g" = staff ] \
   && [ -z "$ck" ] && [ "$(seen portal GET "/portal/t9-$RUN")" = 1 ]; then
    record 1 "/portal/ sends strangers to the Keycloak login; signed in, the portal sees X-User=bob, X-Groups=staff, and no cookies"
else
    record 0 "/portal/ should require sign-in through OAuth2 Proxy, pass the username (not the subject ID) and groups, and not forward cookies" \
        "anonymous ended at: $anon | sign-in ended at: $end_bob | portal saw user=$u groups=$g cookies=[$ck] | /t9 reached the portal $(seen portal GET "/portal/t9-$RUN") times (expected 1)"
fi

end_alice=$(signin alice)
rb=$(req "$EDGE/portal/admin/t10-$RUN" -b "$TMP/bob.jar")
ra=$(req "$EDGE/portal/admin/t10-$RUN" -b "$TMP/alice.jar"); au=$(field user)
rn=$(curl -s -o /dev/null --max-time 10 --cacert "$CA" -w '%{http_code}' "$EDGE/portal/admin/t10-$RUN")
if [ "${rb%% *}" = 403 ] && [ "${ra%% *}" = 200 ] && [ "$au" = alice ] && [ "$rn" = 302 ] \
   && [ "$(seen portal GET "/portal/admin/t10-$RUN")" = 1 ]; then
    record 1 "/portal/admin/ is for the admins group: bob 403, alice 200, strangers sent to sign in"
else
    record 0 "/portal/admin/ should let in only members of the admins group (403 for other staff, a sign-in redirect for strangers)" \
        "bob: ${rb%% *} | alice: ${ra%% *} (user=$au; sign-in ended at: $end_alice) | anonymous: $rn"
fi

echo
echo -e "${BOLD}Requirements: $PASSED / $TOTAL passed${NC}"
if [ "$PASSED" = "$TOTAL" ]; then
    echo -e "${GREEN}${BOLD}Sprint 7 complete: Tidewater's edge checks who every partner, tool user and staff member is.${NC}"
elif [ "$PASSED" = 0 ]; then
    echo -e "${GREEN}${BOLD}Sprint 7 start is ready to go${NC}: the lab is up and every requirement is waiting for you."
fi
[ "$PASSED" = "$TOTAL" ]

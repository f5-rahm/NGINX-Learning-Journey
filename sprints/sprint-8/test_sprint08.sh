#!/usr/bin/env bash
# ==============================================================================
# Sprint 8 Lab Verification Test Suite: Copperline Transit's Edge
#
# Usage:   ./test_sprint08.sh            (from sprints/sprint-8, on the host)
# Targets: the kind cluster "s8" (kubectl context kind-s8) and F5 NGINX Ingress
#          Controller on 127.0.0.1:8098 (HTTP) and :8099 (HTTPS), started by
#          lab/lab.sh up.
#
# Runtime: about 90 seconds. Test 8 restarts arrivals-v1 (a rolling restart) and
#          test 9 makes one arrivals pod fail for a while, then repairs it.
# ==============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB="$SCRIPT_DIR/lab"
HOST=transit.copperline.test
HTTPS_PORT="${HTTPS_PORT:-8099}"
HTTP_PORT="${HTTP_PORT:-8098}"
CA="$LAB/certs/ca.crt"
K="kubectl --context kind-s8"
PASSED=0
TOTAL=0
TMP=$(mktemp -d)
RUN=$(date +%s)
FAILPOD=""

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
podctl() { $K -n transit exec "$1" -- python3 -c "import urllib.request as u; print(u.urlopen(u.Request('http://127.0.0.1:8080$2', method='$3')).read().decode().replace(chr(10),''))" 2>/dev/null; }
served() { podctl "$1" /_ctl/stats GET | python3 -c 'import json,sys; print(json.load(sys.stdin)["served"])' 2>/dev/null || echo "?"; }
cleanup() {
    [ -n "$FAILPOD" ] && podctl "$FAILPOD" "/_ctl/fail?on=0" POST >/dev/null
    jobs -p | xargs -r kill 2>/dev/null
    rm -rf "$TMP"
}
trap cleanup EXIT

# req PATH [curl options]: "STATUS" over HTTPS; the body is in $TMP/body, headers in $TMP/hdr
req() {
    local p="$1"; shift
    curl -s --max-time 20 --resolve "$HOST:$HTTPS_PORT:127.0.0.1" --cacert "$CA" -o "$TMP/body" -D "$TMP/hdr" \
         -w '%{http_code}' "$@" "https://$HOST:$HTTPS_PORT$p"
}
# field NAME: a top-level field of the JSON body ("-" if missing, "ERR" if not JSON)
field() { python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get(sys.argv[2], "-"))
except Exception: print("ERR")' "$TMP/body" "$1"; }
hdr_in_body() { python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1]))["headers"].get(sys.argv[2], "-"))
except Exception: print("ERR")' "$TMP/body" "$1"; }

echo -e "${BOLD}${BLUE}Sprint 8: Copperline Transit's Edge${NC}"
echo -e "${BLUE}Setup check (lab/lab.sh check)${NC}"
if ! "$LAB/lab.sh" check >"$TMP/check" 2>&1; then
    cat "$TMP/check"
    echo -e "${RED}${BOLD}The lab isn't ready, so nothing was tested.${NC} Start it with: cd $LAB && ./lab.sh up"
    exit 2
fi
echo -e "  ${GREEN}cluster, applications and NGINX Ingress Controller ready${NC}"
echo -e "${BLUE}Requirements${NC}"

# --- 1. HTTPS with Copperline's certificate; HTTP redirected -------------------------------
stype=$($K -n transit get secret transit-tls -o jsonpath='{.type}' 2>/dev/null)
want=$(openssl x509 -in "$LAB/certs/transit.crt" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
got=$(echo | timeout 5 openssl s_client -connect 127.0.0.1:$HTTPS_PORT -servername $HOST 2>/dev/null \
      | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
c=$(req /t1-$RUN)
redir=$(curl -s -o /dev/null --max-time 5 -w '%{http_code} %{redirect_url}' -H "Host: $HOST" "http://127.0.0.1:$HTTP_PORT/t1-$RUN")
if [ "$stype" = kubernetes.io/tls ] && [ -n "$got" ] && [ "$got" = "$want" ] && [ "$c" != 000 ] \
   && [ "${redir%% *}" = 301 ] && [[ "${redir#* }" == https://$HOST* ]]; then
    record 1 "HTTPS serves lab/certs/transit.crt from Secret transit/transit-tls; HTTP answers 301 to https://"
else
    record 0 "$HOST should be served over HTTPS with lab/certs/transit.crt, stored in Secret transit-tls (namespace transit), and HTTP should get a 301 to HTTPS" \
        "Secret type: ${stype:-missing} | certificate served matches transit.crt: $([ -n "$got" ] && [ "$got" = "$want" ] && echo yes || echo "no${got:+ (a different one)}") | HTTPS status: $c | HTTP: $redir"
fi

# --- 2. One VirtualServer with its class, and the routes ----------------------------------
vs=$($K -n transit get virtualserver transit -o jsonpath='{.spec.ingressClassName} {.status.state}' 2>/dev/null)
c1=$(req /t2-$RUN); a1=$(field app)
c2=$(req /arrivals/t2-$RUN -H 'X-Canary: no'); a2=$(field app)
c3=$(req /dispatch/t2-$RUN -u dispatcher:radio-check); a3=$(field app)
if [ "$vs" = "nginx Valid" ] && [ "$c1 $a1" = "200 web" ] && [ "$c2 $a2" = "200 arrivals" ] && [ "$c3 $a3" = "200 dispatch" ]; then
    record 1 "VirtualServer transit (class nginx, Valid): / → web, /arrivals → arrivals, /dispatch → dispatch"
else
    record 0 "A VirtualServer named transit (namespace transit) should name ingress class nginx, be Valid, and route / to web, /arrivals to arrivals, /dispatch to dispatch" \
        "VirtualServer class/state: '${vs:-missing}' | /: $c1 $a1 | /arrivals: $c2 $a2 | /dispatch (signed in): $c3 $a3"
fi

# --- 3. /fares delegated to the fares team ---------------------------------------------------
vsr=$($K -n fares get virtualserverroute -o jsonpath='{range .items[*]}{.spec.host} {.status.state}{"\n"}{end}' 2>/dev/null | grep -c "^$HOST Valid$")
deleg=$($K -n transit get virtualserver transit -o jsonpath='{range .spec.routes[*]}{.path}={.route}{" "}{end}' 2>/dev/null)
c=$(req /fares/t3-$RUN); a=$(field app)
if [ "$c $a" = "200 fares" ] && [ "$vsr" -ge 1 ] && [[ "$deleg" == */fares=fares/* ]]; then
    record 1 "/fares is a VirtualServerRoute in namespace fares, delegated from the VirtualServer, and reaches the fares app"
else
    record 0 "/fares should be defined by the fares team: a VirtualServerRoute in namespace fares, referenced from the transit VirtualServer, reaching the fares service" \
        "/fares: $c $a | Valid VirtualServerRoutes for $HOST in fares: $vsr | VirtualServer routes: ${deleg:-none}"
fi

# --- 4. Fares rate limit ------------------------------------------------------------------------
sleep 3
start=$(date +%s%N)
for i in $(seq 30); do curl -s -o /dev/null --max-time 5 -w '%{http_code}\n' --resolve "$HOST:$HTTPS_PORT:127.0.0.1" --cacert "$CA" "https://$HOST:$HTTPS_PORT/fares/t4-$RUN"; done > "$TMP/t4"
ms=$(( ($(date +%s%N) - start) / 1000000 ))
f200=$(grep -c '^200$' "$TMP/t4"); f429=$(grep -c '^429$' "$TMP/t4"); fother=$((30 - f200 - f429))
for i in $(seq 30); do curl -s -o /dev/null --max-time 5 -w '%{http_code}\n' --resolve "$HOST:$HTTPS_PORT:127.0.0.1" --cacert "$CA" -H 'X-Canary: no' "https://$HOST:$HTTPS_PORT/arrivals/t4-$RUN"; done > "$TMP/t4a"
a429=$(grep -c '^429$' "$TMP/t4a")
sleep 3; after=$(req /fares/t4b-$RUN)
if [ "$f200" -ge 10 ] && [ "$f200" -le 20 ] && [ "$f429" -ge 8 ] && [ "$fother" = 0 ] && [ "$ms" -lt 1500 ] && [ "$a429" = 0 ] && [ "$after" = 200 ]; then
    record 1 "/fares: 30 quick requests → $f200 × 200 and $f429 × 429 in ${ms} ms (the burst isn't paced); /arrivals isn't limited; /fares recovers"
else
    record 0 "/fares should allow each client 5 requests/s plus a burst of 10 served without delay, and answer 429 beyond that; other paths aren't limited" \
        "30 quick /fares requests: $f200 × 200, $f429 × 429, $fother other, in ${ms} ms (a burst served without delay takes well under 1.5 s) | /arrivals 429s: $a429 | /fares 3 s later: $after"
fi

# --- 5. The canary ----------------------------------------------------------------------------
hv2=0; cv2=0
for i in $(seq 10); do req /arrivals/t5-$RUN -H 'X-Canary: always' >/dev/null; [ "$(field version)" = v2 ] && hv2=$((hv2 + 1)); done
for i in $(seq 10); do req /arrivals/t5-$RUN -b 'canary=always' >/dev/null; [ "$(field version)" = v2 ] && cv2=$((cv2 + 1)); done
v1=0; v2=0; other=0
for i in $(seq 200); do
    req /arrivals/t5-$RUN >/dev/null
    case "$(field app) $(field version)" in "arrivals v1") v1=$((v1 + 1));; "arrivals v2") v2=$((v2 + 1));; *) other=$((other + 1));; esac
done
if [ "$hv2" = 10 ] && [ "$cv2" = 10 ] && [ "$other" = 0 ] && [ "$v2" -ge 6 ] && [ "$v2" -le 40 ]; then
    record 1 "Canary: X-Canary: always → v2 (10/10), cookie canary=always → v2 (10/10), everyone else $v1 × v1 / $v2 × v2 of 200"
else
    record 0 "/arrivals should send X-Canary: always and cookie canary=always to v2, and about 10% of other requests to v2 (the rest to v1)" \
        "header → v2: $hv2/10 | cookie → v2: $cv2/10 | 200 plain requests: v1 $v1, v2 $v2 (expected 6–40), other $other"
fi

# --- 6. Dispatch sign-in ------------------------------------------------------------------------
n=$(req /dispatch/t6-$RUN)
w=$(req /dispatch/t6-$RUN -u dispatcher:wrong-password)
y=$(req /dispatch/t6-$RUN -u dispatcher:radio-check); ya=$(field app); auth=$(hdr_in_body Authorization)
if [ "$n" = 401 ] && [ "$w" = 401 ] && [ "$y $ya" = "200 dispatch" ] && [ "$auth" = "-" ]; then
    record 1 "/dispatch: 401 without or with a wrong password; dispatcher/radio-check gets in, and the app never sees the Authorization header"
else
    record 0 "/dispatch should require Basic sign-in with lab/secrets/htpasswd (401 otherwise), and the dispatch app should never receive the credentials" \
        "no credentials: $n | wrong password: $w | dispatcher/radio-check: $y $ya | Authorization the app received: $auth"
fi

# --- 7. Five seconds at most for arrivals --------------------------------------------------------
t0=$(date +%s%N); s1=$(req "/arrivals/slow/t7-$RUN?ms=9000" -H 'X-Canary: no'); e1=$(( ($(date +%s%N) - t0) / 1000000 ))
t0=$(date +%s%N); s2=$(req "/arrivals/slow/t7-$RUN?ms=9000" -H 'X-Canary: always'); e2=$(( ($(date +%s%N) - t0) / 1000000 ))
if [ "$s1" = 504 ] && [ "$s2" = 504 ] && [ "$e1" -ge 4500 ] && [ "$e1" -le 7500 ] && [ "$e2" -ge 4500 ] && [ "$e2" -le 7500 ]; then
    record 1 "A 9-second arrivals answer: 504 after ${e1} ms (v1) and ${e2} ms (v2)"
else
    record 0 "NGINX should wait at most 5 seconds for either arrivals version, then answer 504 (the client must have its answer within about 5 s)" \
        "v1: $s1 after ${e1} ms | v2: $s2 after ${e2} ms (expected 504 after 4.5–7.5 s)"
fi

# --- 8. Zero-downtime restart of arrivals-v1 ------------------------------------------------------
pre=$(req /arrivals/t8-$RUN -X POST -d 'trip=42')
if [ "$pre" != 200 ]; then
    record 0 "A rolling restart of arrivals-v1 under steady traffic (including POSTs) should not fail a single request" \
        "a POST to /arrivals answered $pre before the restart, so the restart wasn't tried"
else
    before=$($K -n transit get pods -l app=arrivals,version=v1 -o jsonpath='{.items[*].metadata.name}')
    for w in 1 2 3; do
        ( while [ ! -e "$TMP/stop8" ]; do
            curl -s -o /dev/null --max-time 10 -w '%{http_code}\n' --resolve "$HOST:$HTTPS_PORT:127.0.0.1" --cacert "$CA" \
                 -X POST -d 'trip=42' -H 'X-Canary: no' "https://$HOST:$HTTPS_PORT/arrivals/slow/t8-$RUN?ms=200" || echo "000"
          done >> "$TMP/t8.$w" ) &
    done
    sleep 2
    $K -n transit rollout restart deploy/arrivals-v1 >/dev/null
    $K -n transit rollout status deploy/arrivals-v1 --timeout=180s >/dev/null 2>&1; rs=$?
    sleep 6; touch "$TMP/stop8"; wait
    after=$($K -n transit get pods -l app=arrivals,version=v1 -o jsonpath='{.items[*].metadata.name}')
    cat "$TMP"/t8.* > "$TMP/t8"
    total=$(wc -l < "$TMP/t8"); ok200=$(grep -c '^200$' "$TMP/t8"); bad=$(grep -v '^200$' "$TMP/t8" | sort | uniq -c | tr -s ' ' | tr '\n' ',')
    if [ "$rs" = 0 ] && [ "$before" != "$after" ] && [ "$total" -ge 30 ] && [ "$ok200" = "$total" ]; then
        record 1 "Rolling restart of arrivals-v1 under steady POSTs: $total/$total answered 200"
    else
        record 0 "A rolling restart of arrivals-v1 under steady traffic (including POSTs) should not fail a single request" \
            "rollout finished: $([ $rs = 0 ] && echo yes || echo no) | requests: $total, 200: $ok200, others:${bad:- none}"
    fi
fi

# --- 9. A half-broken arrivals pod -----------------------------------------------------------------
pre=$(req /arrivals/t9-$RUN -H 'X-Canary: no')
FAILPOD=$($K -n transit get pods -l app=arrivals,version=v1 -o json 2>/dev/null | python3 -c 'import json,sys
for p in json.load(sys.stdin)["items"]:
    ready = any(c["type"] == "Ready" and c["status"] == "True" for c in p["status"].get("conditions", []))
    if ready and not p["metadata"].get("deletionTimestamp"):
        print(p["metadata"]["name"]); break' 2>/dev/null)
if [ "$pre" != 200 ] || [ -z "$FAILPOD" ]; then
    record 0 "When one arrivals pod answers 500 to everything, clients should still get 200, and that pod should be left alone for at least 30 s" \
        "/arrivals answered $pre before the test, so it wasn't tried"
    FAILPOD=""
else
    s0=$(served "$FAILPOD")
    podctl "$FAILPOD" "/_ctl/fail?on=1" POST >/dev/null
    for i in $(seq 30); do curl -s -o /dev/null --max-time 10 -w '%{http_code}\n' --resolve "$HOST:$HTTPS_PORT:127.0.0.1" --cacert "$CA" -H 'X-Canary: no' "https://$HOST:$HTTPS_PORT/arrivals/t9-$RUN"; done > "$TMP/t9"
    sleep 15
    for i in $(seq 30); do curl -s -o /dev/null --max-time 10 -w '%{http_code}\n' --resolve "$HOST:$HTTPS_PORT:127.0.0.1" --cacert "$CA" -H 'X-Canary: no' "https://$HOST:$HTTPS_PORT/arrivals/t9-$RUN"; done >> "$TMP/t9"
    s1=$(served "$FAILPOD")
    podctl "$FAILPOD" "/_ctl/fail?on=0" POST >/dev/null; fp=$FAILPOD; FAILPOD=""
    ok200=$(grep -c '^200$' "$TMP/t9"); e500=$(grep -c '^500$' "$TMP/t9"); hits=$(( s1 - s0 ))
    if [ "$ok200" = 60 ] && [ "$hits" -le 1 ]; then
        record 1 "One arrivals pod answering 500: 60/60 clients got 200, and it was sent $hits request(s) in 15+ s"
    else
        record 0 "When one arrivals pod answers 500 to everything (its readiness probe still passes), clients should still get 200, and that pod should be left alone for at least 30 s" \
            "60 requests: $ok200 × 200, $e500 × 500 | the failing pod ($fp) received $hits requests in 15+ s (expected at most 1: the first, which failed over)"
    fi
fi

# --- 10. No version in the Server header -----------------------------------------------------------
req /t10-$RUN >/dev/null; s_vs=$(grep -i '^server:' "$TMP/hdr" | tr -d '\r' | cut -d' ' -f2-)
s_def=$(curl -s -o /dev/null -D - --max-time 5 "http://127.0.0.1:$HTTP_PORT/" | grep -i '^server:' | tr -d '\r' | cut -d' ' -f2-)
if [ "$s_vs" = nginx ] && [ "$s_def" = nginx ]; then
    record 1 "Server: nginx (no version), on $HOST and on the controller's default server"
else
    record 0 "The Server header should say nginx without a version, for every host the controller serves" \
        "$HOST: '${s_vs:-none}' | default server (http://127.0.0.1:$HTTP_PORT/): '${s_def:-none}'"
fi

echo
echo -e "${BOLD}Requirements: $PASSED / $TOTAL passed${NC}"
if [ "$PASSED" = "$TOTAL" ]; then
    echo -e "${GREEN}${BOLD}Sprint 8 complete: Copperline Transit's edge runs on F5 NGINX Ingress Controller, canary and all.${NC}"
elif [ "$PASSED" = 0 ]; then
    echo -e "${GREEN}${BOLD}Sprint 8 start is ready to go${NC}: the lab is up and every requirement is waiting for you."
fi
[ "$PASSED" = "$TOTAL" ]

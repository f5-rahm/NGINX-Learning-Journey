#!/usr/bin/env bash
# ==============================================================================
# Sprint 3 Lab Verification Test Suite: Lumina zero-trust edge
#
# Usage:   ./test_sprint03.sh
# Targets: HTTP_PORT (8083), TLS_PORT (8443), PIDFILE (lab/logs/nginx.pid)
#
# Starts the Sprint 2 mock backends if they aren't running (and stops the ones
# it started). Test 7 reloads your NGINX once (SIGHUP to the pid in PIDFILE).
# HTTP/3 tests run curl in a container ($H3_IMAGE), because the host curl has none.
# ==============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB="$SCRIPT_DIR/lab"
MOCKS="$SCRIPT_DIR/../sprint-2/lab/mocks.sh"
HTTP_PORT="${HTTP_PORT:-8083}"
TLS_PORT="${TLS_PORT:-8443}"
PIDFILE="${PIDFILE:-$LAB/logs/nginx.pid}"
MANAGE_MOCKS="${MANAGE_MOCKS:-1}"
H3_IMAGE="${H3_IMAGE:-alpine/curl-http3:8.11.0}"
CA="$LAB/certs/ca.crt"
NAME=lumina.local
BASE="https://$NAME:$TLS_PORT"
PASSED=0
TOTAL=0
STARTED_MOCKS=()

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
    if [ ${#STARTED_MOCKS[@]} -gt 0 ]; then
        echo -e "\n${BLUE}[*] Stopping mock backends this run started: ${STARTED_MOCKS[*]}${NC}"
        "$MOCKS" stop "${STARTED_MOCKS[@]}" >/dev/null
    fi
}
trap cleanup EXIT

c() { curl -s --max-time 5 --cacert "$CA" --resolve "$NAME:$TLS_PORT:127.0.0.1" "$@"; }

# One handshake. Prints "OK <protocol> <cipher> <sigtype>" or "FAIL".
# TLS 1.3 tickets arrive after the handshake, so the connection stays open briefly.
hs() {
    local sni=(-servername "${SNI-$NAME}"); [ -z "${SNI-$NAME}" ] && sni=(-noservername)
    (sleep 0.3) | openssl s_client -connect "127.0.0.1:$TLS_PORT" "${sni[@]}" -CAfile "$CA" "$@" 2>&1 | awk '
        /^(New|Reused), / { split($0, a, ", "); sub(/Cipher is /, "", a[3]); cipher = a[3] }
        /^ +Protocol +:/   { ver = $NF }
        /Peer signature type/ { sig = $NF }
        END { if (cipher == "" || cipher == "(NONE)") print "FAIL"; else print "OK", ver, cipher, sig }'
}

h3() {
    timeout 30 docker run --rm --network host --add-host "$NAME:127.0.0.1" -v "$LAB/certs:/certs:ro" "$H3_IMAGE" \
        curl -s --max-time 6 --cacert /certs/ca.crt "$@" 2>/dev/null
}

hdr() { grep -i "^$1:" <<<"$2" | head -1 | cut -d: -f2- | tr -d '\r' | sed 's/^ *//'; }

field() { python3 -c 'import json,sys
try: print(json.load(sys.stdin)'"$1"')
except Exception: print("")'; }

echo -e "${BOLD}================================================================${NC}"
echo -e "${BOLD}   Sprint 3: TLS, HTTP/2, HTTP/3 & Edge Hardening Test Runner${NC}"
echo -e "${BOLD}================================================================${NC}"

[ -f "$CA" ] || { echo -e "${RED}[ERROR] $CA not found. Run lab/make_certs.sh first.${NC}"; exit 1; }

if [ "$MANAGE_MOCKS" = 1 ]; then
    for port in 8001 8002 8003; do
        if ! "$MOCKS" status "$port" | grep -q UP; then
            "$MOCKS" start "$port" >/dev/null && STARTED_MOCKS+=("$port")
        fi
    done
    [ ${#STARTED_MOCKS[@]} -gt 0 ] && echo -e "${BLUE}[*] Started mock backends: ${STARTED_MOCKS[*]}${NC}"
fi

if ! c -o /dev/null "$BASE/healthz"; then
    echo -e "${RED}[ERROR] NGINX is not answering HTTPS at $BASE${NC}"
    echo -e "  cd $LAB && ngx -t && ngx"
    exit 1
fi

echo -e "\n${BLUE}--- HTTP to HTTPS ---${NC}"
R=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -H "Host: $NAME" "http://127.0.0.1:$HTTP_PORT/courses/42?ref=mail")
if [ "$R" = "301 $BASE/courses/42?ref=mail" ]; then
    record 1 "Port $HTTP_PORT answers 301 to $BASE with the path and query kept"
else
    record 0 "Port $HTTP_PORT should answer 301 to $BASE/courses/42?ref=mail" "Got: $R"
fi

echo -e "\n${BLUE}--- TLS policy ---${NC}"
T13=$(hs); T11=$(hs -tls1_1 -cipher 'DEFAULT@SECLEVEL=0')
if [[ "$T13" == "OK TLSv1.3"* ]] && [ "$T11" = FAIL ]; then
    record 1 "TLS 1.3 negotiated; TLS 1.1 refused"
else
    record 0 "Default handshake should be TLS 1.3 and TLS 1.1 must be refused" "default: $T13 | TLS 1.1: $T11"
fi

GCM=$(hs -tls1_2 -cipher ECDHE-ECDSA-AES128-GCM-SHA256); CBC=$(hs -tls1_2 -cipher 'ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES128-SHA')
if [[ "$GCM" == "OK TLSv1.2"* ]] && [ "$CBC" = FAIL ]; then
    record 1 "TLS 1.2 accepts an ECDHE AEAD suite and refuses CBC suites"
else
    record 0 "TLS 1.2 should allow ECDHE with AEAD ciphers only" "GCM: $GCM | CBC: $CBC"
fi

ECC=$(hs -sigalgs ecdsa_secp256r1_sha256); RSA=$(hs -sigalgs rsa_pss_rsae_sha256:rsa_pkcs1_sha256)
if [[ "$ECC" == *" ECDSA" ]] && [[ "$RSA" == *" RSA-PSS" || "$RSA" == *" RSA" ]]; then
    record 1 "Both certificates served: ECDSA to ECDSA clients, RSA to RSA-only clients"
else
    record 0 "lumina.local should present an ECDSA and an RSA certificate" "ECDSA client: $ECC | RSA-only client: $RSA"
fi

BAD=$(SNI=unknown.example hs); NONE=$(SNI= hs)
if [ "$BAD" = FAIL ] && [ "$NONE" = FAIL ]; then
    record 1 "TCP handshakes with an unknown SNI name or no SNI are refused"
else
    record 0 "Handshakes for other names, or without SNI, should be refused" "unknown name: $BAD | no SNI: $NONE"
fi

echo -e "\n${BLUE}--- Session resumption ---${NC}"
SESS=$(mktemp)
(sleep 0.3) | openssl s_client -connect "127.0.0.1:$TLS_PORT" -servername $NAME -CAfile "$CA" -sess_out "$SESS" >/dev/null 2>&1
if [ -f "$PIDFILE" ] && kill -HUP "$(cat "$PIDFILE")" 2>/dev/null; then
    sleep 1.5
    REUSE=$((sleep 0.3) | openssl s_client -connect "127.0.0.1:$TLS_PORT" -servername $NAME -CAfile "$CA" -sess_in "$SESS" 2>&1 | grep -oE '^(Reused|New)' | head -1)
    if [ "$REUSE" = Reused ]; then
        record 1 "A session from before a reload resumes after it"
    else
        record 0 "Sessions should still resume after a reload" "Reconnect after reload: ${REUSE:-no handshake}"
    fi
else
    record 0 "Sessions should still resume after a reload" "Could not reload: no running NGINX pid in $PIDFILE"
fi
rm -f "$SESS"

echo -e "\n${BLUE}--- HTTP/2 and HTTP/3 ---${NC}"
V=$(c -o /dev/null -w '%{http_version}' "$BASE/")
if [ "$V" = 2 ]; then
    record 1 "HTTP/2 negotiated through ALPN"
else
    record 0 "Clients offering h2 should get HTTP/2" "Negotiated HTTP/${V:-none}"
fi

if ! command -v docker >/dev/null; then
    record 0 "HTTP/3 over QUIC on UDP $TLS_PORT, advertised with Alt-Svc" "docker not found: the HTTP/3 tests need it"
    record 0 "QUIC handshakes with an unknown SNI name are refused" "docker not found"
else
    H3V=$(h3 --http3-only -o /dev/null -w '%{http_version}' "$BASE/healthz")
    ALTSVC=$(hdr alt-svc "$(c -D - -o /dev/null "$BASE/")")
    if [ "$H3V" = 3 ] && [[ "$ALTSVC" == *"h3=\":$TLS_PORT\""* ]]; then
        record 1 "HTTP/3 answers on UDP $TLS_PORT and Alt-Svc advertises it ($ALTSVC)"
    else
        record 0 "HTTP/3 should answer on UDP $TLS_PORT and be advertised with Alt-Svc h3=\":$TLS_PORT\"" \
            "HTTP/3 request: ${H3V:-failed} | Alt-Svc: ${ALTSVC:-missing}"
    fi
    H3BAD=$(h3 --http3-only -k --resolve "unknown.example:$TLS_PORT:127.0.0.1" -o /dev/null -w '%{http_code}' "https://unknown.example:$TLS_PORT/")
    if [ "$H3V" != 3 ]; then
        record 0 "QUIC handshakes with an unknown SNI name are refused" "Can't check: HTTP/3 itself isn't working yet (test above)"
    elif [ -z "$H3BAD" ] || [ "$H3BAD" = 000 ]; then
        record 1 "QUIC handshakes with an unknown SNI name are refused"
    else
        record 0 "QUIC handshakes with an unknown SNI name should be refused too" "unknown.example over HTTP/3 got HTTP $H3BAD"
    fi
fi

echo -e "\n${BLUE}--- Response headers ---${NC}"
MISSING=""
for path in / /healthz /api/v1/headers "/api/v1/missing?status=404" "/api/v1/broken?status=502"; do
    H=$(c -D - -o /dev/null "$BASE$path")
    HSTS=$(hdr strict-transport-security "$H"); MAXAGE=$(grep -oE 'max-age=[0-9]+' <<<"$HSTS" | cut -d= -f2)
    M=""
    [ "${MAXAGE:-0}" -ge 31536000 ] 2>/dev/null || M+=" HSTS"
    [ "$(hdr x-content-type-options "$H" | tr A-Z a-z)" = nosniff ] || M+=" nosniff"
    [ "$(hdr x-frame-options "$H" | tr a-z A-Z)" = DENY ] || M+=" X-Frame-Options"
    [ -n "$M" ] && MISSING+="$path ->$M; "
done
if [ -z "$MISSING" ]; then
    record 1 "HSTS, nosniff and X-Frame-Options on pages, API responses, and 404/502 errors"
else
    record 0 "Security headers must be on every HTTPS response, errors included" "Missing: $MISSING"
fi

H=$(c -D - -o /dev/null "$BASE/api/v1/headers")
SERVER=$(hdr server "$H"); HANDLED=$(hdr x-handled-by "$H")
if [ "$SERVER" = nginx ] && [ -z "$HANDLED" ]; then
    record 1 "Server header has no version and X-Handled-By is not exposed"
else
    record 0 "Server should read just 'nginx', and X-Handled-By must not reach clients" \
        "Server: ${SERVER:-none} | X-Handled-By: ${HANDLED:-none}"
fi

echo -e "\n${BLUE}--- Lumina services over HTTPS ---${NC}"
HZ=$(c "$BASE/healthz" | field '["status"]'); BODY=$(c "$BASE/api/v1/proto")
XFP=$(field '["headers"].get("X-Forwarded-Proto")' <<<"$BODY"); NODE=$(field '["node"]' <<<"$BODY")
if [ "$HZ" = healthy ] && [[ "$NODE" == api-node-* ]] && [ "$XFP" = https ]; then
    record 1 "/healthz is healthy, and /api/v1/ reaches $NODE with X-Forwarded-Proto: https"
else
    record 0 "/healthz should be healthy, and the API should see X-Forwarded-Proto: https" \
        "healthz status: ${HZ:-none} | node: ${NODE:-none} | X-Forwarded-Proto: ${XFP:-none}"
fi

WS=$(c -i -N --http1.1 --max-time 2 -H "Connection: Upgrade" -H "Upgrade: websocket" \
    -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" "$BASE/ws/chat" | tr -d '\r')
if grep -q "101 Switching Protocols" <<<"$WS" && grep -q "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" <<<"$WS" \
   && grep -q "welcome from chat-ws" <<<"$WS"; then
    record 1 "wss://$NAME:$TLS_PORT/ws/chat upgrades (101) and relays the welcome frame"
else
    record 0 "/ws/chat should upgrade over TLS and relay the backend's welcome frame" "Response: $(head -n1 <<<"$WS")"
fi

echo -e "\n${BOLD}================================================================${NC}"
echo -e "${BOLD}   Core: $PASSED / $TOTAL passed${NC}"
echo -e "${BOLD}================================================================${NC}"
[ "$PASSED" = "$TOTAL" ] && echo -e "${GREEN}Sprint 3 lab gate PASSED${NC}" || echo -e "${RED}Sprint 3 lab gate not yet passed${NC}"
[ "$PASSED" = "$TOTAL" ]

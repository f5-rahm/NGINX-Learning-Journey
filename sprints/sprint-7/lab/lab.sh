#!/usr/bin/env bash
# Sprint 7 lab: the Tidewater Logistics edge (nginx:mainline) and everything behind it.
#
#   ./lab.sh up                  # certificates, network, apps, identity provider, SSO proxy, edge, then the ready check
#   ./lab.sh check               # ready check: config loads, edge answers on both ports, apps, IdP and SSO proxy are up
#   ./lab.sh reload              # nginx -t, then reload, inside the edge container
#   ./lab.sh t | T               # nginx -t / nginx -T inside the edge container
#   ./lab.sh edge                # recreate only the edge
#   ./lab.sh down                # remove the containers and the network (certs/ and secrets/ stay)
#
#   ./lab.sh pki                 # make a new lab PKI in certs/ (then: ./lab.sh up)
#   ./lab.sh stats               # the apps' counters: requests per service and path, authz calls
#   ./lab.sh reset               # zero the apps' counters
#   ./lab.sh impostor on|off     # the ledger presents a certificate from the rogue CA instead of its own
#   ./lab.sh logs [edge|apps|idp|sso|plus]   # follow container output
#
# Enterprise side quest (NGINX Plus, ~/plus/license.jwt, docs/nginx-plus-lab.md):
#   ./lab.sh plus up|down        # s7-plus (10.57.0.60): :8094 HTTPS, Plus API 127.0.0.1:8085; config lab/plus/nginx.conf
#   ./lab.sh plus reload | t     # nginx -t + reload / nginx -t inside s7-plus
#
# The network (s7-net, 10.57.0.0/16):
#   10.57.0.10  s7-edge   :8091 HTTPS (staff portal, ops tool, the IdP's front door), :8092 HTTPS (partner API)
#   10.57.0.20  s7-apps   partners :9001, ops :9002, portal :9003, authz :9100, ledger :9443 (TLS), control 127.0.0.1:8017
#   10.57.0.30  s7-idp    Keycloak, realm "tidewater"; admin console on http://localhost:8031 (admin / admin-lab)
#   10.57.0.40  s7-sso    OAuth2 Proxy :4180
#   10.57.0.5   (office)  the head office's address, used by "office" in helpers.sh
#
# certs/ (made by pki.sh) and secrets/ (ops tokens, SSO cookie secret) are created on the first up, not in git.
set -u

LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME="${HOME:-$(getent passwd "$(id -u)" | cut -d: -f6)}"
NET=s7-net
SUBNET=10.57.0.0/16
EDGE=s7-edge;  EDGE_IP=10.57.0.10
APPS=s7-apps;  APPS_IP=10.57.0.20
IDP=s7-idp;    IDP_IP=10.57.0.30
SSO=s7-sso;    SSO_IP=10.57.0.40
PORTAL_PORT=8091
PARTNER_PORT=8092
CONTROL_PORT=8017
IDP_ADMIN_PORT=8031
NGINX_IMAGE="${NGINX_IMAGE:-nginx:mainline}"
PY_IMAGE="${PY_IMAGE:-python:3.12-alpine}"
KC_IMAGE="${KC_IMAGE:-quay.io/keycloak/keycloak:26.8.2}"
O2P_IMAGE="${O2P_IMAGE:-quay.io/oauth2-proxy/oauth2-proxy:v7.15.6}"
FRONT="https://localhost:$PORTAL_PORT"
REALM=tidewater
NGX=(nginx -p /lab/ -c nginx.conf -e logs/error.log)
PLUS=s7-plus;  PLUS_IP=10.57.0.60
PLUS_PORT=8094
PLUS_NGX=(nginx -c "/lab/plus/${PLUS_CONF:-nginx.conf}")

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}[ok]${NC} $*"; }
bad()  { echo -e "  ${RED}[!!]${NC} $*"; }

running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }

net_up() {
    docker network inspect "$NET" >/dev/null 2>&1 || docker network create --subnet "$SUBNET" "$NET" >/dev/null
}

pki() {
    mkdir -p "$LAB/certs"
    docker run --rm -v "$LAB/pki.sh:/pki.sh:ro" -v "$LAB/certs:/certs" "$NGINX_IMAGE" sh /pki.sh
}

pki_up() {
    [ -s "$LAB/certs/partner-ca.crl" ] && return 0
    echo "making the lab PKI in certs/:"
    pki
}

secrets_up() {
    [ -s "$LAB/secrets/ops_tokens.json" ] && [ -s "$LAB/secrets/sso_cookie_secret" ] && return 0
    mkdir -p "$LAB/secrets" && chmod 700 "$LAB/secrets"
    local viewer admin
    viewer="tw-view-$(head -c 9 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    admin="tw-admin-$(head -c 9 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    (umask 077
     printf '{\n "%s": {"user": "carol", "role": "viewer"},\n "%s": {"user": "dave", "role": "admin"}\n}\n' \
        "$viewer" "$admin" > "$LAB/secrets/ops_tokens.json"
     head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 32 > "$LAB/secrets/sso_cookie_secret")
    # The apps container reads the tokens as root; the file stays owner-only on the host
    echo "created ops tokens (secrets/ops_tokens.json) and the SSO cookie secret"
}

apps_up() {
    running "$APPS" && return 0
    docker rm -f "$APPS" >/dev/null 2>&1
    docker run -d --name "$APPS" --network "$NET" --ip "$APPS_IP" --network-alias ledger.internal \
        -p "127.0.0.1:$CONTROL_PORT:$CONTROL_PORT" \
        -v "$LAB:/lab:ro" "$PY_IMAGE" python3 -u /lab/apps.py >/dev/null
}

idp_up() {
    running "$IDP" && return 0
    docker rm -f "$IDP" >/dev/null 2>&1
    # Front channel (the browser): https://localhost:8091 through the edge. Back channel (OAuth2 Proxy,
    # NGINX Plus): http://10.57.0.30:8080 directly. --hostname-backchannel-dynamic gives each its own URLs.
    docker run -d --name "$IDP" --network "$NET" --ip "$IDP_IP" -m 1g \
        -p "127.0.0.1:$IDP_ADMIN_PORT:8080" \
        -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin-lab \
        -v "$LAB/realm.json:/opt/keycloak/data/import/realm.json:ro" \
        "$KC_IMAGE" start-dev --import-realm --http-port 8080 \
        --hostname "$FRONT" --hostname-admin "http://localhost:$IDP_ADMIN_PORT" \
        --hostname-backchannel-dynamic true --proxy-headers xforwarded >/dev/null
}

sso_up() {
    running "$SSO" && return 0
    docker rm -f "$SSO" >/dev/null 2>&1
    local back="http://$IDP_IP:8080/realms/$REALM/protocol/openid-connect"
    docker run -d --name "$SSO" --network "$NET" --ip "$SSO_IP" "$O2P_IMAGE" \
        --http-address=0.0.0.0:4180 \
        --provider=oidc --provider-display-name="Tidewater SSO" \
        --client-id=portal --client-secret=portal-lab-secret --code-challenge-method=S256 \
        --oidc-issuer-url="$FRONT/realms/$REALM" --skip-oidc-discovery \
        --login-url="$FRONT/realms/$REALM/protocol/openid-connect/auth" \
        --redeem-url="$back/token" --oidc-jwks-url="$back/certs" \
        --redirect-url="$FRONT/oauth2/callback" \
        --scope="openid email profile" --oidc-groups-claim=groups --email-domain='*' \
        --cookie-name=_tidewater_sso --cookie-secret="$(cat "$LAB/secrets/sso_cookie_secret")" --cookie-secure=true \
        --reverse-proxy=true --trusted-proxy-ip="$EDGE_IP/32" \
        --upstream=static://202 --set-xauthrequest=true --skip-provider-button=true >/dev/null
}

edge_up() {
    [ -f "$LAB/nginx.conf" ] || { bad "no nginx.conf in $LAB: copy a dayN_nginx.conf or starter_nginx.conf first"; return 1; }
    mkdir -p "$LAB/logs" "$LAB"/temp/{client,proxy,fastcgi,uwsgi,scgi,cache}
    docker rm -f "$EDGE" >/dev/null 2>&1
    # The whole lab directory is mounted, so edits to nginx.conf (and a new CRL) are seen by a reload
    docker run -d --name "$EDGE" --network "$NET" --ip "$EDGE_IP" \
        -p "$PORTAL_PORT:$PORTAL_PORT" -p "$PARTNER_PORT:$PARTNER_PORT" \
        -v "$LAB:/lab" "$NGINX_IMAGE" "${NGX[@]}" -g 'daemon off;' >/dev/null
    sleep 0.5
    running "$EDGE" || { bad "the edge exited at start:"; docker logs "$EDGE" 2>&1 | tail -5; return 1; }
}

# in_net URL: fetch a URL from inside the lab network (the apps container has Python)
in_net() {
    docker exec "$APPS" python3 -c 'import sys, urllib.request
try: print(urllib.request.urlopen(sys.argv[1], timeout=3).status)
except Exception as e: print(getattr(e, "code", 0))' "$1" 2>/dev/null
}

wait_idp() {
    local i
    for i in $(seq 120); do
        [ "$(in_net "http://$IDP_IP:8080/realms/$REALM")" = 200 ] && return 0
        [ "$i" = 5 ] && echo "  waiting for Keycloak to start (about 30 s on the first up)..."
        sleep 1
    done
    return 1
}

wait_apps() {
    for _ in $(seq 30); do
        curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$CONTROL_PORT/_stats" && return 0
        sleep 0.2
    done
    return 1
}

# Ready check. Exit 0 only if the lab is usable: this is also the test script's preflight.
check() {
    local fail=0 out code
    if running "$APPS" && wait_apps; then ok "apps answer (control on 127.0.0.1:$CONTROL_PORT)"
    else bad "the apps aren't answering (./lab.sh up)"; fail=1; fi
    if running "$IDP" && wait_idp; then ok "Keycloak is up, realm \"$REALM\""
    else bad "Keycloak isn't answering (./lab.sh up, then ./lab.sh logs idp)"; fail=1; fi
    if running "$SSO" && [ "$(in_net "http://$SSO_IP:4180/ping")" = 200 ]; then ok "OAuth2 Proxy is up"
    else bad "OAuth2 Proxy isn't answering (./lab.sh logs sso)"; fail=1; fi
    if ! running "$EDGE"; then
        bad "the edge container isn't running (./lab.sh up)"; return 1
    fi
    if out=$(docker exec "$EDGE" "${NGX[@]}" -t 2>&1); then
        ok "nginx.conf passes nginx -t ($(docker exec "$EDGE" nginx -v 2>&1 | cut -d/ -f2), $(docker exec "$EDGE" openssl version | cut -d' ' -f1-2))"
    else bad "nginx -t fails:"; echo "$out" | sed 's/^/       /'; fail=1; fi
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 --cacert "$LAB/certs/internal-ca.crt" "$FRONT/realms/$REALM/.well-known/openid-configuration")
    if [ "$code" = 200 ]; then ok "the edge answers on :$PORTAL_PORT (HTTPS) and is the IdP's front door"
    else bad "https://localhost:$PORTAL_PORT/realms/$REALM/.well-known/openid-configuration answered $code, not 200"; fail=1; fi
    if curl -s -o /dev/null --max-time 3 --cacert "$LAB/certs/internal-ca.crt" \
            --cert "$LAB/certs/acme.crt" --key "$LAB/certs/acme.key" "https://localhost:$PARTNER_PORT/"; then
        ok "the edge answers on :$PARTNER_PORT (HTTPS)"
    else bad "no TLS answer on :$PARTNER_PORT (curl -v --cacert certs/internal-ca.crt https://localhost:$PARTNER_PORT/)"; fail=1; fi
    if [ "$fail" = 0 ]; then
        echo -e "${GREEN}Sprint 7 lab ready${NC}: edge :$PORTAL_PORT (portal, ops, IdP) and :$PARTNER_PORT (partners) -> $APPS"
    else
        echo -e "${RED}Sprint 7 lab NOT ready${NC}: fix the items marked [!!]"
    fi
    return "$fail"
}

# nginx -t can't see everything: the master can still refuse the new config. It then logs [emerg]
# and keeps the old config, while "nginx -s reload" itself succeeds. Report that instead of "reloaded".
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

plus() {
    case "${1:-}" in
        up)
            [ -s "$HOME/plus/license.jwt" ] || { bad "no license in ~/plus/license.jwt (docs/nginx-plus-lab.md)"; return 1; }
            # shellcheck disable=SC1091
            [ -f "$HOME/plus/plus.env" ] && . "$HOME/plus/plus.env"
            [ -n "${PLUS_IMAGE:-}" ] || { bad "PLUS_IMAGE isn't set (~/plus/plus.env, docs/nginx-plus-lab.md)"; return 1; }
            running "$EDGE" && running "$IDP" || { bad "start the main lab first (./lab.sh up): Keycloak's front door is the edge"; return 1; }
            docker rm -f "$PLUS" >/dev/null 2>&1
            # The lab directory is mounted (not single files), so edits are seen by a reload
            docker run -d --name "$PLUS" --network "$NET" --ip "$PLUS_IP" \
                -p "$PLUS_PORT:$PLUS_PORT" -p "127.0.0.1:8085:8085" \
                -v "$LAB:/lab:ro" -v "$LAB/plus/state:/var/lib/nginx/state" \
                -v "$HOME/plus/license.jwt:/etc/nginx/license.jwt:ro" \
                "$PLUS_IMAGE" "${PLUS_NGX[@]}" -g 'daemon off;' >/dev/null
            sleep 2
            if running "$PLUS"; then ok "NGINX Plus up: https://localhost:$PLUS_PORT, API http://127.0.0.1:8085/api/"
            else bad "s7-plus exited:"; docker logs "$PLUS" 2>&1 | grep -E 'emerg|alert' | tail -5; return 1; fi ;;
        down)   docker rm -f "$PLUS" >/dev/null 2>&1; echo "s7-plus removed" ;;
        t)      docker exec "$PLUS" "${PLUS_NGX[@]}" -t ;;
        reload) docker exec "$PLUS" "${PLUS_NGX[@]}" -t && docker exec "$PLUS" "${PLUS_NGX[@]}" -s reload && sleep 1 && echo "reloaded" ;;
        *)      echo "usage: ./lab.sh plus up|down|reload|t"; return 1 ;;
    esac
}

cmd="${1:-}"; shift || true
case "$cmd" in
    up)       pki_up && secrets_up && net_up && apps_up && idp_up && sso_up && edge_up && check ;;
    edge)     net_up && edge_up && check ;;
    check)    check ;;
    down)     docker rm -f "$PLUS" "$EDGE" "$SSO" "$IDP" "$APPS" >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1
              echo "Sprint 7 lab removed (certs/ and secrets/ kept)" ;;
    reload)   reload ;;
    t)        docker exec "$EDGE" "${NGX[@]}" -t ;;
    T)        docker exec "$EDGE" "${NGX[@]}" -T ;;
    plus)     plus "$@" ;;
    pki)      pki && echo "new PKI made: run ./lab.sh down && ./lab.sh up so every container uses it" ;;
    stats)    curl -s "http://127.0.0.1:$CONTROL_PORT/_stats" ;;
    reset)    curl -s "http://127.0.0.1:$CONTROL_PORT/_stats/reset" >/dev/null && echo "apps counters reset" ;;
    impostor) curl -s "http://127.0.0.1:$CONTROL_PORT/_ledger/impostor?on=$([ "${1:-on}" = off ] && echo 0 || echo 1)" ;;
    logs)     case "${1:-edge}" in apps) c=$APPS ;; idp) c=$IDP ;; sso) c=$SSO ;; plus) c=$PLUS ;; *) c=$EDGE ;; esac
              docker logs -f "$c" ;;
    *)        awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 1 ;;
esac

#!/bin/bash
# Throwaway zero-trust stack, separate from the Sprint 7 lab (own network, own containers, ports 8088/8089).
#
#   ./up.sh [oauth2-proxy flags...]   start (or recreate OAuth2 Proxy with extra flags, e.g. --cookie-refresh=30s)
#   ./down.sh                         remove everything
#
# Environment: REALM=realm-audience.json  start Keycloak with the audience mapper (default: realm.json)
#              CONF=nginx.baseline.conf    start the edge with the first config (default: nginx.conf)
# Keycloak and the edge are only created if missing: run ./down.sh first to change REALM or CONF.
D=$(cd "$(dirname "$0")" && pwd)
N=zta-s7
REALM=${REALM:-realm.json}
CONF=${CONF:-nginx.conf}
mkdir -p "$D/state"
[ -s "$D/state/cookie_secret" ] || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 32 > "$D/state/cookie_secret"

docker network inspect $N >/dev/null 2>&1 || docker network create --subnet 10.89.0.0/24 $N >/dev/null

docker inspect zta-s7-app >/dev/null 2>&1 || docker run -d --name zta-s7-app --network $N --ip 10.89.0.20 \
  -v "$D/app.py:/app.py:ro" python:3.12-alpine python3 -u /app.py >/dev/null

docker inspect zta-s7-idp >/dev/null 2>&1 || docker run -d --name zta-s7-idp --network $N --ip 10.89.0.30 -m 1g -p 127.0.0.1:8089:8080 \
  -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin-lab \
  -v "$D/$REALM:/opt/keycloak/data/import/realm.json:ro" quay.io/keycloak/keycloak:26.8.2 start-dev --import-realm --http-port 8080 \
  --hostname http://localhost:8088 --hostname-admin http://localhost:8089 --hostname-backchannel-dynamic true --proxy-headers xforwarded >/dev/null

docker rm -f zta-s7-sso >/dev/null 2>&1
B=http://10.89.0.30:8080/realms/tidewater/protocol/openid-connect
F=http://localhost:8088/realms/tidewater
docker run -d --name zta-s7-sso --network $N --ip 10.89.0.40 quay.io/oauth2-proxy/oauth2-proxy:v7.15.6 \
  --http-address=0.0.0.0:4180 --provider=oidc --client-id=portal --client-secret=portal-lab-secret --code-challenge-method=S256 \
  --oidc-issuer-url=$F --skip-oidc-discovery --login-url=$F/protocol/openid-connect/auth --redeem-url=$B/token --oidc-jwks-url=$B/certs \
  --redirect-url=http://localhost:8088/oauth2/callback --scope="openid email profile" --oidc-groups-claim=groups --email-domain='*' \
  --cookie-name=_tidewater_sso --cookie-secret="$(cat "$D/state/cookie_secret")" --cookie-secure=false \
  --reverse-proxy=true --trusted-proxy-ip=10.89.0.10/32 --upstream=static://202 --set-xauthrequest=true --skip-provider-button=true \
  --set-authorization-header=true --pass-access-token=true "$@" >/dev/null

docker inspect zta-s7-edge >/dev/null 2>&1 || docker run -d --name zta-s7-edge --network $N --ip 10.89.0.10 -p 127.0.0.1:8088:8088 \
  -v "$D/$CONF:/etc/nginx/nginx.conf:ro" nginx:mainline >/dev/null

printf 'waiting for Keycloak'
until [ "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8088/realms/tidewater)" = 200 ]; do printf .; sleep 2; done
echo " up (realm: $REALM, edge: $CONF)"

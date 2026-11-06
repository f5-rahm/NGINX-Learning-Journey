# Sprint 7 helpers: source this file (source helpers.sh) in every terminal you use for the lab.
#
#   r PATH [curl options]          one request to the portal/ops edge (:8091): "<- STATUS", then the body
#   rh PATH [curl options]         the same, with the response headers
#   partner NAME PATH [opts]       one request to the partner API (:8092) with NAME's client certificate:
#                                  acme, globex, initech (revoked), fake-acme (rogue CA), or none
#   ops WHO PATH [opts]            one request to the ops tool as WHO: viewer, admin, bogus (a made-up token), none
#   office PATH [opts]             one request to :8091 from the head office's address (10.57.0.5)
#   login USER [PASSWORD]          sign in to the staff portal through Keycloak (alice, bob); keeps the session cookie
#   as USER PATH [opts]            one request to :8091 with USER's session cookie
#   logout USER                    forget USER's session cookie
#   cert NAME                      a certificate's subject, issuer, names and dates (acme, edge, ledger, ...)
#   revoke NAME / unrevoke NAME    revoke a partner certificate / take it back; each writes a new CRL
#   crl                            the CRL's dates and the serial numbers on it
#   crl-short SECONDS              write a CRL that expires after SECONDS (crl-fresh: a normal 30-day CRL again)
#   astats / areset                the apps' counters / zero them
#   elog [N] / alog [N]            the last N lines of the edge's error log / access log
LAB7="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CA7="$LAB7/certs/internal-ca.crt"
EDGE7="https://localhost:8091"
PARTNER7="https://localhost:8092"
JARS7="$LAB7/temp/jars"

_show() { # curl args... : prints "<- STATUS" then the body
    local out code
    out=$(curl -s --max-time 10 --cacert "$CA7" -w '\n%{http_code}' "$@")
    code=${out##*$'\n'}
    echo "<- $code"
    printf '%s\n' "${out%$'\n'*}" | sed '/^$/d'
}

r()  { local p="$1"; shift; _show "$@" "$EDGE7$p"; }
rh() { local p="$1"; shift; curl -s -i --max-time 10 --cacert "$CA7" "$@" "$EDGE7$p"; echo; }

partner() {
    local who="$1" p="$2"; shift 2
    if [ "$who" = none ]; then _show "$@" "$PARTNER7$p"
    else _show --cert "$LAB7/certs/$who.crt" --key "$LAB7/certs/$who.key" "$@" "$PARTNER7$p"; fi
}

_ops_token() { # viewer | admin | bogus
    case "$1" in
        bogus) echo "tw-made-up-token" ;;
        *) python3 -c 'import json, sys
for t, w in json.load(open(sys.argv[1])).items():
    if w["role"] == sys.argv[2]: print(t)' "$LAB7/secrets/ops_tokens.json" "$1" ;;
    esac
}

ops() {
    local who="$1" p="$2"; shift 2
    if [ "$who" = none ]; then _show "$@" "$EDGE7$p"
    else _show -H "Authorization: Bearer $(_ops_token "$who")" "$@" "$EDGE7$p"; fi
}

office() {
    local p="$1"; shift
    docker run --rm --network s7-net --ip 10.57.0.5 -v "$LAB7/certs:/certs:ro" curlimages/curl:8.16.0 \
        -s --max-time 10 --cacert /certs/internal-ca.crt -w '\n<- %{http_code}\n' "$@" "https://s7-edge:8091$p" \
        | sed '/^$/d' | awk '{ lines[NR] = $0 } END { print lines[NR]; for (i = 1; i < NR; i++) print lines[i] }'
}

login() {
    local user="$1" pass="${2:-$1-pass}" jar page action final
    mkdir -p "$JARS7"; jar="$JARS7/$user.txt"; rm -f "$jar"
    # 1. the portal sends an anonymous browser to /oauth2/start, which sends it to Keycloak's login page
    page=$(curl -s -L --max-time 10 --cacert "$CA7" -c "$jar" -b "$jar" "$EDGE7/oauth2/start?rd=/portal/")
    action=$(printf '%s' "$page" | grep -o 'action="[^"]*"' | head -1 | sed 's/^action="//; s/"$//; s/&amp;/\&/g')
    if [ -z "$action" ]; then echo "no login form came back: is /oauth2/ routed to OAuth2 Proxy?"; return 1; fi
    # 2. post the password; Keycloak sends the browser to /oauth2/callback, which sets the session cookie
    final=$(curl -s -L --max-time 10 --cacert "$CA7" -c "$jar" -b "$jar" -o /dev/null -w '%{http_code} %{url_effective}' \
        --data-urlencode "username=$user" --data-urlencode "password=$pass" "$action")
    final=${final%%\?*}
    if grep -qP "\t_tidewater_sso\t" "$jar"; then echo "signed in as $user (ended at: $final)"
    else echo "sign-in failed for $user (ended at: $final)"; return 1; fi
}

as()     { local user="$1" p="$2"; shift 2; _show -b "$JARS7/$user.txt" -c "$JARS7/$user.txt" "$@" "$EDGE7$p"; }
logout() { rm -f "$JARS7/$1.txt"; echo "forgot $1's session cookie"; }

cert() {
    openssl x509 -in "$LAB7/certs/$1.crt" -noout -subject -issuer -serial -ext subjectAltName -dates -nameopt RFC2253 \
        | sed '/^X509v3/d; s/^ *//'
}

_ca7() { docker run --rm -v "$LAB7/certs:/certs" -w /certs nginx:mainline "$@"; }
revoke() {
    _ca7 sh -c "openssl ca -config partner-ca.db/ca.cnf -revoke $1.crt 2>&1 | tail -1 &&
                openssl ca -config partner-ca.db/ca.cnf -gencrl -out partner-ca.crl 2>/dev/null && chmod 644 partner-ca.crl"
    echo "new CRL written to certs/partner-ca.crl"
}
unrevoke() { # put a revoked partner certificate back (edits the CA's database), and write a new CRL
    _ca7 sh -c "serial=\$(openssl x509 -in $1.crt -noout -serial | cut -d= -f2) &&
                awk -F'\t' -v OFS='\t' -v s=\"\$serial\" '\$4 == s && \$1 == \"R\" { \$1 = \"V\"; \$3 = \"\" } { print }' \
                    partner-ca.db/index.txt > partner-ca.db/index.new && mv partner-ca.db/index.new partner-ca.db/index.txt &&
                openssl ca -config partner-ca.db/ca.cnf -gencrl -out partner-ca.crl 2>/dev/null && chmod 644 partner-ca.crl"
    echo "$1 is no longer revoked; new CRL written to certs/partner-ca.crl"
}
crl() { # the CRL's dates and the serial numbers on it (cert NAME shows a certificate's serial)
    openssl crl -in "$LAB7/certs/partner-ca.crl" -noout -text | grep -E 'Last Update|Next Update|Serial Number' | sed 's/^ *//'
}
crl-short() {
    _ca7 sh -c "openssl ca -config partner-ca.db/ca.cnf -gencrl -crlsec ${1:-20} -out partner-ca.crl 2>/dev/null && chmod 644 partner-ca.crl"
    echo "certs/partner-ca.crl now expires in ${1:-20} seconds"
}
crl-fresh() {
    _ca7 sh -c "openssl ca -config partner-ca.db/ca.cnf -gencrl -out partner-ca.crl 2>/dev/null && chmod 644 partner-ca.crl"
    echo "certs/partner-ca.crl renewed for 30 days"
}

astats() { curl -s http://127.0.0.1:8017/_stats; }
areset() { curl -s http://127.0.0.1:8017/_stats/reset >/dev/null && echo "apps counters reset"; }
elog()   { tail -n "${1:-10}" "$LAB7/logs/error.log"; }
alog()   { tail -n "${1:-10}" "$LAB7/logs/access.log"; }

# ---- Enterprise side quest (NGINX Plus on :8094)
#   pr PATH [opts] / prh PATH      one request to Plus (:8094) with no token or session (prh: with headers)
#   jwt USER [PASSWORD]            an access token for USER from Keycloak (client dispatch-cli), through the front door
#   api USER PATH [opts]           one request to Plus's dispatch API with USER's token
#   plogin USER [PASSWORD]         sign in to Plus's portal (:8094) through Keycloak; pas USER PATH: a request with that session
PLUS7="https://localhost:8094"
jwt() {
    curl -s --max-time 10 --cacert "$CA7" "$EDGE7/realms/tidewater/protocol/openid-connect/token" \
        -d grant_type=password -d client_id=dispatch-cli --data-urlencode "username=$1" \
        --data-urlencode "password=${2:-$1-pass}" -d scope=openid | python3 -c 'import json, sys
d = json.load(sys.stdin); print(d.get("access_token") or "no token: " + d.get("error_description", str(d)))'
}
decode() { # the claims of a JWT, unchecked
    printf '%s' "$1" | cut -d. -f2 | tr '_-' '/+' | python3 -c 'import base64, json, sys
s = sys.stdin.read().strip(); print(json.dumps(json.loads(base64.b64decode(s + "=" * (-len(s) % 4))), indent=1))'
}
pr()  { local p="$1"; shift; _show "$@" "$PLUS7$p"; }
prh() { local p="$1"; shift; curl -s -i --max-time 10 --cacert "$CA7" "$@" "$PLUS7$p"; echo; }
api() { local user="$1" p="$2"; shift 2; _show -H "Authorization: Bearer $(jwt "$user")" "$@" "$PLUS7$p"; }
plogin() {
    local user="$1" pass="${2:-$1-pass}" jar page action final
    mkdir -p "$JARS7"; jar="$JARS7/plus-$user.txt"; rm -f "$jar"
    page=$(curl -s -L --max-time 10 --cacert "$CA7" -c "$jar" -b "$jar" "$PLUS7/portal/")
    action=$(printf '%s' "$page" | grep -o 'action="[^"]*"' | head -1 | sed 's/^action="//; s/"$//; s/&amp;/\&/g')
    if [ -z "$action" ]; then echo "no login form came back: does /portal/ have auth_oidc?"; return 1; fi
    final=$(curl -s -L --max-time 10 --cacert "$CA7" -c "$jar" -b "$jar" -o /dev/null -w '%{http_code} %{url_effective}' \
        --data-urlencode "username=$user" --data-urlencode "password=$pass" "$action")
    final=${final%%\?*}
    if [ "${final%% *}" = 200 ] && grep -qP "\tNGX_OIDC_SESSION\t" "$jar"; then echo "signed in to Plus as $user (ended at: $final)"
    else echo "sign-in failed for $user (ended at: $final)"; return 1; fi
}
pas() { local user="$1" p="$2"; shift 2; _show -b "$JARS7/plus-$user.txt" -c "$JARS7/plus-$user.txt" "$@" "$PLUS7$p"; }

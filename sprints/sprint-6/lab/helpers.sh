# Sprint 6 helpers. Load in every new terminal:  source helpers.sh
#
#   r PATH [curl options]       one request to the edge (:8096): status line, then the body
#   rh PATH [curl options]      the same, with all the response headers
#   token SUB [--plan P] [--ttl S] [--jti ID] [--key K]
#                               a Lumina session token (JWT, HS256) signed with the lab key
#   link PATH [--ttl S] [--key K]
#                               a signed download link: PATH?expires=...&sig=...
#   tel DEVICE [--sig S] [--data TEXT] [--silent]
#                               one connection to the telemetry port (:8097) with a signed HELLO
#   decode TOKEN                a token's header and payload, unchecked
#   revoke JTI / unrevoke [JTI] add a session ID to the origin's revocation list / take it off
#   ostats                      the origin's counters (pool, URI, last X-User, telemetry)
#   elog [N]                    the last N lines of the edge's error log (default 5)
#
# Send a session:  r /api/me -b "lumina_session=$(token alice --plan beta)"
S6_LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S6_EDGE="${S6_EDGE:-127.0.0.1:8096}"

r()        {
    local p="$1"; shift
    curl -s -w '\n%{http_code}' "$@" "http://$S6_EDGE$p" |
        awk '{ a[NR] = $0 } END { print "<- " a[NR]; for (i = 1; i < NR; i++) if (i < NR - 1 || a[i] != "") print a[i] }'
}
rh()       { local p="$1"; shift; curl -s -i "$@" "http://$S6_EDGE$p"; echo; }
token()    { python3 "$S6_LAB/tools.py" token "$@"; }
link()     { python3 "$S6_LAB/tools.py" link "$@"; }
tel()      { python3 "$S6_LAB/tools.py" tel "$@"; }
decode()   { python3 "$S6_LAB/tools.py" decode "$@"; }
revoke()   { curl -s "http://127.0.0.1:8016/_revoke?jti=$1" | tr -d ' \n'; echo; }
unrevoke() { curl -s "http://127.0.0.1:8016/_unrevoke${1:+?jti=$1}" | tr -d ' \n'; echo; }
ostats()   { curl -s http://127.0.0.1:8016/_stats; }
elog()     { tail -n "${1:-5}" "$S6_LAB/logs/error.log"; }

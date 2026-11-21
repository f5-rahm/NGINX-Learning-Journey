# Sprint 8 helpers. Load them in each new terminal:
#   cd /srv/nginx-journey/sprints/sprint-8/lab && source helpers.sh
# Every request helper runs on the HOST and names the controller and port it goes to.
# `s8help` lists them.

S8_LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S8_HOST=transit.copperline.test
S8_CA="$S8_LAB/certs/ca.crt"

# --- Requests through the open source controller (host ports 8098 HTTP, 8099 HTTPS) ---
# t PATH [curl options]: HTTPS to https://transit.copperline.test:8099, prints the body
t()   { local p=$1; shift; curl -s --resolve $S8_HOST:8099:127.0.0.1 --cacert "$S8_CA" "$@" "https://$S8_HOST:8099$p"; }
# th PATH [curl options]: the same, status line and headers only
th()  { local p=$1; shift; curl -s -o /dev/null -D - --resolve $S8_HOST:8099:127.0.0.1 --cacert "$S8_CA" "$@" "https://$S8_HOST:8099$p"; }
# tc PATH [curl options]: the same, status code only
tc()  { local p=$1; shift; curl -s -o /dev/null -w '%{http_code}\n' --resolve $S8_HOST:8099:127.0.0.1 --cacert "$S8_CA" "$@" "https://$S8_HOST:8099$p"; }
# hreq HOST PATH [curl options]: plain HTTP to 127.0.0.1:8098 with any Host header; status line + headers + body
hreq() { local h=$1 p=$2; shift 2; curl -s -i -H "Host: $h" "$@" "http://127.0.0.1:8098$p"; echo; }
# hwho N HOST PATH [curl options]: N plain-HTTP requests to :8098; how many each app/version/pod answered
hwho() {
  local n=$1 h=$2 p=$3; shift 3
  for _ in $(seq "$n"); do curl -s -H "Host: $h" "$@" "http://127.0.0.1:8098$p" | jq -r '"\(.app) \(.version) \(.pod)"' 2>/dev/null || echo "(not JSON)"; done | sort | uniq -c
}
# who N PATH [curl options]: N HTTPS requests; how many each version/pod answered
who() {
  local n=$1 p=$2; shift 2
  for _ in $(seq "$n"); do t "$p" "$@" | jq -r '"\(.version) \(.pod)"' 2>/dev/null || echo "(not JSON)"; done | sort | uniq -c
}
# load SECONDS WORKERS PATH [curl options]: steady HTTPS requests from WORKERS loops; counts status codes
#   (curl-exit-N = no HTTP answer at all, e.g. 28 = timed out)
load() {
  local dur=$1 w=$2 p=$3; shift 3
  local end=$(( $(date +%s) + dur ))
  for _ in $(seq "$w"); do
    ( while [ "$(date +%s)" -lt $end ]; do
        c=$(curl -s -o /dev/null -m 5 -w '%{http_code}' --resolve $S8_HOST:8099:127.0.0.1 --cacert "$S8_CA" "$@" "https://$S8_HOST:8099$p"); e=$?
        [ $e = 0 ] && echo "$c" || echo "$c curl-exit-$e"
      done ) &
  done | sort | uniq -c
}

# --- Inside the cluster ---
# incluster [curl options] URL: curl from the 'client' pod in namespace transit
incluster() { kubectl -n transit exec client -- curl -s "$@"; }
_s8pod() { kubectl -n "${2:-transit}" get pod -l "app=$1${3:+,version=$3}" -o jsonpath='{.items[0].metadata.name}'; }
_s8ctl() { kubectl -n "$1" exec "$2" -- python3 -c "import urllib.request as u; print(u.urlopen(u.Request('http://127.0.0.1:8080$3', method='$4')).read().decode().replace(chr(10),''))"; }
# pod-fail APP on|off [VERSION]: one pod of APP (in transit) answers 500 to everything but /healthz
pod-fail()    { local p; p=$(_s8pod "$1" transit "${3:-}"); _s8ctl transit "$p" "/_ctl/fail?on=$([ "$2" = on ] && echo 1 || echo 0)" POST; }
# pod-unready APP on|off [VERSION]: one pod of APP answers 503 on /healthz
pod-unready() { local p; p=$(_s8pod "$1" transit "${3:-}"); _s8ctl transit "$p" "/_ctl/unready?on=$([ "$2" = on ] && echo 1 || echo 0)" POST; }
# pod-stats APP [VERSION]: requests served by that same pod, and its switches
pod-stats()   { local p; p=$(_s8pod "$1" transit "${2:-}"); _s8ctl transit "$p" "/_ctl/stats" GET; }

# --- The controller ---
nconf()   { "$S8_LAB/lab.sh" conf "$@"; }     # nconf: list generated files; nconf FILE: show one; nconf -T: nginx -T
reloads() { "$S8_LAB/lab.sh" reloads; }       # reload counters by reason
nlogs()   { "$S8_LAB/lab.sh" logs "${1:-50}"; } # controller log (NGINX access/error log + controller events)

# --- Side quest: the NGINX Plus controller (host ports 8086 HTTP, 8087 HTTPS) ---
pt()  { local p=$1; shift; curl -s --resolve $S8_HOST:8087:127.0.0.1 --cacert "$S8_CA" "$@" "https://$S8_HOST:8087$p"; }
ptc() { local p=$1; shift; curl -s -o /dev/null -w '%{http_code}\n' --resolve $S8_HOST:8087:127.0.0.1 --cacert "$S8_CA" "$@" "https://$S8_HOST:8087$p"; }
pwho() {
  local n=$1 p=$2; shift 2
  for _ in $(seq "$n"); do pt "$p" "$@" | jq -r '"\(.version) \(.pod)"' 2>/dev/null || echo "(not JSON)"; done | sort | uniq -c
}
pload() {
  local dur=$1 w=$2 p=$3; shift 3
  local end=$(( $(date +%s) + dur ))
  for _ in $(seq "$w"); do
    ( while [ "$(date +%s)" -lt $end ]; do
        c=$(curl -s -o /dev/null -m 10 -w '%{http_code}' --resolve $S8_HOST:8087:127.0.0.1 --cacert "$S8_CA" "$@" "https://$S8_HOST:8087$p"); e=$?
        [ $e = 0 ] && echo "$c" || echo "$c curl-exit-$e"
      done ) &
  done | sort | uniq -c
}
# burst N MS [plus]: N requests at once to /arrivals/slow?ms=MS (open source :8099, or Plus :8087); status counts + slowest
burst() {
  local n=$1 ms=$2 port=8099; [ "${3:-}" = plus ] && port=8087
  ( for _ in $(seq "$n"); do
      curl -s -o /dev/null -w '%{http_code} %{time_total}\n' --resolve $S8_HOST:$port:127.0.0.1 --cacert "$S8_CA" \
           -H 'X-Canary: no' "https://$S8_HOST:$port/arrivals/slow/burst?ms=$ms" &
    done; wait ) | awk '{c[$1]++; if ($2 > t) t = $2} END {for (k in c) printf "%s x %d   ", k, c[k]; printf "slowest %.1f s\n", t}'
}
token()  { python3 "$S8_LAB/tools.py" token "$@"; }   # token SUB TIER [ROLES]
decode() { python3 "$S8_LAB/tools.py" decode "$1"; }
papi()   { curl -s "http://127.0.0.1:${PLUS_API_PORT:-8085}/api/9$1"; }   # papi /http/upstreams (after ./lab.sh plus api)
preloads() { "$S8_LAB/lab.sh" plus reloads; }

s8help() {
  cat <<'EOF'
Open source controller (host 8098 HTTP / 8099 HTTPS), host transit.copperline.test:
  t PATH [opts]     HTTPS, body               th PATH   status + headers      tc PATH   status code
  hreq HOST PATH    plain HTTP to :8098 with any Host header (status, headers, body)
  hwho N HOST PATH  which app/version/pod answered N plain-HTTP requests
  who N PATH        which version/pod answered N requests
  load SECS WORKERS PATH [opts]   steady requests, status-code counts
Cluster:  incluster [curl opts] URL     pod-fail APP on|off     pod-unready APP on|off     pod-stats APP
Controller:  nconf [FILE|-T]     reloads     nlogs [N]
Plus side quest (host 8086 / 8087):  pt  ptc  pwho  pload  burst N MS plus  token SUB TIER [ROLES]  decode TOKEN  papi /PATH  preloads
EOF
}
echo "Sprint 8 helpers loaded (s8help lists them). kubectl context: $(kubectl config current-context 2>/dev/null || echo none)"

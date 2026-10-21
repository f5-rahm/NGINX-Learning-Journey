# Sprint 4 helpers. Load in every new terminal:  source helpers.sh
#
#   r PATH [curl args]     one request to the edge, summarized on one line:
#                          status, X-Cache-Status, the origin's hit count for that URI,
#                          the Host the origin saw, and the time taken
#   rr N PATH [curl args]  the same request N times in a row
#   burst N PATH           N requests for PATH at the same moment: status codes, wall time,
#                          and how many of them reached the origin
#   seen PATH              how many times this exact URI has reached the origin
#   key PATH               the cache file for PATH (default key, no Host) and its KEY line
#
# EDGE and ORIGIN override the targets (defaults 127.0.0.1:8084 and 127.0.0.1:8014).
EDGE="${EDGE:-127.0.0.1:8084}"
S4_LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

r() {
    local path="$1"; shift
    local tmp; tmp=$(mktemp -d)
    local out
    out=$(curl -s --max-time 10 -D "$tmp/h" -o "$tmp/b" -w '%{http_code} %{time_total}' "$@" "http://$EDGE$path")
    python3 - "$tmp/h" "$tmp/b" "$out" <<'EOF'
import json, sys
hdrs = {}
for line in open(sys.argv[1], errors="replace"):
    if ":" in line:
        k, v = line.split(":", 1)
        hdrs[k.strip().lower()] = v.strip()
code, secs = sys.argv[3].split()
try:
    body = json.load(open(sys.argv[2]))
except Exception:
    body = {}
print("%s  cache=%-11s origin_hits=%-3s host=%-16s %.2fs" % (
    code, hdrs.get("x-cache-status", "-"), body.get("origin_hits", "-"), body.get("host", "-"), float(secs)))
EOF
    rm -rf "$tmp"
}

rr() {
    local n="$1"; shift
    for _ in $(seq "$n"); do r "$@"; done
}

burst() {
    local n="$1" path="$2" tmp t0; tmp=$(mktemp -d); t0=$(date +%s.%N)
    (   # a subshell, so the shell prints no job-control lines
        for i in $(seq "$n"); do
            curl -s -o /dev/null --max-time 15 -w '%{http_code}\n' "http://$EDGE$path" > "$tmp/$i" &
        done
        wait
    )
    echo "$n requests in $(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN { printf "%.1f", b - a }')s:" \
         "$(sort "$tmp"/* | uniq -c | awk '{ printf "%s x %s  ", $2, $1 }')| origin saw it $(seen "$path") times"
    rm -rf "$tmp"
}

# seen PATH: how many times this exact URI reached the origin
seen() {
    curl -s --max-time 3 "http://${ORIGIN:-127.0.0.1:8014}/_stats" | python3 -c \
        'import json,sys; print(json.load(sys.stdin)["by_uri"].get(sys.argv[1], 0))' "$1"
}

key() {
    local f
    f=$(grep -rlaF "$1" "$S4_LAB/cache" 2>/dev/null | head -5)
    [ -z "$f" ] && { echo "no cache file mentions $1"; return 1; }
    for x in $f; do echo "${x#$S4_LAB/}"; grep -a '^KEY:' "$x"; done
}

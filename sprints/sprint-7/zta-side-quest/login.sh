#!/bin/bash
# ./login.sh [bob|alice]   sign in through the edge with curl; the session cookie lands in state/jar.txt
D=$(cd "$(dirname "$0")" && pwd); J=$D/state/jar.txt; mkdir -p "$D/state"; rm -f "$J"
page=$(curl -s -L --max-time 10 -c "$J" -b "$J" "http://localhost:8088/oauth2/start?rd=/portal/")
action=$(printf '%s' "$page" | grep -o 'action="[^"]*"' | head -1 | sed 's/^action="//; s/"$//; s/&amp;/\&/g')
[ -z "$action" ] && { echo "no login form"; printf '%s\n' "$page" | head -5; exit 1; }
curl -s -L --max-time 10 -c "$J" -b "$J" -o /dev/null -w '%{http_code} %{url_effective}\n' \
  --data-urlencode "username=${1:-bob}" --data-urlencode "password=${1:-bob}-pass" "$action"

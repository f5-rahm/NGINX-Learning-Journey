#!/bin/bash
# ./portal.sh [curl args...]   GET /portal/ with the signed-in session; prints the status, then the app's verdicts
D=$(cd "$(dirname "$0")" && pwd)
curl -s -o "$D/state/r.json" -w '%{http_code}\n' -b "$D/state/jar.txt" -c "$D/state/jar.txt" "$@" http://localhost:8088/portal/
cat "$D/state/r.json"; echo

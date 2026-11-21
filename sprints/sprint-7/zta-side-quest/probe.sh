#!/bin/bash
# ./probe.sh   watch the access token over ~2.5 minutes (realm access-token lifespan: 60 s)
D=$(cd "$(dirname "$0")" && pwd); S=$(date +%s)
for t in 0 25 45 70 100 140; do until [ $(( $(date +%s) - S )) -ge $t ]; do sleep 1; done
  code=$(curl -s -o "$D/state/r.json" -w '%{http_code}' -b "$D/state/jar.txt" -c "$D/state/jar.txt" http://localhost:8088/portal/)
  echo "t+$t: $code $(python3 -c 'import json,sys;a=json.load(open(sys.argv[1]))["access_token"];print(a.get("preferred_username"),"exp_in",a.get("exp_in"),a["result"])' "$D/state/r.json" 2>/dev/null)"
done

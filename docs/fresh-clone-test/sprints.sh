#!/usr/bin/env bash
# Runs inside the fresh-clone test container (started by run.sh), never on a lab box:
# it starts NGINX on every sprint's lab ports and runs the solutions.
#
# For each sprint, from a fresh clone: set the lab up the way the guides do, run the
# test against the starter (checks open), then against the solution (gate passes).
# Logs go to /results/<sprint>-<starter|solution>.log.
set -u
ngx() { /usr/sbin/nginx -p "$PWD" -c "$PWD/nginx.conf" -e logs/error.log "$@"; }
R=/srv/nginx-journey/sprints
strip() { sed 's/\x1b\[[0-9;]*m//g'; }
run() { local tag=$1; shift; echo "################ $tag"; "$@" 2>&1 | strip | tee "/results/$tag.log" | tail -6; }

# Sprint 1: Day 1 step 3, then the Day 2 lab setup
cd $R/sprint-1 && mkdir -p lab/{html,logs,temp,cache}
cd $R/sprint-1/lab
cp starter_nginx.conf nginx.conf
mkdir -p www/media www/app www/.git
echo '<h1>Northwind Storefront</h1>' > www/index.html
echo '<h1>Northwind App Shell</h1><div id="root"></div>' > www/app/index.html
echo 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=' | base64 -d > www/media/logo.png
echo 'DB_PASSWORD=do-not-serve-me' > www/.env
printf '[core]\n\trepositoryformatversion = 0\n' > www/.git/config
echo 'hidden asset' > www/media/.secret
ngx -t && ngx; sleep 1
run s1-starter bash -c "cd $R/sprint-1 && ./test_sprint01.sh"
cp solution_nginx.conf nginx.conf && ngx -s reload; sleep 1
run s1-solution bash -c "cd $R/sprint-1 && ./test_sprint01.sh"
ngx -s quit

# Sprint 2
cd $R/sprint-2/lab && mkdir -p logs temp/{client,proxy,fastcgi,uwsgi,scgi}
cp starter_nginx.conf nginx.conf && ngx -t && ngx; sleep 1
run s2-starter bash -c "cd $R/sprint-2 && ./test_sprint02.sh"
cp solution_nginx.conf nginx.conf && ngx -s reload; sleep 1
run s2-solution bash -c "cd $R/sprint-2 && ./test_sprint02.sh"
ngx -s quit

# Sprint 3: the starter has no certificates configured yet, so it doesn't load;
# the solution is started fresh
cd $R/sprint-3/lab && mkdir -p logs temp/{client,proxy,fastcgi,uwsgi,scgi}
./make_certs.sh > /results/s3-make_certs.log 2>&1; echo "s3 make_certs exit $?"
cp starter_nginx.conf nginx.conf && ngx -t && ngx; sleep 1
run s3-starter bash -c "cd $R/sprint-3 && ./test_sprint03.sh"
cp solution_nginx.conf nginx.conf && { ngx -s reload 2>/dev/null || ngx; }; sleep 1
run s3-solution bash -c "cd $R/sprint-3 && ./test_sprint03.sh"
ngx -s quit

# Sprints 4-6: container labs
for s in 4 5 6; do
  cd $R/sprint-$s/lab
  cp starter_nginx.conf nginx.conf; [ -f starter_lumina.js ] && cp starter_lumina.js lumina.js
  ./lab.sh up > "/results/s$s-up.log" 2>&1; echo "s$s lab.sh up exit $?"
  run s$s-starter bash -c "cd $R/sprint-$s && ./test_sprint0$s.sh"
  cp solution_nginx.conf nginx.conf; [ -f solution_lumina.js ] && cp solution_lumina.js lumina.js
  ./lab.sh reload > "/results/s$s-reload.log" 2>&1; echo "s$s reload exit $?"; sleep 1
  run s$s-solution bash -c "cd $R/sprint-$s && ./test_sprint0$s.sh"
  ./lab.sh down > /dev/null 2>&1
done
echo "################ DONE"

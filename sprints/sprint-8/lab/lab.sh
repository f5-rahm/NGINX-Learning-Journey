#!/usr/bin/env bash
# Sprint 8 lab: Copperline Transit on Kubernetes (kind) with F5 NGINX Ingress Controller.
# Run from anywhere; paths are relative to this script. ./lab.sh help for the commands.
set -uo pipefail
LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER=s8
CTX=kind-s8
NODE_IMAGE="kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5"
CHART=oci://ghcr.io/nginx/charts/nginx-ingress
CHART_VERSION=2.9.0
PLUS_LICENSE="${PLUS_LICENSE:-${HOME:-$(getent passwd "$(id -u)" | cut -d: -f6)}/plus/license.jwt}"
PLUS_API_PORT="${PLUS_API_PORT:-8085}"
K="kubectl --context $CTX"

say()  { printf '\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
die()  { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

need_tools() {
  local missing=""
  for t in kind kubectl helm docker openssl curl; do command -v $t >/dev/null || missing="$missing $t"; done
  [ -z "$missing" ] || die "Missing:$missing. Install kind, kubectl and helm with the README's one-time setup (step 5), then run this again."
}
cluster_exists() { kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; }
need_cluster() { cluster_exists || die "The cluster '$CLUSTER' isn't running. Start it with: ./lab.sh up"; }
nic_pod() { $K -n nginx-ingress get pod -l app.kubernetes.io/name=nginx-ingress -o name 2>/dev/null | head -1; }
plus_pod() { $K -n nginx-plus get pod -l app.kubernetes.io/name=nginx-ingress -o name 2>/dev/null | head -1; }

pki() {
  mkdir -p "$LAB/certs" && chmod 700 "$LAB/certs"
  cd "$LAB/certs" || exit 1
  if [ ! -s ca.key ]; then
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 365 \
      -subj "/O=Copperline Transit/CN=Copperline Lab CA" -keyout ca.key -out ca.crt 2>/dev/null
  fi
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/O=Copperline Transit/CN=transit.copperline.test" \
    -keyout transit.key -out transit.csr 2>/dev/null
  openssl x509 -req -in transit.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 90 -out transit.crt \
    -extfile <(printf 'subjectAltName=DNS:transit.copperline.test,DNS:*.copperline.test\nextendedKeyUsage=serverAuth\n') 2>/dev/null
  rm -f transit.csr
  chmod 600 ./*.key
  ok "lab/certs: ca.crt (Copperline Lab CA), transit.crt + transit.key (transit.copperline.test, *.copperline.test)"
  cd - >/dev/null
}

secrets() {
  mkdir -p "$LAB/secrets" && chmod 700 "$LAB/secrets"
  [ -s "$LAB/secrets/htpasswd" ] || printf 'dispatcher:%s\n' "$(openssl passwd -apr1 radio-check)" > "$LAB/secrets/htpasswd"
  [ -s "$LAB/secrets/jwt.key" ] || openssl rand -hex 32 > "$LAB/secrets/jwt.key"
  chmod 600 "$LAB/secrets/"*
}

apply_apps() {
  for ns in transit fares; do
    $K create namespace $ns --dry-run=client -o yaml | $K apply -f - >/dev/null
    $K -n $ns create configmap app-code --from-file=app.py="$LAB/app.py" --dry-run=client -o yaml | $K apply -f - >/dev/null
  done
  $K apply -f "$LAB/k8s/transit.yaml" -f "$LAB/k8s/fares.yaml" >/dev/null || die "Applying the base manifests failed."
}

wait_apps() {
  $K -n transit rollout status deploy --timeout=180s >/dev/null 2>&1
  $K -n fares rollout status deploy --timeout=180s >/dev/null 2>&1
  $K -n transit wait --for=condition=Ready pod/client --timeout=120s >/dev/null 2>&1
}

nic_install() {
  say "Installing F5 NGINX Ingress Controller 5.8.0 (Helm chart $CHART_VERSION) into namespace nginx-ingress"
  helm --kube-context $CTX upgrade --install nic $CHART --version $CHART_VERSION \
    --namespace nginx-ingress --create-namespace -f "$LAB/nic-values.yaml" --wait --timeout 5m >/dev/null \
    || die "helm install failed (see: helm --kube-context $CTX -n nginx-ingress status nic)"
  ok "release nic: $($K -n nginx-ingress get deploy -o jsonpath='{.items[0].spec.template.spec.containers[0].image}')"
}

up() {
  need_tools
  if cluster_exists; then
    say "Cluster '$CLUSTER' is already running"
  else
    say "Creating the kind cluster '$CLUSTER' (1 control plane + 2 workers, about a minute)"
    kind create cluster --config "$LAB/kind.yaml" --image "$NODE_IMAGE" --wait 120s || die "kind create cluster failed."
  fi
  $K wait --for=condition=Ready node --all --timeout=180s >/dev/null 2>&1   # all three, so pods spread over both workers
  [ "$(kubectl config current-context 2>/dev/null)" = "$CTX" ] || kubectl config use-context $CTX >/dev/null
  mkdir -p "$LAB/work"
  say "Lab PKI and secrets"
  [ -s "$LAB/certs/transit.crt" ] && ok "lab/certs already present (./lab.sh pki makes new ones)" || pki
  secrets
  say "Copperline applications (namespaces transit and fares)"
  apply_apps
  wait_apps
  if [ "${1:-}" = "--no-nic" ]; then
    say "Skipping the ingress controller (--no-nic): Day 1 installs it by hand"
  elif helm --kube-context $CTX -n nginx-ingress status nic >/dev/null 2>&1; then
    say "F5 NGINX Ingress Controller is already installed"
  else
    nic_install
  fi
  check
}

check() {
  need_cluster
  local fails=0
  say "Checking the lab"
  local nr; nr=$($K get nodes --no-headers 2>/dev/null | grep -c ' Ready')
  [ "$nr" = 3 ] && ok "3 nodes Ready" || { bad "nodes Ready: $nr of 3"; fails=1; }
  [ "$(kubectl config current-context 2>/dev/null)" = "$CTX" ] && ok "kubectl context is $CTX" \
    || { bad "kubectl's current context is '$(kubectl config current-context 2>/dev/null)', not $CTX: kubectl config use-context $CTX"; fails=1; }
  for d in transit/web-v1 transit/arrivals-v1 transit/arrivals-v2 transit/dispatch-v1 fares/fares-v1; do
    local r; r=$($K -n ${d%/*} get deploy ${d#*/} -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null)
    [ -n "$r" ] && [ "${r%/*}" = "${r#*/}" ] && ok "deployment $d $r ready" || { bad "deployment $d: ${r:-missing} ready"; fails=1; }
  done
  # Pod-to-pod across nodes: after a host or Docker restart, kind's pod routes can break
  local ips unreach
  ips=$($K get pods -n transit -l 'app in (web,arrivals,dispatch)' -o jsonpath='{.items[*].status.podIP}' 2>/dev/null)
  ips="$ips $($K get pods -n fares -l app=fares -o jsonpath='{.items[*].status.podIP}' 2>/dev/null)"
  unreach=$($K -n transit exec client -- sh -c "for ip in $ips; do curl -s -m 2 -o /dev/null http://\$ip:8080/healthz || echo \$ip; done" 2>/dev/null | tr '\n' ' ')
  if [ -z "$unreach" ]; then ok "every app pod answers from the client pod (pod network across nodes)"
  else bad "pods unreachable from the client pod: $unreach(after a host or Docker restart: ./lab.sh down && ./lab.sh up)"; fails=1; fi
  if [ -n "$(nic_pod)" ]; then
    $K -n nginx-ingress wait --for=condition=Ready $(nic_pod) --timeout=60s >/dev/null 2>&1 \
      && ok "NGINX Ingress Controller pod Ready ($(nic_pod | cut -d/ -f2))" || { bad "NGINX Ingress Controller pod not Ready"; fails=1; }
    local c; c=$(curl -s -o /dev/null -w '%{http_code}' -m 5 http://127.0.0.1:8098/)
    [ "$c" = 404 ] && ok "http://127.0.0.1:8098/ answers 404 (the controller's default server)" || { bad "http://127.0.0.1:8098/ answered '$c', expected 404"; fails=1; }
  else
    echo "  --   NGINX Ingress Controller not installed (Day 1 installs it; or ./lab.sh nic)"
  fi
  [ $fails = 0 ] && say "Lab ready" || { say "Lab NOT ready"; return 1; }
}

reset() {
  need_cluster
  say "Removing every Ingress, VirtualServer, VirtualServerRoute and Policy in transit and fares"
  for ns in transit fares; do
    $K -n $ns delete ingress,virtualserver,virtualserverroute,policy --all --wait=false >/dev/null 2>&1
    $K -n $ns delete secret --all >/dev/null 2>&1
  done
  say "Restoring the applications to lab/k8s (deployments recreated)"
  $K -n transit delete deploy --all --wait=true >/dev/null 2>&1
  $K -n fares delete deploy --all --wait=true >/dev/null 2>&1
  apply_apps
  wait_apps
  if helm --kube-context $CTX -n nginx-ingress status nic >/dev/null 2>&1; then
    say "Restoring the controller's settings to lab/nic-values.yaml"
    helm --kube-context $CTX upgrade nic $CHART --version $CHART_VERSION -n nginx-ingress -f "$LAB/nic-values.yaml" --wait >/dev/null \
      && ok "release nic reset" || bad "helm upgrade failed"
  fi
  check
}

conf() {
  need_cluster
  local p; p=$(nic_pod); [ -n "$p" ] || die "The controller isn't installed."
  if [ -z "${1:-}" ]; then
    $K -n nginx-ingress exec $p -- ls /etc/nginx/conf.d
  elif [ "$1" = "-T" ]; then
    $K -n nginx-ingress exec $p -- nginx -T 2>/dev/null
  else
    $K -n nginx-ingress exec $p -- cat "/etc/nginx/conf.d/$1"
  fi
}

reloads() {
  local ns=${1:-nginx-ingress} p
  [ "$ns" = nginx-plus ] && p=$(plus_pod) || p=$(nic_pod)
  [ -n "$p" ] || die "No controller pod in $ns."
  $K get --raw "/api/v1/namespaces/$ns/pods/${p#pod/}:9113/proxy/metrics" \
    | grep -E '^nginx_ingress_controller_nginx_reload(s|_errors)_total' | sed -E 's/\{class="[^"]*",?/{/; s/\{\}//'
}

plus() {
  need_cluster
  case "${1:-}" in
    up)
      [ -s "$PLUS_LICENSE" ] || die "No NGINX Plus license at $PLUS_LICENSE (see docs/nginx-plus-lab.md)."
      say "Installing F5 NGINX Ingress Controller with NGINX Plus into namespace nginx-plus"
      $K create namespace nginx-plus --dry-run=client -o yaml | $K apply -f - >/dev/null
      $K -n nginx-plus create secret generic nplus-license --from-file=license.jwt="$PLUS_LICENSE" \
        --dry-run=client -o yaml | $K apply -f - >/dev/null
      $K -n nginx-plus create secret docker-registry regcred --docker-server=private-registry.nginx.com \
        --docker-username="$(cat "$PLUS_LICENSE")" --docker-password=none --dry-run=client -o yaml | $K apply -f - >/dev/null
      helm --kube-context $CTX upgrade --install nicplus $CHART --version $CHART_VERSION -n nginx-plus \
        -f "$LAB/plus/nic-plus-values.yaml" --wait --timeout 5m >/dev/null || die "helm install failed."
      ok "release nicplus: $($K -n nginx-plus get deploy -o jsonpath='{.items[0].spec.template.spec.containers[0].image}')"
      local c; c=$(curl -s -o /dev/null -w '%{http_code}' -m 5 http://127.0.0.1:8086/)
      [ "$c" = 404 ] && ok "http://127.0.0.1:8086/ answers 404 (the Plus controller's default server)" || bad "http://127.0.0.1:8086/ answered '$c'"
      ;;
    down)
      plus api-stop
      helm --kube-context $CTX -n nginx-plus uninstall nicplus >/dev/null 2>&1
      $K delete namespace nginx-plus --wait=false >/dev/null 2>&1
      ok "Plus controller removed"
      ;;
    api)
      local p; p=$(plus_pod); [ -n "$p" ] || die "The Plus controller isn't installed: ./lab.sh plus up"
      plus api-stop
      mkdir -p "$LAB/run"
      nohup $K -n nginx-plus port-forward --address 127.0.0.1 "$p" "$PLUS_API_PORT:8080" >"$LAB/run/plus-api.log" 2>&1 &
      echo $! > "$LAB/run/plus-api.pid"
      sleep 2
      curl -s -m 3 "http://127.0.0.1:$PLUS_API_PORT/api/" >/dev/null \
        && ok "Plus API http://127.0.0.1:$PLUS_API_PORT/api/9/  dashboard http://127.0.0.1:$PLUS_API_PORT/dashboard.html" \
        || bad "port-forward didn't come up (see lab/run/plus-api.log)"
      ;;
    api-stop)
      [ -s "$LAB/run/plus-api.pid" ] && kill "$(cat "$LAB/run/plus-api.pid")" 2>/dev/null; rm -f "$LAB/run/plus-api.pid"
      ;;
    reloads) reloads nginx-plus ;;
    conf)
      local p; p=$(plus_pod); [ -n "$p" ] || die "The Plus controller isn't installed."
      if [ -z "${2:-}" ]; then $K -n nginx-plus exec $p -- ls /etc/nginx/conf.d; else $K -n nginx-plus exec $p -- cat "/etc/nginx/conf.d/$2"; fi
      ;;
    logs) $K -n nginx-plus logs "$(plus_pod)" --tail="${2:-50}" ;;
    *) die "usage: ./lab.sh plus up|down|api|api-stop|reloads|conf [FILE]|logs [N]" ;;
  esac
}

case "${1:-help}" in
  up)      shift; up "$@" ;;
  check)   check ;;
  nic)     need_cluster; nic_install ;;
  reset)   reset ;;
  conf)    shift; conf "$@" ;;
  reloads) reloads ;;
  logs)    need_cluster; $K -n nginx-ingress logs "$(nic_pod)" --tail="${2:-50}" ;;
  pki)     pki ;;
  plus)    shift; plus "$@" ;;
  down)    plus api-stop 2>/dev/null; kind delete cluster --name $CLUSTER ;;
  help|*)
    cat <<'EOF'
./lab.sh up [--no-nic]   create the cluster (if needed), lab certs, the apps, and the ingress controller
./lab.sh check           is everything ready?
./lab.sh nic             install (or re-apply lab/nic-values.yaml to) the ingress controller
./lab.sh reset           remove your Ingresses, VirtualServers, routes, policies and secrets; restore apps and controller
./lab.sh conf [FILE|-T]  list the controller's generated config files, show one, or nginx -T
./lab.sh reloads         how many times NGINX reloaded, and why (endpoints / other)
./lab.sh logs [N]        the controller's last N log lines
./lab.sh pki             new lab certificates (same CA)
./lab.sh plus up|down|api|api-stop|reloads|conf|logs   the NGINX Plus side quest
./lab.sh down            delete the cluster (everything in it)
EOF
    ;;
esac

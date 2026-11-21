#!/usr/bin/env bash
# Applies the reference solution to the running lab (./lab.sh reset first for a clean start).
set -euo pipefail
LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$LAB"
kubectl -n transit create secret tls transit-tls --cert=certs/transit.crt --key=certs/transit.key --dry-run=client -o yaml | kubectl apply -f -
kubectl -n transit create secret generic dispatch-users --type=nginx.org/htpasswd --from-file=htpasswd=secrets/htpasswd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f solution/transit-vs.yaml -f solution/fares-vsr.yaml -f solution/arrivals-v1.yaml
helm upgrade nic oci://ghcr.io/nginx/charts/nginx-ingress --version 2.9.0 -n nginx-ingress \
  -f nic-values.yaml -f solution/nic-settings.yaml --wait
kubectl -n transit rollout status deploy/arrivals-v1 --timeout=120s
kubectl get vs,vsr -A

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

CERT_MANAGER_TIMEOUT="${CERT_MANAGER_TIMEOUT:-300s}"

need helm
need kubectl

log "configuring cert-manager Helm repo"
helm repo add jetstack https://charts.jetstack.io --force-update
helm repo update

log "installing cert-manager"
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --wait \
  --timeout "${CERT_MANAGER_TIMEOUT}"

kubectl -n cert-manager rollout status deploy/cert-manager --timeout="${CERT_MANAGER_TIMEOUT}"
kubectl -n cert-manager rollout status deploy/cert-manager-cainjector --timeout="${CERT_MANAGER_TIMEOUT}"
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout="${CERT_MANAGER_TIMEOUT}"

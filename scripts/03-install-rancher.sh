#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

detect_host_ip() {
  local ip_addr=""
  ip_addr="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  if [[ -n "${ip_addr}" ]]; then
    printf '%s\n' "${ip_addr}"
    return
  fi
  printf '127.0.0.1\n'
}

wait_for_url() {
  local url="$1"
  local timeout_seconds="$2"
  local waited=0

  until curl -kfsS "${url}" >/dev/null 2>&1; do
    if (( waited >= timeout_seconds )); then
      die "timed out waiting for ${url}"
    fi
    sleep 5
    waited=$((waited + 5))
  done
}

detect_ingress_class() {
  local ingress_class=""

  for ingress_class in nginx traefik; do
    if kubectl get ingressclass "${ingress_class}" >/dev/null 2>&1; then
      printf '%s\n' "${ingress_class}"
      return
    fi
  done

  kubectl get ingressclass -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

wait_for_ingress_class() {
  local timeout_seconds="$1"
  local waited=0
  local detected_class=""

  if [[ -n "${RANCHER_INGRESS_CLASS}" ]]; then
    until kubectl get ingressclass "${RANCHER_INGRESS_CLASS}" >/dev/null 2>&1; do
      if (( waited >= timeout_seconds )); then
        die "timed out waiting for ingress class ${RANCHER_INGRESS_CLASS}"
      fi
      sleep 5
      waited=$((waited + 5))
    done
    return
  fi

  until detected_class="$(detect_ingress_class)" && [[ -n "${detected_class}" ]]; do
    if (( waited >= timeout_seconds )); then
      die "timed out waiting for an ingress class"
    fi
    sleep 5
    waited=$((waited + 5))
  done

  RANCHER_INGRESS_CLASS="${detected_class}"
}

wait_for_nginx_admission() {
  local timeout_seconds="$1"
  local waited=0
  local endpoint_ips=""

  if [[ "${RANCHER_INGRESS_CLASS}" != "nginx" ]]; then
    return
  fi

  if ! kubectl -n kube-system get service rke2-ingress-nginx-controller-admission >/dev/null 2>&1; then
    return
  fi

  kubectl -n kube-system rollout status daemonset/rke2-ingress-nginx-controller --timeout="${timeout_seconds}s"

  until endpoint_ips="$(kubectl -n kube-system get endpoints rke2-ingress-nginx-controller-admission -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)" && [[ -n "${endpoint_ips}" ]]; do
    if (( waited >= timeout_seconds )); then
      die "timed out waiting for rke2-ingress-nginx admission endpoints"
    fi
    sleep 5
    waited=$((waited + 5))
  done
}

complete_rancher_bootstrap() {
  local rancher_url="https://${RANCHER_HOSTNAME}"
  local eula_agreed_at=""

  if [[ "${RANCHER_BOOTSTRAP_COMPLETE}" != "true" ]]; then
    return
  fi

  eula_agreed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  log "configuring Rancher first-login settings"
  kubectl wait --for=condition=Established crd/settings.management.cattle.io --timeout="${RANCHER_TIMEOUT}"
  kubectl apply -f - <<EOF
apiVersion: management.cattle.io/v3
kind: Setting
metadata:
  name: server-url
value: "${rancher_url}"
---
apiVersion: management.cattle.io/v3
kind: Setting
metadata:
  name: first-login
value: "false"
---
apiVersion: management.cattle.io/v3
kind: Setting
metadata:
  name: eula-agreed
value: "${eula_agreed_at}"
EOF
}

RANCHER_TIMEOUT="${RANCHER_TIMEOUT:-600s}"
RANCHER_INGRESS_READY_TIMEOUT="${RANCHER_INGRESS_READY_TIMEOUT:-300}"
HOST_IP="${HOST_IP:-$(detect_host_ip)}"
RANCHER_HOSTNAME="${RANCHER_HOSTNAME:-${HOST_IP}.sslip.io}"
RANCHER_BOOTSTRAP_PASSWORD="${RANCHER_BOOTSTRAP_PASSWORD:-password}"
RANCHER_BOOTSTRAP_COMPLETE="${RANCHER_BOOTSTRAP_COMPLETE:-true}"
RANCHER_HELM_REPO_CHANNEL="${RANCHER_HELM_REPO_CHANNEL:-stable}"
RANCHER_CHART_VERSION="${RANCHER_CHART_VERSION:-}"
RANCHER_INGRESS_CLASS="${RANCHER_INGRESS_CLASS:-}"

case "${RANCHER_HELM_REPO_CHANNEL}" in
  stable|latest|alpha) ;;
  *) die "unsupported RANCHER_HELM_REPO_CHANNEL=${RANCHER_HELM_REPO_CHANNEL}; expected stable, latest, or alpha" ;;
esac

RANCHER_HELM_REPO_NAME="rancher-${RANCHER_HELM_REPO_CHANNEL}"
RANCHER_HELM_REPO_URL="https://releases.rancher.com/server-charts/${RANCHER_HELM_REPO_CHANNEL}"

need curl
need helm
need kubectl

log "configuring Rancher Helm repo"
helm repo add "${RANCHER_HELM_REPO_NAME}" "${RANCHER_HELM_REPO_URL}" --force-update
helm repo update

log "waiting for ingress controller"
wait_for_ingress_class "${RANCHER_INGRESS_READY_TIMEOUT}"
wait_for_nginx_admission "${RANCHER_INGRESS_READY_TIMEOUT}"

log "installing Rancher"
helm_args=(
  upgrade --install rancher "${RANCHER_HELM_REPO_NAME}/rancher"
  --namespace cattle-system
  --create-namespace
  --set hostname="${RANCHER_HOSTNAME}"
  --set replicas=1
  --set bootstrapPassword="${RANCHER_BOOTSTRAP_PASSWORD}"
  --set ingress.ingressClassName="${RANCHER_INGRESS_CLASS}"
  --wait
  --timeout "${RANCHER_TIMEOUT}"
)

if [[ -n "${RANCHER_CHART_VERSION}" ]]; then
  helm_args+=(--version "${RANCHER_CHART_VERSION}")
fi

if [[ "${RANCHER_HELM_REPO_CHANNEL}" == "alpha" ]]; then
  helm_args+=(--devel)
fi

helm "${helm_args[@]}"

kubectl -n cattle-system rollout status deploy/rancher --timeout="${RANCHER_TIMEOUT}"
complete_rancher_bootstrap
kubectl -n cattle-system get ingress rancher

log "waiting for Rancher ping"
wait_for_url "https://${RANCHER_HOSTNAME}/ping" 300

printf 'Rancher URL: https://%s\n' "${RANCHER_HOSTNAME}"

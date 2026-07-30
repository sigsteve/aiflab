#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

RUNTIME_READY_TIMEOUT="${RUNTIME_READY_TIMEOUT:-300s}"

need curl
need sudo

write_user_kubeconfig() {
  local kubeconfig_dir=""

  kubeconfig_dir="$(dirname "${KUBECONFIG_PATH}")"
  sudo install -d -m 700 \
    -o "${KUBECONFIG_OWNER_UID}" \
    -g "${KUBECONFIG_OWNER_GID}" \
    "${kubeconfig_dir}"
  sudo install -m 600 \
    -o "${KUBECONFIG_OWNER_UID}" \
    -g "${KUBECONFIG_OWNER_GID}" \
    "${RUNTIME_KUBECONFIG}" \
    "${KUBECONFIG_PATH}"

  sudo chmod 640 "${RUNTIME_KUBECONFIG}"
  sudo chown ":${KUBECONFIG_OWNER_GID}" "${RUNTIME_KUBECONFIG}"
}

install_rke2() {
  if command -v rke2 >/dev/null 2>&1 && sudo test -f "${RUNTIME_KUBECONFIG}"; then
    log "using existing RKE2"
  else
    log "installing RKE2"
    curl -sfL https://get.rke2.io | sudo sh -
  fi

  log "enabling RKE2 server"
  sudo systemctl enable rke2-server.service

  log "starting RKE2 server"
  sudo systemctl start rke2-server.service
}

install_k3s() {
  if find_k3s >/dev/null 2>&1 && sudo test -f "${RUNTIME_KUBECONFIG}"; then
    log "using existing k3s"
  else
    log "installing k3s"
    curl -sfL https://get.k3s.io | sudo sh -
  fi
}

if [[ "${INSTALL_RUNTIME}" == "rke2" ]]; then
  install_rke2
else
  install_k3s
fi

log "waiting for runtime kubeconfig at ${RUNTIME_KUBECONFIG}"
for _ in $(seq 1 60); do
  if sudo test -f "${RUNTIME_KUBECONFIG}"; then
    break
  fi
  sleep 2
done

if ! sudo test -f "${RUNTIME_KUBECONFIG}"; then
  die "runtime kubeconfig did not appear at ${RUNTIME_KUBECONFIG}"
fi

log "installing kubeconfig at ${KUBECONFIG_PATH}"
write_user_kubeconfig

log "waiting for Kubernetes node to exist"
for _ in $(seq 1 60); do
  if kubectl get nodes --no-headers 2>/dev/null | grep -q .; then
    break
  fi
  sleep 2
done

if ! kubectl get nodes --no-headers 2>/dev/null | grep -q .; then
  die "${INSTALL_RUNTIME} started, but no Kubernetes nodes appeared"
fi

log "waiting for Kubernetes node readiness"
kubectl wait --for=condition=Ready node --all --timeout="${RUNTIME_READY_TIMEOUT}"
kubectl get nodes

log "refreshing kubeconfig at ${KUBECONFIG_PATH}"
write_user_kubeconfig

log "for this shell, run: source ${SCRIPT_DIR}/common.sh"

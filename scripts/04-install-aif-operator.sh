#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

wait_for_crd() {
  local crd="$1"

  for _ in $(seq 1 60); do
    if kubectl get "crd/${crd}" >/dev/null 2>&1; then
      kubectl wait --for=condition=Established "crd/${crd}" --timeout="${AIF_TIMEOUT}" >/dev/null
      return
    fi
    sleep 2
  done

  die "timed out waiting for CRD ${crd}"
}

AIF_RELEASE="${AIF_RELEASE:-aif-operator}"
AIF_NAMESPACE="${AIF_NAMESPACE:-aif-operator}"
AIF_CHART="${AIF_CHART:-oci://ghcr.io/suse/chart/aif-operator}"
AIF_CHART_VERSION="${AIF_CHART_VERSION:-2.0.1}"
AIF_TIMEOUT="${AIF_TIMEOUT:-600s}"
AIF_UI_ENABLED="${AIF_UI_ENABLED:-true}"
AIF_UI_CR_NAME="${AIF_UI_CR_NAME:-aif-ui}"

need helm
need kubectl

log "checking Rancher and cert-manager CRDs"
wait_for_crd certificates.cert-manager.io
wait_for_crd clusterrepos.catalog.cattle.io
wait_for_crd uiplugins.catalog.cattle.io

log "installing AIF operator chart"
helm upgrade --install "${AIF_RELEASE}" "${AIF_CHART}" \
  --version "${AIF_CHART_VERSION}" \
  --namespace "${AIF_NAMESPACE}" \
  --create-namespace \
  --set "aiExtension.enabled=${AIF_UI_ENABLED}" \
  --wait \
  --timeout "${AIF_TIMEOUT}"

log "waiting for AIF operator deployment"
kubectl -n "${AIF_NAMESPACE}" wait deployment \
  --for=condition=Available \
  --selector "app.kubernetes.io/instance=${AIF_RELEASE},app.kubernetes.io/name=aif-operator" \
  --timeout="${AIF_TIMEOUT}"

wait_for_crd aiworkloads.ai-factory.suse.com
wait_for_crd blueprints.ai-factory.suse.com
wait_for_crd installaiextensions.ai-factory.suse.com
wait_for_crd settings.ai-factory.suse.com

if [[ "${AIF_UI_ENABLED}" == "true" ]]; then
  log "waiting for AIF UI extension"
  kubectl wait \
    --for=jsonpath='{.status.phase}'=Installed \
    "installaiextensions.ai-factory.suse.com/${AIF_UI_CR_NAME}" \
    --timeout="${AIF_TIMEOUT}"
fi

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

resolve_aif_chart_version() {
  local chart_metadata=""
  local resolved_version=""
  local -a show_args=(show chart "${AIF_CHART}")

  if [[ -n "${AIF_CHART_VERSION}" ]]; then
    show_args+=(--version "${AIF_CHART_VERSION}")
  fi

  if ! chart_metadata="$(helm "${show_args[@]}")"; then
    die "could not resolve an AI Factory chart version from ${AIF_CHART}"
  fi
  resolved_version="$(
    awk '/^version:[[:space:]]/ { gsub(/["'\'']/, "", $2); print $2; exit }' \
      <<<"${chart_metadata}"
  )"
  [[ -n "${resolved_version}" ]] ||
    die "AI Factory chart metadata from ${AIF_CHART} has no version"

  printf '%s\n' "${resolved_version}"
}

AIF_RELEASE="${AIF_RELEASE:-aif-operator}"
AIF_NAMESPACE="${AIF_NAMESPACE:-aif-operator}"
AIF_CHART="${AIF_CHART:-oci://ghcr.io/suse/chart/aif-operator}"
AIF_CHART_VERSION="${AIF_CHART_VERSION:-}"
AIF_TIMEOUT="${AIF_TIMEOUT:-600s}"
AIF_UI_ENABLED="${AIF_UI_ENABLED:-true}"
AIF_UI_CR_NAME="${AIF_UI_CR_NAME:-aif-ui}"

need helm
need kubectl

requested_chart_version="${AIF_CHART_VERSION}"
resolved_chart_version="$(resolve_aif_chart_version)"
if [[ -z "${requested_chart_version}" ]]; then
  log "selected latest stable AI Factory chart ${resolved_chart_version}"
elif [[ "${requested_chart_version}" == "${resolved_chart_version}" ]]; then
  log "selected pinned AI Factory chart ${resolved_chart_version}"
else
  log "resolved AI Factory chart constraint ${requested_chart_version} to ${resolved_chart_version}"
fi

log "checking Rancher and cert-manager CRDs"
wait_for_crd certificates.cert-manager.io
wait_for_crd clusterrepos.catalog.cattle.io
wait_for_crd uiplugins.catalog.cattle.io

log "installing AIF operator chart"
helm upgrade --install "${AIF_RELEASE}" "${AIF_CHART}" \
  --version "${resolved_chart_version}" \
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
  ui_generation="$(
    kubectl get \
      "installaiextensions.ai-factory.suse.com/${AIF_UI_CR_NAME}" \
      -o jsonpath='{.metadata.generation}'
  )"
  [[ -n "${ui_generation}" ]] ||
    die "could not determine the desired AIF UI extension generation"
  kubectl wait \
    --for=jsonpath='{.status.observedGeneration}'="${ui_generation}" \
    "installaiextensions.ai-factory.suse.com/${AIF_UI_CR_NAME}" \
    --timeout="${AIF_TIMEOUT}"
  kubectl wait \
    --for=jsonpath='{.status.phase}'=Installed \
    "installaiextensions.ai-factory.suse.com/${AIF_UI_CR_NAME}" \
    --timeout="${AIF_TIMEOUT}"

  ui_chart_version="$(
    kubectl get \
      "installaiextensions.ai-factory.suse.com/${AIF_UI_CR_NAME}" \
      -o jsonpath='{.spec.source.helm.version}'
  )"
  log "AI Factory chart ${resolved_chart_version} is ready with UI chart ${ui_chart_version}"
fi

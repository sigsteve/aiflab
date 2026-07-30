#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/common.sh
. "${SCRIPT_DIR}/../../scripts/common.sh"
CONTROL_NAMESPACE="aiflab-kubeflow"
DELETE_TIMEOUT="${KUBEFLOW_DELETE_TIMEOUT:-20m}"

usage() {
  cat <<'EOF'
Usage: ./cleanup.sh

Delete the dedicated Kubeflow demo through AI Factory, in reverse dependency
order. Keep the prerequisite-owned chart repository available until the main
workload is gone, then remove the dedicated namespaces and data. This is
intentionally destructive; do not run it against namespaces or Istio resources
shared with another deployment. Shared AIFLab platform storage is retained.
AI Factory platform credentials are also retained for other Blueprints.
EOF
}

case "${1:-}" in
  "") ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

command -v kubectl >/dev/null 2>&1 || {
  echo "kubectl is required" >&2
  exit 1
}

# Remove the optional validation object while its KServe controller is present.
if kubectl get crd inferenceservices.serving.kserve.io >/dev/null 2>&1; then
  kubectl -n kubeflow-user-example-com delete \
    inferenceservice.serving.kserve.io/aiflab-kserve-check \
    --ignore-not-found --wait=true --timeout="${DELETE_TIMEOUT}"
fi

delete_workload() {
  local workload="$1"

  kubectl -n "${CONTROL_NAMESPACE}" delete \
    "aiworkload.ai-factory.suse.com/${workload}" \
    --ignore-not-found --wait=true \
    --timeout="${DELETE_TIMEOUT}"
}

# The main release owns its nested PostgreSQL chart and may need to fetch the
# hydrated chart again while uninstalling. The bootstrap workload owns the
# kubeflow-chart-repository Deployment and Service, so remove it only after the
# main workload and ClusterRepo are gone.
delete_workload aiflab-kubeflow
kubectl delete clusterrepo.catalog.cattle.io \
  aiflab-kubeflow-hydrated \
  --ignore-not-found
delete_workload aiflab-kubeflow-bootstrap
delete_workload aiflab-kubeflow-istio

# The upstream Istio chart creates this as a pre-install hook, so Helm does not
# include it in release ownership or remove it during uninstall.
kubectl delete mutatingwebhookconfiguration.admissionregistration.k8s.io \
  istio-sidecar-injector \
  --ignore-not-found

kubectl delete blueprint.ai-factory.suse.com \
  -l 'app.kubernetes.io/part-of=aiflab-kubeflow' \
  --ignore-not-found

kubectl delete namespace \
  kubeflow-user-example-com knative-serving kubeflow istio-system \
  "${CONTROL_NAMESPACE}" \
  --ignore-not-found --wait=true --timeout="${DELETE_TIMEOUT}"

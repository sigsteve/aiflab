#!/usr/bin/env bash
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$(cd "${DEPLOY_DIR}/.." && pwd)"
ROOT_DIR="$(cd "${EXAMPLE_DIR}/../.." && pwd)"
CONTROLLER_DIR="${EXAMPLE_DIR}/controller"
IMAGE="${MODELPROBE_IMAGE:-localhost/xtk-modelprobe-controller:0.1.0}"
KUBECTL=(kubectl)

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

command -v kubectl >/dev/null || fail 'kubectl is required and must be on PATH.'
command -v node >/dev/null || fail 'Node.js is required and must be on PATH.'
[[ "${IMAGE}" =~ ^[A-Za-z0-9._/:@-]+$ ]] ||
  fail 'MODELPROBE_IMAGE contains unsupported characters.'

if [[ -n "${KUBECTL_CONTEXT:-}" ]]; then
  KUBECTL+=(--context "${KUBECTL_CONTEXT}")
fi

ENGINE="${CONTAINER_ENGINE:-}"
if [[ -n "${ENGINE}" ]]; then
  command -v "${ENGINE}" >/dev/null ||
    fail "CONTAINER_ENGINE command '${ENGINE}' was not found."
  "${ENGINE}" info >/dev/null 2>&1 ||
    fail "CONTAINER_ENGINE command '${ENGINE}' is not usable."
elif command -v docker >/dev/null && docker info >/dev/null 2>&1; then
  ENGINE=docker
elif command -v podman >/dev/null && podman info >/dev/null 2>&1; then
  ENGINE=podman
else
  fail 'Docker or Podman is required to build the controller image.'
fi

"${ENGINE}" build --tag "${IMAGE}" "${CONTROLLER_DIR}"

PULL_POLICY="${MODELPROBE_PULL_POLICY:-IfNotPresent}"
if [[ "${IMAGE}" == localhost/* ]]; then
  RKE2_DATA_DIR="${RKE2_DATA_DIR:-/var/lib/rancher/rke2}"
  CTR="${CONTAINERD_CLI:-$(command -v ctr || true)}"
  CTR="${CTR:-${RKE2_DATA_DIR}/bin/ctr}"
  CONTAINERD_ADDRESS="${CONTAINERD_ADDRESS:-/run/k3s/containerd/containerd.sock}"
  [[ -x "${CTR}" ]] ||
    fail 'containerd CLI was not found. Set CONTAINERD_CLI or use MODELPROBE_IMAGE.'
  IMAGE_ARCHIVE="$(mktemp)"
  trap 'rm -f "${IMAGE_ARCHIVE}"' EXIT
  "${ENGINE}" save --output "${IMAGE_ARCHIVE}" "${IMAGE}"

  if [[ "${EUID}" -eq 0 ]]; then
    "${CTR}" \
      --address "${CONTAINERD_ADDRESS}" \
      --namespace k8s.io \
      images import "${IMAGE_ARCHIVE}"
  else
    command -v sudo >/dev/null ||
      fail 'sudo is required to load a local image into RKE2.'
    sudo -n "${CTR}" \
      --address "${CONTAINERD_ADDRESS}" \
      --namespace k8s.io \
      images import "${IMAGE_ARCHIVE}" ||
      fail 'RKE2 image import failed. Configure passwordless sudo or use MODELPROBE_IMAGE.'
  fi
  PULL_POLICY=Never
else
  "${ENGINE}" push "${IMAGE}"
fi

"${KUBECTL[@]}" apply -f "${DEPLOY_DIR}/crd.yaml"
"${KUBECTL[@]}" wait \
  --for=condition=Established \
  crd/modelprobes.xtk.aiflab.io \
  --timeout=60s
sed \
  -e "s|image: localhost/xtk-modelprobe-controller:0.1.0|image: ${IMAGE}|" \
  -e "s|imagePullPolicy: Never|imagePullPolicy: ${PULL_POLICY}|" \
  "${DEPLOY_DIR}/controller.yaml" |
  "${KUBECTL[@]}" apply -f -
"${KUBECTL[@]}" -n xtk-system rollout restart \
  deployment/modelprobe-controller
"${KUBECTL[@]}" -n xtk-system rollout status \
  deployment/modelprobe-controller \
  --timeout=120s

node "${ROOT_DIR}/deploy/extension.mjs" deploy "${EXAMPLE_DIR}"
"${KUBECTL[@]}" apply -f "${DEPLOY_DIR}/samples.yaml"
"${KUBECTL[@]}" get modelprobes -A

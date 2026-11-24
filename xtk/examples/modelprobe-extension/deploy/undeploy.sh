#!/usr/bin/env bash
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$(cd "${DEPLOY_DIR}/.." && pwd)"
ROOT_DIR="$(cd "${EXAMPLE_DIR}/../.." && pwd)"
KUBECTL=(kubectl)

command -v kubectl >/dev/null || {
  printf 'Error: kubectl is required and must be on PATH.\n' >&2
  exit 1
}
command -v node >/dev/null || {
  printf 'Error: Node.js is required and must be on PATH.\n' >&2
  exit 1
}

if [[ -n "${KUBECTL_CONTEXT:-}" ]]; then
  KUBECTL+=(--context "${KUBECTL_CONTEXT}")
fi

"${KUBECTL[@]}" delete -f "${DEPLOY_DIR}/samples.yaml" --ignore-not-found
node "${ROOT_DIR}/deploy/extension.mjs" undeploy "${EXAMPLE_DIR}"
"${KUBECTL[@]}" delete -f "${DEPLOY_DIR}/controller.yaml" --ignore-not-found
"${KUBECTL[@]}" delete -f "${DEPLOY_DIR}/crd.yaml" --ignore-not-found

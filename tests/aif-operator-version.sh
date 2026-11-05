#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
AIFLAB_DIR="$(cd -- "${TEST_DIR}/.." && pwd)"
INSTALL_SCRIPT="${AIFLAB_DIR}/scripts/04-install-aif-operator.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local value="$1"
  local expected="$2"
  local context="$3"

  [[ "${value}" == *"${expected}"* ]] ||
    fail "${context}: expected output to contain: ${expected}"
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
STATE_DIR="${TMP_DIR}/state"
FAKE_BIN_DIR="${TMP_DIR}/bin"
mkdir -p "${STATE_DIR}" "${FAKE_BIN_DIR}"

cat >"${FAKE_BIN_DIR}/helm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%q ' "$@" >>"${FAKE_STATE_DIR:?}/helm-calls"
printf '\n' >>"${FAKE_STATE_DIR}/helm-calls"

if [[ "${1:-}" == "show" && "${2:-}" == "chart" ]]; then
  resolved_version="${FAKE_LATEST_VERSION:?}"
  while (($#)); do
    if [[ "$1" == "--version" ]]; then
      resolved_version="$2"
      break
    fi
    shift
  done
  if [[ "${resolved_version}" == '^2.0.0' ]]; then
    resolved_version="${FAKE_LATEST_VERSION}"
  fi
  printf 'apiVersion: v2\nname: aif-operator\nversion: %s\n' \
    "${resolved_version}"
  exit 0
fi

if [[ "${1:-}" == "upgrade" && "${2:-}" == "--install" ]]; then
  installed_version=""
  while (($#)); do
    if [[ "$1" == "--version" ]]; then
      installed_version="$2"
      break
    fi
    shift
  done
  [[ -n "${installed_version}" ]]
  printf '%s' "${installed_version}" >"${FAKE_STATE_DIR}/installed-version"
  exit 0
fi

printf 'unexpected fake helm invocation: %s\n' "$*" >&2
exit 1
EOF

cat >"${FAKE_BIN_DIR}/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%q ' "$@" >>"${FAKE_STATE_DIR:?}/kubectl-calls"
printf '\n' >>"${FAKE_STATE_DIR}/kubectl-calls"

if [[ "$*" == *"-o jsonpath={.metadata.generation}"* ]]; then
  printf '7'
elif [[ "$*" == *"-o jsonpath={.spec.source.helm.version}"* ]]; then
  cat "${FAKE_STATE_DIR}/installed-version"
fi
EOF

chmod 700 "${FAKE_BIN_DIR}/helm" "${FAKE_BIN_DIR}/kubectl"

run_install() {
  env \
    PATH="${FAKE_BIN_DIR}:${PATH}" \
    INSTALL_RUNTIME=rke2 \
    RKE2_KUBECTL_BIN="${FAKE_BIN_DIR}/kubectl" \
    SYSTEM_KUBECTL_BIN="${FAKE_BIN_DIR}/kubectl" \
    KUBECONFIG_PATH="${TMP_DIR}/kubeconfig" \
    FAKE_STATE_DIR="${STATE_DIR}" \
    FAKE_LATEST_VERSION=2.2.0 \
    AIF_RELEASE=aif-operator \
    AIF_NAMESPACE=aif-operator \
    AIF_CHART=oci://ghcr.io/suse/chart/aif-operator \
    AIF_TIMEOUT=1s \
    AIF_CHART_VERSION= \
    AIF_UI_ENABLED=true \
    AIF_UI_CR_NAME=aif-ui \
    "$@" "${INSTALL_SCRIPT}"
}

reset_state() {
  rm -rf "${STATE_DIR}"
  mkdir -p "${STATE_DIR}"
}

# With no override, resolve the latest stable chart once and install that exact
# result so a newly published tag cannot change the selection midway through a
# deployment.
reset_state
output="$(run_install)"
assert_contains "${output}" \
  'selected latest stable AI Factory chart 2.2.0' 'latest selection'
assert_contains "$(sed -n '1p' "${STATE_DIR}/helm-calls")" \
  'show chart oci://ghcr.io/suse/chart/aif-operator' 'latest lookup'
[[ "$(sed -n '1p' "${STATE_DIR}/helm-calls")" != *'--version'* ]] ||
  fail 'latest lookup unexpectedly supplied a version pin'
assert_contains "$(sed -n '2p' "${STATE_DIR}/helm-calls")" \
  '--version 2.2.0' 'resolved install'
assert_contains "${output}" \
  'AI Factory chart 2.2.0 is ready with UI chart 2.2.0' \
  'latest paired UI chart'
assert_contains "$(cat "${STATE_DIR}/kubectl-calls")" \
  '--for=jsonpath=\{.status.observedGeneration\}=7' 'UI generation wait'

# An exact pin remains available for reproducible or compatibility-sensitive
# installs.
reset_state
output="$(run_install AIF_CHART_VERSION=2.1.0)"
assert_contains "${output}" \
  'selected pinned AI Factory chart 2.1.0' 'pinned selection'
assert_contains "$(sed -n '1p' "${STATE_DIR}/helm-calls")" \
  '--version 2.1.0' 'pinned lookup'
assert_contains "$(sed -n '2p' "${STATE_DIR}/helm-calls")" \
  '--version 2.1.0' 'pinned install'
assert_contains "${output}" \
  'AI Factory chart 2.1.0 is ready with UI chart 2.1.0' \
  'pinned paired UI chart'

# Helm constraints provide an opt-in middle ground between a fixed pin and all
# future stable releases.
reset_state
output="$(run_install 'AIF_CHART_VERSION=^2.0.0')"
assert_contains "${output}" \
  'resolved AI Factory chart constraint ^2.0.0 to 2.2.0' \
  'constraint selection'
assert_contains "$(sed -n '2p' "${STATE_DIR}/helm-calls")" \
  '--version 2.2.0' 'constraint install'

printf 'PASS: AI Factory chart version selection\n'

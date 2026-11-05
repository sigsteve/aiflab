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
  [[ "$1" == *"$2"* ]] || fail "expected output to contain: $2"
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
STATE_DIR="${TMP_DIR}/state"
FAKE_BIN_DIR="${TMP_DIR}/bin"
mkdir -p "${STATE_DIR}" "${FAKE_BIN_DIR}"

cat >"${FAKE_BIN_DIR}/helm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == show && "${2:-}" == chart ]]; then
  printf 'apiVersion: v2\nname: aif-operator\nversion: 2.4.0\n'
  exit 0
fi

if [[ "${1:-}" == upgrade && "${2:-}" == --install ]]; then
  : >"${FAKE_STATE_DIR:?}/helm-invoked"
  # Model Helm's manifest validation before it can run the chart's readiness
  # hook. Fleet CRDs must already be established and namespaces must exist.
  for crd in certificates.cert-manager.io clusterrepos.catalog.cattle.io \
    uiplugins.catalog.cattle.io bundles.fleet.cattle.io \
    gitrepos.fleet.cattle.io bundledeployments.fleet.cattle.io; do
    [[ -e "${FAKE_STATE_DIR:?}/crd_${crd}.established" ]] || {
      printf 'resource mapping not found: prerequisite CRD %s is not ready\n' "${crd}" >&2
      exit 1
    }
  done
  for namespace in fleet-local cattle-ui-plugin-system; do
    [[ -e "${FAKE_STATE_DIR}/namespace_${namespace}.created" ]] || {
      printf 'namespace %s does not exist\n' "${namespace}" >&2
      exit 1
    }
  done
  : >"${FAKE_STATE_DIR}/installed"
  exit 0
fi

printf 'unexpected fake helm invocation: %s\n' "$*" >&2
exit 1
EOF

cat >"${FAKE_BIN_DIR}/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == -n && -e "${FAKE_STATE_DIR}/installed" ]]; then
  exit 0
fi

operation="${1:-}"
condition=""
resource=""
for arg in "$@"; do
  case "${arg}" in
    --for=*) condition="${arg#--for=}" ;;
    crd/*|namespace/*) resource="${arg}" ;;
  esac
done
[[ -n "${resource}" ]] || {
  printf 'unexpected fake kubectl invocation: %s\n' "$*" >&2
  exit 1
}
marker="${FAKE_STATE_DIR}/${resource//\//_}"

# These CRDs are present when Rancher first answers /ping. Fleet's CRDs and
# namespaces deliberately arrive later, during a wait for their creation.
case "${resource}" in
  crd/certificates.cert-manager.io|crd/clusterrepos.catalog.cattle.io|crd/uiplugins.catalog.cattle.io)
    : >"${marker}.created"
    ;;
  crd/*.ai-factory.suse.com)
    [[ -e "${FAKE_STATE_DIR}/installed" ]] || exit 1
    : >"${marker}.created"
    ;;
esac

if [[ "${operation}" == get ]]; then
  [[ -e "${marker}.created" ]]
  exit
fi

[[ "${operation}" == wait && "$*" == *"--timeout=7m30s"* ]] || {
  printf 'wait did not honor AIF_TIMEOUT: %s\n' "$*" >&2
  exit 1
}
case "${condition}" in
  create)
    if [[ "${resource}" == "${FAKE_FAIL_CREATE:-}" ]]; then
      printf 'error: timed out waiting for creation of %s\n' "${resource}" >&2
      exit 1
    fi
    : >"${marker}.created"
    ;;
  condition=Established)
    if [[ "${resource}" == "${FAKE_FAIL_ESTABLISHED:-}" ]]; then
      printf 'error: timed out waiting for establishment of %s\n' "${resource}" >&2
      exit 1
    fi
    [[ -e "${marker}.created" ]] || exit 1
    : >"${marker}.established"
    ;;
  *)
    printf 'unexpected wait condition: %s\n' "${condition}" >&2
    exit 1
    ;;
esac
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
    FAKE_FAIL_CREATE= \
    FAKE_FAIL_ESTABLISHED= \
    AIF_RELEASE=aif-operator \
    AIF_NAMESPACE=aif-operator \
    AIF_CHART=oci://ghcr.io/suse/chart/aif-operator \
    AIF_CHART_VERSION=2.4.0 \
    AIF_TIMEOUT=7m30s \
    AIF_UI_ENABLED=false \
    "$@" "${INSTALL_SCRIPT}"
}

reset_state() {
  rm -rf "${STATE_DIR}"
  mkdir -p "${STATE_DIR}"
}

# A fresh Rancher may be serving /ping while Fleet installs asynchronously.
# Helm must not run until the late prerequisites are created and established.
reset_state
run_install
[[ -e "${STATE_DIR}/installed" ]] || fail 'operator was not installed'

# Missing and unestablished CRDs stop before Helm can create a failed release.
reset_state
if output="$(run_install FAKE_FAIL_CREATE=crd/gitrepos.fleet.cattle.io 2>&1)"; then
  fail 'missing Fleet CRD was accepted'
fi
assert_contains "${output}" 'could not wait for crd/gitrepos.fleet.cattle.io'
assert_contains "${output}" '7m30s'
[[ ! -e "${STATE_DIR}/helm-invoked" ]] || fail 'Helm ran without the GitRepo CRD'

reset_state
if output="$(run_install FAKE_FAIL_ESTABLISHED=crd/gitrepos.fleet.cattle.io 2>&1)"; then
  fail 'unestablished Fleet CRD was accepted'
fi
assert_contains "${output}" 'CRD gitrepos.fleet.cattle.io did not become Established'
[[ ! -e "${STATE_DIR}/helm-invoked" ]] || fail 'Helm ran with an unestablished CRD'

# Namespace readiness is required even when the optional AI UI is disabled.
for namespace in fleet-local cattle-ui-plugin-system; do
  reset_state
  if output="$(run_install "FAKE_FAIL_CREATE=namespace/${namespace}" 2>&1)"; then
    fail "missing ${namespace} namespace was accepted"
  fi
  assert_contains "${output}" "could not wait for namespace/${namespace}"
  [[ ! -e "${STATE_DIR}/helm-invoked" ]] || fail 'Helm ran without a prerequisite namespace'
done

printf 'PASS: AI Factory prerequisite readiness and failure handling\n'

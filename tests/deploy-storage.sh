#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
AIFLAB_DIR="$(cd -- "${TEST_DIR}/.." && pwd)"
DEPLOY_SCRIPT="${AIFLAB_DIR}/deploy.sh"
PLATFORM_SOURCE="${AIFLAB_DIR}/platform/local-storage"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local value="$1"
  local expected="$2"

  [[ "${value}" == *"${expected}"* ]] ||
    fail "expected output to contain: ${expected}"
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
STATE_DIR="${TMP_DIR}/state"
FAKE_KUBECTL="${TMP_DIR}/kubectl"
FAKE_AIFCTL="${TMP_DIR}/aifctl"
DEMO_SOURCE="${TMP_DIR}/demo.yaml"
mkdir -p "${STATE_DIR}"
: >"${DEMO_SOURCE}"

cat >"${FAKE_KUBECTL}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" == *"settings.ai-factory.suse.com/settings"* ]]; then
  printf '|||'
  exit 0
fi

[[ "$*" == "get storageclass -o go-template="* ]] || {
  printf 'unexpected kubectl invocation: %s\n' "$*" >&2
  exit 1
}

if [[ -e "${FAKE_STATE_DIR:?}/storage-installed" ]]; then
  printf 'aiflab-local-path\n'
else
  printf '%s' "${FAKE_DEFAULT_STORAGE_CLASSES:-}"
fi
EOF

cat >"${FAKE_AIFCTL}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"${FAKE_STATE_DIR:?}/aifctl-calls"
if [[ "$*" == *"--from ${FAKE_PLATFORM_SOURCE:?}"* &&
      "$*" != *"--dry-run"* ]]; then
  : >"${FAKE_STATE_DIR}/storage-installed"
fi
EOF
chmod 700 "${FAKE_KUBECTL}" "${FAKE_AIFCTL}"

reset_state() {
  rm -rf "${STATE_DIR}"
  mkdir -p "${STATE_DIR}"
}

run_deploy() {
  env \
    INSTALL_RUNTIME=rke2 \
    RKE2_KUBECTL_BIN="${FAKE_KUBECTL}" \
    SYSTEM_KUBECTL_BIN="${FAKE_KUBECTL}" \
    KUBECONFIG_PATH="${TMP_DIR}/kubeconfig" \
    AIFCTL_BIN="${FAKE_AIFCTL}" \
    FAKE_STATE_DIR="${STATE_DIR}" \
    FAKE_PLATFORM_SOURCE="${PLATFORM_SOURCE}" \
    FAKE_DEFAULT_STORAGE_CLASSES="${1:-}" \
    "${DEPLOY_SCRIPT}" --skip-base --from "${DEMO_SOURCE}" --timeout 1m
}

# Base-only operation does not inspect or install demo storage.
reset_state
base_output="$(env \
  INSTALL_RUNTIME=rke2 \
  RKE2_KUBECTL_BIN="${FAKE_KUBECTL}" \
  SYSTEM_KUBECTL_BIN="${FAKE_KUBECTL}" \
  KUBECONFIG_PATH="${TMP_DIR}/kubeconfig" \
  AIFCTL_BIN="${FAKE_AIFCTL}" \
  FAKE_STATE_DIR="${STATE_DIR}" \
  FAKE_PLATFORM_SOURCE="${PLATFORM_SOURCE}" \
  "${DEPLOY_SCRIPT}" --skip-base)"
[[ ! -e "${STATE_DIR}/aifctl-calls" ]] ||
  fail 'base-only operation invoked aifctl'
assert_contains "${base_output}" 'a bare installation is valid, but authenticated Blueprints require platform credentials before deployment'
assert_contains "${base_output}" 'credentials are reused by future Blueprints and are not deleted with a Blueprint'
assert_contains "${base_output}" 'credential status - Application Collection: not configured'
assert_contains "${base_output}" 'credential status - SUSE Registry: not configured'
assert_contains "${base_output}" 'credential status - NVIDIA: not configured'

# A cluster-supplied default is reused and the platform bundle is only parsed.
reset_state
output="$(run_deploy existing-default)"
assert_contains "${output}" 'using existing default StorageClass existing-default'
[[ ! -e "${STATE_DIR}/storage-installed" ]] ||
  fail 'platform storage was installed despite an existing default'
[[ "$(wc -l <"${STATE_DIR}/aifctl-calls")" -eq 3 ]] ||
  fail 'existing-default path should make two dry-run calls and one deployment'
[[ "$(tail -n 1 "${STATE_DIR}/aifctl-calls")" == *"--from ${DEMO_SOURCE} --timeout 1m"* ]] ||
  fail 'demo was not deployed after reusing the default'

# An explicit domain is passed only to the requested deployment.
reset_state
output="$(
  env \
    INSTALL_RUNTIME=rke2 \
    RKE2_KUBECTL_BIN="${FAKE_KUBECTL}" \
    SYSTEM_KUBECTL_BIN="${FAKE_KUBECTL}" \
    KUBECONFIG_PATH="${TMP_DIR}/kubeconfig" \
    AIFCTL_BIN="${FAKE_AIFCTL}" \
    FAKE_STATE_DIR="${STATE_DIR}" \
    FAKE_PLATFORM_SOURCE="${PLATFORM_SOURCE}" \
    FAKE_DEFAULT_STORAGE_CLASSES=existing-default \
    "${DEPLOY_SCRIPT}" --skip-base --from "${DEMO_SOURCE}" \
      --timeout 1m --domain lab.example.test
)"
assert_contains "${output}" 'using existing default StorageClass existing-default'
[[ "$(tail -n 1 "${STATE_DIR}/aifctl-calls")" == *"--domain lab.example.test"* ]] ||
  fail 'explicit domain was not passed to the requested deployment'
[[ "$(sed -n '1p' "${STATE_DIR}/aifctl-calls")" != *"--domain"* ]] ||
  fail 'explicit domain leaked into the platform dry-run'
[[ "$(sed -n '2p' "${STATE_DIR}/aifctl-calls")" == *"--dry-run --domain lab.example.test"* ]] ||
  fail 'explicit domain was not validated before deployment'

# With no default, the shared platform bundle settles before the demo deploys.
reset_state
output="$(run_deploy '')"
assert_contains "${output}" 'no default StorageClass found; installing AIFLab demo local storage'
assert_contains "${output}" 'default StorageClass aiflab-local-path is ready'
[[ -e "${STATE_DIR}/storage-installed" ]] ||
  fail 'platform storage was not installed when no default existed'
[[ "$(sed -n '3p' "${STATE_DIR}/aifctl-calls")" == *"--from ${PLATFORM_SOURCE} --timeout 1m"* ]] ||
  fail 'platform storage was not the first applied bundle'
[[ "$(sed -n '4p' "${STATE_DIR}/aifctl-calls")" == *"--from ${DEMO_SOURCE} --timeout 1m"* ]] ||
  fail 'demo was not applied after platform storage'

# Ambiguous cluster defaults fail closed before either bundle is mutated.
reset_state
if output="$(run_deploy $'first-default\nsecond-default' 2>&1)"; then
  fail 'multiple default StorageClasses were accepted'
fi
assert_contains "${output}" 'multiple default StorageClasses found (first-default second-default)'
[[ "$(wc -l <"${STATE_DIR}/aifctl-calls")" -eq 2 ]] ||
  fail 'multiple-default path should stop after local dry-run validation'

printf 'PASS: deploy storage selection\n'

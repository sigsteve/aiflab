#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
AIFLAB_DIR="$(cd -- "${TEST_DIR}/.." && pwd)"
CREDENTIAL_SCRIPT="${AIFLAB_DIR}/scripts/05-configure-aif-credentials.sh"

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

assert_not_contains() {
  local value="$1"
  local unexpected="$2"
  local context="$3"

  [[ "${value}" != *"${unexpected}"* ]] ||
    fail "${context}: output unexpectedly contained: ${unexpected}"
}

write_env_file() {
  local path="$1"
  shift

  printf '%s\n' "$@" >"${path}"
  chmod 600 "${path}"
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
STATE_DIR="${TMP_DIR}/fake-kubectl"
FAKE_KUBECTL="${TMP_DIR}/kubectl"
mkdir -p "${STATE_DIR}"

cat >"${FAKE_KUBECTL}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_dir="${FAKE_KUBECTL_STATE:?}"
mkdir -p "${state_dir}"
printf '%q ' "$@" >>"${state_dir}/calls"
printf '\n' >>"${state_dir}/calls"
args="$*"

if [[ "${1:-}" == "apply" ]]; then
  cat >"${state_dir}/applied.yaml"
  : >"${state_dir}/applied"
  exit 0
fi

if [[ "${args}" == *"crd/settings.ai-factory.suse.com"* ]]; then
  exit 0
fi

if [[ "${args}" == *"settings.ai-factory.suse.com/settings"* ]]; then
  if [[ "${args}" == *".spec.registryEndpoints.nvidia"* ]]; then
    printf '%s' "${FAKE_NVIDIA_ENDPOINT:-}"
  elif [[ "${args}" == *".spec.applicationCollection."* ]]; then
    printf 'appco\tuser\tappco\ttoken'
  elif [[ "${args}" == *".spec.suseRegistry."* ]]; then
    printf 'suse-registry\tuser\tsuse-registry\ttoken'
  elif [[ "${args}" == *".spec.nvidia."* ]]; then
    printf 'nvidia\tuser\tnvidia\ttoken'
  fi
  exit 0
fi

if [[ "${args}" == *"namespace/cattle-system"* ||
      "${args}" == *"namespace/fleet-local"* ||
      "${args}" == *"namespace/fleet-default"* ]]; then
  for namespace in cattle-system fleet-local fleet-default; do
    if [[ "${args}" == *"namespace/${namespace}"* ]]; then
      printf 'namespace/%s' "${namespace}"
      break
    fi
  done
  exit 0
fi

if [[ "${args}" == *"secret/application-collection-auth"* ||
      "${args}" == *"secret/suse-ai-registry-auth"* ||
      "${args}" == *"secret/ngc-helm-auth"* ]]; then
  if [[ ! -e "${state_dir}/applied" ]]; then
    printf 'b2xkLXVzZXI=\tb2xkLXRva2Vu'
    exit 0
  fi
  if [[ "${FAKE_STALE:-0}" == "1" && "${args}" == *"-n cattle-system"* &&
        ! -e "${state_dir}/mirror-stale-seen" ]]; then
    : >"${state_dir}/mirror-stale-seen"
    printf 'b2xkLXVzZXI=\tb2xkLXRva2Vu'
    exit 0
  fi
  printf '%s\t%s' "${FAKE_EXPECTED_USER_B64:?}" "${FAKE_EXPECTED_TOKEN_B64:?}"
  exit 0
fi

if [[ "${args}" == *"clusterrepo.catalog.cattle.io/"* &&
      "${args}" == *".spec.forceUpdate"* ]]; then
  if [[ ! -e "${state_dir}/applied" ]]; then
    printf '2000-01-01T00:00:00Z'
    exit 0
  fi
  if [[ "${FAKE_STALE:-0}" == "1" && ! -e "${state_dir}/force-stale-seen" ]]; then
    : >"${state_dir}/force-stale-seen"
    printf '2000-01-01T00:00:00Z'
    exit 0
  fi
  printf '2000-01-01T00:00:01Z'
  exit 0
fi

if [[ "${args}" == *"clusterrepo.catalog.cattle.io/"* &&
      "${args}" == *".status.observedGeneration"* ]]; then
  repo_condition='Downloaded'
  if [[ "${args}" == *"application-collection"* ||
        "${args}" == *"suse-ai-registry"* ||
        -n "${FAKE_NVIDIA_ENDPOINT:-}" ]]; then
    repo_condition='OCIDownloaded'
  fi
  if [[ "${FAKE_ALWAYS_STALE:-0}" == "1" ]]; then
    if [[ "${repo_condition}" == 'OCIDownloaded' ]]; then
      printf '2|1||True|True'
    else
      printf '2|1|True||True'
    fi
    exit 0
  fi
  if [[ "${FAKE_STALE:-0}" == "1" && ! -e "${state_dir}/repo-stale-seen" ]]; then
    : >"${state_dir}/repo-stale-seen"
    if [[ "${repo_condition}" == 'OCIDownloaded' ]]; then
      printf '2|1||False|True'
    else
      printf '2|1|False||True'
    fi
    exit 0
  fi
  if [[ "${repo_condition}" == 'OCIDownloaded' ]]; then
    printf '2|2||True|True'
  else
    printf '2|2|True||True'
  fi
  exit 0
fi

if [[ "${args}" == *"clusterrepo.catalog.cattle.io/"* ]]; then
  exit 0
fi

printf 'unexpected fake kubectl invocation: %s\n' "${args}" >&2
exit 1
EOF
chmod 700 "${FAKE_KUBECTL}"

FAKE_EXPECTED_USER_B64=""
FAKE_EXPECTED_TOKEN_B64=""
FAKE_STALE=0
FAKE_NVIDIA_ENDPOINT=""
FAKE_ALWAYS_STALE=0
TEST_TIMEOUT=10

reset_fake_kubectl() {
  rm -rf "${STATE_DIR}"
  mkdir -p "${STATE_DIR}"
  FAKE_EXPECTED_USER_B64="$1"
  FAKE_EXPECTED_TOKEN_B64="$2"
  FAKE_STALE="${3:-0}"
  FAKE_NVIDIA_ENDPOINT="${4:-}"
  FAKE_ALWAYS_STALE="${5:-0}"
}

credential_command() {
  env \
    INSTALL_RUNTIME=rke2 \
    RKE2_KUBECTL_BIN="${FAKE_KUBECTL}" \
    SYSTEM_KUBECTL_BIN="${FAKE_KUBECTL}" \
    KUBECONFIG_PATH="${TMP_DIR}/kubeconfig" \
    AIF_CREDENTIALS_TIMEOUT_SECONDS="${TEST_TIMEOUT}" \
    FAKE_KUBECTL_STATE="${STATE_DIR}" \
    FAKE_EXPECTED_USER_B64="${FAKE_EXPECTED_USER_B64}" \
    FAKE_EXPECTED_TOKEN_B64="${FAKE_EXPECTED_TOKEN_B64}" \
    FAKE_STALE="${FAKE_STALE}" \
    FAKE_NVIDIA_ENDPOINT="${FAKE_NVIDIA_ENDPOINT}" \
    FAKE_ALWAYS_STALE="${FAKE_ALWAYS_STALE}" \
    "$@"
}

run_credentials() {
  credential_command "${CREDENTIAL_SCRIPT}" "$@"
}

expect_validation_failure() {
  local name="$1"
  local expected="$2"
  local file="$3"
  local output=""

  if output="$(run_credentials --env-file "${file}" --validate-only 2>&1)"; then
    fail "${name}: invalid file was accepted"
  fi
  assert_contains "${output}" "${expected}" "${name}"
}

# Parser failures are explicit and fail closed.
malformed="${TMP_DIR}/malformed.env"
write_env_file "${malformed}" \
  'export AIF_APPLICATION_COLLECTION_USERNAME=user' \
  'AIF_APPLICATION_COLLECTION_TOKEN=token'
expect_validation_failure malformed 'invalid assignment on line 1' "${malformed}"

unknown="${TMP_DIR}/unknown.env"
write_env_file "${unknown}" 'AIF_PASSWORD=secret'
expect_validation_failure unknown 'unsupported variable AIF_PASSWORD' "${unknown}"

duplicate="${TMP_DIR}/duplicate.env"
write_env_file "${duplicate}" \
  'AIF_APPLICATION_COLLECTION_USERNAME=user-one' \
  'AIF_APPLICATION_COLLECTION_USERNAME=user-two' \
  'AIF_APPLICATION_COLLECTION_TOKEN=token'
expect_validation_failure duplicate \
  'duplicate variable AIF_APPLICATION_COLLECTION_USERNAME' "${duplicate}"

incomplete="${TMP_DIR}/incomplete.env"
write_env_file "${incomplete}" 'AIF_APPLICATION_COLLECTION_USERNAME=user'
expect_validation_failure incomplete \
  'AppCo credentials require non-empty' "${incomplete}"

# Same-named ambient variables must not silently complete a partial file.
ambient_output=""
if ambient_output="$(
  AIF_APPLICATION_COLLECTION_TOKEN=ambient-token \
    run_credentials --env-file "${incomplete}" --validate-only 2>&1
)"; then
  fail 'ambient credential variable completed an invalid file'
fi
assert_contains "${ambient_output}" 'AppCo credentials require non-empty' \
  'ambient credential isolation'

# The timeout is validated even when no Kubernetes calls would be made.
valid="${TMP_DIR}/valid.env"
write_env_file "${valid}" \
  'AIF_APPLICATION_COLLECTION_USERNAME=user' \
  'AIF_APPLICATION_COLLECTION_TOKEN=token'
TEST_TIMEOUT=invalid
expect_validation_failure timeout \
  'AIF_CREDENTIALS_TIMEOUT_SECONDS must be a positive integer' "${valid}"
TEST_TIMEOUT=10

# Credential files must be private regular files, never symlinks.
chmod 640 "${valid}"
expect_validation_failure permissions \
  'must not be accessible by group or others' "${valid}"
chmod 600 "${valid}"
symlink="${TMP_DIR}/credentials-link.env"
ln -s "${valid}" "${symlink}"
expect_validation_failure symlink \
  'must be a regular, non-symlink file' "${symlink}"

# bash -x must stop tracing before credential values are parsed.
trace_user='TRACE-USER-DO-NOT-LEAK'
trace_token='TRACE-TOKEN-DO-NOT-LEAK'
trace_file="${TMP_DIR}/trace.env"
write_env_file "${trace_file}" \
  "AIF_APPLICATION_COLLECTION_USERNAME=${trace_user}" \
  "AIF_APPLICATION_COLLECTION_TOKEN=${trace_token}"
trace_output="$(credential_command bash -x "${CREDENTIAL_SCRIPT}" \
  --env-file "${trace_file}" --validate-only 2>&1)"
assert_not_contains "${trace_output}" "${trace_user}" 'xtrace username redaction'
assert_not_contains "${trace_output}" "${trace_token}" 'xtrace token redaction'

# AppCo values remain literal, produce only the AppCo Settings fragment, and
# wait through stale mirrors, forceUpdate, and ClusterRepo status on rotation.
no_eval_marker="${TMP_DIR}/must-not-exist"
appco_user="literal-user \$(touch ${no_eval_marker})"
appco_token='literal-token#with=equals and spaces'
appco_file="${TMP_DIR}/appco.env"
write_env_file "${appco_file}" \
  "AIF_APPLICATION_COLLECTION_USERNAME=${appco_user}" \
  "AIF_APPLICATION_COLLECTION_TOKEN=${appco_token}"
appco_user_b64="$(printf '%s' "${appco_user}" | base64 | tr -d '\n')"
appco_token_b64="$(printf '%s' "${appco_token}" | base64 | tr -d '\n')"
reset_fake_kubectl "${appco_user_b64}" "${appco_token_b64}" 1
appco_output="$(run_credentials --env-file "${appco_file}" 2>&1)"
[[ ! -e "${no_eval_marker}" ]] || fail 'literal AppCo value was evaluated'
appco_manifest="$(<"${STATE_DIR}/applied.yaml")"
assert_contains "${appco_manifest}" 'name: appco' 'AppCo Secret name'
assert_contains "${appco_manifest}" "user: ${appco_user_b64}" 'AppCo user data'
assert_contains "${appco_manifest}" "token: ${appco_token_b64}" 'AppCo token data'
assert_contains "${appco_manifest}" 'applicationCollection:' 'AppCo Settings fragment'
assert_not_contains "${appco_manifest}" 'suseRegistry:' 'AppCo omitted Registry settings'
assert_not_contains "${appco_manifest}" '  nvidia:' 'AppCo omitted NVIDIA settings'
assert_not_contains "${appco_output}" "${appco_user}" 'AppCo username logging'
assert_not_contains "${appco_output}" "${appco_token}" 'AppCo token logging'
[[ -e "${STATE_DIR}/mirror-stale-seen" ]] || fail 'stale auth mirror was not exercised'
[[ -e "${STATE_DIR}/force-stale-seen" ]] || fail 'stale forceUpdate was not exercised'
[[ -e "${STATE_DIR}/repo-stale-seen" ]] || fail 'stale ClusterRepo state was not exercised'
appco_calls="$(<"${STATE_DIR}/calls")"
assert_contains "${appco_calls}" '--field-manager=aiflab-appco-credentials' \
  'AppCo field manager'
assert_contains "${appco_calls}" '-n fleet-local get secret/application-collection-auth' \
  'fleet-local auth mirror'
assert_contains "${appco_calls}" '-n fleet-default get secret/application-collection-auth' \
  'fleet-default auth mirror'

# Each optional group uses its own source Secret and minimal Settings fragment.
registry_user='registry-user'
registry_token='registry-token'
registry_file="${TMP_DIR}/registry.env"
write_env_file "${registry_file}" \
  "AIF_SUSE_REGISTRY_USERNAME=${registry_user}" \
  "AIF_SUSE_REGISTRY_TOKEN=${registry_token}"
registry_user_b64="$(printf '%s' "${registry_user}" | base64 | tr -d '\n')"
registry_token_b64="$(printf '%s' "${registry_token}" | base64 | tr -d '\n')"
reset_fake_kubectl "${registry_user_b64}" "${registry_token_b64}"
run_credentials --env-file "${registry_file}" >/dev/null
registry_manifest="$(<"${STATE_DIR}/applied.yaml")"
registry_calls="$(<"${STATE_DIR}/calls")"
assert_contains "${registry_manifest}" 'name: suse-registry' 'Registry Secret name'
assert_contains "${registry_manifest}" 'suseRegistry:' 'Registry Settings fragment'
assert_not_contains "${registry_manifest}" 'applicationCollection:' \
  'Registry omitted AppCo settings'
assert_not_contains "${registry_manifest}" '  nvidia:' 'Registry omitted NVIDIA settings'
assert_contains "${registry_calls}" '--field-manager=aiflab-suse-registry-credentials' \
  'Registry field manager'

nvidia_token='nvidia-api-key'
nvidia_file="${TMP_DIR}/nvidia.env"
write_env_file "${nvidia_file}" "AIF_NVIDIA_API_KEY=${nvidia_token}"
nvidia_user_b64="$(printf '%s' '$oauthtoken' | base64 | tr -d '\n')"
nvidia_token_b64="$(printf '%s' "${nvidia_token}" | base64 | tr -d '\n')"
reset_fake_kubectl "${nvidia_user_b64}" "${nvidia_token_b64}"
run_credentials --env-file "${nvidia_file}" >/dev/null
nvidia_manifest="$(<"${STATE_DIR}/applied.yaml")"
nvidia_calls="$(<"${STATE_DIR}/calls")"
assert_contains "${nvidia_manifest}" 'name: nvidia' 'NVIDIA Secret name'
assert_contains "${nvidia_manifest}" "user: ${nvidia_user_b64}" \
  'NVIDIA default username'
assert_contains "${nvidia_manifest}" '  nvidia:' 'NVIDIA Settings fragment'
assert_not_contains "${nvidia_manifest}" 'applicationCollection:' \
  'NVIDIA omitted AppCo settings'
assert_not_contains "${nvidia_manifest}" 'suseRegistry:' \
  'NVIDIA omitted Registry settings'
assert_contains "${nvidia_calls}" '--field-manager=aiflab-nvidia-credentials' \
  'NVIDIA field manager'
assert_contains "${nvidia_calls}" \
  'clusterrepo.catalog.cattle.io/nvidia -o jsonpath=' \
  'connected NVIDIA chart repository readiness'
assert_contains "${nvidia_calls}" \
  'clusterrepo.catalog.cattle.io/nvidia-blueprints -o jsonpath=' \
  'connected NVIDIA Blueprint repository readiness'
assert_not_contains "${nvidia_calls}" 'secret/ngc-helm-auth' \
  'connected NVIDIA auth mirror'

# A private NVIDIA endpoint is one authenticated repo and must not wait for the
# connected-mode Blueprint index.
reset_fake_kubectl "${nvidia_user_b64}" "${nvidia_token_b64}" 0 \
  'oci://registry.example.test/nvidia'
run_credentials --env-file "${nvidia_file}" >/dev/null
private_nvidia_calls="$(<"${STATE_DIR}/calls")"
assert_contains "${private_nvidia_calls}" 'secret/ngc-helm-auth' \
  'private NVIDIA auth mirror'
assert_contains "${private_nvidia_calls}" \
  'clusterrepo.catalog.cattle.io/nvidia -o jsonpath=' \
  'private NVIDIA repository readiness'
assert_not_contains "${private_nvidia_calls}" \
  'clusterrepo.catalog.cattle.io/nvidia-blueprints' \
  'private NVIDIA omitted public Blueprint repository'

printf 'PASS: credential env validation, secrecy, manifests, and readiness\n'

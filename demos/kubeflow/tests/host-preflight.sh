#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KUBEFLOW_DIR="$(cd -- "${TEST_DIR}/.." && pwd)"
CHECK_SCRIPT="${KUBEFLOW_DIR}/host-preflight.sh"

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

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

write_limits() {
  local root="$1"
  local instances="$2"
  local watches="$3"

  mkdir -p "${root}"
  printf '%s\n' "${instances}" >"${root}/max_user_instances"
  printf '%s\n' "${watches}" >"${root}/max_user_watches"
}

run_check() {
  AIFLAB_INOTIFY_PROC_ROOT="$1" \
    KUBEFLOW_INOTIFY_MIN_USER_INSTANCES=2280 \
    KUBEFLOW_INOTIFY_MIN_USER_WATCHES=1255360 \
    "${CHECK_SCRIPT}" "${@:2}" 2>&1
}

healthy_root="${TMP_DIR}/healthy"
write_limits "${healthy_root}" 8192 2000000
output="$(run_check "${healthy_root}")"
assert_contains "${output}" 'meet Kubeflow minimums' healthy
assert_not_contains "${output}" 'WARNING:' healthy

low_root="${TMP_DIR}/low"
write_limits "${low_root}" 128 65536
output="$(run_check "${low_root}")"
assert_contains "${output}" 'WARNING: deploy-host inotify limits are below' low
assert_contains "${output}" 'current:     max_user_instances=128, max_user_watches=65536' low
assert_contains "${output}" 'sudo sysctl --write fs.inotify.max_user_instances=2280 fs.inotify.max_user_watches=1255360' low

one_low_root="${TMP_DIR}/one-low"
write_limits "${one_low_root}" 8192 65536
output="$(run_check "${one_low_root}")"
assert_contains "${output}" 'sudo sysctl --write fs.inotify.max_user_watches=1255360' one-low
assert_not_contains "${output}" 'sudo sysctl --write fs.inotify.max_user_instances=' one-low

missing_root="${TMP_DIR}/missing"
output="$(run_check "${missing_root}")"
assert_contains "${output}" 'WARNING: unable to read the deploy host' missing
assert_contains "${output}" 'fs.inotify.max_user_instances=2280' missing

output="$(run_check "${missing_root}" --print-settings)"
assert_contains "${output}" 'Kubeflow deploy-host inotify minimums' print-settings
assert_contains "${output}" '/etc/sysctl.d/90-aiflab-kubeflow.conf' print-settings

output="$(
  AIFLAB_INOTIFY_PROC_ROOT="${missing_root}" \
    KUBEFLOW_HOST_LIMIT_CHECK=false \
    "${CHECK_SCRIPT}" 2>&1
)"
assert_contains "${output}" 'skipping deploy-host inotify check' disabled
assert_not_contains "${output}" 'WARNING:' disabled

printf 'PASS: Kubeflow deploy-host inotify preflight\n'

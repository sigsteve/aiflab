#!/usr/bin/env bash
set -euo pipefail

# Credential values must never appear in xtrace output, including when this
# script is invoked with `bash -x`.
set +x

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

AIF_NAMESPACE="${AIF_NAMESPACE:-aif-operator}"
AIF_CREDENTIALS_TIMEOUT_SECONDS="${AIF_CREDENTIALS_TIMEOUT_SECONDS:-300}"
env_file=""
validate_only=false
env_fd=""
declare -A seen=()

# Credentials come only from the inspected file. Ignore same-named ambient
# variables so an incomplete file cannot be silently completed by the shell
# environment.
unset \
  AIF_APPLICATION_COLLECTION_USERNAME \
  AIF_APPLICATION_COLLECTION_TOKEN \
  AIF_SUSE_REGISTRY_USERNAME \
  AIF_SUSE_REGISTRY_TOKEN \
  AIF_NVIDIA_API_KEY \
  AIF_NVIDIA_USERNAME

usage() {
  cat <<'EOF'
Usage: aiflab/scripts/05-configure-aif-credentials.sh --env-file FILE [--validate-only]

Configure any complete credential groups found in FILE. Values are read as
literal text; FILE is never sourced or evaluated.

Supported variables:
  AIF_APPLICATION_COLLECTION_USERNAME
  AIF_APPLICATION_COLLECTION_TOKEN
  AIF_SUSE_REGISTRY_USERNAME
  AIF_SUSE_REGISTRY_TOKEN
  AIF_NVIDIA_API_KEY
  AIF_NVIDIA_USERNAME                 Optional; defaults to $oauthtoken
EOF
}

while (($#)); do
  case "$1" in
    --env-file)
      (($# >= 2)) || die "--env-file requires a file"
      env_file="$2"
      shift 2
      ;;
    --env-file=*)
      env_file="${1#*=}"
      shift
      ;;
    --validate-only)
      validate_only=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unexpected credential option or argument: $1"
      ;;
  esac
done

[[ -n "${env_file}" ]] || die "--env-file is required"
[[ -f "${env_file}" && ! -L "${env_file}" ]] ||
  die "credential env file must be a regular, non-symlink file: ${env_file}"

need stat
file_mode="$(stat -c '%a' -- "${env_file}")"
file_uid="$(stat -c '%u' -- "${env_file}")"
expected_uid="$(id -u)"
if [[ "${expected_uid}" == "0" && -n "${SUDO_UID:-}" ]]; then
  expected_uid="${SUDO_UID}"
fi
[[ "${file_uid}" == "${expected_uid}" ]] ||
  die "credential env file must be owned by uid ${expected_uid}: ${env_file}"
[[ "${file_mode}" =~ ^[0-7]{3,4}$ ]] ||
  die "could not determine credential env file permissions: ${env_file}"
(( (8#${file_mode} & 077) == 0 )) ||
  die "credential env file must not be accessible by group or others; run: chmod 600 ${env_file}"

exec {env_fd}<"${env_file}"
line_number=0
while IFS= read -r line <&${env_fd} || [[ -n "${line}" ]]; do
  ((line_number += 1))
  line="${line%$'\r'}"
  [[ "${line}" =~ ^[[:space:]]*($|#) ]] && continue
  [[ "${line}" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] ||
    die "invalid assignment on line ${line_number} of ${env_file}; expected KEY=literal-value"

  key="${BASH_REMATCH[1]}"
  value="${BASH_REMATCH[2]}"
  case "${key}" in
    AIF_APPLICATION_COLLECTION_USERNAME|AIF_APPLICATION_COLLECTION_TOKEN|AIF_SUSE_REGISTRY_USERNAME|AIF_SUSE_REGISTRY_TOKEN|AIF_NVIDIA_API_KEY|AIF_NVIDIA_USERNAME) ;;
    *) die "unsupported variable ${key} on line ${line_number} of ${env_file}" ;;
  esac
  [[ -z "${seen[${key}]+present}" ]] ||
    die "duplicate variable ${key} on line ${line_number} of ${env_file}"
  seen["${key}"]=true
  printf -v "${key}" '%s' "${value}"
done
exec {env_fd}<&-

appco_present=false
registry_present=false
nvidia_present=false
if [[ -n "${seen[AIF_APPLICATION_COLLECTION_USERNAME]+present}" ||
      -n "${seen[AIF_APPLICATION_COLLECTION_TOKEN]+present}" ]]; then
  appco_present=true
  [[ -n "${AIF_APPLICATION_COLLECTION_USERNAME:-}" &&
     -n "${AIF_APPLICATION_COLLECTION_TOKEN:-}" ]] ||
    die "AppCo credentials require non-empty AIF_APPLICATION_COLLECTION_USERNAME and AIF_APPLICATION_COLLECTION_TOKEN"
fi
if [[ -n "${seen[AIF_SUSE_REGISTRY_USERNAME]+present}" ||
      -n "${seen[AIF_SUSE_REGISTRY_TOKEN]+present}" ]]; then
  registry_present=true
  [[ -n "${AIF_SUSE_REGISTRY_USERNAME:-}" &&
     -n "${AIF_SUSE_REGISTRY_TOKEN:-}" ]] ||
    die "SUSE Registry credentials require non-empty AIF_SUSE_REGISTRY_USERNAME and AIF_SUSE_REGISTRY_TOKEN"
fi
if [[ -n "${seen[AIF_NVIDIA_API_KEY]+present}" ||
      -n "${seen[AIF_NVIDIA_USERNAME]+present}" ]]; then
  nvidia_present=true
  [[ -n "${AIF_NVIDIA_API_KEY:-}" ]] ||
    die "NVIDIA credentials require a non-empty AIF_NVIDIA_API_KEY"
  AIF_NVIDIA_USERNAME="${AIF_NVIDIA_USERNAME:-\$oauthtoken}"
fi
[[ "${appco_present}" == "true" || "${registry_present}" == "true" ||
   "${nvidia_present}" == "true" ]] ||
  die "credential env file contains no supported credential group: ${env_file}"
[[ "${AIF_CREDENTIALS_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]] ||
  die "AIF_CREDENTIALS_TIMEOUT_SECONDS must be a positive integer"

if [[ "${validate_only}" == "true" ]]; then
  log "credential env file is valid: ${env_file}"
  exit 0
fi

need base64
need tr
need kubectl
kubectl get "crd/settings.ai-factory.suse.com" >/dev/null 2>&1 ||
  die "AI Factory is not installed; omit --skip-base or install it first"
kubectl -n "${AIF_NAMESPACE}" get \
  "settings.ai-factory.suse.com/settings" >/dev/null 2>&1 ||
  die "AI Factory Settings/settings was not found in namespace ${AIF_NAMESPACE}"

apply_credential_group() {
  local label="$1"
  local secret_name="$2"
  local settings_section="$3"
  local repo_name="$4"
  local username="$5"
  local token="$6"
  local field_manager="$7"
  local auth_secret_name="$8"
  local username_b64=""
  local token_b64=""
  local expected_auth=""
  local previous_auth=""
  local previous_force_update=""
  local auth_changed=false

  username_b64="$(printf '%s' "${username}" | base64 | tr -d '\n')"
  token_b64="$(printf '%s' "${token}" | base64 | tr -d '\n')"
  if [[ -n "${auth_secret_name}" ]]; then
    printf -v expected_auth '%s\t%s' "${username_b64}" "${token_b64}"
    previous_auth="$(read_auth_mirror cattle-system "${auth_secret_name}")"
    previous_force_update="$(kubectl get \
      "clusterrepo.catalog.cattle.io/${repo_name}" \
      -o jsonpath='{.spec.forceUpdate}' 2>/dev/null || true)"
    if [[ "${previous_auth}" != "${expected_auth}" ]]; then
      auth_changed=true
      # forceUpdate has one-second timestamp precision. Avoid a rapid rotation
      # producing the same value and looking unreconciled to this waiter.
      while [[ -n "${previous_force_update}" &&
               "$(date -u +%Y-%m-%dT%H:%M:%SZ)" == "${previous_force_update}" ]]; do
        sleep 1
      done
    fi
  fi

  log "configuring ${label} credentials"
  kubectl apply --server-side --force-conflicts \
    --field-manager="${field_manager}" -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${secret_name}
  namespace: ${AIF_NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: aiflab
type: Opaque
data:
  user: ${username_b64}
  token: ${token_b64}
---
apiVersion: ai-factory.suse.com/v1alpha1
kind: Settings
metadata:
  name: settings
  namespace: ${AIF_NAMESPACE}
spec:
  ${settings_section}:
    userSecretRef:
      name: ${secret_name}
      key: user
    tokenSecretRef:
      name: ${secret_name}
      key: token
EOF

  log "${label} Secret and Settings references were submitted"
  wait_for_settings_refs "${settings_section}" "${secret_name}"
  if [[ -n "${auth_secret_name}" ]]; then
    wait_for_auth_mirrors "${auth_secret_name}" "${username_b64}" "${token_b64}"
    if [[ "${auth_changed}" == "true" ]]; then
      wait_for_repo_force_update "${repo_name}" "${previous_force_update}"
    fi
  fi
  wait_for_clusterrepo "${repo_name}"
}

wait_for_settings_refs() {
  local section="$1"
  local secret_name="$2"
  local expected=""
  local actual=""
  local started=${SECONDS}
  local deadline=$((SECONDS + AIF_CREDENTIALS_TIMEOUT_SECONDS))
  local next_progress=$((SECONDS + 10))

  printf -v expected '%s\tuser\t%s\ttoken' "${secret_name}" "${secret_name}"
  log "waiting up to ${AIF_CREDENTIALS_TIMEOUT_SECONDS}s for Settings.${section} to reference ${AIF_NAMESPACE}/${secret_name}"

  while true; do
    actual="$(kubectl -n "${AIF_NAMESPACE}" get \
      "settings.ai-factory.suse.com/settings" \
      -o "jsonpath={.spec.${section}.userSecretRef.name}{'\\t'}{.spec.${section}.userSecretRef.key}{'\\t'}{.spec.${section}.tokenSecretRef.name}{'\\t'}{.spec.${section}.tokenSecretRef.key}" \
      --request-timeout=10s \
      2>/dev/null || true)"
    if [[ "${actual}" == "${expected}" ]]; then
      log "Settings.${section} references are ready ($((SECONDS - started))s elapsed)"
      return 0
    fi
    ((SECONDS < deadline)) ||
      die "timed out waiting for Settings.${section} credential references"
    if ((SECONDS >= next_progress)); then
      log "still waiting for Settings.${section} references ($((SECONDS - started))s/${AIF_CREDENTIALS_TIMEOUT_SECONDS}s)"
      next_progress=$((SECONDS + 10))
    fi
    sleep 2
  done
}

read_auth_mirror() {
  local namespace="$1"
  local secret_name="$2"

  kubectl -n "${namespace}" get "secret/${secret_name}" \
    -o 'jsonpath={.data.username}{"\t"}{.data.password}' \
    --request-timeout=10s \
    2>/dev/null || true
}

wait_for_auth_mirrors() {
  local secret_name="$1"
  local expected_username_b64="$2"
  local expected_token_b64="$3"
  local namespace=""
  local expected=""
  local actual=""
  local namespace_resource=""
  local started=${SECONDS}
  local deadline=$((SECONDS + AIF_CREDENTIALS_TIMEOUT_SECONDS))
  local next_progress=0

  printf -v expected '%s\t%s' \
    "${expected_username_b64}" "${expected_token_b64}"
  for namespace in cattle-system fleet-local fleet-default; do
    namespace_resource="$(kubectl get "namespace/${namespace}" \
      --ignore-not-found -o name --request-timeout=10s)" ||
      die "could not check namespace ${namespace} while waiting for credential mirrors"
    if [[ -z "${namespace_resource}" ]]; then
      log "skipping credential mirror ${namespace}/${secret_name}; namespace does not exist"
      continue
    fi
    log "waiting up to ${AIF_CREDENTIALS_TIMEOUT_SECONDS}s total for credential mirror ${namespace}/${secret_name}"
    next_progress=$((SECONDS + 10))
    while true; do
      actual="$(read_auth_mirror "${namespace}" "${secret_name}")"
      if [[ "${actual}" == "${expected}" ]]; then
        log "credential mirror ${namespace}/${secret_name} is ready ($((SECONDS - started))s elapsed)"
        break
      fi
      ((SECONDS < deadline)) ||
        die "timed out waiting for AI Factory credential mirror ${namespace}/${secret_name}"
      if ((SECONDS >= next_progress)); then
        log "still waiting for credential mirror ${namespace}/${secret_name} ($((SECONDS - started))s/${AIF_CREDENTIALS_TIMEOUT_SECONDS}s total)"
        next_progress=$((SECONDS + 10))
      fi
      sleep 2
    done
  done
}

wait_for_repo_force_update() {
  local repo_name="$1"
  local previous_force_update="$2"
  local current_force_update=""
  local started=${SECONDS}
  local deadline=$((SECONDS + AIF_CREDENTIALS_TIMEOUT_SECONDS))
  local next_progress=$((SECONDS + 10))

  log "waiting up to ${AIF_CREDENTIALS_TIMEOUT_SECONDS}s for ClusterRepo ${repo_name} credential refresh"

  while true; do
    current_force_update="$(kubectl get \
      "clusterrepo.catalog.cattle.io/${repo_name}" \
      -o jsonpath='{.spec.forceUpdate}' --request-timeout=10s \
      2>/dev/null || true)"
    if [[ -n "${current_force_update}" &&
          "${current_force_update}" != "${previous_force_update}" ]]; then
      log "ClusterRepo ${repo_name} credential refresh was requested ($((SECONDS - started))s elapsed)"
      return 0
    fi
    ((SECONDS < deadline)) ||
      die "timed out waiting for AI Factory ClusterRepo ${repo_name} credential refresh"
    if ((SECONDS >= next_progress)); then
      log "still waiting for ClusterRepo ${repo_name} credential refresh ($((SECONDS - started))s/${AIF_CREDENTIALS_TIMEOUT_SECONDS}s)"
      next_progress=$((SECONDS + 10))
    fi
    sleep 2
  done
}

wait_for_clusterrepo() {
  local repo_name="$1"
  local deadline=$((SECONDS + AIF_CREDENTIALS_TIMEOUT_SECONDS))
  local state=""
  local generation=""
  local observed_generation=""
  local downloaded=""
  local oci_downloaded=""
  local follower_downloaded=""
  local ready_condition=""
  local started=${SECONDS}
  local next_progress=$((SECONDS + 10))

  log "waiting up to ${AIF_CREDENTIALS_TIMEOUT_SECONDS}s for ClusterRepo ${repo_name} to download its index"
  while true; do
    state="$(kubectl get "clusterrepo.catalog.cattle.io/${repo_name}" \
      -o 'jsonpath={.metadata.generation}{"|"}{.status.observedGeneration}{"|"}{.status.conditions[?(@.type=="Downloaded")].status}{"|"}{.status.conditions[?(@.type=="OCIDownloaded")].status}{"|"}{.status.conditions[?(@.type=="FollowerDownloaded")].status}' \
      --request-timeout=10s \
      2>/dev/null || true)"
    IFS='|' read -r generation observed_generation downloaded \
      oci_downloaded follower_downloaded <<<"${state}"
    ready_condition=""
    if [[ "${downloaded}" == "True" ]]; then
      ready_condition="Downloaded"
    elif [[ "${oci_downloaded}" == "True" ]]; then
      ready_condition="OCIDownloaded"
    fi
    if [[ -n "${generation}" && "${observed_generation}" == "${generation}" &&
          -n "${ready_condition}" ]]; then
      break
    fi
    if ((SECONDS >= deadline)); then
      kubectl get "clusterrepo.catalog.cattle.io/${repo_name}" \
        -o jsonpath='{range .status.conditions[*]}{.type}{"="}{.status}{" reason="}{.reason}{" message="}{.message}{"\n"}{end}' >&2 || true
      die "AI Factory ClusterRepo ${repo_name} did not become ready"
    fi
    if ((SECONDS >= next_progress)); then
      log "still waiting for ClusterRepo ${repo_name} ($((SECONDS - started))s/${AIF_CREDENTIALS_TIMEOUT_SECONDS}s; generation=${generation:-unknown}, observed=${observed_generation:-unknown}, Downloaded=${downloaded:-unset}, OCIDownloaded=${oci_downloaded:-unset}, FollowerDownloaded=${follower_downloaded:-unset})"
      next_progress=$((SECONDS + 10))
    fi
    sleep 2
  done
  log "${repo_name} chart repository is ready ($((SECONDS - started))s elapsed; ${ready_condition}=True, generation=${generation})"
}

if [[ "${appco_present}" == "true" ]]; then
  apply_credential_group \
    "Application Collection" appco applicationCollection application-collection \
    "${AIF_APPLICATION_COLLECTION_USERNAME}" \
    "${AIF_APPLICATION_COLLECTION_TOKEN}" \
    aiflab-appco-credentials application-collection-auth
fi
if [[ "${registry_present}" == "true" ]]; then
  apply_credential_group \
    "SUSE Registry" suse-registry suseRegistry suse-ai-registry \
    "${AIF_SUSE_REGISTRY_USERNAME}" \
    "${AIF_SUSE_REGISTRY_TOKEN}" \
    aiflab-suse-registry-credentials suse-ai-registry-auth
fi
if [[ "${nvidia_present}" == "true" ]]; then
  nvidia_endpoint="$(kubectl -n "${AIF_NAMESPACE}" get \
    "settings.ai-factory.suse.com/settings" \
    -o jsonpath='{.spec.registryEndpoints.nvidia}' 2>/dev/null || true)"
  if [[ -n "${nvidia_endpoint}" ]]; then
    # A private NVIDIA endpoint is a single authenticated repository.
    apply_credential_group \
      "NVIDIA" nvidia nvidia nvidia \
      "${AIF_NVIDIA_USERNAME}" \
      "${AIF_NVIDIA_API_KEY}" \
      aiflab-nvidia-credentials ngc-helm-auth
  else
    # The connected NVIDIA chart and Blueprint indexes are public. Credentials
    # still enable NVIDIA image access, but the operator keeps both repos
    # anonymous to avoid NGC entitlement failures.
    apply_credential_group \
      "NVIDIA" nvidia nvidia nvidia \
      "${AIF_NVIDIA_USERNAME}" \
      "${AIF_NVIDIA_API_KEY}" \
      aiflab-nvidia-credentials ""
    wait_for_clusterrepo nvidia-blueprints
  fi
fi

log "AI Factory credential settings are ready"

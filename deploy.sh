#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STEPS_DIR="${SCRIPT_DIR}/scripts"
DEMO_STORAGE_SOURCE="${SCRIPT_DIR}/platform/local-storage"
AIF_NAMESPACE="${AIF_NAMESPACE:-aif-operator}"
# shellcheck source=scripts/common.sh
. "${STEPS_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage: ./aiflab/deploy.sh [OPTIONS]

Install the local AI Factory lab stack and optionally deploy one Blueprint
manifest or structured deployment bundle with aifctl. A bare install never
creates credentials. Platform credentials are configured explicitly with
--env-file, reused by later Blueprints, and not owned by those Blueprints.

Before deploying a Blueprint, the wrapper reuses the cluster's single default
StorageClass. If none exists, it installs AIFLab's demo-only Local Path
Provisioner through its platform Blueprint. Application Collection credentials
must already be configured when that fallback is needed.

Options:
  --skip-base          Do not install the runtime, Rancher, or AI Factory
  --env-file FILE      Configure or rotate persistent AI Factory platform
                       credentials from FILE
  --from FILE|DIR      Deploy a multi-document YAML file or structured bundle
  --timeout DURATION   Deployment wait timeout passed to aifctl (default: 30m)
  --domain DOMAIN      Override the discovered <node-ip>.sslip.io base domain
  -h, --help           Show this help

Examples:
  # Base only; no credentials or Blueprint:
  ./aiflab/deploy.sh
  # Configure platform credentials without deploying a Blueprint:
  ./aiflab/deploy.sh --skip-base \
    --env-file ~/.config/aiflab/credentials.env
  # Configure credentials and deploy Kubeflow in one command:
  ./aiflab/deploy.sh --skip-base \
    --env-file ~/.config/aiflab/credentials.env \
    --from aiflab/demos/kubeflow --timeout 45m
  # Reuse credentials already configured in AI Factory Settings:
  ./aiflab/deploy.sh --skip-base \
    --from aiflab/demos/kubeflow --timeout 45m

Set AIFCTL_BIN to use a specific aifctl binary. Otherwise the script uses one
from PATH, aiflab/aifctl/bin/aifctl, or builds the AIFLab client from this
checkout when Go and make are available.
EOF
}

skip_base=false
env_file=""
deployment_source=""
deployment_timeout="30m"
deployment_domain=""

while (($#)); do
  case "$1" in
    --skip-base)
      skip_base=true
      shift
      ;;
    --env-file)
      (($# >= 2)) || die "--env-file requires a file"
      env_file="$2"
      shift 2
      ;;
    --env-file=*)
      env_file="${1#*=}"
      [[ -n "${env_file}" ]] || die "--env-file requires a file"
      shift
      ;;
    --from)
      (($# >= 2)) || die "--from requires a file or directory"
      deployment_source="$2"
      shift 2
      ;;
    --from=*)
      deployment_source="${1#*=}"
      [[ -n "${deployment_source}" ]] || die "--from requires a file or directory"
      shift
      ;;
    --timeout)
      (($# >= 2)) || die "--timeout requires a duration"
      deployment_timeout="$2"
      shift 2
      ;;
    --timeout=*)
      deployment_timeout="${1#*=}"
      [[ -n "${deployment_timeout}" ]] || die "--timeout requires a duration"
      shift
      ;;
    --domain)
      (($# >= 2)) || die "--domain requires a value"
      deployment_domain="$2"
      shift 2
      ;;
    --domain=*)
      deployment_domain="${1#*=}"
      [[ -n "${deployment_domain}" ]] || die "--domain requires a value"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown option: $1"
      ;;
  esac
done

resolve_aifctl() {
  local candidate="${AIFCTL_BIN:-}"

  if [[ -n "${candidate}" ]]; then
    [[ -x "${candidate}" ]] || die "AIFCTL_BIN is not executable: ${candidate}"
    printf '%s\n' "${candidate}"
    return
  fi

  if command -v aifctl >/dev/null 2>&1; then
    command -v aifctl
    return
  fi

  candidate="${SCRIPT_DIR}/aifctl/bin/aifctl"
  if [[ -x "${candidate}" ]]; then
    printf '%s\n' "${candidate}"
    return
  fi

  if command -v go >/dev/null 2>&1 && command -v make >/dev/null 2>&1; then
    log "building aifctl from this checkout" >&2
    make -C "${SCRIPT_DIR}/aifctl" build >&2
    [[ -x "${candidate}" ]] || die "aifctl build completed without creating ${candidate}"
    printf '%s\n' "${candidate}"
    return
  fi

  die "aifctl is required for Blueprint deployment; install it, set AIFCTL_BIN, or run 'make -C aiflab/aifctl build'"
}

default_storage_classes() {
  kubectl get storageclass -o go-template='{{range .items}}{{if or (eq (index .metadata.annotations "storageclass.kubernetes.io/is-default-class") "true") (eq (index .metadata.annotations "storageclass.beta.kubernetes.io/is-default-class") "true")}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}'
}

ensure_demo_storage() {
  local class=""
  local output=""
  local -a defaults=()

  output="$(default_storage_classes)" ||
    die "could not inspect default StorageClasses"
  while IFS= read -r class; do
    [[ -n "${class}" ]] && defaults+=("${class}")
  done <<<"${output}"

  if ((${#defaults[@]} == 1)); then
    log "using existing default StorageClass ${defaults[0]}"
    return
  fi
  if ((${#defaults[@]} > 1)); then
    die "multiple default StorageClasses found (${defaults[*]}); select exactly one before deploying a demo"
  fi

  log "no default StorageClass found; installing AIFLab demo local storage"
  "${aifctl_bin}" blueprint deploy \
    --from "${DEMO_STORAGE_SOURCE}" --timeout "${deployment_timeout}"

  defaults=()
  output="$(default_storage_classes)" ||
    die "could not verify the default StorageClass after deployment"
  while IFS= read -r class; do
    [[ -n "${class}" ]] && defaults+=("${class}")
  done <<<"${output}"
  ((${#defaults[@]} == 1)) ||
    die "demo storage deployment did not leave exactly one default StorageClass"
  log "default StorageClass ${defaults[0]} is ready"
}

credential_group_status() {
  local label="$1"
  local settings_section="$2"
  local repo_name="$3"
  local refs=""
  local user_secret=""
  local user_key=""
  local token_secret=""
  local token_key=""
  local repo_state=""
  local generation=""
  local observed_generation=""
  local downloaded=""
  local oci_downloaded=""

  refs="$(kubectl -n "${AIF_NAMESPACE}" get \
    settings.ai-factory.suse.com/settings \
    -o "jsonpath={.spec.${settings_section}.userSecretRef.name}{'|'}{.spec.${settings_section}.userSecretRef.key}{'|'}{.spec.${settings_section}.tokenSecretRef.name}{'|'}{.spec.${settings_section}.tokenSecretRef.key}" \
    --request-timeout=10s 2>/dev/null)" ||
    die "could not inspect AI Factory ${label} credential status"

  IFS='|' read -r user_secret user_key token_secret token_key <<<"${refs}"
  if [[ -z "${user_secret}${user_key}${token_secret}${token_key}" ]]; then
    log "credential status - ${label}: not configured"
    return
  fi
  if [[ -z "${user_secret}" || -z "${user_key}" ||
        -z "${token_secret}" || -z "${token_key}" ]]; then
    log "credential status - ${label}: incomplete Settings references; repository not ready"
    return
  fi

  repo_state="$(kubectl get \
    "clusterrepo.catalog.cattle.io/${repo_name}" \
    -o 'jsonpath={.metadata.generation}{"|"}{.status.observedGeneration}{"|"}{.status.conditions[?(@.type=="Downloaded")].status}{"|"}{.status.conditions[?(@.type=="OCIDownloaded")].status}' \
    --request-timeout=10s 2>/dev/null || true)"
  IFS='|' read -r generation observed_generation downloaded \
    oci_downloaded <<<"${repo_state}"
  if [[ -n "${generation}" && "${observed_generation}" == "${generation}" &&
        ( "${downloaded}" == "True" || "${oci_downloaded}" == "True" ) ]]; then
    log "credential status - ${label}: configured; repository ready"
    return
  fi
  log "credential status - ${label}: configured in Settings; repository not ready"
}

show_platform_credential_status() {
  log "AI Factory platform credential status (values are never displayed)"
  credential_group_status \
    "Application Collection" applicationCollection application-collection
  credential_group_status \
    "SUSE Registry" suseRegistry suse-ai-registry
  credential_group_status \
    "NVIDIA" nvidia nvidia
}

if [[ -n "${env_file}" ]]; then
  "${STEPS_DIR}/05-configure-aif-credentials.sh" \
    --env-file "${env_file}" --validate-only
fi

steps=(
  "00-install-runtime-deps.sh"
  "01-install-runtime.sh"
  "02-install-rancher-deps.sh"
  "03-install-rancher.sh"
  "04-install-aif-operator.sh"
)

if [[ "${skip_base}" != "true" ]]; then
  for step in "${steps[@]}"; do
    log "running scripts/${step}"
    "${STEPS_DIR}/${step}" || {
      status=$?
      die "scripts/${step} failed (exit ${status})"
    }
  done
fi

if [[ -n "${env_file}" ]]; then
  log "configuring AI Factory credentials"
  "${STEPS_DIR}/05-configure-aif-credentials.sh" --env-file "${env_file}" || {
    status=$?
    die "AI Factory credential configuration failed (exit ${status})"
  }
  log "platform credentials are shared by future Blueprints and are not deleted with a Blueprint"
elif [[ -n "${deployment_source}" ]]; then
  log "no --env-file supplied; using the current AI Factory Settings credential state without creating credentials"
  log "required external chart repositories will be verified before any package resources are applied"
else
  log "no --env-file supplied; this run did not create or change AI Factory credentials"
  show_platform_credential_status
  log "a bare installation is valid, but authenticated Blueprints require platform credentials before deployment"
  log "configure them once with: ./aiflab/deploy.sh --skip-base --env-file ~/.config/aiflab/credentials.env"
  log "credentials are reused by future Blueprints and are not deleted with a Blueprint"
fi

if [[ -n "${deployment_source}" ]]; then
  # Resolve or build the client only after the base dependency step has had a
  # chance to install the AIFLab build toolchain on a clean host.
  aifctl_bin="$(resolve_aifctl)"
  "${aifctl_bin}" blueprint deploy --from "${DEMO_STORAGE_SOURCE}" --dry-run >/dev/null
  validation_args=(
    blueprint deploy
    --from "${deployment_source}"
    --dry-run
  )
  if [[ -n "${deployment_domain}" ]]; then
    validation_args+=(--domain "${deployment_domain}")
  fi
  "${aifctl_bin}" "${validation_args[@]}" >/dev/null

  deployment_args=(
    blueprint deploy
    --from "${deployment_source}"
    --timeout "${deployment_timeout}"
  )
  if [[ -n "${deployment_domain}" ]]; then
    deployment_args+=(--domain "${deployment_domain}")
  fi
  ensure_demo_storage
  log "deploying Blueprint source ${deployment_source}"
  "${aifctl_bin}" "${deployment_args[@]}"
fi

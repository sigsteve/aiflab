#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

K3S_SELINUX_RPM_URL="${K3S_SELINUX_RPM_URL:-https://rpm.rancher.io/k3s/stable/common/microos/noarch/k3s-selinux-1.6-1.sle.noarch.rpm}"
K3S_SELINUX_RPM_PATH="${K3S_SELINUX_RPM_PATH:-${SCRIPT_DIR}/$(basename "${K3S_SELINUX_RPM_URL}")}"

check_tls() {
  local domain="$1"

  if ! command -v curl >/dev/null 2>&1; then
    return
  fi

  local curl_output=""
  if curl_output="$(curl -sSI --connect-timeout 10 --max-time 20 "https://${domain}/" 2>&1 >/dev/null)"; then
    return
  fi

  log "warning: could not verify the TLS certificate for ${domain}"
  log "warning: DNS may be resolving ${domain} through an internal search domain such as ${domain}.<domain>"
  log "warning: ask a maintainer for help before continuing"
  if [[ -n "${curl_output}" ]]; then
    log "warning: curl output: ${curl_output//$'\n'/ }"
  fi
}

TLS_CHECK_DOMAINS=(
  ghcr.io
)

for domain in "${TLS_CHECK_DOMAINS[@]}"; do
  check_tls "${domain}"
done

validate_helm_version() {
  local minimum="${AIFLAB_MIN_HELM_MAJOR:-}" version=""

  [[ -n "${minimum}" ]] || return 0
  version="$(helm version --short)"
  [[ "${version}" =~ ^v?([0-9]+)\. ]] || die "could not parse Helm version: ${version}"
  ((BASH_REMATCH[1] >= minimum)) ||
    die "Helm ${minimum} or newer is required for this deployment; found ${version}"
}

install_helm() {
  if command -v helm >/dev/null 2>&1; then
    validate_helm_version
    log "helm is already installed"
    return
  fi

  log "installing demo dependency: helm"
  sudo zypper --non-interactive install -y helm
  validate_helm_version
}

go_version_supported() {
  local version="$1"

  [[ "${version}" =~ go([0-9]+)\.([0-9]+)(\.|[[:space:]]) ]] || return 1
  ((BASH_REMATCH[1] > 1 ||
    (BASH_REMATCH[1] == 1 && BASH_REMATCH[2] >= 25)))
}

install_aifctl_build_deps() {
  local version=""

  version="$(go version 2>/dev/null || true)"
  if command -v make >/dev/null 2>&1 && go_version_supported "${version}"; then
    log "AIFLab aifctl build dependencies are already installed"
    return
  fi

  log "installing AIFLab client build dependencies: Go and make"
  sudo zypper --non-interactive install -y go make
  need go
  need make
  version="$(go version 2>/dev/null || true)"
  go_version_supported "${version}" ||
    die "Go 1.25 or newer is required to build AIFLab aifctl; found ${version:-not found}"
}

os_id=""
os_like=""
os_pretty="unknown OS"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  os_id="${ID:-}"
  os_like="${ID_LIKE:-}"
  os_pretty="${PRETTY_NAME:-${ID:-unknown OS}}"
fi

case " ${os_id} ${os_like} " in
  *opensuse*|*sles*|*suse*) ;;
  *)
    log "no known ${INSTALL_RUNTIME} dependency step for ${os_pretty}; skipping"
    log "warning: ${INSTALL_RUNTIME} install may still need OS-specific dependencies"
    exit 0
    ;;
esac

need sudo
need zypper

install_helm
install_aifctl_build_deps

if [[ "${INSTALL_RUNTIME}" == "rke2" ]]; then
  log "installing SUSE RKE2 dependency: apparmor-parser"
  sudo zypper --non-interactive install -y apparmor-parser
  exit 0
fi

need curl
need rpm

log "installing SUSE k3s dependency: container-selinux"
sudo zypper --non-interactive install -y container-selinux

if rpm -q k3s-selinux >/dev/null 2>&1; then
  log "k3s-selinux is already installed"
  exit 0
fi

log "downloading k3s-selinux policy RPM"
curl -fL -o "${K3S_SELINUX_RPM_PATH}" "${K3S_SELINUX_RPM_URL}"

log "installing k3s-selinux policy RPM"
sudo rpm -ivh "${K3S_SELINUX_RPM_PATH}"

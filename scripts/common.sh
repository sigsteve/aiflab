# Common installer environment. Source this from bash scripts or an interactive shell.

export PATH="${PATH}:/usr/local/sbin:/usr/local/bin"

log() { printf '>>> %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

INSTALL_RUNTIME="${INSTALL_RUNTIME:-rke2}"
case "${INSTALL_RUNTIME}" in
  rke2|k3s) ;;
  *) die "unsupported INSTALL_RUNTIME=${INSTALL_RUNTIME}; expected rke2 or k3s" ;;
esac

K3S_BIN="${K3S_BIN:-}"
K3S_YAML_PATH="${K3S_YAML_PATH:-/etc/rancher/k3s/k3s.yaml}"
RKE2_KUBECTL_BIN="${RKE2_KUBECTL_BIN:-/var/lib/rancher/rke2/bin/kubectl}"
RKE2_YAML_PATH="${RKE2_YAML_PATH:-/etc/rancher/rke2/rke2.yaml}"
SYSTEM_KUBECTL_BIN="${SYSTEM_KUBECTL_BIN:-$(type -P kubectl || true)}"

default_user_home() {
  if [[ "$(id -u)" -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    local sudo_home=""
    sudo_home="$(getent passwd "${SUDO_USER}" 2>/dev/null | cut -d: -f6 || true)"
    if [[ -n "${sudo_home}" ]]; then
      printf '%s\n' "${sudo_home}"
      return
    fi
  fi

  printf '%s\n' "${HOME:-/root}"
}

default_kubeconfig_owner_uid() {
  if [[ "$(id -u)" -eq 0 && -n "${SUDO_UID:-}" ]]; then
    printf '%s\n' "${SUDO_UID}"
    return
  fi

  id -u
}

default_kubeconfig_owner_gid() {
  if [[ "$(id -u)" -eq 0 && -n "${SUDO_GID:-}" ]]; then
    printf '%s\n' "${SUDO_GID}"
    return
  fi

  id -g
}

if [[ "${INSTALL_RUNTIME}" == "rke2" ]]; then
  RUNTIME_KUBECONFIG="${RUNTIME_KUBECONFIG:-${RKE2_YAML_PATH}}"
else
  RUNTIME_KUBECONFIG="${RUNTIME_KUBECONFIG:-${K3S_YAML_PATH}}"
fi

KUBECONFIG_PATH="${KUBECONFIG_PATH:-$(default_user_home)/.kube/config}"
KUBECONFIG_OWNER_UID="${KUBECONFIG_OWNER_UID:-$(default_kubeconfig_owner_uid)}"
KUBECONFIG_OWNER_GID="${KUBECONFIG_OWNER_GID:-$(default_kubeconfig_owner_gid)}"
export KUBECONFIG="${KUBECONFIG_PATH}"

find_k3s() {
  if [[ -n "${K3S_BIN}" ]]; then
    [[ -x "${K3S_BIN}" ]] || die "K3S_BIN=${K3S_BIN} is not executable"
    printf '%s\n' "${K3S_BIN}"
    return
  fi

  if command -v k3s >/dev/null 2>&1; then
    command -v k3s
    return
  fi

  if [[ -x /usr/local/bin/k3s ]]; then
    printf '%s\n' /usr/local/bin/k3s
    return
  fi

  return 1
}

unalias kubectl 2>/dev/null || true
kubectl() {
  if [[ "${INSTALL_RUNTIME}" == "rke2" ]]; then
    if [[ -x "${RKE2_KUBECTL_BIN}" ]]; then
      "${RKE2_KUBECTL_BIN}" "$@"
      return
    fi
    if [[ -n "${SYSTEM_KUBECTL_BIN}" && -x "${SYSTEM_KUBECTL_BIN}" ]]; then
      "${SYSTEM_KUBECTL_BIN}" "$@"
      return
    fi
    die "missing kubectl; run aiflab/scripts/01-install-runtime.sh first or set SYSTEM_KUBECTL_BIN=/path/to/kubectl"
  fi

  local k3s_bin=""
  k3s_bin="$(find_k3s || true)"
  [[ -n "${k3s_bin}" ]] || die "missing k3s; run aiflab/scripts/01-install-runtime.sh first or set K3S_BIN=/path/to/k3s"
  "${k3s_bin}" kubectl "$@"
}

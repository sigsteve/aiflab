#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/common.sh
. "${SCRIPT_DIR}/../../scripts/common.sh"

MIN_USER_INSTANCES="${KUBEFLOW_INOTIFY_MIN_USER_INSTANCES:-2280}"
MIN_USER_WATCHES="${KUBEFLOW_INOTIFY_MIN_USER_WATCHES:-1255360}"
PROC_ROOT="${AIFLAB_INOTIFY_PROC_ROOT:-/proc/sys/fs/inotify}"
HOST_LIMIT_CHECK="${KUBEFLOW_HOST_LIMIT_CHECK:-true}"
print_settings=false

usage() {
  cat <<'EOF'
Usage: aiflab/demos/kubeflow/host-preflight.sh [--print-settings]

Check the deploy host's inotify limits against Kubeflow's published minimums.
This is advisory: low or unreadable values produce a warning but do not fail a
deployment or modify the host.

Options:
  --print-settings  Print the recommended settings and copyable commands
  -h, --help        Show this help

This script inspects only the machine on which it runs. If Kubernetes nodes are
remote, run the check on every node that can host Kubeflow workloads.
EOF
}

while (($#)); do
  case "$1" in
    --print-settings)
      print_settings=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unexpected host-limit option or argument: $1"
      ;;
  esac
done

[[ "${MIN_USER_INSTANCES}" =~ ^[1-9][0-9]*$ ]] ||
  die "KUBEFLOW_INOTIFY_MIN_USER_INSTANCES must be a positive integer"
[[ "${MIN_USER_WATCHES}" =~ ^[1-9][0-9]*$ ]] ||
  die "KUBEFLOW_INOTIFY_MIN_USER_WATCHES must be a positive integer"
case "${HOST_LIMIT_CHECK}" in
  true|false) ;;
  *) die "KUBEFLOW_HOST_LIMIT_CHECK must be true or false" ;;
esac

print_all_settings() {
  cat <<EOF
Kubeflow deploy-host inotify minimums:
  fs.inotify.max_user_instances=${MIN_USER_INSTANCES}
  fs.inotify.max_user_watches=${MIN_USER_WATCHES}

Apply until the next reboot:
  sudo sysctl --write fs.inotify.max_user_instances=${MIN_USER_INSTANCES} fs.inotify.max_user_watches=${MIN_USER_WATCHES}

To persist on Ubuntu, put these lines in
/etc/sysctl.d/90-aiflab-kubeflow.conf, then run sudo sysctl --system:
  fs.inotify.max_user_instances = ${MIN_USER_INSTANCES}
  fs.inotify.max_user_watches = ${MIN_USER_WATCHES}
EOF
}

if [[ "${print_settings}" == "true" ]]; then
  print_all_settings
  exit 0
fi

if [[ "${HOST_LIMIT_CHECK}" == "false" ]]; then
  log "skipping deploy-host inotify check (KUBEFLOW_HOST_LIMIT_CHECK=false)"
  exit 0
fi

read_limit() {
  local name="$1"
  local path="${PROC_ROOT}/${name}"
  local value=""

  [[ -r "${path}" ]] || return 1
  IFS= read -r value <"${path}" || return 1
  [[ "${value}" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "${value}"
}

current_instances="$(read_limit max_user_instances || true)"
current_watches="$(read_limit max_user_watches || true)"

if [[ -z "${current_instances}" || -z "${current_watches}" ]]; then
  cat >&2 <<EOF
WARNING: unable to read the deploy host's inotify limits from ${PROC_ROOT}.
This warning does not describe remote Kubernetes nodes. Run this check on every
node that can host Kubeflow workloads. Recommended settings follow.
EOF
  print_all_settings >&2
  exit 0
fi

low_instances=false
low_watches=false
((current_instances >= MIN_USER_INSTANCES)) || low_instances=true
((current_watches >= MIN_USER_WATCHES)) || low_watches=true

if [[ "${low_instances}" == "false" && "${low_watches}" == "false" ]]; then
  log "deploy-host inotify limits meet Kubeflow minimums (max_user_instances=${current_instances}, max_user_watches=${current_watches})"
  exit 0
fi

fix_args=()
persist_lines=()
if [[ "${low_instances}" == "true" ]]; then
  fix_args+=("fs.inotify.max_user_instances=${MIN_USER_INSTANCES}")
  persist_lines+=("fs.inotify.max_user_instances = ${MIN_USER_INSTANCES}")
fi
if [[ "${low_watches}" == "true" ]]; then
  fix_args+=("fs.inotify.max_user_watches=${MIN_USER_WATCHES}")
  persist_lines+=("fs.inotify.max_user_watches = ${MIN_USER_WATCHES}")
fi

cat >&2 <<EOF
WARNING: deploy-host inotify limits are below Kubeflow's published minimums.
  current:     max_user_instances=${current_instances}, max_user_watches=${current_watches}
  recommended: max_user_instances>=${MIN_USER_INSTANCES}, max_user_watches>=${MIN_USER_WATCHES}

Low inotify limits can make controllers fail with fsnotify errors such as
"too many open files". This is a warning only; no host setting was changed.
This check sees only the deploy host, not remote Kubernetes nodes.

Copy/paste to raise only the low value(s) until the next reboot:
EOF
printf '  sudo sysctl --write' >&2
printf ' %s' "${fix_args[@]}" >&2
printf '\n\n' >&2
printf '%s\n' \
  'To persist on Ubuntu, add the following to' \
  '/etc/sysctl.d/90-aiflab-kubeflow.conf and run sudo sysctl --system:' >&2
printf '  %s\n' "${persist_lines[@]}" >&2

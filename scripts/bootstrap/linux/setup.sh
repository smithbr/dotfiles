#!/usr/bin/env bash

set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
BOOTSTRAP_DIR="${BASEDIR}/scripts/bootstrap/linux"
source "${BASEDIR}/scripts/common.sh"

log_info "Starting Linux bootstrap"

if ! command -v apt-get >/dev/null 2>&1; then
    log_warn "apt-get not found; skipping Linux package bootstrap"
    exit 0
fi

# Only run apt update/upgrade/install if any base package is missing
apt_needs_install=0
while IFS= read -r pkg || [[ -n "${pkg}" ]]; do
    [[ -z "${pkg}" ]] && continue
    [[ "${pkg}" == \#* ]] && continue
    if ! dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null | grep -q "install ok installed"; then
        apt_needs_install=1
        break
    fi
done < "${BOOTSTRAP_DIR}/apt-packages.txt"

if [[ "${apt_needs_install}" -eq 1 ]]; then
    log_info "Updating apt package index"
    sudo_cmd apt-get update

    log_info "Installing base Linux packages"
    sudo_cmd apt-get install -y $(grep -v '^\s*#' "${BOOTSTRAP_DIR}/apt-packages.txt" | grep -v '^\s*$' | tr '\n' ' ')
else
    log_info "Base Linux packages already installed"
fi

chmod +x "${BOOTSTRAP_DIR}/docker.sh"
"${BOOTSTRAP_DIR}/docker.sh"

chmod +x "${BOOTSTRAP_DIR}/tailscale.sh"
"${BOOTSTRAP_DIR}/tailscale.sh"

chmod +x "${BOOTSTRAP_DIR}/opencode.sh"
"${BOOTSTRAP_DIR}/opencode.sh"

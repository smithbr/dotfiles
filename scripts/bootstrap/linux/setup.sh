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

log_info "Updating apt package index and packages"
sudo_cmd apt-get update

log_info "Upgrading installed apt packages"
sudo_cmd apt-get -y upgrade

log_info "Installing base Linux packages"
sudo_cmd apt-get install -y $(grep -v '^\s*#' "${BOOTSTRAP_DIR}/apt-packages.txt" | grep -v '^\s*$' | tr '\n' ' ')

chmod +x "${BOOTSTRAP_DIR}/docker.sh"
"${BOOTSTRAP_DIR}/docker.sh"

chmod +x "${BOOTSTRAP_DIR}/tailscale.sh"
"${BOOTSTRAP_DIR}/tailscale.sh"

chmod +x "${BOOTSTRAP_DIR}/opencode.sh"
"${BOOTSTRAP_DIR}/opencode.sh"

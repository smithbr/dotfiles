#!/usr/bin/env bash

set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${BASEDIR}/scripts/common.sh"

log_info "Starting Linux bootstrap"

if ! command -v apt-get >/dev/null 2>&1; then
    log_warn "apt-get not found; skipping Linux package bootstrap"
    exit 0
fi

log_info "Updating apt package index"
sudo_cmd apt-get update

log_info "Upgrading installed apt packages"
sudo_cmd apt-get -y upgrade

log_info "Installing base Linux packages"
sudo_cmd apt-get install -y curl build-essential fonts-powerline zsh

#!/usr/bin/env bash

set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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
sudo_cmd apt-get install -y build-essential curl zsh tcpdump dnsutils net-tools

# --- Docker Engine (https://docs.docker.com/engine/install/debian/) ---
if command -v docker >/dev/null 2>&1; then
    log_info "Docker already installed, skipping"
else
    log_info "Removing old Docker packages (if any)"
    # shellcheck disable=SC2046
    sudo_cmd apt-get remove -y $(dpkg --get-selections \
        docker.io docker-compose docker-doc podman-docker containerd runc 2>/dev/null \
        | cut -f1) 2>/dev/null || true

    log_info "Setting up Docker apt repository"
    sudo_cmd apt-get install -y ca-certificates curl
    sudo_cmd install -m 0755 -d /etc/apt/keyrings
    sudo_cmd curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    sudo_cmd chmod a+r /etc/apt/keyrings/docker.asc

    # shellcheck disable=SC1091
    sudo_cmd tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    sudo_cmd apt-get update

    log_info "Installing Docker Engine"
    sudo_cmd apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    log_info "Adding current user to docker group"
    sudo_cmd usermod -aG docker "${USER}"

    log_info "Docker installed. Log out and back in for group changes to take effect."
fi

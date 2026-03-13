#!/usr/bin/env bash
# Tailscale installation via official installer.
# https://tailscale.com/download/linux

set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${BASEDIR}/scripts/common.sh"

if command -v tailscale >/dev/null 2>&1; then
    log_info "Tailscale already installed, skipping"
    exit 0
fi

log_info "Installing Tailscale"
curl -fsSL https://tailscale.com/install.sh | sh

log_info "Tailscale installed. Run 'sudo tailscale up' to connect."

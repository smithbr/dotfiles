#!/usr/bin/env bash
# Tailscale installation via official installer, an optional install.
# https://tailscale.com/download/linux
# detect: tool_installed tailscale

set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${BASEDIR}/scripts/common.sh"

if tool_installed tailscale; then
    log_info "Tailscale already installed, skipping"
    exit 0
fi

log_info "Installing Tailscale"
curl -fsSL https://tailscale.com/install.sh | sh

log_info "Tailscale installed. Run 'sudo tailscale up' to connect."

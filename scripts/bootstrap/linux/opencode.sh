#!/usr/bin/env bash
# OpenCode CLI installation.
# https://opencode.ai

set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${BASEDIR}/scripts/common.sh"

if command -v opencode >/dev/null 2>&1; then
    log_info "OpenCode already installed, skipping"
    exit 0
fi

spin "Installing OpenCode..." bash -c "$(curl -fsSL https://opencode.ai/install)"

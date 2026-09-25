#!/usr/bin/env bash
# Claude Code native installation. Preferred over the Homebrew cask because the
# native build updates itself in the background; the cask only moves on
# `brew upgrade`.
# https://code.claude.com/docs/en/setup

set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${BASEDIR}/scripts/common.sh"

if [[ -x "${HOME}/.local/bin/claude" ]]; then
    log_info "Claude Code already installed, skipping"
else
    spin "Installing Claude Code..." bash -c 'set -o pipefail; curl -fsSL https://claude.ai/install.sh | bash'
fi

if command -v brew >/dev/null 2>&1 \
    && { brew list --cask claude-code@latest || brew list --cask claude-code; } &>/dev/null; then
    log_warn "Homebrew's Claude Code cask is still installed and may shadow the native build; remove it with: brew uninstall --cask claude-code@latest"
fi

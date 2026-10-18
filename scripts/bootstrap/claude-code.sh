#!/usr/bin/env bash
# Claude Code native installation, an optional install on both OSes; the
# native build updates itself, the Homebrew cask only on `brew upgrade`.
# https://code.claude.com/docs/en/setup
# detect: tool_installed claude

set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${BASEDIR}/scripts/common.sh"

LAUNCHER="${HOME}/.local/bin/claude"

# The launcher's version, when it answers.
claude_version() {
    "${LAUNCHER}" --version 2>/dev/null | head -n 1 || true
}

if [[ -x "${LAUNCHER}" ]]; then
    log_info "Claude Code $(claude_version) already installed at ${LAUNCHER}"
elif tool_installed claude; then
    # Through Homebrew (or on PATH some other way): not installed twice.
    log_info "Claude Code already installed outside ${LAUNCHER}; leaving it to its own updates"
    exit 0
else
    # The installer reuses downloads under ~/.local/share/claude, so a version
    # the desktop app already fetched only gets the launcher.
    spin "Installing Claude Code..." bash -c 'set -o pipefail; curl -fsSL https://claude.ai/install.sh | bash'
    if [[ -x "${LAUNCHER}" ]]; then
        log_info "Claude Code $(claude_version) installed at ${LAUNCHER}"
    else
        log_warn "The installer finished but ${LAUNCHER} is missing; see https://code.claude.com/docs/en/setup"
    fi
fi

# The cask's binary usually sits earlier on PATH than ~/.local/bin, so the
# native build would never run.
if command -v brew >/dev/null 2>&1; then
    for cask in claude-code@latest claude-code; do
        if brew list --cask "${cask}" &>/dev/null; then
            log_warn "Homebrew's ${cask} cask is still installed and shadows the native build on PATH; remove it with: brew uninstall --cask ${cask}"
        fi
    done
fi

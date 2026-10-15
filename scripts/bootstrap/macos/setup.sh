#!/usr/bin/env bash

set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${BASEDIR}/scripts/common.sh"

# -n/--dry-run reports what is missing without installing anything.
DRY_RUN=0
[[ "${1:-}" != -n && "${1:-}" != --dry-run ]] || DRY_RUN=1

log_info "Starting macOS bootstrap"

# Ensure Xcode Command Line Tools are installed (required for git, compilers, Homebrew)
if xcode-select -p &>/dev/null; then
    log_info "Xcode Command Line Tools already installed"
elif [[ "${DRY_RUN}" -eq 1 ]]; then
    log_info "Would install the Xcode Command Line Tools"
else
    log_info "Installing Xcode Command Line Tools; finish the installer window, this waits for it"
    xcode-select --install
    # The installer is a GUI window, so wait for it instead of a keypress that
    # closed stdin can never give; CLT_WAIT_SECONDS caps the wait (tests).
    waited=0
    until xcode-select -p &>/dev/null; do
        if [[ "${waited}" -ge "${CLT_WAIT_SECONDS:-1800}" ]]; then
            log_error "Xcode Command Line Tools still missing; finish the installer, then run install.sh again"
            exit 1
        fi
        sleep "${CLT_POLL_SECONDS:-10}"
        waited=$((waited + ${CLT_POLL_SECONDS:-10}))
    done
    log_info "Xcode Command Line Tools installed"
fi

# Accept Xcode license if needed (only when full Xcode.app is installed)
if [[ -d "/Applications/Xcode.app" ]] && ! xcodebuild -license check &>/dev/null; then
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        log_info "Would accept the Xcode license"
    else
        log_info "Accepting Xcode license"
        sudo_cmd xcodebuild -license accept
    fi
fi

# Enable Rosetta 2 on Apple Silicon
if [[ "$(uname -m)" == "arm64" ]]; then
    if pgrep -q oahd >/dev/null 2>&1; then
        log_info "Rosetta 2 already installed"
    elif [[ "${DRY_RUN}" -eq 1 ]]; then
        log_info "Would install Rosetta 2"
    else
        spin "Installing Rosetta 2..." softwareupdate --install-rosetta --agree-to-license
    fi
fi

[[ "${DRY_RUN}" -eq 1 ]] || "${BASEDIR}/scripts/bootstrap/macos/iterm2.sh"

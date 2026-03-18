#!/usr/bin/env bash

set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${BASEDIR}/scripts/common.sh"

log_info "Starting macOS bootstrap"

# Ensure Xcode Command Line Tools are installed (required for git, compilers, Homebrew)
if ! xcode-select -p &>/dev/null; then
    log_info "Installing Xcode Command Line Tools"
    xcode-select --install
    log_info "Press any key once the Xcode CLT installer finishes"
    read -r -n 1
else
    log_info "Xcode Command Line Tools already installed"
fi

# Accept Xcode license if needed (only when full Xcode.app is installed)
if [[ -d "/Applications/Xcode.app" ]] && ! xcodebuild -license check &>/dev/null; then
    log_info "Accepting Xcode license"
    sudo_cmd xcodebuild -license accept
fi

# Enable Rosetta 2 on Apple Silicon
if [[ "$(uname -m)" == "arm64" ]]; then
    if ! pgrep -q oahd >/dev/null 2>&1; then
        spin "Installing Rosetta 2..." softwareupdate --install-rosetta --agree-to-license
    else
        log_info "Rosetta 2 already installed"
    fi
fi

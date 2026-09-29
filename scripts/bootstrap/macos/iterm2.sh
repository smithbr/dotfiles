#!/usr/bin/env bash

# iTerm2 settings that live outside profiles. The profile itself is the
# Dynamic Profile in stow/desktop.darwin; this makes it the default.

set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${BASEDIR}/scripts/common.sh"

ITERM_APP="${ITERM_APP:-/Applications/iTerm.app}"
ITERM_DOMAIN="com.googlecode.iterm2"
# Matches "Guid" in DynamicProfiles/dotfiles.json.
PROFILE_GUID="1254BA0C-8BB4-46CF-BF21-80F30A1F2B77"

if [[ ! -d "${ITERM_APP}" ]]; then
    log_info "iTerm2 not installed; skipping its settings"
    exit 0
fi

# set_default KEY TYPE VALUE SHOWN: write only when `defaults read` differs from SHOWN.
set_default() {
    local key="$1" type="$2" value="$3" shown="$4" current
    current="$(defaults read "${ITERM_DOMAIN}" "${key}" 2>/dev/null || true)"
    if [[ "${current}" == "${shown}" ]]; then
        log_info "iTerm2 ${key} already set"
        return 0
    fi
    defaults write "${ITERM_DOMAIN}" "${key}" "${type}" "${value}"
    log_info "Set iTerm2 ${key}"
}

# Claude Code's iTerm2 split-pane teammates drive iTerm2 through its Python API.
set_default EnableAPIServer -bool true 1
set_default "Default Bookmark Guid" -string "${PROFILE_GUID}" "${PROFILE_GUID}"

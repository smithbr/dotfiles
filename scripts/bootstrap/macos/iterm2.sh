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
# Split panes run under throwaway profiles, so a per-profile "don't warn again"
# never sticks; 0 turns off the "session ended very soon" warning everywhere.
set_default shortLivedSessionDuration -float 0 0
set_default "Default Bookmark Guid" -string "${PROFILE_GUID}" "${PROFILE_GUID}"

# The Catppuccin presets show in Color Presets once they are in "Custom Color
# Presets". Read from the repo so this works before linking; other presets are
# left alone, and a preset is written only when missing or different.
for preset in "${BASEDIR}/stow/desktop.darwin/.config/iterm2/"*.itermcolors; do
    name="$(basename "${preset}" .itermcolors)"
    want="$(plutil -convert xml1 -o - "${preset}")"
    have="$(defaults export "${ITERM_DOMAIN}" - 2>/dev/null |
        plutil -extract "Custom Color Presets.${name}" xml1 -o - - 2>/dev/null || true)"
    if [[ "${have}" == "${want}" ]]; then
        log_info "iTerm2 color preset ${name} already set"
        continue
    fi
    defaults write "${ITERM_DOMAIN}" "Custom Color Presets" -dict-add "${name}" "${want}"
    log_info "Set iTerm2 color preset ${name}"
done

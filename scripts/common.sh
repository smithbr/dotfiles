#!/usr/bin/env bash

set -euo pipefail

# Homebrew resolves its trust store from XDG_CONFIG_HOME, falling back to
# ~/.homebrew when unset. The bootstrap runs before chezmoi deploys ~/.zshenv,
# which is what normally exports it, so without this default `brew trust` grants
# made during install land somewhere the finished shell never reads. Guarded on
# HOME so callers that deliberately unset it still hit their own error path.
if [[ -z "${XDG_CONFIG_HOME:-}" && -n "${HOME:-}" ]]; then
    export XDG_CONFIG_HOME="${HOME}/.config"
fi

_has_gum=""
_has_gum_checked=0
_check_gum() {
    if [[ "${_has_gum_checked}" -eq 0 ]]; then
        _has_gum_checked=1
        command -v gum >/dev/null 2>&1 && _has_gum=1 || _has_gum=0
    fi
}

log_info() {
    _check_gum
    if [[ "${_has_gum}" -eq 1 ]]; then
        gum log --level info "$*"
    else
        printf "info: %s\n" "$*"
    fi
}

log_warn() {
    _check_gum
    if [[ "${_has_gum}" -eq 1 ]]; then
        gum log --level warn "$*" >&2
    else
        printf "warning: %s\n" "$*" >&2
    fi
}

log_error() {
    _check_gum
    if [[ "${_has_gum}" -eq 1 ]]; then
        gum log --level error "$*" >&2
    else
        printf "error: %s\n" "$*" >&2
    fi
}

require_non_root() {
    if [[ "${EUID}" -eq 0 ]]; then
        log_error "Do not run this script as root."
        exit 1
    fi
}

sudo_cmd() {
    if [[ "${EUID}" -eq 0 ]]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        log_error "sudo is required for: $*"
        exit 1
    fi
}

spin() {
    local title="$1"
    shift

    # gum spin hides the wrapped command's stdout/stderr, which turns real
    # failures into an opaque "<title> failed" with no detail. VERBOSE=1
    # (see brew.sh -v/--verbose) skips the spinner so output streams through.
    if [[ "${VERBOSE:-0}" -eq 1 ]]; then
        log_info "${title}"
        if ! "$@"; then
            log_error "${title} failed"
            return 1
        fi
        return 0
    fi

    if command -v gum >/dev/null 2>&1 && [[ "$(type -t "$1" 2>/dev/null)" != "function" ]]; then
        if ! gum spin --spinner dot --title "${title}" --padding="0 1" -- "$@"; then
            log_error "${title} failed"
            return 1
        fi
    else
        log_info "${title}"
        "$@"
    fi
}

gum_choose_multiselect() {
    local header="$1"
    local height="$2"
    shift 2

    gum choose \
        --no-limit \
        --ordered \
        --height="${height}" \
        --header="${header}" \
        --cursor=" " \
        --cursor-prefix="> " \
        --selected-prefix="* " \
        --unselected-prefix="  " \
        --no-show-help \
        --padding="0 1" \
        --cursor.foreground="63" \
        --header.foreground="245" \
        --item.foreground="252" \
        --selected.foreground="213" \
        "$@"
}

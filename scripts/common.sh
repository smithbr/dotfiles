#!/usr/bin/env bash

set -euo pipefail

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

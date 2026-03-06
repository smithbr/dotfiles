#!/usr/bin/env bash

set -euo pipefail

log_info() {
    printf "info: %s\n" "$*"
}

log_warn() {
    printf "warning: %s\n" "$*" >&2
}

log_error() {
    printf "error: %s\n" "$*" >&2
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

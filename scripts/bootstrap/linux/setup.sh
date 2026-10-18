#!/usr/bin/env bash
# Linux bootstrap: the base apt packages from apt-packages.txt.
# -n/--dry-run names the missing packages without installing them.

set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
BOOTSTRAP_DIR="${BOOTSTRAP_DIR:-${BASEDIR}/scripts/bootstrap/linux}"
APT_PACKAGES_FILE="${APT_PACKAGES_FILE:-${BOOTSTRAP_DIR}/apt-packages.txt}"
source "${BASEDIR}/scripts/common.sh"

DRY_RUN=0
[[ "${1:-}" != -n && "${1:-}" != --dry-run ]] || DRY_RUN=1

load_apt_packages() {
    local pkg=""

    while IFS= read -r pkg || [[ -n "${pkg}" ]]; do
        [[ -z "${pkg}" ]] && continue
        [[ "${pkg}" == \#* ]] && continue
        printf '%s\n' "${pkg}"
    done < "${APT_PACKAGES_FILE}"
}

install_base_linux_packages() {
    local pkg=""
    local -a apt_packages=()
    local -a missing_packages=()
    local installed_packages_text=""

    while IFS= read -r pkg || [[ -n "${pkg}" ]]; do
        apt_packages+=("${pkg}")
    done < <(load_apt_packages)

    installed_packages_text=" $(dpkg-query -W -f='${Package}\t${Status}\n' "${apt_packages[@]}" 2>/dev/null \
        | awk '$2 == "install" && $3 == "ok" && $4 == "installed" { print $1 }' \
        | tr '\n' ' ' || true) "

    for pkg in "${apt_packages[@]}"; do
        if [[ "${installed_packages_text}" != *" ${pkg} "* ]]; then
            missing_packages+=("${pkg}")
        fi
    done

    if [[ "${#missing_packages[@]}" -gt 0 && "${DRY_RUN}" -eq 1 ]]; then
        log_info "Would install base Linux packages: ${missing_packages[*]}"
    elif [[ "${#missing_packages[@]}" -gt 0 ]]; then
        log_info "Updating apt package index"
        sudo_cmd apt-get update

        log_info "Installing base Linux packages: ${missing_packages[*]}"
        sudo_cmd apt-get install -y "${missing_packages[@]}"
    else
        log_info "Base Linux packages already installed"
    fi
}

main() {
    log_info "Starting Linux bootstrap"

    if ! command -v apt-get >/dev/null 2>&1; then
        log_warn "apt-get not found; skipping Linux package bootstrap"
        exit 0
    fi

    log_info "Checking base Linux packages"
    install_base_linux_packages

    log_info "Linux bootstrap finished"
}

main "$@"

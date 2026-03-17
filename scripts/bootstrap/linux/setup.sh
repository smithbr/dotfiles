#!/usr/bin/env bash

set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
BOOTSTRAP_DIR="${BOOTSTRAP_DIR:-${BASEDIR}/scripts/bootstrap/linux}"
APT_PACKAGES_FILE="${APT_PACKAGES_FILE:-${BOOTSTRAP_DIR}/apt-packages.txt}"
source "${BASEDIR}/scripts/common.sh"

declare -a SELECTED_OPTIONAL_NAMES=()
declare -a SELECTED_OPTIONAL_SCRIPTS=()

run_bootstrap_step() {
    local step_label="$1"
    local title="$2"

    log_info "Step ${step_label}: ${title}"
}

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

    if [[ "${#missing_packages[@]}" -gt 0 ]]; then
        log_info "Updating apt package index"
        sudo_cmd apt-get update

        log_info "Installing base Linux packages: ${missing_packages[*]}"
        sudo_cmd apt-get install -y "${missing_packages[@]}"
    else
        log_info "Base Linux packages already installed"
    fi
}

optional_linux_entry_is_installed() {
    local entry_id="$1"

    case "${entry_id}" in
        docker)
            command -v docker >/dev/null 2>&1
            ;;
        tailscale)
            command -v tailscale >/dev/null 2>&1
            ;;
        opencode)
            command -v opencode >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}

run_optional_bootstrap_script() {
    local step_label="$1"
    local display_name="$2"
    local script_name="$3"

    run_bootstrap_step "${step_label}" "Running ${display_name} bootstrap"
    chmod +x "${BOOTSTRAP_DIR}/${script_name}"
    "${BOOTSTRAP_DIR}/${script_name}"
}

prompt_optional_linux_bootstraps() {
    local prompt_label="$1"
    local tmp_optional_entries=""
    local raw_entry=""
    local entry_id=""
    local display_name=""
    local script_name=""
    local idx=0
    local reply=""
    local selected_name=""
    local pending_count=0
    local height=0
    local tmp_gum_output=""
    local -a optional_entries=(
        "docker|Docker|docker.sh"
        "tailscale|Tailscale|tailscale.sh"
        "opencode|OpenCode|opencode.sh"
    )
    local -a pending_names=()
    local -a pending_scripts=()

    SELECTED_OPTIONAL_NAMES=()
    SELECTED_OPTIONAL_SCRIPTS=()

    tmp_optional_entries="$(mktemp "${TMPDIR:-/tmp}/linux-bootstrap-optional.XXXXXX")"

    for raw_entry in "${optional_entries[@]}"; do
        IFS='|' read -r entry_id display_name script_name <<< "${raw_entry}"

        if optional_linux_entry_is_installed "${entry_id}"; then
            continue
        fi

        pending_names+=("${display_name}")
        pending_scripts+=("${script_name}")
        pending_count=$((pending_count + 1))
    done

    if [[ "${pending_count}" -eq 0 ]]; then
        log_info "All ${prompt_label}s already installed"
        rm -f "${tmp_optional_entries}"
        return
    fi

    if command -v gum >/dev/null 2>&1 && [[ -t 0 && -t 1 ]]; then
        height="${pending_count}"
        if [[ "${height}" -gt 15 ]]; then
            height=15
        fi
        if [[ "${height}" -lt 3 ]]; then
            height=3
        fi

        tmp_gum_output="$(mktemp "${TMPDIR:-/tmp}/gum-output.XXXXXX")"

        gum choose \
            --no-limit \
            --ordered \
            --height="${height}" \
            --cursor="> " \
            --header="Select optional packages to install" \
            --selected-prefix="* " \
            --unselected-prefix="  " \
            "${pending_names[@]}" > "${tmp_gum_output}" 2>/dev/null || true

        while IFS= read -r selected_name || [[ -n "${selected_name}" ]]; do
            [[ -z "${selected_name}" ]] && continue
            for idx in "${!pending_names[@]}"; do
                if [[ "${pending_names[${idx}]}" == "${selected_name}" ]]; then
                    printf '%s\n' "${idx}" >> "${tmp_optional_entries}"
                    break
                fi
            done
        done < "${tmp_gum_output}"
        rm -f "${tmp_gum_output}"
    else
        for idx in "${!pending_names[@]}"; do
            read -r -p "Install ${prompt_label} ${pending_names[${idx}]}? [Y/n] " reply
            if [[ -z "${reply}" || "${reply}" =~ ^[Yy]$ ]]; then
                printf '%s\n' "${idx}" >> "${tmp_optional_entries}"
            fi
        done
    fi

    while IFS= read -r idx || [[ -n "${idx}" ]]; do
        [[ -z "${idx}" ]] && continue
        SELECTED_OPTIONAL_NAMES+=("${pending_names[${idx}]}")
        SELECTED_OPTIONAL_SCRIPTS+=("${pending_scripts[${idx}]}")
    done < "${tmp_optional_entries}"

    if [[ "${#SELECTED_OPTIONAL_NAMES[@]}" -eq 0 ]]; then
        log_info "No ${prompt_label}s selected"
        rm -f "${tmp_optional_entries}"
        return
    fi

    if command -v gum >/dev/null 2>&1; then
        printf '\033[2m  %s\033[0m\n' "${SELECTED_OPTIONAL_NAMES[*]}"
    else
        log_info "Running optional Linux installs: ${SELECTED_OPTIONAL_NAMES[*]}"
    fi

    rm -f "${tmp_optional_entries}"
}

main() {
    local idx=0

    log_info "Starting Linux bootstrap"

    if ! command -v apt-get >/dev/null 2>&1; then
        log_warn "apt-get not found; skipping Linux package bootstrap"
        exit 0
    fi

    run_bootstrap_step "1" "Checking base Linux packages"
    install_base_linux_packages

    prompt_optional_linux_bootstraps "optional Linux install"

    for idx in "${!SELECTED_OPTIONAL_NAMES[@]}"; do
        run_optional_bootstrap_script \
            "$((idx + 2))" \
            "${SELECTED_OPTIONAL_NAMES[${idx}]}" \
            "${SELECTED_OPTIONAL_SCRIPTS[${idx}]}"
    done

    log_info "Linux bootstrap finished"
}

main "$@"

#!/usr/bin/env bash

set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${BASEDIR}/scripts/common.sh"

require_non_root

case "${OSTYPE}" in
    darwin*)
        os_name="Darwin"
        brewplatform=Homebrew
        brewpath=homebrew
        case "$(uname -m)" in
            arm64)
                brewbinpath=/opt/homebrew/bin
                brewsbinpath=/opt/homebrew/sbin
                ;;
            *)
                brewbinpath=/usr/local/bin
                brewsbinpath=/usr/local/sbin
                ;;
        esac
        ;;
    linux*)
        os_name="Linux"
        brewplatform=Homebrew
        brewpath=homebrew
        brewbinpath=/home/linuxbrew/.linuxbrew/bin
        brewsbinpath=/home/linuxbrew/.linuxbrew/sbin
        ;;
    *)
        log_error "Unsupported OS: ${OSTYPE}"
        exit 1
        ;;
esac

export PATH="${brewbinpath}:${brewsbinpath}:${PATH}"

if [[ ! -x "${brewbinpath}/brew" ]] && ! command -v brew >/dev/null 2>&1; then
    printf "\n\nInstalling %s...\n\n" "${brewpath}"
    /bin/bash -c "$(curl -fsSL "https://raw.githubusercontent.com/${brewplatform}/install/HEAD/install.sh")"
fi

brew_prefix="$(brew --prefix)"
export PATH="${brew_prefix}/bin:${brew_prefix}/sbin:${PATH}"

BREWFILE="${BASEDIR}/homebrew/Brewfile.core"
OPTIONAL_BREWFILE="${BASEDIR}/homebrew/Brewfile.macos"

refresh_brew_state() {
    _installed_formulae=" $(brew list --formula 2>/dev/null | tr '\n' ' ') "
    _installed_casks=" $(brew list --cask 2>/dev/null | tr '\n' ' ') "
    _installed_taps=" $(brew tap 2>/dev/null | tr '\n' ' ') "
}

refresh_brew_state

_brew_has_formula() { [[ "${_installed_formulae}" == *" $1 "* ]]; }
_brew_has_cask()    { [[ "${_installed_casks}" == *" $1 "* ]]; }
_brew_has_tap()     { [[ "${_installed_taps}" == *" $1 "* ]]; }

declare -a LINUX_SUPPORTED_CASKS=(
    "chezit"
)

brew_entry_short_name() {
    local pkg_name="$1"

    printf '%s\n' "${pkg_name##*/}"
}

linux_cask_is_supported() {
    local pkg_name="$1"
    local short_name=""
    local supported_cask=""

    short_name="$(brew_entry_short_name "${pkg_name}")"

    case "${short_name}" in
        font-*)
            return 0
            ;;
    esac

    for supported_cask in "${LINUX_SUPPORTED_CASKS[@]}"; do
        if [[ "${short_name}" == "${supported_cask}" ]]; then
            return 0
        fi
    done

    return 1
}

entry_is_supported_on_platform() {
    local pkg_type="$1"
    local pkg_name="$2"

    if [[ "${os_name}" != "Linux" || "${pkg_type}" != "cask" ]]; then
        return 0
    fi

    linux_cask_is_supported "${pkg_name}"
}

entry_is_brew_managed() {
    local pkg_type="$1"
    local pkg_name="$2"

    case "${pkg_type}" in
        brew)
            if _brew_has_formula "${pkg_name}"; then
                return 0
            fi
            ;;
        cask)
            if _brew_has_cask "$(brew_entry_short_name "${pkg_name}")"; then
                return 0
            fi
            ;;
        tap)
            if _brew_has_tap "${pkg_name}"; then
                return 0
            fi
            ;;
        mas)
            # `mas` entries are installed from the App Store and typically use IDs.
            # Leave these to `brew bundle` unless already tracked by brew.
            ;;
    esac

    return 1
}

cask_app_bundle_exists() {
    local pkg_name="$1"
    local cask_json=""
    local app_candidate=""

    if [[ "${os_name}" != "Darwin" ]]; then
        return 1
    fi

    cask_json="$(brew info --cask --json=v2 "${pkg_name}" 2>/dev/null || true)"
    if [[ -z "${cask_json}" ]]; then
        return 1
    fi

    while IFS= read -r app_candidate; do
        app_candidate="${app_candidate#\"}"
        app_candidate="${app_candidate%\"}"
        app_candidate="${app_candidate%%.app*}.app"
        app_candidate="${app_candidate##*/}"

        [[ -z "${app_candidate}" ]] && continue

        if [[ -d "/Applications/${app_candidate}" ]] || [[ -d "${HOME}/Applications/${app_candidate}" ]]; then
            return 0
        fi
    done < <(printf '%s\n' "${cask_json}" | grep -o '"[^"]*\.app[^"]*"')

    return 1
}

optional_entry_is_installed() {
    local pkg_type="$1"
    local pkg_name="$2"

    if entry_is_brew_managed "${pkg_type}" "${pkg_name}"; then
        return 0
    fi

    if [[ "${pkg_type}" == "cask" ]] && cask_app_bundle_exists "${pkg_name}"; then
        return 0
    fi

    return 1
}

optional_prompt_mode() {
    if [[ ! -e /dev/tty ]]; then
        printf 'skip\n'
        return
    fi

    if command -v gum >/dev/null 2>&1; then
        printf 'gum\n'
    else
        printf 'read\n'
    fi
}

install_filtered_brewfile() {
    local source_brewfile="$1"
    local prompt_label="$2"
    local tmp_brewfile
    local raw_line
    local line
    local pkg_type
    local pkg_name
    local selected_count=0
    local -a pending_names=()

    tmp_brewfile="$(mktemp "${TMPDIR:-/tmp}/brewfile-required.XXXXXX")"

    while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
        line="${raw_line#"${raw_line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        [[ -z "${line}" ]] && continue
        [[ "${line}" == \#* ]] && continue

        if [[ "${line}" =~ ^(brew|cask|tap|mas)[[:space:]]+\"([^\"]+)\" ]]; then
            pkg_type="${BASH_REMATCH[1]}"
            pkg_name="${BASH_REMATCH[2]}"
        elif [[ "${line}" =~ ^(brew|cask|tap|mas)[[:space:]]+\'([^\']+)\' ]]; then
            pkg_type="${BASH_REMATCH[1]}"
            pkg_name="${BASH_REMATCH[2]}"
        else
            log_warn "Skipping unsupported ${prompt_label} line: ${line}"
            continue
        fi

        if entry_is_brew_managed "${pkg_type}" "${pkg_name}"; then
            continue
        fi

        if ! entry_is_supported_on_platform "${pkg_type}" "${pkg_name}"; then
            continue
        fi

        printf '%s "%s"\n' "${pkg_type}" "${pkg_name}" >> "${tmp_brewfile}"
        pending_names+=("${pkg_name}")
        selected_count=$((selected_count + 1))
    done < "${source_brewfile}"

    if [[ "${selected_count}" -gt 0 ]]; then
        spin "Installing ${prompt_label}s..." brew bundle install --file="${tmp_brewfile}"
        refresh_brew_state
    else
        log_info "All ${prompt_label}s already installed"
    fi

    rm -f "${tmp_brewfile}"
}

ensure_1password_agent_symlink() {
    local target_socket=""
    local link_dir="${HOME}/.1password"
    local link_path="${link_dir}/agent.sock"

    if ! command -v op >/dev/null 2>&1; then
        return 0
    fi

    case "${OSTYPE}" in
        darwin*)
            target_socket="${HOME}/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
            ;;
        *)
            return 0
            ;;
    esac

    mkdir -p "${link_dir}"

    if [[ -L "${link_path}" ]] && [[ "$(readlink "${link_path}")" == "${target_socket}" ]]; then
        return 0
    fi

    ln -snf "${target_socket}" "${link_path}"
    log_info "Linked 1Password SSH agent socket at ${link_path}"
}

install_filtered_brewfile "${BREWFILE}" "core Homebrew package"

prompt_optional_brewfile() {
    local optional_brewfile="$1"
    local prompt_label="$2"
    local tmp_optional_brewfile
    local tmp_scan_output
    local scan_pid
    local selected_optional=0
    local -a optional_entries=()
    local -a optional_names=()
    local raw_line
    local line
    local pkg_type
    local pkg_name
    local idx
    local entry
    local reply
    local display_entry
    local pending_count=0
    local selected_name
    local prompt_mode=""
    tmp_optional_brewfile="$(mktemp "${TMPDIR:-/tmp}/brewfile-optional.XXXXXX")"
    tmp_scan_output="$(mktemp "${TMPDIR:-/tmp}/brewfile-optional-scan.XXXXXX")"

    collect_pending_optional_entries() {
        while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
            line="${raw_line#"${raw_line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"

            [[ -z "${line}" ]] && continue
            if [[ "${line}" == \#* ]]; then
                continue
            fi

            if [[ "${line}" =~ ^(brew|cask|tap|mas)[[:space:]]+\"([^\"]+)\" ]]; then
                pkg_type="${BASH_REMATCH[1]}"
                pkg_name="${BASH_REMATCH[2]}"
            elif [[ "${line}" =~ ^(brew|cask|tap|mas)[[:space:]]+\'([^\']+)\' ]]; then
                pkg_type="${BASH_REMATCH[1]}"
                pkg_name="${BASH_REMATCH[2]}"
            else
                log_warn "Skipping unsupported optional line: ${line}"
                continue
            fi

            if optional_entry_is_installed "${pkg_type}" "${pkg_name}"; then
                continue
            fi

            printf '%s\t%s\n' "${pkg_type}" "${pkg_name}" >> "${tmp_scan_output}"
        done < "${optional_brewfile}"
    }

    collect_pending_optional_entries &
    scan_pid=$!

    if command -v gum >/dev/null 2>&1 && [[ -e /dev/tty ]]; then
        spin "Checking already installed optional packages..." \
            bash -c "while kill -0 \"\$1\" 2>/dev/null; do sleep 0.1; done" _ "${scan_pid}"
    else
        log_info "Checking already installed optional packages..."
    fi

    wait "${scan_pid}"

    while IFS=$'\t' read -r pkg_type pkg_name || [[ -n "${pkg_type:-}" ]]; do
        [[ -z "${pkg_type:-}" || -z "${pkg_name:-}" ]] && continue
        optional_entries+=("${pkg_type} \"${pkg_name}\"")
        optional_names+=("${pkg_name}")
        pending_count=$((pending_count + 1))
    done < "${tmp_scan_output}"

    rm -f "${tmp_scan_output}"

    if [[ "${pending_count}" -eq 0 ]]; then
        log_info "All ${prompt_label}s already installed"
        rm -f "${tmp_optional_brewfile}"
        return
    fi

    prompt_mode="$(optional_prompt_mode)"

    case "${prompt_mode}" in
        skip)
            log_info "Skipping optional Homebrew package selection because no interactive terminal was detected"
            rm -f "${tmp_optional_brewfile}"
            return
            ;;
        gum)
            log_info "Optional Homebrew packages available. Use space to select, enter to continue, or esc to skip."

            local height="${pending_count}"
            if [[ "${height}" -gt 15 ]]; then
                height=15
            fi
            if [[ "${height}" -lt 3 ]]; then
                height=3
            fi

            local tmp_gum_output
            tmp_gum_output="$(mktemp "${TMPDIR:-/tmp}/gum-output.XXXXXX")"

            gum choose \
                --no-limit \
                --ordered \
                --height="${height}" \
                --cursor="> " \
                --header="Select optional packages to install" \
                --selected-prefix="* " \
                --unselected-prefix="  " \
                "${optional_names[@]}" \
                < /dev/tty \
                > "${tmp_gum_output}" \
                2> /dev/tty || true

            while IFS= read -r selected_name || [[ -n "${selected_name}" ]]; do
                [[ -z "${selected_name}" ]] && continue
                for idx in "${!optional_names[@]}"; do
                    if [[ "${optional_names[${idx}]}" == "${selected_name}" ]]; then
                        printf '%s\n' "${optional_entries[${idx}]}" >> "${tmp_optional_brewfile}"
                        selected_optional=$((selected_optional + 1))
                        break
                    fi
                done
            done < "${tmp_gum_output}"
            rm -f "${tmp_gum_output}"
            ;;
        read)
            log_info "Optional Homebrew packages available. Press Enter to install a package, or n to skip."

            for idx in "${!optional_entries[@]}"; do
                entry="${optional_entries[${idx}]}"
                display_entry="${optional_names[${idx}]}"
                printf "Install %s %s? [Y/n] " "${prompt_label}" "${display_entry}" > /dev/tty
                read -r reply < /dev/tty
                if [[ -z "${reply}" || "${reply}" =~ ^[Yy]$ ]]; then
                    printf '%s\n' "${entry}" >> "${tmp_optional_brewfile}"
                    selected_optional=$((selected_optional + 1))
                fi
            done
            ;;
    esac

    if [[ "${selected_optional}" -gt 0 ]]; then
        spin "Installing ${prompt_label}s..." brew bundle install --file="${tmp_optional_brewfile}"
        refresh_brew_state
        log_info "Installed ${selected_optional} ${prompt_label}(s)"
    else
        log_info "No ${prompt_label}s selected"
    fi
    rm -f "${tmp_optional_brewfile}"
}

if [[ "${os_name}" == "Darwin" && -f "${OPTIONAL_BREWFILE}" ]]; then
    prompt_optional_brewfile "${OPTIONAL_BREWFILE}" "optional Homebrew package"
fi

ensure_1password_agent_symlink

spin "Cleaning up Homebrew..." brew cleanup --prune=all
log_info "Removing Homebrew cache"
rm -rf "$(brew --cache)"

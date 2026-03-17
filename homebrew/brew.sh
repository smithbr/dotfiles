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
            if _brew_has_cask "${pkg_name}"; then
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

        # Casks are not supported on Linux.
        if [[ "${os_name}" == "Linux" && "${pkg_type}" == "cask" && "${pkg_name}" != font-* ]]; then
            continue
        fi

        printf '%s "%s"\n' "${pkg_type}" "${pkg_name}" >> "${tmp_brewfile}"
        pending_names+=("${pkg_name}")
        selected_count=$((selected_count + 1))
    done < "${source_brewfile}"

    if [[ "${selected_count}" -gt 0 ]]; then
        if command -v gum >/dev/null 2>&1; then
            printf '\033[2m  %s\033[0m\n' "${pending_names[*]}"
            gum spin --spinner dot --title "Installing ${prompt_label}s..." -- \
                brew bundle install --file="${tmp_brewfile}"
        else
            log_info "Installing ${prompt_label}s: ${pending_names[*]}"
            brew bundle install --file="${tmp_brewfile}"
        fi
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
    tmp_optional_brewfile="$(mktemp "${TMPDIR:-/tmp}/brewfile-optional.XXXXXX")"

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

        # Skip packages already managed by brew or already present as app bundles.
        if optional_entry_is_installed "${pkg_type}" "${pkg_name}"; then
            continue
        fi

        optional_entries+=("${pkg_type} \"${pkg_name}\"")
        optional_names+=("${pkg_name}")
        pending_count=$((pending_count + 1))
    done < "${optional_brewfile}"

    if [[ "${pending_count}" -eq 0 ]]; then
        log_info "All ${prompt_label}s already installed"
        rm -f "${tmp_optional_brewfile}"
        return
    fi

    # Single gum picker with all optional packages
    if command -v gum >/dev/null 2>&1 && [[ -t 0 && -t 1 ]]; then
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
            "${optional_names[@]}" > "${tmp_gum_output}" || true

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
    else
        for idx in "${!optional_entries[@]}"; do
            entry="${optional_entries[${idx}]}"
            display_entry="${optional_names[${idx}]}"
            read -r -p "Install ${prompt_label} ${display_entry}? [Y/n] " reply
            if [[ -z "${reply}" || "${reply}" =~ ^[Yy]$ ]]; then
                printf '%s\n' "${entry}" >> "${tmp_optional_brewfile}"
                selected_optional=$((selected_optional + 1))
            fi
        done
    fi

    if [[ "${selected_optional}" -gt 0 ]]; then
        local -a opt_names=()
        local opt_line
        while IFS= read -r opt_line || [[ -n "${opt_line}" ]]; do
            if [[ "${opt_line}" =~ ^[a-z]+[[:space:]]+\"([^\"]+)\" ]]; then
                opt_names+=("${BASH_REMATCH[1]}")
            fi
        done < "${tmp_optional_brewfile}"
        if command -v gum >/dev/null 2>&1; then
            printf '\033[2m  %s\033[0m\n' "${opt_names[*]}"
            gum spin --spinner dot --title "Installing optional packages..." -- \
                brew bundle install --file="${tmp_optional_brewfile}"
        else
            log_info "Installing optional Homebrew packages: ${opt_names[*]}"
            brew bundle install --file="${tmp_optional_brewfile}"
        fi
        refresh_brew_state
    else
        log_info "No ${prompt_label}s selected"
    fi
    rm -f "${tmp_optional_brewfile}"
}

if [[ "${os_name}" == "Darwin" && -f "${OPTIONAL_BREWFILE}" ]]; then
    prompt_optional_brewfile "${OPTIONAL_BREWFILE}" "optional Homebrew package"
fi

ensure_1password_agent_symlink

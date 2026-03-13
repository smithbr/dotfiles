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
OPTIONAL_BREWFILE="${BASEDIR}/homebrew/Brewfile.optional"

refresh_brew_state() {
    _installed_formulae=" $(brew list --formula 2>/dev/null | tr '\n' ' ') "
    _installed_casks=" $(brew list --cask 2>/dev/null | tr '\n' ' ') "
    _installed_taps=" $(brew tap 2>/dev/null | tr '\n' ' ') "
}

refresh_brew_state

_brew_has_formula() { [[ "${_installed_formulae}" == *" $1 "* ]]; }
_brew_has_cask()    { [[ "${_installed_casks}" == *" $1 "* ]]; }
_brew_has_tap()     { [[ "${_installed_taps}" == *" $1 "* ]]; }

if ! _brew_has_formula fzf; then
    log_info "Installing required dependency: fzf"
    brew install fzf
    refresh_brew_state
fi

formula_command_available() {
    local pkg_name="$1"
    local base_name="${pkg_name%%@*}"
    local candidate
    local -a candidates=()

    case "${pkg_name}" in
        ripgrep)
            candidates=("rg")
            ;;
        gnupg)
            candidates=("gpg")
            ;;
        *)
            candidates=("${pkg_name}")
            if [[ "${base_name}" != "${pkg_name}" ]]; then
                candidates+=("${base_name}")
            fi
            ;;
    esac

    for candidate in "${candidates[@]}"; do
        if command -v "${candidate}" >/dev/null 2>&1; then
            return 0
        fi
    done

    return 1
}

linux_system_package_available() {
    local pkg_name="$1"
    local base_name="${pkg_name%%@*}"
    local candidate
    local status
    local -a candidates=()

    if [[ "${os_name}" != "Linux" ]]; then
        return 1
    fi

    candidates=("${pkg_name}")
    if [[ "${base_name}" != "${pkg_name}" ]]; then
        candidates+=("${base_name}")
    fi

    case "${pkg_name}" in
        node)
            candidates+=("nodejs")
            ;;
        docker)
            candidates+=("docker.io" "docker-ce" "moby-engine")
            ;;
        python)
            candidates+=("python3")
            ;;
    esac

    if command -v dpkg-query >/dev/null 2>&1; then
        for candidate in "${candidates[@]}"; do
            status="$(dpkg-query -W -f='${Status}' "${candidate}" 2>/dev/null || true)"
            if [[ "${status}" == "install ok installed" ]]; then
                return 0
            fi
        done
    fi

    if command -v snap >/dev/null 2>&1; then
        for candidate in "${candidates[@]}"; do
            if snap list "${candidate}" >/dev/null 2>&1; then
                return 0
            fi
        done
    fi

    return 1
}

normalize_name() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]'
}

cask_name_candidates() {
    local pkg_name="$1"
    local base_name="${pkg_name%%@*}"
    local stripped_name

    printf '%s\n' "${base_name}"

    for stripped_name in \
        "${base_name%-app}" \
        "${base_name%-cli}" \
        "${base_name%-desktop}" \
        "${base_name%-browser}" \
        "${base_name%-code}"
    do
        if [[ "${stripped_name}" != "${base_name}" ]]; then
            printf '%s\n' "${stripped_name}"
        fi
    done
}

cask_definition_candidates() {
    local pkg_name="$1"
    local raw_line
    local line
    local source_path
    local target_name

    while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
        line="${raw_line#"${raw_line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        if [[ "${line}" =~ ^(app|suite)[[:space:]]+\"([^\"]+\.app)\" ]]; then
            printf 'app\t%s\n' "${BASH_REMATCH[2]%.app}"
            continue
        fi
        if [[ "${line}" =~ ^(app|suite)[[:space:]]+\'([^\']+\.app)\' ]]; then
            printf 'app\t%s\n' "${BASH_REMATCH[2]%.app}"
            continue
        fi
        if [[ "${line}" =~ ^binary[[:space:]]+\"([^\"]+)\" ]]; then
            source_path="${BASH_REMATCH[1]}"
            target_name="${source_path##*/}"
            if [[ "${line}" =~ target:[[:space:]]*\"([^\"]+)\" ]]; then
                target_name="${BASH_REMATCH[1]}"
            fi
            printf 'bin\t%s\n' "${target_name}"
            continue
        fi
        if [[ "${line}" =~ ^binary[[:space:]]+\'([^\']+)\' ]]; then
            source_path="${BASH_REMATCH[1]}"
            target_name="${source_path##*/}"
            if [[ "${line}" =~ target:[[:space:]]*\'([^\']+)\' ]]; then
                target_name="${BASH_REMATCH[1]}"
            fi
            printf 'bin\t%s\n' "${target_name}"
        fi
    done < <(brew cat --cask "${pkg_name}" 2>/dev/null || true)
}

cask_artifact_available() {
    local pkg_name="$1"
    local search_dir
    local app_path
    local app_name
    local app_normalized
    local candidate_name
    local candidate_normalized
    local candidate_type

    if quick_cask_artifact_available "${pkg_name}"; then
        return 0
    fi

    while IFS=$'\t' read -r candidate_type candidate_name || [[ -n "${candidate_type}${candidate_name}" ]]; do
        [[ -z "${candidate_name}" ]] && continue
        case "${candidate_type}" in
            app)
                candidate_normalized="$(normalize_name "${candidate_name}")"
                [[ -z "${candidate_normalized}" ]] && continue
                for search_dir in "/Applications" "${HOME}/Applications"; do
                    [[ -d "${search_dir}" ]] || continue
                    for app_path in "${search_dir}"/*.app; do
                        [[ -d "${app_path}" ]] || continue
                        app_name="${app_path##*/}"
                        app_name="${app_name%.app}"
                        app_normalized="$(normalize_name "${app_name}")"
                        if [[ "${app_normalized}" == "${candidate_normalized}" ]] || [[ "${app_normalized}" == *"${candidate_normalized}"* ]]; then
                            return 0
                        fi
                    done
                done
                ;;
            bin)
                if command -v "${candidate_name}" >/dev/null 2>&1; then
                    return 0
                fi
                ;;
        esac
    done < <(cask_definition_candidates "${pkg_name}")

    return 1
}

quick_cask_artifact_available() {
    local pkg_name="$1"
    local search_dir
    local app_path
    local app_name
    local app_normalized
    local candidate_name
    local candidate_normalized

    while IFS= read -r candidate_name || [[ -n "${candidate_name}" ]]; do
        [[ -z "${candidate_name}" ]] && continue
        candidate_normalized="$(normalize_name "${candidate_name}")"
        [[ -z "${candidate_normalized}" ]] && continue

        for search_dir in "/Applications" "${HOME}/Applications"; do
            [[ -d "${search_dir}" ]] || continue
            for app_path in "${search_dir}"/*.app; do
                [[ -d "${app_path}" ]] || continue
                app_name="${app_path##*/}"
                app_name="${app_name%.app}"
                app_normalized="$(normalize_name "${app_name}")"
                if [[ "${app_normalized}" == "${candidate_normalized}" ]] || [[ "${app_normalized}" == *"${candidate_normalized}"* ]]; then
                    return 0
                fi
            done
        done
    done < <(cask_name_candidates "${pkg_name}")

    return 1
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

_entry_is_installed_impl() {
    local pkg_type="$1"
    local pkg_name="$2"
    local cask_check_fn="$3"

    if entry_is_brew_managed "${pkg_type}" "${pkg_name}"; then
        return 0
    fi

    case "${pkg_type}" in
        brew)
            if formula_command_available "${pkg_name}"; then
                return 0
            fi
            if linux_system_package_available "${pkg_name}"; then
                return 0
            fi
            ;;
        cask)
            if [[ "${os_name}" == "Darwin" ]] && "${cask_check_fn}" "${pkg_name}"; then
                return 0
            fi
            ;;
    esac

    return 1
}

entry_is_already_installed() {
    _entry_is_installed_impl "$1" "$2" cask_artifact_available
}

entry_is_menu_installed() {
    _entry_is_installed_impl "$1" "$2" quick_cask_artifact_available
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
        if [[ "${os_name}" == "Linux" && "${pkg_type}" == "cask" ]]; then
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

gum_choose_optional_category() {
    local prompt_label="$1"
    local category_name="$2"
    shift 2

    local option_count="$#"
    local height=8

    if [[ "${option_count}" -lt "${height}" ]]; then
        height="${option_count}"
    fi
    if [[ "${height}" -lt 3 ]]; then
        height=3
    fi

    gum choose \
        --no-limit \
        --ordered \
        --height="${height}" \
        --cursor="> " \
        --show-help=false \
        --header="Select ${prompt_label}s from ${category_name}" \
        --selected-prefix="* " \
        --unselected-prefix="  " \
        "$@" 2>/dev/null || true
}

append_gum_optional_selection() {
    local category_name="$1"
    local selected_names
    local selected_name
    local idx

    [[ "${#gum_category_names[@]}" -eq 0 ]] && return

    selected_names="$(gum_choose_optional_category "${prompt_label}" "${category_name}" "${gum_category_names[@]}")"

    while IFS= read -r selected_name || [[ -n "${selected_name}" ]]; do
        [[ -z "${selected_name}" ]] && continue
        [[ "${selected_name}" == "nothing selected" ]] && continue

        for idx in "${!gum_category_names[@]}"; do
            if [[ "${gum_category_names[${idx}]}" == "${selected_name}" ]]; then
                printf '%s\n' "${gum_category_entries[${idx}]}" >> "${tmp_optional_brewfile}"
                selected_optional=$((selected_optional + 1))
                break
            fi
        done
    done <<< "${selected_names}"
}

prompt_optional_brewfile() {
    local optional_brewfile="$1"
    local prompt_label="$2"
    local tmp_optional_brewfile
    local selected_optional=0
    local -a optional_entries=()
    local -a optional_categories=()
    local -a optional_installed=()
    local -a optional_names=()
    local raw_line
    local line
    local pkg_type
    local pkg_name
    local current_category="Other"
    local entry_category
    local category_text
    local prompt_last_category=""
    local idx
    local entry
    local reply
    local display_entry
    local installed_count=0
    local installable_count=0
    local gum_category_name=""
    local -a gum_category_entries=()
    local -a gum_category_names=()
    tmp_optional_brewfile="$(mktemp "${TMPDIR:-/tmp}/brewfile-optional.XXXXXX")"

    local _spin_pid=""
    if command -v gum >/dev/null 2>&1; then
        gum spin --spinner dot --title "Scanning optional packages..." -- sleep infinity &
        _spin_pid=$!
    fi

    while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
        line="${raw_line#"${raw_line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        [[ -z "${line}" ]] && continue
        if [[ "${line}" == \#* ]]; then
            category_text="${line#\# }"
            if [[ "${category_text}" != "Optional dependencies. \`homebrew/brew.sh\` prompts for each entry." ]] && \
                [[ "${category_text}" != "Supported entry types: brew, cask, tap, mas." ]]; then
                current_category="${category_text}"
            fi
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

        # Casks are not supported on Linux.
        if [[ "${os_name}" == "Linux" && "${pkg_type}" == "cask" ]]; then
            continue
        fi

        entry_category="${current_category}"
        optional_entries+=("${pkg_type} \"${pkg_name}\"")
        optional_categories+=("${entry_category}")
        optional_names+=("${pkg_name}")
        if entry_is_menu_installed "${pkg_type}" "${pkg_name}"; then
            optional_installed+=("1")
            installed_count=$((installed_count + 1))
        else
            optional_installed+=("0")
            installable_count=$((installable_count + 1))
        fi
    done < "${optional_brewfile}"

    if [[ -n "${_spin_pid}" ]]; then
        kill "${_spin_pid}" 2>/dev/null
        wait "${_spin_pid}" 2>/dev/null || true
    fi

    if [[ "${#optional_entries[@]}" -eq 0 ]]; then
        log_info "No ${prompt_label} entries available"
        rm -f "${tmp_optional_brewfile}"
        return
    fi

    # Prefer a compact gum picker when interactive.
    if [[ "${installable_count}" -eq 0 ]]; then
        log_info "No ${prompt_label} selected"
    elif command -v gum >/dev/null 2>&1 && [[ -t 0 && -t 1 ]]; then
        for idx in "${!optional_entries[@]}"; do
            if [[ "${optional_installed[${idx}]}" == "1" ]]; then
                continue
            fi

            entry_category="${optional_categories[${idx}]}"
            if [[ -n "${gum_category_name}" ]] && [[ "${entry_category}" != "${gum_category_name}" ]]; then
                append_gum_optional_selection "${gum_category_name}"
                gum_category_entries=()
                gum_category_names=()
            fi

            gum_category_name="${entry_category}"
            gum_category_entries+=("${optional_entries[${idx}]}")
            gum_category_names+=("${optional_names[${idx}]}")
        done

        append_gum_optional_selection "${gum_category_name}"
    else
        for idx in "${!optional_entries[@]}"; do
            if [[ "${optional_installed[${idx}]}" == "1" ]]; then
                continue
            fi
            entry="${optional_entries[${idx}]}"
            display_entry="${optional_names[${idx}]}"
            entry_category="${optional_categories[${idx}]}"
            if [[ "${entry_category}" != "${prompt_last_category}" ]]; then
                log_info "${entry_category}"
                prompt_last_category="${entry_category}"
            fi
            read -r -p "Install ${prompt_label} ${display_entry}? [Y/n] " reply
            if [[ -z "${reply}" || "${reply}" =~ ^[Yy]$ ]]; then
                printf '%s\n' "${entry}" >> "${tmp_optional_brewfile}"
                selected_optional=$((selected_optional + 1))
            fi
        done
    fi

    if [[ "${selected_optional}" -gt 0 ]]; then
        # Tailscale: the cask and formula run separate daemons that conflict.
        # If both were selected, drop the formula — the cask is sufficient.
        if [[ "${OSTYPE}" == darwin* ]] && grep -q '^cask "tailscale-app"' "${tmp_optional_brewfile}" \
                     && grep -q '^brew "tailscale"' "${tmp_optional_brewfile}"; then
            log_info "Removing tailscale formula from selection (conflicts with tailscale-app cask)"
            sed -i '' '/^brew "tailscale"$/d' "${tmp_optional_brewfile}"
            selected_optional=$((selected_optional - 1))
        fi
        local -a opt_names=()
        local opt_line opt_name
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
    elif [[ "${installable_count}" -gt 0 ]]; then
        log_info "No ${prompt_label} selected"
    fi
    rm -f "${tmp_optional_brewfile}"
}

if [[ -f "${OPTIONAL_BREWFILE}" ]]; then
    prompt_optional_brewfile "${OPTIONAL_BREWFILE}" "optional Homebrew package"
fi

# Tailscale: the cask and formula run separate daemons that conflict.
# The selection phase already prevents co-installation, but handle the case
# where the formula was installed in a previous run.
refresh_brew_state
if _brew_has_cask tailscale-app && _brew_has_formula tailscale; then
    log_info "Removing tailscale formula (conflicts with tailscale-app cask)"
    brew services stop tailscale 2>/dev/null || true
    brew uninstall tailscale
fi

ensure_1password_agent_symlink

#!/usr/bin/env bash

set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${BASEDIR}/scripts/common.sh"

require_non_root

case "$OSTYPE" in
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

# Snapshot installed packages once to avoid repeated brew calls.
_installed_formulae=" $(brew list --formula 2>/dev/null | tr '\n' ' ') "
_installed_casks=" $(brew list --cask 2>/dev/null | tr '\n' ' ') "
_installed_taps=" $(brew tap 2>/dev/null | tr '\n' ' ') "

_brew_has_formula() { [[ "${_installed_formulae}" == *" $1 "* ]]; }
_brew_has_cask()    { [[ "${_installed_casks}" == *" $1 "* ]]; }
_brew_has_tap()     { [[ "${_installed_taps}" == *" $1 "* ]]; }

if ! _brew_has_formula fzf; then
    log_info "Installing required dependency: fzf"
    brew install fzf
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

cask_app_available() {
    local pkg_name="$1"
    local app_name
    local search_dir
    local title_name
    local -a app_names=()

    case "${pkg_name}" in
        1password)
            app_names=("1Password.app")
            ;;
        1password-cli)
            command -v op >/dev/null 2>&1
            return $?
            ;;
        appcleaner)
            app_names=("AppCleaner.app")
            ;;
        brave-browser)
            app_names=("Brave Browser.app")
            ;;
        chatgpt)
            app_names=("ChatGPT.app")
            ;;
        claude-code)
            command -v claude >/dev/null 2>&1
            return $?
            ;;
        codex)
            command -v codex >/dev/null 2>&1
            return $?
            ;;
        codex-app)
            app_names=("Codex.app")
            ;;
        docker-desktop)
            app_names=("Docker.app")
            ;;
        github)
            app_names=("GitHub Desktop.app")
            ;;
        google-chrome)
            app_names=("Google Chrome.app")
            ;;
        protonvpn)
            app_names=("Proton VPN.app" "ProtonVPN.app")
            ;;
        tailscale-app)
            app_names=("Tailscale.app")
            ;;
        utm)
            app_names=("UTM.app")
            ;;
        visual-studio-code)
            app_names=("Visual Studio Code.app")
            ;;
        *)
            title_name="$(printf '%s\n' "${pkg_name}" | awk -F- '{
                for (i = 1; i <= NF; i++) {
                    $i = toupper(substr($i, 1, 1)) substr($i, 2)
                }
                OFS = " "
                $1 = $1
                print
            }')"
            app_names=("${title_name}.app")
            ;;
    esac

    for app_name in "${app_names[@]}"; do
        for search_dir in "/Applications" "${HOME}/Applications"; do
            if [[ -d "${search_dir}/${app_name}" ]]; then
                return 0
            fi
        done
    done

    return 1
}

entry_is_already_installed() {
    local pkg_type="$1"
    local pkg_name="$2"

    case "${pkg_type}" in
        brew)
            if _brew_has_formula "${pkg_name}"; then
                return 0
            fi
            if formula_command_available "${pkg_name}"; then
                return 0
            fi
            if linux_system_package_available "${pkg_name}"; then
                return 0
            fi
            ;;
        cask)
            if _brew_has_cask "${pkg_name}"; then
                return 0
            fi
            if [[ "${os_name}" == "Darwin" ]] && cask_app_available "${pkg_name}"; then
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

install_filtered_brewfile() {
    local source_brewfile="$1"
    local prompt_label="$2"
    local tmp_brewfile
    local raw_line
    local line
    local pkg_type
    local pkg_name
    local selected_count=0

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

        if entry_is_already_installed "${pkg_type}" "${pkg_name}"; then
            continue
        fi

        printf '%s "%s"\n' "${pkg_type}" "${pkg_name}" >> "${tmp_brewfile}"
        selected_count=$((selected_count + 1))
    done < "${source_brewfile}"

    if [[ "${selected_count}" -gt 0 ]]; then
        brew bundle install --file="${tmp_brewfile}"
    else
        log_info "All ${prompt_label}s already installed"
    fi

    rm -f "${tmp_brewfile}"
}

log_info "Installing core Homebrew packages"
install_filtered_brewfile "${BREWFILE}" "core Homebrew package"

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
    local last_category=""
    local idx
    local entry
    local reply
    local selected_entries
    local selected_entry
    local selected_kind
    local selected_package_entry
    local display_entry
    local installed_count=0
    local installable_count=0
    local macos_conditional_depth=0
    local palette_theme="${DOTFILES_FZF_THEME:-auto}"
    local bg_code
    local color_reset=$'\033[0m'
    local color_header
    local color_category
    local color_package
    local fzf_palette
    tmp_optional_brewfile="$(mktemp "${TMPDIR:-/tmp}/brewfile-optional.XXXXXX")"

    if [[ "${palette_theme}" == "auto" ]]; then
        if [[ -n "${COLORFGBG:-}" ]]; then
            bg_code="${COLORFGBG##*;}"
            if [[ "${bg_code}" =~ ^[0-9]+$ ]] && [[ "${bg_code}" -le 7 ]]; then
                palette_theme="light"
            else
                palette_theme="dark"
            fi
        elif [[ "${os_name}" == "Darwin" ]] && defaults read -g AppleInterfaceStyle &>/dev/null; then
            palette_theme="dark"
        elif [[ "${os_name}" == "Darwin" ]]; then
            palette_theme="light"
        else
            palette_theme="dark"
        fi
    fi

    if [[ "${palette_theme}" == "light" ]]; then
        color_header=$'\033[1;34m'
        color_category=$'\033[38;2;110;110;110m'
        color_package=$'\033[38;2;0;0;0m'
        fzf_palette='fg:#333333,header:4,info:4,prompt:2,pointer:5,marker:1,fg+:#000000,bg+:#e8e8e8'
    else
        color_header=$'\033[1;36m'
        color_category=$'\033[2;37m'
        color_package=$'\033[1;97m'
        fzf_palette='header:6,info:6,prompt:2,pointer:5,marker:3,fg+:15,bg+:236'
    fi

    while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
        line="${raw_line#"${raw_line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        [[ -z "${line}" ]] && continue
        if [[ "${line}" == \#* ]]; then
            category_text="${line#\# }"
            if [[ "${category_text}" != "Optional dependencies. \`homebrew/brew.sh\` prompts for each entry." ]] && \
                [[ "${category_text}" != "Supported entry types: brew, cask, tap, mas." ]] && \
                [[ "${category_text}" != "macOS-only entries can be wrapped in:" ]] && \
                [[ "${category_text}" != "if OS.mac?" ]] && \
                [[ "${category_text}" != "..." ]] && \
                [[ "${category_text}" != "end" ]]; then
                current_category="${category_text}"
            fi
            continue
        fi
        if [[ "${line}" == "if OS.mac?" || ( "${line}" == "end" && "${macos_conditional_depth}" -gt 0 ) ]]; then
            if [[ "${line}" == "if OS.mac?" ]]; then
                macos_conditional_depth=$((macos_conditional_depth + 1))
            else
                macos_conditional_depth=$((macos_conditional_depth - 1))
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

        entry_category="${current_category}"
        optional_entries+=("${pkg_type} \"${pkg_name}\"")
        optional_categories+=("${entry_category}")
        optional_names+=("${pkg_name}")
        if entry_is_already_installed "${pkg_type}" "${pkg_name}"; then
            optional_installed+=("1")
            installed_count=$((installed_count + 1))
        else
            optional_installed+=("0")
            installable_count=$((installable_count + 1))
        fi
    done < "${optional_brewfile}"

    if [[ "${#optional_entries[@]}" -eq 0 ]]; then
        log_info "No ${prompt_label} entries available"
        rm -f "${tmp_optional_brewfile}"
        return
    fi

    # Use fzf checklist-style selection when available.
    if [[ "${installable_count}" -eq 0 ]]; then
        log_info "No ${prompt_label} selected"
    elif command -v fzf >/dev/null 2>&1 && [[ -t 0 && -t 1 ]]; then
        selected_entries="$(
            {
                last_category=""
                for idx in "${!optional_entries[@]}"; do
                    entry_category="${optional_categories[${idx}]}"
                    entry="${optional_entries[${idx}]}"
                    display_entry="${optional_names[${idx}]}"

                    if [[ "${entry_category}" != "${last_category}" ]]; then
                        if [[ -n "${last_category}" ]]; then
                            printf 'meta\t_spacer\t \t\n'
                        fi
                        printf 'header\t%s\t%s%s%s\t\n' "${entry_category}" "${color_header}" "${entry_category}" "${color_reset}"
                        last_category="${entry_category}"
                    fi

                    if [[ "${optional_installed[${idx}]}" == "1" ]]; then
                        printf 'meta\t%s\t%s✓ %s%s\t%s\t1\n' \
                            "${entry_category}" \
                            "${color_category}" "${display_entry}" "${color_reset}" \
                            "${entry}"
                    else
                        printf 'item\t%s\t  %s%s%s\t%s\t%s\n' \
                            "${entry_category}" \
                            "${color_package}" "${display_entry}" "${color_reset}" \
                            "${entry}" \
                            "${optional_installed[${idx}]}"
                    fi
                done
            } | fzf --multi --marker="* " --pointer=" " \
                --ansi \
                --delimiter=$'\t' \
                --with-nth=3 \
                --layout=reverse \
                --border \
                --bind='space:toggle,tab:ignore,btab:ignore' \
                --color="${fzf_palette}" \
                --prompt="Select ${prompt_label}s > " \
                --header=$'ESC to skip | SPACE to toggle | ENTER to confirm\n \n'
        )" || true

        while IFS= read -r selected_entry || [[ -n "${selected_entry}" ]]; do
            [[ -z "${selected_entry}" ]] && continue
            IFS=$'\t' read -r selected_kind _ _ selected_package_entry _ <<< "${selected_entry}"
            [[ "${selected_kind}" != "item" ]] && continue
            printf '%s\n' "${selected_package_entry}" >> "${tmp_optional_brewfile}"
            selected_optional=$((selected_optional + 1))
        done <<< "${selected_entries}"
    else
        for idx in "${!optional_entries[@]}"; do
            if [[ "${optional_installed[${idx}]}" == "1" ]]; then
                continue
            fi
            entry="${optional_entries[${idx}]}"
            display_entry="${optional_names[${idx}]}"
            entry_category="${optional_categories[${idx}]}"
            if [[ "${entry_category}" != "${last_category}" ]]; then
                log_info "${entry_category}"
                last_category="${entry_category}"
            fi
            read -r -p "Install ${prompt_label} ${display_entry}? [Y/n] " reply
            if [[ -z "${reply}" || "${reply}" =~ ^[Yy]$ ]]; then
                printf '%s\n' "${entry}" >> "${tmp_optional_brewfile}"
                selected_optional=$((selected_optional + 1))
            fi
        done
    fi

    if [[ "${selected_optional}" -gt 0 ]]; then
        log_info "Installing optional Homebrew packages"
        brew bundle install --file="${tmp_optional_brewfile}"
    elif [[ "${installable_count}" -gt 0 ]]; then
        log_info "No ${prompt_label} selected"
    fi
    rm -f "${tmp_optional_brewfile}"
}

if [[ -f "${OPTIONAL_BREWFILE}" ]]; then
    prompt_optional_brewfile "${OPTIONAL_BREWFILE}" "optional Homebrew package"
fi

# Tailscale: the app (cask) and the formula run separate daemons that conflict.
# If the cask is installed, remove the formula to avoid issues.
if brew list --cask 2>/dev/null | grep -qx tailscale-app; then
    if brew list --formula 2>/dev/null | grep -qx tailscale; then
        log_info "Removing tailscale formula (conflicts with tailscale-app)"
        brew services stop tailscale 2>/dev/null || true
        brew uninstall tailscale
    fi
elif brew list --formula 2>/dev/null | grep -qx tailscale; then
    log_info "Starting tailscale service"
    brew services start tailscale 2>/dev/null || true
fi


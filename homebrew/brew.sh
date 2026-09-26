#!/usr/bin/env bash

set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${BASEDIR}/scripts/common.sh"

usage() {
    cat <<'EOF'
Usage: brew.sh [OPTIONS]

Options:
  -v, --verbose   Stream full brew/gum output instead of a spinner
  -d, --debug     Verbose output plus shell command tracing (set -x)
  -h, --help      Show this help message and exit
EOF
}

VERBOSE="${VERBOSE:-0}"
while [[ $# -gt 0 ]]; do
    case "${1}" in
        -v|--verbose)
            VERBOSE=1
            ;;
        -d|--debug)
            VERBOSE=1
            export HOMEBREW_DEBUG=1
            set -x
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown option: ${1}"
            usage
            exit 1
            ;;
    esac
    shift
done
export VERBOSE

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

existing_brew=""
if existing_brew="$(command -v brew 2>/dev/null)" && [[ -x "${existing_brew}" ]]; then
    brewbinpath="$(cd "$(dirname "${existing_brew}")" && pwd)"
    brewsbinpath="$(cd "${brewbinpath}/.." && pwd)/sbin"
fi

export PATH="${brewbinpath}:${brewsbinpath}:${PATH}"

if [[ ! -x "${brewbinpath}/brew" ]]; then
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

join_by() {
    local separator="$1"
    local first="$2"

    shift 2
    printf '%s' "${first}" "${@/#/${separator}}"
    printf '\n'
}

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

optional_entry_is_installed() {
    local pkg_type="$1"
    local pkg_name="$2"

    if [[ "${pkg_type}" == "native" ]]; then
        native_entry_is_installed "${pkg_name}"
        return
    fi

    if entry_is_brew_managed "${pkg_type}" "${pkg_name}"; then
        return 0
    fi

    return 1
}

# Optional apps installed with the vendor's own installer instead of Homebrew,
# offered in the same picker as Brewfile.macos. Each maps to a script under
# scripts/bootstrap/macos/.
declare -a NATIVE_OPTIONAL_ENTRIES=(
    "claude-code"
)

native_entry_is_installed() {
    local pkg_name="$1"

    case "${pkg_name}" in
        claude-code)
            [[ -x "${HOME}/.local/bin/claude" ]]
            ;;
        *)
            return 1
            ;;
    esac
}

run_native_install() {
    local pkg_name="$1"
    local script="${BASEDIR}/scripts/bootstrap/macos/${pkg_name}.sh"

    chmod +x "${script}"
    "${script}"
}

# Homebrew casks that provide the same tool as a native entry. When one is
# installed, the native installer would only add a second copy.
native_entry_brew_casks() {
    case "$1" in
        claude-code)
            printf '%s\n' claude-code claude-code@latest
            ;;
    esac
}

native_entry_is_brew_managed() {
    local cask

    while IFS= read -r cask; do
        [[ -n "${cask}" ]] && _brew_has_cask "${cask}" && return 0
    done < <(native_entry_brew_casks "$1")

    return 1
}

native_entry_command() {
    case "$1" in
        claude-code)
            printf 'claude\n'
            ;;
    esac
}

# Print "token<TAB>App.app[<TAB>...]" for each cask, naming the app bundles it
# installs. Casks that ship a pkg instead fall back to "<name>.app". Prints
# nothing when jq or the cask metadata is unavailable, which only disables the
# "installed outside Homebrew" hints.
cask_app_bundles() {
    command -v jq >/dev/null 2>&1 || return 0

    brew info --cask --json=v2 "$@" 2>/dev/null | jq -r '
        .casks[]
        | [.artifacts[]? | objects | .app? // empty
            | ((map(objects | .target) | first) // first)
            | strings | split("/") | last] as $apps
        | [.token] + (if ($apps | length) > 0 then $apps else [.name[]? | . + ".app"] end)
        | join("\t")
    ' 2>/dev/null || true
}

# Print where an entry that Homebrew does not manage is already installed, if
# anywhere: an app bundle for casks, or a command on PATH outside Homebrew.
# BREW_APP_DIRS (colon-separated) overrides the app folders so tests can
# isolate them.
optional_entry_external_path() {
    local pkg_type="$1"
    local pkg_name="$2"
    local app_bundles="$3"
    local short_name
    local line
    local app
    local dir
    local cmd=""
    local cmd_path=""
    local -a apps=()
    local -a app_dirs=()

    IFS=: read -r -a app_dirs <<< "${BREW_APP_DIRS:-/Applications:${HOME}/Applications}"

    case "${pkg_type}" in
        cask)
            short_name="$(brew_entry_short_name "${pkg_name}")"
            while IFS= read -r line; do
                [[ "${line}" == "${short_name}"$'\t'* ]] || continue
                IFS=$'\t' read -r -a apps <<< "${line#*$'\t'}"
                [[ "${#apps[@]}" -gt 0 ]] || continue
                for app in "${apps[@]}"; do
                    for dir in "${app_dirs[@]}"; do
                        if [[ -e "${dir}/${app}" ]]; then
                            printf '%s\n' "${dir}/${app}"
                            return 0
                        fi
                    done
                done
            done <<< "${app_bundles}"
            ;;
        brew)
            cmd="$(brew_entry_short_name "${pkg_name}")"
            ;;
        native)
            cmd="$(native_entry_command "${pkg_name}")"
            ;;
    esac

    [[ -n "${cmd}" ]] || return 0
    cmd_path="$(command -v "${cmd}" 2>/dev/null || true)"
    if [[ "${cmd_path}" == /* && "${cmd_path}" != "${brew_prefix}/"* ]]; then
        printf '%s\n' "${cmd_path}"
    fi
}

has_interactive_tty() {
    # The optional-package picker reads and writes the terminal device directly
    # (see the gum/read branches below), so a piped or redirected stdin/stdout is
    # fine — what matters is whether a controlling terminal can actually be
    # opened. Opening /dev/tty fails with ENXIO when there is no controlling
    # terminal (cron, CI, nohup), which is exactly when we must skip. The device
    # path is overridable so tests can force either outcome deterministically.
    local tty_device="${BREW_TTY_DEVICE:-/dev/tty}"

    ( : < "${tty_device}" ) 2>/dev/null || return 1
    ( : > "${tty_device}" ) 2>/dev/null || return 1

    return 0
}

optional_prompt_mode() {
    if ! has_interactive_tty; then
        printf 'skip\n'
        return
    fi

    if command -v gum >/dev/null 2>&1; then
        printf 'gum\n'
    else
        printf 'read\n'
    fi
}

is_font_cask() {
    local pkg_name="$1"

    [[ "$(brew_entry_short_name "${pkg_name}")" == font-* ]]
}

font_cask_fonts_dir() {
    if [[ "${os_name}" == "Darwin" ]]; then
        printf '%s\n' "${HOME}/Library/Fonts"
        return 0
    fi

    printf '%s\n' "${HOME}/.local/share/fonts"
}

font_cask_font_basenames() {
    local cask="$1"
    local short_name=""
    local ruby_bin=""

    short_name="$(brew_entry_short_name "${cask}")"
    ruby_bin="$(command -v ruby 2>/dev/null || true)"
    [[ -n "${ruby_bin}" ]] || return 1

    brew info --cask --json=v2 "${short_name}" 2>/dev/null | "${ruby_bin}" -rjson -e '
      data = JSON.parse(STDIN.read)
      data[0]["artifacts"].each do |artifact|
        next unless artifact["font"]

        artifact["font"].each { |path| puts File.basename(path) }
      end
    ' 2>/dev/null
}

remove_conflicting_font_cask_files() {
    local cask="$1"
    local fonts_dir=""
    local font_basename=""

    fonts_dir="$(font_cask_fonts_dir)"
    [[ -d "${fonts_dir}" ]] || return 0

    while IFS= read -r font_basename; do
        [[ -n "${font_basename}" ]] || continue
        [[ -e "${fonts_dir}/${font_basename}" ]] || continue
        log_warn "Removing conflicting font ${fonts_dir}/${font_basename} before installing ${cask}"
        rm -f "${fonts_dir}/${font_basename}"
    done < <(font_cask_font_basenames "${cask}")
}

prepare_font_casks_for_install() {
    local pkg_name=""

    for pkg_name in "$@"; do
        [[ -n "${pkg_name}" ]] || continue
        is_font_cask "${pkg_name}" || continue

        if entry_is_brew_managed cask "${pkg_name}"; then
            continue
        fi

        # Drop any broken cask registration so brew bundle can reinstall cleanly.
        brew uninstall --cask --force "$(brew_entry_short_name "${pkg_name}")" 2>/dev/null || true
        remove_conflicting_font_cask_files "${pkg_name}"
    done
}

prepare_font_casks_from_brewfile() {
    local brewfile="$1"
    local -a font_casks=()
    local line=""
    local pkg_name=""

    [[ -f "${brewfile}" ]] || return 0

    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ "${line}" =~ ^cask[[:space:]]+\"([^\"]+)\" ]] || continue
        pkg_name="${BASH_REMATCH[1]}"
        is_font_cask "${pkg_name}" && font_casks+=("${pkg_name}")
    done < "${brewfile}"

    if [[ "${#font_casks[@]}" -gt 0 ]]; then
        prepare_font_casks_for_install "${font_casks[@]}"
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
        prepare_font_casks_from_brewfile "${tmp_brewfile}"
        trust_tapped_brewfile_entries "${tmp_brewfile}"
        local -a bundle_cmd=(brew bundle install --file="${tmp_brewfile}")
        [[ "${VERBOSE:-0}" -eq 1 ]] && bundle_cmd+=(--verbose)
        spin "Installing ${prompt_label}s..." "${bundle_cmd[@]}"
        refresh_brew_state
    else
        log_info "All ${prompt_label}s already installed"
    fi

    rm -f "${tmp_brewfile}"
}

# Homebrew 7 refuses to load formulae and casks from untrusted third-party taps,
# so a tap-qualified Brewfile line would be skipped rather than installed. Trust
# each entry individually instead of the whole tap, which would also cover every
# future formula that tap ships. Failures are non-fatal: older Homebrew has no
# `trust` subcommand, and bundle should still get its chance to run.
brew_supports_trust() {
    brew trust --help >/dev/null 2>&1
}

trust_tapped_brewfile_entries() {
    local brewfile="$1"
    local pkg_type pkg_name flag

    [[ -f "${brewfile}" ]] || return 0
    brew_supports_trust || return 0

    while read -r pkg_type pkg_name; do
        case "${pkg_type}" in
            cask) flag="--cask" ;;
            brew) flag="--formula" ;;
            *) continue ;;
        esac

        if ! brew trust "${flag}" "${pkg_name}" >/dev/null 2>&1; then
            log_warn "Could not trust ${pkg_name}; brew may skip it"
        fi
    done < <(sed -nE 's/^[[:space:]]*(brew|cask)[[:space:]]+"([^"]*\/[^"]*)".*/\1 \2/p' "${brewfile}")
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
    local selected_brew=0
    local -a selected_native=()
    local -a optional_entries=()
    local -a optional_names=()
    local -a optional_labels=()
    local -a pending_casks=()
    local -a brew_installed=()
    local -a native_installed=()
    local app_bundles=""
    local external_path
    local name_width=0
    local tty_device="${BREW_TTY_DEVICE:-/dev/tty}"
    local raw_line
    local line
    local pkg_type
    local pkg_name
    local idx
    local reply
    local display_entry
    local pending_count=0
    local selected_name
    local prompt_mode=""
    tmp_optional_brewfile="$(mktemp "${TMPDIR:-/tmp}/brewfile-optional.XXXXXX")"
    log_info "Checking already installed optional packages..."

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
            brew_installed+=("${pkg_name}")
            continue
        fi

        optional_entries+=("${pkg_type} \"${pkg_name}\"")
        optional_names+=("${pkg_name}")
        [[ "${pkg_type}" == "cask" ]] && pending_casks+=("${pkg_name}")
        pending_count=$((pending_count + 1))
    done < "${optional_brewfile}"

    for pkg_name in "${NATIVE_OPTIONAL_ENTRIES[@]}"; do
        if optional_entry_is_installed native "${pkg_name}"; then
            native_installed+=("${pkg_name}")
            continue
        fi
        if native_entry_is_brew_managed "${pkg_name}"; then
            brew_installed+=("${pkg_name}")
            continue
        fi
        optional_entries+=("native \"${pkg_name}\"")
        optional_names+=("${pkg_name}")
        pending_count=$((pending_count + 1))
    done

    # Guarded: bash 3.2 treats an empty array expansion as unbound under set -u.
    if [[ "${#brew_installed[@]}" -gt 0 ]]; then
        log_info "Already installed via Homebrew: $(join_by ', ' "${brew_installed[@]}")"
    fi
    if [[ "${#native_installed[@]}" -gt 0 ]]; then
        log_info "Already installed with the vendor installer: $(join_by ', ' "${native_installed[@]}")"
    fi

    if [[ "${pending_count}" -eq 0 ]]; then
        log_info "All ${prompt_label}s already installed"
        rm -f "${tmp_optional_brewfile}"
        return
    fi

    if [[ "${#pending_casks[@]}" -gt 0 ]]; then
        app_bundles="$(cask_app_bundles "${pending_casks[@]}")"
    fi

    for pkg_name in "${optional_names[@]}"; do
        [[ "${#pkg_name}" -gt "${name_width}" ]] && name_width="${#pkg_name}"
    done

    # Entries Homebrew does not manage may still be installed another way (a
    # vendor download or the App Store); label them so the picker shows it.
    for idx in "${!optional_entries[@]}"; do
        external_path="$(optional_entry_external_path \
            "${optional_entries[${idx}]%% *}" "${optional_names[${idx}]}" "${app_bundles}")"
        if [[ -n "${external_path}" ]]; then
            optional_labels+=("$(printf '%-*s  installed outside Homebrew: %s' \
                "${name_width}" "${optional_names[${idx}]}" "${external_path}")")
        else
            optional_labels+=("${optional_names[${idx}]}")
        fi
    done

    # Native entries run their installer script; everything else goes to brew bundle.
    select_optional_entry() {
        local idx="$1"

        if [[ "${optional_entries[${idx}]}" == native\ * ]]; then
            selected_native+=("${optional_names[${idx}]}")
        else
            printf '%s\n' "${optional_entries[${idx}]}" >> "${tmp_optional_brewfile}"
            selected_brew=$((selected_brew + 1))
        fi
        selected_optional=$((selected_optional + 1))
    }

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

            # gum shows each label and prints the matching name for selections.
            local -a gum_options=()
            for idx in "${!optional_names[@]}"; do
                gum_options+=("${optional_labels[${idx}]}"$'\t'"${optional_names[${idx}]}")
            done

            # shellcheck disable=SC2094 # gum reads keys from and draws on the terminal.
            gum_choose_multiselect \
                "Select optional packages to install" \
                "${height}" \
                --label-delimiter=$'\t' \
                "${gum_options[@]}" \
                < "${tty_device}" \
                > "${tmp_gum_output}" \
                2> "${tty_device}" || true

            while IFS= read -r selected_name || [[ -n "${selected_name}" ]]; do
                [[ -z "${selected_name}" ]] && continue
                for idx in "${!optional_names[@]}"; do
                    if [[ "${optional_names[${idx}]}" == "${selected_name}" ]]; then
                        select_optional_entry "${idx}"
                        break
                    fi
                done
            done < "${tmp_gum_output}"
            rm -f "${tmp_gum_output}"
            ;;
        read)
            log_info "Optional Homebrew packages available. Press Enter to install a package, or n to skip."

            for idx in "${!optional_entries[@]}"; do
                display_entry="${optional_labels[${idx}]}"
                printf "Install %s %s? [Y/n] " "${prompt_label}" "${display_entry}" > "${tty_device}"
                read -r reply < "${tty_device}" || reply="n"
                if [[ -z "${reply}" || "${reply}" =~ ^[Yy]$ ]]; then
                    select_optional_entry "${idx}"
                fi
            done
            ;;
    esac

    if [[ "${selected_optional}" -gt 0 ]]; then
        if [[ "${selected_brew}" -gt 0 ]]; then
            prepare_font_casks_from_brewfile "${tmp_optional_brewfile}"
            trust_tapped_brewfile_entries "${tmp_optional_brewfile}"
            local -a bundle_cmd=(brew bundle install --file="${tmp_optional_brewfile}")
            [[ "${VERBOSE:-0}" -eq 1 ]] && bundle_cmd+=(--verbose)
            spin "Installing ${prompt_label}s..." "${bundle_cmd[@]}"
            refresh_brew_state
        fi
        # Guarded: bash 3.2 treats an empty array expansion as unbound under set -u.
        if [[ "${#selected_native[@]}" -gt 0 ]]; then
            for pkg_name in "${selected_native[@]}"; do
                run_native_install "${pkg_name}"
            done
        fi
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

declare -a cleanup_cmd=(brew cleanup --prune=all)
[[ "${VERBOSE:-0}" -eq 1 ]] && cleanup_cmd+=(--verbose)
spin "Cleaning up Homebrew..." "${cleanup_cmd[@]}"
log_info "Removing Homebrew cache"
rm -rf "$(brew --cache)"

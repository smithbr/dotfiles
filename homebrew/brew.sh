#!/usr/bin/env bash
# Install Homebrew if needed, then the persona's Brewfiles: those in
# DOTFILES_BREWFILES in full, and on macOS a picker over the entries of
# DOTFILES_BREW_OPTIONAL not yet installed. install.sh sets both from the
# persona and asks the picker's question itself up front (--pending lists the
# entries, DOTFILES_BREW_PICKS answers it); run on its own this installs core
# and offers macos. Brewfiles are plain `brew bundle` files: an entry that only
# applies to macOS says so with `if OS.mac?`. It also writes Homebrew's global
# npmrc so npm never caches in ~/.npm. Nothing is upgraded here; os-doctor
# does that.

set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common.sh
source "${BASEDIR}/scripts/common.sh"

usage() {
    cat <<'USAGE'
Usage: brew.sh [OPTIONS]

Options:
  -n, --dry-run   Report what would be installed without installing anything
      --pending   Print the optional entries not yet installed, one
                  NAME<TAB>LINE per line (every entry when Homebrew is missing)
  -v, --verbose   Stream full brew output instead of a spinner
  -h, --help      Show this help message and exit
USAGE
}

DRY_RUN=0

# Homebrew's bin directory on this machine, to look in before it is on PATH.
brew_bin_dir() {
    case "${OSTYPE}" in
        darwin*)
            case "$(uname -m)" in
                arm64) printf '/opt/homebrew/bin\n' ;;
                *) printf '/usr/local/bin\n' ;;
            esac
            ;;
        linux*) printf '/home/linuxbrew/.linuxbrew/bin\n' ;;
        *)
            log_error "Unsupported OS: ${OSTYPE}"
            return 1
            ;;
    esac
}

# Put Homebrew on PATH when it is installed but not there yet.
find_brew() {
    local bin_dir
    command -v brew >/dev/null 2>&1 && return 0
    bin_dir="$(brew_bin_dir)" || exit 1
    export PATH="${bin_dir}:${bin_dir%/bin}/sbin:${PATH}"
    command -v brew >/dev/null 2>&1
}

ensure_brew() {
    local prefix
    if ! find_brew; then
        if [[ "${DRY_RUN}" -eq 1 ]]; then
            log_info "Would install Homebrew"
            return 1
        fi
        printf '\n\nInstalling Homebrew...\n\n'
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
    prefix="$(brew --prefix)"
    export PATH="${prefix}/bin:${prefix}/sbin:${PATH}"
}

# Homebrew 7 refuses formulae and casks from untrusted third-party taps, so
# each tap-qualified entry is trusted on its own before bundle runs (trusting
# the whole tap would cover everything it ships later). Never fatal.
trust_tapped_entries() {
    local brewfile="$1" kind name flag
    brew trust --help >/dev/null 2>&1 || return 0
    while read -r kind name; do
        flag=--formula
        [[ "${kind}" != cask ]] || flag=--cask
        brew trust "${flag}" "${name}" >/dev/null 2>&1 || log_warn "Could not trust ${name}; brew may skip it"
    done < <(sed -nE 's/^[[:space:]]*(brew|cask)[[:space:]]+"([^"]*\/[^"]*)".*/\1 \2/p' "${brewfile}")
}

bundle_install() {
    local brewfile="$1" label="$2"
    local -a cmd=(brew bundle install --no-upgrade --file="${brewfile}")
    [[ "${VERBOSE}" -eq 0 ]] || cmd+=(--verbose)
    trust_tapped_entries "${brewfile}"
    spin "Installing ${label}..." "${cmd[@]}"
}

# A Brewfile the persona installs in full; bundle skips what is there.
install_brewfile() {
    local name="$1" brewfile="${BASEDIR}/homebrew/Brewfile.$1"
    if [[ ! -f "${brewfile}" ]]; then
        log_error "No homebrew/Brewfile.${name}; check the persona's brew setting"
        exit 1
    fi
    if brew bundle check --no-upgrade --file="${brewfile}" >/dev/null 2>&1; then
        log_info "All ${name} Homebrew packages already installed"
        return 0
    fi
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        log_info "Would install from Brewfile.${name}: $(pending_entries "${brewfile}" | cut -f1 | tr '\n' ' ')"
        return 0
    fi
    bundle_install "${brewfile}" "${name} Homebrew packages"
}

# The brew and cask lines of a Brewfile whose package is not installed, as
# name<TAB>line (a tap-qualified cask is installed under its short name).
# Without Homebrew every entry is pending.
pending_entries() {
    local brewfile="$1" line name installed=""
    if command -v brew >/dev/null 2>&1; then
        installed=" $(brew list --formula 2>/dev/null | tr '\n' ' ') $(brew list --cask 2>/dev/null | tr '\n' ' ') "
    fi
    while IFS= read -r line; do
        [[ "${line}" =~ ^[[:space:]]*(brew|cask)[[:space:]]+\"([^\"]+)\" ]] || continue
        name="${BASH_REMATCH[2]}"
        [[ "${installed}" == *" ${name} "* || "${installed}" == *" ${name##*/} "* ]] && continue
        printf '%s\t%s\n' "${name}" "${line}"
    done < "${brewfile}"
}

# macOS only: the entries of an optional Brewfile not yet installed, chosen on
# a terminal (closed stdin chooses none), bundled from a temporary Brewfile.
# When DOTFILES_BREW_PICKS is set (install.sh asked already), its lines are
# the choice and nothing is asked here.
offer_brewfile() {
    local name="$1" brewfile="${BASEDIR}/homebrew/Brewfile.$1" entry tmp count=0
    local -a pending=()
    [[ -f "${brewfile}" ]] || return 0
    while IFS= read -r entry; do
        pending+=("${entry}")
    done < <(pending_entries "${brewfile}")
    if [[ "${#pending[@]}" -eq 0 ]]; then
        log_info "All ${name} Homebrew packages already installed"
        return 0
    fi
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        log_info "Would offer from Brewfile.${name}: $(printf '%s\n' "${pending[@]}" | cut -f1 | tr '\n' ' ')"
        return 0
    fi
    tmp="$(mktemp "${TMPDIR:-/tmp}/Brewfile.${name}.XXXXXX")"
    while IFS= read -r entry; do
        [[ -z "${entry}" ]] || { printf '%s\n' "${entry}" >> "${tmp}"; count=$((count + 1)); }
    done < <(chosen_entries "${name}" "${pending[@]}" || true)
    if [[ "${count}" -eq 0 ]]; then
        log_info "No ${name} Homebrew packages selected"
    else
        bundle_install "${tmp}" "${count} optional Homebrew package(s)"
    fi
    rm -f "${tmp}"
}

# The lines of the pending entries to install: those of DOTFILES_BREW_PICKS
# when it is set, else the picker's answer.
chosen_entries() {
    local name="$1" entry
    shift
    if [[ -n "${DOTFILES_BREW_PICKS+x}" ]]; then
        for entry in "$@"; do
            grep -qxF "${entry#*$'\t'}" <<< "${DOTFILES_BREW_PICKS}" && printf '%s\n' "${entry#*$'\t'}"
        done
        return 0
    fi
    choose_many "Optional Homebrew packages (${name})" "$@"
}

# npm started outside a shell (Claude's MCP servers through npx, GUI apps)
# never sees .zshenv's NPM_CONFIG_CACHE and caches in ~/.npm. Homebrew's npm
# reads its global npmrc whatever started it, so that file points the cache at
# the same place; the shell's variable still wins where it is set. A global
# npmrc the repo did not write is left alone.
NPMRC_MARKER="# Managed by dotfiles homebrew/brew.sh"

write_global_npmrc() {
    local npmrc wanted
    npmrc="$(brew --prefix)/etc/npmrc"
    wanted="${NPMRC_MARKER}"$'\n''cache=~/.cache/npm'
    if [[ -f "${npmrc}" ]]; then
        [[ "$(cat "${npmrc}")" != "${wanted}" ]] || return 0
        if [[ "$(head -n 1 "${npmrc}")" != "${NPMRC_MARKER}" ]]; then
            log_warn "Leaving ${npmrc} alone (not written by the dotfiles); add cache=~/.cache/npm to keep npm out of ~/.npm"
            return 0
        fi
    fi
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        log_info "Would write ${npmrc} to keep npm's cache in ~/.cache/npm"
        return 0
    fi
    mkdir -p "${npmrc%/*}"
    printf '%s\n' "${wanted}" > "${npmrc}"
    log_info "Wrote ${npmrc}: npm caches in ~/.cache/npm"
}

# --pending: every optional entry not yet installed, for install.sh's question.
print_pending() {
    local name brewfile
    find_brew || true
    for name in ${DOTFILES_BREW_OPTIONAL-macos}; do
        brewfile="${BASEDIR}/homebrew/Brewfile.${name}"
        [[ -f "${brewfile}" ]] && pending_entries "${brewfile}"
    done
    return 0
}

main() {
    local name
    local -a cleanup=(brew cleanup --prune=all)

    VERBOSE="${VERBOSE:-0}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--dry-run) DRY_RUN=1 ;;
            --pending) print_pending; exit 0 ;;
            -v|--verbose) VERBOSE=1 ;;
            -h|--help) usage; exit 0 ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
        shift
    done
    export VERBOSE

    require_non_root
    if ! ensure_brew; then
        # A dry run without Homebrew: every entry would be installed.
        log_info "Would install from Brewfiles: ${DOTFILES_BREWFILES-core}"
        return 0
    fi
    for name in ${DOTFILES_BREWFILES-core}; do
        install_brewfile "${name}"
    done
    if [[ "${OSTYPE}" == darwin* ]]; then
        for name in ${DOTFILES_BREW_OPTIONAL-macos}; do
            offer_brewfile "${name}"
        done
    fi
    write_global_npmrc
    [[ "${DRY_RUN}" -eq 0 ]] || return 0
    [[ "${VERBOSE}" -eq 0 ]] || cleanup+=(--verbose)
    spin "Cleaning up Homebrew..." "${cleanup[@]}"
}

[[ "${BASH_SOURCE[0]}" != "$0" ]] || main "$@"

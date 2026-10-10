#!/usr/bin/env bash
# Install Homebrew if needed, then the persona's Brewfiles: those in
# DOTFILES_BREWFILES in full, and on macOS a picker over the entries of
# DOTFILES_BREW_OPTIONAL not yet installed. install.sh sets both from the
# persona; run on its own this installs core and offers macos. Brewfiles are
# plain `brew bundle` files: an entry that only applies to macOS says so with
# `if OS.mac?`. Nothing is upgraded here; os-update does that.

set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common.sh
source "${BASEDIR}/scripts/common.sh"

usage() {
    cat <<'USAGE'
Usage: brew.sh [OPTIONS]

Options:
  -v, --verbose   Stream full brew output instead of a spinner
  -h, --help      Show this help message and exit
USAGE
}

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

ensure_brew() {
    local bin_dir prefix
    if ! command -v brew >/dev/null 2>&1; then
        bin_dir="$(brew_bin_dir)" || exit 1
        export PATH="${bin_dir}:${bin_dir%/bin}/sbin:${PATH}"
        if ! command -v brew >/dev/null 2>&1; then
            printf '\n\nInstalling Homebrew...\n\n'
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        fi
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
    bundle_install "${brewfile}" "${name} Homebrew packages"
}

# The brew and cask lines of a Brewfile whose package is not installed, as
# name<TAB>line (a tap-qualified cask is installed under its short name).
pending_entries() {
    local brewfile="$1" line name installed
    installed=" $(brew list --formula 2>/dev/null | tr '\n' ' ') $(brew list --cask 2>/dev/null | tr '\n' ' ') "
    while IFS= read -r line; do
        [[ "${line}" =~ ^[[:space:]]*(brew|cask)[[:space:]]+\"([^\"]+)\" ]] || continue
        name="${BASH_REMATCH[2]}"
        [[ "${installed}" == *" ${name} "* || "${installed}" == *" ${name##*/} "* ]] && continue
        printf '%s\t%s\n' "${name}" "${line}"
    done < "${brewfile}"
}

# macOS only: the entries of an optional Brewfile not yet installed, chosen on
# a terminal (closed stdin chooses none), bundled from a temporary Brewfile.
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
    tmp="$(mktemp "${TMPDIR:-/tmp}/Brewfile.${name}.XXXXXX")"
    while IFS= read -r entry; do
        [[ -z "${entry}" ]] || { printf '%s\n' "${entry}" >> "${tmp}"; count=$((count + 1)); }
    done < <(choose_many "Optional Homebrew packages (${name})" "${pending[@]}" || true)
    if [[ "${count}" -eq 0 ]]; then
        log_info "No ${name} Homebrew packages selected"
    else
        bundle_install "${tmp}" "${count} optional Homebrew package(s)"
    fi
    rm -f "${tmp}"
}

main() {
    local name
    local -a cleanup=(brew cleanup --prune=all)

    VERBOSE="${VERBOSE:-0}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
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
    ensure_brew
    for name in ${DOTFILES_BREWFILES-core}; do
        install_brewfile "${name}"
    done
    if [[ "${OSTYPE}" == darwin* ]]; then
        for name in ${DOTFILES_BREW_OPTIONAL-macos}; do
            offer_brewfile "${name}"
        done
    fi
    [[ "${VERBOSE}" -eq 0 ]] || cleanup+=(--verbose)
    spin "Cleaning up Homebrew..." "${cleanup[@]}"
}

[[ "${BASH_SOURCE[0]}" != "$0" ]] || main "$@"

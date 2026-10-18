#!/usr/bin/env bash
# Start from nothing: put this repo on a machine and run its install.sh.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/smithbr/dotfiles/main/bootstrap.sh) [--user NAME] [INSTALL_ARGS...]
#
# Installs git, clones to ~/.dotfiles (DOTFILES_REPO overrides the URL), runs
# install.sh with the remaining arguments. As root, --user NAME first creates
# and hardens that admin user (harden.sh; HARDEN_ARGS adds its options).
# Self-contained and safe to rerun.

set -euo pipefail

REPO_URL="${DOTFILES_REPO:-https://github.com/smithbr/dotfiles.git}"
ADMIN_USER=""

log_info() { printf 'INFO %s\n' "$*"; }
log_error() { printf 'ERROR %s\n' "$*" >&2; }

usage() {
    cat <<'USAGE'
Usage: bootstrap.sh [--user NAME] [INSTALL_ARGS...]

  --user NAME   as root: the admin user to create (through harden.sh, with
                HARDEN_ARGS) and continue as
  -h, --help    show this help

Everything else goes to install.sh, e.g. --persona vps --no-install docker.
USAGE
}

if [[ "${1:-}" == --user ]]; then
    [[ -n "${2:-}" ]] || { log_error "--user needs a name"; exit 2; }
    ADMIN_USER="$2"
    shift 2
fi
[[ "${1:-}" != -h && "${1:-}" != --help ]] || { usage; exit 0; }

as_root() {
    if [[ "${EUID}" -eq 0 ]]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        log_error "sudo is required for: $*"
        exit 1
    fi
}

ensure_git() {
    command -v git >/dev/null 2>&1 && return 0
    case "${OSTYPE}" in
        linux*)
            log_info "Installing git"
            as_root apt-get update -qq
            as_root apt-get install -y -qq git
            ;;
        darwin*)
            log_info "Installing the Xcode Command Line Tools for git; finish the installer window"
            xcode-select --install
            until xcode-select -p >/dev/null 2>&1; do sleep 10; done
            ;;
        *)
            log_error "No way to install git on ${OSTYPE}"
            exit 1
            ;;
    esac
}

# The home of the user the install runs as.
install_home() {
    if [[ -n "${ADMIN_USER}" ]]; then
        getent passwd "${ADMIN_USER}" | cut -d: -f6
    else
        printf '%s\n' "${HOME}"
    fi
}

ensure_git

if [[ "${EUID}" -eq 0 ]]; then
    [[ "${OSTYPE}" == linux* ]] || { log_error "Run this as your own user, not root"; exit 1; }
    [[ -n "${ADMIN_USER}" ]] || { log_error "Running as root: name the admin user with --user NAME"; exit 2; }
    if ! id "${ADMIN_USER}" >/dev/null 2>&1 || [[ ! -f /etc/ssh/sshd_config.d/00-harden.conf ]]; then
        log_info "Creating and hardening for ${ADMIN_USER}"
        # shellcheck disable=SC2086 # HARDEN_ARGS is a list of options
        bash <(curl -fsSL "${REPO_URL%.git}/raw/main/scripts/bootstrap/linux/harden.sh") --user "${ADMIN_USER}" ${HARDEN_ARGS:-}
    fi
fi

target="$(install_home)/.dotfiles"
if [[ -d "${target}/.git" ]]; then
    log_info "Dotfiles already at ${target}"
elif [[ -n "${ADMIN_USER}" ]]; then
    as_root -u "${ADMIN_USER}" -H git clone --quiet "${REPO_URL}" "${target}"
else
    git clone --quiet "${REPO_URL}" "${target}"
fi

# Piped through bash, stdin is this script; give install.sh the terminal.
if ( : < /dev/tty ) 2>/dev/null; then
    exec < /dev/tty
fi
if [[ -n "${ADMIN_USER}" ]]; then
    exec sudo -u "${ADMIN_USER}" -H bash "${target}/install.sh" "$@"
fi
exec bash "${target}/install.sh" "$@"

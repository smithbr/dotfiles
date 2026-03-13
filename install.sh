#!/usr/bin/env bash

set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "${BASEDIR}/scripts/common.sh"

require_non_root

if [[ -z "${HOME:-}" ]]; then
    log_error "Seems you're \$HOMEless :("
    exit 1
fi

CHEZMOI_SOURCE="${BASEDIR}/dotfiles"
CHEZMOI_DEFAULT_SOURCE="${HOME}/.dotfiles/dotfiles"
CHEZMOI_CONFIG_DIR="${HOME}/.config/chezmoi"
CHEZMOI_CONFIG_FILE="${CHEZMOI_CONFIG_DIR}/chezmoi.json"
LOCAL_INSTALL_SSH_KEY_PATH="${HOME}/.ssh/id_rsa"

ssh_key_comment() {
    printf '%s@%s\n' "${USER:-$(id -un)}" "$(hostname -s 2>/dev/null || hostname)"
}

ensure_local_install_ssh_key() {
    local key_comment=""

    mkdir -p "${HOME}/.ssh"
    chmod 700 "${HOME}/.ssh"

    if [[ -f "${LOCAL_INSTALL_SSH_KEY_PATH}" ]]; then
        if [[ ! -f "${LOCAL_INSTALL_SSH_KEY_PATH}.pub" ]]; then
            log_info "Restoring missing public key for ${LOCAL_INSTALL_SSH_KEY_PATH}"
            ssh-keygen -y -f "${LOCAL_INSTALL_SSH_KEY_PATH}" > "${LOCAL_INSTALL_SSH_KEY_PATH}.pub"
            chmod 644 "${LOCAL_INSTALL_SSH_KEY_PATH}.pub"
        fi
        return 0
    fi

    key_comment="$(ssh_key_comment)"
    log_info "Creating local SSH key at ${LOCAL_INSTALL_SSH_KEY_PATH}"
    ssh-keygen -q -t rsa -b 4096 -N "" -C "${key_comment}" -f "${LOCAL_INSTALL_SSH_KEY_PATH}"
    chmod 600 "${LOCAL_INSTALL_SSH_KEY_PATH}"
    chmod 644 "${LOCAL_INSTALL_SSH_KEY_PATH}.pub"
}

copy_and_list_local_example_files() {
    local example_path
    local target_path
    local local_path
    local -a local_paths=()

    while IFS= read -r -d '' example_path; do
        target_path="$(chezmoi target-path --source "${CHEZMOI_SOURCE}" "${example_path}")"
        local_path="${target_path%.example}"

        if [[ ! -e "${local_path}" && ! -L "${local_path}" ]]; then
            cp "${target_path}" "${local_path}"
            log_info "Created local config from example: ${local_path}"
        fi

        local_paths+=("${local_path}")
    done < <(find "${CHEZMOI_SOURCE}" -type f -name '*.local.example' -print0)

    if [[ "${#local_paths[@]}" -gt 0 ]]; then
        printf "\nReview these local config files if you still need to personalize this machine:\n"
        for local_path in "${local_paths[@]}"; do
            printf "  - %s\n" "${local_path/#"${HOME}"/\~}"
        done
    fi
}

cd "${BASEDIR}"

run_system_bootstrap=1
run_brew=1
declare -a chezmoi_args=()
while [[ $# -gt 0 ]]; do
    case "${1}" in
        --skip-system)
            run_system_bootstrap=0
            ;;
        --skip-brew)
            run_brew=0
            ;;
        *)
            chezmoi_args+=("$1")
            ;;
    esac
    shift
done

if ! command -v chezmoi >/dev/null 2>&1; then
    log_info "Installing chezmoi"
    if command -v brew >/dev/null 2>&1; then
        brew install chezmoi
    else
        bin_dir="${HOME}/.local/bin"
        mkdir -p "${bin_dir}"
        sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "${bin_dir}"
        export PATH="${bin_dir}:${PATH}"
    fi
fi

log_info "Linking dotfiles repo to ${HOME}/.dotfiles"
ln -sfn "${BASEDIR}" "${HOME}/.dotfiles"

ensure_local_install_ssh_key

# Remove invalid config so chezmoi apply can regenerate it from the template
if [[ -f "${CHEZMOI_CONFIG_FILE}" ]] && ! chezmoi --source "${CHEZMOI_SOURCE}" dump-config &>/dev/null; then
    log_warn "Removing invalid ${CHEZMOI_CONFIG_FILE}"
    rm -f "${CHEZMOI_CONFIG_FILE}"
fi

log_info "Applying dotfiles with chezmoi source ${CHEZMOI_SOURCE}"
if [[ "${#chezmoi_args[@]}" -gt 0 ]]; then
    chezmoi --source "${CHEZMOI_SOURCE}" apply "${chezmoi_args[@]}"
else
    chezmoi --source "${CHEZMOI_SOURCE}" apply
fi

if [[ "$(chezmoi source-path 2>/dev/null || true)" != "${CHEZMOI_DEFAULT_SOURCE}" ]]; then
    log_warn "chezmoi sourceDir is not set to ${CHEZMOI_DEFAULT_SOURCE}"
fi

# Symlinks
log_info "Linking managed configs to application-specific paths"
CLAUDE_SOURCE="${HOME}/.config/agents/tools/claude/CLAUDE.md"
CLAUDE_TARGET="${HOME}/.claude/CLAUDE.md"
if [[ -f "${CLAUDE_SOURCE}" ]]; then
    mkdir -p "${HOME}/.claude"
    ln -sfn "${CLAUDE_SOURCE}" "${CLAUDE_TARGET}"
fi

if [[ "${run_system_bootstrap}" -eq 1 ]]; then
    case "${OSTYPE}" in
        darwin*)
            chmod +x scripts/bootstrap/macos.sh && ./scripts/bootstrap/macos.sh
            ;;
        linux*)
            chmod +x scripts/bootstrap/linux.sh && ./scripts/bootstrap/linux.sh
            ;;
    esac
fi

if [[ "${run_brew}" -eq 1 ]]; then
    chmod +x homebrew/brew.sh && ./homebrew/brew.sh
fi

zsh_path="$(command -v zsh || true)"
if [[ -n "${zsh_path}" ]]; then
    if ! grep -qxF "${zsh_path}" /etc/shells; then
        log_info "Adding ${zsh_path} to /etc/shells"
        if command -v sudo >/dev/null 2>&1; then
            printf '%s\n' "${zsh_path}" | sudo tee -a /etc/shells >/dev/null
        else
            log_warn "sudo not found; could not update /etc/shells"
        fi
    fi
    if [[ "${SHELL}" != "${zsh_path}" ]]; then
        chsh -s "${zsh_path}"
        log_info "Default shell changed to ${zsh_path}"
    fi
fi

copy_and_list_local_example_files

if [[ -n "${zsh_path:-}" ]]; then
    log_info "Run 'exec -l \$SHELL' (or open a new terminal) to reload your shell"
fi

printf "\nDone.\n"

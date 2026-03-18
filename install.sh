#!/usr/bin/env bash

set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
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
HAS_GUM=false
command -v gum >/dev/null 2>&1 && [[ -t 1 ]] && HAS_GUM=true

_header() {
    if [[ "${HAS_GUM}" == true ]]; then
        gum style --bold --foreground 212 "$1"
    else
        printf '%s\n' "$1"
    fi
}

_item() {
    if [[ "${HAS_GUM}" == true ]]; then
        gum style --foreground 244 "  $1"
    else
        printf '  %s\n' "$1"
    fi
}

_box() {
    local content="$1"

    if [[ "${HAS_GUM}" == true ]]; then
        printf '%s' "${content}" | gum style --border rounded --border-foreground 240 --margin "0 0" --padding "0 1"
    else
        printf '%s\n' "${content}" | sed 's/^/  /'
    fi
}

begin_section() {
    printf '\n'
    _header "$1"
}

run_boxed() {
    local tmp_output=""
    local output=""
    local status=0

    tmp_output="$(mktemp "${TMPDIR:-/tmp}/install-output.XXXXXX")"
    if ! "$@" > "${tmp_output}" 2>&1; then
        status=$?
    fi
    output="$(cat "${tmp_output}")"
    rm -f "${tmp_output}"

    if [[ -n "${output}" ]]; then
        _box "${output}"
    else
        _box "Done."
    fi

    return "${status}"
}

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
    local review_message=""

    while IFS= read -r -d '' example_path; do
        target_path="$(chezmoi target-path --source "${CHEZMOI_SOURCE}" "${example_path}")"
        local_path="${target_path%.example}"

        if [[ ! -e "${local_path}" && ! -L "${local_path}" ]]; then
            cp "${target_path}" "${local_path}"
            log_info " Local config ${local_path} doesn't exist yet, creating one from example: ${local_path}"
        fi
    done < <(find "${CHEZMOI_SOURCE}" -type f -name '*.local.example' -print0)

    review_message=$'Review these local config files if you still need to personalize this machine:\n\n'
    review_message+=$'  - ~/.config/git/config.local\n'
    review_message+=$'  - ~/.config/zsh/.zshrc.local\n'
    review_message+=$'  - ~/.ssh/config.local\n'
    review_message+=$'  - ~/.config/1Password/ssh/agent.toml'

    printf '%s\n' "${review_message}"
}

ensure_dotfiles_repo_link() {
    local current_target=""

    if [[ -e "${HOME}/.dotfiles" || -L "${HOME}/.dotfiles" ]]; then
        current_target="$(cd "${HOME}/.dotfiles" 2>/dev/null && pwd -P || true)"
        if [[ "${current_target}" == "${BASEDIR}" ]]; then
            log_info "Dotfiles repo already linked at ${HOME}/.dotfiles"
            return 0
        fi
    fi

    spin "Linking dotfiles repo..." ln -sfn "${BASEDIR}" "${HOME}/.dotfiles"
}

ensure_chezmoi() {
    local chezmoi_path=""
    local bin_dir=""

    chezmoi_path="$(command -v chezmoi || true)"
    if [[ -n "${chezmoi_path}" ]]; then
        return 0
    fi

    if command -v brew >/dev/null 2>&1; then
        log_info "Installing chezmoi with Homebrew"
        spin "Installing chezmoi..." brew install chezmoi
    else
        bin_dir="${HOME}/.local/bin"
        mkdir -p "${bin_dir}"
        log_info "Installing chezmoi to ${bin_dir}"
        spin "Installing chezmoi..." sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "${bin_dir}"
        export PATH="${bin_dir}:${PATH}"
    fi

    chezmoi_path="$(command -v chezmoi || true)"
    if [[ -n "${chezmoi_path}" ]]; then
        log_info "chezmoi available at ${chezmoi_path}"
    fi
}

log_pending_chezmoi_changes() {
    local status_output=""
    local pending_count=""

    log_info "Checking pending chezmoi changes"
    status_output="$(chezmoi --source "${CHEZMOI_SOURCE}" status 2>/dev/null || true)"

    if [[ -z "${status_output}" ]]; then
        log_info "chezmoi reports no pending changes before apply"
        return 0
    fi

    pending_count="$(printf '%s\n' "${status_output}" | awk 'NF { count++ } END { print count + 0 }')"
    log_info "chezmoi reports ${pending_count} pending change(s) before apply"
}

resolve_dir_path() {
    local path="$1"

    if [[ -z "${path}" ]]; then
        return 1
    fi

    cd "${path}" 2>/dev/null && pwd -P
}

run_chezmoi_apply() {
    local -a apply_cmd=(chezmoi --source "${CHEZMOI_SOURCE}" apply)

    if [[ "${#chezmoi_args[@]}" -gt 0 ]]; then
        apply_cmd+=("${chezmoi_args[@]}")
    fi

    "${apply_cmd[@]}"
}

apply_dotfiles() {
    log_info "Applying dotfiles from ${CHEZMOI_SOURCE}"
    log_pending_chezmoi_changes

    run_chezmoi_apply

    log_info "chezmoi apply complete"
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

begin_section "Repository"
_item "Running dotfiles repo link check"
_item "Running ln -sfn ${BASEDIR} ${HOME}/.dotfiles when needed"
run_boxed ensure_dotfiles_repo_link

begin_section "SSH Key"
_item "Running SSH key existence check"
_item "Running ssh-keygen when the local install key is missing"
run_boxed ensure_local_install_ssh_key

if [[ "${run_system_bootstrap}" -eq 1 ]]; then
    begin_section "System Bootstrap"
    case "${OSTYPE}" in
        darwin*)
            _item "Running chmod +x scripts/bootstrap/macos/setup.sh"
            _item "Running ./scripts/bootstrap/macos/setup.sh"
            chmod +x scripts/bootstrap/macos/setup.sh
            ./scripts/bootstrap/macos/setup.sh
            ;;
        linux*)
            _item "Running chmod +x scripts/bootstrap/linux/setup.sh"
            _item "Running ./scripts/bootstrap/linux/setup.sh"
            chmod +x scripts/bootstrap/linux/setup.sh
            ./scripts/bootstrap/linux/setup.sh
            ;;
    esac
    _box "System bootstrap completed."
fi

if [[ "${run_brew}" -eq 1 ]]; then
    begin_section "Homebrew"
    _item "Running chmod +x homebrew/brew.sh"
    _item "Running ./homebrew/brew.sh"
    chmod +x homebrew/brew.sh
    ./homebrew/brew.sh
    _box "Homebrew setup completed."
fi

begin_section "Chezmoi"
_item "Running chezmoi availability check"
_item "Running brew install chezmoi or the standalone installer when needed"
run_boxed ensure_chezmoi

# Remove invalid config so chezmoi apply can regenerate it from the template
if [[ -f "${CHEZMOI_CONFIG_FILE}" ]] && ! chezmoi --source "${CHEZMOI_SOURCE}" dump-config &>/dev/null; then
    begin_section "Chezmoi Config"
    _item "Running chezmoi --source ${CHEZMOI_SOURCE} dump-config"
    _item "Running rm -f ${CHEZMOI_CONFIG_FILE}"
    log_warn "Removing invalid ${CHEZMOI_CONFIG_FILE}"
    rm -f "${CHEZMOI_CONFIG_FILE}"
    _box "Removed invalid ${CHEZMOI_CONFIG_FILE}."
fi

begin_section "Apply"
_item "Running chezmoi status"
_item "Running chezmoi apply"
run_boxed apply_dotfiles

chezmoi_source_path="$(chezmoi source-path 2>/dev/null || true)"
chezmoi_source_resolved="$(resolve_dir_path "${chezmoi_source_path}" || true)"
chezmoi_default_resolved="$(resolve_dir_path "${CHEZMOI_DEFAULT_SOURCE}" || true)"
if [[ "${chezmoi_source_path}" != "${CHEZMOI_DEFAULT_SOURCE}" ]] \
    && [[ -z "${chezmoi_source_resolved}" || -z "${chezmoi_default_resolved}" || "${chezmoi_source_resolved}" != "${chezmoi_default_resolved}" ]]; then
    log_warn "chezmoi sourceDir is not set to ${CHEZMOI_DEFAULT_SOURCE}"
fi

zsh_path="$(command -v zsh || true)"
if [[ -n "${zsh_path}" ]]; then
    begin_section "Shell"
    if ! grep -qxF "${zsh_path}" /etc/shells; then
        if command -v sudo >/dev/null 2>&1; then
            _item "Running printf '%s\\n' '${zsh_path}' | sudo tee -a /etc/shells >/dev/null"
            bash -c "printf '%s\n' '${zsh_path}' | sudo tee -a /etc/shells >/dev/null"
        else
            log_warn "sudo not found; could not update /etc/shells"
        fi
    fi
    if [[ "${SHELL}" != "${zsh_path}" ]]; then
        _item "Running chsh -s ${zsh_path}"
        chsh -s "${zsh_path}"
    fi
    _box "Shell setup completed."
fi

begin_section "Local Config"
_item "Running local example file scan"
run_boxed copy_and_list_local_example_files

if [[ -n "${zsh_path:-}" ]]; then
    begin_section "Next Steps"
    _box "Run 'exec -l \$SHELL' (or open a new terminal) to reload your shell"
fi

printf "\nDone.\n"

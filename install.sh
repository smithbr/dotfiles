#!/usr/bin/env bash

set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "${BASEDIR}/scripts/common.sh"

usage() {
    cat <<'EOF'
Usage: install.sh [OPTIONS] [-- CHEZMOI_ARGS...]

Sets this machine up: links the repo into place, ensures an SSH key exists,
runs the OS bootstrap and Homebrew, then applies the dotfiles with chezmoi.

Options:
  -n, --dry-run      Report what would change without touching the system
  -v, --verbose      Stream command output instead of collecting it into boxes
  -d, --debug        Verbose output plus shell command tracing (set -x)
  -h, --help         Show this help message and exit
      --skip-system  Skip the OS bootstrap (scripts/bootstrap/<os>/setup.sh)
      --skip-brew    Skip the Homebrew install/update/bundle step
      --skip-shell   Skip adding zsh to /etc/shells and chsh

Unrecognised arguments are passed through to `chezmoi apply`, as is everything
after `--`, e.g. install.sh --skip-brew -- --force --exclude=scripts
EOF
}

VERBOSE="${VERBOSE:-0}"
dry_run=0
run_system_bootstrap=1
run_brew=1
run_shell_setup=1
declare -a chezmoi_args=()
while [[ $# -gt 0 ]]; do
    case "${1}" in
        -n|--dry-run)
            dry_run=1
            ;;
        -v|--verbose)
            VERBOSE=1
            ;;
        -d|--debug)
            VERBOSE=1
            set -x
            ;;
        --skip-system)
            run_system_bootstrap=0
            ;;
        --skip-brew)
            run_brew=0
            ;;
        --skip-shell)
            run_shell_setup=0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            while [[ $# -gt 0 ]]; do
                chezmoi_args+=("$1")
                shift
            done
            break
            ;;
        *)
            chezmoi_args+=("$1")
            ;;
    esac
    shift
done
export VERBOSE

if [[ "${dry_run}" -eq 1 ]]; then
    chezmoi_args+=(--dry-run)
fi

require_non_root

if [[ -z "${HOME:-}" ]]; then
    log_error "Seems you're \$HOMEless :("
    exit 1
fi

# Point chezmoi at the repo root; .chezmoiroot redirects it to the dotfiles/ subdir.
CHEZMOI_SOURCE="${BASEDIR}"
# Resolved source path that `chezmoi source-path` reports, used by the sanity check below.
CHEZMOI_DEFAULT_SOURCE="${HOME}/.dotfiles/dotfiles"
CHEZMOI_CONFIG_DIR="${HOME}/.config/chezmoi"
CHEZMOI_CONFIG_FILE="${CHEZMOI_CONFIG_DIR}/chezmoi.json"
LOCAL_INSTALL_SSH_KEY_PATH="${HOME}/.ssh/id_ed25519"
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
    local columns=0
    local longest=0
    local -a width_args=()

    if [[ "${HAS_GUM}" == true ]]; then
        # gum style never wraps on its own, so a line wider than the terminal
        # gets soft-wrapped by the terminal and tears the border apart. Cap the
        # box (content + padding; the border adds 2) to the terminal width, but
        # only when needed so short messages keep a snug box.
        columns="${COLUMNS:-$(tput cols 2>/dev/null || printf '80')}"
        longest="$(printf '%s\n' "${content}" | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }')"
        if (( longest + 4 > columns && columns > 12 )); then
            width_args=(--width "$((columns - 2))")
        fi
        printf '%s' "${content}" | gum style --border rounded --border-foreground 240 --margin "0 0" --padding "0 1" ${width_args[@]+"${width_args[@]}"}
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

    if [[ "${VERBOSE}" -eq 1 ]]; then
        "$@" || status=$?
        return "${status}"
    fi

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

    if [[ "${dry_run}" -eq 1 ]]; then
        if [[ ! -f "${LOCAL_INSTALL_SSH_KEY_PATH}" && ! -f "${LOCAL_INSTALL_SSH_KEY_PATH}.pub" ]]; then
            log_info "Would create an SSH key at ${LOCAL_INSTALL_SSH_KEY_PATH}"
        elif [[ -f "${LOCAL_INSTALL_SSH_KEY_PATH}" && ! -f "${LOCAL_INSTALL_SSH_KEY_PATH}.pub" ]]; then
            log_info "Would restore the public key for ${LOCAL_INSTALL_SSH_KEY_PATH}"
        else
            log_info "SSH key at ${LOCAL_INSTALL_SSH_KEY_PATH} is already in place"
        fi
        return 0
    fi

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

    # A public key present without a private key on disk means the key is managed
    # by an external SSH agent (e.g. 1Password keeps the private half in the vault
    # and exposes only the .pub here as the IdentityFile). Generating a new keypair
    # would clobber it and break SSH auth and commit signing, so leave it alone.
    if [[ -f "${LOCAL_INSTALL_SSH_KEY_PATH}.pub" ]]; then
        log_info "Found ${LOCAL_INSTALL_SSH_KEY_PATH}.pub with no private key on disk; assuming an external agent (e.g. 1Password) manages it, leaving it untouched"
        return 0
    fi

    key_comment="$(ssh_key_comment)"
    log_info "Creating local SSH key at ${LOCAL_INSTALL_SSH_KEY_PATH}"
    ssh-keygen -q -t ed25519 -N "" -C "${key_comment}" -f "${LOCAL_INSTALL_SSH_KEY_PATH}"
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
            if [[ "${dry_run}" -eq 1 ]]; then
                log_info " Would create ${local_path} from example ${target_path}"
            else
                cp "${target_path}" "${local_path}"
                log_info " Local config ${local_path} doesn't exist yet, creating one from example: ${local_path}"
            fi
        fi
    done < <(find "${BASEDIR}/dotfiles" -type f -name '*.local.example' -print0)

    review_message=$'Check these local config files:\n\n'
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

    if [[ "${dry_run}" -eq 1 ]]; then
        log_info "Would link ${BASEDIR} to ${HOME}/.dotfiles"
        return 0
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

    if [[ "${dry_run}" -eq 1 ]]; then
        log_warn "chezmoi is not installed; would install it before applying"
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

    if "${apply_cmd[@]}"; then
        return 0
    fi

    # The .config/agents external clones a private repo over SSH. On a first run
    # this host's key isn't registered with GitHub yet, so the clone fails and
    # takes the rest of the apply down with it -- leaving no shell config at all.
    # Retry without externals so the machine ends up usable, and say what is
    # needed to finish.
    log_warn "chezmoi apply failed; retrying without externals"
    "${apply_cmd[@]}" --exclude=externals

    log_warn "Applied without externals. Register this host's SSH key with GitHub, then re-run:"
    log_warn "  chezmoi --source ${CHEZMOI_SOURCE} apply"
}

apply_dotfiles() {
    if ! command -v chezmoi >/dev/null 2>&1; then
        log_warn "chezmoi is not installed; skipping apply"
        return 0
    fi

    log_info "Applying dotfiles from ${CHEZMOI_SOURCE}"
    log_pending_chezmoi_changes

    run_chezmoi_apply

    log_info "chezmoi apply complete"
}

cd "${BASEDIR}"

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
    if [[ "${dry_run}" -eq 1 ]]; then
        _box "Dry run: skipping the system bootstrap script."
    else
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
fi

if [[ "${run_brew}" -eq 1 ]]; then
    begin_section "Homebrew"
    if [[ "${dry_run}" -eq 1 ]]; then
        _box "Dry run: skipping Homebrew install/update/bundle."
    else
        _item "Running chmod +x homebrew/brew.sh"
        _item "Running ./homebrew/brew.sh"
        chmod +x homebrew/brew.sh
        ./homebrew/brew.sh
        _box "Homebrew setup completed."
    fi
fi

begin_section "Configuration"
_item "Running chezmoi availability check"
_item "Running brew install chezmoi or the standalone installer when needed"
run_boxed ensure_chezmoi

# Remove invalid config so chezmoi apply can regenerate it from the template
if [[ -f "${CHEZMOI_CONFIG_FILE}" ]] && command -v chezmoi >/dev/null 2>&1 \
    && ! chezmoi --source "${CHEZMOI_SOURCE}" dump-config &>/dev/null; then
    _item "Running chezmoi --source ${CHEZMOI_SOURCE} dump-config"
    if [[ "${dry_run}" -eq 1 ]]; then
        _box "Would remove invalid ${CHEZMOI_CONFIG_FILE}."
    else
        _item "Running rm -f ${CHEZMOI_CONFIG_FILE}"
        log_warn "Removing invalid ${CHEZMOI_CONFIG_FILE}"
        rm -f "${CHEZMOI_CONFIG_FILE}"
        _box "Removed invalid ${CHEZMOI_CONFIG_FILE}."
    fi
fi

_item "Running chezmoi status"
_item "Running chezmoi apply"
# Not boxed: chezmoi prompts before overwriting files changed since it last
# wrote them, and capturing its output would hide the prompt while it waits.
apply_dotfiles

chezmoi_source_path="$(chezmoi source-path 2>/dev/null || true)"
chezmoi_source_resolved="$(resolve_dir_path "${chezmoi_source_path}" || true)"
chezmoi_default_resolved="$(resolve_dir_path "${CHEZMOI_DEFAULT_SOURCE}" || true)"
if [[ "${chezmoi_source_path}" != "${CHEZMOI_DEFAULT_SOURCE}" ]] \
    && [[ -z "${chezmoi_source_resolved}" || -z "${chezmoi_default_resolved}" || "${chezmoi_source_resolved}" != "${chezmoi_default_resolved}" ]]; then
    log_warn "chezmoi sourceDir is not set to ${CHEZMOI_DEFAULT_SOURCE}"
fi

zsh_path=""
if [[ "${run_shell_setup}" -eq 1 ]]; then
    zsh_path="$(command -v zsh || true)"
fi
if [[ -n "${zsh_path}" ]]; then
    if ! grep -qxF "${zsh_path}" /etc/shells; then
        if ! command -v sudo >/dev/null 2>&1; then
            log_warn "sudo not found; could not update /etc/shells"
        elif [[ "${dry_run}" -eq 1 ]]; then
            _item "Would add ${zsh_path} to /etc/shells"
        else
            _item "Running printf '%s\\n' '${zsh_path}' | sudo tee -a /etc/shells >/dev/null"
            bash -c "printf '%s\n' '${zsh_path}' | sudo tee -a /etc/shells >/dev/null"
        fi
    fi
    if [[ "${SHELL}" != "${zsh_path}" ]]; then
        if [[ "${dry_run}" -eq 1 ]]; then
            _item "Would run chsh -s ${zsh_path}"
        else
            _item "Running chsh -s ${zsh_path}"
            chsh -s "${zsh_path}"
        fi
    fi
    _box "Shell setup completed."
fi

begin_section "Finish"
_item "Running local example file scan"
run_boxed copy_and_list_local_example_files

if [[ -n "${zsh_path:-}" && "${dry_run}" -eq 0 ]]; then
    _box "Run 'exec -l \$SHELL' (or open a new terminal) to reload your shell"
fi

printf "\nDone.\n"

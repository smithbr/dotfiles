#!/usr/bin/env bash

set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "${BASEDIR}/scripts/common.sh"

usage() {
    cat <<'EOF'
Usage: install.sh [OPTIONS] [-- STOW_ARGS...]

Sets this machine up: links the repo into place, ensures an SSH key exists,
runs the OS bootstrap and Homebrew, then links the dotfiles with GNU Stow.

Options:
  -n, --dry-run      Report what would change without touching the system
  -v, --verbose      Stream command output instead of collecting it into boxes
  -d, --debug        Verbose output plus shell command tracing (set -x)
  -h, --help         Show this help message and exit
      --skip-system  Skip the OS bootstrap (scripts/bootstrap/<os>/setup.sh)
      --skip-brew    Skip the Homebrew install/update/bundle step
      --skip-shell   Skip adding zsh to /etc/shells and chsh

Unrecognised arguments are passed through to stow, as is everything after
`--`, e.g. install.sh --skip-brew -- --verbose=2
EOF
}

VERBOSE="${VERBOSE:-0}"
dry_run=0
run_system_bootstrap=1
run_brew=1
run_shell_setup=1
declare -a link_args=()
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
                link_args+=("$1")
                shift
            done
            break
            ;;
        *)
            link_args+=("$1")
            ;;
    esac
    shift
done
export VERBOSE

require_non_root

if [[ -z "${HOME:-}" ]]; then
    log_error "Seems you're \$HOMEless :("
    exit 1
fi

LINK_SCRIPT="${BASEDIR}/scripts/link.sh"
LOCAL_INSTALL_SSH_KEY_PATH="${HOME}/.ssh/id_ed25519"
HAS_GUM=false
command -v gum >/dev/null 2>&1 && [[ -t 1 ]] && HAS_GUM=true
STEP_INDEX=0
STEP_TOTAL=0
# Follow-ups gathered during the run and shown together at the end, so they
# are not lost in the scrollback of Homebrew and stow output.
declare -a NEXT_STEPS=()

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

_check() {
    if [[ "${HAS_GUM}" == true ]]; then
        gum style --foreground 76 "  $(printf '\xe2\x9c\x93') $1"
    else
        printf '  ok: %s\n' "$1"
    fi
}

_cross() {
    if [[ "${HAS_GUM}" == true ]]; then
        gum style --foreground 196 "  $(printf '\xe2\x9c\x97') $1"
    else
        printf '  failed: %s\n' "$1"
    fi
}

_skip() {
    if [[ "${HAS_GUM}" == true ]]; then
        gum style --foreground 244 "  - $1"
    else
        printf '  skipped: %s\n' "$1"
    fi
}

_next_step() {
    NEXT_STEPS+=("$1")
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

# Numbered section: "[2/7] SSH key" plus one line saying what the step is for.
begin_step() {
    local title="$1"
    local purpose="$2"

    STEP_INDEX=$((STEP_INDEX + 1))
    begin_section "[${STEP_INDEX}/${STEP_TOTAL}] ${title}"
    _item "${purpose}"
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
    "$@" > "${tmp_output}" 2>&1 || status=$?
    # Drop the "INFO " prefix: inside a step, plain progress needs no label,
    # which leaves WARN/ERROR lines standing out.
    output="$(sed 's/^INFO //' "${tmp_output}")"
    rm -f "${tmp_output}"

    if [[ "${status}" -eq 0 && -n "${output}" && "${output}" != *$'\n'* && "${output}" != WARN* ]]; then
        _check "${output}"
    elif [[ -n "${output}" ]]; then
        _box "${output}"
    fi
    if [[ "${status}" -ne 0 ]]; then
        _cross "Failed (exit ${status})"
    elif [[ -z "${output}" ]]; then
        _check "Nothing to change"
    fi

    return "${status}"
}

ssh_key_comment() {
    printf '%s@%s\n' "${USER:-$(id -un)}" "$(hostname -s 2>/dev/null || hostname)"
}

require_ssh_keygen() {
    command -v ssh-keygen >/dev/null 2>&1 && return 0
    log_error "ssh-keygen is not installed; install openssh-client (the Linux system bootstrap does this) and re-run"
    return 1
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
            require_ssh_keygen || return 1
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

    require_ssh_keygen || return 1
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

    # Stow packages mirror $HOME, so a package-relative path is the target path.
    while IFS= read -r -d '' example_path; do
        example_path="${example_path#"${BASEDIR}"/stow/}"
        target_path="${HOME}/${example_path#*/}"
        local_path="${target_path%.example}"

        if [[ ! -e "${local_path}" && ! -L "${local_path}" ]]; then
            if [[ "${dry_run}" -eq 1 ]]; then
                log_info "Would create ${local_path} from ${target_path}"
            else
                cp "${target_path}" "${local_path}"
                log_info "Created ${local_path} from ${target_path}"
            fi
        fi
    done < <(find "${BASEDIR}/stow" -type f -name '*.local.example' -print0)

    review_message='Review machine-specific settings in ~/.config/git/config.local,'
    review_message+=' ~/.config/zsh/.zshrc.local, ~/.ssh/config.local,'
    review_message+=' and ~/.config/1Password/ssh/agent.toml'
    _next_step "${review_message}"
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

ensure_stow() {
    if command -v stow >/dev/null 2>&1; then
        return 0
    fi

    if [[ "${dry_run}" -eq 1 ]]; then
        log_warn "GNU Stow is not installed; would install it before linking"
        return 0
    fi

    if command -v brew >/dev/null 2>&1; then
        log_info "Installing GNU Stow with Homebrew"
        spin "Installing stow..." brew install stow
    elif command -v apt-get >/dev/null 2>&1; then
        log_info "Installing GNU Stow with apt"
        spin "Installing stow..." sudo_cmd apt-get install -y -qq stow
    else
        log_error "GNU Stow is not installed and no package manager was found to install it"
        return 1
    fi
}

log_pending_link_changes() {
    local status_output=""
    local pending_count=""

    log_info "Checking links before applying"
    status_output="$(bash "${LINK_SCRIPT}" status 2>/dev/null || true)"

    if [[ -z "${status_output}" ]]; then
        log_info "All dotfiles are already linked"
        return 0
    fi

    pending_count="$(printf '%s\n' "${status_output}" | awk 'NF { count++ } END { print count + 0 }')"
    log_info "${pending_count} path(s) to link or repair"
}

apply_dotfiles() {
    local -a link_cmd=(bash "${LINK_SCRIPT}")

    if ! command -v stow >/dev/null 2>&1 && [[ "${dry_run}" -eq 0 ]]; then
        log_error "GNU Stow is not installed; cannot link dotfiles"
        return 1
    fi

    log_info "Linking dotfiles from ${BASEDIR}/stow"
    log_pending_link_changes

    if [[ "${dry_run}" -eq 1 ]]; then
        link_cmd+=(--dry-run)
    fi
    if [[ "${#link_args[@]}" -gt 0 ]]; then
        link_cmd+=(-- "${link_args[@]}")
    fi
    "${link_cmd[@]}"

    log_info "Linking complete"
}

review_existing_files() {
    local index=0
    local review_only="${dry_run}"
    local -a review_args=(--source "${BASEDIR}")

    # stow's own simulate flags make the whole install a dry run.
    while [[ "${index}" -lt "${#link_args[@]}" ]]; do
        case "${link_args[index]}" in
            -n|--no|--simulate)
                review_only=1
                ;;
        esac
        index=$((index + 1))
    done
    if [[ "${review_only}" -eq 0 && -t 0 && -t 1 ]]; then
        review_args+=(--cleanup)
    fi
    if ! bash "${BASEDIR}/scripts/file-review.sh" "${review_args[@]}"; then
        log_warn "File review incomplete; inspect the errors above before cleaning up"
    fi
}

cd "${BASEDIR}"

run_mode="Installing"
[[ "${dry_run}" -eq 1 ]] && run_mode="Dry run (nothing will be changed)"
declare -a skipped_steps=()
STEP_TOTAL=5
if [[ "${run_system_bootstrap}" -eq 1 ]]; then
    STEP_TOTAL=$((STEP_TOTAL + 1))
else
    skipped_steps+=("system packages")
fi
if [[ "${run_brew}" -eq 1 ]]; then
    STEP_TOTAL=$((STEP_TOTAL + 1))
else
    skipped_steps+=("Homebrew")
fi
if [[ "${run_shell_setup}" -eq 1 ]]; then
    STEP_TOTAL=$((STEP_TOTAL + 1))
else
    skipped_steps+=("login shell")
fi

_header "Dotfiles setup"
_item "${run_mode} from ${BASEDIR}"
if [[ "${#skipped_steps[@]}" -gt 0 ]]; then
    _item "Skipping: $(printf '%s, ' "${skipped_steps[@]}" | sed 's/, $//')"
fi
if [[ "${VERBOSE}" -eq 0 ]]; then
    _item "Use --verbose to stream full command output"
fi

begin_step "Repository link" "Point ~/.dotfiles at this checkout"
run_boxed ensure_dotfiles_repo_link

if [[ "${run_system_bootstrap}" -eq 1 ]]; then
    case "${OSTYPE}" in
        darwin*) os_label="macOS" ;;
        linux*) os_label="Linux" ;;
        *) os_label="${OSTYPE}" ;;
    esac
    begin_step "System packages" "Run the ${os_label} bootstrap script (system tools and settings)"
    if [[ "${dry_run}" -eq 1 ]]; then
        _skip "Dry run: skipping the system bootstrap script."
    else
        case "${OSTYPE}" in
            darwin*)
                chmod +x scripts/bootstrap/macos/setup.sh
                ./scripts/bootstrap/macos/setup.sh
                ;;
            linux*)
                chmod +x scripts/bootstrap/linux/setup.sh
                ./scripts/bootstrap/linux/setup.sh
                ;;
        esac
        _check "System bootstrap complete"
    fi
fi

# After the system bootstrap, which installs ssh-keygen on a bare Linux host.
begin_step "SSH key" "Make sure this machine has ${LOCAL_INSTALL_SSH_KEY_PATH} for GitHub and signing"
run_boxed ensure_local_install_ssh_key

if [[ "${run_brew}" -eq 1 ]]; then
    begin_step "Homebrew" "Install Homebrew if needed, then the packages in homebrew/Brewfile.*"
    if [[ "${dry_run}" -eq 1 ]]; then
        _skip "Dry run: skipping Homebrew install/update/bundle."
    else
        chmod +x homebrew/brew.sh
        ./homebrew/brew.sh
        _check "Homebrew packages up to date"
    fi
fi

begin_step "Dotfiles" "Install GNU Stow if needed, then link the managed files into your home"
run_boxed ensure_stow

# Not boxed: backups of replaced files are listed as they happen, and the
# agents clone may need to show an SSH prompt.
apply_dotfiles

zsh_path=""
if [[ "${run_shell_setup}" -eq 1 ]]; then
    begin_step "Login shell" "Make zsh your login shell"
    zsh_path="$(command -v zsh || true)"
    if [[ -z "${zsh_path}" ]]; then
        _skip "zsh is not installed"
    fi
fi
if [[ -n "${zsh_path}" ]]; then
    if ! grep -qxF "${zsh_path}" /etc/shells; then
        if ! command -v sudo >/dev/null 2>&1; then
            log_warn "sudo not found; could not update /etc/shells"
        elif [[ "${dry_run}" -eq 1 ]]; then
            _item "Would add ${zsh_path} to /etc/shells"
        else
            _item "Adding ${zsh_path} to /etc/shells (may ask for your password)"
            printf '%s\n' "${zsh_path}" | sudo tee -a /etc/shells >/dev/null
        fi
    fi
    if [[ "${SHELL}" != "${zsh_path}" ]]; then
        if [[ "${dry_run}" -eq 1 ]]; then
            _item "Would run chsh -s ${zsh_path}"
        else
            _item "Changing login shell to ${zsh_path} (may ask for your password)"
            chsh -s "${zsh_path}"
        fi
    fi
    _check "Login shell is ${zsh_path}"
fi

begin_step "Local config" "Create machine-specific *.local files from their examples"
run_boxed copy_and_list_local_example_files

begin_step "Existing files" "List leftover dotfiles that the repo no longer manages"
review_existing_files

if [[ -n "${zsh_path:-}" && "${dry_run}" -eq 0 ]]; then
    _next_step "Reload your shell: exec -l \$SHELL (or open a new terminal)"
fi

printf '\n'
if [[ "${dry_run}" -eq 1 ]]; then
    _header "Done. Dry run finished; nothing was changed."
else
    _header "Done. Setup finished in $((SECONDS / 60))m $((SECONDS % 60))s."
fi
if [[ "${#NEXT_STEPS[@]}" -gt 0 ]]; then
    next_steps_text="Next steps:"
    step_number=0
    for next_step in "${NEXT_STEPS[@]}"; do
        step_number=$((step_number + 1))
        next_steps_text+=$'\n'"  ${step_number}. ${next_step}"
    done
    _box "${next_steps_text}"
fi

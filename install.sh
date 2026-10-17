#!/usr/bin/env bash

set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "${BASEDIR}/scripts/common.sh"

usage() {
    cat <<'EOF'
Usage: install.sh [OPTIONS] [-- STOW_ARGS...]

Sets this machine up: asks what it is (persona, installs, optional packages)
once and remembers, offers to harden a Linux server or VPS first when it is
not, then links the repo into place, ensures an SSH key exists, runs the OS
bootstrap and Homebrew, links the dotfiles with GNU Stow, and applies the
chosen installs. Safe to run again: every step skips what is already done.

Options:
  -n, --dry-run      Report what would change without touching the system
  -v, --verbose      Stream command output instead of collecting it into boxes
  -d, --debug        Verbose output plus shell command tracing (set -x)
  -h, --help         Show this help message and exit
      --persona NAME Set this machine up as NAME (home, work, server, vps;
                     see personas/). Saved for later runs; without it, a terminal
                     asks every run with the saved choice preselected (Enter
                     keeps it), otherwise the saved choice or the OS default
                     applies
      --install NAME Add an install: one offered to every persona (docker,
                     tailscale, claude-code, on by default; holeberry, off) or a
                     role the persona offers (see roles/: pihole);
                     --no-install NAME drops one.
                     Saved for later runs; without either, a terminal asks until
                     a choice is saved. DOTFILES_INSTALLS="a b" sets the whole
                     list
      --harden       Run scripts/bootstrap/linux/harden.sh first (key-only SSH
                     over Tailscale, ufw, unattended upgrades; HARDEN_ARGS adds
                     its options). Without it, a server or vps persona on Linux
                     that harden-test.sh finds unhardened asks on a terminal;
                     --no-harden skips the question
      --reconfigure  Ask the install questions again (the persona is asked
                     on every terminal run)
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
persona_arg=""
harden_arg=""
reconfigure=0
declare -a link_args=() install_args=() no_install_args=()
while [[ $# -gt 0 ]]; do
    case "${1}" in
        --persona|--install|--no-install)
            if [[ $# -lt 2 || -z "${2}" ]]; then
                log_error "${1} requires a name"
                exit 2
            fi
            case "${1}" in
                --persona) persona_arg="${2}" ;;
                --install) install_args+=("${2}") ;;
                --no-install) no_install_args+=("${2}") ;;
            esac
            shift
            ;;
        --harden)
            harden_arg=yes
            ;;
        --no-harden)
            harden_arg=no
            ;;
        --reconfigure)
            reconfigure=1
            ;;
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
STEP_INDEX=0
STEP_TOTAL=0

_next_step() {
    NEXT_STEPS+=("$1")
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

# Live output in a step's style: each line indented and the "INFO " label
# dropped as run_boxed does, for a step that must show things as they happen
# (a backup being made, a login URL to open) rather than hold them for a box.
# The command keeps the terminal as stdin, so a prompt it draws there works.
run_streamed() {
    local line status=0

    if [[ "${VERBOSE}" -eq 1 ]]; then
        "$@" || status=$?
        return "${status}"
    fi

    "$@" 2>&1 | while IFS= read -r line || [[ -n "${line}" ]]; do
        printf '  %s\n' "${line#INFO }"
    done || status="${PIPESTATUS[0]}"

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
    local managed
    local target_path
    local local_path
    local review_message=""

    # Only the examples this persona links; another layer's example has no
    # linked copy here to start from. Read once: piping it into grep -q
    # would stop link.sh with SIGPIPE, which pipefail reports as no match.
    managed="$(bash "${LINK_SCRIPT}" managed)" || {
        log_error "Could not list managed paths"
        return 1
    }
    while IFS= read -r target_path; do
        [[ "${target_path}" == *.local.example ]] || continue
        local_path="${target_path%.example}"

        if [[ ! -e "${local_path}" && ! -L "${local_path}" ]]; then
            if [[ "${dry_run}" -eq 1 ]]; then
                log_info "Would create ${local_path} from ${target_path}"
            else
                cp "${target_path}" "${local_path}"
                log_info "Created ${local_path} from ${target_path}"
            fi
        fi
    done <<< "${managed}"

    review_message='Review machine-specific settings in ~/.config/git/config.local,'
    review_message+=' ~/.config/zsh/.zshrc.local, ~/.ssh/config.local'
    if grep -qxF "${HOME}/.config/1Password/ssh/agent.toml.example" <<< "${managed}"; then
        review_message+=', and ~/.config/1Password/ssh/agent.toml'
    fi
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
    # An install always pulls the agents checkout; link.sh on its own only
    # does weekly.
    local -a link_cmd=(bash "${LINK_SCRIPT}" --refresh)

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

# df-doctor's --fix questions need a real terminal and a run that may change files;
# stow's own simulate flags make the whole install a dry run.
file_cleanup_is_interactive() {
    local index=0

    [[ "${dry_run}" -eq 0 && -t 0 && -t 1 ]] || return 1
    while [[ "${index}" -lt "${#link_args[@]}" ]]; do
        case "${link_args[index]}" in
            -n|--no|--simulate)
                return 1
                ;;
        esac
        index=$((index + 1))
    done
}

# Report only: this runs boxed, which holds output until it exits, so it must
# never prompt. A failed check clears offer_cleanup so no questions follow.
review_existing_files() {
    local -a review_args=(--source "${BASEDIR}" --report)

    [[ "${offer_cleanup:-0}" -eq 1 ]] && review_args+=(--no-hint)
    if ! bash "${BASEDIR}/scripts/doctor.sh" "${review_args[@]}"; then
        offer_cleanup=0
        log_warn "File review incomplete; inspect the errors above before cleaning up"
    fi
}

# Unboxed so df-doctor's --fix questions can draw on the terminal.
select_files_to_archive() {
    if ! bash "${BASEDIR}/scripts/doctor.sh" --source "${BASEDIR}" --fix-only; then
        log_warn "File cleanup did not finish; inspect the errors above"
    fi
}

# An install's setup script lives in scripts/bootstrap/<os>/ or scripts/bootstrap/.
setup_script_path() {
    local name="$1" dir
    for dir in "${BASEDIR}/scripts/bootstrap/${os_dir}" "${BASEDIR}/scripts/bootstrap"; do
        if [[ -f "${dir}/${name}.sh" ]]; then
            printf '%s\n' "${dir}/${name}.sh"
            return 0
        fi
    done
    return 1
}

# True once an install is applied: its detect command succeeds, with
# common.sh's helpers (tool_installed) in scope.
install_applied() {
    bash -c "source '${BASEDIR}/scripts/common.sh' && $1" >/dev/null 2>&1
}

# Apply the chosen installs in order, last, once everything is linked, so a
# machine gets what it is for (Tailscale, a Pi-hole) when it is ready. One
# whose detect command already succeeds is skipped; a failure is reported,
# not fatal, and the install stays chosen so the next run retries. A setup
# script's output streams, since a vendor installer may take minutes or
# print a login URL, but in the step's style.
run_installs() {
    local name setup detect script

    while IFS=$'\t' read -r name setup detect; do
        [[ "${name}" == install=* ]] || continue
        name="${name#install=}"
        if install_applied "${detect}"; then
            _check "${name} already applied"
            continue
        fi
        if ! script="$(setup_script_path "${setup}")"; then
            _cross "No ${setup} setup script for ${os_label}; ${name} not applied"
            continue
        fi
        if [[ "${dry_run}" -eq 1 ]]; then
            _item "Would apply ${name}: bash ${script}"
            continue
        fi
        _item "Applying ${name}"
        if run_streamed bash "${script}" && install_applied "${detect}"; then
            _check "${name} applied"
        else
            _cross "${name} not applied; rerun it: bash ${script}"
        fi
    done <<< "${INSTALL_INFO}"
}

# Ask which persona this machine is, when a terminal is available and neither
# --persona nor DOTFILES_PERSONA chose one. Unboxed, before the steps, so the
# picker can draw. A closed stdin, EOF or an empty answer keeps the default
# (the saved choice, else the OS default); SOURCE saved names it in the header.
#   prompt_persona DEFAULT [SOURCE]
prompt_persona() {
    local default="$1" source="${2:-}" name header="Which persona is this machine?"
    local -a names=()

    while IFS= read -r name; do
        names+=("${name}")
    done < <(bash "${LINK_SCRIPT}" personas)
    [[ "${#names[@]}" -gt 0 ]] || { printf '%s\n' "${default}"; return 0; }
    [[ "${source}" != saved ]] || header="This machine is saved as ${default}. Keep it or pick another:"
    choose_one "${header}" "${default}" "${names[@]}"
}

# True when both stdin and stdout are a terminal, so a question can be asked.
on_terminal() {
    [[ -t 0 && -t 1 ]]
}

# Settle the persona before anything changes, and pass it on to link.sh and
# doctor.sh through the environment. A terminal is asked every run, the saved
# choice preselected, so a run never starts on a persona nobody confirmed.
resolve_persona() {
    local resolved name source
    if [[ -n "${persona_arg}" ]]; then
        export DOTFILES_PERSONA="${persona_arg}"
    fi
    resolved="$(bash "${LINK_SCRIPT}" persona)" || exit 2
    read -r name source <<< "${resolved}"
    if [[ "${source}" != flag && "${source}" != env ]] && on_terminal; then
        name="$(prompt_persona "${name}" "${source}")"
        export DOTFILES_PERSONA="${name}"
        source=chosen
    fi
    PERSONA_NAME="${name}"
    PERSONA_SOURCE="${source}"
}

# The persona's install lists from link.sh: brew=, brew_optional=, installs=
# (chosen, in run order), installs_source=, and an
# install=NAME<TAB>SETUP<TAB>DETECT line per chosen install.
read_installs() {
    local key value
    INSTALL_INFO="$(bash "${LINK_SCRIPT}" installs)" || exit 2
    while IFS='=' read -r key value; do
        case "${key}" in
            brew) DOTFILES_BREWFILES="${value}" ;;
            brew_optional) DOTFILES_BREW_OPTIONAL="${value}" ;;
            harden) PERSONA_HARDEN="${value}" ;;
            installs) INSTALLS="${value}" ;;
            installs_source) INSTALLS_SOURCE="${value}" ;;
        esac
    done <<< "${INSTALL_INFO}"
    export DOTFILES_BREWFILES DOTFILES_BREW_OPTIONAL
}

# Settle the installs (the optional installs every persona gets, on by
# default, and the persona's roles): --install/--no-install and
# DOTFILES_INSTALLS decide outright; otherwise a terminal is asked until a
# choice is saved (or --reconfigure), with the saved or default installs and
# the ones already applied preselected; closed stdin keeps those. The answer
# goes to link.sh as DOTFILES_INSTALLS, which saves it, orders it, and adds
# the roles' layers. PENDING_INSTALLS is what is chosen but not yet applied.
resolve_installs() {
    local name detect reply chosen="" applied="" source="" source_was=""
    local -a items=()

    OFFERED_INSTALLS="" PENDING_INSTALLS=""
    while IFS=$'\t' read -r name _ detect; do
        [[ -n "${name}" ]] || continue
        OFFERED_INSTALLS="${OFFERED_INSTALLS}${name} "
        if [[ -n "${detect}" ]] && install_applied "${detect}"; then
            applied="${applied} ${name}"
            items+=("${name} (applied)"$'\t'"${name}")
        else
            items+=("${name}"$'\t'"${name}")
        fi
    done < <(bash "${LINK_SCRIPT}" offered)
    read_installs
    chosen="${INSTALLS}" source_was="${INSTALLS_SOURCE}"

    if [[ "${#install_args[@]}" -gt 0 || "${#no_install_args[@]}" -gt 0 ]]; then
        chosen="${chosen} ${install_args[*]+"${install_args[*]}"}"
        for name in ${no_install_args[@]+"${no_install_args[@]}"}; do
            chosen=" ${chosen} "
            chosen="${chosen// ${name} / }"
        done
        source=flag
    elif [[ "${#items[@]}" -gt 0 && ( "${INSTALLS_SOURCE}" == default || "${reconfigure}" -eq 1 ) && -t 0 && -t 1 ]]; then
        # Esc or an invalid answer keeps the marked installs.
        if reply="$(choose_many --selected "${chosen} ${applied}" "Installs for this machine" "${items[@]}")"; then
            chosen="$(tr '\n' ' ' <<< "${reply}")"
        fi
        source=chosen
    fi
    export DOTFILES_INSTALLS="${chosen}"
    read_installs
    INSTALLS_SOURCE="${source:-${source_was}}"
    for name in ${INSTALLS}; do
        [[ " ${applied} " == *" ${name} "* ]] || PENDING_INSTALLS="${PENDING_INSTALLS}${name} "
    done
}

# Offer hardening first, before anything is installed, on a Linux box whose
# persona says harden=yes (server, vps) when harden-test.sh finds it is not:
# its --brief output lists what is missing. --harden runs harden.sh outright
# (it is safe to run again) and --no-harden skips the question; closed stdin
# skips it too, since on a server in use harden.sh closes every port but the
# tailnet's and allows only one SSH user. The question is asked in a dry run
# as well, so the dry run shows the step.
resolve_harden() {
    local gap
    HARDEN=0 HARDEN_SOURCE="" HARDEN_GAPS=""
    if [[ "${harden_arg}" == yes ]]; then
        if [[ "${os_dir}" != linux ]]; then
            log_error "The --harden option is for Linux (scripts/bootstrap/linux/harden.sh)"
            exit 2
        fi
        HARDEN=1 HARDEN_SOURCE=flag
        return 0
    fi
    [[ "${os_dir}" == linux && "${PERSONA_HARDEN}" == yes ]] || return 0
    HARDEN_GAPS="$(bash "${BASEDIR}/scripts/bootstrap/linux/harden-test.sh" --brief 2>/dev/null || true)"
    [[ -n "${HARDEN_GAPS}" ]] || return 0
    [[ "${harden_arg}" != no && -t 0 && -t 1 ]] || return 0
    printf '\n'
    _header "This machine is not hardened:"
    while IFS= read -r gap; do
        _item "${gap}"
    done <<< "${HARDEN_GAPS}"
    if [[ "$(choose_one "Harden it first? harden.sh: key-only SSH over Tailscale, ufw, unattended upgrades. On a server in use this closes every port but the tailnet's and allows only your SSH user." no yes no)" == yes ]]; then
        HARDEN=1 HARDEN_SOURCE=chosen
    fi
}

# harden.sh re-runs itself through sudo for this user and streams (a
# Tailscale login URL to open). HARDEN_ARGS adds its options (--allow 443,
# --cloudflare, --keep-public-ssh), as with bootstrap.sh. A failure is
# reported, not fatal: the rest of the install does not depend on it.
run_harden() {
    local script="${BASEDIR}/scripts/bootstrap/linux/harden.sh"
    local -a args=()
    # shellcheck disable=SC2206 # HARDEN_ARGS is a list of options
    [[ -z "${HARDEN_ARGS:-}" ]] || args=(${HARDEN_ARGS})
    if [[ "${dry_run}" -eq 1 ]]; then
        run_boxed bash "${script}" --dry-run ${args[@]+"${args[@]}"} || true
        return 0
    fi
    if run_streamed bash "${script}" ${args[@]+"${args[@]}"}; then
        _check "Hardened; in a new terminal, check that you can still log in before closing this one"
    else
        _cross "Hardening did not finish; rerun it: sudo bash ${script}"
    fi
}

# Ask the optional Homebrew packages question up front, when Homebrew will
# run on macOS and a terminal is there; brew.sh then installs the answer
# (DOTFILES_BREW_PICKS) without asking. Closed stdin picks none.
resolve_brew_picks() {
    local line
    local -a pending=()
    BREW_PICK_COUNT=0
    [[ "${run_brew}" -eq 1 && "${os_dir}" == macos && -n "${DOTFILES_BREW_OPTIONAL// /}" ]] || return 0
    while IFS= read -r line; do
        [[ -n "${line}" ]] && pending+=("${line}")
    done < <(bash "${BASEDIR}/homebrew/brew.sh" --pending)
    export DOTFILES_BREW_PICKS=""
    [[ "${#pending[@]}" -gt 0 && "${dry_run}" -eq 0 && -t 0 && -t 1 ]] || return 0
    DOTFILES_BREW_PICKS="$(choose_many "Optional Homebrew packages" "${pending[@]}" || true)"
    [[ -z "${DOTFILES_BREW_PICKS}" ]] || BREW_PICK_COUNT="$(wc -l <<< "${DOTFILES_BREW_PICKS}" | tr -d ' ')"
}

# One sudo prompt up front when a step will need it, so no password prompt
# hides inside a boxed step or a spinner. ponytail: no keepalive; sudo's own
# timeout covers a normal run.
prime_sudo() {
    [[ "${dry_run}" -eq 0 && "${EUID}" -ne 0 ]] || return 0
    command -v sudo >/dev/null 2>&1 || return 0
    if [[ "${os_dir}" == linux && "${run_system_bootstrap}" -eq 1 ]] || [[ -n "${PENDING_INSTALLS// /}" || "${HARDEN}" -eq 1 ]]; then
        _item "Some steps need sudo; it may ask for your password now"
        sudo -v || log_warn "sudo failed; steps that need it will ask again or fail"
    fi
}

case "${OSTYPE}" in
    darwin*) os_label="macOS" os_dir=macos ;;
    linux*) os_label="Linux" os_dir=linux ;;
    *) os_label="${OSTYPE}" os_dir="" ;;
esac

# Preflight: every question, before anything changes.
PERSONA_NAME="" PERSONA_SOURCE="" PERSONA_HARDEN=no INSTALL_INFO="" INSTALLS="" INSTALLS_SOURCE="" OFFERED_INSTALLS="" PENDING_INSTALLS=""
HARDEN=0 HARDEN_SOURCE="" HARDEN_GAPS=""
brew_skip_reason="Homebrew"
resolve_persona
resolve_installs
resolve_harden
if [[ -z "${DOTFILES_BREWFILES// /}" && -z "${DOTFILES_BREW_OPTIONAL// /}" && "${run_brew}" -eq 1 ]]; then
    run_brew=0
    brew_skip_reason="Homebrew (the ${PERSONA_NAME} persona installs none)"
fi
resolve_brew_picks

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
    skipped_steps+=("${brew_skip_reason}")
fi
if [[ "${run_shell_setup}" -eq 1 ]]; then
    STEP_TOTAL=$((STEP_TOTAL + 1))
else
    skipped_steps+=("login shell")
fi
[[ -z "${INSTALLS// /}" ]] || STEP_TOTAL=$((STEP_TOTAL + 1))
[[ "${HARDEN}" -eq 0 ]] || STEP_TOTAL=$((STEP_TOTAL + 1))

_header "Dotfiles setup"
_item "${run_mode} from ${BASEDIR}"
_item "Persona: ${PERSONA_NAME} (${PERSONA_SOURCE})"
if [[ "${HARDEN}" -eq 1 ]]; then
    _item "Hardening first (${HARDEN_SOURCE})"
elif [[ -n "${HARDEN_GAPS}" ]]; then
    _item "Not hardened: $(tr '\n' ';' <<< "${HARDEN_GAPS}" | sed 's/;$//; s/;/; /g')"
fi
if [[ -n "${INSTALLS// /}" ]]; then
    _item "Installs: ${INSTALLS} (${INSTALLS_SOURCE})"
elif [[ -n "${OFFERED_INSTALLS// /}" ]]; then
    _item "Installs: none chosen of ${OFFERED_INSTALLS% }"
fi
if [[ "${BREW_PICK_COUNT}" -gt 0 ]]; then
    _item "Optional Homebrew packages: ${BREW_PICK_COUNT} chosen"
fi
if [[ "${#skipped_steps[@]}" -gt 0 ]]; then
    _item "Skipping: $(printf '%s, ' "${skipped_steps[@]}" | sed 's/, $//')"
fi
if [[ "${VERBOSE}" -eq 0 ]]; then
    _item "Use --verbose to stream full command output"
fi
prime_sudo

if [[ "${HARDEN}" -eq 1 ]]; then
    begin_step "Harden" "Key-only SSH over Tailscale, ufw, unattended upgrades (scripts/bootstrap/linux/harden.sh)"
    run_harden
fi

begin_step "Repository link" "Point ~/.dotfiles at this checkout"
run_boxed ensure_dotfiles_repo_link

if [[ "${run_system_bootstrap}" -eq 1 ]]; then
    begin_step "System packages" "Run the ${os_label} bootstrap script (system tools and settings)"
    if [[ -z "${os_dir}" ]]; then
        _skip "No bootstrap for ${OSTYPE}"
    elif [[ "${dry_run}" -eq 1 ]]; then
        run_boxed bash "scripts/bootstrap/${os_dir}/setup.sh" --dry-run
    else
        bash "scripts/bootstrap/${os_dir}/setup.sh"
        _check "System bootstrap complete"
    fi
fi

# After the system bootstrap, which installs ssh-keygen on a bare Linux host.
begin_step "SSH key" "Make sure this machine has ${LOCAL_INSTALL_SSH_KEY_PATH} for GitHub and signing"
run_boxed ensure_local_install_ssh_key

if [[ "${run_brew}" -eq 1 ]]; then
    begin_step "Homebrew" "Install Homebrew if needed, then the ${DOTFILES_BREWFILES:-core} Brewfile packages"
    if [[ "${dry_run}" -eq 1 ]]; then
        run_boxed bash homebrew/brew.sh --dry-run
    else
        bash homebrew/brew.sh
        _check "Homebrew packages up to date"
    fi
fi

begin_step "Dotfiles" "Install GNU Stow if needed, then link the managed files into your home"
run_boxed ensure_stow

# Streamed, not boxed: backups of replaced files are listed as they happen,
# and the agents clone may need to show an SSH prompt.
run_streamed apply_dotfiles

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
offer_cleanup=0
file_cleanup_is_interactive && offer_cleanup=1
run_boxed review_existing_files
if [[ "${offer_cleanup}" -eq 1 ]]; then
    select_files_to_archive
fi

if [[ -n "${INSTALLS// /}" ]]; then
    begin_step "Installs" "Apply what this machine gets: ${INSTALLS}"
    run_installs
fi

if [[ "${HARDEN}" -eq 0 && -n "${HARDEN_GAPS}" ]]; then
    _next_step "Harden this machine when it is new or yours alone: ${BASEDIR}/install.sh --harden (scripts/bootstrap/linux/harden-test.sh shows what is missing)"
fi
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

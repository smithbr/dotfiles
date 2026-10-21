#!/usr/bin/env bats
# Tests for install.sh — argument parsing, ssh_key_comment, ensure_local_install_ssh_key.
# These tests source only the functions they need; they never run the full
# install flow, so they are safe and side-effect free.

load test_helper

setup() {
    setup_tmpdir
    export HOME="${TEST_TMPDIR}/home"
    mkdir -p "${HOME}"
}

teardown() {
    teardown_tmpdir
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

# Extract the real option parser from install.sh so these tests exercise the
# shipped code instead of a copy of it that can drift.
parser_snippet() {
    sed -n '/^VERBOSE="${VERBOSE:-0}"$/,/^export VERBOSE$/p' "${PROJECT_ROOT}/install.sh"
}

run_parser() {
    run bash -c "
        usage() { printf 'USAGE\n'; }
        $(parser_snippet)
        printf 'dry=%s system=%s brew=%s shell=%s verbose=%s args=%s\n' \
            \"\${dry_run}\" \"\${run_system_bootstrap}\" \"\${run_brew}\" \
            \"\${run_shell_setup}\" \"\${VERBOSE}\" \"\${link_args[*]:-}\"
    " bash "$@"
}

@test "install.sh defaults to running every step" {
    run_parser
    assert_success
    assert_output "dry=0 system=1 brew=1 shell=1 verbose=0 args="
}

@test "install.sh parses --skip-system flag" {
    run_parser --skip-system
    assert_success
    assert_output "dry=0 system=0 brew=1 shell=1 verbose=0 args="
}

@test "install.sh parses --skip-brew flag" {
    run_parser --skip-brew
    assert_success
    assert_output "dry=0 system=1 brew=0 shell=1 verbose=0 args="
}

@test "install.sh parses --skip-shell flag" {
    run_parser --skip-shell
    assert_success
    assert_output "dry=0 system=1 brew=1 shell=0 verbose=0 args="
}

@test "install.sh parses --dry-run and -n" {
    run_parser --dry-run
    assert_success
    assert_output --partial "dry=1"

    run_parser -n
    assert_success
    assert_output --partial "dry=1"
}

@test "install.sh parses --verbose and -v" {
    run_parser --verbose
    assert_success
    assert_output --partial "verbose=1"

    run_parser -v
    assert_success
    assert_output --partial "verbose=1"
}

@test "install.sh --debug turns on verbose output" {
    run_parser --debug
    assert_success
    assert_output --partial "verbose=1"
}

@test "install.sh --help prints usage and exits successfully" {
    run_parser --help
    assert_success
    assert_output "USAGE"

    run_parser -h
    assert_success
    assert_output "USAGE"
}

@test "install.sh passes unknown args through to stow" {
    run_parser --skip-system --verbose --adopt
    assert_success
    assert_output "dry=0 system=0 brew=1 shell=1 verbose=1 args=--adopt"
}

@test "install.sh passes everything after -- through to stow" {
    run_parser --skip-brew -- --skip-system --adopt
    assert_success
    assert_output "dry=0 system=1 brew=0 shell=1 verbose=0 args=--skip-system --adopt"
}

@test "install.sh always refreshes the agents checkout when linking" {
    printf '#!/usr/bin/env bash\nprintf "link.sh %%s\\n" "$*"\n' > "${TEST_TMPDIR}/link.sh"
    run bash -c "
        log_info() { :; }
        log_pending_link_changes() { :; }
        stow() { :; }
        LINK_SCRIPT='${TEST_TMPDIR}/link.sh' dry_run=0 link_args=(--adopt)
        $(sed -n '/^apply_dotfiles() {$/,/^}$/p' "${PROJECT_ROOT}/install.sh")
        apply_dotfiles
    "
    assert_success
    assert_output "link.sh --refresh -- --adopt"
}

@test "install.sh takes --persona NAME without passing it to stow" {
    run bash -c "
        usage() { :; }
        log_error() { printf 'ERROR %s\n' \"\$*\"; }
        $(parser_snippet)
        printf 'persona=%s args=%s\n' \"\${persona_arg}\" \"\${link_args[*]:-}\"
    " bash --persona work --adopt
    assert_success
    assert_output "persona=work args=--adopt"

    run bash -c "
        log_error() { printf 'ERROR %s\n' \"\$*\"; }
        $(parser_snippet)
    " bash --persona
    assert_failure 2
    assert_output --partial "--persona requires a name"
}

# Runs install.sh's persona picker without gum, answering with stdin.
run_persona_prompt() {
    local answer="$1"
    run bash -c "
        source '${PROJECT_ROOT}/scripts/common.sh'
        LINK_SCRIPT='${PROJECT_ROOT}/scripts/link.sh'
        $(sed -n '/^prompt_persona() {$/,/^}$/p' "${PROJECT_ROOT}/install.sh")
        DOTFILES_PROMPT=read prompt_persona home 2>/dev/null
    " <<< "${answer}"
}

@test "install.sh persona picker takes a number or a name and falls back to the default" {
    export DOTFILES_OS=darwin
    run_persona_prompt "3"
    assert_output "work"
    run_persona_prompt "server"
    assert_output "server"
    run_persona_prompt ""
    assert_output "home"
    run_persona_prompt "bogus"
    assert_output "home"
    run bash -c "
        source '${PROJECT_ROOT}/scripts/common.sh'
        LINK_SCRIPT='${PROJECT_ROOT}/scripts/link.sh'
        $(sed -n '/^prompt_persona() {$/,/^}$/p' "${PROJECT_ROOT}/install.sh")
        DOTFILES_PROMPT=read prompt_persona home 2>/dev/null
    " < /dev/null
    assert_output "home"
}

# Runs install.sh's resolve_persona against a stub link.sh reporting
# "server SOURCE", with on_terminal answering TERMINAL (yes or no) and stdin
# as the picker's answer.
run_resolve_persona() {
    local source="$1" terminal="$2" answer="$3"
    shift 3
    printf '#!/usr/bin/env bash\ncase "$1" in\n    persona) printf "%%s\\n" "${DOTFILES_PERSONA:-server} %s" ;;\n    personas) printf "home\\nserver\\nvps\\n" ;;\nesac\n' "${source}" > "${TEST_TMPDIR}/link.sh"
    run env "$@" bash -c "
        source '${PROJECT_ROOT}/scripts/common.sh'
        LINK_SCRIPT='${TEST_TMPDIR}/link.sh' persona_arg=''
        $(sed -n '/^prompt_persona() {$/,/^}$/p;/^on_terminal() {$/,/^}$/p;/^resolve_persona() {$/,/^}$/p' "${PROJECT_ROOT}/install.sh")
        on_terminal() { [[ '${terminal}' == yes ]]; }
        DOTFILES_PROMPT=read resolve_persona
        printf 'persona=%s source=%s env=%s\n' \"\${PERSONA_NAME}\" \"\${PERSONA_SOURCE}\" \"\${DOTFILES_PERSONA:-}\"
    " <<< "${answer}"
}

@test "install.sh confirms a saved persona on a terminal, and Enter keeps it" {
    # The picker writes to stderr, without a newline once nothing is typed.
    run_resolve_persona saved yes ""
    assert_success
    assert_output --partial "This machine is saved as server. Keep it or pick another:"
    assert_output --partial "persona=server source=chosen env=server"

    run_resolve_persona saved yes "vps"
    assert_success
    assert_output --partial "persona=vps source=chosen env=vps"

    # The OS default is asked too, with the plain question.
    run_resolve_persona default yes ""
    assert_success
    assert_output --partial "Which persona is this machine?"
    refute_output --partial "saved as"
    assert_output --partial "persona=server source=chosen env=server"
}

@test "install.sh never asks for the persona without a terminal or when a flag or env chose it" {
    run_resolve_persona saved no "vps"
    assert_success
    assert_output "persona=server source=saved env="

    run_resolve_persona env yes "vps" DOTFILES_PERSONA=home
    assert_success
    assert_output "persona=home source=env env=home"
}

# Runs install.sh's resolve_installs against a stub link.sh that offers
# docker and pihole (pihole applied when PIHOLE_DETECT is true) with "docker"
# saved, on_terminal answering TERMINAL (yes or no), stdin as the picker's
# answer, and any further arguments as install.sh's --install/--no-install.
run_resolve_installs() {
    local terminal="$1" answer="$2" pihole_detect="${PIHOLE_DETECT:-false}"
    shift 2
    cat > "${TEST_TMPDIR}/link.sh" <<SH
#!/usr/bin/env bash
case "\$1" in
    offered) printf 'docker\\tdefault\\tfalse\\npihole\\toptional\\t${pihole_detect}\\n' ;;
    installs)
        if [[ -n "\${DOTFILES_INSTALLS+set}" ]]; then
            printf 'installs=%s\\ninstalls_source=env\\n' "\$(xargs <<< "\${DOTFILES_INSTALLS}")"
        else
            printf 'installs=docker\\ninstalls_source=saved\\n'
        fi
        ;;
esac
SH
    run bash -c "
        source '${PROJECT_ROOT}/scripts/common.sh'
        LINK_SCRIPT='${TEST_TMPDIR}/link.sh' BASEDIR='${PROJECT_ROOT}'
        declare -a install_args=() no_install_args=()
        $(sed -n '/^install_applied() {$/,/^}$/p;/^read_installs() {$/,/^}$/p;/^pick_installs() {$/,/^}$/p;/^resolve_installs() {$/,/^}$/p' "${PROJECT_ROOT}/install.sh")
        on_terminal() { [[ '${terminal}' == yes ]]; }
        DOTFILES_PROMPT=read resolve_installs
        printf 'installs=%s source=%s pending=%s\n' \"\${INSTALLS}\" \"\${INSTALLS_SOURCE}\" \"\${PENDING_INSTALLS}\"
    " <<< "${answer}"
}

@test "install.sh asks what the machine is for, then the installs, on every terminal run" {
    # The roles (pihole) get their own question before the optional installs,
    # and a saved choice is asked again, so a role left out before is a tick away.
    run_resolve_installs yes $'1\n1'
    assert_success
    assert_output --partial "What is this machine for?"
    assert_output --partial "1) [ ] pihole"
    assert_output --partial "Installs for this machine"
    assert_output --partial "1) [x] docker"
    assert_output --partial "installs=pihole docker source=chosen pending=pihole docker "

    # Enter keeps the marks in both.
    run_resolve_installs yes $'\n'
    assert_success
    assert_output --partial "installs=docker source=chosen"

    # A role already applied is marked, so Enter keeps it.
    PIHOLE_DETECT=true run_resolve_installs yes $'\n'
    assert_success
    assert_output --partial "1) [x] pihole (applied)"
    assert_output --partial "installs=pihole docker source=chosen pending=docker "

    # An invalid answer keeps that question's marks.
    run_resolve_installs yes $'9\n'
    assert_success
    assert_output --partial "installs=docker source=chosen"

    run_resolve_installs no $'1\n1'
    assert_success
    assert_output "installs=docker source=saved pending=docker "
}

@test "install.sh applies the chosen installs last, skips applied ones, and reports a failing one" {
    local repo="${TEST_TMPDIR}/repo" installs
    mkdir -p "${repo}/scripts/bootstrap/linux"
    cp "${PROJECT_ROOT}/scripts/common.sh" "${repo}/scripts/"
    printf '#!/usr/bin/env bash\necho ran one\ntouch "${TEST_TMPDIR}/one-done"\n' > "${repo}/scripts/bootstrap/linux/one.sh"
    printf '#!/usr/bin/env bash\necho ran two\nexit 3\n' > "${repo}/scripts/bootstrap/two.sh"
    printf '#!/usr/bin/env bash\necho ran four\n' > "${repo}/scripts/bootstrap/four.sh"
    # A detect line runs with common.sh in scope, so tool_installed works there.
    installs="installs=zero one two three four
install=zero	zero	tool_installed bash
install=one	one	[[ -e '${TEST_TMPDIR}/one-done' ]]
install=two	two	false
install=three	three	false
install=four	four	false"
    run bash -c "
        source '${PROJECT_ROOT}/scripts/common.sh'
        BASEDIR='${repo}' os_dir=linux os_label=Linux dry_run=0 VERBOSE=0 INSTALL_INFO=\"\$1\"
        $(sed -n '/^run_streamed() {$/,/^}$/p;/^setup_script_path() {$/,/^}$/p;/^install_applied() {$/,/^}$/p;/^run_installs() {$/,/^}$/p' "${PROJECT_ROOT}/install.sh")
        run_installs
    " bash "${installs}" < /dev/null
    assert_success
    assert_line "  ok: zero already applied"
    # A setup script's output streams in the step's style.
    assert_line "  ran one"
    assert_line "  ok: one applied"
    assert_line "  ran two"
    assert_line "  failed: two not applied; rerun it: bash ${repo}/scripts/bootstrap/two.sh"
    assert_line "  failed: No three setup script for Linux; three not applied"
    # A script that exits 0 without satisfying the detect is still a failure.
    assert_line "  failed: four not applied; rerun it: bash ${repo}/scripts/bootstrap/four.sh"

    run bash -c "
        source '${PROJECT_ROOT}/scripts/common.sh'
        BASEDIR='${repo}' os_dir=linux os_label=Linux dry_run=1 VERBOSE=0 INSTALL_INFO=\"\$1\"
        $(sed -n '/^run_streamed() {$/,/^}$/p;/^setup_script_path() {$/,/^}$/p;/^install_applied() {$/,/^}$/p;/^run_installs() {$/,/^}$/p' "${PROJECT_ROOT}/install.sh")
        run_installs
    " bash "${installs}" < /dev/null
    assert_success
    assert_line "  Would apply two: bash ${repo}/scripts/bootstrap/two.sh"
    refute_output --partial "ran two"
}

@test "install.sh parses --install and --no-install" {
    run bash -c "
        usage() { :; }
        log_error() { printf 'ERROR %s\n' \"\$*\"; }
        $(parser_snippet)
        printf 'installs=%s no=%s args=%s\n' \"\${install_args[*]:-}\" \"\${no_install_args[*]:-}\" \"\${link_args[*]:-}\"
    " bash --install docker --install pihole --no-install claude-code --adopt
    assert_success
    assert_output "installs=docker pihole no=claude-code args=--adopt"

    run bash -c "
        log_error() { printf 'ERROR %s\n' \"\$*\"; }
        $(parser_snippet)
    " bash --install
    assert_failure 2
    assert_output --partial "--install requires a name"
}

@test "install.sh parses --harden and --no-harden" {
    run bash -c "
        usage() { :; }
        $(parser_snippet)
        printf 'harden=%s args=%s\n' \"\${harden_arg}\" \"\${link_args[*]:-}\"
    " bash --harden --adopt
    assert_success
    assert_output "harden=yes args=--adopt"
    run bash -c "
        usage() { :; }
        $(parser_snippet)
        printf 'harden=%s\n' \"\${harden_arg}\"
    " bash --no-harden
    assert_output "harden=no"
}

# resolve_harden from install.sh against a fake repo whose harden-test.sh
# prints what HARDEN_TEST_GAPS holds. Prints HARDEN, its source, and the gaps.
run_resolve_harden() {
    local repo="${TEST_TMPDIR}/repo"
    mkdir -p "${repo}/scripts/bootstrap/linux"
    printf '#!/usr/bin/env bash\n[[ "$1" == --brief ]] || exit 2\nprintf "%%s" "${HARDEN_TEST_GAPS:-}"\n' > "${repo}/scripts/bootstrap/linux/harden-test.sh"
    run bash -c "
        source '${PROJECT_ROOT}/scripts/common.sh'
        BASEDIR='${repo}' os_dir=\"\$1\" PERSONA_HARDEN=\"\$2\" harden_arg=\"\$3\"
        $(sed -n '/^resolve_harden() {$/,/^}$/p' "${PROJECT_ROOT}/install.sh")
        resolve_harden
        printf 'harden=%s source=%s gaps=%s\n' \"\${HARDEN}\" \"\${HARDEN_SOURCE}\" \"\${HARDEN_GAPS//\$'\\n'/|}\"
    " bash "$@" < /dev/null
}

@test "install.sh offers hardening only on a Linux persona with harden=yes that the check finds unhardened" {
    # A hardened box, or a persona without harden=yes, asks nothing.
    HARDEN_TEST_GAPS="" run_resolve_harden linux yes ""
    assert_success
    assert_output "harden=0 source= gaps="
    HARDEN_TEST_GAPS=$'root can log in over SSH\nufw is not enabled' run_resolve_harden linux no ""
    assert_output "harden=0 source= gaps="
    HARDEN_TEST_GAPS=$'root can log in over SSH' run_resolve_harden macos yes ""
    assert_output "harden=0 source= gaps="

    # Unhardened with closed stdin: the gaps are reported, nothing is opted into.
    HARDEN_TEST_GAPS=$'root can log in over SSH\nufw is not enabled' run_resolve_harden linux yes ""
    assert_success
    assert_output "harden=0 source= gaps=root can log in over SSH|ufw is not enabled"
    refute_output --partial "Harden it first"
    HARDEN_TEST_GAPS=$'root can log in over SSH' run_resolve_harden linux yes no
    assert_output "harden=0 source= gaps=root can log in over SSH"

    # --harden runs harden.sh outright, without the check, and only on Linux.
    HARDEN_TEST_GAPS="" run_resolve_harden linux yes yes
    assert_success
    assert_output "harden=1 source=flag gaps="
    run_resolve_harden macos yes yes
    assert_failure 2
    assert_output --partial "The --harden option is for Linux"
}

@test "install.sh hardens first with --harden and otherwise says what the check found" {
    local repo="${TEST_TMPDIR}/repo" home="${TEST_TMPDIR}/harden-home" bin="${TEST_TMPDIR}/bin"
    mkdir -p "${repo}/scripts/bootstrap/linux" "${repo}/stow/common" "${repo}/personas" "${repo}/roles" "${home}" "${bin}"
    cp "${PROJECT_ROOT}/install.sh" "${repo}/"
    cp "${PROJECT_ROOT}/scripts/common.sh" "${PROJECT_ROOT}/scripts/link.sh" "${PROJECT_ROOT}/scripts/doctor.sh" "${repo}/scripts/"
    printf 'export DEMO=1\n' > "${repo}/stow/common/.demo"
    printf 'os=darwin,linux\nlayers=common\nagents=no\neditors=no\nharden=yes\nbrew=\nbrew_optional=\n' > "${repo}/personas/server"
    cp "${repo}/personas/server" "${repo}/personas/home"
    printf '#!/usr/bin/env bash\n[[ -e "${HOME}/.hardened" ]] && exit 0\nprintf "root can log in over SSH\\nufw is not enabled\\n"\nexit 1\n' > "${repo}/scripts/bootstrap/linux/harden-test.sh"
    printf '#!/usr/bin/env bash\necho "harden $*"\n[[ "$1" == --dry-run ]] || touch "${HOME}/.hardened"\n' > "${repo}/scripts/bootstrap/linux/harden.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${bin}/stow"
    printf '#!/usr/bin/env bash\nprintf "ssh-rsa k\\n" > "${*: -1}.pub"\ntouch "${*: -1}"\n' > "${bin}/ssh-keygen"
    chmod +x "${bin}/stow" "${bin}/ssh-keygen"
    local -a env=(PATH="${bin}:/usr/bin:/bin" HOME="${home}" HOMEBREW_PREFIX="${TEST_TMPDIR}/brew" USER=t SHELL=/bin/sh OSTYPE=linux-gnu DOTFILES_OS=linux)

    # Closed stdin: the gaps are stated up front and as a next step; harden.sh does not run.
    run env "${env[@]}" bash "${repo}/install.sh" --skip-system --skip-brew --skip-shell < /dev/null
    assert_success
    assert_output --partial "Not hardened: root can log in over SSH; ufw is not enabled"
    assert_output --partial "install.sh --harden"
    refute_output --partial "] Harden"
    refute_line --regexp "^  harden"
    [ ! -e "${home}/.hardened" ]

    # A dry run with --harden dry-runs harden.sh, first.
    run env "${env[@]}" bash "${repo}/install.sh" --skip-system --skip-brew --skip-shell --harden --dry-run < /dev/null
    assert_success
    assert_output --partial "Hardening first (flag)"
    assert_output --partial "[1/"
    assert_line --regexp "\[1/[0-9]+\] Harden"
    assert_output --partial "harden --dry-run"
    [ ! -e "${home}/.hardened" ]

    # --harden runs harden.sh with HARDEN_ARGS, before the repository link.
    run env "${env[@]}" HARDEN_ARGS="--allow 443 --cloudflare" bash "${repo}/install.sh" --skip-system --skip-brew --skip-shell --harden < /dev/null
    assert_success
    assert_line "  harden --allow 443 --cloudflare"
    assert_output --partial "ok: Hardened;"
    refute_output --partial "Not hardened"
    [ -e "${home}/.hardened" ]
    [[ "${output%%Repository link*}" == *"] Harden"* ]]

    # Hardened now: nothing is said or offered.
    run env "${env[@]}" bash "${repo}/install.sh" --skip-system --skip-brew --skip-shell < /dev/null
    assert_success
    refute_output --partial "Harden"
    refute_output --partial "Not hardened"
}

@test "install.sh rejects an unknown persona before changing anything" {
    run bash "${PROJECT_ROOT}/install.sh" --dry-run --persona nope < /dev/null
    assert_failure 2
    assert_output --partial "Unknown persona 'nope'"
    refute_output --partial "Dotfiles setup"
    [ -z "$(ls -A "${HOME}")" ]
}

@test "install.sh supports both --skip-system and --skip-brew together" {
    run_parser --skip-system --skip-brew
    assert_success
    assert_output "dry=0 system=0 brew=0 shell=1 verbose=0 args="
}

@test "install.sh --help works without any setup" {
    run "${PROJECT_ROOT}/install.sh" --help
    assert_success
    assert_output --partial "Usage: install.sh [OPTIONS]"
    assert_output --partial "--skip-brew"
    assert_output --partial "--dry-run"
}

# ---------------------------------------------------------------------------
# _box
# ---------------------------------------------------------------------------

# Run the shipped _box with a stub gum that records its arguments, so the
# tests check what width (if any) the box is asked to wrap at.
# ---------------------------------------------------------------------------
# ssh_key_comment
# ---------------------------------------------------------------------------

@test "ssh_key_comment returns user@hostname format" {
    run bash -c '
        ssh_key_comment() {
            printf "%s@%s\n" "${USER:-$(id -un)}" "$(hostname -s 2>/dev/null || hostname)"
        }
        result="$(ssh_key_comment)"
        [[ "${result}" =~ ^[^@]+@[^@]+$ ]] && echo "PASS: ${result}" || echo "FAIL: ${result}"
    '
    assert_success
    assert_output --partial "PASS:"
}

# ---------------------------------------------------------------------------
# ensure_local_install_ssh_key
# ---------------------------------------------------------------------------

@test "ensure_local_install_ssh_key creates .ssh dir and key pair" {
    run bash -c '
        set -euo pipefail
        export HOME="'"${HOME}"'"
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        LOCAL_INSTALL_SSH_KEY_PATH="${HOME}/.ssh/id_ed25519"

        stat_mode() {
            if stat -f %Lp "$1" >/dev/null 2>&1; then
                stat -f %Lp "$1"
            else
                stat -c %a "$1"
            fi
        }

        ssh_key_comment() {
            printf "%s@%s\n" "${USER:-$(id -un)}" "$(hostname -s 2>/dev/null || hostname)"
        }

        ensure_local_install_ssh_key() {
            local key_comment=""
            mkdir -p "${HOME}/.ssh"
            chmod 700 "${HOME}/.ssh"
            if [[ -f "${LOCAL_INSTALL_SSH_KEY_PATH}" ]]; then
                if [[ ! -f "${LOCAL_INSTALL_SSH_KEY_PATH}.pub" ]]; then
                    ssh-keygen -y -f "${LOCAL_INSTALL_SSH_KEY_PATH}" > "${LOCAL_INSTALL_SSH_KEY_PATH}.pub"
                    chmod 644 "${LOCAL_INSTALL_SSH_KEY_PATH}.pub"
                fi
                return 0
            fi
            key_comment="$(ssh_key_comment)"
            ssh-keygen -q -t ed25519 -N "" -C "${key_comment}" -f "${LOCAL_INSTALL_SSH_KEY_PATH}"
            chmod 600 "${LOCAL_INSTALL_SSH_KEY_PATH}"
            chmod 644 "${LOCAL_INSTALL_SSH_KEY_PATH}.pub"
        }

        ensure_local_install_ssh_key

        [[ -d "${HOME}/.ssh" ]]                      || { echo "FAIL: .ssh dir missing"; exit 1; }
        [[ -f "${LOCAL_INSTALL_SSH_KEY_PATH}" ]]     || { echo "FAIL: private key missing"; exit 1; }
        [[ -f "${LOCAL_INSTALL_SSH_KEY_PATH}.pub" ]] || { echo "FAIL: public key missing"; exit 1; }

        priv_perms="$(stat_mode "${LOCAL_INSTALL_SSH_KEY_PATH}")"
        pub_perms="$(stat_mode "${LOCAL_INSTALL_SSH_KEY_PATH}.pub")"
        dir_perms="$(stat_mode "${HOME}/.ssh")"

        [[ "${priv_perms}" == "600" ]] || { echo "FAIL: private key perms ${priv_perms}"; exit 1; }
        [[ "${pub_perms}" == "644" ]]  || { echo "FAIL: public key perms ${pub_perms}"; exit 1; }
        [[ "${dir_perms}" == "700" ]]  || { echo "FAIL: .ssh dir perms ${dir_perms}"; exit 1; }

        echo "PASS"
    '
    assert_success
    assert_output --partial "PASS"
}

@test "ensure_local_install_ssh_key is idempotent when key exists" {
    run bash -c '
        set -euo pipefail
        export HOME="'"${HOME}"'"
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        LOCAL_INSTALL_SSH_KEY_PATH="${HOME}/.ssh/id_ed25519"

        ssh_key_comment() {
            printf "%s@%s\n" "${USER:-$(id -un)}" "$(hostname -s 2>/dev/null || hostname)"
        }

        ensure_local_install_ssh_key() {
            local key_comment=""
            mkdir -p "${HOME}/.ssh"
            chmod 700 "${HOME}/.ssh"
            if [[ -f "${LOCAL_INSTALL_SSH_KEY_PATH}" ]]; then
                if [[ ! -f "${LOCAL_INSTALL_SSH_KEY_PATH}.pub" ]]; then
                    ssh-keygen -y -f "${LOCAL_INSTALL_SSH_KEY_PATH}" > "${LOCAL_INSTALL_SSH_KEY_PATH}.pub"
                    chmod 644 "${LOCAL_INSTALL_SSH_KEY_PATH}.pub"
                fi
                return 0
            fi
            key_comment="$(ssh_key_comment)"
            ssh-keygen -q -t ed25519 -N "" -C "${key_comment}" -f "${LOCAL_INSTALL_SSH_KEY_PATH}"
            chmod 600 "${LOCAL_INSTALL_SSH_KEY_PATH}"
            chmod 644 "${LOCAL_INSTALL_SSH_KEY_PATH}.pub"
        }

        ensure_local_install_ssh_key
        first_fp="$(ssh-keygen -l -f "${LOCAL_INSTALL_SSH_KEY_PATH}" | awk "{print \$2}")"

        ensure_local_install_ssh_key
        second_fp="$(ssh-keygen -l -f "${LOCAL_INSTALL_SSH_KEY_PATH}" | awk "{print \$2}")"

        [[ "${first_fp}" == "${second_fp}" ]] && echo "PASS" || echo "FAIL: key changed"
    '
    assert_success
    assert_output --partial "PASS"
}

@test "ensure_local_install_ssh_key restores missing public key" {
    run bash -c '
        set -euo pipefail
        export HOME="'"${HOME}"'"
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        LOCAL_INSTALL_SSH_KEY_PATH="${HOME}/.ssh/id_ed25519"

        ssh_key_comment() {
            printf "%s@%s\n" "${USER:-$(id -un)}" "$(hostname -s 2>/dev/null || hostname)"
        }

        ensure_local_install_ssh_key() {
            local key_comment=""
            mkdir -p "${HOME}/.ssh"
            chmod 700 "${HOME}/.ssh"
            if [[ -f "${LOCAL_INSTALL_SSH_KEY_PATH}" ]]; then
                if [[ ! -f "${LOCAL_INSTALL_SSH_KEY_PATH}.pub" ]]; then
                    ssh-keygen -y -f "${LOCAL_INSTALL_SSH_KEY_PATH}" > "${LOCAL_INSTALL_SSH_KEY_PATH}.pub"
                    chmod 644 "${LOCAL_INSTALL_SSH_KEY_PATH}.pub"
                fi
                return 0
            fi
            key_comment="$(ssh_key_comment)"
            ssh-keygen -q -t ed25519 -N "" -C "${key_comment}" -f "${LOCAL_INSTALL_SSH_KEY_PATH}"
            chmod 600 "${LOCAL_INSTALL_SSH_KEY_PATH}"
            chmod 644 "${LOCAL_INSTALL_SSH_KEY_PATH}.pub"
        }

        ensure_local_install_ssh_key
        original_key="$(awk "{print \$2}" "${LOCAL_INSTALL_SSH_KEY_PATH}.pub")"
        rm "${LOCAL_INSTALL_SSH_KEY_PATH}.pub"

        ensure_local_install_ssh_key
        restored_key="$(awk "{print \$2}" "${LOCAL_INSTALL_SSH_KEY_PATH}.pub")"

        [[ "${original_key}" == "${restored_key}" ]] && echo "PASS" || echo "FAIL: mismatch"
    '
    assert_success
    assert_output --partial "PASS"
}

@test "ensure_local_install_ssh_key leaves an agent-managed public key untouched" {
    run bash -c '
        set -euo pipefail
        export HOME="'"${HOME}"'"
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        LOCAL_INSTALL_SSH_KEY_PATH="${HOME}/.ssh/id_ed25519"

        ssh_key_comment() {
            printf "%s@%s\n" "${USER:-$(id -un)}" "$(hostname -s 2>/dev/null || hostname)"
        }

        ensure_local_install_ssh_key() {
            local key_comment=""
            mkdir -p "${HOME}/.ssh"
            chmod 700 "${HOME}/.ssh"
            if [[ -f "${LOCAL_INSTALL_SSH_KEY_PATH}" ]]; then
                if [[ ! -f "${LOCAL_INSTALL_SSH_KEY_PATH}.pub" ]]; then
                    ssh-keygen -y -f "${LOCAL_INSTALL_SSH_KEY_PATH}" > "${LOCAL_INSTALL_SSH_KEY_PATH}.pub"
                    chmod 644 "${LOCAL_INSTALL_SSH_KEY_PATH}.pub"
                fi
                return 0
            fi
            if [[ -f "${LOCAL_INSTALL_SSH_KEY_PATH}.pub" ]]; then
                return 0
            fi
            key_comment="$(ssh_key_comment)"
            ssh-keygen -q -t ed25519 -N "" -C "${key_comment}" -f "${LOCAL_INSTALL_SSH_KEY_PATH}"
            chmod 600 "${LOCAL_INSTALL_SSH_KEY_PATH}"
            chmod 644 "${LOCAL_INSTALL_SSH_KEY_PATH}.pub"
        }

        # Simulate a 1Password-style layout: public key on disk, private half
        # held by the agent (no private key file present).
        mkdir -p "${HOME}/.ssh"
        printf "ssh-ed25519 AAAAEXTERNALAGENTKEY agent@vault\n" > "${LOCAL_INSTALL_SSH_KEY_PATH}.pub"

        ensure_local_install_ssh_key

        [[ ! -f "${LOCAL_INSTALL_SSH_KEY_PATH}" ]] || { echo "FAIL: generated a private key"; exit 1; }
        grep -q "AAAAEXTERNALAGENTKEY" "${LOCAL_INSTALL_SSH_KEY_PATH}.pub" || { echo "FAIL: clobbered the agent public key"; exit 1; }
        echo "PASS"
    '
    assert_success
    assert_output --partial "PASS"
}

# ---------------------------------------------------------------------------
# install.sh exits when HOME is empty
# ---------------------------------------------------------------------------

@test "install.sh exits with error when HOME is unset" {
    run bash -c '
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        HOME=""
        if [[ -z "${HOME:-}" ]]; then
            echo "error: homeless"
            exit 1
        fi
    '
    assert_failure
    assert_output --partial "homeless"
}

# ---------------------------------------------------------------------------
# End-to-end install flow in an isolated sandbox
# ---------------------------------------------------------------------------

@test "install.sh performs setup actions inside an isolated home" {
    run bash -c '
        set -euo pipefail

        export HOME="'"${TEST_TMPDIR}"'/sandbox-home"
        export TEST_BIN="'"${TEST_TMPDIR}"'/bin"
        export TEST_LOG="'"${TEST_TMPDIR}"'/actions.log"
        export TEST_STOW_STUB="'"${TEST_TMPDIR}"'/stow.stub"
        export AGENTS_REPO_URL="file://'"${TEST_TMPDIR}"'/no-agents-repo"
        export HOMEBREW_PREFIX="'"${TEST_TMPDIR}"'/brew"
        export USER="sandbox-user"
        export SHELL="${TEST_BIN}/zsh"

        mkdir -p "${HOME}" "${TEST_BIN}"
        : > "${TEST_LOG}"
        export PATH="${TEST_BIN}:/usr/bin:/bin"

        cat > "${TEST_BIN}/hostname" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
echo "sandbox-host"
MOCK

        cat > "${TEST_BIN}/find" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
exit 0
MOCK

        cat > "${TEST_BIN}/zsh" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
exit 0
MOCK

        cat > "${TEST_BIN}/grep" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
if [[ "${*: -1}" == "/etc/shells" ]]; then
    exit 0
fi
exec /usr/bin/grep "$@"
MOCK

        cat > "${TEST_BIN}/ssh-keygen" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
set -euo pipefail

file=""
if [[ "${1:-}" == "-y" ]]; then
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f)
                file="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done
    cat "${file}.pub"
    exit 0
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f)
            file="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

printf "PRIVATE KEY\n" > "${file}"
printf "ssh-rsa sandbox-public\n" > "${file}.pub"
MOCK

        cat > "${TEST_STOW_STUB}" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
printf "stow %s\n" "$*" >> "${TEST_LOG}"
MOCK

        cat > "${TEST_BIN}/brew" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
set -euo pipefail

printf "brew %s\n" "$*" >> "${TEST_LOG}"

if [[ "${1:-}" == "install" && "${2:-}" == "stow" ]]; then
    cp "${TEST_STOW_STUB}" "${TEST_BIN}/stow"
    chmod +x "${TEST_BIN}/stow"
    exit 0
fi

exit 0
MOCK

        chmod +x "${TEST_BIN}/hostname" "${TEST_BIN}/find" "${TEST_BIN}/zsh" "${TEST_BIN}/grep" "${TEST_BIN}/ssh-keygen" "${TEST_BIN}/brew" "${TEST_STOW_STUB}"

        cd "'"${PROJECT_ROOT}"'"
        # install.sh links the physical path, which a symlinked TMPDIR changes.
        REAL_ROOT="$(pwd -P)"
        # No installs: claude-code, on by default, would run its real
        # installer; holeberry is off by default, and dropping it is harmless.
        ./install.sh --skip-system --skip-brew --no-install claude-code --no-install holeberry --adopt

        [[ -L "${HOME}/.dotfiles" ]] || { echo "missing dotfiles symlink"; exit 1; }
        [[ "$(cat "${HOME}/.local/state/dotfiles/installs")" == "" ]] || { echo "installs not saved as none"; exit 1; }
        [[ "$(readlink "${HOME}/.dotfiles")" == "${REAL_ROOT}" ]] || { echo "bad dotfiles symlink"; exit 1; }
        [[ -f "${HOME}/.ssh/id_ed25519" ]] || { echo "missing private key"; exit 1; }
        [[ -f "${HOME}/.ssh/id_ed25519.pub" ]] || { echo "missing public key"; exit 1; }
        grep -qx "brew install stow" "${TEST_LOG}" || { echo "missing brew install stow"; exit 1; }
        grep -q "^stow --dir ${REAL_ROOT}/stow --target ${HOME} --no-folding --restow .* --adopt common\( \|$\)" "${TEST_LOG}" || {
            echo "missing stow run"
            cat "${TEST_LOG}"
            exit 1
        }
        [[ "$(readlink "${HOME}/.claude/CLAUDE.md")" == "${HOME}/.config/agents/AGENTS.md" ]] || { echo "missing Claude agent link"; exit 1; }
        [[ ! -L "${HOME}/.claude/settings.json" ]] || { echo "settings.json is a link, not a merged file"; exit 1; }
        [[ ! -e "${HOME}/.cursor/AGENTS.md" ]] || { echo "home persona got the Cursor links"; exit 1; }
    '
    assert_success
    assert_output --partial "Persona: home (default)"
    assert_output --partial "Installs: none chosen of holeberry claude-code"
    assert_output --partial "Installing GNU Stow with Homebrew"
    assert_output --partial "Linking dotfiles from "
    assert_output --partial "Checking links before applying"
    assert_output --partial "Could not clone"
    assert_output --partial "Linking complete"
    assert_output --partial "Existing files"
    assert_output --partial "df-doctor ~"
    refute_output --partial "Archive which paths?"
    assert_output --partial "Done."
}

@test "install.sh does not create a nested self-link when repo already lives at HOME/.dotfiles" {
    run bash -c '
        set -euo pipefail

        export HOME="'"${TEST_TMPDIR}"'/sandbox-home"
        export TEST_BIN="'"${TEST_TMPDIR}"'/bin"
        export TEST_LOG="'"${TEST_TMPDIR}"'/actions.log"
        export TEST_STOW_STUB="'"${TEST_TMPDIR}"'/stow.stub"
        export AGENTS_REPO_URL="file://'"${TEST_TMPDIR}"'/no-agents-repo"
        export USER="sandbox-user"
        export SHELL="${TEST_BIN}/zsh"
        export REPO_COPY="${HOME}/.dotfiles"

        mkdir -p "${HOME}" "${TEST_BIN}" "${REPO_COPY}/scripts" "${REPO_COPY}/stow"
        : > "${TEST_LOG}"
        export PATH="${TEST_BIN}:/usr/bin:/bin"

        cp "'"${PROJECT_ROOT}"'/install.sh" "${REPO_COPY}/install.sh"
        cp "'"${PROJECT_ROOT}"'/scripts/common.sh" "${REPO_COPY}/scripts/common.sh"
        cp "'"${PROJECT_ROOT}"'/scripts/link.sh" "${REPO_COPY}/scripts/link.sh"
        cp -R "'"${PROJECT_ROOT}"'/personas" "${REPO_COPY}/personas"
        cp -R "'"${PROJECT_ROOT}"'/roles" "${REPO_COPY}/roles"

        cat > "${TEST_BIN}/hostname" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
echo "sandbox-host"
MOCK

        cat > "${TEST_BIN}/find" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
exit 0
MOCK

        cat > "${TEST_BIN}/zsh" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
exit 0
MOCK

        cat > "${TEST_BIN}/grep" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
if [[ "${*: -1}" == "/etc/shells" ]]; then
    exit 0
fi
exec /usr/bin/grep "$@"
MOCK

        cat > "${TEST_BIN}/ssh-keygen" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
set -euo pipefail

file=""
if [[ "${1:-}" == "-y" ]]; then
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f)
                file="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done
    cat "${file}.pub"
    exit 0
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f)
            file="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

printf "PRIVATE KEY\n" > "${file}"
printf "ssh-rsa sandbox-public\n" > "${file}.pub"
MOCK

        cat > "${TEST_STOW_STUB}" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
printf "stow %s\n" "$*" >> "${TEST_LOG}"
MOCK

        cat > "${TEST_BIN}/brew" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "install" && "${2:-}" == "stow" ]]; then
    cp "${TEST_STOW_STUB}" "${TEST_BIN}/stow"
    chmod +x "${TEST_BIN}/stow"
    exit 0
fi

exit 0
MOCK

        chmod +x "${TEST_BIN}/hostname" "${TEST_BIN}/find" "${TEST_BIN}/zsh" "${TEST_BIN}/grep" "${TEST_BIN}/ssh-keygen" "${TEST_BIN}/brew" "${TEST_STOW_STUB}"

        cd "${REPO_COPY}"
        DOTFILES_INSTALLS="" ./install.sh --skip-system --skip-brew --adopt

        [[ -d "${REPO_COPY}" ]] || { echo "repo copy missing"; exit 1; }
        [[ ! -e "${REPO_COPY}/.dotfiles" ]] || { echo "nested self-link created"; exit 1; }
    '
    assert_success
    assert_output --partial "Dotfiles repo already linked at"
}

@test "install.sh applies the default and chosen installs, records them, and skips them on the next run" {
    local repo="${TEST_TMPDIR}/repo" home="${TEST_TMPDIR}/install-home" bin="${TEST_TMPDIR}/bin"
    mkdir -p "${repo}/scripts/bootstrap/linux" "${repo}/stow/common" "${repo}/personas" "${repo}/roles" "${home}" "${bin}"
    cp "${PROJECT_ROOT}/install.sh" "${repo}/"
    cp "${PROJECT_ROOT}/scripts/common.sh" "${PROJECT_ROOT}/scripts/link.sh" "${PROJECT_ROOT}/scripts/doctor.sh" "${repo}/scripts/"
    printf 'export DEMO=1\n' > "${repo}/stow/common/.demo"
    printf 'os=darwin,linux\nlayers=common\nagents=no\neditors=no\nbrew=\nbrew_optional=\nroles_optional=demo\n' > "${repo}/personas/home"
    cp "${repo}/personas/home" "${repo}/personas/server"
    # A role the persona offers, and an optional install (a setup script with
    # a detect line) that every persona gets, on by default.
    printf 'os=darwin,linux\ndetect=[[ -e "${HOME}/.demo-applied" ]]\n' > "${repo}/roles/demo"
    printf '#!/usr/bin/env bash\necho demo running\ntouch "${HOME}/.demo-applied"\n' > "${repo}/scripts/bootstrap/demo.sh"
    printf '#!/usr/bin/env bash\n# detect: tool_installed tool\necho tool running\nmkdir -p "${HOME}/.local/bin"\nprintf "#!/bin/sh\\n" > "${HOME}/.local/bin/tool"\nchmod +x "${HOME}/.local/bin/tool"\n' > "${repo}/scripts/bootstrap/tool.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${bin}/stow"
    printf '#!/usr/bin/env bash\nprintf "ssh-rsa k\\n" > "${*: -1}.pub"\ntouch "${*: -1}"\n' > "${bin}/ssh-keygen"
    chmod +x "${bin}/stow" "${bin}/ssh-keygen"

    run env PATH="${bin}:/usr/bin:/bin" HOME="${home}" HOMEBREW_PREFIX="${TEST_TMPDIR}/brew" USER=t SHELL=/bin/sh \
        bash "${repo}/install.sh" --skip-system --skip-brew --skip-shell --install demo < /dev/null
    assert_success
    assert_output --partial "Installs: tool demo (flag)"
    assert_output --partial "] Installs"
    assert_output --partial "Applying tool"
    assert_output --partial "Applying demo"
    # The setup script's output streams in the step's style.
    assert_line "  tool running"
    assert_line "  demo running"
    assert_output --partial "ok: tool applied"
    assert_output --partial "ok: demo applied"
    [ "$(cat "${home}/.local/state/dotfiles/installs")" = "tool demo" ]
    [ -e "${home}/.demo-applied" ]
    [ -x "${home}/.local/bin/tool" ]

    # Saved: no flag needed, and an applied install is not run again.
    run env PATH="${bin}:/usr/bin:/bin" HOME="${home}" HOMEBREW_PREFIX="${TEST_TMPDIR}/brew" USER=t SHELL=/bin/sh \
        bash "${repo}/install.sh" --skip-system --skip-brew --skip-shell < /dev/null
    assert_success
    assert_output --partial "Installs: tool demo (saved)"
    assert_output --partial "ok: tool already applied"
    assert_output --partial "ok: demo already applied"
    refute_output --partial "running"

    # --no-install drops from the saved choice, the default install included.
    run env PATH="${bin}:/usr/bin:/bin" HOME="${home}" HOMEBREW_PREFIX="${TEST_TMPDIR}/brew" USER=t SHELL=/bin/sh \
        bash "${repo}/install.sh" --skip-system --skip-brew --skip-shell --no-install demo < /dev/null
    assert_success
    assert_output --partial "Installs: tool (flag)"
    [ "$(cat "${home}/.local/state/dotfiles/installs")" = "tool" ]
    run env PATH="${bin}:/usr/bin:/bin" HOME="${home}" HOMEBREW_PREFIX="${TEST_TMPDIR}/brew" USER=t SHELL=/bin/sh \
        bash "${repo}/install.sh" --skip-system --skip-brew --skip-shell --no-install tool < /dev/null
    assert_success
    assert_output --partial "Installs: none chosen of tool demo"
    [ "$(cat "${home}/.local/state/dotfiles/installs")" = "" ]

    # A fresh machine with closed stdin gets the default install only.
    run env PATH="${bin}:/usr/bin:/bin" HOME="${TEST_TMPDIR}/fresh-home" HOMEBREW_PREFIX="${TEST_TMPDIR}/brew" USER=t SHELL=/bin/sh \
        bash "${repo}/install.sh" --skip-system --skip-brew --skip-shell --dry-run < /dev/null
    assert_success
    assert_output --partial "Installs: tool (default)"
    assert_output --partial "Would apply tool: bash "
    refute_output --partial "Would apply demo"

    # An install the persona does not offer is refused before anything changes.
    run env PATH="${bin}:/usr/bin:/bin" HOME="${TEST_TMPDIR}/other-home" HOMEBREW_PREFIX="${TEST_TMPDIR}/brew" USER=t SHELL=/bin/sh \
        bash "${repo}/install.sh" --skip-system --skip-brew --skip-shell --install nope < /dev/null
    assert_failure 2
    assert_output --partial "does not offer install 'nope'"
    [ ! -e "${TEST_TMPDIR}/other-home/.dotfiles" ]
}

@test "install.sh --dry-run reports changes without touching the system" {
    run bash -c '
        set -euo pipefail

        export HOME="'"${TEST_TMPDIR}"'/dryrun-home"
        export TEST_BIN="'"${TEST_TMPDIR}"'/bin"
        export TEST_LOG="'"${TEST_TMPDIR}"'/actions.log"
        export USER="sandbox-user"
        export SHELL="${TEST_BIN}/zsh"

        mkdir -p "${HOME}" "${TEST_BIN}"
        : > "${TEST_LOG}"
        export PATH="${TEST_BIN}:/usr/bin:/bin"

        cat > "${TEST_BIN}/hostname" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
echo "sandbox-host"
MOCK

        cat > "${TEST_BIN}/find" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
exit 0
MOCK

        cat > "${TEST_BIN}/zsh" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
exit 0
MOCK

        cat > "${TEST_BIN}/grep" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
if [[ "${*: -1}" == "/etc/shells" ]]; then
    exit 0
fi
exec /usr/bin/grep "$@"
MOCK

        # Mutating commands only record that they ran; a dry run must not call them.
        cat > "${TEST_BIN}/ssh-keygen" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
printf "ssh-keygen %s\n" "$*" >> "${TEST_LOG}"
MOCK

        cat > "${TEST_BIN}/brew" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
printf "brew %s\n" "$*" >> "${TEST_LOG}"
MOCK

        cat > "${TEST_BIN}/chsh" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
printf "chsh %s\n" "$*" >> "${TEST_LOG}"
MOCK

        cat > "${TEST_BIN}/stow" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
printf "stow %s\n" "$*" >> "${TEST_LOG}"
MOCK

        chmod +x "${TEST_BIN}/hostname" "${TEST_BIN}/find" "${TEST_BIN}/zsh" "${TEST_BIN}/grep" "${TEST_BIN}/ssh-keygen" "${TEST_BIN}/brew" "${TEST_BIN}/chsh" "${TEST_BIN}/stow"

        cat > "${TEST_BIN}/xcode-select" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
exit 1
MOCK

        chmod +x "${TEST_BIN}/xcode-select"
        cd "'"${PROJECT_ROOT}"'"
        OSTYPE=darwin24 ./install.sh --dry-run

        [[ ! -e "${HOME}/.dotfiles" ]] || { echo "FAIL: created the dotfiles symlink"; exit 1; }
        [[ ! -e "${HOME}/.ssh" ]] || { echo "FAIL: created the .ssh directory"; exit 1; }
        grep -q "^stow .*--simulate" "${TEST_LOG}" || {
            echo "FAIL: stow did not run in simulate mode"
            cat "${TEST_LOG}"
            exit 1
        }
        ! grep -q "^ssh-keygen " "${TEST_LOG}" || { echo "FAIL: ran ssh-keygen"; exit 1; }
        # Homebrew is only asked what is installed, never to install.
        ! grep -q "^brew \(bundle install\|install\)" "${TEST_LOG}" || { echo "FAIL: ran brew install"; exit 1; }
        grep -q "^brew bundle check" "${TEST_LOG}" || { echo "FAIL: did not check the Brewfiles"; exit 1; }
        ! grep -q "^chsh " "${TEST_LOG}" || { echo "FAIL: ran chsh"; exit 1; }
        # find is mocked above; use the real one to prove HOME is untouched.
        [[ -z "$(/usr/bin/find "${HOME}" -mindepth 1 -print)" ]] || { echo "FAIL: wrote into HOME"; /usr/bin/find "${HOME}"; exit 1; }
    '
    assert_success
    assert_output --partial "Installs: claude-code (default)"
    refute_output --partial "Installs: holeberry"
    assert_output --partial "Would link "
    assert_output --partial "Would install the Xcode Command Line Tools"
    assert_output --partial "Would create an SSH key at "
    assert_output --partial "Would offer from Brewfile.macos"
    assert_output --partial "Would apply claude-code: bash "
}

# ---------------------------------------------------------------------------
# explain_overwrite_prompts
# ---------------------------------------------------------------------------

@test "run_boxed preserves failures with collected and streamed output" {
    for verbose in 0 1; do
        run bash -c '
            set -euo pipefail
            VERBOSE="$1"
            _box() { printf "%s\n" "$1"; }
            _check() { printf "ok: %s\n" "$1"; }
            _cross() { printf "failed: %s\n" "$1"; }
            eval "$(sed -n '\''/^run_boxed() {$/,/^}$/p'\'' "$PROJECT_ROOT/install.sh")"
            fail_command() { printf "command failed\n"; return 7; }
            run_boxed fail_command
        ' _ "${verbose}"
        assert_equal "${status}" 7
        assert_output --partial "command failed"
        refute_output --partial "ok:"
    done
}

@test "run_streamed indents live output, drops the INFO label, and keeps the exit status" {
    run bash -c '
        set -euo pipefail
        VERBOSE=0
        eval "$(sed -n '\''/^run_streamed() {$/,/^}$/p'\'' "$PROJECT_ROOT/install.sh")"
        talk() { printf "INFO first\n"; printf "WARN second\n" >&2; printf "no newline"; return 3; }
        run_streamed talk || printf "\nstatus=%s\n" "$?"
    '
    assert_success
    assert_line "  first"
    assert_line "  WARN second"
    assert_line "  no newline"
    assert_line "status=3"

    # Verbose runs stream the command as it is.
    run bash -c '
        set -euo pipefail
        VERBOSE=1
        eval "$(sed -n '\''/^run_streamed() {$/,/^}$/p'\'' "$PROJECT_ROOT/install.sh")"
        talk() { printf "INFO first\n"; return 3; }
        run_streamed talk || printf "status=%s\n" "$?"
    '
    assert_success
    assert_line "INFO first"
    assert_line "status=3"
}

@test "ensure_local_install_ssh_key fails clearly when ssh-keygen is missing" {
    local bin="${TEST_TMPDIR}/no-keygen-bin"
    mkdir -p "${bin}"
    ln -s "$(command -v mkdir)" "${bin}/mkdir"
    ln -s "$(command -v chmod)" "${bin}/chmod"

    run env -i HOME="${TEST_TMPDIR}/home" PATH="${bin}" "${BASH}" -c "
        set -euo pipefail
        log_info() { printf 'INFO:%s\n' \"\$*\"; }
        log_error() { printf 'ERROR:%s\n' \"\$*\"; }
        dry_run=0
        LOCAL_INSTALL_SSH_KEY_PATH=\"\${HOME}/.ssh/id_ed25519\"
        $(sed -n '/^require_ssh_keygen() {/,/^}/p;/^ensure_local_install_ssh_key() {/,/^}/p' "${PROJECT_ROOT}/install.sh")
        ensure_local_install_ssh_key
    "
    assert_failure
    assert_output --partial "ERROR:ssh-keygen is not installed"
    refute_output --partial "Creating local SSH key"
    [ ! -e "${TEST_TMPDIR}/home/.ssh/id_ed25519" ]
}

# Runs install.sh's example-copy step against a stand-in link.sh that prints
# the given managed paths slowly, the way the real one streams them.
run_example_step() {
    local fake="${TEST_TMPDIR}/fake-link.sh"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'printf "%%s\\n" "%s"\n' "$@"
        printf 'sleep 0.2\n'
        printf 'printf "%%s\\n" "%s/later/path"\n' "${HOME}"
    } > "${fake}"
    run bash -c "
        set -euo pipefail
        log_info() { printf 'INFO %s\\n' \"\$*\"; }
        log_error() { printf 'ERROR %s\\n' \"\$*\"; }
        _next_step() { printf 'NEXT %s\\n' \"\$*\"; }
        dry_run=0
        LINK_SCRIPT='${fake}'
        $(sed -n '/^copy_and_list_local_example_files() {$/,/^}$/p' "${PROJECT_ROOT}/install.sh")
        copy_and_list_local_example_files
    "
}

@test "install.sh local config step copies managed examples and names 1Password when managed" {
    mkdir -p "${HOME}/.config/git" "${HOME}/.config/1Password/ssh"
    printf 'example\n' > "${HOME}/.config/git/config.local.example"
    run_example_step "${HOME}/.config/1Password/ssh/agent.toml.example" "${HOME}/.config/git/config.local.example"
    assert_success
    assert_output --partial "Created ${HOME}/.config/git/config.local"
    assert_output --partial "~/.config/1Password/ssh/agent.toml"
    [ "$(cat "${HOME}/.config/git/config.local")" = "example" ]

    run_example_step "${HOME}/.config/git/config.local.example"
    assert_success
    refute_output --partial "1Password"
    refute_output --partial "Created"
}

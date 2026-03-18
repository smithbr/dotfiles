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
# Argument parsing (--skip-system, --skip-brew, passthrough)
# ---------------------------------------------------------------------------

@test "install.sh parses --skip-system flag" {
    run bash -c '
        run_system_bootstrap=1
        run_brew=1
        declare -a chezmoi_args=()
        set -- --skip-system
        while [[ $# -gt 0 ]]; do
            case "${1}" in
                --skip-system) run_system_bootstrap=0 ;;
                --skip-brew)   run_brew=0 ;;
                *)             chezmoi_args+=("$1") ;;
            esac
            shift
        done
        echo "system=${run_system_bootstrap} brew=${run_brew} args=${chezmoi_args[*]:-}"
    '
    assert_success
    assert_output "system=0 brew=1 args="
}

@test "install.sh parses --skip-brew flag" {
    run bash -c '
        run_system_bootstrap=1
        run_brew=1
        declare -a chezmoi_args=()
        set -- --skip-brew
        while [[ $# -gt 0 ]]; do
            case "${1}" in
                --skip-system) run_system_bootstrap=0 ;;
                --skip-brew)   run_brew=0 ;;
                *)             chezmoi_args+=("$1") ;;
            esac
            shift
        done
        echo "system=${run_system_bootstrap} brew=${run_brew} args=${chezmoi_args[*]:-}"
    '
    assert_success
    assert_output "system=1 brew=0 args="
}

@test "install.sh passes unknown args to chezmoi_args" {
    run bash -c '
        run_system_bootstrap=1
        run_brew=1
        declare -a chezmoi_args=()
        set -- --skip-system --verbose --dry-run
        while [[ $# -gt 0 ]]; do
            case "${1}" in
                --skip-system) run_system_bootstrap=0 ;;
                --skip-brew)   run_brew=0 ;;
                *)             chezmoi_args+=("$1") ;;
            esac
            shift
        done
        echo "system=${run_system_bootstrap} brew=${run_brew} args=${chezmoi_args[*]:-}"
    '
    assert_success
    assert_output "system=0 brew=1 args=--verbose --dry-run"
}

@test "install.sh supports both --skip-system and --skip-brew together" {
    run bash -c '
        run_system_bootstrap=1
        run_brew=1
        declare -a chezmoi_args=()
        set -- --skip-system --skip-brew
        while [[ $# -gt 0 ]]; do
            case "${1}" in
                --skip-system) run_system_bootstrap=0 ;;
                --skip-brew)   run_brew=0 ;;
                *)             chezmoi_args+=("$1") ;;
            esac
            shift
        done
        echo "system=${run_system_bootstrap} brew=${run_brew}"
    '
    assert_success
    assert_output "system=0 brew=0"
}

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
        LOCAL_INSTALL_SSH_KEY_PATH="${HOME}/.ssh/id_rsa"

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
            ssh-keygen -q -t rsa -b 4096 -N "" -C "${key_comment}" -f "${LOCAL_INSTALL_SSH_KEY_PATH}"
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
        LOCAL_INSTALL_SSH_KEY_PATH="${HOME}/.ssh/id_rsa"

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
            ssh-keygen -q -t rsa -b 4096 -N "" -C "${key_comment}" -f "${LOCAL_INSTALL_SSH_KEY_PATH}"
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
        LOCAL_INSTALL_SSH_KEY_PATH="${HOME}/.ssh/id_rsa"

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
            ssh-keygen -q -t rsa -b 4096 -N "" -C "${key_comment}" -f "${LOCAL_INSTALL_SSH_KEY_PATH}"
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
        export TEST_CHEZMOI_STUB="'"${TEST_TMPDIR}"'/chezmoi.stub"
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

        cat > "${TEST_CHEZMOI_STUB}" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--source" ]]; then
    source_dir="$2"
    shift 2
    case "${1:-}" in
        status)
            printf "M %s/zshrc\n" "${HOME}"
            exit 0
            ;;
        apply)
            shift
            printf "chezmoi apply --source %s %s\n" "${source_dir}" "$*" >> "${TEST_LOG}"
            exit 0
            ;;
        dump-config)
            exit 0
            ;;
    esac
fi

case "${1:-}" in
    source-path)
        printf "%s\n" "${HOME}/.dotfiles/dotfiles"
        ;;
    *)
        printf "chezmoi %s\n" "$*" >> "${TEST_LOG}"
        ;;
esac
MOCK

        cat > "${TEST_BIN}/brew" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
set -euo pipefail

printf "brew %s\n" "$*" >> "${TEST_LOG}"

if [[ "${1:-}" == "install" && "${2:-}" == "chezmoi" ]]; then
    cp "${TEST_CHEZMOI_STUB}" "${TEST_BIN}/chezmoi"
    chmod +x "${TEST_BIN}/chezmoi"
    exit 0
fi

exit 0
MOCK

        chmod +x "${TEST_BIN}/hostname" "${TEST_BIN}/find" "${TEST_BIN}/zsh" "${TEST_BIN}/grep" "${TEST_BIN}/ssh-keygen" "${TEST_BIN}/brew" "${TEST_CHEZMOI_STUB}"

        cd "'"${PROJECT_ROOT}"'"
        ./install.sh --skip-system --skip-brew --force

        [[ -L "${HOME}/.dotfiles" ]] || { echo "missing dotfiles symlink"; exit 1; }
        [[ "$(readlink "${HOME}/.dotfiles")" == "'"${PROJECT_ROOT}"'" ]] || { echo "bad dotfiles symlink"; exit 1; }
        [[ -f "${HOME}/.ssh/id_rsa" ]] || { echo "missing private key"; exit 1; }
        [[ -f "${HOME}/.ssh/id_rsa.pub" ]] || { echo "missing public key"; exit 1; }
        grep -qx "brew install chezmoi" "${TEST_LOG}" || { echo "missing brew install chezmoi"; exit 1; }
        grep -qx "chezmoi apply --source '"${PROJECT_ROOT}"'/dotfiles --force" "${TEST_LOG}" || {
            echo "missing chezmoi apply"
            cat "${TEST_LOG}"
            exit 1
        }
        [[ ! -e "${HOME}/.local/bin/chezmoi" ]] || { echo "unexpected curl install path used"; exit 1; }
    '
    assert_success
    assert_output --partial "Installing chezmoi with Homebrew"
    assert_output --partial "Applying dotfiles from "
    assert_output --partial "Checking pending chezmoi changes"
    assert_output --partial "chezmoi reports 1 pending change(s) before apply"
    assert_output --partial "chezmoi apply complete"
    assert_output --partial "Done."
}

@test "install.sh does not create a nested self-link when repo already lives at HOME/.dotfiles" {
    run bash -c '
        set -euo pipefail

        export HOME="'"${TEST_TMPDIR}"'/sandbox-home"
        export TEST_BIN="'"${TEST_TMPDIR}"'/bin"
        export TEST_LOG="'"${TEST_TMPDIR}"'/actions.log"
        export TEST_CHEZMOI_STUB="'"${TEST_TMPDIR}"'/chezmoi.stub"
        export USER="sandbox-user"
        export SHELL="${TEST_BIN}/zsh"
        export REPO_COPY="${HOME}/.dotfiles"

        mkdir -p "${HOME}" "${TEST_BIN}" "${REPO_COPY}/scripts" "${REPO_COPY}/dotfiles"
        : > "${TEST_LOG}"
        export PATH="${TEST_BIN}:/usr/bin:/bin"

        cp "'"${PROJECT_ROOT}"'/install.sh" "${REPO_COPY}/install.sh"
        cp "'"${PROJECT_ROOT}"'/scripts/common.sh" "${REPO_COPY}/scripts/common.sh"

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

        cat > "${TEST_CHEZMOI_STUB}" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--source" ]]; then
    source_dir="$2"
    shift 2
    case "${1:-}" in
        status)
            exit 0
            ;;
        apply)
            shift
            printf "chezmoi apply --source %s %s\n" "${source_dir}" "$*" >> "${TEST_LOG}"
            exit 0
            ;;
        dump-config)
            exit 0
            ;;
    esac
fi

case "${1:-}" in
    source-path)
        printf "%s\n" "${HOME}/.dotfiles/dotfiles"
        ;;
    *)
        printf "chezmoi %s\n" "$*" >> "${TEST_LOG}"
        ;;
esac
MOCK

        cat > "${TEST_BIN}/brew" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "install" && "${2:-}" == "chezmoi" ]]; then
    cp "${TEST_CHEZMOI_STUB}" "${TEST_BIN}/chezmoi"
    chmod +x "${TEST_BIN}/chezmoi"
    exit 0
fi

exit 0
MOCK

        chmod +x "${TEST_BIN}/hostname" "${TEST_BIN}/find" "${TEST_BIN}/zsh" "${TEST_BIN}/grep" "${TEST_BIN}/ssh-keygen" "${TEST_BIN}/brew" "${TEST_CHEZMOI_STUB}"

        cd "${REPO_COPY}"
        ./install.sh --skip-system --skip-brew --force

        [[ -d "${REPO_COPY}" ]] || { echo "repo copy missing"; exit 1; }
        [[ ! -e "${REPO_COPY}/.dotfiles" ]] || { echo "nested self-link created"; exit 1; }
    '
    assert_success
    assert_output --partial "Dotfiles repo already linked at"
}

@test "install.sh does not warn when chezmoi source-path resolves through the dotfiles symlink" {
    run bash -c '
        set -euo pipefail

        export HOME="'"${TEST_TMPDIR}"'/sandbox-home"
        export TEST_BIN="'"${TEST_TMPDIR}"'/bin"
        export TEST_LOG="'"${TEST_TMPDIR}"'/actions.log"
        export TEST_CHEZMOI_STUB="'"${TEST_TMPDIR}"'/chezmoi.stub"
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

        cat > "${TEST_CHEZMOI_STUB}" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--source" ]]; then
    source_dir="$2"
    shift 2
    case "${1:-}" in
        status)
            exit 0
            ;;
        apply)
            shift
            printf "chezmoi apply --source %s %s\n" "${source_dir}" "$*" >> "${TEST_LOG}"
            exit 0
            ;;
        dump-config)
            exit 0
            ;;
    esac
fi

case "${1:-}" in
    source-path)
        printf "%s\n" "'"${PROJECT_ROOT}"'/dotfiles"
        ;;
    *)
        printf "chezmoi %s\n" "$*" >> "${TEST_LOG}"
        ;;
esac
MOCK

        cat > "${TEST_BIN}/brew" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "install" && "${2:-}" == "chezmoi" ]]; then
    cp "${TEST_CHEZMOI_STUB}" "${TEST_BIN}/chezmoi"
    chmod +x "${TEST_BIN}/chezmoi"
    exit 0
fi

exit 0
MOCK

        chmod +x "${TEST_BIN}/hostname" "${TEST_BIN}/find" "${TEST_BIN}/zsh" "${TEST_BIN}/grep" "${TEST_BIN}/ssh-keygen" "${TEST_BIN}/brew" "${TEST_CHEZMOI_STUB}"

        cd "'"${PROJECT_ROOT}"'"
        ./install.sh --skip-system --skip-brew --force
    '
    assert_success
    refute_output --partial "WARN chezmoi sourceDir is not set to"
}

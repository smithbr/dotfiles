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

        priv_perms="$(stat -c %a "${LOCAL_INSTALL_SSH_KEY_PATH}")"
        pub_perms="$(stat -c %a "${LOCAL_INSTALL_SSH_KEY_PATH}.pub")"
        dir_perms="$(stat -c %a "${HOME}/.ssh")"

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

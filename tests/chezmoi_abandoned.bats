#!/usr/bin/env bats

load test_helper

setup() {
    setup_tmpdir

    export HOME="${TEST_TMPDIR}/home"
    export CHEZMOI_STUB_LOG="${TEST_TMPDIR}/chezmoi.log"
    mkdir -p "${HOME}/.config/git" "${HOME}/.config/agents" "${HOME}/.local/bin" "${HOME}/Documents"
    printf 'local override\n' > "${HOME}/.config/git/config.local"
    printf 'tool cache\n' > "${HOME}/.config/agents/tools"
    printf 'extra binary\n' > "${HOME}/.local/bin/ph-extra"
    printf 'noise\n' > "${HOME}/Documents/todo.txt"

    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/chezmoi" <<'MOCK'
#!/usr/bin/env bash

set -euo pipefail

source_dir=""
subcommand=""
last_arg=""
args=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source)
            source_dir="$2"
            shift 2
            ;;
        managed|status|unmanaged)
            subcommand="$1"
            shift
            break
            ;;
        *)
            shift
            ;;
    esac
done

while [[ $# -gt 0 ]]; do
    args+=("$1")
    last_arg="$1"
    shift
done

case "${subcommand}" in
    managed)
        cat <<EOF
${HOME}/.bashrc
${HOME}/.config/git
${HOME}/.config/git/config
${HOME}/.config/agents/skills
${HOME}/.config/agents/rules/00-meta.md
${HOME}/.local/bin/ph-padd
EOF
        ;;
    status)
        if [[ "${TEST_CHEZMOI_STATUS:-}" == "dirty" ]]; then
            printf ' M %s\n' "${HOME}/.local/bin/ph-padd"
        fi
        ;;
    unmanaged)
        printf '%s\n' "${last_arg}" >> "${CHEZMOI_STUB_LOG}"
        case "${last_arg}" in
            "${HOME}/.config/git")
                printf '%s\n' "${HOME}/.config/git/config.local"
                ;;
            "${HOME}/.config/agents")
                printf '%s\n' "${HOME}/.config/agents/tools"
                ;;
            "${HOME}/.local/bin")
                printf '%s\n' "${HOME}/.local/bin/ph-extra"
                ;;
        esac
        ;;
    *)
        exit 1
        ;;
esac
MOCK
    chmod +x "${TEST_TMPDIR}/bin/chezmoi"

    export PATH="${TEST_TMPDIR}/bin:/usr/bin:/bin"
    export TEST_SOURCE_DIR="${TEST_TMPDIR}/source/dotfiles"
    mkdir -p "${TEST_SOURCE_DIR}"
}

teardown() {
    teardown_tmpdir
}

@test "chezmoi-abandoned highlights unmanaged neighbors without scanning home" {
    run "${PROJECT_ROOT}/scripts/chezmoi-abandoned.sh" --source "${TEST_SOURCE_DIR}"
    assert_success
    assert_output --partial "Managed drift: none"
    assert_output --partial "Potential leftovers:"
    # shellcheck disable=SC2088
    assert_output --partial "$(printf '%s' '~/.config/agents')"
    # shellcheck disable=SC2088
    assert_output --partial "$(printf '%s' '~/.config/agents/tools')"
    # shellcheck disable=SC2088
    assert_output --partial "$(printf '%s' '~/.local/bin')"
    # shellcheck disable=SC2088
    assert_output --partial "$(printf '%s' '~/.local/bin/ph-extra')"
    assert_output --partial "Hidden local/runtime files by default:"
    assert_output --partial "action: usually ignore these unless you now want to start managing them"
    refute_output --partial "${HOME}/Documents/todo.txt"

    run cat "${CHEZMOI_STUB_LOG}"
    assert_success
    [[ "${output}" != "${HOME}" ]]
    [[ "${output}" != *$'\n'"${HOME}"$'\n'* ]]
    assert_output --partial "${HOME}/.config/agents"
    assert_output --partial "${HOME}/.config/git"
    assert_output --partial "${HOME}/.local/bin"
}

@test "chezmoi-abandoned prints managed drift when chezmoi reports it" {
    run env TEST_CHEZMOI_STATUS="dirty" \
        "${PROJECT_ROOT}/scripts/chezmoi-abandoned.sh" --source "${TEST_SOURCE_DIR}"
    assert_success
    assert_output --partial "Managed drift:"
    # shellcheck disable=SC2088
    assert_output --partial "$(printf '%s' '~/.local/bin/ph-padd')"
    assert_output --partial "action: diff the local file against the repo"
}

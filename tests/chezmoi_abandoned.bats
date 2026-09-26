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
dest_dir="${HOME}"
subcommand=""
last_arg=""
args=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source)
            source_dir="$2"
            shift 2
            ;;
        --destination)
            dest_dir="$2"
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

if [[ "${TEST_CHEZMOI_FAIL:-}" == "${subcommand}" ]]; then
    printf 'simulated %s failure\n' "${subcommand}" >&2
    exit 1
fi

case "${subcommand}" in
    managed)
        cat <<EOF
${dest_dir}/.bashrc
${dest_dir}/.config/git
${dest_dir}/.config/git/config
${dest_dir}/.config/git/config.local.example
${dest_dir}/.config/agents/skills
${dest_dir}/.config/agents/rules/00-meta.md
${dest_dir}/.local/bin/ph-padd
EOF
        [[ -z "${TEST_MANAGED_EXTRA:-}" ]] || printf '%s\n' "${TEST_MANAGED_EXTRA}"
        ;;
    status)
        if [[ "${TEST_CHEZMOI_STATUS:-}" == "dirty" ]]; then
            printf ' M %s\n' "${dest_dir}/.local/bin/ph-padd"
        fi
        ;;
    unmanaged)
        printf '%s\n' "${last_arg}" >> "${CHEZMOI_STUB_LOG}"
        case "${last_arg}" in
            "${dest_dir}/.config/git")
                printf '%s\n' "${dest_dir}/.config/git/config.local"
                ;;
            "${dest_dir}/.config/agents")
                printf '%s\n' "${dest_dir}/.config/agents/tools"
                ;;
            "${dest_dir}/.local/bin")
                printf '%s\n' "${dest_dir}/.local/bin/ph-extra"
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

@test "chezmoi-abandoned reviews neighbors without walking home or private agents" {
    run "${PROJECT_ROOT}/scripts/chezmoi-abandoned.sh" --source "${TEST_SOURCE_DIR}"
    assert_success
    assert_output --partial "Managed drift: none"
    assert_output --partial "Potential leftovers:"
    # shellcheck disable=SC2088
    assert_output --partial "$(printf '%s' '~/.config/agents')"
    refute_output --partial "~/.config/agents/tools"
    # shellcheck disable=SC2088
    assert_output --partial "$(printf '%s' '~/.local/bin')"
    # shellcheck disable=SC2088
    assert_output --partial "$(printf '%s' '~/.local/bin/ph-extra')"
    refute_output --partial "~/.config/git/config.local\n"
    refute_output --partial "${HOME}/Documents/todo.txt"

    run cat "${CHEZMOI_STUB_LOG}"
    assert_success
    [[ "${output}" != "${HOME}" ]]
    [[ "${output}" != *$'\n'"${HOME}"$'\n'* ]]
    refute_output --partial "${HOME}/.config/agents"
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

@test "file review finds home leftovers, broken links, and saved backups without changing them" {
    mkdir -p "${HOME}/.old-tool" "${HOME}/.config/agents-backup.saved/agents"
    printf 'keep this\n' > "${HOME}/.old-tool/config"
    ln -s "${HOME}/missing-target" "${HOME}/.config/git/broken"
    export TEST_MANAGED_EXTRA="${HOME}/.config/git/broken"

    run "${PROJECT_ROOT}/scripts/chezmoi-abandoned.sh" --source "${TEST_SOURCE_DIR}"
    assert_success
    assert_output --partial "~/.old-tool"
    assert_output --partial "~/.config/git/broken -> ${HOME}/missing-target"
    assert_output --partial "~/.config/agents-backup.saved"
    assert_output --partial "Agents checkout needs attention"
    [[ -L "${HOME}/.config/git/broken" ]]
    [[ "$(cat "${HOME}/.old-tool/config")" == 'keep this' ]]
    [[ ! -e "${HOME}/.local/state/dotfiles/cleanup" ]]
}

@test "bulk cleanup archives selected directories and symlinks without following them" {
    mkdir -p "${HOME}/.old-tool" "${TEST_TMPDIR}/outside"
    printf 'keep this\n' > "${HOME}/.old-tool/config"
    printf 'outside\n' > "${TEST_TMPDIR}/outside/file"
    ln -s "${TEST_TMPDIR}/outside" "${HOME}/.old-link"

    run bash -c 'printf "1 2\n" | "$1/scripts/chezmoi-abandoned.sh" --source "$2" --cleanup' _ "${PROJECT_ROOT}" "${TEST_SOURCE_DIR}"
    assert_success
    local archives=("${HOME}/.local/state/dotfiles/cleanup/"*)
    [[ "${#archives[@]}" -eq 1 ]]
    [[ ! -e "${HOME}/.old-tool" && ! -L "${HOME}/.old-link" ]]
    [[ "$(cat "${archives[0]}/.old-tool/config")" == 'keep this' ]]
    [[ -L "${archives[0]}/.old-link" ]]
    [[ "$(cat "${TEST_TMPDIR}/outside/file")" == outside ]]
    [[ -f "${HOME}/.local/bin/ph-extra" ]]
}

@test "bulk cleanup skips closed stdin and validates the entire selection before moving" {
    printf 'keep\n' > "${HOME}/.old-file"
    run bash -c '"$1/scripts/chezmoi-abandoned.sh" --source "$2" --cleanup </dev/null' _ "${PROJECT_ROOT}" "${TEST_SOURCE_DIR}"
    assert_success
    assert_output --partial "Cleanup skipped"
    [[ -f "${HOME}/.old-file" ]]
    [[ ! -e "${HOME}/.local/state/dotfiles/cleanup" ]]

    run bash -c 'printf "1 invalid\n" | "$1/scripts/chezmoi-abandoned.sh" --source "$2" --cleanup' _ "${PROJECT_ROOT}" "${TEST_SOURCE_DIR}"
    assert_success
    assert_output --partial "Invalid selection"
    [[ -f "${HOME}/.old-file" ]]
    [[ ! -e "${HOME}/.local/state/dotfiles/cleanup" ]]
}

@test "bulk cleanup never selects managed parents, credentials, private agents, or local overrides" {
    mkdir -p "${HOME}/.ssh" "${HOME}/.owned" "${HOME}/.dotfiles"
    printf 'private\n' > "${HOME}/.ssh/secret"
    printf 'managed\n' > "${HOME}/.owned/file"
    export TEST_MANAGED_EXTRA="${HOME}/.owned/file"
    run bash -c 'printf "all\n" | "$1/scripts/chezmoi-abandoned.sh" --source "$2" --cleanup' _ "${PROJECT_ROOT}" "${TEST_SOURCE_DIR}"
    assert_success
    [[ -f "${HOME}/.ssh/secret" ]]
    [[ -f "${HOME}/.owned/file" ]]
    [[ -f "${HOME}/.config/agents/tools" ]]
    [[ -f "${HOME}/.config/git/config.local" ]]
    [[ -d "${HOME}/.dotfiles" ]]
    [[ ! -e "${HOME}/.local/bin/ph-extra" ]]
}

@test "failed inventory queries report an incomplete review and disable cleanup" {
    printf 'keep\n' > "${HOME}/.old-file"
    for failure in managed status unmanaged; do
        run bash -c 'printf "all\n" | env TEST_CHEZMOI_FAIL="$3" "$1/scripts/chezmoi-abandoned.sh" --source "$2" --cleanup' _ "${PROJECT_ROOT}" "${TEST_SOURCE_DIR}" "${failure}"
        assert_failure
        assert_output --partial "incomplete"
        refute_output --partial "Potential leftovers: none"
        [[ -f "${HOME}/.old-file" ]]
        [[ ! -e "${HOME}/.local/state/dotfiles/cleanup" ]]
    done
}

@test "cleanup respects a separate destination and does not change HOME" {
    local destination="${TEST_TMPDIR}/destination"
    mkdir -p "${destination}"
    printf 'target\n' > "${destination}/.old-file"
    printf 'home\n' > "${HOME}/.old-file"
    run bash -c 'printf "all\n" | "$1/scripts/chezmoi-abandoned.sh" --source "$2" --destination "$3" --cleanup' _ "${PROJECT_ROOT}" "${TEST_SOURCE_DIR}" "${destination}"
    assert_success
    [[ ! -e "${destination}/.old-file" ]]
    [[ "$(cat "${HOME}/.old-file")" == home ]]
    local archives=("${destination}/.local/state/dotfiles/cleanup/"*)
    [[ "$(cat "${archives[0]}/.old-file")" == target ]]
}

@test "second cleanup does not offer the existing archive again" {
    printf 'old\n' > "${HOME}/.old-file"
    run bash -c 'printf "all\n" | "$1/scripts/chezmoi-abandoned.sh" --source "$2" --cleanup' _ "${PROJECT_ROOT}" "${TEST_SOURCE_DIR}"
    assert_success
    run bash -c 'printf "all\n" | "$1/scripts/chezmoi-abandoned.sh" --source "$2" --cleanup' _ "${PROJECT_ROOT}" "${TEST_SOURCE_DIR}"
    assert_success
    refute_output --partial "Archive candidates"
    assert_output --partial "Saved migration backups:"
    local archives=("${HOME}/.local/state/dotfiles/cleanup/"*)
    [[ "${#archives[@]}" -eq 1 ]]
    [[ -f "${archives[0]}/.old-file" ]]
}

@test "installer reviews existing files with closed stdin and leaves leftovers untouched" {
    printf 'keep\n' > "${HOME}/.old-file"
    run bash -c '
        source "$PROJECT_ROOT/scripts/common.sh"
        eval "$(sed -n '\''/^review_existing_files() {$/,/^}$/p'\'' "$PROJECT_ROOT/install.sh")"
        BASEDIR="$PROJECT_ROOT"
        CHEZMOI_SOURCE="$TEST_SOURCE_DIR"
        dry_run=0
        chezmoi_args=()
        review_existing_files </dev/null
    '
    assert_success
    assert_output --partial "~/.old-file"
    refute_output --partial "Archive which paths?"
    [[ -f "${HOME}/.old-file" ]]
    [[ ! -e "${HOME}/.local/state/dotfiles/cleanup" ]]
}

@test "installer dry-run review uses the forwarded destination without archiving" {
    local destination="${TEST_TMPDIR}/other-home"
    mkdir -p "${destination}"
    printf 'target\n' > "${destination}/.old-file"
    run bash -c '
        source "$PROJECT_ROOT/scripts/common.sh"
        eval "$(sed -n '\''/^review_existing_files() {$/,/^}$/p'\'' "$PROJECT_ROOT/install.sh")"
        BASEDIR="$PROJECT_ROOT"
        CHEZMOI_SOURCE="$TEST_SOURCE_DIR"
        dry_run=1
        chezmoi_args=(--destination "$1")
        review_existing_files
    ' _ "${destination}"
    assert_success
    assert_output --partial "${destination}/.old-file"
    refute_output --partial "Archive which paths?"
    [[ -f "${destination}/.old-file" ]]
    [[ ! -e "${destination}/.local/state/dotfiles/cleanup" ]]
}

@test "installer surfaces failed file review instead of claiming a clean machine" {
    run env TEST_CHEZMOI_FAIL=managed bash -c '
        source "$PROJECT_ROOT/scripts/common.sh"
        eval "$(sed -n '\''/^review_existing_files() {$/,/^}$/p'\'' "$PROJECT_ROOT/install.sh")"
        BASEDIR="$PROJECT_ROOT"
        CHEZMOI_SOURCE="$TEST_SOURCE_DIR"
        dry_run=0
        chezmoi_args=()
        review_existing_files </dev/null
    '
    assert_success
    assert_output --partial "File review incomplete"
    refute_output --partial "Potential leftovers: none"
}

@test "cleanup does not move files through a symlinked parent" {
    mv "${HOME}/.local/bin" "${TEST_TMPDIR}/outside-bin"
    ln -s "${TEST_TMPDIR}/outside-bin" "${HOME}/.local/bin"
    run bash -c 'printf "all\n" | "$1/scripts/chezmoi-abandoned.sh" --source "$2" --cleanup' _ "${PROJECT_ROOT}" "${TEST_SOURCE_DIR}"
    assert_success
    [[ -f "${TEST_TMPDIR}/outside-bin/ph-extra" ]]
    [[ -L "${HOME}/.local/bin" ]]
    [[ ! -e "${HOME}/.local/state/dotfiles/cleanup" ]]
}

@test "cleanup refuses a symlinked archive directory" {
    mkdir -p "${TEST_TMPDIR}/outside-state"
    ln -s "${TEST_TMPDIR}/outside-state" "${HOME}/.local/state"
    run bash -c 'printf "all\n" | "$1/scripts/chezmoi-abandoned.sh" --source "$2" --cleanup' _ "${PROJECT_ROOT}" "${TEST_SOURCE_DIR}"
    assert_failure
    assert_output --partial "Archive parent is a symlink"
    [[ -f "${HOME}/.local/bin/ph-extra" ]]
    [[ ! -e "${TEST_TMPDIR}/outside-state/dotfiles" ]]
}

@test "cleanup protects the source repository's parent directory" {
    mkdir -p "${HOME}/.sources/dotfiles"
    run bash -c 'printf "all\n" | "$1/scripts/chezmoi-abandoned.sh" --source "$2" --cleanup' _ "${PROJECT_ROOT}" "${HOME}/.sources/dotfiles"
    assert_success
    [[ -d "${HOME}/.sources/dotfiles" ]]
}

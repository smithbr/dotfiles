#!/usr/bin/env bats

load test_helper

setup() {
    setup_tmpdir

    export HOME="${TEST_TMPDIR}/home"
    mkdir -p "${HOME}/.config/git" "${HOME}/.config/agents" "${HOME}/.local/bin" "${HOME}/Documents"
    printf 'local override\n' > "${HOME}/.config/git/config.local"
    printf 'tool cache\n' > "${HOME}/.config/agents/tools"
    printf 'extra binary\n' > "${HOME}/.local/bin/ph-extra"
    printf 'noise\n' > "${HOME}/Documents/todo.txt"

    # A minimal dotfiles repo, linked into HOME the way link.sh leaves it.
    export TEST_SOURCE_DIR="${TEST_TMPDIR}/source"
    local relative
    for relative in .bashrc .config/git/config .config/git/config.local.example .local/bin/ph-padd; do
        mkdir -p "$(dirname "${TEST_SOURCE_DIR}/stow/common/${relative}")"
        printf 'managed\n' > "${TEST_SOURCE_DIR}/stow/common/${relative}"
        ln -s "${TEST_SOURCE_DIR}/stow/common/${relative}" "${HOME}/${relative}"
    done
    mkdir -p "${HOME}/.config/agents/skills" "${HOME}/.agents/skills"
    for relative in .cursor/skills; do
        mkdir -p "$(dirname "${HOME}/${relative}")"
        ln -s "${HOME}/.agents/skills" "${HOME}/${relative}"
    done
    for relative in .codex/AGENTS.md .cursor/AGENTS.md; do
        mkdir -p "$(dirname "${HOME}/${relative}")"
        ln -s "${HOME}/.config/agents/AGENTS.md" "${HOME}/${relative}"
    done
    mkdir -p "${HOME}/.config/agents/agents"
    ln -s "${HOME}/.config/agents/agents" "${HOME}/.cursor/agents"
    printf 'agents\n' > "${HOME}/.config/agents/AGENTS.md"
    rm "${HOME}/.config/agents/tools"
    mkdir -p "${HOME}/.config/agents/tools/cursor"
    printf '{}\n' > "${HOME}/.config/agents/tools/cursor/cli-config.json"
    printf '{"version":1,"hooks":{}}\n' > "${HOME}/.config/agents/tools/cursor/hooks.json"
    # Real files, merged from the managed settings by link.sh.
    printf '{}\n' > "${HOME}/.cursor/cli-config.json"
    printf '{"version":1,"hooks":{}}\n' > "${HOME}/.cursor/hooks.json"
    printf 'tool cache\n' > "${HOME}/.config/agents/tools/cache"

    export PATH="/usr/bin:/bin"
}

teardown() {
    teardown_tmpdir
}

@test "file review lists unmanaged neighbors without walking home or private agents" {
    run "${PROJECT_ROOT}/scripts/file-review.sh" --source "${TEST_SOURCE_DIR}"
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
    refute_output --partial "~/.config/git/config.local"$'\n'
    refute_output --partial "todo.txt"
}

@test "file review explains a real file where a link belongs" {
    rm "${HOME}/.local/bin/ph-padd"
    printf 'edited copy\n' > "${HOME}/.local/bin/ph-padd"

    run "${PROJECT_ROOT}/scripts/file-review.sh" --source "${TEST_SOURCE_DIR}"
    assert_success
    assert_output --partial "Managed drift:"
    # shellcheck disable=SC2088
    assert_output --partial "$(printf '%s' '~/.local/bin/ph-padd')"
    assert_output --partial "action: diff the local file against the repo"
}

@test "file review explains drifted Cursor config" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    printf '{"approvalMode":"allowlist"}\n' > "${HOME}/.config/agents/tools/cursor/cli-config.json"

    run "${PROJECT_ROOT}/scripts/file-review.sh" --source "${TEST_SOURCE_DIR}"
    assert_success
    # shellcheck disable=SC2088
    assert_output --partial "$(printf '%s' '~/.cursor/cli-config.json')"
    assert_output --partial "status: a managed setting was changed or removed here"
    [[ "$(cat "${HOME}/.cursor/cli-config.json")" == '{}' ]]
}

@test "file review finds home leftovers, broken links, and saved backups without changing them" {
    mkdir -p "${HOME}/.old-tool" "${HOME}/.config/agents-backup.saved/agents"
    printf 'keep this\n' > "${HOME}/.old-tool/config"
    ln -s "${HOME}/missing-target" "${HOME}/.config/git/broken"
    printf 'managed\n' > "${TEST_SOURCE_DIR}/stow/common/.config/git/broken"

    run "${PROJECT_ROOT}/scripts/file-review.sh" --source "${TEST_SOURCE_DIR}"
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

    run bash -c 'printf "1 2\n" | "$1/scripts/file-review.sh" --source "$2" --cleanup' _ "${PROJECT_ROOT}" "${TEST_SOURCE_DIR}"
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
    run bash -c '"$1/scripts/file-review.sh" --source "$2" --cleanup </dev/null' _ "${PROJECT_ROOT}" "${TEST_SOURCE_DIR}"
    assert_success
    assert_output --partial "Cleanup skipped"
    [[ -f "${HOME}/.old-file" ]]
    [[ ! -e "${HOME}/.local/state/dotfiles/cleanup" ]]

    run bash -c 'printf "1 invalid\n" | "$1/scripts/file-review.sh" --source "$2" --cleanup' _ "${PROJECT_ROOT}" "${TEST_SOURCE_DIR}"
    assert_success
    assert_output --partial "Invalid selection"
    [[ -f "${HOME}/.old-file" ]]
    [[ ! -e "${HOME}/.local/state/dotfiles/cleanup" ]]
}

@test "bulk cleanup never selects managed parents, credentials, private agents, or local overrides" {
    mkdir -p "${HOME}/.ssh" "${HOME}/.owned" "${HOME}/.dotfiles"
    printf 'private\n' > "${HOME}/.ssh/secret"
    printf 'managed\n' > "${HOME}/.owned/file"
    mkdir -p "${TEST_SOURCE_DIR}/stow/common/.owned"
    printf 'managed\n' > "${TEST_SOURCE_DIR}/stow/common/.owned/file"
    run bash -c 'printf "all\n" | "$1/scripts/file-review.sh" --source "$2" --cleanup' _ "${PROJECT_ROOT}" "${TEST_SOURCE_DIR}"
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
    # A source without stow/ makes link.sh fail to list managed paths.
    mkdir -p "${TEST_TMPDIR}/not-a-repo"
    run bash -c 'printf "all\n" | "$1/scripts/file-review.sh" --source "$2" --cleanup' _ "${PROJECT_ROOT}" "${TEST_TMPDIR}/not-a-repo"
    assert_failure
    assert_output --partial "incomplete"
    refute_output --partial "Potential leftovers: none"
    [[ -f "${HOME}/.old-file" ]]
    [[ ! -e "${HOME}/.local/state/dotfiles/cleanup" ]]
}

@test "cleanup respects a separate destination and does not change HOME" {
    local destination="${TEST_TMPDIR}/destination"
    mkdir -p "${destination}"
    printf 'target\n' > "${destination}/.old-file"
    printf 'home\n' > "${HOME}/.old-file"
    run bash -c 'printf "all\n" | "$1/scripts/file-review.sh" --source "$2" --destination "$3" --cleanup' _ "${PROJECT_ROOT}" "${TEST_SOURCE_DIR}" "${destination}"
    assert_success
    [[ ! -e "${destination}/.old-file" ]]
    [[ "$(cat "${HOME}/.old-file")" == home ]]
    local archives=("${destination}/.local/state/dotfiles/cleanup/"*)
    [[ "$(cat "${archives[0]}/.old-file")" == target ]]
}

@test "second cleanup does not offer the existing archive again" {
    printf 'old\n' > "${HOME}/.old-file"
    run bash -c 'printf "all\n" | "$1/scripts/file-review.sh" --source "$2" --cleanup' _ "${PROJECT_ROOT}" "${TEST_SOURCE_DIR}"
    assert_success
    run bash -c 'printf "all\n" | "$1/scripts/file-review.sh" --source "$2" --cleanup' _ "${PROJECT_ROOT}" "${TEST_SOURCE_DIR}"
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
        review_existing_files </dev/null
    '
    assert_success
    assert_output --partial "~/.old-file"
    refute_output --partial "Archive which paths?"
    [[ -f "${HOME}/.old-file" ]]
    [[ ! -e "${HOME}/.local/state/dotfiles/cleanup" ]]
}

@test "installer surfaces failed file review instead of claiming a clean machine" {
    # An install tree without stow/ cannot list what it manages.
    local broken_repo="${TEST_TMPDIR}/broken-repo"
    mkdir -p "${broken_repo}"
    cp -R "${PROJECT_ROOT}/scripts" "${broken_repo}/scripts"
    run env BROKEN_REPO="${broken_repo}" bash -c '
        source "$PROJECT_ROOT/scripts/common.sh"
        eval "$(sed -n '\''/^review_existing_files() {$/,/^}$/p'\'' "$PROJECT_ROOT/install.sh")"
        BASEDIR="$BROKEN_REPO"
        offer_cleanup=1
        review_existing_files </dev/null
        echo "offer_cleanup=${offer_cleanup}"
    '
    assert_success
    assert_output --partial "File review incomplete"
    assert_output --partial "offer_cleanup=0"
    refute_output --partial "Potential leftovers: none"
}

@test "cleanup does not move files through a symlinked parent" {
    mv "${HOME}/.local/bin" "${TEST_TMPDIR}/outside-bin"
    ln -s "${TEST_TMPDIR}/outside-bin" "${HOME}/.local/bin"
    run bash -c 'printf "all\n" | "$1/scripts/file-review.sh" --source "$2" --cleanup' _ "${PROJECT_ROOT}" "${TEST_SOURCE_DIR}"
    assert_success
    [[ -f "${TEST_TMPDIR}/outside-bin/ph-extra" ]]
    [[ -L "${HOME}/.local/bin" ]]
    [[ ! -e "${HOME}/.local/state/dotfiles/cleanup" ]]
}

@test "cleanup refuses a symlinked archive directory" {
    mkdir -p "${TEST_TMPDIR}/outside-state"
    ln -s "${TEST_TMPDIR}/outside-state" "${HOME}/.local/state"
    run bash -c 'printf "all\n" | "$1/scripts/file-review.sh" --source "$2" --cleanup' _ "${PROJECT_ROOT}" "${TEST_SOURCE_DIR}"
    assert_failure
    assert_output --partial "Archive parent is a symlink"
    [[ -f "${HOME}/.local/bin/ph-extra" ]]
    [[ ! -e "${TEST_TMPDIR}/outside-state/dotfiles" ]]
}

@test "cleanup protects the source repository's parent directory" {
    mkdir -p "${HOME}/.sources/dotfiles/stow"
    run bash -c 'printf "all\n" | "$1/scripts/file-review.sh" --source "$2" --cleanup' _ "${PROJECT_ROOT}" "${HOME}/.sources/dotfiles"
    assert_success
    [[ -d "${HOME}/.sources/dotfiles" ]]
}

# A gum stand-in: choose prints $GUM_PICK, confirm exits with $GUM_CONFIRM.
write_gum_mock() {
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/gum" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    choose)
        printf '%s\n' "$@" > "${TEST_TMPDIR}/gum-choose-args"
        [[ -z "${GUM_PICK:-}" ]] || printf '%s\n' "${GUM_PICK}"
        exit "${GUM_CHOOSE_STATUS:-0}"
        ;;
    confirm)
        printf '%s\n' "$@" > "${TEST_TMPDIR}/gum-confirm-args"
        exit "${GUM_CONFIRM:-0}"
        ;;
    log)
        shift 3
        printf '%s\n' "$*"
        ;;
esac
MOCK
    chmod +x "${TEST_TMPDIR}/bin/gum"
}

@test "select mode offers the archive picker without printing the review" {
    printf 'keep\n' > "${HOME}/.old-file"
    run bash -c 'printf "all\n" | "$1/scripts/file-review.sh" --source "$2" --select' _ "${PROJECT_ROOT}" "${TEST_SOURCE_DIR}"
    assert_success
    refute_output --partial "File review for"
    refute_output --partial "Bulk cleanup"
    assert_output --partial "Archive which paths?"
    local archives=("${HOME}/.local/state/dotfiles/cleanup/"*)
    [[ -f "${archives[0]}/.old-file" ]]
    [[ ! -e "${HOME}/.old-file" ]]
}

@test "no-cleanup-hint drops the closing cleanup hint only" {
    run "${PROJECT_ROOT}/scripts/file-review.sh" --source "${TEST_SOURCE_DIR}" --no-cleanup-hint
    assert_success
    assert_output --partial "File review for"
    refute_output --partial "Bulk cleanup"
}

@test "gum picker archives the chosen paths after confirmation" {
    write_gum_mock
    printf 'keep\n' > "${HOME}/.old-file"
    printf 'keep\n' > "${HOME}/.other-file"
    run env PATH="${TEST_TMPDIR}/bin:${PATH}" TEST_TMPDIR="${TEST_TMPDIR}" \
        FILE_REVIEW_PROMPT=gum GUM_PICK="${HOME}/.old-file" \
        "${PROJECT_ROOT}/scripts/file-review.sh" --source "${TEST_SOURCE_DIR}" --select
    assert_success
    assert_output --partial "Selected for archiving:"
    assert_output --partial "archived ~/.old-file"
    grep -Fqx -- "--no-limit" "${TEST_TMPDIR}/gum-choose-args"
    # Each option shows the path and why, and carries the real path as its value.
    grep -Eq -- "^~/\.other-file  \(review: no installed owner found, but changed today\)"$'\t'"${HOME}/\.other-file\$" "${TEST_TMPDIR}/gum-choose-args"
    grep -Fqx -- "--default=false" "${TEST_TMPDIR}/gum-confirm-args"
    [[ ! -e "${HOME}/.old-file" && -f "${HOME}/.other-file" ]]
}

@test "gum picker moves nothing when skipped, declined, or given an unknown path" {
    write_gum_mock
    printf 'keep\n' > "${HOME}/.old-file"
    local -a base=(env PATH="${TEST_TMPDIR}/bin:${PATH}" TEST_TMPDIR="${TEST_TMPDIR}" FILE_REVIEW_PROMPT=gum)
    local -a review=("${PROJECT_ROOT}/scripts/file-review.sh" --source "${TEST_SOURCE_DIR}" --select)

    run "${base[@]}" GUM_CHOOSE_STATUS=130 GUM_PICK="${HOME}/.old-file" "${review[@]}"
    assert_success
    assert_output --partial "Cleanup skipped; no files moved."

    run "${base[@]}" GUM_PICK="${HOME}/.old-file" GUM_CONFIRM=1 "${review[@]}"
    assert_success
    assert_output --partial "Cleanup skipped; no files moved."

    run "${base[@]}" GUM_PICK="${HOME}/.config" "${review[@]}"
    assert_success
    assert_output --partial "Invalid selection; no files moved"

    [[ -f "${HOME}/.old-file" ]]
    [[ ! -e "${HOME}/.local/state/dotfiles/cleanup" ]]
}

@test "interactive installer boxes the report, then archives through a separate picker" {
    printf 'keep\n' > "${HOME}/.old-file"
    run bash -c '
        source "$PROJECT_ROOT/scripts/common.sh"
        eval "$(sed -n '\''/^review_existing_files() {$/,/^}$/p;/^select_files_to_archive() {$/,/^}$/p'\'' "$PROJECT_ROOT/install.sh")"
        BASEDIR="$PROJECT_ROOT"
        offer_cleanup=1
        echo "--- report"
        review_existing_files </dev/null
        echo "--- select"
        printf "all\n" | FILE_REVIEW_PROMPT=read select_files_to_archive
    '
    assert_success
    local report="${output%%--- select*}"
    local select="${output#*--- select}"
    [[ "${report}" == *"File review for"* && "${report}" == *"~/.old-file"* ]]
    [[ "${report}" != *"Bulk cleanup"* && "${report}" != *"Archive which paths?"* ]]
    [[ "${select}" != *"File review for"* && "${select}" == *"archived ~/.old-file"* ]]
    [[ ! -e "${HOME}/.old-file" ]]
}

@test "the review sorts home dotfiles by verdict and the picker follows that order" {
    printf 'copy\n' > "${HOME}/.notes.bak"
    # .true is owned by /usr/bin/true, so it is in use; kept entries carry no size.
    mkdir -p "${HOME}/.stale-tool" "${HOME}/.fresh-tool" "${HOME}/.true"
    touch "${HOME}/.stale-tool/data" "${HOME}/.fresh-tool/data" "${HOME}/.true/data"
    find "${HOME}/.stale-tool" -exec touch -t 202001010000 {} +
    run bash -c '"$1/scripts/file-review.sh" --source "$2" --cleanup </dev/null' _ "${PROJECT_ROOT}" "${TEST_SOURCE_DIR}"
    assert_success
    assert_output --partial "most likely abandoned first"
    assert_output --regexp "Junk: [^"$'\n'"]*"$'\n'" +~/\.notes\.bak +[0-9.]+[KMG] +backup copy or OS litter"
    assert_output --regexp "~/\.stale-tool +[0-9.]+[KMG] +no installed owner, untouched [0-9]+ days"
    assert_output --regexp "~/\.fresh-tool +[0-9.]+[KMG] +no installed owner found, but changed today"
    assert_output --regexp "In use: [^"$'\n'"]*"$'\n'" +~/\.true {20,}in use by true; changed today"

    # The numbered picker lists junk, then leftovers, then entries to review.
    run bash -c 'printf "\n" | FILE_REVIEW_PROMPT=read "$1/scripts/file-review.sh" --source "$2" --select' _ "${PROJECT_ROOT}" "${TEST_SOURCE_DIR}"
    assert_success
    assert_line --regexp "^  1\) ~/\.notes\.bak  \(junk: "
    assert_line --regexp "^  2\) ~/\.stale-tool  \(leftover: no installed owner, untouched [0-9]+ days\)$"
    assert_line --regexp "^  [0-9]+\) ~/\.fresh-tool  \(review: "
    assert_line --regexp "^  [0-9]+\) ~/\.local/bin/ph-extra  \(beside managed files\)$"
    assert_output --partial "Cleanup skipped; no files moved."
    [[ -f "${HOME}/.notes.bak" && -d "${HOME}/.stale-tool" ]]
}

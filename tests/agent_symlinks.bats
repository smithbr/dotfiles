#!/usr/bin/env bats
# Tests for dotfiles/run_before_backup-agent-symlinks.sh — the guard that keeps
# `chezmoi apply` from silently deleting a real ~/.claude/settings.json (or any
# other agent config) when it replaces that path with a symlink.
#
# The script is run directly with CHEZMOI_* set, so these tests never touch the
# real home directory and never resolve the .chezmoiexternal.toml git external.

load test_helper

GUARD="dotfiles/run_before_backup-agent-symlinks.sh"

setup() {
    setup_tmpdir
    DEST="${TEST_TMPDIR}/home"
    SRC="${TEST_TMPDIR}/src"
    mkdir -p "${DEST}" "${SRC}"
}

teardown() {
    teardown_tmpdir
}

run_guard() {
    run env CHEZMOI_SOURCE_DIR="${SRC}" CHEZMOI_DEST_DIR="${DEST}" \
        bash "${PROJECT_ROOT}/${GUARD}"
}

backup_of() {
    find "${DEST}/.local/state/dotfiles/clobbered" -path "*/$1" 2>/dev/null | head -1
}

# ---------------------------------------------------------------------------
# Backing up real files that are about to be clobbered
# ---------------------------------------------------------------------------

@test "moves a real file aside and preserves its content" {
    mkdir -p "${SRC}/private_dot_claude" "${DEST}/.claude"
    echo 'target' > "${SRC}/private_dot_claude/symlink_settings.json"
    echo '{"iWroteThis":true}' > "${DEST}/.claude/settings.json"

    run_guard
    assert_success
    assert_output --partial 'Backed up'

    [ ! -e "${DEST}/.claude/settings.json" ]
    run cat "$(backup_of '.claude/settings.json')"
    assert_output '{"iWroteThis":true}'
}

@test "moves a real directory aside with its contents" {
    mkdir -p "${SRC}/private_dot_claude" "${DEST}/.claude/skills/microsandbox"
    echo 'target' > "${SRC}/private_dot_claude/symlink_skills"
    echo 'skill' > "${DEST}/.claude/skills/microsandbox/SKILL.md"

    run_guard
    assert_success

    [ ! -e "${DEST}/.claude/skills" ]
    run cat "$(backup_of '.claude/skills/microsandbox/SKILL.md')"
    assert_output 'skill'
}

@test "handles .tmpl suffixes and stacked attribute prefixes" {
    mkdir -p "${SRC}/private_dot_claude" "${DEST}/.claude"
    echo 'target' > "${SRC}/private_dot_claude/symlink_CLAUDE.md.tmpl"
    echo 'real' > "${DEST}/.claude/CLAUDE.md"

    run_guard
    assert_success
    [ ! -e "${DEST}/.claude/CLAUDE.md" ]
    [ -n "$(backup_of '.claude/CLAUDE.md')" ]
}

# ---------------------------------------------------------------------------
# Leaving everything else alone
# ---------------------------------------------------------------------------

@test "leaves an existing symlink alone and stays quiet" {
    mkdir -p "${SRC}/private_dot_claude" "${DEST}/.claude"
    echo 'target' > "${SRC}/private_dot_claude/symlink_settings.json"
    ln -s /somewhere/else "${DEST}/.claude/settings.json"

    run_guard
    assert_success
    assert_output ''
    [ -L "${DEST}/.claude/settings.json" ]
    [ ! -d "${DEST}/.local/state/dotfiles/clobbered" ]
}

@test "is quiet on a fresh machine where nothing exists yet" {
    mkdir -p "${SRC}/private_dot_claude"
    echo 'target' > "${SRC}/private_dot_claude/symlink_settings.json"

    run_guard
    assert_success
    assert_output ''
}

@test "does not touch unmanaged files such as transcripts and local settings" {
    mkdir -p "${SRC}/private_dot_claude" "${DEST}/.claude/projects/sess"
    echo 'target' > "${SRC}/private_dot_claude/symlink_settings.json"
    echo 'transcript' > "${DEST}/.claude/projects/sess/x.jsonl"
    echo 'overrides' > "${DEST}/.claude/settings.local.json"
    echo '{}' > "${DEST}/.claude/settings.json"

    run_guard
    assert_success

    run cat "${DEST}/.claude/projects/sess/x.jsonl"
    assert_output 'transcript'
    run cat "${DEST}/.claude/settings.local.json"
    assert_output 'overrides'
}

@test "refuses to run without CHEZMOI_DEST_DIR rather than guessing at \$HOME" {
    # BSD env requires -u before any VAR=value assignments.
    run env -u CHEZMOI_DEST_DIR CHEZMOI_SOURCE_DIR="${SRC}" \
        bash "${PROJECT_ROOT}/${GUARD}"
    assert_failure
    assert_output --partial 'CHEZMOI_DEST_DIR'
}

# ---------------------------------------------------------------------------
# The source-path -> target-path transform must agree with chezmoi itself.
# This is what catches a rename like dot_claude -> private_dot_claude silently
# pointing the guard at a path that no longer exists.
# ---------------------------------------------------------------------------

@test "target_path_for agrees with chezmoi target-path for every managed entry" {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"

    local source_root="${PROJECT_ROOT}/dotfiles"
    local snippet
    snippet="$(sed -n '/^target_path_for() {$/,/^}$/p' "${PROJECT_ROOT}/${GUARD}")"
    [ -n "${snippet}" ] || fail "could not extract target_path_for from ${GUARD}"

    local checked=0
    while IFS= read -r source_path; do
        local mine theirs
        mine="${HOME}/$(source_dir="${source_root}" bash -c "
            set -euo pipefail
            ${snippet}
            target_path_for '${source_path}'
        ")"
        theirs="$(chezmoi target-path "${source_path}")"
        [ "${mine}" = "${theirs}" ] || fail "transform drift: ${source_path} -> ${mine}, chezmoi says ${theirs}"
        checked=$((checked + 1))
    done < <(find "${source_root}" \( -name 'symlink_*' -o -name 'dot_*' -o -name 'private_*' \) -print | sort)

    [ "${checked}" -gt 0 ] || fail "found no managed entries to check"
}

#!/usr/bin/env bats
# Tests for scripts/link.sh — linking the stow packages, agent links and seed
# files into a scratch destination. The agents repo is a local fixture, so no
# test touches the network or the real home directory.

load test_helper

LINK="scripts/link.sh"

setup() {
    setup_tmpdir
    DEST="${TEST_TMPDIR}/home"
    mkdir -p "${DEST}"

    # Stands in for the private agents repo.
    AGENTS_FIXTURE="${TEST_TMPDIR}/agents-origin"
    mkdir -p "${AGENTS_FIXTURE}/skills/core/demo" "${AGENTS_FIXTURE}/skills/extra/other" \
        "${AGENTS_FIXTURE}/skills/vault/notes" \
        "${AGENTS_FIXTURE}/agents"
    printf 'rules\n' > "${AGENTS_FIXTURE}/AGENTS.md"
    printf 'agent\n' > "${AGENTS_FIXTURE}/agents/demo.md"
    printf 'skill\n' > "${AGENTS_FIXTURE}/skills/core/demo/SKILL.md"
    printf 'skill\n' > "${AGENTS_FIXTURE}/skills/extra/other/SKILL.md"
    printf 'skill\n' > "${AGENTS_FIXTURE}/skills/vault/notes/SKILL.md"
    git -C "${AGENTS_FIXTURE}" init -q
    git -C "${AGENTS_FIXTURE}" add -A
    git -C "${AGENTS_FIXTURE}" -c user.name=test -c user.email=test@example.com commit -q -m fixture
    export AGENTS_REPO_URL="file://${AGENTS_FIXTURE}"
    export DOTFILES_OS=darwin
}

teardown() {
    teardown_tmpdir
}

run_link() {
    run bash "${PROJECT_ROOT}/${LINK}" --destination "${DEST}" "$@"
}

package_file() {
    printf '%s/stow/%s\n' "${PROJECT_ROOT}" "$1"
}

backup_of() {
    find "${DEST}/.local/state/dotfiles/clobbered" -path "*/$1" 2>/dev/null | head -1
}

# Sets NO_STOW_PATH to a directory of links to every command on PATH except stow.
hide_stow() {
    local dir entry name
    local -a dirs=()
    NO_STOW_PATH="${TEST_TMPDIR}/no-stow-bin"
    mkdir -p "${NO_STOW_PATH}"
    IFS=: read -r -a dirs <<< "${PATH}"
    for dir in "${dirs[@]}"; do
        for entry in "${dir}"/*; do
            name="${entry##*/}"
            [[ "${name}" == stow || -e "${NO_STOW_PATH}/${name}" || ! -x "${entry}" ]] && continue
            ln -s "${entry}" "${NO_STOW_PATH}/${name}"
        done
    done
}

stat_mode() {
    stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"
}

# ---------------------------------------------------------------------------
# Linking packages
# ---------------------------------------------------------------------------

@test "links every package file so the live file is the repo file" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    run_link
    assert_success

    [ -L "${DEST}/.zshenv" ]
    [ -L "${DEST}/.config/git/config" ]
    [ -L "${DEST}/.local/bin/home-audit" ]
    [ -x "${DEST}/.local/bin/home-audit" ]
    [ "$(cat "${DEST}/.zshenv")" = "$(cat "$(package_file common/.zshenv)")" ]
    # --no-folding: directories stay real, so apps cannot write into the repo.
    [ -d "${DEST}/.config" ] && [ ! -L "${DEST}/.config" ]
    [ -d "${DEST}/.config/git" ] && [ ! -L "${DEST}/.config/git" ]
}

@test "shares one editor settings file between Code and Cursor, and only where the persona wants it" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    run_link
    assert_success
    local app f
    for app in Code Cursor; do
        for f in settings.json keybindings.json; do
            [ "$(readlink "${DEST}/Library/Application Support/${app}/User/${f}")" = "${PROJECT_ROOT}/editors/code/${f}" ]
        done
    done
    [ -d "${DEST}/Library/Application Support/Code/User" ] && [ ! -L "${DEST}/Library/Application Support/Code/User" ]
    [ ! -e "${DEST}/.config/Code" ]

    # Linux defaults to the server persona, which takes no editor settings.
    DEST="${TEST_TMPDIR}/linux-home"
    DOTFILES_OS=linux run_link
    assert_success
    [ ! -e "${DEST}/.config/Code" ]
    [ ! -e "${DEST}/.config/Cursor" ]
    [ ! -e "${DEST}/Library" ]
    [ ! -e "${DEST}/.config/docker" ]
}

@test "keeps each editor setting file in the repo only once" {
    [ -z "$(find "${PROJECT_ROOT}/stow" -path '*/User/*' -print)" ]
}

@test "relinks an editor link left by the old stow layout without a backup" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    local dir="${DEST}/Library/Application Support/Code/User"
    mkdir -p "${dir}"
    ln -s "../../../../.dotfiles/stow/darwin/Library/Application Support/Code/User/keybindings.json" "${dir}/keybindings.json"

    run_link
    assert_success
    refute_output --partial "Backed up"
    [ "$(readlink "${dir}/keybindings.json")" = "${PROJECT_ROOT}/editors/code/keybindings.json" ]
    [ ! -e "${DEST}/.local/state/dotfiles/clobbered" ]
}

@test "replaces identical editor settings and backs up changed ones" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    local dir="${DEST}/Library/Application Support/Cursor/User"
    mkdir -p "${dir}"
    cp "${PROJECT_ROOT}/editors/code/settings.json" "${dir}/settings.json"
    printf '[]\n' > "${dir}/keybindings.json"

    run_link
    assert_success
    assert_output --partial "Backed up ${dir}/keybindings.json"
    refute_output --partial "Backed up ${dir}/settings.json"
    [ -L "${dir}/settings.json" ] && [ -L "${dir}/keybindings.json" ]
    run cat "$(backup_of "Library/Application Support/Cursor/User/keybindings.json")"
    assert_output '[]'
}

@test "dry run reports editor links without creating them" {
    local dir="${DEST}/Library/Application Support/Code/User"
    mkdir -p "${dir}"
    printf '[]\n' > "${dir}/keybindings.json"

    run_link --dry-run
    assert_success
    assert_output --partial "Would back up ${dir}/keybindings.json"
    assert_output --partial "Would link ${dir}/settings.json -> ${PROJECT_ROOT}/editors/code/settings.json"
    [ ! -L "${dir}/keybindings.json" ] && [ ! -e "${dir}/settings.json" ]
    [ ! -e "${DEST}/Library/Application Support/Cursor" ]
}

@test "replaces an identical copy without keeping a backup" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    mkdir -p "${DEST}/.config/git"
    cp "$(package_file common/.config/git/ignore)" "${DEST}/.config/git/ignore"

    run_link
    assert_success
    [ -L "${DEST}/.config/git/ignore" ]
    [ -z "$(backup_of .config/git/ignore)" ]
}

@test "backs up a changed copy before linking" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    mkdir -p "${DEST}/.config/git"
    printf 'my local edit\n' > "${DEST}/.config/git/ignore"

    run_link
    assert_success
    assert_output --partial "Backed up ${DEST}/.config/git/ignore"
    [ -L "${DEST}/.config/git/ignore" ]
    run cat "$(backup_of .config/git/ignore)"
    assert_output 'my local edit'
}

@test "backs up a foreign symlink before linking" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    ln -s /somewhere/else "${DEST}/.bashrc"

    run_link
    assert_success
    [ "$(cat "${DEST}/.bashrc")" = "$(cat "$(package_file common/.bashrc)")" ]
    [ "$(readlink "$(backup_of .bashrc)")" = /somewhere/else ]
}

@test "creates backup directories privately" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    mkdir -p "${DEST}/.config/git"
    printf 'my local edit\n' > "${DEST}/.config/git/ignore"

    run_link
    assert_success
    local backup stamp_dir
    backup="$(backup_of .config/git/ignore)"
    stamp_dir="${backup%/.config/git/ignore}"
    [ "$(stat_mode "${DEST}/.local/state/dotfiles/clobbered")" = 700 ]
    [ "$(stat_mode "${stamp_dir}")" = 700 ]
    [ "$(stat_mode "${stamp_dir}/.config")" = 700 ]
    [ "$(stat_mode "${stamp_dir}/.config/git")" = 700 ]
}

@test "refuses to back up through a symlinked state directory" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    mkdir -p "${DEST}/.local" "${TEST_TMPDIR}/elsewhere" "${DEST}/.config/git"
    ln -s "${TEST_TMPDIR}/elsewhere" "${DEST}/.local/state"
    printf 'my local edit\n' > "${DEST}/.config/git/ignore"

    run_link
    assert_failure
    assert_output --partial "Backup parent is a symlink: ${DEST}/.local/state"
    [ ! -L "${DEST}/.config/git/ignore" ]
    [ "$(cat "${DEST}/.config/git/ignore")" = 'my local edit' ]
    [ -z "$(ls -A "${TEST_TMPDIR}/elsewhere")" ]
}

@test "a second run changes nothing" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    run_link
    assert_success
    local before
    before="$(cd "${DEST}" && find . -print | LC_ALL=C sort)"

    run_link
    assert_success
    refute_output --partial "Backed up"
    refute_output --partial "Created"
    [ "$(cd "${DEST}" && find . -print | LC_ALL=C sort)" = "${before}" ]
}

@test "dry run reports changes without touching the destination" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    mkdir -p "${DEST}/.config/git"
    printf 'my local edit\n' > "${DEST}/.config/git/ignore"

    run_link --dry-run
    assert_success
    assert_output --partial "Would back up ${DEST}/.config/git/ignore"
    assert_output --partial "Would clone"
    assert_output --partial "Would create ${DEST}/.config/gh/hosts.yml"
    [ "$(find "${DEST}" -mindepth 1 -print | LC_ALL=C sort)" = "$(printf '%s\n' "${DEST}/.config" "${DEST}/.config/git" "${DEST}/.config/git/ignore")" ]
}

@test "dry run without stow still reports conflicts" {
    hide_stow
    mkdir -p "${DEST}/.config/git"
    printf 'my local edit\n' > "${DEST}/.config/git/ignore"

    run env PATH="${NO_STOW_PATH}" bash "${PROJECT_ROOT}/${LINK}" --destination "${DEST}" --dry-run
    assert_success
    assert_output --partial "Would back up ${DEST}/.config/git/ignore"
    [ "$(cat "${DEST}/.config/git/ignore")" = 'my local edit' ]
}

@test "a real run without stow fails before moving anything" {
    hide_stow
    mkdir -p "${DEST}/.config/git"
    printf 'my local edit\n' > "${DEST}/.config/git/ignore"

    run env PATH="${NO_STOW_PATH}" bash "${PROJECT_ROOT}/${LINK}" --destination "${DEST}"
    assert_failure
    assert_output --partial "GNU Stow is not installed"
    [ "$(cat "${DEST}/.config/git/ignore")" = 'my local edit' ]
    [ ! -e "${DEST}/.local/state/dotfiles/clobbered" ]
}

@test "stow's own simulate flag also makes the run a dry run" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    run_link -- --simulate
    assert_success
    [ -z "$(find "${DEST}" -mindepth 1 -print)" ]
}

@test "refuses a stow target that would bypass the destination" {
    run_link -- --target=/tmp
    assert_failure 2
    assert_output --partial "--destination"
}

# ---------------------------------------------------------------------------
# Agent links
# ---------------------------------------------------------------------------

@test "home links Claude Code to the agents repo and work adds Cursor" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    run_link --persona home
    assert_success
    [ -d "${DEST}/.config/agents/.git" ]
    [ ! -e "${DEST}/.claude/settings.json" ]
    [ "$(cat "${DEST}/.claude/CLAUDE.md")" = rules ]
    [ "$(cat "${DEST}/.codex/AGENTS.md")" = rules ]
    [ "$(stat_mode "${DEST}/.claude")" = 700 ]
    [ ! -e "${DEST}/.cursor" ]

    DEST="${TEST_TMPDIR}/work-home"
    run_link --persona work
    assert_success
    [ ! -e "${DEST}/.cursor/cli-config.json" ] && [ ! -e "${DEST}/.cursor/hooks.json" ]
    [ "$(cat "${DEST}/.cursor/AGENTS.md")" = rules ]
    [ "$(cat "${DEST}/.codex/AGENTS.md")" = rules ]
    [ "$(stat_mode "${DEST}/.cursor")" = 700 ]
    [ "$(cat "${DEST}/.claude/CLAUDE.md")" = rules ]
}

@test "stows the persona's skill bundles into a real skills directory" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    local persona app
    for persona in home:.claude work:.cursor; do
        app="${persona#*:}"
        DEST="${TEST_TMPDIR}/${persona%%:*}"
        run_link --persona "${persona%%:*}"
        assert_success
        [ -d "${DEST}/.agents/skills" ] && [ ! -L "${DEST}/.agents/skills" ]
        [ -L "${DEST}/.agents/skills/demo" ]
        [ ! -e "${DEST}/.agents/skills/other" ]
        [ "$(readlink "${DEST}/${app}/skills")" = "${DEST}/.agents/skills" ]
    done
}

@test "only home stows the vault bundle, and leaving home removes it" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    run_link --persona home
    assert_success
    [ -L "${DEST}/.agents/skills/notes" ]
    [ "$(cat "${DEST}/.claude/skills/notes/SKILL.md")" = skill ]
    # A bundle no persona lists stays a skills-add choice.
    stow --dir "${DEST}/.config/agents/skills" --target "${DEST}/.agents/skills" extra

    run_link --persona work status
    assert_line "stale ${DEST}/.agents/skills/notes"
    refute_line --partial "skills/other"

    run_link --persona work
    assert_success
    [ ! -e "${DEST}/.agents/skills/notes" ] && [ ! -L "${DEST}/.agents/skills/notes" ]
    [ ! -e "${DEST}/.cursor/skills/notes" ]
    [ -L "${DEST}/.agents/skills/demo" ]
    [ -L "${DEST}/.agents/skills/other" ]
    [ -f "${DEST}/.config/agents/skills/vault/notes/SKILL.md" ]
    run_link --persona work status
    refute_line --partial "stale"

    DEST="${TEST_TMPDIR}/work-home"
    run_link --persona work
    assert_success
    [ -L "${DEST}/.agents/skills/demo" ]
    [ ! -e "${DEST}/.agents/skills/notes" ]
}

@test "links Claude's agents directory, keeps hand-made agents, and leaves Cursor's alone" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    mkdir -p "${DEST}/.claude/agents" "${DEST}/.cursor/agents"
    printf 'mine\n' > "${DEST}/.claude/agents/mine.md"
    printf 'cursor\n' > "${DEST}/.cursor/agents/own.md"

    run_link --persona work
    assert_success
    [ "$(readlink "${DEST}/.claude/agents")" = "${DEST}/.config/agents/agents" ]
    [ "$(cat "${DEST}/.claude/agents/demo.md")" = agent ]
    run cat "$(backup_of .claude/agents/mine.md)"
    assert_output 'mine'
    [ ! -L "${DEST}/.cursor/agents" ] && [ "$(cat "${DEST}/.cursor/agents/own.md")" = cursor ]
}

@test "switching from work to home removes Cursor's links and leaves its settings alone" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    run_link --persona work
    assert_success
    printf '{"p":true}\n' > "${DEST}/.cursor/cli-config.json"

    run_link --persona home status
    assert_line "stale ${DEST}/.cursor/AGENTS.md"

    run_link --persona home
    assert_success
    for link in .cursor/AGENTS.md .cursor/agents .cursor/skills; do
        [ ! -e "${DEST}/${link}" ] && [ ! -L "${DEST}/${link}" ]
    done
    [ "$(cat "${DEST}/.cursor/cli-config.json")" = '{"p":true}' ]
    [ "$(readlink "${DEST}/.claude/CLAUDE.md")" = "${DEST}/.config/agents/AGENTS.md" ]
    [ -L "${DEST}/.codex/AGENTS.md" ]

    run_link --persona work
    assert_success
    # Work gets no identity from the repo.
    run_link --persona work status
    assert_success
    assert_output "unset ${DEST}/.config/git/config.local"
}

@test "replaces the old whole-library skills link and keeps imported bundles" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    run_link
    assert_success
    stow --dir "${DEST}/.config/agents/skills" --target "${DEST}/.agents/skills" extra
    run_link
    assert_success
    [ -L "${DEST}/.agents/skills/other" ]

    rm -rf "${DEST}/.agents/skills"
    ln -s "${DEST}/.config/agents/skills" "${DEST}/.agents/skills"
    run_link
    assert_success
    [ ! -L "${DEST}/.agents/skills" ]
    [ -L "${DEST}/.agents/skills/demo" ]
}

@test "moves real agent config aside and leaves unmanaged agent state alone" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    export DOTFILES_PERSONA=work
    mkdir -p "${DEST}/.cursor/skills/mine" "${DEST}/.cursor/projects/sess"
    printf 'skill\n' > "${DEST}/.cursor/skills/mine/SKILL.md"
    printf 'transcript\n' > "${DEST}/.cursor/projects/sess/x.jsonl"
    printf 'overrides\n' > "${DEST}/.cursor/mcp.json"

    run_link
    assert_success
    [ -L "${DEST}/.cursor/skills" ]
    run cat "$(backup_of .cursor/skills/mine/SKILL.md)"
    assert_output 'skill'
    [ "$(cat "${DEST}/.cursor/projects/sess/x.jsonl")" = transcript ]
    [ "$(cat "${DEST}/.cursor/mcp.json")" = overrides ]
}

@test "names skill folders left from the old flat layout and keeps them" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    run_link
    assert_success
    refute_output --partial "does not track"

    mkdir -p "${DEST}/.config/agents/skills/old-skill"
    printf 'finder\n' > "${DEST}/.config/agents/skills/old-skill/.DS_Store"
    run_link
    assert_success
    assert_output --partial "does not track, likely left from the old flat layout: old-skill."
    [ -f "${DEST}/.config/agents/skills/old-skill/.DS_Store" ]
}

@test "a recent checkout is pulled only with --refresh" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    run_link
    assert_success
    printf 'new rules\n' > "${AGENTS_FIXTURE}/AGENTS.md"
    git -C "${AGENTS_FIXTURE}" -c user.name=test -c user.email=test@example.com commit -qam rules

    run_link
    assert_success
    [ "$(cat "${DEST}/.config/agents/AGENTS.md")" = rules ]
    run_link --refresh
    assert_success
    [ "$(cat "${DEST}/.config/agents/AGENTS.md")" = 'new rules' ]
}

@test "an unreachable agents repo does not stop the rest of the install" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    AGENTS_REPO_URL="file://${TEST_TMPDIR}/missing" run_link
    assert_success
    assert_output --partial "Could not clone"
    [ -L "${DEST}/.zshenv" ]
    [ ! -e "${DEST}/.claude/settings.json" ]
}

@test "leaves a non-git agents directory alone" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    mkdir -p "${DEST}/.config/agents"
    printf 'hand made\n' > "${DEST}/.config/agents/AGENTS.md"

    run_link
    assert_success
    assert_output --partial "is not a git checkout"
    [ "$(cat "${DEST}/.config/agents/AGENTS.md")" = 'hand made' ]
}

# ---------------------------------------------------------------------------
# Personas without agents
# ---------------------------------------------------------------------------

@test "a persona without agents removes agent links and leaves app settings alone" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    run_link --persona work
    assert_success
    stow --dir "${DEST}/.config/agents/skills" --target "${DEST}/.agents/skills" extra
    mkdir -p "${DEST}/.agents/skills/synced/mine"
    printf '{"hints":true}\n' > "${DEST}/.cursor/cli-config.json"
    printf 'transcript\n' > "${DEST}/.cursor/ide_state.json"

    run_link --persona sandbox status
    assert_line "stale ${DEST}/.cursor/AGENTS.md"
    assert_line "stale ${DEST}/.agents/skills/other"
    assert_line "unused ${DEST}/.config/agents"

    run_link --persona sandbox
    assert_success
    assert_output --partial "this persona does not use"
    for link in .cursor/AGENTS.md .cursor/agents .cursor/skills .codex/AGENTS.md \
        .agents/skills/demo .agents/skills/other; do
        [ ! -e "${DEST}/${link}" ] && [ ! -L "${DEST}/${link}" ]
    done
    [ -d "${DEST}/.agents/skills/synced/mine" ]
    [ "$(cat "${DEST}/.cursor/cli-config.json")" = '{"hints":true}' ]
    [ -d "${DEST}/.config/agents/.git" ]
    [ "$(cat "${DEST}/.cursor/ide_state.json")" = transcript ]

    run_link --persona sandbox status
    assert_success
    refute_line --partial "stale"
    assert_line "unused ${DEST}/.config/agents"
    run_link --persona sandbox managed
    refute_line --partial ".claude/"
    refute_line --partial ".cursor/"
}

@test "a persona with agents removes agent links it no longer lists" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    run_link
    assert_success
    mkdir -p "${DEST}/.codex"
    ln -s "${DEST}/.config/agents/rules" "${DEST}/.codex/rules"
    ln -s /somewhere/else "${DEST}/.codex/other"

    run_link
    assert_success
    [ ! -L "${DEST}/.codex/rules" ]
    [ -L "${DEST}/.codex/other" ]
    [ -L "${DEST}/.codex/AGENTS.md" ]
}

# ---------------------------------------------------------------------------
# Seed files
# ---------------------------------------------------------------------------

@test "copies seed files once, privately, and never overwrites them" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    run_link
    assert_success
    [ -f "${DEST}/.config/docker/config.json" ] && [ ! -L "${DEST}/.config/docker/config.json" ]
    [ "$(stat_mode "${DEST}/.config/gh/hosts.yml")" = 600 ]

    printf 'rewritten by gh\n' > "${DEST}/.config/gh/hosts.yml"
    run_link
    assert_success
    [ "$(cat "${DEST}/.config/gh/hosts.yml")" = 'rewritten by gh' ]
}

# ---------------------------------------------------------------------------
# Inventory
# ---------------------------------------------------------------------------

@test "managed lists package files, seeds and agent links for this platform only" {
    run_link managed
    assert_success
    assert_line "${DEST}/.zshenv"
    assert_line "${DEST}/Library/Application Support/Code/User/settings.json"
    assert_line "${DEST}/.config/gh/hosts.yml"
    assert_line "${DEST}/.claude/CLAUDE.md"
    refute_line "${DEST}/.claude/settings.json"
    assert_line "${DEST}/.claude/skills"
    assert_line "${DEST}/.codex/AGENTS.md"
    refute_line --partial "${DEST}/.cursor/"
    assert_line "${DEST}/.agents/skills"
    assert_line "${DEST}/.config/agents"
    refute_line "${DEST}/.config/Code/User/settings.json"

    run_link --persona work managed
    assert_line "${DEST}/.cursor/AGENTS.md"
    refute_line "${DEST}/.cursor/cli-config.json"
    assert_line "${DEST}/.cursor/skills"
    assert_line "${DEST}/.claude/CLAUDE.md"
}

@test "status names each kind of drift" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    run_link
    assert_success

    rm "${DEST}/.bashrc"
    rm "${DEST}/.zshenv" && printf 'saved by an editor\n' > "${DEST}/.zshenv"
    rm "${DEST}/.config/git/ignore" && ln -s /somewhere/else "${DEST}/.config/git/ignore"
    rm -rf "${DEST}/.agents/skills"
    local editor="${DEST}/Library/Application Support/Code/User"
    rm "${editor}/settings.json" && printf '{}\n' > "${editor}/settings.json"
    rm "${editor}/keybindings.json"

    run_link status
    assert_success
    assert_line "replaced ${editor}/settings.json"
    assert_line "missing ${editor}/keybindings.json"
    refute_line --partial "Cursor"
    assert_line "missing ${DEST}/.bashrc"
    assert_line "replaced ${DEST}/.zshenv"
    assert_line "foreign ${DEST}/.config/git/ignore"
    assert_line "missing ${DEST}/.agents/skills"
    assert_line "broken ${DEST}/.claude/skills"
    refute_line --partial ".config/git/config"
}

# ---------------------------------------------------------------------------
# Stale links
# ---------------------------------------------------------------------------

# Sets FIXTURE to a small dotfiles repo whose history held stow/common/.config/gone/rc
# and stow/linux/.config/tool/rc, and which now holds stow/common/.keep, a
# stow/extra package this platform does not use, and editors/code/settings.json.
make_fixture_repo() {
    FIXTURE="${TEST_TMPDIR}/fixture"
    mkdir -p "${FIXTURE}/stow/common/.config/gone" "${FIXTURE}/stow/linux/.config/tool" \
        "${FIXTURE}/stow/extra/.config/extra" "${FIXTURE}/editors/code"
    printf 'keep\n' > "${FIXTURE}/stow/common/.keep"
    printf 'gone\n' > "${FIXTURE}/stow/common/.config/gone/rc"
    printf 'tool\n' > "${FIXTURE}/stow/linux/.config/tool/rc"
    printf 'extra\n' > "${FIXTURE}/stow/extra/.config/extra/rc"
    printf '{}\n' > "${FIXTURE}/editors/code/settings.json"
    git -C "${FIXTURE}" init -q
    git -C "${FIXTURE}" add -A
    git -C "${FIXTURE}" -c user.name=test -c user.email=test@example.com commit -q -m one
    git -C "${FIXTURE}" rm -q -r stow/common/.config/gone stow/linux
    git -C "${FIXTURE}" -c user.name=test -c user.email=test@example.com commit -q -m two
}

run_fixture_link() {
    run bash "${PROJECT_ROOT}/${LINK}" --repo "${FIXTURE}" --destination "${DEST}" "$@"
}

# Leaves the links a run from the fixture's first commit would have made, on
# both platforms: two now dangle, one points into an unused package, and one is
# an editor link in the Linux editor directory.
plant_old_links() {
    mkdir -p "${DEST}/.config/gone" "${DEST}/.config/tool" "${DEST}/.config/extra" "${DEST}/.config/Code/User"
    ln -s ../../../fixture/stow/common/.config/gone/rc "${DEST}/.config/gone/rc"
    ln -s ../../../fixture/stow/linux/.config/tool/rc "${DEST}/.config/tool/rc"
    ln -s ../../../fixture/stow/extra/.config/extra/rc "${DEST}/.config/extra/rc"
    ln -s "${FIXTURE}/editors/code/settings.json" "${DEST}/.config/Code/User/settings.json"
}

@test "removes links to files that left the repo or no longer apply here" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    make_fixture_repo
    plant_old_links

    run_fixture_link
    assert_success
    assert_output --partial "Removed stale link ${DEST}/.config/gone/rc"
    [ ! -L "${DEST}/.config/gone/rc" ]
    [ ! -L "${DEST}/.config/tool/rc" ]
    [ ! -L "${DEST}/.config/extra/rc" ]
    [ ! -L "${DEST}/.config/Code/User/settings.json" ]
    [ -L "${DEST}/Library/Application Support/Code/User/settings.json" ]
    [ -L "${DEST}/.keep" ]
    [ ! -e "${DEST}/.local/state/dotfiles/clobbered" ]
}

@test "stale link removal leaves real files and foreign links alone" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    make_fixture_repo
    mkdir -p "${DEST}/.config/gone" "${DEST}/.config/tool" "${DEST}/.config/Code/User"
    printf 'mine\n' > "${DEST}/.config/gone/rc"
    ln -s /somewhere/else "${DEST}/.config/tool/rc"
    ln -s "${TEST_TMPDIR}/elsewhere.json" "${DEST}/.config/Code/User/settings.json"

    run_fixture_link
    assert_success
    refute_output --partial "stale"
    [ "$(cat "${DEST}/.config/gone/rc")" = "mine" ]
    [ "$(readlink "${DEST}/.config/tool/rc")" = "/somewhere/else" ]
    [ -L "${DEST}/.config/Code/User/settings.json" ]
}

@test "dry run and status report stale links without removing them" {
    make_fixture_repo
    plant_old_links

    run_fixture_link --dry-run
    assert_success
    assert_output --partial "Would remove stale link ${DEST}/.config/gone/rc"
    assert_output --partial "Would remove stale link ${DEST}/.config/Code/User/settings.json"

    run_fixture_link status
    assert_success
    assert_line "stale ${DEST}/.config/gone/rc"
    assert_line "stale ${DEST}/.config/tool/rc"
    assert_line "stale ${DEST}/.config/extra/rc"
    assert_line "stale ${DEST}/.config/Code/User/settings.json"
    [ -L "${DEST}/.config/gone/rc" ]
    [ -L "${DEST}/.config/Code/User/settings.json" ]
}

@test "relinks a file that moved to another package without a backup" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    make_fixture_repo
    # .keep once lived in the linux package; its old link now dangles.
    ln -s ../fixture/stow/linux/.keep "${DEST}/.keep"

    run_fixture_link
    assert_success
    refute_output --partial "Backed up"
    [ "$(readlink "${DEST}/.keep")" = "../fixture/stow/common/.keep" ]
    [ ! -e "${DEST}/.local/state/dotfiles/clobbered" ]
}

# ---------------------------------------------------------------------------
# Adding files
# ---------------------------------------------------------------------------

@test "add copies a file into the layer and links it without a backup" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    make_fixture_repo
    mkdir -p "${DEST}/.config/tool"
    printf 'setting=1\n' > "${DEST}/.config/tool/rc"
    chmod 755 "${DEST}/.config/tool/rc"

    run_fixture_link add --layer common "${DEST}/.config/tool/rc" < /dev/null
    assert_success
    assert_output --partial "/fixture add stow/common"
    [[ "$(cat "${FIXTURE}/stow/common/.config/tool/rc")" == "setting=1" ]]
    [ -x "${FIXTURE}/stow/common/.config/tool/rc" ]
    [ -L "${DEST}/.config/tool/rc" ]
    [[ "$(cat "${DEST}/.config/tool/rc")" == "setting=1" ]]
    [ ! -e "${DEST}/.local/state/dotfiles/clobbered" ]
}

@test "add takes a directory, a platform part, and paths relative to the current directory" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    make_fixture_repo
    mkdir -p "${DEST}/.config/app/themes"
    printf 'a\n' > "${DEST}/.config/app/config"
    printf 'b\n' > "${DEST}/.config/app/themes/dark"

    cd "${DEST}/.config"
    run_fixture_link add --layer common --platform app < /dev/null
    assert_success
    [ -f "${FIXTURE}/stow/common.darwin/.config/app/config" ]
    [ -f "${FIXTURE}/stow/common.darwin/.config/app/themes/dark" ]
    [ -L "${DEST}/.config/app/config" ]
    [ -L "${DEST}/.config/app/themes/dark" ]
    [ -d "${DEST}/.config/app" ] && [ ! -L "${DEST}/.config/app" ]
}

@test "add --seed copies the file as a seed and leaves the live file alone" {
    make_fixture_repo
    mkdir -p "${DEST}/.config/app"
    printf 'owned by the app\n' > "${DEST}/.config/app/state.json"

    run_fixture_link add --layer common --seed "${DEST}/.config/app/state.json" < /dev/null
    assert_success
    [ -f "${FIXTURE}/seed/common/.config/app/state.json" ]
    [ -f "${DEST}/.config/app/state.json" ] && [ ! -L "${DEST}/.config/app/state.json" ]
}

@test "add refuses secrets, local overrides, managed and outside paths before copying anything" {
    make_fixture_repo
    mkdir -p "${DEST}/.ssh" "${DEST}/.config/zsh" "${DEST}/.config/agents" "${DEST}/.config/Code/User"
    printf 'fine\n' > "${DEST}/.fine"
    printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\n' > "${DEST}/.ssh/work"
    printf 'key\n' > "${DEST}/.ssh/id_ed25519"
    printf 'TOKEN=x\n' > "${DEST}/.env"
    printf 'alias x=y\n' > "${DEST}/.config/zsh/.zshrc.local"
    printf 'rules\n' > "${DEST}/.config/agents/AGENTS.md"
    printf '{}\n' > "${DEST}/.config/Code/User/keybindings.json"
    printf 'keep\n' > "${DEST}/.keep"
    printf 'outside\n' > "${TEST_TMPDIR}/outside"

    for path in .ssh/work .ssh/id_ed25519 .env .config/zsh/.zshrc.local \
        .config/agents/AGENTS.md .config/Code/User/keybindings.json .keep; do
        run_fixture_link add --layer common "${DEST}/.fine" "${DEST}/${path}" < /dev/null
        assert_failure
        assert_output --partial "Not adding ~/${path}"
    done
    run_fixture_link add --layer common "${TEST_TMPDIR}/outside" < /dev/null
    assert_failure
    assert_output --partial "Not inside"

    [ ! -e "${FIXTURE}/stow/common/.fine" ]
    [ -f "${DEST}/.fine" ] && [ ! -L "${DEST}/.fine" ]
}

@test "add refuses a file with a banned word without naming the word" {
    make_fixture_repo
    mkdir -p "${DEST}/.config"
    printf '# comment\nzorblax\n' > "${DEST}/.config/banned-words"
    printf 'say ZORBLAX here\n' > "${DEST}/.rc"

    run_fixture_link add --layer common "${DEST}/.rc" < /dev/null
    assert_failure
    assert_output --partial "contains a banned word"
    refute_output --partial "orblax"
    [ ! -e "${FIXTURE}/stow/common/.rc" ]
}

@test "add needs a layer this persona links, and asks for none without a terminal" {
    make_fixture_repo
    printf 'x\n' > "${DEST}/.rc"

    run_fixture_link add "${DEST}/.rc" < /dev/null
    assert_failure
    assert_output --partial "Name the layer with --layer"

    run_fixture_link add --layer extra "${DEST}/.rc" < /dev/null
    assert_failure
    assert_output --partial "does not link layer 'extra'"
    [ ! -e "${FIXTURE}/stow/extra/.rc" ]

    run_fixture_link --layer common status
    assert_failure
    assert_output --partial "only apply to add"
}

@test "add dry run copies and links nothing" {
    make_fixture_repo
    printf 'x\n' > "${DEST}/.rc"

    run_fixture_link --dry-run add --layer common "${DEST}/.rc" < /dev/null
    assert_success
    assert_output --partial "Would copy ~/.rc to stow/common/.rc"
    [ ! -e "${FIXTURE}/stow/common/.rc" ]
    [ -f "${DEST}/.rc" ] && [ ! -L "${DEST}/.rc" ]
}

@test "add refuses a symlink, whether ours or foreign" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    make_fixture_repo
    run_fixture_link
    assert_success
    ln -s /etc/hosts "${DEST}/.hosts"

    run_fixture_link add --layer common "${DEST}/.keep" < /dev/null
    assert_failure
    assert_output --partial "Already managed"
    run_fixture_link add --layer common "${DEST}/.hosts" < /dev/null
    assert_failure
    assert_output --partial "Not adding a symlink"
}

# ---------------------------------------------------------------------------
# Personas
# ---------------------------------------------------------------------------

persona_state() {
    cat "${DEST}/.local/state/dotfiles/persona"
}

@test "lists the personas this OS can use" {
    run_link personas
    assert_success
    assert_line --partial "home"$'\t'
    assert_line --partial "work"$'\t'
    DOTFILES_OS=linux run_link personas
    assert_success
    refute_line --partial "home"$'\t'
    assert_line --partial "server"$'\t'
    assert_line --partial "sandbox"$'\t'
}

@test "uses the OS default until a persona is chosen, and says so" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    run_link persona
    assert_output "home default"
    DOTFILES_OS=linux run_link persona
    assert_output "server default"

    run_link
    assert_success
    assert_output --partial "No persona chosen"
    [ ! -e "${DEST}/.local/state/dotfiles/persona" ]
}

@test "a chosen persona is saved privately and reused by later runs" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    run_link --persona work
    assert_success
    assert_output --partial "Saved persona work"
    [ "$(persona_state)" = "work" ]
    [ "$(stat_mode "${DEST}/.local/state/dotfiles")" = "700" ]

    run_link persona
    assert_output "work saved"
    run_link
    assert_success
    refute_output --partial "No persona chosen"
    refute_output --partial "Saved persona"
}

@test "the persona from the environment is used and saved like the flag" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    DOTFILES_PERSONA=sandbox run_link persona
    assert_output "sandbox env"
    DOTFILES_PERSONA=sandbox run_link
    assert_success
    [ "$(persona_state)" = "sandbox" ]
    # The flag wins over the environment.
    DOTFILES_PERSONA=sandbox run_link --persona work persona
    assert_output "work flag"
}

@test "a dry run never saves the persona" {
    run_link --dry-run --persona work
    assert_success
    [ ! -e "${DEST}/.local/state/dotfiles/persona" ]
}

@test "a persona without agents or editors links only the shared files" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    run_link --persona sandbox
    assert_success
    [ -L "${DEST}/.zshenv" ]
    [ ! -e "${DEST}/.config/agents" ]
    [ ! -e "${DEST}/.cursor/AGENTS.md" ]
    [ ! -e "${DEST}/Library/Application Support/Code" ]

    run_link managed
    refute_line "${DEST}/.config/agents"
    refute_line --partial "Application Support"
    run_link status
    assert_success
    assert_output "unset ${DEST}/.config/git/config.local"
}

@test "switching to a persona without editors removes the editor links" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    run_link --persona home
    assert_success
    [ -L "${DEST}/Library/Application Support/Code/User/settings.json" ]

    run_link --persona server
    assert_success
    assert_output --partial "Removed stale link ${DEST}/Library/Application Support/Code/User/settings.json"
    [ ! -e "${DEST}/Library/Application Support/Code/User/settings.json" ]
    [ -L "${DEST}/.zshenv" ]
    [ "$(persona_state)" = "server" ]
}

@test "rejects an unknown persona or one for another OS before changing anything" {
    run_link --persona nope
    assert_failure 2
    assert_output --partial "Unknown persona 'nope'"
    run_link --persona ../home
    assert_failure 2
    DOTFILES_OS=linux run_link --persona home
    assert_failure 2
    assert_output --partial "Persona 'home' is not for linux"
    [ -z "$(ls -A "${DEST}")" ]
}

@test "a saved persona that no longer exists fails clearly" {
    mkdir -p "${DEST}/.local/state/dotfiles"
    printf 'retired\n' > "${DEST}/.local/state/dotfiles/persona"
    run_link status
    assert_failure 2
    assert_output --partial "Unknown persona 'retired'"
}

# ---------------------------------------------------------------------------
# Layers
# ---------------------------------------------------------------------------

@test "each persona links its own layers" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    run_link --persona home
    assert_success
    [ -L "${DEST}/.config/ghostty/config" ]
    [ -L "${DEST}/.local/bin/sshkey" ]
    [ -L "${DEST}/.local/bin/df-deploy" ]
    [ -L "${DEST}/.config/restic/b2.env.example" ]
    [ ! -e "${DEST}/.local/bin/ph-update" ]

    # A work Mac gets the shared tools but nothing personal or Pi-hole.
    DEST="${TEST_TMPDIR}/work-home"
    run_link --persona work
    assert_success
    [ -L "${DEST}/.local/bin/sshkey" ]
    for path in .local/bin/cf-cert .local/bin/df-deploy .local/bin/ts-test \
        .config/restic .local/bin/ph-update .local/bin/ph-padd; do
        [ ! -e "${DEST}/${path}" ]
    done

    DEST="${TEST_TMPDIR}/pi-home"
    DOTFILES_OS=linux run_link --persona server
    assert_success
    [ -L "${DEST}/.local/bin/ph-update" ]
    [ -L "${DEST}/.local/bin/ph-agent-setup" ]
    [ -L "${DEST}/.local/bin/sshkey" ]
    [ -L "${DEST}/.local/bin/cf-cert" ]
    [ -L "${DEST}/.local/bin/ts-test" ]
    [ ! -e "${DEST}/.config/ghostty" ]
    [ ! -e "${DEST}/.config/1Password" ]

    # A Mac server gets the shared tools but not the Linux-only Pi-hole ones.
    DEST="${TEST_TMPDIR}/mini-home"
    run_link --persona server
    assert_success
    [ -L "${DEST}/.local/bin/os-update" ]
    [ ! -e "${DEST}/.local/bin/ph-update" ]

    DEST="${TEST_TMPDIR}/sandbox-home"
    DOTFILES_OS=linux run_link --persona sandbox
    assert_success
    [ -L "${DEST}/.zshenv" ]
    [ ! -e "${DEST}/.local/bin" ]
}

# Prints a git setting as git resolves it with DEST as the home directory.
dest_git_config() {
    HOME="${DEST}" XDG_CONFIG_HOME="${DEST}/.config" GIT_CONFIG_NOSYSTEM=1 \
        git config --global --includes --get "$1"
}

@test "git and ssh pick up the settings of the persona's layers" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    run_link --persona work
    assert_success
    run dest_git_config core.editor
    assert_output code
    run dest_git_config gpg.format
    assert_output ssh
    [ -L "${DEST}/.ssh/config.d/1password" ]

    # config.local overrides a layer setting.
    printf '[core]\n    editor = vim\n' > "${DEST}/.config/git/config.local"
    run dest_git_config core.editor
    assert_output vim

    DEST="${TEST_TMPDIR}/pi-home"
    DOTFILES_OS=linux run_link --persona server
    assert_success
    run dest_git_config core.pager
    assert_output delta
    run dest_git_config merge.tool
    assert_output vimdiff
    [ ! -e "${DEST}/.ssh/config.d" ]

    DEST="${TEST_TMPDIR}/sandbox-home"
    DOTFILES_OS=linux run_link --persona sandbox
    assert_success
    run dest_git_config core.pager
    assert_failure
}

@test "only the personal layer brings a git identity and the gh login" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    run_link --persona home
    assert_success
    refute_output --partial "No git identity"
    [ -f "${DEST}/.config/gh/hosts.yml" ]
    run dest_git_config user.email
    assert_output --partial smithbr@users.noreply.github.com

    # config.local still wins over the personal identity.
    printf '[user]\n    email = me@example.com\n' > "${DEST}/.config/git/config.local"
    run dest_git_config user.email
    assert_output me@example.com

    for persona in work sandbox; do
        DEST="${TEST_TMPDIR}/${persona}-home"
        run_link --persona "${persona}"
        assert_success
        run dest_git_config user.email
        assert_failure
        [ ! -e "${DEST}/.config/gh/hosts.yml" ]
        run_link --persona "${persona}"
        assert_output --partial "No git identity for persona '${persona}'"
        run_link --persona "${persona}" status
        assert_line "unset ${DEST}/.config/git/config.local"

        printf '[user]\n    email = me@work.example\n' > "${DEST}/.config/git/config.local"
        run_link --persona "${persona}"
        refute_output --partial "No git identity"
    done
}

@test "a [user] in ~/.gitconfig is reported because it overrides config.local" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    printf '[user]\n    email = old@example.com\n' > "${DEST}/.gitconfig"
    run_link --persona work
    assert_success
    assert_output --partial "${DEST}/.gitconfig sets [user]"
    run_link --persona work status
    assert_line "shadowed ${DEST}/.gitconfig"
    [ "$(cat "${DEST}/.gitconfig")" = "$(printf '[user]\n    email = old@example.com')" ]

    printf '[filter "lfs"]\n    required = true\n' > "${DEST}/.gitconfig"
    run_link --persona work status
    refute_line "shadowed ${DEST}/.gitconfig"
}

@test "status names real files a layer the persona does not link would own" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    mkdir -p "${DEST}/.config/restic" "${DEST}/.config/git" "${DEST}/.local/bin"
    printf 'secret\n' > "${DEST}/.config/restic/b2.env"
    printf 'old copy\n' > "${DEST}/.local/bin/cf-cert"
    printf '[user]\n    email = me@work.example\n' > "${DEST}/.config/git/config.local"
    run_link --persona work
    assert_success

    run_link --persona work status
    assert_success
    assert_output "unlinked ${DEST}/.config/restic
unlinked ${DEST}/.local/bin/cf-cert"
    [ "$(cat "${DEST}/.config/restic/b2.env")" = secret ]
    [ "$(cat "${DEST}/.local/bin/cf-cert")" = 'old copy' ]

    # A persona that links the layer does not report its folder.
    rm "${DEST}/.local/bin/cf-cert"
    run_link --persona home
    assert_success
    run_link --persona home status
    refute_output --partial unlinked
}

# Links a run of the single-layer layout left: every tool under stow/common.
plant_single_layer_links() {
    local name
    mkdir -p "${DEST}/.local/bin" "${DEST}/.config/ghostty"
    for name in sshkey ph-update ph-agent-setup; do
        ln -s "${PROJECT_ROOT}/stow/common/.local/bin/${name}" "${DEST}/.local/bin/${name}"
    done
    ln -s "${PROJECT_ROOT}/stow/common/.config/ghostty/config" "${DEST}/.config/ghostty/config"
}

@test "moving to layers relinks what the persona keeps and removes the rest" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    plant_single_layer_links
    run_link --persona home
    assert_success
    refute_output --partial "Backed up"
    [ "$(readlink "${DEST}/.local/bin/sshkey")" = "../../.dotfiles/stow/tools/.local/bin/sshkey" ] \
        || [ "$(cd "${DEST}/.local/bin" && cd -P "$(dirname "$(readlink sshkey)")" && pwd)" = "${PROJECT_ROOT}/stow/tools/.local/bin" ]
    [ -e "${DEST}/.config/ghostty/config" ]
    [ ! -L "${DEST}/.local/bin/ph-update" ]
    [ ! -L "${DEST}/.local/bin/ph-agent-setup" ]
    [ ! -e "${DEST}/.local/state/dotfiles/clobbered" ]

    DEST="${TEST_TMPDIR}/pi-home"
    plant_single_layer_links
    DOTFILES_OS=linux run_link --persona server
    assert_success
    refute_output --partial "Backed up"
    [ -e "${DEST}/.local/bin/ph-update" ]
    [ -e "${DEST}/.local/bin/ph-agent-setup" ]
    [ ! -L "${DEST}/.config/ghostty/config" ]
    [ ! -e "${DEST}/.local/state/dotfiles/clobbered" ]
    DOTFILES_OS=linux run_link status
    assert_success
    assert_output ""
}

@test "installs prints what each persona installs" {
    run_link --persona work installs
    assert_success
    assert_output "brew=core work
brew_optional=macos
linux_optional="
    run_link --persona home installs
    assert_line "brew=core home personal"
    DOTFILES_OS=linux run_link --persona server installs
    assert_line "linux_optional=docker tailscale claude-code"
    assert_line "brew=core personal"
    DOTFILES_OS=linux run_link --persona sandbox installs
    assert_line "brew="
    assert_line "brew_optional="
}

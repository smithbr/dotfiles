#!/usr/bin/env bats
# Tests for scripts/link.sh — linking the stow packages, agent links and seed
# files into a scratch destination. The agents repo is a local fixture, so no
# test touches the network or the real home directory.

load test_helper
load link_helper

# ---------------------------------------------------------------------------
# Linking packages
# ---------------------------------------------------------------------------

@test "links every package file so the live file is the repo file" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    run_link
    assert_success

    [ -L "${DEST}/.zshenv" ]
    [ -L "${DEST}/.config/git/config" ]
    [ -L "${DEST}/.local/bin/df-doctor" ]
    [ -x "${DEST}/.local/bin/df-doctor" ]
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
            [ "$(readlink "${DEST}/Library/Application Support/${app}/User/${f}")" = "${REPO_ROOT}/editors/code/${f}" ]
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
    assert_output --partial "Would link ${dir}/settings.json -> editors/code/settings.json"
    [ ! -L "${dir}/keybindings.json" ] && [ ! -e "${dir}/settings.json" ]
    [ ! -e "${DEST}/Library/Application Support/Cursor" ]
}

@test "replaces an identical copy without keeping a backup" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    mkdir -p "${DEST}/.config/git"
    cp "$(package_file common/.config/git/ignore)" "${DEST}/.config/git/ignore"

    run_link
    assert_success
    assert_output --partial "Removed identical copy ${DEST}/.config/git/ignore"
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
    local before="${TEST_TMPDIR}/before"
    dest_paths > "${before}"

    run_link
    assert_success
    refute_output --partial "Backed up"
    refute_output --partial "Created"
    refute_output --partial "Removed"
    refute_output --partial "Linked "
    # diff, so a failure prints the paths that changed.
    run diff "${before}" <(dest_paths)
    assert_success
}

@test "a run names each link it makes and sums up every step" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    run_link
    assert_success
    assert_output --partial "Linking persona home (default for darwin) into ${DEST}, layers: common, tools"
    assert_output --partial "Linked ${DEST}/.zshenv -> stow/common/.zshenv"
    assert_output --partial "Linked ${DEST}/.claude/CLAUDE.md -> ${DEST}/.config/agents/AGENTS.md"
    assert_output --partial "Agents checkout ${DEST}/.config/agents: cloned from ${AGENTS_REPO_URL}"
    local bundles
    bundles="$(sed -n 's/^skills=//p' "${PROJECT_ROOT}/personas/home" | sed 's/ /, /g')"
    assert_output --partial "Skill bundles ${bundles}: stowed into ${DEST}/.agents/skills"
    assert_output --regexp "Seed files: 0 of [0-9]+ were present"
    assert_output --regexp "Layers common, tools, [a-z, .]*desktop: [0-9]+ of [0-9]+ linked"
    local summary
    summary="$(grep '^Done: ' <<< "${output}")"
    [[ "${summary}" =~ ^Done:\ ([0-9]+)\ of\ ([0-9]+)\ links\ in\ place,\ ([0-9]+)\ new ]]
    [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ]
    [ "${BASH_REMATCH[3]}" = "${BASH_REMATCH[2]}" ]

    run_link
    assert_success
    refute_output --partial "Linked "
    assert_output --partial "Agents checkout ${DEST}/.config/agents: pulled in the last 7 days"
    assert_output --regexp "Editor settings: ([0-9]+) of [0-9]+ linked, 0 new"
    assert_output --regexp "Done: [0-9]+ of [0-9]+ links in place, 0 new"
}

@test "shows paths under the home directory with a tilde" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    HOME="${DEST}" run_link
    assert_success
    assert_output --partial "into ~, layers:"
    assert_output --partial "Linked ~/.zshenv -> stow/common/.zshenv"
    refute_output --partial "${DEST}/.zshenv"
}

@test "tightens a private directory and says so once" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    mkdir -p "${DEST}/.ssh"
    chmod 755 "${DEST}/.ssh"

    run_link
    assert_success
    assert_output --partial "Set ${DEST}/.ssh to mode 700"
    [ "$(stat_mode "${DEST}/.ssh")" = 700 ]
    run_link
    assert_success
    refute_output --partial "to mode 700"
}

@test "dry run lists the links it would make instead of stow's preview" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    run_link --dry-run
    assert_success
    assert_output --partial "Dry run, nothing changes. Would link persona home"
    assert_output --partial "Would link ${DEST}/.zshenv -> stow/common/.zshenv"
    assert_output --regexp "Dry run done: 0 of [0-9]+ links in place"
    refute_output --partial "LINK:"
    refute_output --partial "simulation mode"
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
    mkdir -p "${DEST}/.config/git"
    printf 'my local edit\n' > "${DEST}/.config/git/ignore"

    run env PATH="${NO_STOW_PATH}" bash "${PROJECT_ROOT}/${LINK}" --destination "${DEST}" --dry-run
    assert_success
    assert_output --partial "Would back up ${DEST}/.config/git/ignore"
    [ "$(cat "${DEST}/.config/git/ignore")" = 'my local edit' ]
}

@test "a real run without stow fails before moving anything" {
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

@test "server links Claude Code and Codex to the agents repo and home adds Cursor" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    run_link --persona server
    assert_success
    [ -d "${DEST}/.config/agents/.git" ]
    [ ! -e "${DEST}/.claude/settings.json" ]
    [ "$(cat "${DEST}/.claude/CLAUDE.md")" = rules ]
    [ "$(cat "${DEST}/.codex/AGENTS.md")" = rules ]
    [ "$(stat_mode "${DEST}/.claude")" = 700 ]
    [ ! -e "${DEST}/.cursor" ]

    DEST="${TEST_TMPDIR}/home-home"
    run_link --persona home
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

@test "links a Homebrew CLI's own skill while the CLI is installed, then removes the link" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    local skill="${HOMEBREW_PREFIX}/opt/agent-browser/libexec/lib/node_modules/agent-browser/skills/agent-browser"
    mkdir -p "${skill}"
    printf 'browser\n' > "${skill}/SKILL.md"

    run_link --persona home --dry-run
    assert_success
    assert_output --partial "Would link ${DEST}/.agents/skills/agent-browser"
    [ ! -L "${DEST}/.agents/skills/agent-browser" ]

    run_link --persona home
    assert_success
    [ "$(readlink "${DEST}/.agents/skills/agent-browser")" = "${skill}" ]
    [ "$(cat "${DEST}/.claude/skills/agent-browser/SKILL.md")" = browser ]

    rm -rf "${HOMEBREW_PREFIX}/opt/agent-browser"
    run_link --persona home
    assert_success
    assert_output --partial "Removed ${DEST}/.agents/skills/agent-browser"
    [ ! -L "${DEST}/.agents/skills/agent-browser" ]
    [ -L "${DEST}/.agents/skills/demo" ]
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

@test "switching from home to server removes Cursor's links and leaves its settings alone" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    run_link --persona home
    assert_success
    printf '{"p":true}\n' > "${DEST}/.cursor/cli-config.json"

    run_link --persona server status
    assert_line "stale ${DEST}/.cursor/AGENTS.md"

    run_link --persona server
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

@test "a recent checkout is pulled only with --refresh" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    own_agents_fixture
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
    assert_output --regexp "Agents checkout ${DEST}/.config/agents: pulled [0-9a-f]+\.\.[0-9a-f]+"
    run_link --refresh
    assert_success
    assert_output --regexp "Agents checkout ${DEST}/.config/agents: already up to date at [0-9a-f]+"
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
    make_bare_repo
    run_bare_link --persona work
    assert_success
    stow --dir "${DEST}/.config/agents/skills" --target "${DEST}/.agents/skills" extra
    mkdir -p "${DEST}/.agents/skills/synced/mine"
    printf '{"hints":true}\n' > "${DEST}/.cursor/cli-config.json"
    printf 'transcript\n' > "${DEST}/.cursor/ide_state.json"

    run_bare_link --persona bare status
    assert_line "stale ${DEST}/.cursor/AGENTS.md"
    assert_line "stale ${DEST}/.agents/skills/other"
    assert_line "unused ${DEST}/.config/agents"

    run_bare_link --persona bare
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

    run_bare_link --persona bare status
    assert_success
    refute_line --partial "stale"
    assert_line "unused ${DEST}/.config/agents"
    run_bare_link --persona bare managed
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
    assert_line "${DEST}/.cursor/AGENTS.md"
    refute_line "${DEST}/.cursor/cli-config.json"
    assert_line "${DEST}/.cursor/skills"
    assert_line "${DEST}/.agents/skills"
    assert_line "${DEST}/.config/agents"
    refute_line "${DEST}/.config/Code/User/settings.json"

    # Server lists no Cursor and takes no editor settings.
    run_link --persona server managed
    assert_line "${DEST}/.claude/CLAUDE.md"
    assert_line "${DEST}/.codex/AGENTS.md"
    refute_line --partial "${DEST}/.cursor/"
    refute_line "${DEST}/Library/Application Support/Code/User/settings.json"
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
    assert_output --partial "Removed old link ${DEST}/.keep -> stow/linux/.keep"
    assert_output --partial "Linked ${DEST}/.keep -> stow/common/.keep"
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

@test "add describes each layer on a terminal, by its rule or else its files, and takes the answer by number or name" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    make_fixture_repo
    mkdir -p "${FIXTURE}/stow/desk.darwin/.config/app" "${FIXTURE}/stow/common/.local/bin"
    printf 'app\n' > "${FIXTURE}/stow/desk.darwin/.config/app/rc"
    printf 'tool\n' > "${FIXTURE}/stow/common/.local/bin/tool"
    printf 'os=darwin,linux\nlayers=common extra desk\nagents=yes\nskills=core\neditors=no\nbrew=\n' > "${FIXTURE}/personas/home"
    printf 'x\n' > "${DEST}/.rc"
    printf 'y\n' > "${DEST}/.rc2"
    printf 'z\n' > "${DEST}/.rc3"

    run_fixture_link_on_tty 2 --persona home add "${DEST}/.rc"
    assert_success
    assert_output --partial "Layer for the new files"
    assert_output --partial "1) common  config for a tool that every machine has (every persona)"
    assert_output --partial "2) extra   .config/extra (home)"
    assert_output --partial "3) desk    .config/app (home; macOS only)"
    assert_output --partial "Copied ~/.rc to stow/extra/.rc"
    [[ "$(cat "${FIXTURE}/stow/extra/.rc")" == "x" ]]
    [ -L "${DEST}/.rc" ]

    run_fixture_link_on_tty common --persona home add "${DEST}/.rc2"
    assert_success
    assert_output --partial "Copied ~/.rc2 to stow/common/.rc2"
    [ -L "${DEST}/.rc2" ]

    run_fixture_link_on_tty "" --persona home --dry-run add "${DEST}/.rc3"
    assert_failure
    assert_output --partial "No layer chosen"
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

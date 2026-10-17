#!/usr/bin/env bats
# Tests for scripts/link.sh — linking the stow packages, agent links and seed
# files into a scratch destination. The agents repo is a local fixture, so no
# test touches the network or the real home directory.

load test_helper

LINK="scripts/link.sh"

# Stands in for the private agents repo. Built once: link.sh only clones from
# it, so every test shares it; a test that commits to it copies it first
# (own_agents_fixture).
setup_file() {
    export AGENTS_FIXTURE="${BATS_FILE_TMPDIR}/agents-origin"
    mkdir -p "${AGENTS_FIXTURE}/skills/core/demo" "${AGENTS_FIXTURE}/skills/extra/other" \
        "${AGENTS_FIXTURE}/skills/vault/notes" \
        "${AGENTS_FIXTURE}/agents"
    # Every bundle a shipped persona asks for, so no run warns about one
    # missing (each warning is a gum process).
    local bundle
    for bundle in $(sed -n 's/^skills=//p' "${PROJECT_ROOT}"/personas/* | tr ' ' '\n' | sort -u); do
        mkdir -p "${AGENTS_FIXTURE}/skills/${bundle}/${bundle}-demo"
        printf 'skill\n' > "${AGENTS_FIXTURE}/skills/${bundle}/${bundle}-demo/SKILL.md"
    done
    printf 'rules\n' > "${AGENTS_FIXTURE}/AGENTS.md"
    printf 'agent\n' > "${AGENTS_FIXTURE}/agents/demo.md"
    printf 'skill\n' > "${AGENTS_FIXTURE}/skills/core/demo/SKILL.md"
    printf 'skill\n' > "${AGENTS_FIXTURE}/skills/extra/other/SKILL.md"
    printf 'skill\n' > "${AGENTS_FIXTURE}/skills/vault/notes/SKILL.md"
    git -C "${AGENTS_FIXTURE}" init -q
    git -C "${AGENTS_FIXTURE}" add -A
    git -C "${AGENTS_FIXTURE}" -c user.name=test -c user.email=test@example.com commit -q -m fixture
}

# A private copy of the agents fixture for a test that changes it.
own_agents_fixture() {
    cp -R "${AGENTS_FIXTURE}" "${TEST_TMPDIR}/agents-origin"
    AGENTS_FIXTURE="${TEST_TMPDIR}/agents-origin"
    export AGENTS_REPO_URL="file://${AGENTS_FIXTURE}"
}

setup() {
    setup_tmpdir
    DEST="${TEST_TMPDIR}/home"
    mkdir -p "${DEST}"
    export AGENTS_REPO_URL="file://${AGENTS_FIXTURE}"
    export DOTFILES_OS=darwin
    # Keeps the machine's own Homebrew (and its tool skills) out of the tests.
    export HOMEBREW_PREFIX="${TEST_TMPDIR}/brew"
}

teardown() {
    teardown_tmpdir
}

run_link() {
    run bash "${PROJECT_ROOT}/${LINK}" --destination "${DEST}" "$@"
}

# A copy of the repo whose personas also hold "bare": the common layer only,
# no agents, no editors, on either OS. No real persona is that spare.
make_bare_repo() {
    BARE="${TEST_TMPDIR}/bare-repo"
    mkdir -p "${BARE}/scripts"
    cp -R "${PROJECT_ROOT}/stow" "${PROJECT_ROOT}/editors" "${PROJECT_ROOT}/seed" "${PROJECT_ROOT}/personas" "${PROJECT_ROOT}/roles" "${BARE}/"
    cp "${PROJECT_ROOT}/scripts/link.sh" "${PROJECT_ROOT}/scripts/common.sh" "${BARE}/scripts/"
    printf 'os=darwin,linux\nlayers=common\nagents=no\nagent_apps=\nskills=\neditors=no\nbrew=\nbrew_optional=\nroles=\n' > "${BARE}/personas/bare"
}

run_bare_link() {
    run bash "${BARE}/scripts/link.sh" --repo "${BARE}" --destination "${DEST}" "$@"
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
    local before
    before="$(cd "${DEST}" && find . -print | LC_ALL=C sort)"

    run_link
    assert_success
    refute_output --partial "Backed up"
    refute_output --partial "Created"
    [ "$(cd "${DEST}" && find . -print | LC_ALL=C sort)" = "${before}" ]
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
    assert_output --regexp "Layers common, tools, [a-z, .]*desktop.darwin: [0-9]+ of [0-9]+ linked"
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
    write_test_persona "${FIXTURE}" yes
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

# Runs link.sh with stdin on a pseudo-terminal and the answer typed there,
# since the layer prompt asks only on a terminal. Output is what the terminal
# showed, with its line endings normalized.
run_fixture_link_on_tty() {
    local answer="$1"
    shift
    command -v python3 >/dev/null 2>&1 || skip "python3 not available"
    run python3 - "${answer}" bash "${PROJECT_ROOT}/${LINK}" --repo "${FIXTURE}" --destination "${DEST}" "$@" <<'PY'
import os, pty, sys
answer, cmd = sys.argv[1], sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    os.environ["DOTFILES_PROMPT"] = "read"
    os.execvp(cmd[0], cmd)
os.write(fd, (answer + "\n").encode())
out = b""
while True:
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    out += chunk
_, status = os.waitpid(pid, 0)
sys.stdout.write(out.decode(errors="replace").replace("\r\n", "\n"))
sys.exit(status >> 8 if os.WIFEXITED(status) else 1)
PY
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

# ---------------------------------------------------------------------------
# Removing files
# ---------------------------------------------------------------------------

# The fixture repo with an executable tool and an app directory of two files
# committed in common, all linked into the destination.
make_linked_fixture() {
    make_fixture_repo
    mkdir -p "${FIXTURE}/stow/common/.local/bin" "${FIXTURE}/stow/common/.config/app/themes"
    printf '#!/bin/sh\necho tool\n' > "${FIXTURE}/stow/common/.local/bin/tool"
    chmod 750 "${FIXTURE}/stow/common/.local/bin/tool"
    printf 'a\n' > "${FIXTURE}/stow/common/.config/app/config"
    printf 'b\n' > "${FIXTURE}/stow/common/.config/app/themes/dark"
    git -C "${FIXTURE}" add -A
    git -C "${FIXTURE}" -c user.name=test -c user.email=test@example.com commit -q -m three
    run_fixture_link
    assert_success
    [ -L "${DEST}/.local/bin/tool" ] && [ -L "${DEST}/.config/app/themes/dark" ]
}

fixture_tracks() {
    git -C "${FIXTURE}" ls-files --error-unmatch -- "$1" >/dev/null 2>&1
}

# A bare "! cmd" never fails a Bats test, so the negation lives in a function.
fixture_untracks() {
    ! fixture_tracks "$1"
}

@test "rm keeps the file as a real copy with its mode and takes it out of the layer and the index" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    make_linked_fixture

    run_fixture_link rm "${DEST}/.local/bin/tool" < /dev/null
    assert_success
    assert_output --partial "Kept ~/.local/bin/tool as a real file"
    assert_output --partial "Removed stow/common/.local/bin/tool from the repo"
    assert_output --partial "/fixture commit"
    assert_output --partial "run df-rm on it before pulling"

    [ -f "${DEST}/.local/bin/tool" ] && [ ! -L "${DEST}/.local/bin/tool" ]
    [ "$(cat "${DEST}/.local/bin/tool")" = "$(printf '#!/bin/sh\necho tool')" ]
    [ "$(stat_mode "${DEST}/.local/bin/tool")" = 750 ]
    [ ! -e "${FIXTURE}/stow/common/.local/bin/tool" ]
    [ ! -e "${FIXTURE}/stow/common/.local" ]
    [ -d "${FIXTURE}/stow/common" ]
    fixture_untracks stow/common/.local/bin/tool
    [ -z "$(find "${DEST}/.local/bin" -name '.df-rm.*')" ]

    # The next link run leaves the real file alone.
    run_fixture_link
    assert_success
    [ -f "${DEST}/.local/bin/tool" ] && [ ! -L "${DEST}/.local/bin/tool" ]
}

@test "rm takes a directory and removes every managed link in it" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    make_linked_fixture
    printf 'mine\n' > "${DEST}/.config/app/local"
    ln -s /etc/hosts "${DEST}/.config/app/hosts"

    cd "${DEST}/.config"
    run_fixture_link rm app < /dev/null
    assert_success
    [ "$(cat "${DEST}/.config/app/config")" = a ] && [ ! -L "${DEST}/.config/app/config" ]
    [ "$(cat "${DEST}/.config/app/themes/dark")" = b ] && [ ! -L "${DEST}/.config/app/themes/dark" ]
    [ "$(readlink "${DEST}/.config/app/hosts")" = /etc/hosts ]
    [ "$(cat "${DEST}/.config/app/local")" = mine ]
    [ ! -e "${FIXTURE}/stow/common/.config/app" ]
    fixture_untracks stow/common/.config/app/config
    fixture_untracks stow/common/.config/app/themes/dark
    [ -L "${DEST}/.local/bin/tool" ]
    fixture_tracks stow/common/.local/bin/tool
}

@test "rm refuses real files, foreign and non-repo links, and outside paths before changing anything" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    make_linked_fixture
    mkdir -p "${FIXTURE}/seed/common/.config/seeded" "${DEST}/.config/seeded"
    printf 'seed\n' > "${FIXTURE}/seed/common/.config/seeded/state"
    printf 'seed\n' > "${DEST}/.config/seeded/state"
    printf 'real\n' > "${DEST}/.real"
    ln -s /etc/hosts "${DEST}/.hosts"
    ln -s "${DEST}/.config/agents/AGENTS.md" "${DEST}/.agents-md"
    printf 'outside\n' > "${TEST_TMPDIR}/outside"
    local before
    before="$(git -C "${FIXTURE}" status --porcelain)"

    for path in .real .hosts .agents-md .config/seeded/state "Library/Application Support/Code/User/settings.json"; do
        run_fixture_link rm "${DEST}/.local/bin/tool" "${DEST}/${path}" < /dev/null
        assert_failure
        assert_output --partial "Not removing ~/${path}"
        refute_output --partial "Kept"
    done
    run_fixture_link rm "${DEST}/.config/seeded/state" < /dev/null
    assert_output --partial "a seed file"
    run_fixture_link rm "${DEST}/.hosts" < /dev/null
    assert_output --partial "links outside the repo"
    run_fixture_link rm "${DEST}/.local/bin/tool" "${TEST_TMPDIR}/outside" < /dev/null
    assert_failure
    assert_output --partial "Not inside"
    run_fixture_link rm "${DEST}" < /dev/null
    assert_failure
    assert_output --partial "Not inside"
    run_fixture_link rm "${DEST}/.config/seeded" < /dev/null
    assert_failure
    assert_output --partial "No managed files to remove"

    [ -L "${DEST}/.local/bin/tool" ]
    fixture_tracks stow/common/.local/bin/tool
    [ "$(git -C "${FIXTURE}" status --porcelain)" = "${before}" ]
    [ "$(readlink "${DEST}/.hosts")" = /etc/hosts ]
    [ "$(cat "${DEST}/.real")" = real ]
}

@test "rm dry run changes nothing" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    make_linked_fixture

    run_fixture_link --dry-run rm "${DEST}/.local/bin/tool" < /dev/null
    assert_success
    assert_output --partial "Would replace the link ~/.local/bin/tool with a copy of stow/common/.local/bin/tool"
    run_fixture_link --dry-run rm --delete "${DEST}/.local/bin/tool" < /dev/null
    assert_success
    assert_output --partial "Would move ~/.local/bin/tool to ${DEST}/.local/state/dotfiles/cleanup/"

    [ -L "${DEST}/.local/bin/tool" ]
    [ -f "${FIXTURE}/stow/common/.local/bin/tool" ]
    fixture_tracks stow/common/.local/bin/tool
    [ -z "$(git -C "${FIXTURE}" status --porcelain)" ]
    [ ! -e "${DEST}/.local/state/dotfiles/cleanup" ]
}

@test "rm --delete moves the file to the cleanup folder instead of keeping it" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    make_linked_fixture

    run_fixture_link rm --delete "${DEST}/.local/bin/tool" < /dev/null
    assert_success
    assert_output --partial "Moved ~/.local/bin/tool to ${DEST}/.local/state/dotfiles/cleanup/"
    [ ! -e "${DEST}/.local/bin/tool" ] && [ ! -L "${DEST}/.local/bin/tool" ]
    local archived
    archived="$(find "${DEST}/.local/state/dotfiles/cleanup" -path '*.remove/.local/bin/tool')"
    [ -n "${archived}" ] && [ ! -L "${archived}" ]
    [ "$(stat_mode "${archived}")" = 750 ]
    grep -q 'echo tool' "${archived}"
    [ "$(stat_mode "${archived%/.local/bin/tool}")" = 700 ]
    fixture_untracks stow/common/.local/bin/tool

    run_fixture_link --delete status
    assert_failure
    assert_output --partial "--delete only applies to rm"
}

# ---------------------------------------------------------------------------
# Moving files between layers
# ---------------------------------------------------------------------------

# The linked fixture with home linking common and extra, server also linking
# solo, a layer home does not, and work linking only common.
make_move_fixture() {
    make_linked_fixture
    local name layers
    for name in home server work; do
        case "${name}" in
            home) layers="common extra" ;;
            server) layers="common extra solo" ;;
            work) layers="common" ;;
        esac
        printf 'os=darwin,linux\nlayers=%s\nagents=yes\nagent_apps=claude cursor codex\nskills=core\neditors=yes\nbrew=\nbrew_optional=\nroles=\n' \
            "${layers}" > "${FIXTURE}/personas/${name}"
    done
    git -C "${FIXTURE}" add -A
    git -C "${FIXTURE}" -c user.name=test -c user.email=test@example.com commit -q -m four
    run_fixture_link
    assert_success
}

# Where a link in the destination points inside the fixture's stow/.
linked_package_path() {
    local text
    text="$(readlink "$1")"
    printf '%s\n' "stow/${text##*/stow/}"
}

@test "mv moves a file to another layer and keeps it linked" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    make_move_fixture

    run_fixture_link mv --layer extra "${DEST}/.local/bin/tool" < /dev/null
    assert_success
    assert_output --partial "Moved stow/common/.local/bin/tool to stow/extra/.local/bin/tool; ~/.local/bin/tool links there"
    assert_output --partial "/fixture commit"
    assert_output --partial "one whose persona does not link 'extra' (linked by home, server) loses the file there"

    [ -L "${DEST}/.local/bin/tool" ] && [ -x "${DEST}/.local/bin/tool" ]
    [ "$(cat "${DEST}/.local/bin/tool")" = "$(printf '#!/bin/sh\necho tool')" ]
    [ "$(linked_package_path "${DEST}/.local/bin/tool")" = stow/extra/.local/bin/tool ]
    [[ "$(readlink "${DEST}/.local/bin/tool")" != /* ]]
    [ ! -e "${FIXTURE}/stow/common/.local" ]
    run git -C "${FIXTURE}" diff --cached -M --name-status
    assert_output "$(printf 'R100\tstow/common/.local/bin/tool\tstow/extra/.local/bin/tool')"
    [ -z "$(find "${DEST}/.local/bin" -name '.df-mv.*')" ]

    # The next link run keeps the new link and backs nothing up.
    run_fixture_link
    assert_success
    [ "$(linked_package_path "${DEST}/.local/bin/tool")" = stow/extra/.local/bin/tool ]
    [ ! -e "${DEST}/.local/state/dotfiles/clobbered" ]
}

@test "mv --platform moves into this OS's part, keeps it by default, and --no-platform moves out" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    make_move_fixture

    run_fixture_link mv --layer common --platform "${DEST}/.local/bin/tool" < /dev/null
    assert_success
    assert_output --partial "every persona links 'common'"
    [ "$(linked_package_path "${DEST}/.local/bin/tool")" = stow/common.darwin/.local/bin/tool ]

    run_fixture_link mv --layer extra "${DEST}/.local/bin/tool" < /dev/null
    assert_success
    [ "$(linked_package_path "${DEST}/.local/bin/tool")" = stow/extra.darwin/.local/bin/tool ]
    [ ! -e "${FIXTURE}/stow/common.darwin/.local" ]

    run_fixture_link mv --layer extra --no-platform "${DEST}/.local/bin/tool" < /dev/null
    assert_success
    [ "$(linked_package_path "${DEST}/.local/bin/tool")" = stow/extra/.local/bin/tool ]
    [ "$(cat "${DEST}/.local/bin/tool")" = "$(printf '#!/bin/sh\necho tool')" ]
    [ -f "${FIXTURE}/stow/extra/.local/bin/tool" ]
    [ ! -e "${FIXTURE}/stow/extra.darwin/.local" ]
}

@test "mv takes a directory and moves every managed link in it" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    make_move_fixture
    printf 'mine\n' > "${DEST}/.config/app/local"
    ln -s /etc/hosts "${DEST}/.config/app/hosts"

    cd "${DEST}/.config"
    run_fixture_link mv --layer extra app < /dev/null
    assert_success
    [ "$(linked_package_path "${DEST}/.config/app/config")" = stow/extra/.config/app/config ]
    [ "$(linked_package_path "${DEST}/.config/app/themes/dark")" = stow/extra/.config/app/themes/dark ]
    [ "$(cat "${DEST}/.config/app/themes/dark")" = b ]
    [ "$(readlink "${DEST}/.config/app/hosts")" = /etc/hosts ]
    [ "$(cat "${DEST}/.config/app/local")" = mine ]
    [ ! -e "${FIXTURE}/stow/common/.config/app" ]
    [ "$(linked_package_path "${DEST}/.local/bin/tool")" = stow/common/.local/bin/tool ]
}

@test "mv asks for the layer on a terminal and needs one without it" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    make_move_fixture

    run_fixture_link mv "${DEST}/.local/bin/tool" < /dev/null
    assert_failure
    assert_output --partial "Name the layer with --layer (one of: common extra)"

    run_fixture_link_on_tty extra mv "${DEST}/.local/bin/tool"
    assert_success
    assert_output --partial "Layer to move the files to"
    [ "$(linked_package_path "${DEST}/.local/bin/tool")" = stow/extra/.local/bin/tool ]
}

@test "mv refuses bad paths, unlinked layers, the same place, and taken destinations with nothing changed" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    make_move_fixture
    mkdir -p "${FIXTURE}/seed/common/.config/seeded" "${DEST}/.config/seeded" "${FIXTURE}/stow/extra/.config/app"
    printf 'seed\n' > "${FIXTURE}/seed/common/.config/seeded/state"
    printf 'seed\n' > "${DEST}/.config/seeded/state"
    printf 'taken\n' > "${FIXTURE}/stow/extra/.config/app/config"
    printf 'real\n' > "${DEST}/.real"
    ln -s /etc/hosts "${DEST}/.hosts"
    ln -s "${DEST}/.config/agents/AGENTS.md" "${DEST}/.agents-md"
    printf 'outside\n' > "${TEST_TMPDIR}/outside"
    local before
    before="$(git -C "${FIXTURE}" status --porcelain)"

    for path in .real .hosts .agents-md .config/seeded/state "Library/Application Support/Code/User/settings.json"; do
        run_fixture_link mv --layer extra "${DEST}/.local/bin/tool" "${DEST}/${path}" < /dev/null
        assert_failure
        assert_output --partial "Not moving ~/${path}"
        refute_output --partial "Moved"
    done
    run_fixture_link mv --layer extra "${DEST}/.local/bin/tool" "${TEST_TMPDIR}/outside" < /dev/null
    assert_failure
    assert_output --partial "Not inside"

    run_fixture_link mv --layer solo "${DEST}/.local/bin/tool" < /dev/null
    assert_failure
    assert_output --partial "does not link layer 'solo' (linked by server)"
    run_fixture_link mv --layer common "${DEST}/.local/bin/tool" < /dev/null
    assert_failure
    assert_output --partial "Not moving ~/.local/bin/tool: already in stow/common"
    run_fixture_link mv --layer extra "${DEST}/.local/bin/tool" "${DEST}/.config/app" < /dev/null
    assert_failure
    assert_output --partial "Not moving ~/.config/app/config: stow/extra/.config/app/config already exists"
    run_fixture_link mv --layer extra --platform --no-platform "${DEST}/.local/bin/tool" < /dev/null
    assert_failure
    assert_output --partial "contradict"
    run_fixture_link rm --no-platform "${DEST}/.local/bin/tool" < /dev/null
    assert_failure
    assert_output --partial "--no-platform only applies to mv"

    [ "$(linked_package_path "${DEST}/.local/bin/tool")" = stow/common/.local/bin/tool ]
    [ "$(linked_package_path "${DEST}/.config/app/themes/dark")" = stow/common/.config/app/themes/dark ]
    [ "$(git -C "${FIXTURE}" status --porcelain)" = "${before}" ]
    [ "$(cat "${FIXTURE}/stow/extra/.config/app/config")" = taken ]
}

@test "mv dry run changes nothing" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    make_move_fixture

    run_fixture_link --dry-run mv --layer extra "${DEST}/.local/bin/tool" < /dev/null
    assert_success
    assert_output --partial "Would move stow/common/.local/bin/tool to stow/extra/.local/bin/tool and relink ~/.local/bin/tool"
    [ "$(linked_package_path "${DEST}/.local/bin/tool")" = stow/common/.local/bin/tool ]
    [ ! -e "${FIXTURE}/stow/extra/.local" ]
    [ -z "$(git -C "${FIXTURE}" status --porcelain)" ]
}

@test "mv lists references to the old repo path without editing them" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    make_move_fixture
    mkdir -p "${FIXTURE}/tests"
    printf 'first\nrun stow/common/.local/bin/tool here\n' > "${FIXTURE}/tests/check"
    git -C "${FIXTURE}" add -A
    git -C "${FIXTURE}" -c user.name=test -c user.email=test@example.com commit -q -m refs

    run_fixture_link mv --layer extra "${DEST}/.local/bin/tool" < /dev/null
    assert_success
    assert_output --partial "References to stow/common/.local/bin/tool, left for you to update:"
    assert_output --partial "  tests/check:2:run stow/common/.local/bin/tool here"
    grep -q 'stow/common/.local/bin/tool' "${FIXTURE}/tests/check"
}

@test "mv renames the repo file of a link renamed in ~ and keeps its layer" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    make_move_fixture
    mv "${DEST}/.config/app/config" "${DEST}/.config/app/settings"

    run_fixture_link --dry-run mv "${DEST}/.config/app/settings" < /dev/null
    assert_success
    assert_output --partial "Would move stow/common/.config/app/config to stow/common/.config/app/settings and relink ~/.config/app/settings"
    [ -z "$(git -C "${FIXTURE}" status --porcelain)" ]

    run_fixture_link mv "${DEST}/.config/app/settings" < /dev/null
    assert_success
    assert_output --partial "Moved stow/common/.config/app/config to stow/common/.config/app/settings; ~/.config/app/settings links there"
    assert_output --partial "Renamed 1 file(s) in the repo to match ~"
    refute_output --partial "Layer to move"
    [ "$(cat "${DEST}/.config/app/settings")" = a ]
    [ "$(linked_package_path "${DEST}/.config/app/settings")" = stow/common/.config/app/settings ]
    run git -C "${FIXTURE}" diff --cached -M --name-status
    assert_output "$(printf 'R100\tstow/common/.config/app/config\tstow/common/.config/app/settings')"

    # The next link run keeps the new name and brings back nothing at the old one.
    run_fixture_link
    assert_success
    [ ! -e "${DEST}/.config/app/config" ] && [ ! -L "${DEST}/.config/app/config" ]
    [ "$(linked_package_path "${DEST}/.config/app/settings")" = stow/common/.config/app/settings ]
    [ ! -e "${DEST}/.local/state/dotfiles/clobbered" ]
}

@test "mv still asks for the layer of a renamed file on a terminal, defaulting to its own" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    make_move_fixture
    mv "${DEST}/.config/app/config" "${DEST}/.config/app/settings"
    mv "${DEST}/.config/app/themes/dark" "${DEST}/.config/app/themes/night"

    run_fixture_link_on_tty "" mv "${DEST}/.config/app/settings"
    assert_success
    assert_output --partial "Layer to move the files to"
    assert_output --partial "Choice [common]"
    assert_output --partial "Renamed 1 file(s) in the repo to match ~"
    [ "$(linked_package_path "${DEST}/.config/app/settings")" = stow/common/.config/app/settings ]

    run_fixture_link_on_tty extra mv "${DEST}/.config/app/themes/night"
    assert_success
    assert_output --partial "Moved 1 file(s) to layer extra"
    [ "$(linked_package_path "${DEST}/.config/app/themes/night")" = stow/extra/.config/app/themes/night ]
    [ "$(cat "${DEST}/.config/app/themes/night")" = b ]
}

@test "mv follows a link moved to another depth, whose old text no longer resolves" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    make_move_fixture
    mv "${DEST}/.local/bin/tool" "${DEST}/.config/tool"
    [ ! -e "${DEST}/.config/tool" ]

    run_fixture_link mv "${DEST}/.config/tool" < /dev/null
    assert_success
    [ -x "${DEST}/.config/tool" ]
    [ "$(cat "${DEST}/.config/tool")" = "$(printf '#!/bin/sh\necho tool')" ]
    [ "$(linked_package_path "${DEST}/.config/tool")" = stow/common/.config/tool ]
    [[ "$(readlink "${DEST}/.config/tool")" != /* ]]
    [ ! -e "${FIXTURE}/stow/common/.local" ]
}

@test "mv follows a renamed directory, and --layer changes the layer too" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    make_move_fixture
    mv "${DEST}/.config/app" "${DEST}/.config/app2"

    run_fixture_link mv --layer extra "${DEST}/.config/app2" < /dev/null
    assert_success
    [ "$(linked_package_path "${DEST}/.config/app2/config")" = stow/extra/.config/app2/config ]
    [ "$(linked_package_path "${DEST}/.config/app2/themes/dark")" = stow/extra/.config/app2/themes/dark ]
    [ "$(cat "${DEST}/.config/app2/themes/dark")" = b ]
    [ ! -e "${FIXTURE}/stow/common/.config/app" ]
}

@test "mv refuses a rename that add would refuse, with nothing changed" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    make_move_fixture
    mv "${DEST}/.config/app/config" "${DEST}/.config/app/config.local"

    run_fixture_link mv "${DEST}/.config/app/config.local" < /dev/null
    assert_failure
    assert_output --partial "Not moving ~/.config/app/config.local: a .local file holds this machine's overrides"
    [ -z "$(git -C "${FIXTURE}" status --porcelain)" ]
    [ -f "${FIXTURE}/stow/common/.config/app/config" ]
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
    assert_line "home"
    assert_line "work"
    DOTFILES_OS=linux run_link personas
    assert_success
    refute_line "home"
    assert_line "server"
    assert_line "vps"
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
    DOTFILES_PERSONA=server run_link persona
    assert_output "server env"
    DOTFILES_PERSONA=server run_link
    assert_success
    [ "$(persona_state)" = "server" ]
    # The flag wins over the environment.
    DOTFILES_PERSONA=server run_link --persona work persona
    assert_output "work flag"
}

@test "a dry run never saves the persona" {
    run_link --dry-run --persona work
    assert_success
    [ ! -e "${DEST}/.local/state/dotfiles/persona" ]
}

@test "a persona without agents or editors links only the shared files" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    make_bare_repo
    run_bare_link --persona bare
    assert_success
    [ -L "${DEST}/.zshenv" ]
    [ ! -e "${DEST}/.config/agents" ]
    [ ! -e "${DEST}/.cursor/AGENTS.md" ]
    [ ! -e "${DEST}/Library/Application Support/Code" ]

    run_bare_link managed
    refute_line "${DEST}/.config/agents"
    refute_line --partial "Application Support"
    run_bare_link status
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
    assert test -L "${DEST}/.config/ghostty/config.ghostty"
    [ -L "${DEST}/.local/bin/sshkey" ]
    [ -L "${DEST}/.local/bin/df-deploy" ]
    [ ! -e "${DEST}/.local/bin/ph-update" ]

    # A work Mac gets the shared tools but nothing personal or Pi-hole.
    DEST="${TEST_TMPDIR}/work-home"
    run_link --persona work
    assert_success
    [ -L "${DEST}/.local/bin/sshkey" ]
    for path in .local/bin/cf-cert .local/bin/df-deploy .local/bin/ts-test \
        .local/bin/ph-update .local/bin/ph-padd; do
        [ ! -e "${DEST}/${path}" ]
    done

    # The Pi-hole tools come with the pihole role, not the server persona.
    DEST="${TEST_TMPDIR}/pi-home"
    DOTFILES_OS=linux run_link --persona server
    assert_success
    [ ! -e "${DEST}/.local/bin/ph-update" ]
    [ -L "${DEST}/.local/bin/sshkey" ]
    DOTFILES_OS=linux DOTFILES_INSTALLS=pihole run_link --persona server
    assert_success
    [ -L "${DEST}/.local/bin/ph-update" ]
    [ -L "${DEST}/.local/bin/ph-backup" ]
    [ -L "${DEST}/.local/bin/sshkey" ]
    [ -L "${DEST}/.local/bin/cf-cert" ]
    [ -L "${DEST}/.local/bin/ts-test" ]
    [ ! -e "${DEST}/.config/ghostty" ]
    [ ! -e "${DEST}/.config/1Password" ]

    # A Mac server gets the shared tools but not the Linux-only Pi-hole ones.
    DEST="${TEST_TMPDIR}/mini-home"
    run_link --persona server
    assert_success
    [ -L "${DEST}/.local/bin/os-doctor" ]
    [ ! -e "${DEST}/.local/bin/ph-update" ]

    DEST="${TEST_TMPDIR}/vps-home"
    DOTFILES_OS=linux run_link --persona vps
    assert_success
    [ -L "${DEST}/.zshenv" ]
    [ -L "${DEST}/.local/bin/cf-cert" ]
    [ ! -e "${DEST}/.local/bin/ph-update" ]
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

    DEST="${TEST_TMPDIR}/vps-home"
    DOTFILES_OS=linux run_link --persona vps
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

    for persona in work; do
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
    assert_output --partial "then archive it with df-doctor"
    run_link --persona work status
    assert_line "shadowed ${DEST}/.gitconfig"
    [ "$(cat "${DEST}/.gitconfig")" = "$(printf '[user]\n    email = old@example.com')" ]

    printf '[filter "lfs"]\n    required = true\n' > "${DEST}/.gitconfig"
    run_link --persona work status
    refute_line "shadowed ${DEST}/.gitconfig"
}

@test "status names real files a layer the persona does not link would own" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    mkdir -p "${DEST}/.config/git" "${DEST}/.local/bin"
    printf 'old copy\n' > "${DEST}/.local/bin/cf-cert"
    printf '[user]\n    email = me@work.example\n' > "${DEST}/.config/git/config.local"
    run_link --persona work
    assert_success

    run_link --persona work status
    assert_success
    assert_output "unlinked ${DEST}/.local/bin/cf-cert"
    [ "$(cat "${DEST}/.local/bin/cf-cert")" = 'old copy' ]

    # A whole folder only an unlinked layer would own is named once, not per
    # file. A fresh home: here work has linked that folder already.
    local server_home="${TEST_TMPDIR}/server-home"
    mkdir -p "${server_home}/.config/ghostty"
    printf 'font-size = 14\n' > "${server_home}/.config/ghostty/config"
    DEST="${server_home}" run_link --persona server status
    assert_success
    assert_line "unlinked ${server_home}/.config/ghostty"
    refute_output --partial "ghostty/config"
    [ "$(cat "${server_home}/.config/ghostty/config")" = 'font-size = 14' ]

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
    for name in sshkey ph-update ph-backup; do
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
    assert test -L "${DEST}/.config/ghostty/config.ghostty"
    refute test -L "${DEST}/.config/ghostty/config"
    [ ! -L "${DEST}/.local/bin/ph-update" ]
    [ ! -L "${DEST}/.local/bin/ph-backup" ]
    [ ! -e "${DEST}/.local/state/dotfiles/clobbered" ]

    DEST="${TEST_TMPDIR}/pi-home"
    plant_single_layer_links
    DOTFILES_OS=linux DOTFILES_INSTALLS=pihole run_link --persona server
    assert_success
    refute_output --partial "Backed up"
    [ -e "${DEST}/.local/bin/ph-update" ]
    [ -e "${DEST}/.local/bin/ph-backup" ]
    [ ! -L "${DEST}/.config/ghostty/config" ]
    [ ! -e "${DEST}/.local/state/dotfiles/clobbered" ]
    DOTFILES_OS=linux run_link status
    assert_success
    assert_output ""
}

@test "installs prints what each persona installs, with the optional installs on by default but Holeberry off" {
    run_link --persona work installs
    assert_success
    assert_output "brew=core work
brew_optional=macos
harden=no
installs=claude-code
installs_source=default
install=claude-code	claude-code	tool_installed claude"
    run_link --persona home installs
    assert_line "brew=core home"
    assert_line "installs=claude-code"
    # Picked by name, Holeberry is still installed.
    DOTFILES_INSTALLS="holeberry claude-code" run_link --persona work installs
    assert_success
    assert_line "installs=holeberry claude-code"
    assert_line "installs_source=env"
    DOTFILES_OS=linux run_link --persona server installs
    assert_line "installs=docker tailscale claude-code"
    assert_line "brew=core"
    DOTFILES_OS=linux run_link --persona vps installs
    assert_line "brew=core"
    assert_line "brew_optional="
    assert_line "harden=yes"
    assert_line "installs=docker tailscale claude-code"
}

@test "a persona's harden setting must be yes or no" {
    local repo="${TEST_TMPDIR}/harden-repo"
    mkdir -p "${repo}/stow/common" "${repo}/personas"
    printf 'os=darwin,linux\nlayers=common\nagents=no\neditors=no\nharden=maybe\n' > "${repo}/personas/home"
    cp "${repo}/personas/home" "${repo}/personas/server"
    run bash "${PROJECT_ROOT}/scripts/link.sh" --destination "${DEST}" --repo "${repo}" installs
    assert_failure 2
    assert_output --partial "harden must be yes or no, not 'maybe'"
}

@test "offered lists the optional installs for this OS, then the persona's roles, with each detect command" {
    local hb_detect='[[ -d "${HOLEBERRY_APPS_DIR:-/Applications}/Holeberry.app" ]]'
    run_link --persona work offered
    assert_success
    assert_output "holeberry	optional	${hb_detect}
claude-code	default	tool_installed claude"
    run_link --persona server offered
    assert_output "holeberry	optional	${hb_detect}
claude-code	default	tool_installed claude"
    DOTFILES_OS=linux run_link --persona server offered
    assert_line --index 0 "docker	default	tool_installed docker"
    assert_line --index 1 "tailscale	default	tool_installed tailscale"
    assert_line --index 2 "claude-code	default	tool_installed claude"
    assert_line "pihole	optional	[[ -x /usr/bin/pihole-FTL && -x /usr/local/bin/pihole && -x /usr/sbin/unbound && -f /etc/unbound/unbound.conf.d/pi-hole.conf ]]"
    DOTFILES_OS=linux run_link --persona vps offered
    assert_line --index 0 "docker	default	tool_installed docker"
    refute_line --partial pihole
}

@test "optional installs are the setup scripts with a detect line, the OS directory first, on every persona" {
    make_bare_repo
    mkdir -p "${BARE}/scripts/bootstrap/linux" "${BARE}/scripts/bootstrap/macos"
    printf '#!/usr/bin/env bash\n# detect: command -v zed\n' > "${BARE}/scripts/bootstrap/zed.sh"
    printf '#!/usr/bin/env bash\n# detect: command -v docker\n' > "${BARE}/scripts/bootstrap/linux/docker.sh"
    printf '#!/usr/bin/env bash\n# detect: [[ -d /Applications/Docker.app ]]\n' > "${BARE}/scripts/bootstrap/macos/docker.sh"
    # A script without a detect line (an OS bootstrap, a role's setup) is not one.
    printf '#!/usr/bin/env bash\necho plain\n' > "${BARE}/scripts/bootstrap/plain.sh"
    DOTFILES_OS=linux run_bare_link --persona bare offered
    assert_success
    assert_output "docker	default	command -v docker
zed	default	command -v zed"
    DOTFILES_OS=darwin run_bare_link --persona bare offered
    assert_line --index 0 "docker	default	[[ -d /Applications/Docker.app ]]"
    DOTFILES_OS=linux run_bare_link --persona bare installs
    assert_line "installs=docker zed"
    assert_line "installs_source=default"
    assert_line "install=zed	zed	command -v zed"
    # A role may require an optional install, which then joins before it.
    printf 'os=darwin,linux\nrequires=zed\n' > "${BARE}/roles/needy"
    printf 'os=darwin,linux\nlayers=common\nagents=no\neditors=no\nroles_optional=needy\n' > "${BARE}/personas/bare"
    DOTFILES_OS=linux DOTFILES_INSTALLS="needy" run_bare_link --persona bare installs
    assert_success
    assert_line "installs=zed needy"
}

@test "chosen installs come from DOTFILES_INSTALLS, in run order with what they require, and add their layers" {
    DOTFILES_OS=linux DOTFILES_INSTALLS="pihole" run_link --persona server installs
    assert_success
    assert_line "installs=tailscale pihole"
    assert_line "installs_source=env"
    assert_line "install=pihole	pihole	[[ -x /usr/bin/pihole-FTL && -x /usr/local/bin/pihole && -x /usr/sbin/unbound && -f /etc/unbound/unbound.conf.d/pi-hole.conf ]]"
    # The pihole role brings the pihole layer; without it a Linux server has no ph-* tools.
    DOTFILES_OS=linux DOTFILES_INSTALLS="pihole" run_link --persona server managed
    assert_line "${DEST}/.local/bin/ph-update"
    DOTFILES_OS=linux DOTFILES_INSTALLS="" run_link --persona server managed
    refute_line "${DEST}/.local/bin/ph-update"

    DOTFILES_OS=linux DOTFILES_INSTALLS="pihole" run_link --persona vps installs
    assert_failure 2
    assert_output --partial "does not offer install 'pihole' on linux"
    DOTFILES_OS=linux DOTFILES_INSTALLS="docker" run_link --persona server installs
    assert_line "installs=docker"
}

@test "chosen installs are saved with the persona and a persona switch drops the ones it does not offer" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    DOTFILES_OS=linux DOTFILES_INSTALLS="pihole docker" run_link --persona server
    assert_success
    assert_output --partial "Saved installs tailscale pihole docker"
    [ "$(cat "${DEST}/.local/state/dotfiles/installs")" = "tailscale pihole docker" ]
    [ -L "${DEST}/.local/bin/ph-update" ]

    DOTFILES_OS=linux run_link installs
    assert_line "installs=tailscale pihole docker"
    assert_line "installs_source=saved"

    DOTFILES_OS=linux run_link --persona vps
    assert_success
    assert_output --partial "does not offer the saved install 'pihole'"
    [ ! -e "${DEST}/.local/bin/ph-update" ]
    DOTFILES_OS=linux DOTFILES_INSTALLS="" run_link --persona vps
    assert_output --partial "Saved installs none"
    [ "$(cat "${DEST}/.local/state/dotfiles/installs")" = "" ]

    DOTFILES_OS=linux DOTFILES_INSTALLS="docker" run_link --dry-run --persona server
    assert_success
    [ "$(cat "${DEST}/.local/state/dotfiles/installs")" = "" ]
}

@test "a persona naming a role the repo lacks, or a role requiring one, fails clearly" {
    make_bare_repo
    printf 'os=darwin,linux\nlayers=common\nagents=no\neditors=no\nroles=missing\n' > "${BARE}/personas/bare"
    run_bare_link --persona bare installs
    assert_failure 2
    assert_output --partial "no roles/missing for roles"
    printf 'os=darwin,linux\nrequires=nothing\n' > "${BARE}/roles/odd"
    printf 'os=darwin,linux\nlayers=common\nagents=no\neditors=no\nroles_optional=odd\n' > "${BARE}/personas/bare"
    DOTFILES_INSTALLS=odd run_bare_link --persona bare installs
    assert_failure 2
    assert_output --partial "roles/odd requires 'nothing', which neither roles/ nor scripts/bootstrap/ has"
}

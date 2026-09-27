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
    mkdir -p "${AGENTS_FIXTURE}/skills/demo" "${AGENTS_FIXTURE}/tools/claude"
    printf 'rules\n' > "${AGENTS_FIXTURE}/AGENTS.md"
    printf 'skill\n' > "${AGENTS_FIXTURE}/skills/demo/SKILL.md"
    printf '{}\n' > "${AGENTS_FIXTURE}/tools/claude/settings.json"
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

@test "clones the agents repo and links agent config into it" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    run_link
    assert_success
    [ -d "${DEST}/.config/agents/.git" ]
    [ "$(readlink "${DEST}/.claude/settings.json")" = "${DEST}/.config/agents/tools/claude/settings.json" ]
    [ "$(cat "${DEST}/.codex/AGENTS.md")" = rules ]
    [ -f "${DEST}/.agents/skills/demo/SKILL.md" ]
    [ "$(stat_mode "${DEST}/.claude")" = 700 ]
}

@test "moves real agent config aside and leaves unmanaged agent state alone" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    mkdir -p "${DEST}/.claude/skills/mine" "${DEST}/.claude/projects/sess"
    printf '{"iWroteThis":true}\n' > "${DEST}/.claude/settings.json"
    printf 'skill\n' > "${DEST}/.claude/skills/mine/SKILL.md"
    printf 'transcript\n' > "${DEST}/.claude/projects/sess/x.jsonl"
    printf 'overrides\n' > "${DEST}/.claude/settings.local.json"

    run_link
    assert_success
    [ -L "${DEST}/.claude/settings.json" ]
    [ -L "${DEST}/.claude/skills" ]
    run cat "$(backup_of .claude/settings.json)"
    assert_output '{"iWroteThis":true}'
    run cat "$(backup_of .claude/skills/mine/SKILL.md)"
    assert_output 'skill'
    [ "$(cat "${DEST}/.claude/projects/sess/x.jsonl")" = transcript ]
    [ "$(cat "${DEST}/.claude/settings.local.json")" = overrides ]
}

@test "an unreachable agents repo does not stop the rest of the install" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    AGENTS_REPO_URL="file://${TEST_TMPDIR}/missing" run_link
    assert_success
    assert_output --partial "Could not clone"
    [ -L "${DEST}/.zshenv" ]
    [ -L "${DEST}/.claude/settings.json" ]
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
    assert_line "${DEST}/.claude/settings.json"
    assert_line "${DEST}/.config/agents"
    refute_line "${DEST}/.config/Code/User/settings.json"
}

@test "status names each kind of drift" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    run_link
    assert_success

    rm "${DEST}/.bashrc"
    rm "${DEST}/.zshenv" && printf 'saved by an editor\n' > "${DEST}/.zshenv"
    rm "${DEST}/.config/git/ignore" && ln -s /somewhere/else "${DEST}/.config/git/ignore"
    rm -rf "${DEST}/.config/agents/skills"
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
    [ ! -e "${DEST}/.claude/CLAUDE.md" ]
    [ ! -e "${DEST}/Library/Application Support/Code" ]

    run_link managed
    refute_line "${DEST}/.config/agents"
    refute_line --partial "Application Support"
    run_link status
    assert_success
    assert_output ""
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
    [ ! -e "${DEST}/.local/bin/ph-update" ]

    DEST="${TEST_TMPDIR}/pi-home"
    DOTFILES_OS=linux run_link --persona server
    assert_success
    [ -L "${DEST}/.local/bin/ph-update" ]
    [ -L "${DEST}/.local/bin/ph-agent-setup" ]
    [ -L "${DEST}/.local/bin/sshkey" ]
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
    DOTFILES_OS=linux run_link --persona server installs
    assert_line "linux_optional=docker tailscale claude-code"
    DOTFILES_OS=linux run_link --persona sandbox installs
    assert_line "brew="
    assert_line "brew_optional="
}

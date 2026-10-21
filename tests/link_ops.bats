#!/usr/bin/env bats
# Tests for scripts/link.sh add, rm and mv, personas, layers and git identity,
# against the same fixtures as link.bats (link_helper.bash).

load test_helper
load link_helper

# ---------------------------------------------------------------------------
# Removing files
# ---------------------------------------------------------------------------

# The fixture repo with an executable tool and an app directory of two files
# committed in common, all linked into the destination. A function named as the
# argument changes the repo before the one link run.
make_linked_fixture() {
    make_fixture_repo
    mkdir -p "${FIXTURE}/stow/common/.local/bin" "${FIXTURE}/stow/common/.config/app/themes"
    printf '#!/bin/sh\necho tool\n' > "${FIXTURE}/stow/common/.local/bin/tool"
    chmod 750 "${FIXTURE}/stow/common/.local/bin/tool"
    printf 'a\n' > "${FIXTURE}/stow/common/.config/app/config"
    printf 'b\n' > "${FIXTURE}/stow/common/.config/app/themes/dark"
    git -C "${FIXTURE}" add -A
    git -C "${FIXTURE}" -c user.name=test -c user.email=test@example.com commit -q -m three
    [[ -z "${1:-}" ]] || "$1"
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
    make_linked_fixture write_move_personas
}

write_move_personas() {
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
    # A path the repo holds today: a file only in history is stale only when
    # git log can see it, and CI's checkout is shallow.
    ln -s "${PROJECT_ROOT}/stow/common/.config/ghostty/config.ghostty" "${DEST}/.config/ghostty/config.ghostty"
}

@test "moving to layers relinks what the persona keeps and removes the rest" {
    command -v stow >/dev/null 2>&1 || skip "stow not installed"
    plant_single_layer_links
    run_link --persona home
    assert_success
    refute_output --partial "Backed up"
    [ "$(readlink "${DEST}/.local/bin/sshkey")" = "../../.dotfiles/stow/tools/.local/bin/sshkey" ] \
        || [ "$(cd "${DEST}/.local/bin" && cd -P "$(dirname "$(readlink sshkey)")" && pwd)" = "${REPO_ROOT}/stow/tools/.local/bin" ]
    [ "$(cd "${DEST}/.config/ghostty" && cd -P "$(dirname "$(readlink config.ghostty)")" && pwd)" = "${REPO_ROOT}/stow/desktop/.config/ghostty" ]
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
    [ ! -L "${DEST}/.config/ghostty/config.ghostty" ]
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
    # A vps is asked whether it is a Pi-hole too.
    DOTFILES_OS=linux run_link --persona vps offered
    assert_line --index 0 "docker	default	tool_installed docker"
    assert_line --partial "pihole	optional	"
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

    DOTFILES_OS=darwin DOTFILES_INSTALLS="pihole" run_link --persona server installs
    assert_failure 2
    assert_output --partial "does not offer install 'pihole' on darwin"
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

    # Every Linux persona offers pihole; the same persona on macOS does not.
    DOTFILES_OS=darwin run_link --persona server
    assert_success
    assert_output --partial "does not offer the saved install 'pihole'"
    [ ! -e "${DEST}/.local/bin/ph-update" ]
    DOTFILES_OS=darwin DOTFILES_INSTALLS="" run_link --persona server
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

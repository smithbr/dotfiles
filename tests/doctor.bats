#!/usr/bin/env bats
# Tests for scripts/doctor.sh (df-doctor): the findings it reports, the
# list of changes, and the installer's use of it.
# shellcheck disable=SC2088 # "~/" is literal display text in expected output

load test_helper

DOCTOR="${PROJECT_ROOT}/scripts/doctor.sh"

setup() {
    setup_tmpdir
    TEST_JQ="$(command -v jq || true)"

    export HOME="${TEST_TMPDIR}/home"
    mkdir -p "${HOME}/.config/git" "${HOME}/.config/agents" "${HOME}/.local/bin" "${HOME}/Documents"
    printf '[user]\n    email = me@example.com\n' > "${HOME}/.config/git/config.local"
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
    printf '[include]\n    path = ~/.config/git/config.local\n' > "${TEST_SOURCE_DIR}/stow/common/.config/git/config"
    write_test_persona "${TEST_SOURCE_DIR}"
    mkdir -p "${HOME}/.config/agents/skills" "${HOME}/.agents/skills" "${HOME}/.config/agents/agents" "${HOME}/.config/agents/tools"
    for relative in .claude/skills .cursor/skills; do
        mkdir -p "$(dirname "${HOME}/${relative}")"
        ln -s "${HOME}/.agents/skills" "${HOME}/${relative}"
    done
    for relative in .claude/CLAUDE.md .codex/AGENTS.md .cursor/AGENTS.md; do
        mkdir -p "$(dirname "${HOME}/${relative}")"
        ln -s "${HOME}/.config/agents/AGENTS.md" "${HOME}/${relative}"
    done
    ln -s "${HOME}/.config/agents/agents" "${HOME}/.claude/agents"
    printf 'agents\n' > "${HOME}/.config/agents/AGENTS.md"
    printf '{}\n' > "${HOME}/.claude/settings.json"
    printf '{}\n' > "${HOME}/.cursor/cli-config.json"
    printf 'tool cache\n' > "${HOME}/.config/agents/tools/cache"

    # Commands the owner check can find, and no xdg-ninja data unless a test adds it.
    export BIN="${TEST_TMPDIR}/bin"
    mkdir -p "${BIN}"
    export DF_DOCTOR_PROGRAMS="${TEST_TMPDIR}/programs"
    mkdir -p "${DF_DOCTOR_PROGRAMS}"
    export PATH="${BIN}:/usr/bin:/bin"
}

teardown() {
    teardown_tmpdir
}

doctor() {
    run bash "${DOCTOR}" --source "${TEST_SOURCE_DIR}" "$@"
}

# doctor with stdin from the given text, through the numbered prompts.
doctor_answering() {
    local answers="$1"
    shift
    run bash -c 'printf "%b" "$1" | DOTFILES_PROMPT=read bash "$2" --source "$3" "${@:4}"' _ "${answers}" "${DOCTOR}" "${TEST_SOURCE_DIR}" "$@"
}

# doctor --fix with every row set to skip except each PICK: "VERB PATH" sets
# that path's row, a bare VERB every item's row. The row numbers come from a
# first run that changes nothing. Arguments after -- go to doctor.sh.
doctor_picking() {
    local list answer="none" line n path pick verb
    local -a picks=() args=()
    while [[ $# -gt 0 && "$1" != -- ]]; do
        picks+=("$1")
        shift
    done
    [[ $# -eq 0 ]] || { shift; args=("$@"); }
    list="$(printf 'none\n' | DOTFILES_PROMPT=read bash "${DOCTOR}" --source "${TEST_SOURCE_DIR}" ${args[@]+"${args[@]}"} --fix-only 2>&1 || true)"
    for pick in ${picks[@]+"${picks[@]}"}; do
        verb="${pick%% *}"
        answer+=" ${verb}"
        while IFS= read -r line; do
            [[ "${line}" =~ ^\ +([0-9]+)\)\ [a-z]+\ +([^ ]+) ]] || continue
            n="${BASH_REMATCH[1]}" path="${BASH_REMATCH[2]}"
            if [[ "${pick}" == "${verb}" && "${path}" == [~/]* ]] || [[ "${pick}" == "${verb} ${path}" ]]; then
                answer+=" ${n}"
            fi
        done <<< "${list}"
    done
    doctor_answering "${answer}\n" ${args[@]+"${args[@]}"} --fix
}

make_stale() {
    local dir
    for dir in "$@"; do
        find "${dir}" -exec touch -t 202001010000 {} +
    done
}

# xdg-ninja entries for the tests, and jq to read them.
write_xdg_fixture() {
    [[ -n "${TEST_JQ}" ]] || skip "jq not installed"
    ln -sf "${TEST_JQ}" "${BIN}/jq"
    cat > "${DF_DOCTOR_PROGRAMS}/fixtures.json" <<'JSON'
{
    "name": "movetool",
    "files": [
        { "path": "$HOME/.movetool", "movable": true,
          "help": "Supported by default.\n\nYou can move the directory to _$XDG_DATA_HOME/movetool_.\n" },
        { "path": "$HOME/.hinttool", "movable": true,
          "help": "Export the following environment variables:\n\n```bash\nexport HINTTOOL_HOME=\"$XDG_DATA_HOME\"/hinttool\n```\n" },
        { "path": "$HOME/.stuckapp", "movable": false, "help": "Currently unsupported." },
        { "path": "$HOME/.npmlike", "movable": true,
          "help": "You need to put the following into your npmrc:\n\n```dosini\nprefix=${XDG_DATA_HOME}/npm\n```\n" },
        { "path": "$HOME/.config/movetool", "movable": true, "help": "nested paths are ignored" }
    ]
}
JSON
}

# The repo's ~/.zshenv stub and a ZDOTDIR .zshenv exporting each VAR=PATH as a
# path under HOME, so a new zsh sees them whether or not /etc/zshenv sets ZDOTDIR.
write_zshenv() {
    local pair
    command -v zsh >/dev/null || skip "zsh not installed"
    mkdir -p "${HOME}/.config/zsh"
    cp "${PROJECT_ROOT}/stow/common/.zshenv" "${HOME}/.zshenv"
    : > "${HOME}/.config/zsh/.zshenv"
    for pair in "$@"; do
        # shellcheck disable=SC2016 # expanded by zsh
        printf 'export %s="${HOME}/%s"\n' "${pair%%=*}" "${pair#*=}" >> "${HOME}/.config/zsh/.zshenv"
    done
}

# --- The report ----------------------------------------------------------------

@test "the report sorts findings into Fix, Decide, and Ignore and changes nothing" {
    printf 'copy\n' > "${HOME}/.notes.bak"
    mkdir -p "${HOME}/.fresh-tool" "${HOME}/.stale-tool" "${HOME}/.true"
    touch "${HOME}/.fresh-tool/data" "${HOME}/.stale-tool/data" "${HOME}/.true/data"
    make_stale "${HOME}/.stale-tool"
    ln -s /usr/bin/true "${BIN}/true"
    local before
    before="$(cd "${HOME}" && find . -print | sort)"

    doctor
    assert_success
    assert_line "df-doctor ~"
    assert_line --regexp "^1 to fix · 3 to decide · 0 not in the repo · [0-9]+ ignored$"
    assert_output --regexp "Fix \(1\)[^"$'\n'"]*"$'\n'"  ~/\.notes\.bak +[0-9.]+[KMG]  archive: backup copy or leftover cache"
    assert_output --regexp "~/\.stale-tool +[0-9.]+[KMG]  no owner found; untouched for [0-9]+ days · likely leftover"
    assert_output --regexp "~/\.fresh-tool +[0-9.]+[KMG] +no owner found; changed today"
    assert_output --regexp "~/\.local/bin/ph-extra +[0-9.]+[KMG] +in ~/\.local/bin but cannot run"
    assert_output --partial "Ignore ("
    refute_output --partial "~/.true "
    assert_output --partial "Run df-doctor in a terminal (or with --fix) to choose a change for each item."
    # Private agents, the .example override, and folders without managed files stay out.
    refute_output --partial "~/.config/agents"
    refute_output --partial "config.local"
    refute_output --partial "todo.txt"
    [ "$(cd "${HOME}" && find . -print | sort)" = "${before}" ]
}

@test "--all lists the Ignore items one by one" {
    mkdir -p "${HOME}/.true"
    ln -s /usr/bin/true "${BIN}/true"
    doctor
    refute_output --regexp "~/\.true +in use by true"
    doctor --all
    assert_success
    assert_output --regexp "In use"$'\n'" +~/\.true +by true; changed today"
    refute_output --partial "(--all lists them)"
}

@test "repo links that are off come first, with what to do" {
    rm "${HOME}/.local/bin/ph-padd"
    printf 'edited copy\n' > "${HOME}/.local/bin/ph-padd"
    printf '[user]\n    email = old@example.com\n' > "${HOME}/.gitconfig"
    ln -s "${HOME}/missing-target" "${HOME}/.config/git/broken"
    printf 'managed\n' > "${TEST_SOURCE_DIR}/stow/common/.config/git/broken"

    doctor
    assert_success
    assert_output --partial "Links (3)  repair these, then run df-link"
    assert_output --partial "  ~/.local/bin/ph-padd  replaced"$'\n'"    a real file sits where a link belongs"
    assert_output --partial "  ~/.gitconfig  shadowed"$'\n'"    sets [user], which overrides ~/.config/git/config.local"
    assert_output --partial "  ~/.config/git/broken  foreign"$'\n'"    points somewhere other than the repo"
    assert test -L "${HOME}/.config/git/broken"
}

@test "working commands in ~/.local/bin are not in the repo, broken links and zsh caches are fixes" {
    printf '#!/bin/sh\n' > "${HOME}/.local/bin/mytool"
    chmod +x "${HOME}/.local/bin/mytool"
    ln -s "${HOME}/missing-tool" "${HOME}/.local/bin/broken-tool"
    mkdir -p "${HOME}/.config/zsh" "${TEST_SOURCE_DIR}/stow/common/.config/zsh"
    printf 'managed\n' > "${TEST_SOURCE_DIR}/stow/common/.config/zsh/.zshrc"
    ln -s "${TEST_SOURCE_DIR}/stow/common/.config/zsh/.zshrc" "${HOME}/.config/zsh/.zshrc"
    printf 'dump\n' > "${HOME}/.config/zsh/.zcompdump"

    doctor --tsv
    assert_success
    assert_line "unmanaged"$'\t'"${HOME}/.local/bin/mytool"$'\t'"keep"$'\t\t'"a command you installed"
    assert_line "fix"$'\t'"${HOME}/.local/bin/broken-tool"$'\t'"archive"$'\t\t'"broken link to ${HOME}/missing-tool"
    assert_line "decide"$'\t'"${HOME}/.local/bin/ph-extra"$'\t'"keep"$'\t\t'"in ~/.local/bin but cannot run; check what put it there"
    assert_line "fix"$'\t'"${HOME}/.config/zsh/.zcompdump"$'\t'"archive"$'\t\t'"old zsh completion cache; zsh rebuilds it"

    doctor
    assert_output --partial "Not in the repo (1)  config and commands made outside the repo"
    assert_output --regexp "  ~/\.local/bin/mytool +[0-9.]+[KMG] +a command you installed"
}

@test "config directly in ~/.config that the repo does not manage is listed" {
    mkdir -p "${HOME}/.config/owned-app" "${HOME}/.config/stale-app" "${HOME}/.config/fresh-app" "${TEST_TMPDIR}/elsewhere"
    touch "${HOME}/.config/owned-app/config" "${HOME}/.config/stale-app/config" "${HOME}/.config/fresh-app/config" "${HOME}/.config/.DS_Store"
    # brew trust writes it; brew.sh rebuilds it from the Brewfiles.
    mkdir -p "${HOME}/.config/homebrew"
    printf '{}\n' > "${HOME}/.config/homebrew/trust.json"
    make_stale "${HOME}/.config/stale-app"
    ln -s /usr/bin/true "${BIN}/owned-app"
    ln -s "${TEST_TMPDIR}/elsewhere" "${HOME}/.config/linked-app"
    ln -s "${HOME}/missing" "${HOME}/.config/broken-app"

    doctor --tsv
    assert_success
    assert_line --regexp "^unmanaged"$'\t'"${HOME}/\.config/owned-app"$'\t'"keep"$'\t\t'"owned-app is installed; changed today$"
    assert_line --regexp "^unmanaged"$'\t'"${HOME}/\.config/fresh-app"$'\t'"keep"$'\t\t'"no owner found; changed today$"
    assert_line --regexp "^decide"$'\t'"${HOME}/\.config/stale-app"$'\t'"archive"$'\t\t'"no owner found; untouched for [0-9]+ days$"
    assert_line "unmanaged"$'\t'"${HOME}/.config/linked-app"$'\t'"keep"$'\t\t'"links to ${TEST_TMPDIR}/elsewhere"
    assert_line "fix"$'\t'"${HOME}/.config/broken-app"$'\t'"archive"$'\t\t'"broken link to ${HOME}/missing"
    assert_line "ignore"$'\t'"${HOME}/.config/.DS_Store"$'\t'"keep"$'\t\t'"local state"
    assert_line "ignore"$'\t'"${HOME}/.config/homebrew"$'\t'"keep"$'\t\t'"local state"
    # A folder holding managed files is looked into, not listed whole; private agents stay out.
    refute_output --partial "${HOME}/.config/git"$'\t'
    refute_output --partial "${HOME}/.config/agents"
}

@test "the XDG places come from a new shell, and ~/.local/bin is checked without managed files" {
    mkdir -p "${HOME}/cfg/zz-app" "${HOME}/bin"
    touch "${HOME}/cfg/zz-app/config"
    printf '#!/bin/sh\n' > "${HOME}/bin/tool"
    chmod +x "${HOME}/bin/tool"
    write_zshenv XDG_CONFIG_HOME=cfg XDG_BIN_HOME=bin
    doctor --tsv
    assert_success
    assert_line --regexp "^unmanaged"$'\t'"${HOME}/cfg/zz-app"$'\t'
    assert_line "unmanaged"$'\t'"${HOME}/bin/tool"$'\t'"keep"$'\t\t'"a command you installed"
}

@test "saved backups are summarized and never offered" {
    mkdir -p "${HOME}/.local/state/dotfiles/clobbered/20260101-000000"
    doctor
    assert_success
    assert_output --partial "Backups: 1 saved copy under ~/.local/state/dotfiles"
    doctor --tsv
    refute_output --partial "clobbered"
}

@test "a path marked to ignore, and anything in it, is ignored until unignored" {
    local list="${HOME}/.local/state/dotfiles/doctor-ignore"
    mkdir -p "${HOME}/.config/fresh-app" "${HOME}/.config/other-app" "${HOME}/.config/zsh" "${TEST_SOURCE_DIR}/stow/common/.config/zsh"
    touch "${HOME}/.config/fresh-app/config" "${HOME}/.config/other-app/config"
    printf 'managed\n' > "${TEST_SOURCE_DIR}/stow/common/.config/zsh/.zshrc"
    ln -s "${TEST_SOURCE_DIR}/stow/common/.config/zsh/.zshrc" "${HOME}/.config/zsh/.zshrc"
    printf 'notes\n' > "${HOME}/.config/zsh/notes"
    printf 'dump\n' > "${HOME}/.config/zsh/.zcompdump"

    # A quoted ~ and a path relative to here both land as ~/ entries.
    doctor --ignore "~/.config/fresh-app"
    assert_success
    assert_output --partial "ignoring ~/.config/fresh-app (undo: df-doctor --unignore ~/.config/fresh-app)"
    run bash -c 'cd "$1/.config/fresh-app" && bash "$2" --source "$3" --ignore ../zsh/' _ "${HOME}" "${DOCTOR}" "${TEST_SOURCE_DIR}"
    assert_success
    assert_equal "$(cat "${list}")" "~/.config/fresh-app"$'\n'"~/.config/zsh"
    assert_equal "$(stat -c %a "${list}" 2>/dev/null || stat -f %Lp "${list}")" 600
    doctor --ignore "${HOME}/.config/zsh"
    assert_success
    assert_output --partial "already ignored ~/.config/zsh"
    assert_equal "$(wc -l < "${list}" | tr -d ' ')" 2

    doctor --tsv
    assert_success
    assert_line "ignore"$'\t'"${HOME}/.config/fresh-app"$'\t'"keep"$'\t\t'"marked to ignore"
    # Children of a marked folder, whatever group they would be in.
    assert_line "ignore"$'\t'"${HOME}/.config/zsh/notes"$'\t'"keep"$'\t\t'"marked to ignore"
    assert_line "ignore"$'\t'"${HOME}/.config/zsh/.zcompdump"$'\t'"keep"$'\t\t'"marked to ignore"
    # Unmarked paths are unchanged.
    assert_line --regexp "^unmanaged"$'\t'"${HOME}/\.config/other-app"$'\t'"keep"$'\t\t'"no owner found; changed today$"
    assert_line "decide"$'\t'"${HOME}/.local/bin/ph-extra"$'\t'"keep"$'\t\t'"in ~/.local/bin but cannot run; check what put it there"
    doctor
    assert_output --partial "3 marked to ignore"
    doctor --explain "${HOME}/.config/zsh/notes"
    assert_output --partial "df-doctor --unignore ~/.config/zsh reports it again."

    # Unignoring a child of a marked folder is refused and names the folder.
    doctor --unignore "${HOME}/.config/zsh/notes"
    assert_failure
    assert_output --partial "~/.config/zsh/notes is inside ~/.config/zsh; unignore that instead"
    doctor --unignore "~/.config/fresh-app"
    assert_success
    assert_output --partial "df-doctor reports ~/.config/fresh-app again."
    assert_equal "$(cat "${list}")" "~/.config/zsh"
    doctor --tsv
    assert_line --regexp "^unmanaged"$'\t'"${HOME}/\.config/fresh-app"$'\t'
    doctor --unignore "~/.config/fresh-app"
    assert_failure
    assert_output --partial "Not on the ignore list: ~/.config/fresh-app"

    # Only paths inside the destination, and never through a symlinked state folder.
    doctor --ignore "${TEST_TMPDIR}"
    assert_failure
    assert_output --partial "is not a plain path inside ~"
    rm -rf "${HOME}/.local/state/dotfiles"
    mkdir -p "${TEST_TMPDIR}/elsewhere"
    ln -s "${TEST_TMPDIR}/elsewhere" "${HOME}/.local/state/dotfiles"
    doctor --ignore "${HOME}/.config/other-app"
    assert_failure
    assert_output --partial "Ignore list path is a symlink"
    refute test -e "${TEST_TMPDIR}/elsewhere/doctor-ignore"
}

@test "classification follows xdg-ninja, the owner, and the last change" {
    write_xdg_fixture
    printf '#!/usr/bin/env bash\n' > "${BIN}/ownedtool"
    chmod +x "${BIN}/ownedtool"
    ln -s /usr/bin/true "${BIN}/ownedstale"
    mkdir -p "${HOME}/.hinttool" "${HOME}/.npmlike" "${HOME}/.stuckapp" "${HOME}/.ownedtool" \
        "${HOME}/.zzactive" "${HOME}/.zzorphan/sub" "${HOME}/.ownedstale" "${HOME}/.1password"
    touch "${HOME}/.zzorphan/sub/data" "${HOME}/.ownedstale/data"
    make_stale "${HOME}/.zzorphan" "${HOME}/.ownedstale" "${HOME}/.1password"

    doctor --tsv
    assert_success
    # shellcheck disable=SC2016 # literal export text
    assert_line "decide"$'\t'"${HOME}/.hinttool"$'\t'"keep"$'\t\t'"movetool supports XDG"
    assert_line "decide"$'\t'"${HOME}/.npmlike"$'\t'"keep"$'\t\t'"movetool supports XDG"
    assert_line "ignore"$'\t'"${HOME}/.stuckapp"$'\t'"keep"$'\t\t'"movetool: no XDG support"
    assert_line --regexp "^ignore"$'\t'"${HOME}/\.ownedtool"$'\t'"keep"$'\t\t'"in use by ownedtool; changed today$"
    assert_line --regexp "^decide"$'\t'"${HOME}/\.zzactive"$'\t'"keep"$'\t\t'"no owner found; changed today$"
    assert_line --regexp "^decide"$'\t'"${HOME}/\.ownedstale"$'\t'"keep"$'\t\t'"ownedstale is installed, but this is untouched for [0-9]{4,} days$"
    assert_line --regexp "^decide"$'\t'"${HOME}/\.zzorphan"$'\t'"archive"$'\t\t'"no owner found; untouched for [0-9]{4,} days$"
    assert_line --regexp "^ignore"$'\t'"${HOME}/\.1password"$'\t'"keep"$'\t\t'"1Password SSH agent socket link"
    refute_output --partial "${HOME}/.config/movetool"

    # The report shows xdg-ninja's advice on a how: line.
    doctor
    # shellcheck disable=SC2016 # literal export text
    assert_output --regexp '~/\.hinttool +[0-9.]+[KMG] +movetool supports XDG'$'\n'' +how: export HINTTOOL_HOME="\$XDG_DATA_HOME"/hinttool'

    # --days moves the line between untouched and in use.
    doctor --tsv --days 999999
    assert_line --regexp "^decide"$'\t'"${HOME}/\.zzorphan"$'\t'"keep"$'\t\t'"no owner found; changed [0-9]+ days ago$"
}

@test "files the OS made are normal or critical while their owner is installed, else leftovers" {
    export DF_DOCTOR_ROOT="${TEST_TMPDIR}/root"
    mkdir -p "${DF_DOCTOR_ROOT}/bin" "${DF_DOCTOR_ROOT}/usr/bin" "${DF_DOCTOR_ROOT}/usr/lib/aarch64-linux-gnu"
    touch "${DF_DOCTOR_ROOT}/bin/sh" "${DF_DOCTOR_ROOT}/usr/bin/xdg-user-dirs-update" "${DF_DOCTOR_ROOT}/usr/lib/aarch64-linux-gnu/libgtk-3.so.0"
    mkdir -p "${HOME}/.config/dconf" "${HOME}/.config/gtk-3.0"
    touch "${HOME}/.profile" "${HOME}/.config/user-dirs.dirs" "${HOME}/.config/user-dirs.locale" "${HOME}/.config/gnome-initial-setup-done"
    make_stale "${HOME}/.profile" "${HOME}/.config"

    doctor --tsv
    assert_success
    assert_line --regexp "^ignore"$'\t'"${HOME}/\.profile"$'\t'"keep"$'\t\t'"critical: read by every login shell"
    assert_line --regexp "^ignore"$'\t'"${HOME}/\.config/user-dirs\.dirs"$'\t'"keep"$'\t\t'"critical: where Desktop, Downloads"
    assert_line --regexp "^ignore"$'\t'"${HOME}/\.config/user-dirs\.locale"$'\t'"keep"$'\t\t'"normal: the language"
    # A glob in the evidence matches any architecture's library folder.
    assert_line --regexp "^ignore"$'\t'"${HOME}/\.config/gtk-3\.0"$'\t'"keep"$'\t\t'"normal: GTK 3"
    assert_line --regexp "^decide"$'\t'"${HOME}/\.config/dconf"$'\t'"archive"$'\t\t'"the settings database .*; nothing installed uses it any more, so it is a leftover$"
    assert_line --regexp "^decide"$'\t'"${HOME}/\.config/gnome-initial-setup-done"$'\t'"archive"$'\t\t'"GNOME's first-login marker.*leftover$"

    # The report counts them, and --all lists them with their level.
    doctor --all
    assert_output --partial "4 made by the OS (2 critical)"
    assert_output --partial "Made by the OS (critical: removing it breaks something)"
    assert_output --regexp '~/\.config/user-dirs\.locale +normal: the language the user folders were named in'

    # Installing the owner turns the leftover into a critical file to keep.
    mkdir -p "${DF_DOCTOR_ROOT}/usr/libexec"
    touch "${DF_DOCTOR_ROOT}/usr/libexec/dconf-service"
    doctor --tsv
    assert_line --regexp "^ignore"$'\t'"${HOME}/\.config/dconf"$'\t'"keep"$'\t\t'"critical: the settings database"
}

@test "an entry a new shell redirects is the old copy, named by the variable that matches it" {
    write_xdg_fixture
    cat > "${DF_DOCTOR_PROGRAMS}/twovar.json" <<'JSON'
{ "name": "twovar", "files": [ { "path": "$HOME/.twovar", "movable": true,
  "help": "Export the following environment variables:\n\n```bash\nexport TWOVAR_INIT=\"$XDG_CONFIG_HOME\"/twovar/init.js\nexport TWOVAR_CACHE=\"$XDG_CACHE_HOME\"/twovar\n```\n" } ] }
JSON
    mkdir -p "${HOME}/.twovar" "${HOME}/.hinttool"

    # Exported only in this shell: a new shell would not see it.
    run env TWOVAR_CACHE="${HOME}/.cache/twovar" bash "${DOCTOR}" --source "${TEST_SOURCE_DIR}" --tsv
    assert_line "decide"$'\t'"${HOME}/.twovar"$'\t'"keep"$'\t\t'"twovar supports XDG"

    write_zshenv TWOVAR_INIT=.config/twovar/init.js TWOVAR_CACHE=.cache/twovar HINTTOOL_HOME=.hinttool
    doctor --tsv
    assert_success
    assert_line "fix"$'\t'"${HOME}/.twovar"$'\t'"archive"$'\t\t'"twovar now uses ~/.cache/twovar (\$TWOVAR_CACHE); this is the old copy"
    # A variable that still points at the entry itself is not a redirect.
    assert_line "decide"$'\t'"${HOME}/.hinttool"$'\t'"keep"$'\t\t'"movetool supports XDG"
}

@test "a move is offered to the one place xdg-ninja's advice names for that kind of entry" {
    write_xdg_fixture
    cat > "${DF_DOCTOR_PROGRAMS}/advice.json" <<'JSON'
{
    "name": "advtool",
    "files": [
        { "path": "$HOME/.advfile", "movable": true,
          "help": "Supported by default.\n\nYou can move the file to _$XDG_CONFIG_HOME/advfile/config_.\n" },
        { "path": "$HOME/.advkind", "movable": true,
          "help": "You can move the directory to _$XDG_DATA_HOME/advkind_.\n" },
        { "path": "$HOME/.advit", "movable": true,
          "help": "If you have a custom file in it, you should move it to _$XDG_CONFIG_HOME/advit/conf_.\n" },
        { "path": "$HOME/.advgated", "movable": true,
          "help": "Older versions need:\n\n```bash\nexport ADVGATED_FILE=\"$XDG_STATE_HOME\"/advgated\n```\n\nYou can move the file to _$XDG_STATE_HOME/advgated_.\n" }
    ]
}
JSON
    touch "${HOME}/.advfile" "${HOME}/.advkind" "${HOME}/.advit" "${HOME}/.advgated"
    mkdir -p "${HOME}/.movetool"

    doctor --tsv
    assert_success
    assert_line "fix"$'\t'"${HOME}/.advfile"$'\t'"move"$'\t'"${HOME}/.config/advfile/config"$'\t'"advtool reads ~/.config/advfile/config"
    assert_line "fix"$'\t'"${HOME}/.movetool"$'\t'"move"$'\t'"${HOME}/.local/share/movetool"$'\t'"movetool reads ~/.local/share/movetool"
    # The advice moves a directory, and this is a file; "move it" does not say what moves.
    assert_line --regexp "^decide"$'\t'"${HOME}/\.advkind"$'\t'"keep"$'\t\t'
    assert_line --regexp "^decide"$'\t'"${HOME}/\.advit"$'\t'"keep"$'\t\t'
    # Advice that exports a variable waits until a new shell sets it.
    assert_line --regexp "^decide"$'\t'"${HOME}/\.advgated"$'\t'"keep"$'\t\t'

    # A new shell's XDG base is the one used, and the gated advice now applies.
    write_zshenv XDG_CONFIG_HOME=cfg ADVGATED_FILE=.local/state/advgated
    doctor --tsv
    assert_line --regexp "^fix"$'\t'"${HOME}/\.advfile"$'\t'"move"$'\t'"${HOME}/cfg/advfile/config"$'\t'
    assert_line --regexp "^fix"$'\t'"${HOME}/\.advgated"$'\t'"move"$'\t'"${HOME}/\.local/state/advgated"$'\t'

    # With both places present, neither is moved over the other.
    mkdir -p "${HOME}/.local/share/movetool"
    doctor --tsv
    assert_line "decide"$'\t'"${HOME}/.movetool"$'\t'"keep"$'\t\t'"movetool reads ~/.local/share/movetool too, which exists; merge them by hand, then archive this one"
}

@test "names with control characters cannot drive the terminal or break the columns" {
    touch "${HOME}/.evil"$'\033'"[31mred.bak" "${HOME}/.tab"$'\t'"name.bak"
    doctor
    assert_success
    [[ "${output}" != *$'\033'* ]]
    assert_output --partial '~/.evil?[31mred.bak'
    assert_output --partial '~/.tab?name.bak'
}

@test "the report says when xdg-ninja data is missing" {
    doctor
    assert_output --partial "xdg-ninja data or jq not found"
    write_xdg_fixture
    doctor
    refute_output --partial "xdg-ninja data or jq not found"
}

@test "--explain shows one path's finding with xdg-ninja's full advice" {
    write_xdg_fixture
    mkdir -p "${HOME}/.hinttool"
    doctor --explain "~/.hinttool"
    assert_success
    assert_line "~/.hinttool"
    assert_line "  group:      decide"
    assert_line "  why:        movetool supports XDG"
    assert_output --partial "xdg-ninja (movetool):"$'\n'"Export the following environment variables:"

    doctor --explain "${HOME}/.bashrc"
    assert_failure
    assert_output --partial "nothing to report about ~/.bashrc: it is managed, protected, or not checked"
}

@test "an incomplete check says so and offers no fixes" {
    printf 'keep\n' > "${HOME}/.old-file.bak"
    mkdir -p "${TEST_TMPDIR}/not-a-repo"
    run bash -c '{ printf "yes\n"; } | DOTFILES_PROMPT=read bash "$1" --source "$2" --fix' _ "${DOCTOR}" "${TEST_TMPDIR}/not-a-repo"
    assert_failure
    assert_output --partial "incomplete"
    assert test -f "${HOME}/.old-file.bak"
    refute test -e "${HOME}/.local/state/dotfiles/cleanup"
}

@test "options are checked and --help explains the groups" {
    doctor --bogus
    assert_failure
    assert_output --partial "Unknown option: --bogus"
    doctor --days soon
    assert_failure
    assert_output --partial "--days needs a number"
    doctor --help
    assert_success
    assert_output --partial "Usage: df-doctor [--report]"
    assert_output --partial "Decide  needs you"
}

# --- The list of changes -------------------------------------------------------

@test "Enter applies the Fix suggestions and skips the other items" {
    write_xdg_fixture
    printf 'copy\n' > "${HOME}/.notes.bak"
    mkdir -p "${HOME}/.movetool" "${HOME}/.fresh-tool"
    printf 'state\n' > "${HOME}/.movetool/state"

    doctor_answering '\n' --fix
    assert_success
    assert_output --partial "Choose a change for each item:"
    assert_output --regexp " [0-9]+\) archive ~/\.notes\.bak +[0-9.]+[KMG]  backup copy or leftover cache"
    assert_output --regexp " [0-9]+\) move    ~/\.movetool +[0-9.]+[KMG]  movetool reads ~/\.local/share/movetool"
    assert_output --regexp " [0-9]+\) skip    ~/\.fresh-tool +[0-9.]+[KMG]  no owner found"
    assert_output --partial "archived ~/.notes.bak"
    assert_output --partial "moved ~/.movetool to ~/.local/share/movetool (undo: mv ~/.local/share/movetool ~/.movetool)"
    assert_output --partial "Done: archived 1, moved 1."
    refute test -e "${HOME}/.notes.bak"
    assert_equal "$(cat "${HOME}/.local/share/movetool/state")" state
    assert_equal "$(cut -f2- "${HOME}/.local/state/dotfiles/moves.tsv")" "${HOME}/.movetool"$'\t'"${HOME}/.local/share/movetool"
    assert test -d "${HOME}/.fresh-tool"
    local archives=("${HOME}/.local/state/dotfiles/cleanup/"*)
    assert_equal "$(cat "${archives[0]}/.notes.bak")" copy
}

@test "one list archives, adds, and ignores together, and later runs skip what was ignored" {
    local list="${HOME}/.local/state/dotfiles/doctor-ignore"
    printf 'copy\n' > "${HOME}/.notes.bak"
    printf 'a\n' > "${HOME}/.old-a"
    printf 'b\n' > "${HOME}/.old-b"
    mkdir -p "${HOME}/.config/fresh-app" "${HOME}/.config/other-app"
    touch "${HOME}/.config/fresh-app/config" "${HOME}/.config/other-app/config"
    # The Fix item is kept; ph-extra is added, which link.sh refuses without
    # a terminal, changing nothing.
    doctor_picking "archive ~/.old-b" "ignore ~/.old-a" "archive ~/.config/other-app" \
        "ignore ~/.config/fresh-app" "add ~/.local/bin/ph-extra"
    assert_failure
    assert_output --partial "archived ~/.old-b"
    assert_output --partial "archived ~/.config/other-app"
    assert_output --partial "ignoring ~/.old-a (undo: df-doctor --unignore ~/.old-a)"
    assert_output --partial "Not managed: ~/.local/bin/ph-extra"
    assert_output --partial "Done, with problems: archived 2, added 1 to the repo, ignored 2; see the messages above."
    refute_output --partial "archived ~/.notes.bak"
    assert test -f "${HOME}/.notes.bak"
    assert test -f "${HOME}/.old-a"
    refute test -e "${HOME}/.old-b"
    refute test -e "${HOME}/.config/other-app"
    assert test -d "${HOME}/.config/fresh-app"
    assert test -f "${HOME}/.local/bin/ph-extra"
    assert_equal "$(cat "${list}")" "~/.old-a"$'\n'"~/.config/fresh-app"

    doctor --tsv
    assert_line "ignore"$'\t'"${HOME}/.old-a"$'\t'"keep"$'\t\t'"marked to ignore"
    assert_line "ignore"$'\t'"${HOME}/.config/fresh-app"$'\t'"keep"$'\t\t'"marked to ignore"
    assert_line "fix"$'\t'"${HOME}/.notes.bak"$'\t'"archive"$'\t\t'"backup copy or leftover cache"
}

@test "delete removes an item for good after a yes, and keeps it on anything else" {
    printf 'a\n' > "${HOME}/.old-a"
    mkdir -p "${HOME}/.old-dir" "${TEST_TMPDIR}/outside"
    printf 'outside\n' > "${TEST_TMPDIR}/outside/file"
    ln -s "${TEST_TMPDIR}/outside" "${HOME}/.old-dir/link"
    doctor_picking "delete ~/.old-a" "delete ~/.old-dir"
    assert_success
    assert_output --partial "Not deleting them."
    assert test -f "${HOME}/.old-a"

    local list
    list="$(printf 'none\n' | DOTFILES_PROMPT=read bash "${DOCTOR}" --source "${TEST_SOURCE_DIR}" --fix-only 2>&1 || true)"
    local a b
    a="$(sed -nE 's/^ +([0-9]+)\) [a-z]+ +~\/\.old-a .*/\1/p' <<< "${list}")"
    b="$(sed -nE 's/^ +([0-9]+)\) [a-z]+ +~\/\.old-dir .*/\1/p' <<< "${list}")"
    doctor_answering "none delete ${a} ${b}\ny\n" --fix
    assert_success
    assert_output --partial "Delete for good, with no copy kept:"$'\n'"  ~/.old-a"
    assert_output --partial "deleted ~/.old-a"
    assert_output --partial "deleted ~/.old-dir"
    refute test -e "${HOME}/.old-a"
    refute test -e "${HOME}/.old-dir"
    assert_equal "$(cat "${TEST_TMPDIR}/outside/file")" outside
    refute test -e "${HOME}/.local/state/dotfiles/cleanup"
}

@test "a line the list cannot read changes nothing" {
    printf 'copy\n' > "${HOME}/.notes.bak"
    local reply
    for reply in 'archive 99' 'bogus 1' '1' 'move 1' 'relink 1'; do
        doctor_answering "${reply}\n" --fix
        assert_success
        assert_output --partial "nothing changed"
        assert test -f "${HOME}/.notes.bak"
    done
    refute test -e "${HOME}/.local/state/dotfiles/cleanup"
}

@test "missing repo links get one row, set to repair them with df-link" {
    local dir stow_dir=""
    for dir in /opt/homebrew/bin /usr/local/bin /home/linuxbrew/.linuxbrew/bin /usr/bin; do
        [[ ! -x "${dir}/stow" ]] || { stow_dir="${dir}"; break; }
    done
    [[ -n "${stow_dir}" ]] || skip "GNU Stow not installed"
    export PATH="${PATH}:${stow_dir}"
    # Stow leaves the fixture's absolute links alone, so all four go missing.
    rm "${HOME}/.bashrc" "${HOME}/.config/git/config" "${HOME}/.config/git/config.local.example" "${HOME}/.local/bin/ph-padd"
    doctor_answering '\n' --fix
    assert_success
    assert_output --partial " 1) relink  4 missing or stale repo links; df-link repairs them"
    assert_output --partial "Repairing repo links"
    assert test -L "${HOME}/.bashrc"
    assert_equal "$(cat "${HOME}/.bashrc")" managed
}

@test "the list changes nothing on none, on closed stdin, or with nothing to fix" {
    printf 'copy\n' > "${HOME}/.notes.bak"
    doctor_answering 'none\n' --fix
    assert_success
    assert_output --partial "Nothing changed."
    assert test -f "${HOME}/.notes.bak"

    # keep, the old name for skip, still reads.
    doctor_answering 'keep 1\n' --fix
    assert_success
    assert_output --partial "Nothing changed."
    assert test -f "${HOME}/.notes.bak"

    run bash -c 'bash "$1" --source "$2" --fix </dev/null' _ "${DOCTOR}" "${TEST_SOURCE_DIR}"
    assert_success
    assert_output --partial "Nothing changed: df-doctor asks before changing anything, and stdin is closed."
    refute_output --partial "Choose a change"
    assert test -f "${HOME}/.notes.bak"
    refute test -e "${HOME}/.local/state/dotfiles/cleanup"
    refute test -e "${HOME}/.local/state/dotfiles/doctor-ignore"

    # Without a terminal, or with --report, it only reports.
    doctor_answering '\n'
    assert_success
    assert_output --partial "Run df-doctor in a terminal (or with --fix) to choose a change for each item."
    refute_output --partial "Choose a change"
    assert test -f "${HOME}/.notes.bak"

    rm "${HOME}/.notes.bak" "${HOME}/.local/bin/ph-extra"
    doctor_answering '\n' --fix
    assert_success
    assert_output --partial "Nothing to fix."
}

@test "the list never touches managed parents, credentials, private agents, overrides, or the repo" {
    mkdir -p "${HOME}/.ssh" "${HOME}/.owned" "${HOME}/.dotfiles" "${HOME}/.sources/dotfiles/stow"
    printf 'private\n' > "${HOME}/.ssh/secret"
    printf 'managed\n' > "${HOME}/.owned/file"
    mkdir -p "${TEST_SOURCE_DIR}/stow/common/.owned"
    printf 'managed\n' > "${TEST_SOURCE_DIR}/stow/common/.owned/file"
    doctor_picking archive
    assert_success
    assert test -f "${HOME}/.ssh/secret"
    assert test -f "${HOME}/.owned/file"
    assert test -d "${HOME}/.config/agents/tools"
    assert test -f "${HOME}/.config/git/config.local"
    assert test -d "${HOME}/.dotfiles"
    refute test -e "${HOME}/.local/bin/ph-extra"

    # The source repository's parents are protected too.
    write_test_persona "${HOME}/.sources/dotfiles"
    doctor_picking archive -- --source "${HOME}/.sources/dotfiles"
    assert test -d "${HOME}/.sources/dotfiles"
}

@test "the list archives directories and symlinks without following them, once" {
    mkdir -p "${HOME}/.old-tool" "${TEST_TMPDIR}/outside"
    printf 'keep this\n' > "${HOME}/.old-tool/config"
    printf 'outside\n' > "${TEST_TMPDIR}/outside/file"
    ln -s "${TEST_TMPDIR}/outside" "${HOME}/.old-link"
    doctor_picking archive
    assert_success
    local archives=("${HOME}/.local/state/dotfiles/cleanup/"*)
    assert_equal "${#archives[@]}" 1
    assert_equal "$(cat "${archives[0]}/.old-tool/config")" 'keep this'
    assert test -L "${archives[0]}/.old-link"
    assert_equal "$(cat "${TEST_TMPDIR}/outside/file")" outside

    # A second run does not offer the archive.
    doctor_picking archive
    assert_success
    assert_output --partial "Nothing to fix."
    archives=("${HOME}/.local/state/dotfiles/cleanup/"*)
    assert_equal "${#archives[@]}" 1
}

@test "the list respects a separate destination and leaves HOME alone" {
    local destination="${TEST_TMPDIR}/destination"
    mkdir -p "${destination}"
    printf 'target\n' > "${destination}/.old-file.bak"
    printf 'home\n' > "${HOME}/.old-file.bak"
    # Row 1 repairs the destination's missing links; skip it, archive the rest.
    doctor_answering 'skip 1\n' --destination "${destination}" --fix
    assert_success
    refute test -e "${destination}/.old-file.bak"
    assert_equal "$(cat "${HOME}/.old-file.bak")" home
    local archives=("${destination}/.local/state/dotfiles/cleanup/"*)
    assert_equal "$(cat "${archives[0]}/.old-file.bak")" target
}

@test "the list leaves files inside a symlinked folder and refuses a symlinked archive" {
    mv "${HOME}/.local/bin" "${TEST_TMPDIR}/outside-bin"
    ln -s "${TEST_TMPDIR}/outside-bin" "${HOME}/.local/bin"
    doctor_picking archive
    assert_success
    assert test -f "${TEST_TMPDIR}/outside-bin/ph-extra"
    refute test -e "${HOME}/.local/state/dotfiles/cleanup"
    rm "${HOME}/.local/bin"
    mv "${TEST_TMPDIR}/outside-bin" "${HOME}/.local/bin"

    mkdir -p "${TEST_TMPDIR}/outside-state"
    ln -s "${TEST_TMPDIR}/outside-state" "${HOME}/.local/state"
    doctor_picking archive
    assert_failure
    assert_output --partial "Archive parent is a symlink"
    assert test -f "${HOME}/.local/bin/ph-extra"
    refute test -e "${TEST_TMPDIR}/outside-state/dotfiles"
}

@test "the list refuses to move through a symlinked parent or while a program has the files open" {
    write_xdg_fixture
    mkdir -p "${HOME}/.movetool" "${TEST_TMPDIR}/elsewhere"
    printf 'state\n' > "${HOME}/.movetool/state"
    ln -s "${TEST_TMPDIR}/elsewhere" "${HOME}/.linked"
    write_zshenv XDG_DATA_HOME=.linked/share
    doctor_answering '\n' --fix
    assert_failure
    assert_output --partial "Not moved: ~/.linked is a symlink"
    assert test -d "${HOME}/.movetool"
    refute test -e "${TEST_TMPDIR}/elsewhere/share"

    [[ -x /usr/sbin/lsof || -x /usr/bin/lsof ]] || command -v lsof >/dev/null || skip "lsof not installed"
    rm "${HOME}/.config/zsh/.zshenv"
    sleep 60 < "${HOME}/.movetool/state" &
    local holder=$!
    doctor_answering '\n' --fix
    kill "${holder}"
    assert_failure
    assert_output --partial "Not moved: a running program has ~/.movetool open"
    assert test -f "${HOME}/.movetool/state"
    refute test -e "${HOME}/.local/share/movetool"
    refute test -e "${HOME}/.local/state/dotfiles/moves.tsv"
}

@test "on a terminal the list takes one key per change and Enter applies them" {
    [[ "${OSTYPE}" == darwin* ]] || skip "drives a terminal through BSD script"
    printf 'copy\n' > "${HOME}/.notes.bak"
    printf 'a\n' > "${HOME}/.old-a"
    printf 'b\n' > "${HOME}/.old-b"
    # Rows: .notes.bak (archive), .old-a, .old-b, ph-extra. Set the first to
    # archive, then back to skip; ignore the second; delete the third after a yes.
    run bash -c '{ printf "as"; sleep 1; printf "\033[Bi"; sleep 1; printf "\033[Bd"; sleep 1; printf "\r"; sleep 1; printf "y\r"; sleep 1; } |
        script -q /dev/null bash "$1" --source "$2"' _ "${DOCTOR}" "${TEST_SOURCE_DIR}"
    assert_success
    assert_output --partial "Choose a change for each item"
    assert_output --partial "deleted ~/.old-b"
    assert_output --partial "ignoring ~/.old-a"
    assert test -f "${HOME}/.notes.bak"
    assert test -f "${HOME}/.old-a"
    refute test -e "${HOME}/.old-b"
}

# --- The installer -------------------------------------------------------------

@test "the installer reports with closed stdin and changes nothing" {
    printf 'keep\n' > "${HOME}/.old-file.bak"
    run bash -c '
        source "$PROJECT_ROOT/scripts/common.sh"
        eval "$(sed -n '\''/^review_existing_files() {$/,/^}$/p'\'' "$PROJECT_ROOT/install.sh")"
        BASEDIR="$PROJECT_ROOT"
        review_existing_files </dev/null
    '
    assert_success
    assert_output --partial "~/.old-file.bak"
    refute_output --partial "Apply the"
    assert test -f "${HOME}/.old-file.bak"
    refute test -e "${HOME}/.local/state/dotfiles/cleanup"
}

@test "the installer surfaces an incomplete check instead of claiming a clean machine" {
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
    refute_output --partial "Nothing to fix"
}

@test "an interactive install boxes the report, then shows the list unboxed" {
    printf 'keep\n' > "${HOME}/.old-file.bak"
    run bash -c '
        source "$PROJECT_ROOT/scripts/common.sh"
        eval "$(sed -n '\''/^review_existing_files() {$/,/^}$/p;/^select_files_to_archive() {$/,/^}$/p'\'' "$PROJECT_ROOT/install.sh")"
        BASEDIR="$PROJECT_ROOT"
        offer_cleanup=1
        echo "--- report"
        review_existing_files </dev/null
        echo "--- fix"
        printf "\n" | DOTFILES_PROMPT=read select_files_to_archive
    '
    assert_success
    local report="${output%%--- fix*}"
    local fix="${output#*--- fix}"
    [[ "${report}" == *"df-doctor ~"* && "${report}" == *"~/.old-file.bak"* ]]
    [[ "${report}" != *"Run df-doctor"* && "${report}" != *"Choose a change"* ]]
    [[ "${fix}" != *"df-doctor ~"* && "${fix}" == *"archived ~/.old-file.bak"* ]]
    refute test -e "${HOME}/.old-file.bak"
}

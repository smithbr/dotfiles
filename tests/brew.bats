#!/usr/bin/env bats
# Tests for homebrew/brew.sh — the Brewfiles themselves, and the script run
# against a mocked brew: full installs, the optional picker, taps, and the
# persona's selection.

load test_helper

setup() {
    setup_tmpdir
    TEST_BIN="${TEST_TMPDIR}/bin"
    TEST_LOG="${TEST_TMPDIR}/brew.log"
    TEST_BUNDLE="${TEST_TMPDIR}/bundle.txt"
    mkdir -p "${TEST_BIN}" "${TEST_TMPDIR}/home"
    : > "${TEST_LOG}"
    export TEST_BIN TEST_LOG TEST_BUNDLE
}

teardown() {
    teardown_tmpdir
}

# A brew that logs every call. `bundle check` fails unless BREW_CHECK_OK=1;
# `bundle install` copies its Brewfile to TEST_BUNDLE; `list` prints
# BREW_FORMULAE and BREW_CASKS; `trust` succeeds.
write_brew_mock() {
    cat > "${TEST_BIN}/brew" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'brew %s\n' "$*" >> "${TEST_LOG}"
case "${1:-} ${2:-}" in
    "--prefix ") printf '%s\n' "${TEST_TMPDIR}/prefix" ;;
    "list --formula") printf '%s\n' ${BREW_FORMULAE:-} ;;
    "list --cask") printf '%s\n' ${BREW_CASKS:-} ;;
    "bundle check") [[ "${BREW_CHECK_OK:-0}" -eq 1 ]] || exit 1 ;;
    "bundle install")
        for arg in "$@"; do
            [[ "${arg}" == --file=* ]] && cp "${arg#--file=}" "${TEST_BUNDLE}"
        done
        ;;
esac
exit 0
MOCK
    chmod +x "${TEST_BIN}/brew"
}

# Runs brew.sh with the mocked brew on PATH, as the given OS, stdin closed.
run_brew_sh() {
    local os="$1"
    shift
    write_brew_mock
    run env PATH="${TEST_BIN}:/usr/bin:/bin" HOME="${TEST_TMPDIR}/home" OSTYPE="${os}" \
        TEST_TMPDIR="${TEST_TMPDIR}" TEST_LOG="${TEST_LOG}" TEST_BUNDLE="${TEST_BUNDLE}" \
        DOTFILES_PROMPT=read "$@" bash "${PROJECT_ROOT}/homebrew/brew.sh" < /dev/null
}

# ---------------------------------------------------------------------------
# The Brewfiles
# ---------------------------------------------------------------------------

@test "Brewfile.core holds only entries, comments, and an OS.mac? block" {
    run grep -vE '^\s*$|^\s*#|^\s*(brew|cask|tap|mas) "|^if OS\.mac\?$|^end$' "${PROJECT_ROOT}/homebrew/Brewfile.core"
    assert_failure
}

@test "Brewfile.core has no duplicate entries" {
    run bash -c "grep -oE '^\s*(brew|cask) \"[^\"]+\"' '${PROJECT_ROOT}/homebrew/Brewfile.core' | sed 's/^ *//' | sort | uniq -d"
    assert_output ""
}

@test "Brewfile.core keeps its casks to macOS" {
    run awk '/^if OS\.mac\?$/ { mac = 1 } /^end$/ { mac = 0 } /^\s*cask / && !mac { print }' "${PROJECT_ROOT}/homebrew/Brewfile.core"
    assert_output ""
}

@test "Brewfile.macos leaves Claude Code to the native installer" {
    run grep -Eq '^cask "claude-code' "${PROJECT_ROOT}/homebrew/Brewfile.macos"
    assert_failure
}

@test "Brewfile.macos tracks mactop as a formula" {
    run grep -qx 'brew "mactop"' "${PROJECT_ROOT}/homebrew/Brewfile.macos"
    assert_success
}

@test "Brewfile.core installs GNU Stow for linking the dotfiles" {
    run grep -qx 'brew "stow"' "${PROJECT_ROOT}/homebrew/Brewfile.core"
    assert_success
}

@test "Brewfile.core installs eza, fd, and zoxide, which the shell config uses unchecked" {
    local tool
    for tool in eza fd zoxide; do
        grep -qF "${tool}" "${PROJECT_ROOT}/stow/common/.config/shell/aliases" \
            "${PROJECT_ROOT}/stow/common/.config/zsh/.zshrc"
        grep -qx "brew \"${tool}\"" "${PROJECT_ROOT}/homebrew/Brewfile.core"
    done
}

# Every brew/cask package declared across all Brewfiles, one short name per line.
_all_brewfile_packages() {
    local brewfile raw_line line
    for brewfile in "${PROJECT_ROOT}"/homebrew/Brewfile.*; do
        [[ -f "${brewfile}" ]] || continue
        while IFS= read -r raw_line; do
            line="${raw_line#"${raw_line%%[![:space:]]*}"}"
            [[ "${line}" =~ ^(brew|cask)[[:space:]]+\"([^\"]+)\" ]] || continue
            printf '%s\n' "${BASH_REMATCH[2]##*/}"
        done < "${brewfile}"
    done
}

# config-file (relative to repo) | binary referenced | formula expected to supply it
_config_tool_map() {
    cat <<'MAP'
stow/common/.config/git/config|fzf|fzf
stow/common/.config/git/config|git-lfs|git-lfs
stow/common/.config/git/config|ghq|ghq
MAP
}

@test "tools referenced by git config are provided by a Brewfile" {
    local packages config_file binary formula missing=""
    packages="$(_all_brewfile_packages)"

    while IFS='|' read -r config_file binary formula; do
        [[ -z "${config_file}" ]] && continue
        if ! grep -qF "${binary}" "${PROJECT_ROOT}/${config_file}"; then
            missing+="'${binary}' is no longer referenced in ${config_file}"$'\n'
            continue
        fi
        if ! grep -qxF "${formula}" <<<"${packages}"; then
            missing+="${config_file} references '${binary}' but no Brewfile installs '${formula}'"$'\n'
        fi
    done < <(_config_tool_map)

    if [[ -n "${missing}" ]]; then
        printf '%s' "${missing}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# brew.sh
# ---------------------------------------------------------------------------

@test "brew_bin_dir knows macOS and Linux and rejects other systems" {
    run bash -c 'source "$1"; OSTYPE=linux-gnu brew_bin_dir' _ "${PROJECT_ROOT}/homebrew/brew.sh"
    assert_success
    assert_output "/home/linuxbrew/.linuxbrew/bin"
    run bash -c 'source "$1"; OSTYPE=darwin24 brew_bin_dir' _ "${PROJECT_ROOT}/homebrew/brew.sh"
    assert_success
    assert_output --regexp "^/(opt/homebrew|usr/local)/bin$"
    run bash -c 'source "$1"; OSTYPE=freebsd14 brew_bin_dir' _ "${PROJECT_ROOT}/homebrew/brew.sh"
    assert_failure
    assert_output --partial "Unsupported OS: freebsd14"
}

@test "brew.sh --help prints usage and rejects unknown options without touching brew" {
    run bash "${PROJECT_ROOT}/homebrew/brew.sh" --help
    assert_success
    assert_output --partial "Usage: brew.sh"
    run bash "${PROJECT_ROOT}/homebrew/brew.sh" --bogus-flag
    assert_failure
    assert_output --partial "Unknown option: --bogus-flag"
    [[ ! -s "${TEST_LOG}" ]]
}

@test "brew.sh bundles the core Brewfile without upgrades and cleans up, offering nothing on Linux" {
    run_brew_sh linux-gnu
    assert_success
    assert_output --partial "Installing core Homebrew packages..."
    refute_output --partial "Optional Homebrew packages"
    run grep -x "brew bundle install --no-upgrade --file=${PROJECT_ROOT}/homebrew/Brewfile.core" "${TEST_LOG}"
    assert_success
    run grep -x "brew cleanup --prune=all" "${TEST_LOG}"
    assert_success
    run grep -c "brew bundle install" "${TEST_LOG}"
    assert_output "1"
}

@test "brew.sh skips a Brewfile whose packages are all installed" {
    run_brew_sh linux-gnu BREW_CHECK_OK=1
    assert_success
    assert_output --partial "All core Homebrew packages already installed"
    refute_line --regexp "^brew bundle install"
    run grep "bundle install" "${TEST_LOG}"
    assert_failure
}

@test "brew.sh --verbose passes --verbose to bundle and cleanup and skips the spinner" {
    cat > "${TEST_BIN}/gum" <<'MOCK'
#!/usr/bin/env bash
echo "gum $*"
MOCK
    chmod +x "${TEST_BIN}/gum"
    write_brew_mock
    run env PATH="${TEST_BIN}:/usr/bin:/bin" HOME="${TEST_TMPDIR}/home" OSTYPE=linux-gnu \
        TEST_TMPDIR="${TEST_TMPDIR}" TEST_LOG="${TEST_LOG}" TEST_BUNDLE="${TEST_BUNDLE}" \
        bash "${PROJECT_ROOT}/homebrew/brew.sh" --verbose < /dev/null
    assert_success
    refute_output --partial "gum spin"
    run grep -x "brew bundle install --no-upgrade --file=${PROJECT_ROOT}/homebrew/Brewfile.core --verbose" "${TEST_LOG}"
    assert_success
    run grep -x "brew cleanup --prune=all --verbose" "${TEST_LOG}"
    assert_success
}

@test "brew.sh trusts each tap-qualified entry before bundling it" {
    mkdir -p "${TEST_TMPDIR}/repo/homebrew" "${TEST_TMPDIR}/repo/scripts"
    cp "${PROJECT_ROOT}/homebrew/brew.sh" "${TEST_TMPDIR}/repo/homebrew/"
    cp "${PROJECT_ROOT}/scripts/common.sh" "${TEST_TMPDIR}/repo/scripts/"
    printf 'brew "jq"\nbrew "some/tap/tool"\ncask "other/tap/app"\n' > "${TEST_TMPDIR}/repo/homebrew/Brewfile.core"
    write_brew_mock
    run env PATH="${TEST_BIN}:/usr/bin:/bin" HOME="${TEST_TMPDIR}/home" OSTYPE=linux-gnu \
        TEST_TMPDIR="${TEST_TMPDIR}" TEST_LOG="${TEST_LOG}" TEST_BUNDLE="${TEST_BUNDLE}" \
        bash "${TEST_TMPDIR}/repo/homebrew/brew.sh" < /dev/null
    assert_success
    run grep -x "brew trust --formula some/tap/tool" "${TEST_LOG}"
    assert_success
    run grep -x "brew trust --cask other/tap/app" "${TEST_LOG}"
    assert_success
    run grep "brew trust.*jq" "${TEST_LOG}"
    assert_failure
}

@test "brew.sh offers the pending macos entries and bundles the chosen ones" {
    run_brew_sh darwin24 BREW_FORMULAE="htop tree" BREW_CASKS="chatgpt claude" DOTFILES_BREWFILES="" BREW_CHECK_OK=1
    assert_success
    assert_output --partial "No macos Homebrew packages selected"
    run grep "bundle install" "${TEST_LOG}"
    assert_failure

    : > "${TEST_LOG}"
    write_brew_mock
    run env PATH="${TEST_BIN}:/usr/bin:/bin" HOME="${TEST_TMPDIR}/home" OSTYPE=darwin24 \
        TEST_TMPDIR="${TEST_TMPDIR}" TEST_LOG="${TEST_LOG}" TEST_BUNDLE="${TEST_BUNDLE}" \
        DOTFILES_PROMPT=read DOTFILES_BREWFILES="" BREW_FORMULAE="htop tree" BREW_CASKS="chatgpt claude" \
        bash "${PROJECT_ROOT}/homebrew/brew.sh" <<< "1 2"
    assert_success
    assert_output --partial "Installing 2 optional Homebrew package(s)..."
    # htop and tree are installed, so wget and the first cask are the first two offered.
    run cat "${TEST_BUNDLE}"
    assert_output 'brew "wget"
cask "brave-browser"'
    run grep -c "bundle install" "${TEST_LOG}"
    assert_output "1"
}

@test "brew.sh --pending lists the optional entries not installed, all of them without Homebrew" {
    write_brew_mock
    run env PATH="${TEST_BIN}:/usr/bin:/bin" HOME="${TEST_TMPDIR}/home" OSTYPE=darwin24 TEST_TMPDIR="${TEST_TMPDIR}" \
        TEST_LOG="${TEST_LOG}" BREW_FORMULAE="htop tree" BREW_CASKS="chatgpt claude" \
        bash "${PROJECT_ROOT}/homebrew/brew.sh" --pending < /dev/null
    assert_success
    assert_line --index 0 $'wget\tbrew "wget"'
    refute_line --partial 'brew "htop"'
    refute_line --partial 'cask "chatgpt"'
    run grep -c "bundle" "${TEST_LOG}"
    assert_output "0"

    # No brew on PATH and none in its usual place: nothing is installed, so every entry is pending.
    run env PATH="/usr/bin:/bin" HOME="${TEST_TMPDIR}/home" OSTYPE=linux-gnu DOTFILES_BREW_OPTIONAL=macos \
        bash "${PROJECT_ROOT}/homebrew/brew.sh" --pending < /dev/null
    assert_success
    assert_line --index 0 $'htop\tbrew "htop"'
}

@test "brew.sh installs DOTFILES_BREW_PICKS instead of asking" {
    write_brew_mock
    run env PATH="${TEST_BIN}:/usr/bin:/bin" HOME="${TEST_TMPDIR}/home" OSTYPE=darwin24 \
        TEST_TMPDIR="${TEST_TMPDIR}" TEST_LOG="${TEST_LOG}" TEST_BUNDLE="${TEST_BUNDLE}" \
        DOTFILES_PROMPT=read DOTFILES_BREWFILES="" BREW_FORMULAE="htop tree" BREW_CASKS="chatgpt claude" \
        DOTFILES_BREW_PICKS=$'brew "wget"\ncask "firefox"\ncask "htop"' \
        bash "${PROJECT_ROOT}/homebrew/brew.sh" <<< "1 2"
    assert_success
    assert_output --partial "Installing 2 optional Homebrew package(s)..."
    refute_output --partial "Optional Homebrew packages (macos)"
    run cat "${TEST_BUNDLE}"
    assert_output 'brew "wget"
cask "firefox"'

    # Set but empty: install.sh asked and got nothing, so nothing is offered.
    : > "${TEST_LOG}"
    run_brew_sh darwin24 DOTFILES_BREWFILES="" BREW_FORMULAE="htop tree" DOTFILES_BREW_PICKS=
    assert_success
    assert_output --partial "No macos Homebrew packages selected"
    run grep "bundle install" "${TEST_LOG}"
    assert_failure
}

@test "brew.sh --dry-run reports what it would install and installs nothing" {
    write_brew_mock
    run env PATH="${TEST_BIN}:/usr/bin:/bin" HOME="${TEST_TMPDIR}/home" OSTYPE=darwin24 TEST_TMPDIR="${TEST_TMPDIR}" \
        TEST_LOG="${TEST_LOG}" DOTFILES_BREWFILES="core" BREW_FORMULAE="htop tree" BREW_CASKS="chatgpt" \
        bash "${PROJECT_ROOT}/homebrew/brew.sh" --dry-run < /dev/null
    assert_success
    assert_output --partial "Would install from Brewfile.core:"
    assert_output --partial "Would offer from Brewfile.macos: wget"
    run grep "bundle install\|cleanup" "${TEST_LOG}"
    assert_failure

    run env PATH="/usr/bin:/bin" HOME="${TEST_TMPDIR}/home" OSTYPE=linux-gnu DOTFILES_BREWFILES="core" \
        bash "${PROJECT_ROOT}/homebrew/brew.sh" --dry-run < /dev/null
    assert_success
    assert_output --partial "Would install Homebrew"
    assert_output --partial "Would install from Brewfiles: core"
}

@test "brew.sh writes Homebrew's global npmrc once, then leaves it as is" {
    local npmrc="${TEST_TMPDIR}/prefix/etc/npmrc"
    run_brew_sh linux-gnu
    assert_success
    assert_output --partial "Wrote ${npmrc}"
    run cat "${npmrc}"
    assert_output $'# Managed by dotfiles homebrew/brew.sh\ncache=~/.cache/npm'

    run_brew_sh linux-gnu
    assert_success
    refute_output --partial "npmrc"
}

@test "brew.sh rewrites its own stale npmrc but keeps one it did not write" {
    local npmrc="${TEST_TMPDIR}/prefix/etc/npmrc"
    mkdir -p "${npmrc%/*}"
    printf '# Managed by dotfiles homebrew/brew.sh\ncache=/old\n' > "${npmrc}"
    run_brew_sh linux-gnu
    assert_success
    run cat "${npmrc}"
    assert_output $'# Managed by dotfiles homebrew/brew.sh\ncache=~/.cache/npm'

    printf 'registry=https://example.test/\n' > "${npmrc}"
    run_brew_sh linux-gnu
    assert_success
    assert_output --partial "Leaving ${npmrc} alone"
    run cat "${npmrc}"
    assert_output "registry=https://example.test/"
}

@test "brew.sh --dry-run reports the npmrc without writing it" {
    write_brew_mock
    run env PATH="${TEST_BIN}:/usr/bin:/bin" HOME="${TEST_TMPDIR}/home" OSTYPE=linux-gnu TEST_TMPDIR="${TEST_TMPDIR}" \
        TEST_LOG="${TEST_LOG}" bash "${PROJECT_ROOT}/homebrew/brew.sh" --dry-run < /dev/null
    assert_success
    assert_output --partial "Would write ${TEST_TMPDIR}/prefix/etc/npmrc"
    [[ ! -e "${TEST_TMPDIR}/prefix/etc/npmrc" ]]
}

@test "brew.sh says so when every optional entry is installed" {
    local all
    all="$(grep -oE '^(brew|cask) "[^"]+"' "${PROJECT_ROOT}/homebrew/Brewfile.macos" | sed -E 's/^[a-z]+ "([^"]+)"/\1/' | tr '\n' ' ')"
    run_brew_sh darwin24 BREW_FORMULAE="${all}" BREW_CASKS="${all}" DOTFILES_BREWFILES="" BREW_CHECK_OK=1
    assert_success
    assert_output --partial "All macos Homebrew packages already installed"
}

@test "brew.sh installs every Brewfile the persona lists and fails on one the repo lacks" {
    run_brew_sh linux-gnu DOTFILES_BREWFILES="core work" DOTFILES_BREW_OPTIONAL=""
    assert_success
    run grep -c "brew bundle install --no-upgrade --file=" "${TEST_LOG}"
    assert_output "2"
    run grep -x "brew bundle install --no-upgrade --file=${PROJECT_ROOT}/homebrew/Brewfile.work" "${TEST_LOG}"
    assert_success

    run_brew_sh linux-gnu DOTFILES_BREWFILES="core missing"
    assert_failure
    assert_output --partial "No homebrew/Brewfile.missing"
}

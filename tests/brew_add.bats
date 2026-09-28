#!/usr/bin/env bats
# Tests for scripts/brew-add.sh and the df-add wrapper — run against a fake repo
# with scratch Brewfiles and a stub brew that logs its calls.

load test_helper

setup() {
    setup_tmpdir
    FAKE_REPO="${TEST_TMPDIR}/repo"
    mkdir -p "${FAKE_REPO}/scripts" "${FAKE_REPO}/homebrew" "${TEST_TMPDIR}/bin"
    cp "${PROJECT_ROOT}/scripts/brew-add.sh" "${PROJECT_ROOT}/scripts/common.sh" "${FAKE_REPO}/scripts/"
    cat > "${FAKE_REPO}/scripts/link.sh" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == installs ]] || { printf '%s|' link.sh "$@"; exit 0; }
printf 'brew=%s\nbrew_optional=%s\nlinux_optional=\n' "${FAKE_BREW-core home}" "${FAKE_BREW_OPTIONAL-macos}"
EOF
    cat > "${FAKE_REPO}/homebrew/Brewfile.core" <<'EOF'
# Install all dependencies with: brew bundle

# Core Tools
brew "fzf"
brew "jq"
cask "1password-cli"

# Fonts
cask "font-hack-nerd-font"
EOF
    cat > "${FAKE_REPO}/homebrew/Brewfile.home" <<'EOF'
# Install all dependencies with: brew bundle

brew "vhs"
brew "superradcompany/tap/microsandbox"
EOF
    printf '# Work only\n' > "${FAKE_REPO}/homebrew/Brewfile.work"
    printf '# Optional\n\n# Browsers\ncask "firefox"\n' > "${FAKE_REPO}/homebrew/Brewfile.macos"

    cat > "${TEST_TMPDIR}/bin/brew" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TEST_TMPDIR}/brew.log"
has() { [[ " $1 " == *" $2 "* ]]; }
case "$1 $2" in
    "info --formula") has "${BREW_FORMULAE:-}" "$3" ;;
    "info --cask") has "${BREW_CASKS:-}" "$3" ;;
    "list --formula"|"list --cask") has "${BREW_INSTALLED:-}" "$3" ;;
    "install --formula"|"install --cask") [[ "$3" != "${BREW_FAIL:-}" ]] ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "${TEST_TMPDIR}/bin/brew" "${FAKE_REPO}/scripts/link.sh"
    export PATH="${TEST_TMPDIR}/bin:${PATH}"
    export BREW_FORMULAE="llmfit mtr aria2 zoxide"
    export BREW_CASKS="zen docker"
}

teardown() {
    teardown_tmpdir
}

brew_add() {
    run bash "${FAKE_REPO}/scripts/brew-add.sh" "$@" </dev/null
}

@test "brew-add installs a formula and sorts it among the section's formulae" {
    brew_add --file core --section "core tools" llmfit
    assert_success
    assert_output --partial 'Added brew "llmfit" to homebrew/Brewfile.core (Core Tools)'
    run cat "${FAKE_REPO}/homebrew/Brewfile.core"
    assert_output "$(printf '%s\n' '# Install all dependencies with: brew bundle' '' '# Core Tools' \
        'brew "fzf"' 'brew "jq"' 'brew "llmfit"' 'cask "1password-cli"' '' '# Fonts' 'cask "font-hack-nerd-font"')"
    run grep -x 'install --formula llmfit' "${TEST_TMPDIR}/brew.log"
    assert_success
}

@test "brew-add detects casks, puts formulae before casks and casks last" {
    brew_add --file core --section "Core Tools" aria2 zen
    assert_success
    run sed -n '4,8p' "${FAKE_REPO}/homebrew/Brewfile.core"
    assert_output "$(printf '%s\n' 'brew "aria2"' 'brew "fzf"' 'brew "jq"' 'cask "1password-cli"' 'cask "zen"')"
    run grep -x 'install --cask zen' "${TEST_TMPDIR}/brew.log"
    assert_success
}

@test "brew-add prefers a formula over a cask of the same name unless --cask" {
    export BREW_FORMULAE="docker"
    brew_add --file macos --no-install docker
    assert_success
    assert_output --partial 'brew "docker"'

    brew_add --file work --no-install --cask zen
    assert_success
    run cat "${FAKE_REPO}/homebrew/Brewfile.work"
    assert_output "$(printf '%s\n' '# Work only' '' 'cask "zen"')"
}

@test "brew-add uses the only section and starts one in a file without entries" {
    brew_add --file home --no-install mtr zoxide
    assert_success
    run tail -n 2 "${FAKE_REPO}/homebrew/Brewfile.home"
    assert_output "$(printf '%s\n' 'brew "superradcompany/tap/microsandbox"' 'brew "zoxide"')"
    run grep -c mtr "${FAKE_REPO}/homebrew/Brewfile.home"
    assert_output 1

    export BREW_FORMULAE="aria2 llmfit"
    brew_add --file Brewfile.work --no-install llmfit aria2
    assert_success
    run cat "${FAKE_REPO}/homebrew/Brewfile.work"
    assert_output "$(printf '%s\n' '# Work only' '' 'brew "aria2"' 'brew "llmfit"')"
}

@test "brew-add skips names listed in any Brewfile, matching tap-qualified names" {
    brew_add --file core jq microsandbox
    assert_success
    assert_output --partial "jq is already in Brewfile.core"
    assert_output --partial "microsandbox is already in Brewfile.home"
    assert [ ! -e "${TEST_TMPDIR}/brew.log" ]
}

@test "brew-add does not record a package whose install fails" {
    export BREW_FAIL=llmfit
    before="$(cat "${FAKE_REPO}/homebrew/Brewfile.core")"
    brew_add --file core --section fonts llmfit
    assert_failure
    assert_output --partial "Installing llmfit failed"
    run cat "${FAKE_REPO}/homebrew/Brewfile.core"
    assert_output "${before}"
}

@test "brew-add skips the install of a package already installed" {
    export BREW_INSTALLED=llmfit
    brew_add --file home llmfit
    assert_success
    run grep -c '^install' "${TEST_TMPDIR}/brew.log"
    assert_output 0
    run grep -x 'brew "llmfit"' "${FAKE_REPO}/homebrew/Brewfile.home"
    assert_success
}

@test "brew-add dry run changes nothing and installs nothing" {
    before="$(cat "${FAKE_REPO}/homebrew/Brewfile.macos")"
    brew_add -n --file macos zen
    assert_success
    assert_output --partial 'Would add cask "zen" to homebrew/Brewfile.macos (Browsers)'
    run cat "${FAKE_REPO}/homebrew/Brewfile.macos"
    assert_output "${before}"
    run grep -c '^install' "${TEST_TMPDIR}/brew.log"
    assert_output 0
}

@test "brew-add on closed stdin needs --file and --section instead of asking" {
    brew_add llmfit
    assert_failure
    assert_output --partial "Name the Brewfile with --file (one of: core home macos)"

    export FAKE_BREW="" FAKE_BREW_OPTIONAL=""
    brew_add llmfit
    assert_failure
    assert_output --partial "(one of: core home macos work)"

    brew_add --file core llmfit
    assert_failure
    assert_output --partial 'Name the section with --section (one of: "Core Tools" "Fonts" )'
    run grep -q '^install' "${TEST_TMPDIR}/brew.log"
    assert_failure
}

@test "brew-add rejects unknown packages, files, sections and malformed names" {
    brew_add --file core nosuchthing
    assert_failure
    assert_output --partial "No formula or cask named nosuchthing"

    brew_add --file nope llmfit
    assert_failure
    assert_output --partial "No such Brewfile: homebrew/Brewfile.nope"

    brew_add --file core --section nope llmfit
    assert_failure
    assert_output --partial "No section 'nope'"

    brew_add --file core 'bad"name'
    assert_failure
    assert_output --partial "Not a package name"

    brew_add
    assert_failure
    assert_output --partial "Name at least one package"
}

# Links df-add into a bin directory the way stow would.
link_df_add() {
    mkdir -p "${FAKE_REPO}/stow/tools/.local/bin" "${TEST_TMPDIR}/home/.local/bin"
    cp "${PROJECT_ROOT}/stow/tools/.local/bin/df-add" "${FAKE_REPO}/stow/tools/.local/bin/"
    ln -s "../../../repo/stow/tools/.local/bin/df-add" "${TEST_TMPDIR}/home/.local/bin/df-add"
}

@test "df-add brew runs the repo's brew-add.sh through the stow link" {
    link_df_add
    run "${TEST_TMPDIR}/home/.local/bin/df-add" brew --file home --no-install llmfit </dev/null
    assert_success
    run grep -x 'brew "llmfit"' "${FAKE_REPO}/homebrew/Brewfile.home"
    assert_success
}

@test "df-add stow runs link.sh add with every argument" {
    link_df_add
    run "${TEST_TMPDIR}/home/.local/bin/df-add" stow --layer tools "a file"
    assert_success
    assert_output "link.sh|add|--layer|tools|a file|"
}

@test "df-add rejects a missing or unknown kind" {
    link_df_add
    run "${TEST_TMPDIR}/home/.local/bin/df-add"
    assert_failure 2
    assert_output --partial "Usage: df-add brew"
    run "${TEST_TMPDIR}/home/.local/bin/df-add" npm left-pad
    assert_failure 2
}

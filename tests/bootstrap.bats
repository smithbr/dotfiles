#!/usr/bin/env bats
# Tests for bootstrap scripts — guard clauses, idempotency checks, and
# structural validation. No system packages are installed; we only verify
# the decision logic.

load test_helper

setup() {
    setup_tmpdir
}

teardown() {
    teardown_tmpdir
}

# ---------------------------------------------------------------------------
# linux/setup.sh — apt-packages.txt validation
# ---------------------------------------------------------------------------

@test "apt-packages.txt exists and is non-empty" {
    local pkg_file="${PROJECT_ROOT}/scripts/bootstrap/linux/apt-packages.txt"
    [[ -f "${pkg_file}" ]]
    [[ -s "${pkg_file}" ]]
}

@test "apt-packages.txt contains no blank entries after filtering" {
    run bash -c '
        count=0
        while IFS= read -r pkg || [[ -n "${pkg}" ]]; do
            [[ -z "${pkg}" ]] && continue
            [[ "${pkg}" == \#* ]] && continue
            count=$((count + 1))
        done < "'"${PROJECT_ROOT}/scripts/bootstrap/linux/apt-packages.txt"'"
        echo "${count}"
    '
    assert_success
    # Should have at least one actual package
    [[ "${output}" -gt 0 ]]
}

@test "apt-packages.txt has no duplicate packages" {
    run bash -c '
        filtered_packages="$(mktemp)"
        while IFS= read -r pkg || [[ -n "${pkg}" ]]; do
            [[ -z "${pkg}" ]] && continue
            [[ "${pkg}" == \#* ]] && continue
            printf "%s\n" "${pkg}" >> "${filtered_packages}"
        done < "'"${PROJECT_ROOT}/scripts/bootstrap/linux/apt-packages.txt"'"
        duplicate="$(sort "${filtered_packages}" | uniq -d | head -n 1)"
        rm -f "${filtered_packages}"
        if [[ -n "${duplicate}" ]]; then
            echo "DUPLICATE: ${duplicate}"
            exit 1
        fi
        echo "NO_DUPLICATES"
    '
    assert_success
    assert_output "NO_DUPLICATES"
}

# ---------------------------------------------------------------------------
# linux/setup.sh — apt-get guard clause
# ---------------------------------------------------------------------------

@test "linux setup.sh skips gracefully when apt-get is absent" {
    # Use a PATH that has basic tools but NOT apt-get
    mkdir -p "${TEST_TMPDIR}/bin"
    ln -sf "$(command -v bash)" "${TEST_TMPDIR}/bin/bash"
    ln -sf "$(command -v echo)" "${TEST_TMPDIR}/bin/echo"

    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"'"

        if ! command -v apt-get >/dev/null 2>&1; then
            echo "SKIPPED"
            exit 0
        fi
        echo "CONTINUED"
    '
    assert_success
    assert_output "SKIPPED"
}

@test "linux setup.sh installs only missing base packages" {
    run bash -c '
        set -euo pipefail

        export TEST_ROOT="'"${TEST_TMPDIR}"'/linux-bootstrap-missing-apt"
        export TEST_BOOTSTRAP_DIR="${TEST_ROOT}/bootstrap"
        export TEST_BIN="${TEST_ROOT}/bin"
        export TEST_LOG="${TEST_ROOT}/apt.log"
        export PATH="${TEST_BIN}:/usr/bin:/bin"
        export BOOTSTRAP_DIR="${TEST_BOOTSTRAP_DIR}"

        mkdir -p "${TEST_BOOTSTRAP_DIR}" "${TEST_BIN}"
        : > "${TEST_LOG}"

        printf "curl\ngit\nzsh\n" > "${TEST_BOOTSTRAP_DIR}/apt-packages.txt"

        cat > "${TEST_BOOTSTRAP_DIR}/docker.sh" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
echo "OPTIONAL docker" >> "${TEST_LOG}"
MOCK

        cat > "${TEST_BOOTSTRAP_DIR}/tailscale.sh" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
echo "OPTIONAL tailscale" >> "${TEST_LOG}"
MOCK

        cat > "${TEST_BIN}/apt-get" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
echo "apt-get $*" >> "${TEST_LOG}"
MOCK

        cat > "${TEST_BIN}/sudo" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
"$@"
MOCK

        cat > "${TEST_BIN}/dpkg-query" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
shift 2
for pkg in "$@"; do
    case "${pkg}" in
        curl|zsh)
            printf "%s\tinstall ok installed\n" "${pkg}"
            ;;
    esac
done
MOCK

        chmod +x "${TEST_BOOTSTRAP_DIR}/docker.sh" \
            "${TEST_BOOTSTRAP_DIR}/tailscale.sh" \
            "${TEST_BIN}/apt-get" \
            "${TEST_BIN}/sudo" \
            "${TEST_BIN}/dpkg-query"

        cd "'"${PROJECT_ROOT}"'"
        printf "n\nn\n" | ./scripts/bootstrap/linux/setup.sh

        grep -qx "apt-get update" "${TEST_LOG}" || { echo "missing apt update"; exit 1; }
        grep -qx "apt-get install -y git" "${TEST_LOG}" || { echo "missing missing-only install"; exit 1; }
        if grep -q "curl" "${TEST_LOG}" || grep -q "zsh" "${TEST_LOG}"; then
            echo "installed packages should not be reinstalled"
            exit 1
        fi
    '
    assert_success
    assert_output --partial "Installing base Linux packages: git"
}

# ---------------------------------------------------------------------------
# linux/docker.sh — idempotency guard
# ---------------------------------------------------------------------------

# Runs a vendor install script (docker.sh, tailscale.sh) with a scratch HOME
# and Homebrew prefix, no apt-get, and only the mocks in TEST_TMPDIR/bin on
# PATH; $1 prepares them.
_run_vendor_script() {
    local script="$1"
    run bash -c '
        export HOME="'"${TEST_TMPDIR}"'/home" HOMEBREW_PREFIX="'"${TEST_TMPDIR}"'/brew"
        export PATH="'"${TEST_TMPDIR}"'/bin:/usr/bin:/bin"
        mkdir -p "${HOME}" "'"${TEST_TMPDIR}"'/bin"
        '"$2"'
        "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/'"${script}"'"
    '
}

@test "docker.sh skips when docker is on PATH, or came through Homebrew" {
    _run_vendor_script docker.sh 'printf "#!/bin/sh\n" > "'"${TEST_TMPDIR}"'/bin/docker"; chmod +x "'"${TEST_TMPDIR}"'/bin/docker"'
    assert_success
    assert_output --partial "Docker already installed, skipping"

    _run_vendor_script docker.sh 'mkdir -p "${HOMEBREW_PREFIX}/bin"; printf "#!/bin/sh\n" > "${HOMEBREW_PREFIX}/bin/docker"; chmod +x "${HOMEBREW_PREFIX}/bin/docker"'
    assert_success
    assert_output --partial "Docker already installed, skipping"

    # Neither: on a box without apt-get the install stops there.
    _run_vendor_script docker.sh 'rm -f "'"${TEST_TMPDIR}"'/bin/docker" "${HOMEBREW_PREFIX}/bin/docker"'
    assert_success
    assert_output --partial "apt-get not found; skipping Docker install"
}

@test "docker.sh skips when apt-get is absent and docker is missing" {
    # Use a PATH with no apt-get and no docker
    mkdir -p "${TEST_TMPDIR}/bin"
    ln -sf "$(command -v bash)" "${TEST_TMPDIR}/bin/bash"

    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"'"

        if command -v docker >/dev/null 2>&1; then
            echo "SKIPPED_DOCKER_EXISTS"
            exit 0
        fi
        if ! command -v apt-get >/dev/null 2>&1; then
            echo "SKIPPED_NO_APT"
            exit 0
        fi
        echo "WOULD_INSTALL"
    '
    assert_success
    assert_output "SKIPPED_NO_APT"
}

# ---------------------------------------------------------------------------
# linux/tailscale.sh — idempotency guard
# ---------------------------------------------------------------------------

@test "tailscale.sh skips when tailscale is already installed" {
    mkdir -p "${TEST_TMPDIR}/bin"
    printf '#!/usr/bin/env bash\necho "Tailscale mock"' > "${TEST_TMPDIR}/bin/tailscale"
    chmod +x "${TEST_TMPDIR}/bin/tailscale"

    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"':${PATH}"
        if command -v tailscale >/dev/null 2>&1; then
            echo "SKIPPED"
            exit 0
        fi
        echo "WOULD_INSTALL"
    '
    assert_success
    assert_output "SKIPPED"
}

# ---------------------------------------------------------------------------
# linux/harden.sh — dry runs against a scratch root with mocked system tools
# ---------------------------------------------------------------------------

# Runs harden.sh with HARDEN_ROOT pointing at a scratch tree. TS_UP=1 makes
# the mocked tailscale report a connection; ROOT_KEYS=0 leaves root without
# SSH keys; SUDO_MOCK=1 replaces sudo with one that only prints its arguments.
# Arguments go to harden.sh.
_run_harden() {
    run bash -c '
        set -euo pipefail
        export HARDEN_ROOT="'"${TEST_TMPDIR}"'/root"
        export TEST_BIN="'"${TEST_TMPDIR}"'/bin"
        export PATH="${TEST_BIN}:/usr/bin:/bin"
        mkdir -p "${TEST_BIN}" "${HARDEN_ROOT}/etc/ssh" "${HARDEN_ROOT}/root/.ssh"
        printf "Include /etc/ssh/sshd_config.d/*.conf\n" > "${HARDEN_ROOT}/etc/ssh/sshd_config"
        if [[ "${ROOT_KEYS:-1}" -eq 1 ]]; then
            printf "ssh-ed25519 AAAA test\n" > "${HARDEN_ROOT}/root/.ssh/authorized_keys"
        fi
        cat > "${TEST_BIN}/getent" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
[[ "$2" == root ]] && printf "root:x:0:0::/root:/bin/bash\n" && exit 0
exit 2
MOCK
        cat > "${TEST_BIN}/tailscale" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
[[ "${TS_UP:-0}" -eq 1 ]] || exit 1
printf "100.64.0.1 box admin@ linux -\n"
MOCK
        cat > "${TEST_BIN}/curl" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
case "$*" in
    *ips-v4) printf "173.245.48.0/20\n104.16.0.0/13" ;;
    *ips-v6) printf "2400:cb00::/32" ;;
esac
MOCK
        printf "#!/usr/bin/env bash\nexit 0\n" > "${TEST_BIN}/apt-get"
        printf "#!/usr/bin/env bash\nexit 0\n" > "${TEST_BIN}/systemctl"
        printf "#!/usr/bin/env bash\nexit 1\n" > "${TEST_BIN}/sshd"
        if [[ "${SUDO_MOCK:-0}" -eq 1 ]]; then
            printf "#!/usr/bin/env bash\nprintf \"sudo %%s\\\\n\" \"\$*\"\n" > "${TEST_BIN}/sudo"
        fi
        chmod +x "${TEST_BIN}"/*
        cd "'"${PROJECT_ROOT}"'"
        ./scripts/bootstrap/linux/harden.sh '"$*"'
    '
}

@test "harden.sh defaults to the user running it and rejects root and bad ports" {
    _run_harden --dry-run
    assert_success
    assert_output --partial "AllowUsers $(id -un)"

    _run_harden --dry-run --user root
    assert_failure
    assert_output --partial "must not be root"

    _run_harden --dry-run --user admin --allow http
    assert_failure
    assert_output --partial "Not a port: http"
}

@test "harden.sh re-runs itself through sudo when not root, for the user who ran it" {
    [[ "${EUID}" -ne 0 ]] || skip "running as root"
    SUDO_MOCK=1 _run_harden --allow 443 --cloudflare
    assert_success
    assert_output --regexp "^sudo bash .*/scripts/bootstrap/linux/harden.sh --user $(id -un) --allow 443 --cloudflare$"
}

@test "harden.sh closes public SSH once Tailscale is connected" {
    TS_UP=1 _run_harden --dry-run --user admin --allow 443
    assert_success
    assert_output --partial "would copy root's SSH keys to ${TEST_TMPDIR}/root/home/admin/.ssh/authorized_keys"
    assert_output --partial "admin ALL=(ALL) NOPASSWD:ALL"
    assert_output --partial "PermitRootLogin no"
    assert_output --partial "PasswordAuthentication no"
    assert_output --partial "AllowUsers admin"
    assert_output --partial "would run: ufw allow in on tailscale0"
    assert_output --partial "would run: ufw allow 443/tcp"
    assert_output --partial "would run: ufw --force delete allow 22/tcp"
    assert_output --partial "Public SSH closed"
    refute_output --partial "ufw limit 22/tcp"
    [[ ! -e "${TEST_TMPDIR}/root/etc/ssh/sshd_config.d/00-harden.conf" ]]
    [[ ! -e "${TEST_TMPDIR}/root/home/admin" ]]
}

@test "harden.sh keeps public SSH while Tailscale is not connected, and does not wait for a login without a terminal" {
    TS_UP=0 _run_harden --dry-run --user admin
    assert_success
    assert_output --partial "No terminal to log Tailscale in from"
    refute_output --partial "would run: tailscale up"
    assert_output --partial "public SSH stays open"
    assert_output --partial "would run: ufw limit 22/tcp"
    refute_output --partial "Public SSH closed"
}

@test "harden.sh opens --allow ports only to Cloudflare with --cloudflare" {
    TS_UP=1 _run_harden --dry-run --user admin --allow 443 --cloudflare
    assert_success
    assert_output --partial "would run: ufw allow proto tcp from 173.245.48.0/20 to any port 443"
    assert_output --partial "would run: ufw allow proto tcp from 104.16.0.0/13 to any port 443"
    assert_output --partial "would run: ufw allow proto tcp from 2400:cb00::/32 to any port 443"
    refute_output --partial "would run: ufw allow 443/tcp"
}

@test "harden.sh stops before touching SSH when there is no key to copy" {
    ROOT_KEYS=0 TS_UP=1 _run_harden --dry-run --user admin
    assert_failure
    assert_output --partial "No SSH keys for admin"
    refute_output --partial "useradd"
    refute_output --partial "PermitRootLogin"
    refute_output --partial "would run: ufw"
}

# ---------------------------------------------------------------------------
# claude-code.sh — native installer, shared by macOS and Linux
# ---------------------------------------------------------------------------

_run_claude_code_script() {
    run bash -c '
        set -euo pipefail

        export HOME="'"${TEST_TMPDIR}"'/home"
        export HOMEBREW_PREFIX="'"${TEST_TMPDIR}"'/brew"
        export TEST_BIN="'"${TEST_TMPDIR}"'/bin"
        export TEST_LOG="'"${TEST_TMPDIR}"'/claude.log"
        export PATH="${TEST_BIN}:/usr/bin:/bin"
        mkdir -p "${HOME}" "${TEST_BIN}"
        : > "${TEST_LOG}"

        cat > "${TEST_BIN}/curl" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
printf "curl %s\n" "$*" >> "${TEST_LOG}"
printf "echo installer-ran >> \"\${TEST_LOG}\"\n"
MOCK
        chmod +x "${TEST_BIN}/curl"

        '"$1"'

        cd "'"${PROJECT_ROOT}"'"
        ./scripts/bootstrap/claude-code.sh
        cat "${TEST_LOG}"
    '
}

@test "claude-code.sh runs the native installer when claude is missing" {
    _run_claude_code_script ":"
    assert_success
    assert_output --partial "Installing Claude Code..."
    assert_output --partial "curl -fsSL https://claude.ai/install.sh"
    assert_output --partial "installer-ran"
}

@test "claude-code.sh skips when the native build is already installed" {
    _run_claude_code_script 'mkdir -p "${HOME}/.local/bin"; printf "#!/usr/bin/env bash\n" > "${HOME}/.local/bin/claude"; chmod +x "${HOME}/.local/bin/claude"'
    assert_success
    assert_output --partial "already installed at ${TEST_TMPDIR}/home/.local/bin/claude"
    refute_output --partial "curl "
}

@test "claude-code.sh skips when Claude Code came through Homebrew" {
    _run_claude_code_script 'mkdir -p "${HOMEBREW_PREFIX}/bin"; printf "#!/usr/bin/env bash\n" > "${HOMEBREW_PREFIX}/bin/claude"; chmod +x "${HOMEBREW_PREFIX}/bin/claude"'
    assert_success
    assert_output --partial "already installed outside ${TEST_TMPDIR}/home/.local/bin/claude"
    refute_output --partial "curl "
}

@test "claude-code.sh warns when the Homebrew cask is still installed" {
    _run_claude_code_script 'mkdir -p "${HOME}/.local/bin"; printf "#!/usr/bin/env bash\n" > "${HOME}/.local/bin/claude"; chmod +x "${HOME}/.local/bin/claude"; printf "#!/usr/bin/env bash\n[[ \"\$*\" == \"list --cask claude-code@latest\" ]]\n" > "${TEST_BIN}/brew"; chmod +x "${TEST_BIN}/brew"'
    assert_success
    assert_output --partial "Homebrew's claude-code@latest cask is still installed"
    assert_output --partial "brew uninstall --cask claude-code@latest"
}

# ---------------------------------------------------------------------------
# macos/setup.sh — mocked execution flow
# ---------------------------------------------------------------------------

@test "macOS setup.sh installs CLT and Rosetta when needed" {
    run bash -c '
        set -euo pipefail

        export TEST_ROOT="'"${TEST_TMPDIR}"'/macos-bootstrap"
        export TEST_BIN="${TEST_ROOT}/bin"
        export TEST_LOG="${TEST_ROOT}/bootstrap.log"
        export PATH="${TEST_BIN}:/usr/bin:/bin"
        export OSTYPE="darwin24"
        export ITERM_APP="${TEST_ROOT}/no-iTerm.app"

        mkdir -p "${TEST_BIN}"
        : > "${TEST_LOG}"

        cat > "${TEST_BIN}/xcode-select" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    -p)
        exit 1
        ;;
    --install)
        printf "xcode-select %s\n" "$*" >> "${TEST_LOG}"
        ;;
esac
MOCK

        cat > "${TEST_BIN}/xcodebuild" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "-license" && "${2:-}" == "check" ]]; then
    exit 0
fi

printf "xcodebuild %s\n" "$*" >> "${TEST_LOG}"
MOCK

        cat > "${TEST_BIN}/uname" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
printf "arm64\n"
MOCK

        cat > "${TEST_BIN}/pgrep" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
exit 1
MOCK

        cat > "${TEST_BIN}/softwareupdate" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
printf "softwareupdate %s\n" "$*" >> "${TEST_LOG}"
MOCK

        chmod +x \
            "${TEST_BIN}/xcode-select" \
            "${TEST_BIN}/xcodebuild" \
            "${TEST_BIN}/uname" \
            "${TEST_BIN}/pgrep" \
            "${TEST_BIN}/softwareupdate"

        cd "'"${PROJECT_ROOT}"'"
        printf "\n" | ./scripts/bootstrap/macos/setup.sh

        grep -qx "xcode-select --install" "${TEST_LOG}" || { echo "missing xcode-select install"; exit 1; }
        grep -qx "softwareupdate --install-rosetta --agree-to-license" "${TEST_LOG}" || {
            echo "missing rosetta install"
            exit 1
        }
    '
    assert_success
    assert_output --partial "Installing Xcode Command Line Tools"
    assert_output --partial "Installing Rosetta 2..."
    assert_output --partial "iTerm2 not installed; skipping its settings"
}

# Runs iterm2.sh against a fake app and a `defaults` mock whose store is
# ${TEST_ROOT}/store/<key>; writes are logged to ${TEST_ROOT}/defaults.log.
# Dictionary adds and exports go through the real plist ${TEST_ROOT}/domain.plist.
_run_iterm2_script() {
    command -v plutil >/dev/null || skip "plutil is macOS-only"
    local root="${TEST_TMPDIR}/iterm2"
    mkdir -p "${root}/bin" "${root}/store" "${root}/iTerm.app"
    : > "${root}/defaults.log"
    cat > "${root}/bin/defaults" <<'MOCK'
#!/usr/bin/env bash
plist="${TEST_ROOT}/domain.plist"
case "$1" in
    read) cat "${TEST_ROOT}/store/$3" 2>/dev/null || exit 1 ;;
    export) [[ -f "${plist}" ]] && cat "${plist}" || exit 1 ;;
    write)
        if [[ "$4" == "-dict-add" ]]; then
            printf '%s\n' "${*:1:5}" >> "${TEST_ROOT}/defaults.log"
            [[ -f "${plist}" ]] || plutil -create xml1 "${plist}"
            plutil -extract "$3" raw "${plist}" >/dev/null 2>&1 || plutil -insert "$3" -dictionary "${plist}"
            plutil -replace "$3.$5" -xml "$6" "${plist}"
            exit 0
        fi
        printf '%s\n' "$*" >> "${TEST_ROOT}/defaults.log"
        [[ "$4" == "-bool" ]] && echo 1 > "${TEST_ROOT}/store/$3" || echo "$5" > "${TEST_ROOT}/store/$3"
        ;;
esac
MOCK
    chmod +x "${root}/bin/defaults"
    TEST_ROOT="${root}" ITERM_APP="${root}/iTerm.app" PATH="${root}/bin:/usr/bin:/bin" \
        run "${PROJECT_ROOT}/scripts/bootstrap/macos/iterm2.sh"
}

@test "iterm2.sh enables the Python API and makes the repo profile the default" {
    _run_iterm2_script
    assert_success
    local guid
    guid="$(jq -r '.Profiles[0].Guid' "${PROJECT_ROOT}/stow/desktop.darwin/Library/Application Support/iTerm2/DynamicProfiles/dotfiles.json")"
    run cat "${TEST_TMPDIR}/iterm2/defaults.log"
    assert_line "write com.googlecode.iterm2 EnableAPIServer -bool true"
    assert_line "write com.googlecode.iterm2 shortLivedSessionDuration -float 0"
    assert_line "write com.googlecode.iterm2 Default Bookmark Guid -string ${guid}"
}

@test "iterm2.sh writes nothing when the settings are already in place" {
    _run_iterm2_script
    _run_iterm2_script
    assert_success
    assert_output --partial "EnableAPIServer already set"
    run wc -l < "${TEST_TMPDIR}/iterm2/defaults.log"
    assert_output --regexp '^ *0$'
}

@test "iterm2.sh adds the Catppuccin color presets, fixes a stale one, and keeps the user's" {
    command -v plutil >/dev/null || skip "plutil is macOS-only"
    local root="${TEST_TMPDIR}/iterm2" presets="${PROJECT_ROOT}/stow/desktop.darwin/.config/iterm2"
    mkdir -p "${root}"
    plutil -create xml1 "${root}/domain.plist"
    plutil -insert "Custom Color Presets" -dictionary "${root}/domain.plist"
    plutil -insert "Custom Color Presets.Mine" -xml '<dict><key>a</key><integer>1</integer></dict>' "${root}/domain.plist"
    plutil -insert "Custom Color Presets.Catppuccin Mocha" -xml '<dict/>' "${root}/domain.plist"

    _run_iterm2_script
    assert_success
    assert_output --partial "Set iTerm2 color preset Catppuccin Mocha"

    run plutil -extract "Custom Color Presets.Mine.a" raw "${root}/domain.plist"
    assert_output "1"
    local name
    for name in Frappe Latte Macchiato Mocha; do
        [[ "$(plutil -extract "Custom Color Presets.Catppuccin ${name}" xml1 -o - "${root}/domain.plist")" == \
            "$(plutil -convert xml1 -o - "${presets}/Catppuccin ${name}.itermcolors")" ]] ||
            fail "Catppuccin ${name} differs from the repo file"
    done
}

# ---------------------------------------------------------------------------
# All shell scripts have correct shebang and strict mode
# ---------------------------------------------------------------------------

@test "all shell scripts use bash shebang" {
    run bash -c '
        failed=0
        for f in \
            "'"${PROJECT_ROOT}"'/install.sh" \
            "'"${PROJECT_ROOT}"'/scripts/common.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/setup.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/docker.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/tailscale.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/harden.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/macos/setup.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/claude-code.sh" \
            "'"${PROJECT_ROOT}"'/homebrew/brew.sh"; do
            first_line="$(head -1 "${f}")"
            if [[ "${first_line}" != "#!/usr/bin/env bash" ]]; then
                echo "BAD SHEBANG: ${f} -> ${first_line}"
                failed=1
            fi
        done
        [[ "${failed}" -eq 0 ]] && echo "ALL_OK" || exit 1
    '
    assert_success
    assert_output "ALL_OK"
}

@test "all shell scripts enable strict mode (set -euo pipefail)" {
    run bash -c '
        failed=0
        for f in \
            "'"${PROJECT_ROOT}"'/install.sh" \
            "'"${PROJECT_ROOT}"'/scripts/common.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/setup.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/docker.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/tailscale.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/harden.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/macos/setup.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/claude-code.sh" \
            "'"${PROJECT_ROOT}"'/homebrew/brew.sh"; do
            if ! grep -q "set -euo pipefail" "${f}"; then
                echo "MISSING strict mode: ${f}"
                failed=1
            fi
        done
        [[ "${failed}" -eq 0 ]] && echo "ALL_OK" || exit 1
    '
    assert_success
    assert_output "ALL_OK"
}

# ---------------------------------------------------------------------------
# All shell scripts source common.sh (except common.sh itself)
# ---------------------------------------------------------------------------

@test "all scripts except common.sh source common.sh" {
    run bash -c '
        failed=0
        for f in \
            "'"${PROJECT_ROOT}"'/install.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/setup.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/docker.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/tailscale.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/harden.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/macos/setup.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/claude-code.sh" \
            "'"${PROJECT_ROOT}"'/homebrew/brew.sh"; do
            if ! grep -q "source.*common\.sh" "${f}"; then
                echo "MISSING source common.sh: ${f}"
                failed=1
            fi
        done
        [[ "${failed}" -eq 0 ]] && echo "ALL_OK" || exit 1
    '
    assert_success
    assert_output "ALL_OK"
}

# ---------------------------------------------------------------------------
# BASEDIR resolution consistency
# ---------------------------------------------------------------------------

@test "scripts resolve BASEDIR relative to their location" {
    run bash -c '
        failed=0
        for f in \
            "'"${PROJECT_ROOT}"'/install.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/setup.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/docker.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/tailscale.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/harden.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/macos/setup.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/claude-code.sh" \
            "'"${PROJECT_ROOT}"'/homebrew/brew.sh"; do
            if ! grep -q "BASEDIR=" "${f}"; then
                echo "MISSING BASEDIR: ${f}"
                failed=1
            fi
        done
        [[ "${failed}" -eq 0 ]] && echo "ALL_OK" || exit 1
    '
    assert_success
    assert_output "ALL_OK"
}

# ---------------------------------------------------------------------------

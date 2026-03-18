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

@test "linux setup.sh defines optional install selection flow" {
    local setup_script="${PROJECT_ROOT}/scripts/bootstrap/linux/setup.sh"

    grep -qF 'prompt_optional_linux_bootstraps "optional Linux install"' "${setup_script}" || {
        echo "MISSING optional prompt"
        return 1
    }

    grep -qF 'gum_choose_multiselect \' "${setup_script}" || {
        echo "MISSING gum chooser helper"
        return 1
    }

    grep -qF '"Select optional packages to install"' "${setup_script}" || {
        echo "MISSING gum chooser header"
        return 1
    }

    grep -qF 'read -r -p "Install ${prompt_label} ${pending_names[${idx}]}? [Y/n] " reply' "${setup_script}" || {
        echo "MISSING fallback prompt"
        return 1
    }

    grep -qF 'run_bootstrap_step "1" "Checking base Linux packages"' "${setup_script}" || {
        echo "MISSING base package step"
        return 1
    }

    grep -qF 'run_optional_bootstrap_script' "${setup_script}" || {
        echo "MISSING optional bootstrap runner"
        return 1
    }
}

@test "linux setup.sh runs only selected optional installs" {
    run bash -c '
        set -euo pipefail

        export TEST_ROOT="'"${TEST_TMPDIR}"'/linux-bootstrap"
        export TEST_BOOTSTRAP_DIR="${TEST_ROOT}/bootstrap"
        export TEST_BIN="${TEST_ROOT}/bin"
        export TEST_LOG="${TEST_ROOT}/optional.log"
        export PATH="${TEST_BIN}:/usr/bin:/bin"
        export BOOTSTRAP_DIR="${TEST_BOOTSTRAP_DIR}"

        mkdir -p "${TEST_BOOTSTRAP_DIR}" "${TEST_BIN}"
        : > "${TEST_LOG}"

        printf "curl\n" > "${TEST_BOOTSTRAP_DIR}/apt-packages.txt"

        cat > "${TEST_BOOTSTRAP_DIR}/docker.sh" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
echo "OPTIONAL docker" >> "${TEST_LOG}"
MOCK

        cat > "${TEST_BOOTSTRAP_DIR}/tailscale.sh" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
echo "OPTIONAL tailscale" >> "${TEST_LOG}"
MOCK

        cat > "${TEST_BOOTSTRAP_DIR}/opencode.sh" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
echo "OPTIONAL opencode" >> "${TEST_LOG}"
MOCK

        cat > "${TEST_BIN}/apt-get" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
echo "apt-get $*" >> "${TEST_LOG}"
MOCK

        cat > "${TEST_BIN}/dpkg-query" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
printf "curl\tinstall ok installed\n"
MOCK

        chmod +x "${TEST_BOOTSTRAP_DIR}/docker.sh" \
            "${TEST_BOOTSTRAP_DIR}/tailscale.sh" \
            "${TEST_BOOTSTRAP_DIR}/opencode.sh" \
            "${TEST_BIN}/apt-get" \
            "${TEST_BIN}/dpkg-query"

        cd "'"${PROJECT_ROOT}"'"
        printf "y\nn\ny\n" | ./scripts/bootstrap/linux/setup.sh

        grep -qx "OPTIONAL docker" "${TEST_LOG}" || { echo "missing docker"; exit 1; }
        grep -qx "OPTIONAL opencode" "${TEST_LOG}" || { echo "missing opencode"; exit 1; }
        if grep -qx "OPTIONAL tailscale" "${TEST_LOG}"; then
            echo "tailscale should not run"
            exit 1
        fi
        if grep -q "^apt-get " "${TEST_LOG}"; then
            echo "base apt packages should have been treated as already installed"
            exit 1
        fi
    '
    assert_success
    assert_output --partial "Running optional Linux installs: Docker OpenCode"
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

        cat > "${TEST_BOOTSTRAP_DIR}/opencode.sh" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
echo "OPTIONAL opencode" >> "${TEST_LOG}"
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
            "${TEST_BOOTSTRAP_DIR}/opencode.sh" \
            "${TEST_BIN}/apt-get" \
            "${TEST_BIN}/sudo" \
            "${TEST_BIN}/dpkg-query"

        cd "'"${PROJECT_ROOT}"'"
        printf "n\nn\nn\n" | ./scripts/bootstrap/linux/setup.sh

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

@test "linux setup.sh excludes installed optional packages from selection" {
    run bash -c '
        set -euo pipefail

        export TEST_ROOT="'"${TEST_TMPDIR}"'/linux-bootstrap-installed-optional"
        export TEST_BOOTSTRAP_DIR="${TEST_ROOT}/bootstrap"
        export TEST_BIN="${TEST_ROOT}/bin"
        export TEST_LOG="${TEST_ROOT}/optional.log"
        export PATH="${TEST_BIN}:/usr/bin:/bin"
        export BOOTSTRAP_DIR="${TEST_BOOTSTRAP_DIR}"

        mkdir -p "${TEST_BOOTSTRAP_DIR}" "${TEST_BIN}"
        : > "${TEST_LOG}"

        printf "curl\n" > "${TEST_BOOTSTRAP_DIR}/apt-packages.txt"

        cat > "${TEST_BOOTSTRAP_DIR}/docker.sh" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
echo "OPTIONAL docker" >> "${TEST_LOG}"
MOCK

        cat > "${TEST_BOOTSTRAP_DIR}/tailscale.sh" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
echo "OPTIONAL tailscale" >> "${TEST_LOG}"
MOCK

        cat > "${TEST_BOOTSTRAP_DIR}/opencode.sh" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
echo "OPTIONAL opencode" >> "${TEST_LOG}"
MOCK

        cat > "${TEST_BIN}/docker" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
exit 0
MOCK

        cat > "${TEST_BIN}/apt-get" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
echo "apt-get $*" >> "${TEST_LOG}"
MOCK

        cat > "${TEST_BIN}/dpkg-query" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
printf "curl\tinstall ok installed\n"
MOCK

        chmod +x "${TEST_BOOTSTRAP_DIR}/docker.sh" \
            "${TEST_BOOTSTRAP_DIR}/tailscale.sh" \
            "${TEST_BOOTSTRAP_DIR}/opencode.sh" \
            "${TEST_BIN}/docker" \
            "${TEST_BIN}/apt-get" \
            "${TEST_BIN}/dpkg-query"

        cd "'"${PROJECT_ROOT}"'"
        printf "y\ny\n" | ./scripts/bootstrap/linux/setup.sh

        grep -qx "OPTIONAL tailscale" "${TEST_LOG}" || { echo "missing tailscale"; exit 1; }
        grep -qx "OPTIONAL opencode" "${TEST_LOG}" || { echo "missing opencode"; exit 1; }
        if grep -q "^OPTIONAL docker$" "${TEST_LOG}"; then
            echo "docker should have been excluded from the picker"
            exit 1
        fi
    '
    assert_success
    assert_output --partial "Running optional Linux installs: Tailscale OpenCode"
}

@test "linux setup.sh skips optional installs when none are selected" {
    run bash -c '
        set -euo pipefail

        export TEST_ROOT="'"${TEST_TMPDIR}"'/linux-bootstrap-none"
        export TEST_BOOTSTRAP_DIR="${TEST_ROOT}/bootstrap"
        export TEST_BIN="${TEST_ROOT}/bin"
        export TEST_LOG="${TEST_ROOT}/optional.log"
        export PATH="${TEST_BIN}:/usr/bin:/bin"
        export BOOTSTRAP_DIR="${TEST_BOOTSTRAP_DIR}"

        mkdir -p "${TEST_BOOTSTRAP_DIR}" "${TEST_BIN}"
        : > "${TEST_LOG}"

        printf "curl\n" > "${TEST_BOOTSTRAP_DIR}/apt-packages.txt"

        cat > "${TEST_BOOTSTRAP_DIR}/docker.sh" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
echo "OPTIONAL docker" >> "${TEST_LOG}"
MOCK

        cat > "${TEST_BOOTSTRAP_DIR}/tailscale.sh" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
echo "OPTIONAL tailscale" >> "${TEST_LOG}"
MOCK

        cat > "${TEST_BOOTSTRAP_DIR}/opencode.sh" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
echo "OPTIONAL opencode" >> "${TEST_LOG}"
MOCK

        cat > "${TEST_BIN}/apt-get" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
echo "apt-get $*" >> "${TEST_LOG}"
MOCK

        cat > "${TEST_BIN}/dpkg-query" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
printf "curl\tinstall ok installed\n"
MOCK

        chmod +x "${TEST_BOOTSTRAP_DIR}/docker.sh" \
            "${TEST_BOOTSTRAP_DIR}/tailscale.sh" \
            "${TEST_BOOTSTRAP_DIR}/opencode.sh" \
            "${TEST_BIN}/apt-get" \
            "${TEST_BIN}/dpkg-query"

        cd "'"${PROJECT_ROOT}"'"
        printf "n\nn\nn\n" | ./scripts/bootstrap/linux/setup.sh

        if grep -q "^OPTIONAL " "${TEST_LOG}"; then
            echo "optional installers should not run"
            exit 1
        fi
    '
    assert_success
    assert_output --partial "No optional Linux installs selected"
}

# ---------------------------------------------------------------------------
# linux/docker.sh — idempotency guard
# ---------------------------------------------------------------------------

@test "docker.sh skips when docker is already installed" {
    # Create a mock docker binary
    mkdir -p "${TEST_TMPDIR}/bin"
    printf '#!/usr/bin/env bash\necho "Docker mock"' > "${TEST_TMPDIR}/bin/docker"
    chmod +x "${TEST_TMPDIR}/bin/docker"

    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"':${PATH}"
        if command -v docker >/dev/null 2>&1; then
            echo "SKIPPED"
            exit 0
        fi
        echo "WOULD_INSTALL"
    '
    assert_success
    assert_output "SKIPPED"
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
# linux/opencode.sh — idempotency guard
# ---------------------------------------------------------------------------

@test "opencode.sh skips when opencode is already installed" {
    mkdir -p "${TEST_TMPDIR}/bin"
    printf '#!/usr/bin/env bash\necho "OpenCode mock"' > "${TEST_TMPDIR}/bin/opencode"
    chmod +x "${TEST_TMPDIR}/bin/opencode"

    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"':${PATH}"
        if command -v opencode >/dev/null 2>&1; then
            echo "SKIPPED"
            exit 0
        fi
        echo "WOULD_INSTALL"
    '
    assert_success
    assert_output "SKIPPED"
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
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/opencode.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/macos/setup.sh" \
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
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/opencode.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/macos/setup.sh" \
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
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/opencode.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/macos/setup.sh" \
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
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/linux/opencode.sh" \
            "'"${PROJECT_ROOT}"'/scripts/bootstrap/macos/setup.sh" \
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

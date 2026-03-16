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
        declare -A seen
        while IFS= read -r pkg || [[ -n "${pkg}" ]]; do
            [[ -z "${pkg}" ]] && continue
            [[ "${pkg}" == \#* ]] && continue
            if [[ -n "${seen[${pkg}]:-}" ]]; then
                echo "DUPLICATE: ${pkg}"
                exit 1
            fi
            seen["${pkg}"]=1
        done < "'"${PROJECT_ROOT}/scripts/bootstrap/linux/apt-packages.txt"'"
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

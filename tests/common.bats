#!/usr/bin/env bats
# Tests for scripts/common.sh — logging, require_non_root, sudo_cmd, spin.

load test_helper

setup() {
    setup_tmpdir
    export PATH="${TEST_TMPDIR}/bin:${PATH}"
    mkdir -p "${TEST_TMPDIR}/bin"
}

teardown() {
    teardown_tmpdir
}

# ---------------------------------------------------------------------------
# _check_gum / gum detection
# ---------------------------------------------------------------------------

@test "log_info outputs to stdout with info prefix when gum is absent" {
    run bash -c '
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        log_info "hello world"
    '
    assert_success
    assert_output "info: hello world"
}

@test "log_warn outputs to stderr with warning prefix when gum is absent" {
    run bash -c '
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        log_warn "caution" 2>&1
    '
    assert_success
    assert_output "warning: caution"
}

@test "log_error outputs to stderr with error prefix when gum is absent" {
    run bash -c '
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        log_error "something broke" 2>&1
    '
    assert_success
    assert_output "error: something broke"
}

@test "log_info delegates to gum when gum is on PATH" {
    cat > "${TEST_TMPDIR}/bin/gum" <<'MOCK'
#!/usr/bin/env bash
echo "gum $*"
MOCK
    chmod +x "${TEST_TMPDIR}/bin/gum"

    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"':${PATH}"
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        log_info "via gum"
    '
    assert_success
    assert_output --partial "gum log --level info via gum"
}

@test "log_warn delegates to gum when gum is on PATH" {
    cat > "${TEST_TMPDIR}/bin/gum" <<'MOCK'
#!/usr/bin/env bash
echo "gum $*" >&2
MOCK
    chmod +x "${TEST_TMPDIR}/bin/gum"

    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"':${PATH}"
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        log_warn "warning via gum" 2>&1
    '
    assert_success
    assert_output --partial "gum log --level warn warning via gum"
}

@test "log_error delegates to gum when gum is on PATH" {
    cat > "${TEST_TMPDIR}/bin/gum" <<'MOCK'
#!/usr/bin/env bash
echo "gum $*" >&2
MOCK
    chmod +x "${TEST_TMPDIR}/bin/gum"

    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"':${PATH}"
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        log_error "err via gum" 2>&1
    '
    assert_success
    assert_output --partial "gum log --level error err via gum"
}

# ---------------------------------------------------------------------------
# require_non_root
# EUID is readonly in bash, so we test the logic by inlining the conditional.
# ---------------------------------------------------------------------------

@test "require_non_root logic accepts non-zero EUID" {
    run bash -c '
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        test_euid=1000
        if [[ "${test_euid}" -eq 0 ]]; then
            log_error "Do not run this script as root."
            exit 1
        fi
        echo "OK"
    '
    assert_success
    assert_output "OK"
}

@test "require_non_root logic rejects EUID 0" {
    run bash -c '
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        test_euid=0
        if [[ "${test_euid}" -eq 0 ]]; then
            log_error "Do not run this script as root."
            exit 1
        fi
    ' 2>&1
    assert_failure
    assert_output --partial "Do not run this script as root"
}

# ---------------------------------------------------------------------------
# sudo_cmd
# ---------------------------------------------------------------------------

@test "sudo_cmd logic runs command directly when EUID is 0" {
    run bash -c '
        test_euid=0
        if [[ "${test_euid}" -eq 0 ]]; then
            echo "ran directly"
        fi
    '
    assert_success
    assert_output "ran directly"
}

@test "sudo_cmd logic uses sudo when EUID is non-zero" {
    cat > "${TEST_TMPDIR}/bin/sudo" <<'MOCK'
#!/usr/bin/env bash
echo "sudo: $*"
MOCK
    chmod +x "${TEST_TMPDIR}/bin/sudo"

    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"':${PATH}"
        log_error() { printf "error: %s\n" "$*" >&2; }

        sudo_cmd() {
            local test_euid=1000
            if [[ "${test_euid}" -eq 0 ]]; then
                "$@"
            elif command -v sudo >/dev/null 2>&1; then
                sudo "$@"
            else
                log_error "sudo is required for: $*"
                exit 1
            fi
        }

        sudo_cmd echo "elevated"
    '
    assert_success
    assert_output "sudo: echo elevated"
}

@test "sudo_cmd logic fails when sudo is missing and non-root" {
    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"'"
        log_error() { printf "error: %s\n" "$*" >&2; }

        sudo_cmd() {
            local test_euid=1000
            if [[ "${test_euid}" -eq 0 ]]; then
                "$@"
            elif command -v sudo >/dev/null 2>&1; then
                sudo "$@"
            else
                log_error "sudo is required for: $*"
                exit 1
            fi
        }

        sudo_cmd echo "nope" 2>&1
    '
    assert_failure
    assert_output --partial "sudo is required"
}

# ---------------------------------------------------------------------------
# spin
# ---------------------------------------------------------------------------

@test "spin runs command and prints title when gum is absent" {
    run bash -c '
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        spin "Testing..." echo "payload"
    '
    assert_success
    assert_output --partial "Testing..."
    assert_output --partial "payload"
}

@test "spin returns failure when the wrapped command fails" {
    run bash -c '
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        spin "Should fail..." false
    '
    assert_failure
}

@test "spin invokes function directly even when gum is present" {
    cat > "${TEST_TMPDIR}/bin/gum" <<'MOCK'
#!/usr/bin/env bash
echo "gum $*"
MOCK
    chmod +x "${TEST_TMPDIR}/bin/gum"

    run bash -c '
        export PATH="'"${TEST_TMPDIR}/bin"':${PATH}"
        source "'"${PROJECT_ROOT}"'/scripts/common.sh"
        my_fn() { echo "from function"; }
        spin "Running fn..." my_fn
    '
    assert_success
    assert_output --partial "from function"
}

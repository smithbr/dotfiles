#!/usr/bin/env bats
# The versioned git hooks in .githooks and the sandbox install pre-push runs,
# against stub commands: no agents checkout and no container runtime needed.

load test_helper

setup() {
    setup_tmpdir
    mkdir -p "${TEST_TMPDIR}/home/.config/agents/scripts" "${TEST_TMPDIR}/bin"
    CHECK_DRIFT="${TEST_TMPDIR}/home/.config/agents/scripts/check-drift"
}

teardown() {
    teardown_tmpdir
}

write_check_drift() {
    printf '#!/usr/bin/env bash\n%s\n' "$1" > "${CHECK_DRIFT}"
    chmod +x "${CHECK_DRIFT}"
}

@test "pre-commit passes when check-drift passes" {
    write_check_drift 'printf "0 failed check(s)\n"'

    run env HOME="${TEST_TMPDIR}/home" bash "${PROJECT_ROOT}/.githooks/pre-commit"
    assert_success
    assert_output --partial "0 failed check(s)"
}

@test "pre-commit reports a check-drift failure as drift" {
    write_check_drift 'printf "FAIL  retired term\n"; exit 1'

    run env HOME="${TEST_TMPDIR}/home" bash "${PROJECT_ROOT}/.githooks/pre-commit"
    assert_failure
    assert_output --partial "check-drift failed; see ~/.config/agents/MAINTENANCE.md"
    refute_output --partial "crashed"
}

@test "pre-commit reports a check-drift crash as a crash, not drift" {
    write_check_drift 'kill -BUS $$'

    run env HOME="${TEST_TMPDIR}/home" bash "${PROJECT_ROOT}/.githooks/pre-commit"
    assert_failure
    assert_output --partial "check-drift crashed (signal 10), not a drift failure"
    assert_output --partial "run ${CHECK_DRIFT} by hand"
    refute_output --partial "see ~/.config/agents/MAINTENANCE.md"
}

@test "pre-commit skips when the agents checkout is missing" {
    run env HOME="${TEST_TMPDIR}/home" bash "${PROJECT_ROOT}/.githooks/pre-commit"
    assert_success
    assert_output --partial "skipping check-drift"
}

@test "sandbox-install keeps the full install log when the install fails" {
    # A daemon that answers, and an install that prints 100 lines and fails.
    cat > "${TEST_TMPDIR}/bin/docker" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
    exec) [[ "$*" == *guest-install.sh* ]] && { seq 1 100; exit 1; } ;;
esac
exit 0
MOCK
    chmod +x "${TEST_TMPDIR}/bin/docker"

    run env HOME="${TEST_TMPDIR}/home" XDG_STATE_HOME="${TEST_TMPDIR}/state" DOCKER_HOST="unix:///stub.sock" \
        PATH="${TEST_TMPDIR}/bin:${PATH}" bash "${PROJECT_ROOT}/tests/sandbox-install.sh"
    assert_failure
    assert_output --partial "sandbox: install failed"
    assert_output --partial "sandbox: full log: ${TEST_TMPDIR}/state/dotfiles/sandbox-install.log"
    # Only the tail is printed; the saved log has every line.
    refute_output --regexp $'(^|\n)1\n'
    run wc -l < "${TEST_TMPDIR}/state/dotfiles/sandbox-install.log"
    assert_output --regexp '^ *100$'
}

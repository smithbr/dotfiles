#!/usr/bin/env bats
# The versioned git hooks in .githooks and the sandbox install pre-push runs,
# against stub commands: no agents checkout and no container runtime needed.

load test_helper

setup() {
    setup_tmpdir
    mkdir -p "${TEST_TMPDIR}/home/.config/agents/scripts" "${TEST_TMPDIR}/bin"
    CHECK_DRIFT="${TEST_TMPDIR}/home/.config/agents/scripts/check-drift"
    # git reads the scratch home's config, not the real one's signing or hooks.
    export HOME="${TEST_TMPDIR}/home"
    # A scratch repo with the hook and the runner it lints through, so what
    # the real repo has staged never matters.
    REPO="${TEST_TMPDIR}/repo"
    mkdir -p "${REPO}/.githooks" "${REPO}/tests" "${REPO}/stow/tools/.local/bin"
    cp "${PROJECT_ROOT}/.githooks/pre-commit" "${REPO}/.githooks/"
    cp "${PROJECT_ROOT}/tests/run_tests.sh" "${PROJECT_ROOT}/tests/lint-docs.sh" "${REPO}/tests/"
    git -C "${REPO}" init -q
}

teardown() {
    teardown_tmpdir
}

write_check_drift() {
    printf '#!/usr/bin/env bash\n%s\n' "$1" > "${CHECK_DRIFT}"
    chmod +x "${CHECK_DRIFT}"
}

run_pre_commit() {
    run bash -c 'cd "$1" && bash .githooks/pre-commit' _ "${REPO}"
}

# A script ShellCheck flags (SC2086, an unquoted variable) and one it passes.
write_bad_script() {
    printf '#!/usr/bin/env bash\nrm $1\n' > "${REPO}/$1"
}

write_good_script() {
    printf '#!/usr/bin/env bash\nrm -- "$1"\n' > "${REPO}/$1"
}

commit_all() {
    git -C "${REPO}" add -A
    git -C "${REPO}" -c user.name=test -c user.email=test@example.com commit -q --no-verify -m fixture
}

@test "pre-commit passes when check-drift passes" {
    write_check_drift 'printf "0 failed check(s)\n"'

    run_pre_commit
    assert_success
    assert_output --partial "0 failed check(s)"
}

@test "pre-commit reports a check-drift failure as drift" {
    write_check_drift 'printf "FAIL  retired term\n"; exit 1'

    run_pre_commit
    assert_failure
    assert_output --partial "check-drift failed; see ~/.config/agents/MAINTENANCE.md"
    refute_output --partial "crashed"
}

@test "pre-commit reports a check-drift crash as a crash, not drift" {
    write_check_drift 'kill -BUS $$'

    run_pre_commit
    assert_failure
    assert_output --partial "check-drift crashed (signal 10), not a drift failure"
    assert_output --partial "run ${CHECK_DRIFT} by hand"
    refute_output --partial "see ~/.config/agents/MAINTENANCE.md"
}

@test "pre-commit skips when the agents checkout is missing" {
    run_pre_commit
    assert_success
    assert_output --partial "skipping check-drift"
}

@test "pre-commit fails on a staged shell script ShellCheck flags, before check-drift" {
    command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
    write_check_drift 'printf "check-drift ran\n"'
    write_bad_script bad.sh
    git -C "${REPO}" add bad.sh

    run_pre_commit
    assert_failure
    assert_output --partial "running shellcheck on staged files"
    assert_output --partial "SC2086"
    refute_output --partial "check-drift ran"
}

@test "pre-commit lints only the staged files" {
    command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
    write_check_drift 'printf "check-drift ran\n"'
    # A tracked script ShellCheck flags, left out of this commit.
    write_bad_script old.sh
    commit_all
    write_good_script new.sh
    printf '#!/usr/bin/env python3\nimport os\n' > "${REPO}/stow/tools/.local/bin/tool"
    printf 'notes\n' > "${REPO}/notes.txt"
    git -C "${REPO}" add new.sh stow/tools/.local/bin/tool notes.txt

    run_pre_commit
    assert_success
    assert_output --partial "running shellcheck on staged files"
    refute_output --partial "old.sh"
    assert_output --partial "check-drift ran"
}

@test "pre-commit skips ShellCheck when the staged change only deletes a script" {
    write_check_drift 'printf "check-drift ran\n"'
    write_bad_script old.sh
    commit_all
    git -C "${REPO}" rm -q old.sh

    run_pre_commit
    assert_success
    refute_output --partial "running shellcheck"
    assert_output --partial "check-drift ran"
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

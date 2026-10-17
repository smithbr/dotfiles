#!/usr/bin/env bats
# Checks on the bash the suite itself runs on (see ensure_test_bash in
# run_tests.sh).

load test_helper

setup() {
    setup_tmpdir
}

teardown() {
    teardown_tmpdir
}

@test "a failing [[ ]] check before a test's last line fails the test" {
    cat > "${TEST_TMPDIR}/probe.bats" <<'EOF'
@test probe {
    [[ -e /nonexistent ]]
    true
}
EOF

    run bats "${TEST_TMPDIR}/probe.bats"

    assert_failure
    assert_output --partial 'not ok 1 probe'
}

@test "the scripts under test keep macOS's own bash" {
    [[ "${OSTYPE}" == darwin* ]] || skip "macOS only"
    cat > "${TEST_TMPDIR}/version.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${BASH_VERSION}"
EOF
    chmod +x "${TEST_TMPDIR}/version.sh"

    run "${TEST_TMPDIR}/version.sh"

    assert_success
    assert_output "$(/bin/bash -c 'printf "%s\n" "${BASH_VERSION}"')"
}

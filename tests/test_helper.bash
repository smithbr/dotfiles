#!/usr/bin/env bash
# Shared helpers loaded by each BATS test file.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"

if [[ -z "${BATS_LIB_PATH:-}" ]]; then
    echo "error: BATS_LIB_PATH is not set. Run tests via tests/run_tests.sh." >&2
    return 1
fi

bats_load_library bats-support
bats_load_library bats-assert

# Create a throwaway temp directory per test, cleaned up automatically.
setup_tmpdir() {
    TEST_TMPDIR="$(mktemp -d)"
    export TEST_TMPDIR
}

teardown_tmpdir() {
    [[ -d "${TEST_TMPDIR:-}" ]] && rm -rf "${TEST_TMPDIR}"
}

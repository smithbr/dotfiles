#!/usr/bin/env bash
# Shared helpers loaded by each BATS test file.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"

load "${TESTS_DIR}/libs/bats-support/load"
load "${TESTS_DIR}/libs/bats-assert/load"

# Create a throwaway temp directory per test, cleaned up automatically.
setup_tmpdir() {
    TEST_TMPDIR="$(mktemp -d)"
    export TEST_TMPDIR
}

teardown_tmpdir() {
    [[ -d "${TEST_TMPDIR:-}" ]] && rm -rf "${TEST_TMPDIR}"
}

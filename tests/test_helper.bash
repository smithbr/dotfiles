#!/usr/bin/env bash
# Shared helpers loaded by each BATS test file.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"
export PROJECT_ROOT

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

# Give a fixture repo the default persona for either OS (home on macOS,
# server on Linux), linking the common layer and, with a second argument of
# yes, the shared editor settings; link.sh refuses a repo without personas/.
write_test_persona() {
    local name
    mkdir -p "$1/personas"
    for name in home server; do
        printf 'os=darwin,linux\nlayers=common\nagents=yes\nagent_apps=claude cursor codex\nskills=core\neditors=%s\nbrew=\nbrew_optional=\nlinux_optional=\n' "${2:-no}" > "$1/personas/${name}"
    done
}

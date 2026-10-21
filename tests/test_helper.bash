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
        printf 'os=darwin,linux\nlayers=common\nagents=yes\nagent_apps=claude cursor codex\nskills=core\neditors=%s\nbrew=\nbrew_optional=\nroles=\n' "${2:-no}" > "$1/personas/${name}"
    done
}

# A gum in $TEST_TMPDIR/bin that answers each call with the next line of
# $GUM_ANSWERS: esc fails as Esc does, "row TEXT" picks the item whose label
# has TEXT then a space, and anything else is printed as the value. pager
# prints its input. Every call's arguments go to $GUM_CALLS.
stub_gum() {
    export GUM_ANSWERS="${TEST_TMPDIR}/gum-answers" GUM_CALLS="${TEST_TMPDIR}/gum-calls"
    printf '%s\n' "$@" > "${GUM_ANSWERS}"
    : > "${GUM_CALLS}"
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/gum" <<'GUM'
#!/bin/bash
printf '%s\n' "$*" >> "${GUM_CALLS}"
[[ "$1" != pager ]] || exec cat
answer="$(head -n 1 "${GUM_ANSWERS}")"
sed -i.bak 1d "${GUM_ANSWERS}"
case "${answer}" in
    esc) exit 1 ;;
    row\ *)
        for item in "$@"; do
            label="${item%%$'\t'*}"
            [[ "${label}" != *"${answer#row } "* ]] || { printf '%s\n' "${item#*$'\t'}"; exit 0; }
        done
        exit 1
        ;;
    *) printf '%s\n' "${answer}" ;;
esac
GUM
    chmod +x "${TEST_TMPDIR}/bin/gum"
}

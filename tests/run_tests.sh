#!/usr/bin/env bash
# Run the full test suite, or with --lint-only just ShellCheck (what the
# pre-push hook runs; CI runs everything). Name test files to run only those:
# ./tests/run_tests.sh tests/link.bats --filter add
# After --lint-only, named files limit the lint to those of them it would
# check anyway (what the pre-commit hook does with the staged files).
#
# Bats, its libraries, GNU parallel, a Python with tomllib, and on a Mac a bash
# new enough for Bats come from a per-user cache that tests/deps.sh fills on the
# first run (see its header). shellcheck and stow are the machine's own tools
# (Brewfile.core, apt) and are required, never installed here.

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT_ONLY=0
if [[ "${1:-}" == --lint-only ]]; then
    LINT_ONLY=1
    shift
fi

require_tool() { # name hint
    command -v "$1" >/dev/null 2>&1 && return
    echo "error: $1 not found; $2" >&2
    exit 1
}

run_shellcheck() { # [file...]
    local file
    local -a shellcheck_files=()
    local wanted=''
    [[ "$#" -eq 0 ]] || wanted=$'\n'"$(printf '%s\n' "$@")"$'\n'

    while IFS= read -r file; do
        [[ -z "${wanted}" || "${wanted}" == *$'\n'"${file}"$'\n'* ]] || continue
        # Bin scripts may be written in another language (ai-doctor is Python).
        if [[ "${file}" == stow/*/.local/bin/* ]] && ! head -n 1 "${file}" | grep -Eq '^#!.*[/ ](ba)?sh$'; then
            continue
        fi
        shellcheck_files+=("${file}")
    done < <(git ls-files -- '*.sh' '*.bash' 'stow/*/.local/bin/*')

    if [[ "${#shellcheck_files[@]}" -eq 0 ]]; then
        printf 'No shell scripts found for shellcheck\n'
        return
    fi

    printf 'Running shellcheck\n'
    shellcheck "${shellcheck_files[@]}"
}

# Before 4.1, bash does not let a failing [[ ]] trip errexit, so under macOS's
# /bin/bash 3.2 a [[ ]] check that is not a test's last line can never fail it.
# Run Bats on the newer bash deps.sh found or built, but keep the scripts under
# test on /bin/bash, the one a fresh Mac runs them with: a `bash` shim first on
# PATH (Bats' shebangs are `#!/usr/bin/env bash`) hands Bats' own programs to
# the new bash and everything else, `bash -c` and script shebangs, to /bin/bash.
ensure_test_bash() {
    local system_bash=/bin/bash
    [[ -x "${system_bash}" ]] || system_bash="$(command -v bash)"
    [[ "${DEPS_TEST_BASH}" != "${system_bash}" ]] || return 0

    BASH_SHIM_DIR="$(mktemp -d)"
    trap 'rm -rf "${BASH_SHIM_DIR}"' EXIT
    # shellcheck disable=SC2016 # the shim expands these, not this script
    {
        printf '#!%s\n' "${system_bash}"
        printf 'case "${1##*/}" in\n'
        printf '    bats | bats-*) exec %q "$@" ;;\n' "${DEPS_TEST_BASH}"
        printf 'esac\n'
        printf 'exec %q "$@"\n' "${system_bash}"
    } > "${BASH_SHIM_DIR}/bash"
    chmod +x "${BASH_SHIM_DIR}/bash"
    PATH="${BASH_SHIM_DIR}:${PATH}"
    export PATH
}

require_tool shellcheck 'install it with brew install shellcheck (apt install shellcheck on Debian)'
if [[ "${LINT_ONLY}" -eq 1 ]]; then
    run_shellcheck "$@"
    exit 0
fi
run_shellcheck

# The link suite drives the real GNU Stow against scratch directories.
require_tool stow 'install it with brew install stow (apt install stow on Debian)'

# shellcheck source=tests/deps.sh
source "${TESTS_DIR}/deps.sh"
deps_ensure
ensure_test_bash

# The cache's python3 (uv's, with tomllib) first, so every test sees the same
# interpreter; bats and parallel last, where runner.bats and Bats' --jobs find
# them without shadowing anything.
[[ -x "${DEPS_DIR}/python/python3" ]] && PATH="${DEPS_DIR}/python:${PATH}"
PATH="${PATH}:${DEPS_DIR}/bin"
export PATH

# Run tests in parallel across all available cores. Each test isolates its own
# state via setup_tmpdir (mktemp -d), so parallel execution is safe and roughly
# halves wall-clock time versus serial. getconf is portable across macOS/Linux;
# fall back to 1 job if the core count can't be determined.
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"

# Test files or directories named on the command line replace the default of
# every suite; any other argument is passed on to Bats.
targets=()
bats_args=()
for arg in "$@"; do
    if [[ "${arg}" == *.bats && -f "${arg}" ]] || [[ -d "${arg}" ]]; then
        targets+=("${arg}")
    else
        bats_args+=("${arg}")
    fi
done
[[ "${#targets[@]}" -gt 0 ]] || targets=("${TESTS_DIR}"/*.bats)

"${DEPS_BATS}" --jobs "${JOBS}" ${bats_args[@]+"${bats_args[@]}"} "${targets[@]}"

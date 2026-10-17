#!/usr/bin/env bash
# Run the full test suite using Homebrew-installed Bats, or with --lint-only
# just ShellCheck (what the pre-push hook runs; CI runs everything). Name test
# files to run only those: ./tests/run_tests.sh tests/link.bats --filter add

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT_ONLY=0
if [[ "${1:-}" == --lint-only ]]; then
    LINT_ONLY=1
    shift
fi

if ! command -v brew >/dev/null 2>&1; then
    echo "error: Homebrew not found. Install Homebrew first." >&2
    exit 1
fi

formula_installed() {
    local formula="$1"
    brew list --versions "${formula}" >/dev/null 2>&1
}

ensure_shellcheck() {
    if ! formula_installed "shellcheck"; then
        printf 'Installing test dependency: shellcheck\n'
        brew install shellcheck
    fi
}

# The link suite drives the real GNU Stow against scratch directories.
ensure_stow() {
    if ! formula_installed "stow"; then
        printf 'Installing test dependency: stow\n'
        brew install stow
    fi
}

# GNU parallel is required for Bats' --jobs flag (parallel test execution).
# Being installed is not enough: the keg stays unlinked when another formula
# already owns one of its binaries (e.g. sem-cli owns bin/sem), so `parallel`
# can be absent from PATH while `brew list` reports it present. Fall back to the
# keg's own bin directory instead of relinking, which would clobber that
# formula. Appended, not prepended, so we don't shadow the other formula here.
ensure_parallel() {
    if ! formula_installed "parallel"; then
        printf 'Installing test dependency: parallel\n'
        # A failed link step fails the install too, though the keg is there.
        brew install parallel || formula_installed "parallel"
    fi

    if command -v parallel >/dev/null 2>&1; then
        return
    fi

    local keg_bin
    keg_bin="$(brew --prefix parallel 2>/dev/null)/bin"
    if [[ -x "${keg_bin}/parallel" ]]; then
        printf 'Note: GNU parallel is unlinked; using %s\n' "${keg_bin}"
        PATH="${PATH}:${keg_bin}"
        export PATH
    fi
}

ensure_bats_dependencies() {
    local -a missing_formulae=()

    formula_installed "bats-core" || missing_formulae+=("bats-core")
    formula_installed "bats-support" || missing_formulae+=("bats-support")
    formula_installed "bats-assert" || missing_formulae+=("bats-assert")

    if [[ "${#missing_formulae[@]}" -gt 0 ]]; then
        echo "Installing test dependencies: ${missing_formulae[*]}"
        brew tap bats-core/bats-core >/dev/null 2>&1 || true
        # Newer Homebrew refuses formulae from taps nobody has trusted; older
        # releases have no trust command, so a failure here is not fatal.
        brew trust bats-core/bats-core >/dev/null 2>&1 || true
        brew install "${missing_formulae[@]}"
    fi
}

# Before 4.1, bash does not let a failing [[ ]] trip errexit, so under macOS's
# /bin/bash 3.2 a [[ ]] check that is not a test's last line can never fail it.
# Run Bats on a newer bash from Homebrew, but keep the scripts under test on
# /bin/bash, the one a fresh Mac runs them with, even when Homebrew's bash comes
# first on PATH: a `bash` shim first on PATH (Bats' shebangs are
# `#!/usr/bin/env bash`) hands Bats' own programs to the new bash and
# everything else, `bash -c` and script shebangs, to /bin/bash.
ensure_test_bash() {
    local system_bash=/bin/bash test_bash
    [[ -x "${system_bash}" ]] || system_bash="$(command -v bash)"
    if "${system_bash}" -c '(( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] >= 401 ))'; then
        return
    fi

    # Installed only for the tests, so unlinked: putting bash 5 first on PATH
    # would change which bash `#!/usr/bin/env bash` finds outside them too.
    if ! formula_installed "bash"; then
        printf 'Installing test dependency: bash (unlinked)\n'
        brew install bash
        brew unlink bash >/dev/null
    fi
    test_bash="$(brew --prefix bash)/bin/bash"

    BASH_SHIM_DIR="$(mktemp -d)"
    trap 'rm -rf "${BASH_SHIM_DIR}"' EXIT
    # shellcheck disable=SC2016 # the shim expands these, not this script
    {
        printf '#!%s\n' "${system_bash}"
        printf 'case "${1##*/}" in\n'
        printf '    bats | bats-*) exec %q "$@" ;;\n' "${test_bash}"
        printf 'esac\n'
        printf 'exec %q "$@"\n' "${system_bash}"
    } > "${BASH_SHIM_DIR}/bash"
    chmod +x "${BASH_SHIM_DIR}/bash"
    PATH="${BASH_SHIM_DIR}:${PATH}"
    export PATH
}

run_shellcheck() {
    local file
    local -a shellcheck_files=()

    while IFS= read -r file; do
        # Bin scripts may be written in another language (st is Python).
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

ensure_shellcheck
run_shellcheck
[[ "${LINT_ONLY}" -eq 0 ]] || exit 0

ensure_stow
ensure_parallel
ensure_bats_dependencies
ensure_test_bash

BREW_PREFIX="$(brew --prefix)"
BATS="${BREW_PREFIX}/bin/bats"

if [[ ! -x "${BATS}" ]]; then
    echo "error: bats not found after install at ${BATS}" >&2
    exit 1
fi

if [[ ! -f "${BREW_PREFIX}/lib/bats-support/load.bash" ]]; then
    echo "error: bats-support not found after install" >&2
    exit 1
fi

if [[ ! -f "${BREW_PREFIX}/lib/bats-assert/load.bash" ]]; then
    echo "error: bats-assert not found after install" >&2
    exit 1
fi

export BATS_LIB_PATH="${BREW_PREFIX}/lib"

# Run tests in parallel across all available cores. Each test isolates its own
# state via setup_tmpdir (mktemp -d), so parallel execution is safe and roughly
# halves wall-clock time versus serial. getconf is portable across macOS/Linux;
# fall back to 1 job if the core count can't be determined.
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"

# Without GNU parallel, Bats' --jobs silently executes zero tests, so refuse to
# run in parallel unless it is genuinely callable.
if ! command -v parallel >/dev/null 2>&1; then
    printf 'warning: GNU parallel unavailable; running tests serially\n' >&2
    JOBS=1
fi

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

"${BATS}" --jobs "${JOBS}" ${bats_args[@]+"${bats_args[@]}"} "${targets[@]}"

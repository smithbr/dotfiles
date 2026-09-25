#!/usr/bin/env bash
# Run the full test suite using Homebrew-installed Bats.

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# GNU parallel is required for Bats' --jobs flag (parallel test execution).
# Being installed is not enough: the keg stays unlinked when another formula
# already owns one of its binaries (e.g. sem-cli owns bin/sem), so `parallel`
# can be absent from PATH while `brew list` reports it present. Fall back to the
# keg's own bin directory instead of relinking, which would clobber that
# formula. Appended, not prepended, so we don't shadow the other formula here.
ensure_parallel() {
    if ! formula_installed "parallel"; then
        printf 'Installing test dependency: parallel\n'
        brew install parallel
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
        brew install "${missing_formulae[@]}"
    fi
}

run_shellcheck() {
    local file
    local -a shellcheck_files=()

    while IFS= read -r file; do
        shellcheck_files+=("${file}")
    done < <(git ls-files -- '*.sh' '*.bash' 'dotfiles/dot_local/bin/*')

    if [[ "${#shellcheck_files[@]}" -eq 0 ]]; then
        printf 'No shell scripts found for shellcheck\n'
        return
    fi

    printf 'Running shellcheck\n'
    shellcheck "${shellcheck_files[@]}"
}

ensure_shellcheck
ensure_parallel
ensure_bats_dependencies

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

run_shellcheck

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

"${BATS}" --jobs "${JOBS}" "${TESTS_DIR}"/*.bats "$@"

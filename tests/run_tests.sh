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

"${BATS}" "${TESTS_DIR}"/*.bats "$@"

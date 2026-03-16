#!/usr/bin/env bash
# Run the full test suite using the vendored BATS.

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BATS="${TESTS_DIR}/libs/bats-core/bin/bats"

if [[ ! -x "${BATS}" ]]; then
    echo "error: bats not found. Run 'git submodule update --init --recursive'" >&2
    exit 1
fi

"${BATS}" "${TESTS_DIR}"/*.bats "$@"

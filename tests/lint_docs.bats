#!/usr/bin/env bats
# lint-docs.sh against scratch repos: a clean one passes, and each fault it
# guards against fails naming the file.

load test_helper

setup() {
    setup_tmpdir
    REPO="${TEST_TMPDIR}/repo"
    mkdir -p "${REPO}/scripts" "${REPO}/docs" "${REPO}/stow/tools/.local/bin"
    git -C "${REPO}" init -q
    printf '#!/usr/bin/env bash\n# Does one thing.\nset -euo pipefail\n[[ "${1:-}" == --dry-run ]] && echo "${SCRATCH_HOME:-}"\n' > "${REPO}/scripts/tool.sh"
    printf '# Repo\n\nRun `scripts/tool.sh` with `--dry-run`; `SCRATCH_HOME` moves its state.\n' > "${REPO}/README.md"
}

teardown() {
    teardown_tmpdir
}

run_lint() {
    git -C "${REPO}" add -A
    run env "$@" bash "${PROJECT_ROOT}/tests/lint-docs.sh" "${REPO}"
}

# A Markdown paragraph of N words, with a parenthetical every GAP words.
prose_words() { # n gap
    local i
    for ((i = 1; i <= $1; i++)); do
        if ((i % $2 == 0)); then printf '(aside) '; else printf 'word '; fi
    done
    printf '\n'
}

@test "lint-docs: a clean repo passes with one ok line per check" {
    run_lint
    assert_success
    assert_line --partial "ok    every documented path exists"
    assert_line --partial "ok    every documented flag and variable is in a script"
    assert_line --partial "ok    every Markdown file is under"
    assert_line --partial "ok    no comment paragraph is over 6 lines"
}

@test "lint-docs: a documented path that does not exist fails naming it" {
    printf 'See `scripts/gone.sh` and `docs/also-gone.md`.\n' >> "${REPO}/README.md"
    run_lint
    assert_failure
    assert_line --partial 'README.md: `scripts/gone.sh` does not exist'
    assert_line --partial 'README.md: `docs/also-gone.md` does not exist'
    assert_line --partial "2 docs check(s) failed"
}

@test "lint-docs: a path resolves against the Markdown file's own directory or by bare name" {
    printf '# Docs\n\nNext to this page: `notes.md`; anywhere: `tool.sh`; from the root: `scripts/tool.sh`.\n' > "${REPO}/docs/README.md"
    printf '# Notes\n' > "${REPO}/docs/notes.md"
    run_lint
    assert_success
}

@test "lint-docs: a flag or variable no script has fails naming it" {
    printf 'Pass `--no-such-flag`; `NO_SUCH_VAR` sets nothing.\n' >> "${REPO}/README.md"
    run_lint
    assert_failure
    assert_line --partial 'README.md: `--no-such-flag` is in no script'
    assert_line --partial 'README.md: `NO_SUCH_VAR` is in no script'
}

@test "lint-docs: a Markdown file over the word limit fails with the count" {
    prose_words 60 1000 >> "${REPO}/README.md"
    run_lint LINT_DOCS_MAX_WORDS=50
    assert_failure
    assert_line --regexp 'README.md: [0-9]+ words, over 50'
}

@test "lint-docs: too many parentheticals fail; code spans and links do not count" {
    prose_words 200 100 >> "${REPO}/README.md"
    run_lint
    assert_success
    prose_words 200 25 >> "${REPO}/docs/dense.md"
    run_lint
    assert_failure
    assert_line --regexp 'docs/dense.md: [0-9]+ parentheticals in [0-9]+ words, over 20 per 1000'
    printf '`(not prose)` [link](https://example.com/(x)) `(nor this)`\n' > "${REPO}/docs/dense.md"
    prose_words 200 1000 >> "${REPO}/docs/dense.md"
    run_lint
    assert_success
}

@test "lint-docs: a comment paragraph over the limit fails with its lines; a bare # splits it" {
    {
        printf '#!/usr/bin/env bash\n# shellcheck disable=SC2034\n'
        for i in 1 2 3 4 5 6 7; do printf '# line %s\n' "${i}"; done
        printf 'true\n'
    } > "${REPO}/scripts/long.sh"
    run_lint
    assert_failure
    assert_line --partial "scripts/long.sh:3-9: comment paragraph (7 lines) is over 6"

    {
        printf '#!/usr/bin/env bash\n'
        for i in 1 2 3; do printf '# line %s\n' "${i}"; done
        printf '#\n'
        for i in 4 5 6 7; do printf '# line %s\n' "${i}"; done
        printf 'true\n'
    } > "${REPO}/scripts/long.sh"
    run_lint
    assert_success
}

@test "lint-docs: a bin script in another language is not read for comments" {
    {
        printf '#!/usr/bin/env python3\n'
        for i in 1 2 3 4 5 6 7 8; do printf '# line %s\n' "${i}"; done
    } > "${REPO}/stow/tools/.local/bin/py-tool"
    {
        printf '#!/usr/bin/env bash\n'
        for i in 1 2 3 4 5 6 7 8; do printf '# line %s\n' "${i}"; done
        printf 'true\n'
    } > "${REPO}/stow/tools/.local/bin/sh-tool"
    run_lint
    assert_failure
    refute_line --partial "py-tool"
    assert_line --partial "stow/tools/.local/bin/sh-tool:2-9"
}

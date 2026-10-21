#!/usr/bin/env bash
set -euo pipefail

# Hand the failed log of this branch's latest CI run to a headless Claude,
# which fixes the cause in the working tree and leaves the diff for review.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common.sh
source "${REPO_ROOT}/scripts/common.sh"

GH_BIN="${GH_BIN:-gh}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
CI_FIX_LOG_LINES="${CI_FIX_LOG_LINES:-400}"
# Read and edit anything, but run only the test runner and read-only git.
CI_FIX_TOOLS="Read,Grep,Glob,Edit,Write,Bash(./tests/run_tests.sh:*),Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(git blame:*)"

DRY_RUN=0
RUN_ID=""

usage() {
    local text
    text="$(cat <<'EOF'
# ci-fix.sh

Give the failed log of this branch's latest CI run to `claude -p`, which finds the cause, fixes it in the working tree, and runs the affected Bats files. It never commits or pushes; the diff is left for you to review.

## Steps

1. Find the latest CI run on the current branch with `gh`, or use RUN_ID. A run that did not fail ends here.
2. Take the last 400 lines of its failed steps (`CI_FIX_LOG_LINES` changes it).
3. Run Claude on them with edits allowed, and as commands only `./tests/run_tests.sh` and read-only git.
4. List the changed files.

It needs `gh` signed in, `claude`, and a clean working tree, so the diff is only Claude's.

## Options

- `-n`, `--dry-run`: show the run, the log, and the prompt; do not start Claude.
- `-h`, `--help`: show this help.

## Examples

```bash
./tests/ci-fix.sh
./tests/ci-fix.sh 18342277104
./tests/ci-fix.sh --dry-run | less
```
EOF
)"
    if [[ "${HAS_GUM}" == true ]]; then
        gum format <<< "${text}"
    else
        printf '%s\n' "${text}"
    fi
}

prompt_text() { # run_id sha
    cat <<EOF
CI run $1 failed on commit $2 of this repository. The failing output is on stdin.
Read AGENTS.md and the README.md of each directory you change, and follow them.
Find the root cause; watch for assumptions about git history, since CI checks out a shallow clone.
Fix it in the working tree. Verify with ./tests/run_tests.sh and only the Bats files the fix affects, never the full suite.
Do not commit, push, or install anything. End with the cause, the fix, and which tests you ran.
EOF
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
            -n | --dry-run) DRY_RUN=1 ;;
            -h | --help | help)
                usage
                exit 0
                ;;
            -*) die "Unknown option: $1 (see tests/ci-fix.sh --help)" ;;
            *)
                [[ -z "${RUN_ID}" ]] || die "Only one run ID: $1 (see tests/ci-fix.sh --help)"
                [[ "$1" =~ ^[0-9]+$ ]] || die "Not a run ID: $1"
                RUN_ID="$1"
                ;;
        esac
        shift
    done
}

main() {
    local branch fields conclusion sha log

    parse_args "$@"
    cd "${REPO_ROOT}"

    command -v "${GH_BIN}" >/dev/null 2>&1 || die "gh not found; install it with brew install gh"
    [[ "${DRY_RUN}" -eq 1 ]] || command -v "${CLAUDE_BIN}" >/dev/null 2>&1 \
        || die "claude not found; install Claude Code first"
    if [[ "${DRY_RUN}" -eq 0 && -n "$(git status --porcelain --untracked-files=no)" ]]; then
        die "The working tree has changes; commit or stash them first so the diff is only Claude's"
    fi

    branch="$(git branch --show-current)"
    if [[ -z "${RUN_ID}" ]]; then
        fields="$("${GH_BIN}" run list --branch "${branch}" --workflow ci.yml --limit 1 \
            --json databaseId,conclusion,headSha --jq '.[0] | "\(.databaseId) \(.headSha) \(.conclusion)"')" \
            || die "Could not list CI runs; check gh auth status"
        [[ -n "${fields}" && "${fields}" != null* ]] || die "No CI runs on ${branch}"
    else
        fields="$("${GH_BIN}" run view "${RUN_ID}" --json databaseId,conclusion,headSha \
            --jq '"\(.databaseId) \(.headSha) \(.conclusion)"')" || die "No CI run ${RUN_ID}"
    fi
    # Conclusion last: it is empty while a run is in progress.
    read -r RUN_ID sha conclusion <<< "${fields}"

    _header "ci-fix: run ${RUN_ID} on ${branch}"
    if [[ "${conclusion}" != failure ]]; then
        _success "Run ${RUN_ID} did not fail (${conclusion:-still running}); nothing to fix"
        exit 0
    fi
    if [[ "${sha}" != "$(git rev-parse HEAD)" ]]; then
        log_warn "Run ${RUN_ID} tested ${sha:0:7}, but HEAD is $(git rev-parse --short HEAD)"
    fi

    log="$("${GH_BIN}" run view "${RUN_ID}" --log-failed | tail -n "${CI_FIX_LOG_LINES}")" \
        || die "Could not fetch the log of run ${RUN_ID}"
    [[ -n "${log}" ]] || die "Run ${RUN_ID} has no failed-step log yet; try again once it finishes"

    if [[ "${DRY_RUN}" -eq 1 ]]; then
        _header "Log: last ${CI_FIX_LOG_LINES} lines of the failed steps"
        printf '%s\n' "${log}"
        _header "Prompt"
        prompt_text "${RUN_ID}" "${sha}"
        _header "Tools"
        printf '%s\n' "${CI_FIX_TOOLS}"
        printf 'Dry run: Claude not started\n'
        exit 0
    fi

    _header "Claude"
    printf '%s\n' "${log}" | "${CLAUDE_BIN}" -p "$(prompt_text "${RUN_ID}" "${sha}")" \
        --allowedTools "${CI_FIX_TOOLS}" || die "Claude failed; any edits it made are still in the working tree"

    _header "Changes"
    if [[ -z "$(git status --porcelain --untracked-files=no)" ]]; then
        _warn "Claude changed nothing"
        exit 1
    fi
    git status --short
    _header "Next steps"
    _box "- git diff
- git commit -am '...' && git push"
}

main "$@"

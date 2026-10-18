#!/usr/bin/env bash
# Keep the docs and comments short and true. run_tests.sh --lint-only runs it,
# so the pre-commit hook and CI do too. Exit 1 when any check fails.
#
# Drift: a backticked repo path, --flag, or UPPER_CASE name in a Markdown file
# must exist in a tracked file. Verbosity: a Markdown file stays under
# MAX_WORDS words and MAX_PARENS parentheticals per 1000 words, and a comment
# paragraph in a shell script runs at most MAX_COMMENT_RUN lines.

set -euo pipefail

MAX_WORDS="${LINT_DOCS_MAX_WORDS:-1500}"
MAX_PARENS="${LINT_DOCS_MAX_PARENS:-20}"
MAX_COMMENT_RUN="${LINT_DOCS_MAX_COMMENT_RUN:-6}"
# Flags that stand for any flag in scripts/DESIGN.md.
PLACEHOLDER_FLAGS='--opt'

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "${ROOT}"

failures=0
fail() { printf 'FAIL  %s\n' "$*"; failures=$((failures + 1)); }
ok() { printf 'ok    %s\n' "$*"; }

# Tracked files when in a git repo, else everything under ROOT.
tracked() { # [pathspec...]
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git ls-files -- "$@"
    else
        find . -type f -not -path './.git/*' | sed 's|^\./||' | sort
    fi
}

markdown_files() { tracked '*.md' | grep -v '^\.github/' || true; }

shell_files() {
    local file
    while IFS= read -r file; do
        if [[ "${file}" == stow/*/.local/bin/* ]] && ! head -n 1 "${file}" | grep -Eq '^#!.*[/ ](ba)?sh$'; then
            continue
        fi
        printf '%s\n' "${file}"
    done < <(tracked '*.sh' '*.bash' 'stow/*/.local/bin/*')
}

# Markdown prose: fenced blocks, code spans, and link targets removed.
prose() { # file
    # shellcheck disable=SC2016 # literal backticks
    awk '/^```/ { fence = !fence; next } !fence { print }' "$1" \
        | sed -e 's/`[^`]*`//g' -e 's/\]([^)]*)//g'
}

# Every backticked token in the Markdown files, as FILE<TAB>TOKEN.
backticked() {
    local file
    while IFS= read -r file; do
        # shellcheck disable=SC2016 # literal backticks
        grep -oE '`[^` ]+`' "${file}" 2>/dev/null | tr -d '`' | sort -u | sed "s|^|${file}	|"
    done < <(markdown_files)
}

check_paths() {
    local file token dir found=0 bad=0
    while IFS=$'\t' read -r file token; do
        case "${token}" in
            *'*'* | *'<'* | '~'* | /* | http* | *'$'* | .) continue ;;
        esac
        if [[ "${token}" == */* ]]; then
            [[ "${token}" =~ ^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+/?$ ]] || continue
        else
            [[ "${token}" =~ ^[A-Za-z0-9_-]+\.(sh|bash|bats|md|txt|toml|json|yml|yaml|itermcolors)$ ]] || continue
        fi
        dir="$(dirname "${file}")"
        found=0
        if [[ -e "${token}" || -e "${dir}/${token}" ]]; then
            found=1
        elif [[ "${token}" != */* ]] && tracked | grep -q "\(^\|/\)${token}$"; then
            found=1
        fi
        if [[ "${found}" -eq 0 ]]; then
            fail "${file}: \`${token}\` does not exist"
            bad=1
        fi
    done < <(backticked)
    [[ "${bad}" -eq 1 ]] || ok "every documented path exists"
}

# Backticked --flags and UPPER_CASE names must appear in a non-Markdown file.
check_names() {
    local file token name bad=0
    while IFS=$'\t' read -r file token; do
        if [[ "${token}" =~ ^-{1,2}[A-Za-z][A-Za-z0-9-]* ]]; then
            name="${BASH_REMATCH[0]}"
            [[ " ${PLACEHOLDER_FLAGS} " != *" ${name} "* ]] || continue
            git grep -qF -- "${name}" -- ':!*.md' 2>/dev/null && continue
        elif [[ "${token}" =~ ^[A-Z][A-Z0-9_]{3,}$ ]]; then
            name="${token}"
            git grep -qwF -- "${name}" -- ':!*.md' 2>/dev/null && continue
        else
            continue
        fi
        fail "${file}: \`${name}\` is in no script"
        bad=1
    done < <(backticked)
    [[ "${bad}" -eq 1 ]] || ok "every documented flag and variable is in a script"
}

check_markdown_size() {
    local file words parens per_thousand bad=0
    while IFS= read -r file; do
        words="$(wc -w < "${file}" | tr -d ' ')"
        if [[ "${words}" -gt "${MAX_WORDS}" ]]; then
            fail "${file}: ${words} words, over ${MAX_WORDS}; cut it or move a part to the directory that owns it"
            bad=1
        fi
        parens="$(prose "${file}" | grep -oE '\([^)]+\)' | grep -cvE '^\(s\)$' || true)"
        [[ "${words}" -ge 200 ]] || continue
        per_thousand=$((parens * 1000 / words))
        if [[ "${per_thousand}" -gt "${MAX_PARENS}" ]]; then
            fail "${file}: ${parens} parentheticals in ${words} words, over ${MAX_PARENS} per 1000; make them sentences or drop them"
            bad=1
        fi
    done < <(markdown_files)
    [[ "${bad}" -eq 1 ]] || ok "every Markdown file is under ${MAX_WORDS} words and ${MAX_PARENS} parentheticals per 1000"
}

# A comment paragraph is a run of full-line comments; a bare # or a blank
# line ends it. The shebang and shellcheck directives do not count.
check_comment_runs() {
    local file hit bad=0
    while IFS= read -r file; do
        hit="$(awk -v max="${MAX_COMMENT_RUN}" '
            /^[[:space:]]*#!/ || /^[[:space:]]*# shellcheck/ { next }
            /^[[:space:]]*#[[:space:]]*$/ { run = 0; next }
            /^[[:space:]]*#/ { run++; if (run == max + 1) start = NR - max; next }
            { if (run > max) printf "%d-%d (%d lines)\n", start, NR - 1, run; run = 0 }
            END { if (run > max) printf "%d-%d (%d lines)\n", start, NR, run }
        ' "${file}")"
        [[ -n "${hit}" ]] || continue
        while IFS= read -r line; do
            fail "${file}:${line%% *}: comment paragraph ${line#* } is over ${MAX_COMMENT_RUN}; say it once, shorter, or in the README"
        done <<< "${hit}"
        bad=1
    done < <(shell_files)
    [[ "${bad}" -eq 1 ]] || ok "no comment paragraph is over ${MAX_COMMENT_RUN} lines"
}

check_paths
check_names
check_markdown_size
check_comment_runs

if [[ "${failures}" -gt 0 ]]; then
    printf '%d docs check(s) failed\n' "${failures}" >&2
    exit 1
fi

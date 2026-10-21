#!/usr/bin/env bash

set -euo pipefail

# Default XDG_CONFIG_HOME so brew trust grants made before ~/.zshenv is linked
# land where the shell reads them. Guarded on HOME for callers that unset it.
if [[ -z "${XDG_CONFIG_HOME:-}" && -n "${HOME:-}" ]]; then
    export XDG_CONFIG_HOME="${HOME}/.config"
fi

# Styling uses the terminal's own 16 ANSI colors, so it follows the theme;
# only the log labels below use gum's fixed 256-color palette.
# HAS_COLOR and HAS_COLOR_ERR: stdout and stderr are a terminal and NO_COLOR
# is unset. HAS_GUM: gum is installed and stdout a terminal, for boxes, help,
# and pickers. Decided when sourced; call again after changing PATH.
detect_gum() {
    HAS_GUM=false HAS_COLOR=false HAS_COLOR_ERR=false
    command -v gum >/dev/null 2>&1 && [[ -t 1 ]] && HAS_GUM=true
    if [[ -z "${NO_COLOR:-}" ]]; then
        [[ -t 1 ]] && HAS_COLOR=true
        [[ -t 2 ]] && HAS_COLOR_ERR=true
    fi
    return 0
}
detect_gum

# gum's key-help line is drawn in fixed dark grays that a dark theme hides, so
# it is off for every gum prompt. A picker that needs more than arrows and
# Enter lists its keys in its header instead, as choose_many does.
export GUM_CHOOSE_SHOW_HELP=false GUM_CONFIRM_SHOW_HELP=false \
    GUM_FILTER_SHOW_HELP=false GUM_INPUT_SHOW_HELP=false

# One line of TEXT in ANSI style CODE when COLOR is true, else PLAIN.
_paint() {
    local color="$1" code="$2" text="$3" plain="$4"
    if [[ "${color}" == true ]]; then
        printf '\033[%sm%s\033[0m\n' "${code}" "${text}"
    else
        printf '%s\n' "${plain}"
    fi
}

# Log lines lead with a bold label in gum log's own 256-color palette, so they
# match gum's levels: INFO 86, WARN 192, ERROR 204. gum has no success level;
# SUCCESS (_success) is 84, a green from the same bright family.
log_info() { _badge "${HAS_COLOR}" '1;38;5;86' INFO "$*"; }
log_warn() { _badge "${HAS_COLOR_ERR}" '1;38;5;192' WARN "$*" >&2; }
log_error() { _badge "${HAS_COLOR_ERR}" '1;38;5;204' ERROR "$*" >&2; }

_header() { _paint "${HAS_COLOR}" '1;35' "$1" "$1"; }
_item() { _paint "${HAS_COLOR}" '2' "  $1" "  $1"; }
_check() { _paint "${HAS_COLOR}" '32' "  ✓ $1" "  ok: $1"; }
_cross() { _paint "${HAS_COLOR}" '31' "  ✗ $1" "  failed: $1"; }
_caution() { _paint "${HAS_COLOR}" '33' "  ! $1" "  warning: $1"; }
_skip() { _paint "${HAS_COLOR}" '2' "  - $1" "  skipped: $1"; }
# The last line of a run: a bold LABEL in style CODE, then TEXT.
_badge() {
    local color="$1" code="$2" label="$3" text="$4"
    if [[ "${color}" == true ]]; then
        printf '\033[%sm%s\033[0m %s\n' "${code}" "${label}" "${text}"
    else
        printf '%s %s\n' "${label}" "${text}"
    fi
}

_success() { _badge "${HAS_COLOR}" '1;38;5;84' SUCCESS "$1"; }
_warn() { _badge "${HAS_COLOR_ERR}" '1;38;5;192' WARN "$1" >&2; }

# A bordered block. gum style never wraps, so a line wider than the terminal
# would tear the border; cap the box to the terminal width only when needed.
_box() {
    local content="$1" columns=0 longest=0
    local -a width_args=()

    if [[ "${HAS_GUM}" == true ]]; then
        columns="${COLUMNS:-$(tput cols 2>/dev/null || printf '80')}"
        longest="$(printf '%s\n' "${content}" | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }')"
        if (( longest + 4 > columns && columns > 12 )); then
            width_args=(--width "$((columns - 2))")
        fi
        printf '%s' "${content}" | gum style --border rounded --border-foreground 8 --margin "0 0" --padding "0 1" ${width_args[@]+"${width_args[@]}"}
    else
        printf '%s\n' "${content}" | sed 's/^/  /'
    fi
}

die() {
    _badge "${HAS_COLOR_ERR}" '1;38;5;204' ERROR "$1" >&2
    exit 1
}

# Results and follow-ups gathered during a run, shown together at the end.
declare -a SUMMARY_RESULTS=()
declare -a NEXT_STEPS=()
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

add_result() {
    local kind="$1" message="$2"

    SUMMARY_RESULTS+=("${kind}"$'\t'"${message}")
    case "${kind}" in
        PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
        WARN) WARN_COUNT=$((WARN_COUNT + 1)) ;;
        FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    esac
}

add_next_step() {
    local step="$1" existing

    for existing in ${NEXT_STEPS[@]+"${NEXT_STEPS[@]}"}; do
        [[ "${existing}" == "${step}" ]] && return 0
    done
    NEXT_STEPS+=("${step}")
}

# Every add_result under a Summary header, for a run whose rows were not
# shown as it went.
print_results() {
    local entry body=""

    for entry in ${SUMMARY_RESULTS[@]+"${SUMMARY_RESULTS[@]}"}; do
        body+="${entry%%$'\t'*}  ${entry#*$'\t'}"$'\n'
    done
    [[ -n "${body}" ]] || return 0
    printf '\n'
    _header "Summary"
    _box "${body%$'\n'}"
}

# The end of a run: the count line, then the next steps. Returns 1 when a
# result failed, so it can be the last command of main.
print_summary() {
    local step body=""
    local counts="Passed: ${PASS_COUNT}  Warnings: ${WARN_COUNT}  Failed: ${FAIL_COUNT}"

    printf '\n'
    if ((FAIL_COUNT > 0)); then
        _warn "${counts}"
    else
        _success "${counts}"
    fi
    for step in ${NEXT_STEPS[@]+"${NEXT_STEPS[@]}"}; do
        body+="- ${step}"$'\n'
    done
    if [[ -n "${body}" ]]; then
        printf '\n'
        _header "Next steps"
        _box "${body%$'\n'}"
    fi
    ((FAIL_COUNT == 0))
}

# Help, as markdown on stdin: rendered by gum format on a terminal, printed
# as is otherwise.
show_help() {
    if [[ "${HAS_GUM}" == true ]]; then
        gum format
    else
        cat
    fi
}

require_non_root() {
    if [[ "${EUID}" -eq 0 ]]; then
        log_error "Do not run this script as root."
        exit 1
    fi
}

sudo_cmd() {
    if [[ "${EUID}" -eq 0 ]]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        log_error "sudo is required for: $*"
        exit 1
    fi
}

# Where a tool sits before the shell config puts it on PATH: the native
# ~/.local/bin, and Homebrew's bin (HOMEBREW_PREFIX when set, else its usual
# prefixes on macOS and Linux).
tool_bin_dirs() {
    printf '%s\n' "${HOME}/.local/bin"
    if [[ -n "${HOMEBREW_PREFIX:-}" ]]; then
        printf '%s/bin\n' "${HOMEBREW_PREFIX}"
    else
        printf '%s\n' /opt/homebrew/bin /usr/local/bin /home/linuxbrew/.linuxbrew/bin
    fi
}

# True when NAME is installed through either manager: on PATH, or in one of
# tool_bin_dirs. An optional install's detect line uses it so a tool that
# came through Homebrew, or natively, is not installed again the other way.
tool_installed() {
    local dir
    command -v "$1" >/dev/null 2>&1 && return 0
    while IFS= read -r dir; do
        [[ -x "${dir}/$1" ]] && return 0
    done < <(tool_bin_dirs)
    return 1
}

spin() {
    local title="$1"
    shift

    # gum spin hides the wrapped command's output; --show-error prints it if
    # the command fails, so a failure is never just "<title> failed". VERBOSE=1
    # (see brew.sh -v/--verbose) skips the spinner so output streams through.
    if [[ "${VERBOSE:-0}" -eq 1 ]]; then
        log_info "${title}"
        if ! "$@"; then
            log_error "${title} failed"
            return 1
        fi
        return 0
    fi

    # Spinner only on a terminal and for an external command; else log the
    # title and stream.
    if command -v gum >/dev/null 2>&1 && [[ -t 1 && "$(type -t "$1" 2>/dev/null)" != "function" ]]; then
        if ! gum spin --spinner dot --show-error --title "${title}" --padding="0 1" -- "$@"; then
            log_error "${title} failed"
            return 1
        fi
    else
        log_info "${title}"
        "$@"
    fi
}

# The cursor gets its own column and color: gum draws a ticked row in the
# selected style even under the cursor, so a cursor that shared the tick's
# column or color would vanish on ticked rows.
gum_choose_multiselect() {
    local header="$1"
    local height="$2"
    shift 2

    gum choose \
        --no-limit \
        --ordered \
        --height="${height}" \
        --header="${header}" \
        --cursor="> " \
        --cursor-prefix="  " \
        --selected-prefix="* " \
        --unselected-prefix="  " \
        --padding="0 1" \
        --cursor.foreground="6" \
        --header.foreground="5" \
        --selected.foreground="5" \
        "$@"
}

# How a prompt runs: gum when it is installed and stdin and stderr are a
# terminal (it reads keys from one and draws on the other), else plain reads
# from stdin, which may be a pipe. DOTFILES_PROMPT=gum or read forces a mode.
prompt_mode() {
    if [[ -n "${DOTFILES_PROMPT:-}" ]]; then
        printf '%s\n' "${DOTFILES_PROMPT}"
    elif command -v gum >/dev/null 2>&1 && [[ -t 0 && -t 2 ]]; then
        printf 'gum\n'
    else
        printf 'read\n'
    fi
}

# Yes or no, by gum or a [y/N] question on stderr answered on stdin. No
# unless the answer starts with y; end of input, and Enter in gum, is no.
#   confirm QUESTION
confirm() {
    local answer=""
    if [[ "$(prompt_mode)" == gum ]]; then
        gum confirm --default=false "$1"
        return
    fi
    printf '%s [y/N] ' "$1" >&2
    IFS= read -r answer || answer=""
    [[ "${answer}" =~ ^[Yy] ]]
}

# One of the ITEMs, by gum or a numbered list on stderr, printed to stdout.
# An ITEM may be LABEL<tab>VALUE: the label is shown, the value printed. The
# answer may be a number or a value; anything else, an empty answer, or end
# of input gives DEFAULT (a value), which may be empty.
#   choose_one HEADER DEFAULT ITEM...
choose_one() {
    local header="$1" default="$2" item reply="" index selected=""
    local -a items=() labels=() values=() options=()
    shift 2
    items=("$@")

    for item in "${items[@]}"; do
        labels+=("${item%%$'\t'*}")
        values+=("${item#*$'\t'}")
    done
    if [[ "$(prompt_mode)" == gum ]]; then
        for index in "${!items[@]}"; do
            options+=("${labels[${index}]}"$'\t'"${values[${index}]}")
            # gum matches --selected against labels.
            [[ "${values[${index}]}" != "${default}" ]] || selected="${labels[${index}]}"
        done
        [[ -z "${selected}" ]] || options=(--selected "${selected}" "${options[@]}")
        reply="$(gum choose --header "${header}" --label-delimiter=$'\t' "${options[@]}")" || reply=""
    else
        printf '%s\n' "${header}" >&2
        for index in "${!items[@]}"; do
            printf '  %d) %s\n' "$((index + 1))" "${labels[${index}]}" >&2
        done
        printf 'Choice%s: ' "${default:+ [${default}]}" >&2
        IFS= read -r reply || reply=""
    fi
    if [[ "${reply}" =~ ^[0-9]+$ && "${reply}" -ge 1 && "${reply}" -le "${#items[@]}" ]]; then
        reply="${values[$((reply - 1))]}"
    fi
    for item in "${values[@]}"; do
        if [[ "${item}" == "${reply}" ]]; then
            printf '%s\n' "${item}"
            return 0
        fi
    done
    printf '%s\n' "${default}"
}

# Any number of the ITEMs, by gum multi-select or numbers on stdin ("1 3",
# all, or Enter for none), one per line. An ITEM may be LABEL<tab>VALUE: the
# label is shown, the value printed. Esc, end of input, or an invalid number
# picks none and returns 1. With --selected, those values start selected and
# Enter or end of input keeps them, returning 0; "none" then picks none.
#   choose_many [--selected "VALUE..."] HEADER ITEM...
choose_many() {
    local header selected="" item reply="" token index=1 height mark
    local -a items=() labels=() values=() options=() preselected=()
    if [[ "${1:-}" == --selected ]]; then
        selected=" $2 "
        shift 2
    fi
    header="$1"
    shift
    items=("$@")

    for item in "${items[@]}"; do
        labels+=("${item%%$'\t'*}")
        values+=("${item#*$'\t'}")
    done
    if [[ "$(prompt_mode)" == gum ]]; then
        height="${#items[@]}"
        (( height > 15 )) && height=15
        (( height < 3 )) && height=3
        for index in "${!items[@]}"; do
            options+=("${labels[${index}]}"$'\t'"${values[${index}]}")
            # gum matches --selected against labels.
            [[ "${selected}" != *" ${values[${index}]} "* ]] || preselected+=("${labels[${index}]}")
        done
        if [[ "${#preselected[@]}" -gt 0 ]]; then
            options=(--selected="$(IFS=,; printf '%s' "${preselected[*]}")" "${options[@]}")
        fi
        header+=$'\n'"x toggles, ctrl+a ticks all, enter applies, esc skips"
        # Esc exits non-zero; whatever gum printed before that is no choice.
        reply="$(gum_choose_multiselect "${header}" "${height}" --label-delimiter=$'\t' "${options[@]}")" || return 1
        [[ -z "${reply}" ]] || printf '%s\n' "${reply}"
        return 0
    fi

    printf '%s\n' "${header}" >&2
    for index in "${!items[@]}"; do
        mark=""
        if [[ -n "${selected}" ]]; then
            mark="[ ] "
            [[ "${selected}" != *" ${values[${index}]} "* ]] || mark="[x] "
        fi
        printf '  %d) %s%s\n' "$((index + 1))" "${mark}" "${labels[${index}]}" >&2
    done
    if [[ -n "${selected}" ]]; then
        printf 'Numbers separated by spaces, all, none, or Enter to keep the [x] marks: ' >&2
    else
        printf 'Numbers separated by spaces, all, or Enter for none: ' >&2
    fi
    IFS= read -r reply || reply=""
    if [[ -z "${reply//[[:space:]]/}" ]]; then
        [[ -n "${selected}" ]] || return 1
        for index in "${!items[@]}"; do
            [[ "${selected}" != *" ${values[${index}]} "* ]] || printf '%s\n' "${values[${index}]}"
        done
        return 0
    fi
    [[ "${reply}" != none ]] || return 0
    if [[ "${reply}" == all ]]; then
        printf '%s\n' "${values[@]}"
        return 0
    fi
    for token in ${reply}; do
        if [[ ! "${token}" =~ ^[1-9][0-9]*$ || "${#token}" -gt 6 ]] || (( token > ${#items[@]} )); then
            log_warn "Invalid selection: ${token}"
            return 1
        fi
    done
    for token in ${reply}; do
        printf '%s\n' "${values[$((token - 1))]}"
    done
}

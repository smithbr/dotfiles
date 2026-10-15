#!/usr/bin/env bash

set -euo pipefail

# Homebrew resolves its trust store from XDG_CONFIG_HOME, falling back to
# ~/.homebrew when unset. The bootstrap runs before link.sh deploys ~/.zshenv,
# which is what normally exports it, so without this default `brew trust` grants
# made during install land somewhere the finished shell never reads. Guarded on
# HOME so callers that deliberately unset it still hit their own error path.
if [[ -z "${XDG_CONFIG_HOME:-}" && -n "${HOME:-}" ]]; then
    export XDG_CONFIG_HOME="${HOME}/.config"
fi

_has_gum=""
_has_gum_checked=0
_check_gum() {
    if [[ "${_has_gum_checked}" -eq 0 ]]; then
        _has_gum_checked=1
        command -v gum >/dev/null 2>&1 && _has_gum=1 || _has_gum=0
    fi
}

log_info() {
    _check_gum
    if [[ "${_has_gum}" -eq 1 ]]; then
        gum log --level info "$*"
    else
        printf "info: %s\n" "$*"
    fi
}

log_warn() {
    _check_gum
    if [[ "${_has_gum}" -eq 1 ]]; then
        gum log --level warn "$*" >&2
    else
        printf "warning: %s\n" "$*" >&2
    fi
}

log_error() {
    _check_gum
    if [[ "${_has_gum}" -eq 1 ]]; then
        gum log --level error "$*" >&2
    else
        printf "error: %s\n" "$*" >&2
    fi
}

# Styled output on a terminal with gum, plain text otherwise. Decided when
# sourced, so a step whose output is captured keeps the style it started with;
# a script that resets PATH calls detect_gum again.
detect_gum() {
    HAS_GUM=false
    command -v gum >/dev/null 2>&1 && [[ -t 1 ]] && HAS_GUM=true
    return 0
}
detect_gum

_header() {
    if [[ "${HAS_GUM}" == true ]]; then
        gum style --bold --foreground 212 "$1"
    else
        printf '%s\n' "$1"
    fi
}

_item() {
    if [[ "${HAS_GUM}" == true ]]; then
        gum style --foreground 244 "  $1"
    else
        printf '  %s\n' "$1"
    fi
}

_check() {
    if [[ "${HAS_GUM}" == true ]]; then
        gum style --foreground 76 "  $(printf '\xe2\x9c\x93') $1"
    else
        printf '  ok: %s\n' "$1"
    fi
}

_cross() {
    if [[ "${HAS_GUM}" == true ]]; then
        gum style --foreground 196 "  $(printf '\xe2\x9c\x97') $1"
    else
        printf '  failed: %s\n' "$1"
    fi
}

_skip() {
    if [[ "${HAS_GUM}" == true ]]; then
        gum style --foreground 244 "  - $1"
    else
        printf '  skipped: %s\n' "$1"
    fi
}

_success() {
    if [[ "${HAS_GUM}" == true ]]; then
        gum style --foreground 76 --bold "$1"
    else
        printf '%s\n' "$1"
    fi
}

_warn() {
    if [[ "${HAS_GUM}" == true ]]; then
        gum style --foreground 214 --bold "$1"
    else
        printf '%s\n' "$1" >&2
    fi
}

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
        printf '%s' "${content}" | gum style --border rounded --border-foreground 240 --margin "0 0" --padding "0 1" ${width_args[@]+"${width_args[@]}"}
    else
        printf '%s\n' "${content}" | sed 's/^/  /'
    fi
}

die() {
    if [[ "${HAS_GUM}" == true ]]; then
        gum log --level error "$1" >&2
    else
        printf '%s\n' "$1" >&2
    fi
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

    # gum spin hides the wrapped command's stdout/stderr, which turns real
    # failures into an opaque "<title> failed" with no detail. VERBOSE=1
    # (see brew.sh -v/--verbose) skips the spinner so output streams through.
    if [[ "${VERBOSE:-0}" -eq 1 ]]; then
        log_info "${title}"
        if ! "$@"; then
            log_error "${title} failed"
            return 1
        fi
        return 0
    fi

    # The spinner only draws on a terminal: captured into a box or piped
    # through install.sh, gum spin leaves cursor escapes in the output, so
    # the title is logged and the command prints as it goes.
    if command -v gum >/dev/null 2>&1 && [[ -t 1 && "$(type -t "$1" 2>/dev/null)" != "function" ]]; then
        if ! gum spin --spinner dot --title "${title}" --padding="0 1" -- "$@"; then
            log_error "${title} failed"
            return 1
        fi
    else
        log_info "${title}"
        "$@"
    fi
}

gum_choose_multiselect() {
    local header="$1"
    local height="$2"
    shift 2

    gum choose \
        --no-limit \
        --ordered \
        --height="${height}" \
        --header="${header}" \
        --cursor=" " \
        --cursor-prefix="> " \
        --selected-prefix="* " \
        --unselected-prefix="  " \
        --no-show-help \
        --padding="0 1" \
        --cursor.foreground="63" \
        --header.foreground="245" \
        --item.foreground="252" \
        --selected.foreground="213" \
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

# One of the ITEMs, by gum or a numbered list on stderr, printed to stdout.
# The answer may be a number or an item; anything else, an empty answer, or
# end of input gives DEFAULT, which may be empty.
#   choose_one HEADER DEFAULT ITEM...
choose_one() {
    local header="$1" default="$2" item reply="" index=1
    shift 2
    local -a items=("$@")

    if [[ "$(prompt_mode)" == gum ]]; then
        reply="$(gum choose --header "${header}" ${default:+--selected "${default}"} "${items[@]}")" || reply=""
    else
        printf '%s\n' "${header}" >&2
        for item in "${items[@]}"; do
            printf '  %d) %s\n' "${index}" "${item}" >&2
            index=$((index + 1))
        done
        printf 'Choice%s: ' "${default:+ [${default}]}" >&2
        IFS= read -r reply || reply=""
    fi
    if [[ "${reply}" =~ ^[0-9]+$ && "${reply}" -ge 1 && "${reply}" -le "${#items[@]}" ]]; then
        reply="${items[$((reply - 1))]}"
    fi
    for item in "${items[@]}"; do
        if [[ "${item}" == "${reply}" ]]; then
            printf '%s\n' "${item}"
            return 0
        fi
    done
    printf '%s\n' "${default}"
}

# Any number of the ITEMs, by gum multi-select or numbers on stdin ("1 3",
# all, or Enter for none), printed one per line. An ITEM may be
# LABEL<tab>VALUE: the label is shown, the value printed. Esc, end of input,
# or an invalid number picks none and returns 1. With --selected, those
# values start selected (ticked in gum, [x] in the list) and Enter keeps
# them; "none" then picks none.
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
        log_info "Use tab or x to select, ctrl+a for all, enter to continue, or esc to skip." >&2
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

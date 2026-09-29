#!/usr/bin/env bash

set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common.sh
source "${BASEDIR}/scripts/common.sh"

# Dotfiles repo whose stow/ and seed/ trees define what is managed.
SOURCE_DIR="${HOME}/.dotfiles"
SHOW_ALL=0
MANAGED_PATHS_CACHE=""
REVIEW_INCOMPLETE=0
DEST_DIR="${HOME}"
CLEANUP=0
SELECT_ONLY=0
CLEANUP_HINT=1
declare -a candidates=()
declare -a candidate_labels=()
declare -a extra_roots=()
# home-audit's verdicts for the top-level home entries: bucket<TAB>path<TAB>size<TAB>note.
HOME_VERDICTS=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [--source PATH] [--destination PATH] [--all] [--cleanup | --select] [--no-cleanup-hint] [audit-root...]

Review existing files on this machine. Nothing changes unless --cleanup or --select is used.
--cleanup offers one selection of paths to archive; it never permanently deletes.
--select offers the same selection without printing the review first.
--no-cleanup-hint leaves out the closing hint about --cleanup.
Skip the selection (Esc, or Enter at the numbered prompt) or close stdin to leave everything in place.
Unmanaged files are review candidates, not proof that a file is abandoned.

By default this script:
- translates managed drift into a short action list
- sorts home dotfiles by home-audit's verdict (junk, leftover, could move,
  review, in use), with the reason and last change for each
- highlights likely leftovers
- lists saved migration backups and broken managed symlinks
- hides obvious local/runtime state unless --all is passed
- checks unmanaged dotfiles directly in ${HOME} without walking the whole home
- skips recursive scans of broad roots like ${HOME}/.config and ${HOME}/.local

Pass one or more audit roots to widen the scan. For example:
  $(basename "$0") "${HOME}"
  $(basename "$0") --all
  $(basename "$0") --source "${HOME}/src/dotfiles" "${HOME}/.config"
EOF
}

display_path() {
    local path="$1"

    if [[ "${path}" == "${HOME}" ]]; then
        printf '~\n'
    elif [[ "${path}" == "${HOME}/"* ]]; then
        # shellcheck disable=SC2088
        printf '~/%s\n' "${path#"${HOME}"/}"
    else
        printf '%s\n' "${path}"
    fi
}

is_excluded_root() {
    local path="$1"

    case "${path}" in
        "${DEST_DIR}" | "${DEST_DIR}/.config" | "${DEST_DIR}/.local" | "${DEST_DIR}/Library" | "${DEST_DIR}/Library/Application Support")
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cleanup)
                CLEANUP=1
                shift
                ;;
            --select)
                CLEANUP=1
                SELECT_ONLY=1
                shift
                ;;
            --no-cleanup-hint)
                CLEANUP_HINT=0
                shift
                ;;
            --all)
                SHOW_ALL=1
                shift
                ;;
            --source)
                if [[ $# -lt 2 ]]; then
                    log_error "--source requires a path"
                    exit 1
                fi
                SOURCE_DIR="$2"
                shift 2
                ;;
            --destination)
                if [[ $# -lt 2 ]]; then
                    log_error "--destination requires a path"
                    exit 1
                fi
                DEST_DIR="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                while [[ $# -gt 0 ]]; do
                    extra_roots+=("$1")
                    shift
                done
                ;;
            -*)
                log_error "Unknown option: $1"
                exit 1
                ;;
            *)
                extra_roots+=("$1")
                shift
                ;;
        esac
    done
}

link_script() {
    bash "${BASEDIR}/scripts/link.sh" --repo "${SOURCE_DIR}" --destination "${DEST_DIR}" "$@"
}

collect_managed_paths() {
    link_script managed
}

# Unmanaged files and symlinks under a root. Descends only into directories
# that hold managed paths; wholly unmanaged directories are not listed.
list_unmanaged() {
    local dir="$1" entry=""

    for entry in "${dir}"/.[!.]* "${dir}"/..?* "${dir}"/*; do
        [[ -e "${entry}" || -L "${entry}" ]] || continue
        if grep -Fqx -- "${entry}" <<< "${MANAGED_PATHS_CACHE}"; then
            continue
        fi
        if [[ -d "${entry}" && ! -L "${entry}" ]]; then
            if grep -Fq -- "${entry}/" <<< "${MANAGED_PATHS_CACHE}"; then
                list_unmanaged "${entry}" || return 1
            fi
            continue
        fi
        printf '%s\n' "${entry}"
    done
}

prime_managed_paths_cache() {
    if [[ -n "${MANAGED_PATHS_CACHE}" ]]; then
        return
    fi

    if ! MANAGED_PATHS_CACHE="$(collect_managed_paths)"; then
        log_error "Could not list managed paths; file review is incomplete"
        return 1
    fi
}

is_expected_local_override() {
    local path="$1"
    local example_path=""

    if [[ "${path}" != *.local ]]; then
        return 1
    fi

    example_path="${path}.example"
    prime_managed_paths_cache

    grep -Fqx -- "${example_path}" <<< "${MANAGED_PATHS_CACHE}"
}

collect_audit_roots() {
    local managed_path=""
    local parent_dir=""

    while IFS= read -r managed_path; do
        [[ -n "${managed_path}" ]] || continue
        parent_dir="$(dirname "${managed_path}")"
        if is_excluded_root "${parent_dir}" || is_protected "${parent_dir}"; then
            continue
        fi
        printf '%s\n' "${parent_dir}"
    done <<< "${MANAGED_PATHS_CACHE}"

    if [[ "${#extra_roots[@]}" -gt 0 ]]; then
        printf '%s\n' "${extra_roots[@]}"
    fi
}

print_unique_roots() {
    local candidate=""
    local last_kept=""

    while IFS= read -r candidate; do
        [[ -n "${candidate}" ]] || continue
        if [[ -n "${last_kept}" && ( "${candidate}" == "${last_kept}" || "${candidate}" == "${last_kept}/"* ) ]]; then
            continue
        fi
        printf '%s\n' "${candidate}"
        last_kept="${candidate}"
    done < <(collect_audit_roots | sort -u)
}

print_status_section() {
    local status_output=""
    local line=""
    local state=""
    local path=""
    local printed_header=0

    if ! status_output="$(link_script status)"; then
        log_warn "Could not check managed drift; file review is incomplete"
        REVIEW_INCOMPLETE=1
        return
    fi

    while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        state="${line%% *}"
        path="${line#* }"
        # Broken links get their own section below.
        [[ "${state}" != broken ]] || continue
        if [[ "${printed_header}" -eq 0 ]]; then
            printf 'Managed drift:\n'
            printed_header=1
        fi
        case "${state}" in
            missing)
                printf '  %s\n' "$(display_path "${path}")"
                printf '    status: not linked yet\n'
                printf '    action: run ~/.dotfiles/scripts/link.sh, or remove the repo file if it is obsolete\n'
                ;;
            replaced)
                printf '  %s\n' "$(display_path "${path}")"
                printf '    status: a real file sits where a link belongs; an app or editor may have replaced the link\n'
                printf '    action: diff the local file against the repo, keep any wanted change in the repo, then run link.sh (it backs up the file first)\n'
                ;;
            foreign)
                printf '  %s\n' "$(display_path "${path}")"
                printf '    status: symlink points somewhere other than the repo\n'
                printf '    action: check what it points to, then run link.sh to relink it\n'
                ;;
            stale)
                printf '  %s\n' "$(display_path "${path}")"
                printf '    status: link into the repo for a file that moved, was removed, or no longer applies here\n'
                printf '    action: run ~/.dotfiles/scripts/link.sh to remove it\n'
                ;;
            drifted)
                printf '  %s\n' "$(display_path "${path}")"
                printf '    status: a managed setting was changed or removed here\n'
                printf '    action: keep any wanted change in the agents repo'\''s tools/claude settings, then run link.sh (it backs up the file first)\n'
                ;;
            unused)
                printf '  %s\n' "$(display_path "${path}")"
                printf '    status: private agents checkout on a persona without agents\n'
                printf '    action: delete it if this machine should not keep it; link.sh never does\n'
                ;;
            *)
                printf '  %s\n' "${line}"
                ;;
        esac
    done <<< "${status_output}"

    if [[ "${printed_header}" -eq 0 ]]; then
        printf 'Managed drift: none\n'
    fi
}

is_hidden_local_state() {
    local path="$1"

    case "${path}" in
        "${DEST_DIR}/.claude/"* | "${DEST_DIR}/.codex/"* | "${DEST_DIR}/.ssh/"* )
            return 0
            ;;
        "${DEST_DIR}/Library/Application Support/Code/"* | "${DEST_DIR}/Library/Application Support/Cursor/"* )
            return 0
            ;;
        "${DEST_DIR}/.config/1Password/ssh/agent.toml" | "${DEST_DIR}/.config/gh/config.yml" | "${DEST_DIR}/.config/git/config.local" | "${DEST_DIR}/.config/zsh/.zsh_history" | "${DEST_DIR}/.config/zsh/plugins.zsh" | "${DEST_DIR}/.local/bin/python"* )
            return 0
            ;;
        *"/.DS_Store" | *"/.ignore.swp" | *"/Cookies" | *"/Cookies-journal" | *"/DIPS" | *"/DIPS-wal" | *"/Network Persistent State" | *"/SharedStorage" | *"/SharedStorage-wal" | *"/TransportSecurity" | *"/Trust Tokens" | *"/Trust Tokens-journal" | *"/code.lock" | *"/languagepacks.json" | *"/machineid" | *"/known_hosts" | *"/known_hosts.old" | *"/history.jsonl" | *"/mcp-needs-auth-cache.json" | *"/models_cache.json" | *"/policy-limits.json" | *"/readout-cost-cache.json" | *"/readout-pricing.json" | *"/session_index.jsonl" | *"/stats-cache.json" | *"/auth.json" | *"/.codex-global-state.json" | *"/.personality_migration" | *"/logs_"*.sqlite | *"/logs_"*.sqlite-shm | *"/logs_"*.sqlite-wal | *"/state_"*.sqlite | *"/state_"*.sqlite-shm | *"/state_"*.sqlite-wal )
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

leftover_action() {
    local path="$1"

    case "${path}" in
        "${DEST_DIR}/.local/bin/"*)
            printf 'check its owner and usage; keep local tools, or archive it if confirmed obsolete\n'
            ;;
        "${DEST_DIR}/.config/agents/"*)
            printf 'review in the private agents repo; do not copy private agent configuration into public dotfiles\n'
            ;;
        *)
            printf 'review its owner and usage; keep it local, manage it in the appropriate repo, or archive it if obsolete\n'
            ;;
    esac
}

print_candidate_section() {
    local root=""
    local unmanaged_output=""
    local path=""
    local display_root=""
    local visible_for_root=""
    local hidden_for_root=""
    local hidden_count=0
    local printed_candidates=0
    local printed_hidden=0
    local -a hidden_summaries=()

    while IFS= read -r root; do
        [[ -n "${root}" ]] || continue

        if [[ ! -e "${root}" ]]; then
            continue
        fi

        if ! unmanaged_output="$(list_unmanaged "${root}")"; then
            log_warn "Could not inspect ${root}; file review is incomplete"
            REVIEW_INCOMPLETE=1
            continue
        fi

        if [[ -z "${unmanaged_output}" ]]; then
            continue
        fi

        display_root="$(display_path "${root}")"
        visible_for_root=""
        hidden_for_root=""
        hidden_count=0

        while IFS= read -r path; do
            [[ -n "${path}" ]] || continue
            if is_expected_local_override "${path}" || is_protected "${path}"; then
                continue
            fi
            if is_hidden_local_state "${path}"; then
                hidden_count=$((hidden_count + 1))
                if [[ "${SHOW_ALL}" -eq 1 ]]; then
                    hidden_for_root="${hidden_for_root}  $(display_path "${path}")"$'\n'
                    hidden_for_root="${hidden_for_root}    action: ignore unless you intentionally want to start managing this local/runtime file"$'\n'
                fi
                continue
            fi
            add_candidate "${path}" "beside managed files"
            visible_for_root="${visible_for_root}  $(display_path "${path}")"$'\n'
            visible_for_root="${visible_for_root}    action: $(leftover_action "${path}")"$'\n'
        done <<< "${unmanaged_output}"

        if [[ -n "${visible_for_root}" ]]; then
            if [[ "${printed_candidates}" -eq 0 ]]; then
                printf '\nPotential leftovers:\n'
                printed_candidates=1
            fi
            printf '%s\n' "${display_root}"
            printf '%s' "${visible_for_root}"
        fi

        if [[ "${hidden_count}" -gt 0 ]]; then
            hidden_summaries+=("${display_root} (${hidden_count} hidden local/runtime files)")
            if [[ "${SHOW_ALL}" -eq 1 && -n "${hidden_for_root}" ]]; then
                if [[ "${printed_hidden}" -eq 0 ]]; then
                    printf '\nLocal/runtime files:\n'
                    printed_hidden=1
                fi
                printf '%s\n' "${display_root}"
                printf '%s' "${hidden_for_root}"
            fi
        fi
    done < <(print_unique_roots)

    if [[ "${printed_candidates}" -eq 0 && "${REVIEW_INCOMPLETE}" -eq 0 ]]; then
        printf '\nPotential leftovers: none\n'
    fi

    if [[ "${#hidden_summaries[@]}" -gt 0 ]]; then
        printf '\nHidden local/runtime files by default:\n'
        printf '  %s\n' "${hidden_summaries[@]}"
        printf '  action: usually ignore these unless you now want to start managing them\n'
        if [[ "${SHOW_ALL}" -eq 0 ]]; then
            printf '  run %s --all to show them\n' "$(basename "$0")"
        fi
    fi
}

is_protected() {
    local path="$1"

    [[ "${SOURCE_DIR}" == "${path}/"* || "${BASEDIR}" == "${path}/"* ]] && return 0
    case "${path}" in
        "${DEST_DIR}" | "${DEST_DIR}/.config" | "${DEST_DIR}/.local" | "${DEST_DIR}/.git" | "${DEST_DIR}/.git/"* | "${DEST_DIR}/.dotfiles" | "${DEST_DIR}/.dotfiles/"* | "${DEST_DIR}/.cache" | "${DEST_DIR}/.cache/"* | "${DEST_DIR}/.Trash" | "${DEST_DIR}/.Trash/"*) return 0 ;;
        "${DEST_DIR}/.ssh" | "${DEST_DIR}/.ssh/"* | "${DEST_DIR}/.gnupg" | "${DEST_DIR}/.gnupg/"* | "${DEST_DIR}/.aws" | "${DEST_DIR}/.aws/"* | "${DEST_DIR}/.1password" | "${DEST_DIR}/.1password/"*) return 0 ;;
        "${DEST_DIR}/.netrc" | "${DEST_DIR}/.npmrc" | "${DEST_DIR}/.pypirc" | "${DEST_DIR}/.kube" | "${DEST_DIR}/.kube/"* | "${DEST_DIR}/.docker" | "${DEST_DIR}/.docker/"*) return 0 ;;
        "${DEST_DIR}/.agents" | "${DEST_DIR}/.agents/"* | "${DEST_DIR}/.claude" | "${DEST_DIR}/.claude/"* | "${DEST_DIR}/.codex" | "${DEST_DIR}/.codex/"* | "${DEST_DIR}/.cursor" | "${DEST_DIR}/.cursor/"* | "${DEST_DIR}/.claude.json" | "${DEST_DIR}/.config/agents" | "${DEST_DIR}/.config/agents/"*) return 0 ;;
        "${DEST_DIR}/.local/state/dotfiles" | "${DEST_DIR}/.local/state/dotfiles/"* | "${DEST_DIR}/.config/agents-backup."*) return 0 ;;
        "${SOURCE_DIR}" | "${SOURCE_DIR}/"* | "${BASEDIR}" | "${BASEDIR}/"*) return 0 ;;
    esac
    return 1
}

contains_managed_path() {
    local path="$1"
    local managed=""

    while IFS= read -r managed; do
        [[ -n "${managed}" ]] || continue
        if [[ "${managed}" == "${path}" || "${managed}" == "${path}/"* || ( "${path}" == "${managed}/"* && -L "${managed}" ) ]]; then
            return 0
        fi
    done <<< "${MANAGED_PATHS_CACHE}"
    return 1
}

add_candidate() {
    local path="$1"
    local label="${2:-}"
    local existing=""
    local parent="${path%/*}"

    [[ -e "${path}" || -L "${path}" ]] || return 0
    [[ "${path}" == "${DEST_DIR}/"* && "${path}" != *$'\n'* && "${path}" != *$'\t'* ]] || return 0
    is_protected "${path}" && return 0
    contains_managed_path "${path}" && return 0
    # Never move a file through a symlinked parent into someone else's tree.
    while [[ "${parent}" != "${DEST_DIR}" && "${parent}" != / ]]; do
        [[ -L "${parent}" ]] && return 0
        parent="${parent%/*}"
    done
    if [[ "${#candidates[@]}" -gt 0 ]]; then
        for existing in "${candidates[@]}"; do
            [[ "${path}" == "${existing}" || "${path}" == "${existing}/"* ]] && return 0
        done
    fi
    candidates+=("${path}")
    candidate_labels+=("${label}")
}

# The picker's line for a candidate: its path and, when known, why.
candidate_label() {
    local index="$1" label="${candidate_labels[$1]:-}"
    if [[ -n "${label}" ]]; then
        printf '%s  (%s)\n' "$(display_path "${candidates[index]}")" "${label}"
    else
        display_path "${candidates[index]}"
    fi
}

# Ask home-audit (read-only) for a verdict on each top-level home entry. It is
# repo tooling here, so it runs from the repo whatever layers this persona
# links. Without it, entries are listed unsorted.
load_home_verdicts() {
    local audit="${BASEDIR}/stow/tools/.local/bin/home-audit"
    HOME_VERDICTS=""
    [[ -f "${audit}" ]] || return 0
    if ! HOME_VERDICTS="$(DOTFILES_DIR="${SOURCE_DIR}" bash "${audit}" --home "${DEST_DIR}" --tsv 2>/dev/null)"; then
        HOME_VERDICTS=""
        log_warn "home-audit failed; home dotfiles are listed without verdicts"
    fi
}

# bucket, size and note for one path, or review with no detail. Fields are
# split on the unit separator: read merges runs of tabs, which would lose an
# empty size.
home_verdict() {
    local row
    row="$(awk -F '\t' -v p="$1" '$2 == p { print $1 "\037" $3 "\037" $4; exit }' <<< "${HOME_VERDICTS}")"
    printf '%s\n' "${row:-review$'\037'$'\037'no verdict available}"
}

# Unmanaged top-level dotfiles, grouped by verdict, most likely abandoned
# first. The picker offers them in the same order.
print_home_candidates() {
    local path="" bucket="" size="" note="" group="" heading="" found=0 i=0
    local -a entries=() buckets=() sizes=() notes=()

    for path in "${DEST_DIR}"/.[!.]* "${DEST_DIR}"/..?*; do
        [[ -e "${path}" || -L "${path}" ]] || continue
        is_protected "${path}" && continue
        contains_managed_path "${path}" && continue
        is_hidden_local_state "${path}" && continue
        IFS=$'\037' read -r bucket size note <<< "$(home_verdict "${path}")"
        entries+=("${path}")
        buckets+=("${bucket}")
        sizes+=("${size}")
        notes+=("${note}")
    done

    printf '\nHome dotfiles the repo does not manage, most likely abandoned first:\n'
    for group in junk leftover move review keep; do
        heading=""
        for ((i = 0; i < ${#entries[@]}; i++)); do
            [[ "${buckets[i]}" == "${group}" ]] || continue
            path="${entries[i]}" size="${sizes[i]}" note="${notes[i]}"
            if [[ -z "${heading}" ]]; then
                case "${group}" in
                    junk) heading="Junk: OS litter and backup copies" ;;
                    leftover) heading="Leftover: nothing installed uses it, or its tool now looks elsewhere" ;;
                    move) heading="Could move: the tool supports XDG paths (home-audit shows how)" ;;
                    review) heading="Review: owner not found; judge by the last change" ;;
                    keep) heading="In use: an installed tool still writes here" ;;
                esac
                printf '  %s\n' "${heading}"
            fi
            # A move hint is a list of exports; name the tool and leave the detail to home-audit.
            [[ "${group}" != move ]] || note="${note%%:*} supports XDG"
            printf '    %-26s %6s  %s\n' "$(display_path "${path}")" "${size}" "${note}"
            add_candidate "${path}" "${group}: ${note}"
            found=1
        done
    done
    [[ "${found}" -ne 0 ]] || printf '  none\n'
}

# gum draws on stderr and reads keys from stdin, so both must be a terminal.
# FILE_REVIEW_PROMPT (gum or read) lets tests pick a mode without a terminal.
cleanup_prompt_mode() {
    if [[ -n "${FILE_REVIEW_PROMPT:-}" ]]; then
        printf '%s\n' "${FILE_REVIEW_PROMPT}"
    elif command -v gum >/dev/null 2>&1 && [[ -t 0 && -t 2 ]]; then
        printf 'gum\n'
    else
        printf 'read\n'
    fi
}

# Both choosers fill the caller's selected array, or return 1 to move nothing.
choose_with_gum() {
    local choice="" path="" tmp_output="" known=0
    local height="${#candidates[@]}"
    local -a options=() picked=()

    [[ "${height}" -le 15 ]] || height=15
    [[ "${height}" -ge 3 ]] || height=3
    local index=0
    for path in "${candidates[@]}"; do
        options+=("$(candidate_label "${index}")"$'\t'"${path}")
        index=$((index + 1))
    done

    log_info "Archive candidates: unmanaged does not necessarily mean unused. Use tab or x to select, ctrl+a for all, enter to continue, or esc to skip."
    tmp_output="$(mktemp "${TMPDIR:-/tmp}/file-review.XXXXXX")"
    if ! gum_choose_multiselect "Select paths to archive" "${height}" \
        --label-delimiter=$'\t' "${options[@]}" > "${tmp_output}"; then
        rm -f "${tmp_output}"
        printf 'Cleanup skipped; no files moved.\n'
        return 1
    fi
    while IFS= read -r choice || [[ -n "${choice}" ]]; do
        [[ -z "${choice}" ]] || picked+=("${choice}")
    done < "${tmp_output}"
    rm -f "${tmp_output}"

    # Only paths that were offered may move.
    if [[ "${#picked[@]}" -gt 0 ]]; then
        for choice in "${picked[@]}"; do
            known=0
            for path in "${candidates[@]}"; do
                if [[ "${path}" == "${choice}" ]]; then
                    selected+=("${path}")
                    known=1
                    break
                fi
            done
            if [[ "${known}" -eq 0 ]]; then
                log_warn "Invalid selection; no files moved"
                return 1
            fi
        done
    fi

    if [[ "${#selected[@]}" -eq 0 ]]; then
        printf 'Cleanup skipped; no files moved.\n'
        return 1
    fi
    printf 'Selected for archiving:\n'
    for path in "${selected[@]}"; do
        printf '  %s\n' "$(display_path "${path}")"
    done
    if ! gum confirm --default=false "Archive ${#selected[@]} path(s)?"; then
        printf 'Cleanup skipped; no files moved.\n'
        return 1
    fi
}

choose_with_read() {
    local answer="" token="" index=0 path=""
    local -a choices=()

    printf '\nArchive candidates, most likely abandoned first. Unmanaged does not necessarily mean unused:\n'
    for path in "${candidates[@]}"; do
        printf '  %d) %s\n' "$((index + 1))" "$(candidate_label "${index}")"
        index=$((index + 1))
    done
    printf 'Archive which paths? Enter numbers separated by spaces, all, or Enter to skip: '
    if ! IFS= read -r answer || [[ -z "${answer//[[:space:]]/}" ]]; then
        printf '\nCleanup skipped; no files moved.\n'
        return 1
    fi
    if [[ "${answer}" == all ]]; then
        selected=("${candidates[@]}")
        return 0
    fi
    read -r -a choices <<< "${answer}"
    for token in "${choices[@]}"; do
        if [[ ! "${token}" =~ ^[1-9][0-9]*$ || "${#token}" -gt 6 ]] || (( token > ${#candidates[@]} )); then
            log_warn "Invalid selection; no files moved"
            return 1
        fi
        selected+=("${candidates[token-1]}")
    done
}

archive_selection() {
    local path="" archive="" relative=""
    local -a selected=()

    if [[ "${REVIEW_INCOMPLETE}" -ne 0 ]]; then
        log_warn "Cleanup unavailable because the review is incomplete"
        return
    fi
    [[ "${#candidates[@]}" -gt 0 ]] || return 0
    case "$(cleanup_prompt_mode)" in
        gum) choose_with_gum || return 0 ;;
        *) choose_with_read || return 0 ;;
    esac
    MANAGED_PATHS_CACHE=""
    prime_managed_paths_cache || return 1
    for path in "${selected[@]}"; do
        if contains_managed_path "${path}"; then
            log_error "Managed paths changed during review; no files moved"
            return 1
        fi
    done
    for path in "${DEST_DIR}/.local" "${DEST_DIR}/.local/state" "${DEST_DIR}/.local/state/dotfiles" "${DEST_DIR}/.local/state/dotfiles/cleanup"; do
        if [[ -L "${path}" ]]; then
            log_error "Archive parent is a symlink: ${path}; no files moved"
            return 1
        fi
    done
    umask 077
    mkdir -p "${DEST_DIR}/.local/state/dotfiles/cleanup"
    archive="$(mktemp -d "${DEST_DIR}/.local/state/dotfiles/cleanup/$(date +%Y%m%d-%H%M%S).XXXXXX")"
    printf '\nArchive: %s\n' "${archive}"
    for path in "${selected[@]}"; do
        [[ -e "${path}" || -L "${path}" ]] || continue
        relative="${path#"${DEST_DIR}"/}"
        mkdir -p "${archive}/$(dirname "${relative}")"
        mv "${path}" "${archive}/${relative}"
        printf '  archived %s\n' "$(display_path "${path}")"
    done
    printf 'Original relative paths are preserved. To restore a file, move it from the archive back under %s; check for conflicts first.\n' "${DEST_DIR}"
}

print_installation_state() {
    local path=""
    local found=0

    printf '\nBroken managed symlinks:\n'
    while IFS= read -r path; do
        if [[ -L "${path}" && ! -e "${path}" ]]; then
            printf '  %s -> %s\n' "$(display_path "${path}")" "$(readlink "${path}")"
            found=1
        fi
    done <<< "${MANAGED_PATHS_CACHE}"
    if [[ "${found}" -eq 0 ]]; then
        printf '  none\n'
    else
        printf '  action: restore the missing target or correct the repo link, then run link.sh\n'
    fi

    printf '\nSaved migration backups:\n'
    found=0
    for path in "${DEST_DIR}/.local/state/dotfiles/clobbered/"* "${DEST_DIR}/.local/state/dotfiles/cleanup/"* "${DEST_DIR}/.config/agents-backup."*; do
        [[ -e "${path}" || -L "${path}" ]] || continue
        printf '  %s\n' "$(display_path "${path}")"
        found=1
    done
    if [[ "${found}" -eq 0 ]]; then
        printf '  none\n'
    else
        printf '  action: compare with the current configuration and recover needed data before removing any backup\n'
    fi

    if [[ -d "${DEST_DIR}/.config/agents" && ! -e "${DEST_DIR}/.config/agents/.git" ]]; then
        printf '\nAgents checkout needs attention: %s\n' "$(display_path "${DEST_DIR}/.config/agents")"
        printf '  action: preserve this directory before replacing it with the configured private Git checkout\n'
    fi
}

print_report() {
    printf 'File review for %s\n' "${DEST_DIR}"
    print_status_section
    print_home_candidates
    print_installation_state
    print_candidate_section

    printf '\nRecursive scans skipped by default: %s, %s, %s\n' \
        "$(display_path "${DEST_DIR}")" \
        "$(display_path "${DEST_DIR}/.config")" \
        "$(display_path "${DEST_DIR}/.local")"
}

main() {
    parse_args "$@"

    if [[ ! -d "${SOURCE_DIR}" ]]; then
        log_error "dotfiles repo not found: ${SOURCE_DIR}"
        exit 1
    fi

    DEST_DIR="$(cd "${DEST_DIR}" && pwd -L)" || return 1
    SOURCE_DIR="$(cd "${SOURCE_DIR}" && pwd -L)" || return 1
    prime_managed_paths_cache || return 1
    load_home_verdicts
    if [[ "${SELECT_ONLY}" -eq 1 ]]; then
        # Candidates are gathered while printing; the caller already showed them.
        print_report > /dev/null 2>&1
    else
        print_report
    fi
    if [[ "${CLEANUP}" -eq 1 ]]; then
        archive_selection
    elif [[ "${CLEANUP_HINT}" -eq 1 ]]; then
        printf 'Bulk cleanup: run %s --cleanup to select paths to archive.\n' "${BASEDIR}/scripts/file-review.sh"
    fi
    return "${REVIEW_INCOMPLETE}"
}

main "$@"

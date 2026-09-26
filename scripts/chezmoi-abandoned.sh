#!/usr/bin/env bash

set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common.sh
source "${BASEDIR}/scripts/common.sh"

# Repo root; .chezmoiroot redirects chezmoi to the dotfiles/ subdir.
CHEZMOI_SOURCE="${HOME}/.dotfiles"
SHOW_ALL=0
MANAGED_PATHS_CACHE=""
REVIEW_INCOMPLETE=0
DEST_DIR="${HOME}"
CLEANUP=0
declare -a candidates=()
declare -a extra_roots=()

usage() {
    cat <<EOF
Usage: $(basename "$0") [--source PATH] [--destination PATH] [--all] [--cleanup] [audit-root...]

Review existing files on this machine. Nothing changes unless --cleanup is used.
--cleanup offers one selection of paths to archive; it never permanently deletes.
Press Enter or close stdin to leave everything in place.
Unmanaged files are review candidates, not proof that a file is abandoned.

By default this script:
- translates managed drift into a short action list
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

require_command() {
    local command_name="$1"

    if ! command -v "${command_name}" >/dev/null 2>&1; then
        log_error "Missing dependency: ${command_name}"
        exit 1
    fi
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
            --all)
                SHOW_ALL=1
                shift
                ;;
            --source)
                if [[ $# -lt 2 ]]; then
                    log_error "--source requires a path"
                    exit 1
                fi
                CHEZMOI_SOURCE="$2"
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

collect_managed_paths() {
    chezmoi --source "${CHEZMOI_SOURCE}" --destination "${DEST_DIR}" managed --include=files,dirs,symlinks --path-style=absolute
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
    local action=""
    local path=""
    local printed_header=0

    if ! status_output="$(chezmoi --source "${CHEZMOI_SOURCE}" --destination "${DEST_DIR}" status --exclude=scripts --path-style=absolute)"; then
        log_warn "Could not check managed drift; file review is incomplete"
        REVIEW_INCOMPLETE=1
        return
    fi

    while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        action="${line:1:1}"
        path="${line:3}"
        if [[ "${printed_header}" -eq 0 ]]; then
            printf 'Managed drift:\n'
            printed_header=1
        fi
        case "${action}" in
            A)
                printf '  %s\n' "$(display_path "${path}")"
                printf '    status: missing target, chezmoi would create it\n'
                printf '    action: run chezmoi apply if you still want it, or remove the source entry if it is obsolete\n'
                ;;
            D)
                printf '  %s\n' "$(display_path "${path}")"
                printf '    status: extra target, chezmoi would delete it\n'
                printf '    action: run chezmoi apply if the source of truth is the repo, or re-add it to source if deletion is wrong\n'
                ;;
            M)
                printf '  %s\n' "$(display_path "${path}")"
                printf '    status: target differs from source, chezmoi would update it\n'
                printf '    action: diff the local file against the repo, then either keep the change in source or re-apply chezmoi\n'
                ;;
            R)
                printf '  %s\n' "$(display_path "${path}")"
                printf '    status: script would run\n'
                printf '    action: review the script change and re-run chezmoi if expected\n'
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

        if ! unmanaged_output="$(chezmoi --source "${CHEZMOI_SOURCE}" --destination "${DEST_DIR}" unmanaged --include=files,symlinks --path-style=absolute -- "${root}")"; then
            log_warn "Could not inspect ${root}; file review is incomplete"
            REVIEW_INCOMPLETE=1
            continue
        fi
        unmanaged_output="$(printf '%s\n' "${unmanaged_output}" | grep -Ev '/\.config/chezmoi/chezmoistate\.boltdb$' || true)"

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
            add_candidate "${path}"
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

    [[ "${CHEZMOI_SOURCE}" == "${path}/"* || "${BASEDIR}" == "${path}/"* ]] && return 0
    case "${path}" in
        "${DEST_DIR}" | "${DEST_DIR}/.config" | "${DEST_DIR}/.local" | "${DEST_DIR}/.git" | "${DEST_DIR}/.git/"* | "${DEST_DIR}/.dotfiles" | "${DEST_DIR}/.dotfiles/"* | "${DEST_DIR}/.cache" | "${DEST_DIR}/.cache/"* | "${DEST_DIR}/.Trash" | "${DEST_DIR}/.Trash/"*) return 0 ;;
        "${DEST_DIR}/.ssh" | "${DEST_DIR}/.ssh/"* | "${DEST_DIR}/.gnupg" | "${DEST_DIR}/.gnupg/"* | "${DEST_DIR}/.aws" | "${DEST_DIR}/.aws/"* | "${DEST_DIR}/.1password" | "${DEST_DIR}/.1password/"*) return 0 ;;
        "${DEST_DIR}/.netrc" | "${DEST_DIR}/.npmrc" | "${DEST_DIR}/.pypirc" | "${DEST_DIR}/.kube" | "${DEST_DIR}/.kube/"* | "${DEST_DIR}/.docker" | "${DEST_DIR}/.docker/"*) return 0 ;;
        "${DEST_DIR}/.agents" | "${DEST_DIR}/.agents/"* | "${DEST_DIR}/.claude" | "${DEST_DIR}/.claude/"* | "${DEST_DIR}/.codex" | "${DEST_DIR}/.codex/"* | "${DEST_DIR}/.cursor" | "${DEST_DIR}/.cursor/"* | "${DEST_DIR}/.claude.json" | "${DEST_DIR}/.config/agents" | "${DEST_DIR}/.config/agents/"*) return 0 ;;
        "${DEST_DIR}/.local/state/dotfiles" | "${DEST_DIR}/.local/state/dotfiles/"* | "${DEST_DIR}/.config/agents-backup."*) return 0 ;;
        "${CHEZMOI_SOURCE}" | "${CHEZMOI_SOURCE}/"* | "${BASEDIR}" | "${BASEDIR}/"*) return 0 ;;
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
}

print_home_candidates() {
    local path=""
    local found=0

    printf '\nUnmanaged home dotfiles (review before archiving):\n'
    for path in "${DEST_DIR}"/.[!.]* "${DEST_DIR}"/..?*; do
        [[ -e "${path}" || -L "${path}" ]] || continue
        is_protected "${path}" && continue
        contains_managed_path "${path}" && continue
        is_hidden_local_state "${path}" && continue
        printf '  %s\n' "$(display_path "${path}")"
        add_candidate "${path}"
        found=1
    done
    [[ "${found}" -ne 0 ]] || printf '  none\n'
}

archive_selection() {
    local answer="" token="" index=0 path="" archive="" relative=""
    local -a selected=()

    if [[ "${REVIEW_INCOMPLETE}" -ne 0 ]]; then
        log_warn "Cleanup unavailable because the review is incomplete"
        return
    fi
    [[ "${#candidates[@]}" -gt 0 ]] || return 0
    printf '\nArchive candidates — unmanaged does not necessarily mean unused:\n'
    for path in "${candidates[@]}"; do
        index=$((index + 1))
        printf '  %d) %s\n' "${index}" "$(display_path "${path}")"
    done
    printf 'Archive which paths? Enter numbers separated by spaces, all, or Enter to skip: '
    if ! IFS= read -r answer || [[ -z "${answer//[[:space:]]/}" ]]; then
        printf '\nCleanup skipped; no files moved.\n'
        return
    fi
    if [[ "${answer}" == all ]]; then
        selected=("${candidates[@]}")
    else
        local -a choices=()
        read -r -a choices <<< "${answer}"
        for token in "${choices[@]}"; do
            if [[ ! "${token}" =~ ^[1-9][0-9]*$ || "${#token}" -gt 6 ]] || (( token > ${#candidates[@]} )); then
                log_warn "Invalid selection; no files moved"
                return
            fi
            selected+=("${candidates[token-1]}")
        done
    fi
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
        printf '  action: restore the missing target or correct the source link, then apply\n'
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

main() {
    parse_args "$@"

    require_command chezmoi

    if [[ ! -d "${CHEZMOI_SOURCE}" ]]; then
        log_error "chezmoi source directory not found: ${CHEZMOI_SOURCE}"
        exit 1
    fi

    DEST_DIR="$(cd "${DEST_DIR}" && pwd -L)" || return 1
    CHEZMOI_SOURCE="$(cd "${CHEZMOI_SOURCE}" && pwd -L)" || return 1
    prime_managed_paths_cache || return 1
    printf 'File review for %s\n' "${DEST_DIR}"
    print_status_section
    print_home_candidates
    print_installation_state
    print_candidate_section

    printf '\nRecursive scans skipped by default: %s, %s, %s\n' \
        "$(display_path "${DEST_DIR}")" \
        "$(display_path "${DEST_DIR}/.config")" \
        "$(display_path "${DEST_DIR}/.local")"
    if [[ "${CLEANUP}" -eq 1 ]]; then
        archive_selection
    else
        printf 'Bulk cleanup: run %s --cleanup to select paths to archive.\n' "${BASEDIR}/scripts/chezmoi-abandoned.sh"
    fi
    return "${REVIEW_INCOMPLETE}"
}

main "$@"

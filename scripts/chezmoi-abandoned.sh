#!/usr/bin/env bash

set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common.sh
source "${BASEDIR}/scripts/common.sh"

CHEZMOI_SOURCE="${HOME}/.dotfiles/dotfiles"
SHOW_ALL=0
MANAGED_PATHS_CACHE=""
declare -a extra_roots=()

usage() {
    cat <<EOF
Usage: $(basename "$0") [--source PATH] [audit-root...]

Highlight unmanaged files near chezmoi-managed paths after a symlink migration.

By default this script:
- translates managed drift into a short action list
- highlights likely leftovers
- hides obvious local/runtime state unless --all is passed
- skips broad roots like ${HOME}, ${HOME}/.config, and ${HOME}/.local

Pass one or more audit roots to widen the scan. For example:
  $(basename "$0") "${HOME}"
  $(basename "$0") --all
  $(basename "$0") --source "${HOME}/src/dotfiles/dotfiles" "${HOME}/.config"
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
        "${HOME}" | "${HOME}/.config" | "${HOME}/.local" | "${HOME}/Library" | "${HOME}/Library/Application Support")
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
    chezmoi --source "${CHEZMOI_SOURCE}" managed --include=files,dirs,symlinks --path-style=absolute
}

prime_managed_paths_cache() {
    if [[ -n "${MANAGED_PATHS_CACHE}" ]]; then
        return
    fi

    MANAGED_PATHS_CACHE="$(collect_managed_paths)"
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
        if is_excluded_root "${parent_dir}"; then
            continue
        fi
        printf '%s\n' "${parent_dir}"
    done < <(collect_managed_paths)

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

    status_output="$(chezmoi --source "${CHEZMOI_SOURCE}" status --path-style=absolute || true)"

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
        "${HOME}/.claude/"* | "${HOME}/.codex/"* | "${HOME}/.ssh/"* )
            return 0
            ;;
        "${HOME}/Library/Application Support/Code/"* | "${HOME}/Library/Application Support/Cursor/"* )
            return 0
            ;;
        "${HOME}/.config/1Password/ssh/agent.toml" | "${HOME}/.config/gh/config.yml" | "${HOME}/.config/git/config.local" | "${HOME}/.config/zsh/zsh_history" | "${HOME}/.config/zsh/plugins.zsh" | "${HOME}/.local/bin/python"* )
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
        "${HOME}/.local/bin/"*)
            printf 'add a matching executable to dotfiles if you want it managed, otherwise remove the stray binary\n'
            ;;
        "${HOME}/.config/agents/"* | "${HOME}/.config/git/"* | "${HOME}/.config/zsh/"*)
            printf 'either add it to dotfiles if it belongs in the repo, or delete it if it was left behind by the migration\n'
            ;;
        *)
            printf 'review it and decide whether to add it to dotfiles, keep it local, or delete it\n'
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

        unmanaged_output="$(chezmoi --source "${CHEZMOI_SOURCE}" unmanaged --include=files,symlinks --path-style=absolute -- "${root}" 2>/dev/null || true)"
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
            if is_expected_local_override "${path}"; then
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

    if [[ "${printed_candidates}" -eq 0 ]]; then
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

main() {
    parse_args "$@"

    require_command chezmoi

    if [[ ! -d "${CHEZMOI_SOURCE}" ]]; then
        log_error "chezmoi source directory not found: ${CHEZMOI_SOURCE}"
        exit 1
    fi

    print_status_section
    print_candidate_section

    printf '\nSkipped broad roots by default: %s, %s, %s\n' \
        "$(display_path "${HOME}")" \
        "$(display_path "${HOME}/.config")" \
        "$(display_path "${HOME}/.local")"
}

main "$@"

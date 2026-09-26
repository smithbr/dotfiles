#!/usr/bin/env bash
# Link the dotfiles into place with GNU Stow, and report what the repo owns.
#
#   stow/common, stow/<os>  mirror $HOME; every file becomes a symlink into the
#                           repo, so editing the live file edits the repo.
#   seed/common, seed/<os>  copied once when missing, then owned by the app
#                           (docker and gh rewrite these themselves).
#   AGENT_LINKS             symlinks into the private agents checkout, which is
#                           cloned into ~/.config/agents and refreshed weekly.
#
# A real file where a link belongs is replaced only when its content matches
# the repo. Anything else is moved to ~/.local/state/dotfiles/clobbered/ first,
# so linking never loses data.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

REPO="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
DEST="${HOME}"
DRY_RUN=0
REFRESH=0
COMMAND=apply
declare -a stow_args=()

AGENTS_REPO_URL="${AGENTS_REPO_URL:-git@github.com:smithbr/agents-private.git}"
AGENTS_REFRESH_DAYS=7

# destination|target inside ~/.config/agents
AGENT_LINKS=(
    ".agents/skills|skills"
    ".claude/CLAUDE.md|AGENTS.md"
    ".claude/settings.json|tools/claude/settings.json"
    ".claude/skills|skills"
    ".codex/AGENTS.md|AGENTS.md"
    ".cursor/AGENTS.md|AGENTS.md"
    ".cursor/skills|skills"
)

# Directories that hold credentials or private agent state.
PRIVATE_DIRS=(.ssh .claude .config/glow)

usage() {
    cat <<'EOF'
Usage: link.sh [OPTIONS] [COMMAND] [-- STOW_ARGS...]

Commands:
  apply     Link packages, agent links and seed files (default)
  managed   Print every destination path the repo owns
  status    Report missing, replaced, foreign and broken links

Options:
  -n, --dry-run           Report what would change without touching anything
      --refresh           Pull the agents checkout even if it is fresh
      --repo PATH         Dotfiles repo to read (default: this script's repo)
      --destination PATH  Home directory to link into (default: $HOME)
  -h, --help              Show this help and exit

Arguments after -- go to stow, e.g. link.sh -- --verbose=2
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--dry-run) DRY_RUN=1 ;;
            --refresh) REFRESH=1 ;;
            --repo|--destination)
                if [[ $# -lt 2 ]]; then
                    log_error "$1 requires a path"
                    exit 2
                fi
                if [[ "$1" == --repo ]]; then REPO="$2"; else DEST="$2"; fi
                shift
                ;;
            apply|managed|status) COMMAND="$1" ;;
            -h|--help) usage; exit 0 ;;
            --)
                shift
                stow_args+=("$@")
                break
                ;;
            *)
                log_error "Unknown argument: $1"
                usage >&2
                exit 2
                ;;
        esac
        shift
    done

    local arg
    for arg in ${stow_args[@]+"${stow_args[@]}"}; do
        case "${arg}" in
            -n|--no|--simulate) DRY_RUN=1 ;;
            -t|--target|--target=*|-d|--dir|--dir=*)
                log_error "Set the destination with --destination, not stow's ${arg}"
                exit 2
                ;;
        esac
    done
}

platform() {
    if [[ -n "${DOTFILES_OS:-}" ]]; then
        printf '%s\n' "${DOTFILES_OS}"
        return
    fi
    case "$(uname -s)" in
        Darwin) printf 'darwin\n' ;;
        Linux) printf 'linux\n' ;;
        *) printf 'unknown\n' ;;
    esac
}

# Package directories under $1 (stow or seed) that apply to this platform.
packages_in() {
    local kind="$1" name
    for name in common "$(platform)"; do
        [[ -d "${REPO}/${kind}/${name}" ]] && printf '%s\n' "${name}"
    done
    return 0
}

# Relative paths of every file and symlink in one package.
package_files() {
    local dir="${REPO}/$1/$2"
    (cd "${dir}" && find . \( -type f -o -type l \) ! -name .DS_Store -print | sed 's#^\./##' | LC_ALL=C sort)
}

# Follow every symlink in a path, portably (no GNU readlink -f on older macOS).
physical_path() {
    local path="$1" link dir hops=0
    while [[ -L "${path}" && "${hops}" -lt 40 ]]; do
        link="$(readlink "${path}")"
        if [[ "${link}" == /* ]]; then
            path="${link}"
        else
            path="$(dirname "${path}")/${link}"
        fi
        hops=$((hops + 1))
    done
    dir="$(cd -P "$(dirname "${path}")" 2>/dev/null && pwd)" || return 1
    printf '%s/%s\n' "${dir}" "$(basename "${path}")"
}

# True when the destination already resolves to the package file.
is_linked() {
    local target="$1" source="$2" resolved
    [[ -L "${target}" ]] || return 1
    resolved="$(physical_path "${target}")" || return 1
    [[ "${resolved}" == "$(physical_path "${source}")" ]]
}

BACKUP_DIR=""
backup_path() {
    local target="$1" relative="${1#"${DEST}"/}"
    if [[ -z "${BACKUP_DIR}" ]]; then
        BACKUP_DIR="${DEST}/.local/state/dotfiles/clobbered/$(date +%Y%m%d-%H%M%S)"
    fi
    mkdir -p "$(dirname "${BACKUP_DIR}/${relative}")"
    mv "${target}" "${BACKUP_DIR}/${relative}"
    printf 'Backed up %s -> %s\n' "${target}" "${BACKUP_DIR}/${relative}"
}

# Clear real files and foreign links out of stow's way. BLOCKED counts the
# paths that still block stow, which is always 0 unless this is a dry run.
BLOCKED=0
clear_conflicts() {
    local package relative target source
    while IFS= read -r package; do
        while IFS= read -r relative; do
            target="${DEST}/${relative}"
            source="${REPO}/stow/${package}/${relative}"
            [[ -e "${target}" || -L "${target}" ]] || continue
            is_linked "${target}" "${source}" && continue

            if [[ -f "${target}" && ! -L "${target}" ]] && cmp -s "${target}" "${source}"; then
                if [[ "${DRY_RUN}" -eq 1 ]]; then
                    printf 'Would replace identical copy %s with a link\n' "${target}"
                    BLOCKED=$((BLOCKED + 1))
                else
                    rm -f "${target}"
                fi
            elif [[ "${DRY_RUN}" -eq 1 ]]; then
                printf 'Would back up %s before linking\n' "${target}"
                BLOCKED=$((BLOCKED + 1))
            else
                backup_path "${target}"
            fi
        done < <(package_files stow "${package}")
    done < <(packages_in stow)
}

run_stow() {
    local -a packages=()
    local package
    while IFS= read -r package; do
        packages+=("${package}")
    done < <(packages_in stow)
    [[ "${#packages[@]}" -gt 0 ]] || return 0

    if ! command -v stow >/dev/null 2>&1; then
        log_error "GNU Stow is not installed (brew install stow, or apt-get install stow)"
        return 1
    fi

    clear_conflicts
    local -a cmd=(stow --dir "${REPO}/stow" --target "${DEST}" --no-folding --restow --ignore '\.DS_Store')
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        if [[ "${BLOCKED}" -gt 0 ]]; then
            printf 'Stow preview skipped until the paths above are cleared\n'
            return 0
        fi
        cmd+=(--simulate --verbose=1)
    fi
    "${cmd[@]}" ${stow_args[@]+"${stow_args[@]}"} "${packages[@]}"
}

agents_checkout_is_fresh() {
    local fetch_head="${DEST}/.config/agents/.git/FETCH_HEAD"
    [[ -f "${fetch_head}" ]] || fetch_head="${DEST}/.config/agents/.git/HEAD"
    [[ -n "$(find "${fetch_head}" -mtime "-${AGENTS_REFRESH_DAYS}" -print 2>/dev/null)" ]]
}

# Clone or refresh the private agents repo. Failure is not fatal: a new host's
# SSH key is usually not registered with GitHub yet, and the rest of the
# dotfiles should still land.
sync_agents_repo() {
    local checkout="${DEST}/.config/agents"

    if [[ -d "${checkout}/.git" ]]; then
        if [[ "${REFRESH}" -eq 0 ]] && agents_checkout_is_fresh; then
            return 0
        fi
        if [[ "${DRY_RUN}" -eq 1 ]]; then
            printf 'Would pull %s\n' "${checkout}"
        elif ! git -C "${checkout}" pull --ff-only --quiet; then
            log_warn "Could not update ${checkout}; continuing with the current checkout"
        fi
    elif [[ -e "${checkout}" || -L "${checkout}" ]]; then
        log_warn "${checkout} exists but is not a git checkout; leaving it alone"
    elif [[ "${DRY_RUN}" -eq 1 ]]; then
        printf 'Would clone %s into %s\n' "${AGENTS_REPO_URL}" "${checkout}"
    elif ! command -v git >/dev/null 2>&1; then
        log_warn "git is not installed; skipping ${checkout}"
    else
        mkdir -p "$(dirname "${checkout}")"
        if ! git clone --quiet --depth 1 "${AGENTS_REPO_URL}" "${checkout}"; then
            log_warn "Could not clone ${AGENTS_REPO_URL}. Register this host's SSH key with GitHub, then run: ${REPO}/scripts/link.sh --refresh"
        fi
    fi
}

link_agents() {
    local entry relative target link_target
    for entry in "${AGENT_LINKS[@]}"; do
        relative="${entry%%|*}"
        target="${DEST}/${relative}"
        link_target="${DEST}/.config/agents/${entry#*|}"

        if [[ -L "${target}" && "$(readlink "${target}")" == "${link_target}" ]]; then
            continue
        fi
        if [[ "${DRY_RUN}" -eq 1 ]]; then
            if [[ -e "${target}" && ! -L "${target}" ]]; then
                printf 'Would back up %s and link it to %s\n' "${target}" "${link_target}"
            else
                printf 'Would link %s -> %s\n' "${target}" "${link_target}"
            fi
            continue
        fi
        # A real file or directory here is usually config an agent CLI wrote on
        # its first run. Keep it recoverable instead of deleting it.
        if [[ -e "${target}" && ! -L "${target}" ]]; then
            backup_path "${target}"
        fi
        mkdir -p "$(dirname "${target}")"
        ln -sfn "${link_target}" "${target}"
    done
}

copy_seeds() {
    local package relative target
    while IFS= read -r package; do
        while IFS= read -r relative; do
            target="${DEST}/${relative}"
            [[ -e "${target}" || -L "${target}" ]] && continue
            if [[ "${DRY_RUN}" -eq 1 ]]; then
                printf 'Would create %s\n' "${target}"
                continue
            fi
            mkdir -p "$(dirname "${target}")"
            cp "${REPO}/seed/${package}/${relative}" "${target}"
            chmod 600 "${target}"
            printf 'Created %s\n' "${target}"
        done < <(package_files seed "${package}")
    done < <(packages_in seed)
}

secure_private_dirs() {
    local relative
    [[ "${DRY_RUN}" -eq 0 ]] || return 0
    for relative in "${PRIVATE_DIRS[@]}"; do
        if [[ -d "${DEST}/${relative}" && ! -L "${DEST}/${relative}" ]]; then
            chmod 700 "${DEST}/${relative}"
        fi
    done
}

print_managed() {
    local kind package relative entry
    for kind in stow seed; do
        while IFS= read -r package; do
            while IFS= read -r relative; do
                printf '%s/%s\n' "${DEST}" "${relative}"
            done < <(package_files "${kind}" "${package}")
        done < <(packages_in "${kind}")
    done
    for entry in "${AGENT_LINKS[@]}"; do
        printf '%s/%s\n' "${DEST}" "${entry%%|*}"
    done
    printf '%s/.config/agents\n' "${DEST}"
}

# One line per problem: <state> <path>. States: missing, replaced (a real file
# where a link belongs), foreign (a link to somewhere else), broken.
print_status() {
    local package relative target source entry link_target
    while IFS= read -r package; do
        while IFS= read -r relative; do
            target="${DEST}/${relative}"
            source="${REPO}/stow/${package}/${relative}"
            if is_linked "${target}" "${source}"; then
                continue
            elif [[ -L "${target}" ]]; then
                printf 'foreign %s\n' "${target}"
            elif [[ -e "${target}" ]]; then
                printf 'replaced %s\n' "${target}"
            else
                printf 'missing %s\n' "${target}"
            fi
        done < <(package_files stow "${package}")
    done < <(packages_in stow)

    for entry in "${AGENT_LINKS[@]}"; do
        target="${DEST}/${entry%%|*}"
        link_target="${DEST}/.config/agents/${entry#*|}"
        if [[ -L "${target}" && "$(readlink "${target}")" == "${link_target}" ]]; then
            [[ -e "${target}" ]] || printf 'broken %s\n' "${target}"
        elif [[ -L "${target}" ]]; then
            printf 'foreign %s\n' "${target}"
        elif [[ -e "${target}" ]]; then
            printf 'replaced %s\n' "${target}"
        else
            printf 'missing %s\n' "${target}"
        fi
    done
}

main() {
    parse_args "$@"

    if [[ ! -d "${REPO}/stow" ]]; then
        log_error "Not a dotfiles repo (no stow/ directory): ${REPO}"
        exit 1
    fi
    REPO="$(cd "${REPO}" && pwd -P)"
    if [[ "${DRY_RUN}" -eq 0 ]]; then
        mkdir -p "${DEST}"
    fi
    if [[ ! -d "${DEST}" ]]; then
        log_error "Destination does not exist: ${DEST}"
        exit 1
    fi
    DEST="$(cd "${DEST}" && pwd)"

    case "${COMMAND}" in
        managed) print_managed ;;
        status) print_status ;;
        apply)
            run_stow
            sync_agents_repo
            link_agents
            copy_seeds
            secure_private_dirs
            ;;
    esac
}

main "$@"

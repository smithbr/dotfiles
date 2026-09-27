#!/usr/bin/env bash
# Link the dotfiles into place with GNU Stow, and report what the repo owns.
#
#   stow/common, stow/<os>  mirror $HOME; every file becomes a symlink into the
#                           repo, so editing the live file edits the repo.
#   seed/common, seed/<os>  copied once when missing, then owned by the app
#                           (docker and gh rewrite these themselves).
#   editors/<name>          one copy of shared editor settings, linked into each
#                           editor's user directory listed in editor_dirs.
#   AGENT_LINKS             symlinks into the private agents checkout, which is
#                           cloned into ~/.config/agents and refreshed weekly.
#
# A real file where a link belongs is replaced only when its content matches
# the repo. Anything else is moved to ~/.local/state/dotfiles/clobbered/ first,
# so linking never loses data.
#
# A link into the repo's stow/ or editors/ that no longer belongs here (its file
# moved or was deleted, or its package no longer applies) is stale and removed.
# Only links are removed; real files are never touched this way.

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

# destination directory|directory under editors/, one line per editor. Every
# file in the editors/ directory is linked into the destination directory.
# Takes a platform; defaults to this one.
editor_dirs() {
    case "${1:-$(platform)}" in
        darwin)
            printf '%s\n' \
                "Library/Application Support/Code/User|code" \
                "Library/Application Support/Cursor/User|code"
            ;;
        linux)
            printf '%s\n' \
                ".config/Code/User|code" \
                ".config/Cursor/User|code"
            ;;
    esac
}

# Directories that hold credentials or private agent state.
PRIVATE_DIRS=(.ssh .claude .config/glow)

usage() {
    cat <<'EOF'
Usage: link.sh [OPTIONS] [COMMAND] [-- STOW_ARGS...]

Commands:
  apply     Link packages, editor settings, agent links and seed files (default)
  managed   Print every destination path the repo owns
  status    Report missing, replaced, foreign, broken and stale links

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

# Where a link points, as an absolute path, even when the target is gone. The
# link's own directory and the longest existing prefix of the target are
# resolved physically, so a repo reached through a symlink still compares equal.
link_destination() {
    local target="$1" link path part prefix rest=""
    local -a parts=() kept=()
    link="$(readlink "${target}")" || return 1
    if [[ "${link}" == /* ]]; then
        path="${link}"
    else
        path="$(cd -P "$(dirname "${target}")" 2>/dev/null && pwd)/${link}" || return 1
    fi
    IFS=/ read -r -a parts <<< "${path}"
    for part in ${parts[@]+"${parts[@]}"}; do
        case "${part}" in
            ''|.) ;;
            ..)
                if [[ "${#kept[@]}" -gt 0 ]]; then
                    kept=(${kept[@]+"${kept[@]:0:$((${#kept[@]} - 1))}"})
                fi
                ;;
            *) kept+=("${part}") ;;
        esac
    done
    prefix=""
    for part in ${kept[@]+"${kept[@]}"}; do
        prefix="${prefix}/${part}"
    done
    while [[ -n "${prefix}" && ! -d "${prefix}" ]]; do
        rest="/${prefix##*/}${rest}"
        prefix="${prefix%/*}"
    done
    if [[ -n "${prefix}" ]]; then
        prefix="$(cd -P "${prefix}" && pwd)" || return 1
    fi
    printf '%s%s\n' "${prefix}" "${rest}"
}

# True when a link points into the repo's stow/ or editors/, existing or not.
is_repo_link() {
    local destination
    [[ -L "$1" ]] || return 1
    destination="$(link_destination "$1")" || return 1
    [[ "${destination}" == "${REPO}/stow/"* || "${destination}" == "${REPO}/editors/"* ]]
}

# Relative paths of the links that belong here: this platform's stow files and
# editor links.
managed_links() {
    local package relative entry
    while IFS= read -r package; do
        package_files stow "${package}"
    done < <(packages_in stow)
    while IFS= read -r entry; do
        printf '%s\n' "${entry%%|*}"
    done < <(editor_links)
}

# Relative paths where a repo link may have been left behind: every file any
# stow package has held, now or in the repo's history, and whatever sits in
# any platform's editor directories.
stale_candidates() {
    local dir line entry os
    for dir in "${REPO}/stow"/*/; do
        [[ -d "${dir}" ]] && package_files stow "$(basename "${dir}")"
    done
    if command -v git >/dev/null 2>&1 && git -C "${REPO}" rev-parse --git-dir >/dev/null 2>&1; then
        while IFS= read -r line; do
            [[ "${line}" == stow/*/* ]] && printf '%s\n' "${line#stow/*/}"
        done < <(git -C "${REPO}" -c core.quotePath=false log --format= --name-only -- stow 2>/dev/null || true)
    fi
    for os in darwin linux; do
        while IFS= read -r entry; do
            dir="${DEST}/${entry%%|*}"
            [[ -d "${dir}" && ! -L "${dir}" ]] || continue
            for line in "${dir}"/*; do
                [[ -L "${line}" ]] && printf '%s\n' "${line#"${DEST}"/}"
            done
        done < <(editor_dirs "${os}")
    done
}

# Absolute paths of stale links: repo links that are not managed here.
stale_links() {
    local managed relative target
    managed="$(managed_links)"
    while IFS= read -r relative; do
        [[ -n "${relative}" ]] || continue
        target="${DEST}/${relative}"
        is_repo_link "${target}" || continue
        grep -Fxq -- "${relative}" <<< "${managed}" && continue
        printf '%s\n' "${target}"
    done < <(stale_candidates | LC_ALL=C sort -u)
}

prune_stale_links() {
    local target
    while IFS= read -r target; do
        if [[ "${DRY_RUN}" -eq 1 ]]; then
            printf 'Would remove stale link %s\n' "${target}"
        else
            rm -f "${target}"
            printf 'Removed stale link %s\n' "${target}"
        fi
    done < <(stale_links)
}

BACKUP_DIR=""
# Backups can hold credentials, so the directories are private and never
# reached through a symlinked parent (as in file-review.sh's archive).
backup_path() {
    local target="$1" relative="${1#"${DEST}"/}" parent backup_dir
    backup_dir="${BACKUP_DIR:-${DEST}/.local/state/dotfiles/clobbered/$(date +%Y%m%d-%H%M%S)}"
    for parent in "${DEST}/.local" "${DEST}/.local/state" "${DEST}/.local/state/dotfiles" \
        "${DEST}/.local/state/dotfiles/clobbered" "${backup_dir}"; do
        if [[ -L "${parent}" ]]; then
            log_error "Backup parent is a symlink: ${parent}; not moving ${target}"
            return 1
        fi
    done
    BACKUP_DIR="${backup_dir}"
    (umask 077 && mkdir -p "$(dirname "${BACKUP_DIR}/${relative}")")
    chmod 700 "${BACKUP_DIR}"
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

            # Our own link into another package (the file moved between
            # packages) is replaced quietly, like an identical copy.
            if is_repo_link "${target}"; then
                if [[ "${DRY_RUN}" -eq 1 ]]; then
                    printf 'Would relink %s\n' "${target}"
                    BLOCKED=$((BLOCKED + 1))
                else
                    rm -f "${target}"
                fi
            elif [[ -f "${target}" && ! -L "${target}" ]] && cmp -s "${target}" "${source}"; then
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

    # A dry run on a fresh host still reports conflicts; install.sh installs
    # stow before the real run.
    local have_stow=1
    command -v stow >/dev/null 2>&1 || have_stow=0
    if [[ "${have_stow}" -eq 0 && "${DRY_RUN}" -eq 0 ]]; then
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
        if [[ "${have_stow}" -eq 0 ]]; then
            printf 'Stow preview skipped: GNU Stow is not installed\n'
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

# destination|source for every shared editor file on this platform.
editor_links() {
    local entry dir name relative
    while IFS= read -r entry; do
        dir="${entry%%|*}"
        name="${entry#*|}"
        [[ -d "${REPO}/editors/${name}" ]] || continue
        while IFS= read -r relative; do
            printf '%s/%s|%s/editors/%s/%s\n' "${dir}" "${relative}" "${REPO}" "${name}" "${relative}"
        done < <(package_files editors "${name}")
    done < <(editor_dirs)
}

# Same rules as the stow packages: an identical copy is replaced, anything
# else is backed up first. A link into the repo's old stow/ copy of the file
# is ours and is replaced quietly.
link_editors() {
    local entry relative target source
    while IFS= read -r entry; do
        relative="${entry%%|*}"
        source="${entry#*|}"
        target="${DEST}/${relative}"
        is_linked "${target}" "${source}" && continue

        if is_repo_link "${target}" \
            || [[ -L "${target}" && "$(readlink "${target}")" == */stow/"$(platform)/${relative}" ]]; then
            [[ "${DRY_RUN}" -eq 0 ]] && rm -f "${target}"
        elif [[ -f "${target}" && ! -L "${target}" ]] && cmp -s "${target}" "${source}"; then
            [[ "${DRY_RUN}" -eq 0 ]] && rm -f "${target}"
        elif [[ -e "${target}" || -L "${target}" ]]; then
            if [[ "${DRY_RUN}" -eq 1 ]]; then
                printf 'Would back up %s before linking\n' "${target}"
                continue
            fi
            backup_path "${target}"
        fi
        if [[ "${DRY_RUN}" -eq 1 ]]; then
            printf 'Would link %s -> %s\n' "${target}" "${source}"
            continue
        fi
        mkdir -p "$(dirname "${target}")"
        ln -s "${source}" "${target}"
    done < <(editor_links)
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
    while IFS= read -r entry; do
        printf '%s/%s\n' "${DEST}" "${entry%%|*}"
    done < <(editor_links)
    for entry in "${AGENT_LINKS[@]}"; do
        printf '%s/%s\n' "${DEST}" "${entry%%|*}"
    done
    printf '%s/.config/agents\n' "${DEST}"
}

print_link_state() {
    local target="$1" source="$2"
    if is_linked "${target}" "${source}"; then
        return 0
    elif [[ -L "${target}" ]]; then
        printf 'foreign %s\n' "${target}"
    elif [[ -e "${target}" ]]; then
        printf 'replaced %s\n' "${target}"
    else
        printf 'missing %s\n' "${target}"
    fi
}

# One line per problem: <state> <path>. States: missing, replaced (a real file
# where a link belongs), foreign (a link to somewhere else), broken.
print_status() {
    local package relative target entry link_target
    while IFS= read -r package; do
        while IFS= read -r relative; do
            print_link_state "${DEST}/${relative}" "${REPO}/stow/${package}/${relative}"
        done < <(package_files stow "${package}")
    done < <(packages_in stow)
    while IFS= read -r entry; do
        print_link_state "${DEST}/${entry%%|*}" "${entry#*|}"
    done < <(editor_links)

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

    while IFS= read -r target; do
        printf 'stale %s\n' "${target}"
    done < <(stale_links)
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
            prune_stale_links
            run_stow
            link_editors
            sync_agents_repo
            link_agents
            copy_seeds
            secure_private_dirs
            ;;
    esac
}

main "$@"

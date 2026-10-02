#!/usr/bin/env bash
# Link the dotfiles into place with GNU Stow, and report what the repo owns.
#
#   personas/<name>         which layers, editors, agents and installs a machine
#                           gets: key=value lines for os, layers, agents,
#                           agent_apps, skills, editors, brew,
#                           brew_optional, linux_optional.
#   stow/<layer>, stow/<layer>.<os>
#                           mirror $HOME; every file becomes a symlink into the
#                           repo, so editing the live file edits the repo.
#   seed/<layer>, seed/<layer>.<os>
#                           copied once when missing, then owned by the app
#                           (docker and gh rewrite these themselves).
#   editors/<name>          one copy of shared editor settings, linked into each
#                           editor's user directory listed in editor_dirs.
#   AGENT_LINKS             symlinks into the private agents checkout, which is
#                           cloned into ~/.config/agents and refreshed weekly.
#   SKILL_LINKS             link to ~/.agents/skills, a real directory that Stow
#                           fills from the agents repo's skills/ bundles: the
#                           persona's skills list (core when unset). A bundle no
#                           persona lists is left to skills-add; one another
#                           persona lists is removed as stale.
#
# A persona without agents gets none of these: its agent links are removed as
# stale, and a leftover checkout is reported but never deleted. Each app's own
# settings (~/.claude/settings.json, ~/.cursor/cli-config.json, ~/.codex/
# config.toml) are left to the app.
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
PERSONA=""
ADD_LAYER=""
ADD_PLATFORM=0
ADD_SEED=0
declare -a add_paths=()
declare -a stow_args=()

AGENTS_REPO_URL="${AGENTS_REPO_URL:-git@github.com:smithbr/agents-private.git}"
AGENTS_REFRESH_DAYS=7

# destination|target inside ~/.config/agents
AGENT_LINKS=(
    ".claude/CLAUDE.md|AGENTS.md"
    ".claude/agents|agents"
    ".codex/AGENTS.md|AGENTS.md"
    ".cursor/AGENTS.md|AGENTS.md"
)

# Agent apps a persona can pick with agent_apps. An entry above or in
# SKILL_LINKS belongs to the app named by its first path component (.claude is
# claude); a persona links only its apps' entries.
AGENT_APPS="claude codex cursor"

# Enabled skills live in SKILLS_DIR (relative to $HOME); these link to it.
SKILLS_DIR=".agents/skills"
SKILL_LINKS=(.claude/skills .cursor/skills)

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
PRIVATE_DIRS=(.ssh .claude .cursor .config/glow)

usage() {
    cat <<'EOF'
Usage: link.sh [OPTIONS] [COMMAND] [-- STOW_ARGS...]

Commands:
  apply     Link packages, editor settings, agent links and seed files (default)
  managed   Print every destination path the repo owns
  status    Report missing, replaced, foreign, broken and stale links
  persona   Print the persona in effect and where it came from
            (flag, env, saved or default)
  personas  List the personas this OS can use, with their descriptions
  installs  Print the persona's brew, brew_optional and linux_optional lists
  add PATH...
            Start managing files from the home directory: copy each one into
            a layer, then link it (a directory adds every file in it)

Options:
  -n, --dry-run           Report what would change without touching anything
      --persona NAME      Link as this persona (see personas/); a real apply
                          saves it for later runs
      --refresh           Pull the agents checkout even if it is fresh
      --repo PATH         Dotfiles repo to read (default: this script's repo)
      --destination PATH  Home directory to link into (default: $HOME)
      --layer NAME        add: the layer to put the files in (asked on a
                          terminal when missing)
      --platform          add: use the layer's part for this OS only
                          (stow/<layer>.<os>)
      --seed              add: copy once as a seed file the app then owns,
                          instead of linking
  -h, --help              Show this help and exit

Arguments after -- go to stow, e.g. link.sh -- --verbose=2
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--dry-run) DRY_RUN=1 ;;
            --refresh) REFRESH=1 ;;
            --platform) ADD_PLATFORM=1 ;;
            --seed) ADD_SEED=1 ;;
            --repo|--destination|--persona|--layer)
                if [[ $# -lt 2 ]]; then
                    log_error "$1 requires a value"
                    exit 2
                fi
                case "$1" in
                    --repo) REPO="$2" ;;
                    --destination) DEST="$2" ;;
                    --layer) ADD_LAYER="$2" ;;
                    *) PERSONA="$2" ;;
                esac
                shift
                ;;
            apply|managed|status|persona|personas|installs|add) COMMAND="$1" ;;
            -h|--help) usage; exit 0 ;;
            --)
                shift
                stow_args+=("$@")
                break
                ;;
            -*)
                log_error "Unknown argument: $1"
                usage >&2
                exit 2
                ;;
            *)
                if [[ "${COMMAND}" != add ]]; then
                    log_error "Unknown argument: $1"
                    usage >&2
                    exit 2
                fi
                add_paths+=("$1")
                ;;
        esac
        shift
    done

    if [[ "${COMMAND}" == add && "${#add_paths[@]}" -eq 0 ]]; then
        log_error "add needs at least one path"
        exit 2
    fi
    if [[ "${COMMAND}" != add && ( -n "${ADD_LAYER}" || "${ADD_PLATFORM}" -eq 1 || "${ADD_SEED}" -eq 1 ) ]]; then
        log_error "--layer, --platform and --seed only apply to add"
        exit 2
    fi

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

# The persona in effect, set by load_persona. A repo without personas/ links
# every package for the platform, as before personas existed.
PERSONA_NAME=""
PERSONA_SOURCE=""
PERSONA_LAYERS=""
PERSONA_AGENTS=yes
PERSONA_EDITORS=yes
PERSONA_AGENT_APPS="${AGENT_APPS}"
PERSONA_SKILLS=core
# Installs, for install.sh: Brewfiles installed in full, Brewfiles offered in
# the macOS picker, and the Linux bootstrap's optional installs.
PERSONA_BREW=core
PERSONA_BREW_OPTIONAL=macos
PERSONA_LINUX_OPTIONAL="docker tailscale"

persona_state_file() {
    printf '%s/.local/state/dotfiles/persona\n' "${DEST}"
}

default_persona() {
    case "$(platform)" in
        darwin) printf 'home\n' ;;
        linux) printf 'server\n' ;;
        *) printf 'sandbox\n' ;;
    esac
}

# key=value lines from one persona file; comments and blank lines skipped.
persona_settings() {
    local line key value
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line%%#*}"
        [[ "${line}" == *=* ]] || continue
        key="${line%%=*}"
        value="${line#*=}"
        key="${key//[[:space:]]/}"
        value="$(printf '%s' "${value}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        printf '%s=%s\n' "${key}" "${value}"
    done < "$1"
}

# True when a persona file allows this platform.
persona_allows_platform() {
    local os
    os="$(persona_settings "$1" | sed -n 's/^os=//p')"
    [[ ",${os// /}," == *",$(platform),"* ]]
}

list_personas() {
    local file description
    [[ -d "${REPO}/personas" ]] || return 0
    for file in "${REPO}/personas"/*; do
        [[ -f "${file}" ]] || continue
        persona_allows_platform "${file}" || continue
        description="$(sed -n 's/^# *//p' "${file}" | head -1)"
        printf '%s\t%s\n' "$(basename "${file}")" "${description}"
    done
}

load_persona() {
    local name="" source file setting key value saved app bundle
    if [[ ! -d "${REPO}/personas" ]]; then
        PERSONA_LAYERS="common $(platform)"
        select_agent_apps
        return 0
    fi

    if [[ -n "${PERSONA}" ]]; then
        name="${PERSONA}" source=flag
    elif [[ -n "${DOTFILES_PERSONA:-}" ]]; then
        name="${DOTFILES_PERSONA}" source=env
    else
        saved="$(persona_state_file)"
        if [[ -f "${saved}" && ! -L "${saved}" ]]; then
            IFS= read -r name < "${saved}" || true
            source=saved
        fi
        if [[ -z "${name}" ]]; then
            name="$(default_persona)" source=default
        fi
    fi

    file="${REPO}/personas/${name}"
    if [[ ! "${name}" =~ ^[a-z][a-z0-9-]*$ || ! -f "${file}" ]]; then
        log_error "Unknown persona '${name}'. Choose one of: $(list_personas | cut -f1 | tr '\n' ' ')"
        exit 2
    fi
    if ! persona_allows_platform "${file}"; then
        log_error "Persona '${name}' is not for $(platform). Choose one of: $(list_personas | cut -f1 | tr '\n' ' ')"
        exit 2
    fi

    PERSONA_NAME="${name}"
    PERSONA_SOURCE="${source}"
    PERSONA_LAYERS=""
    PERSONA_BREW=""
    PERSONA_BREW_OPTIONAL=""
    PERSONA_LINUX_OPTIONAL=""
    while IFS= read -r setting; do
        key="${setting%%=*}"
        value="${setting#*=}"
        case "${key}" in
            os) ;;
            layers) PERSONA_LAYERS="${value}" ;;
            brew) PERSONA_BREW="${value}" ;;
            brew_optional) PERSONA_BREW_OPTIONAL="${value}" ;;
            linux_optional) PERSONA_LINUX_OPTIONAL="${value}" ;;
            skills)
                for bundle in ${value}; do
                    if [[ ! "${bundle}" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
                        log_error "${file}: skills takes bundle names, not '${bundle}'"
                        exit 2
                    fi
                done
                PERSONA_SKILLS="${value}"
                ;;
            agent_apps)
                for app in ${value}; do
                    if [[ " ${AGENT_APPS} " != *" ${app} "* ]]; then
                        log_error "${file}: agent_apps takes ${AGENT_APPS// /, }, not '${app}'"
                        exit 2
                    fi
                done
                PERSONA_AGENT_APPS="${value}"
                ;;
            agents|editors)
                if [[ "${value}" != yes && "${value}" != no ]]; then
                    log_error "${file}: ${key} must be yes or no, not '${value}'"
                    exit 2
                fi
                if [[ "${key}" == agents ]]; then PERSONA_AGENTS="${value}"; else PERSONA_EDITORS="${value}"; fi
                ;;
            *)
                log_error "${file}: unknown setting '${key}'"
                exit 2
                ;;
        esac
    done < <(persona_settings "${file}")
    select_agent_apps
}

# True when an agent entry (relative to $HOME) belongs to one of the persona's
# agent apps.
app_wanted() {
    local app="${1%%/*}"
    [[ " ${PERSONA_AGENT_APPS} " == *" ${app#.} "* ]]
}

# The persona's share of AGENT_LINKS and SKILL_LINKS.
select_agent_apps() {
    local entry
    WANTED_AGENT_LINKS=() WANTED_SKILL_LINKS=()
    for entry in "${AGENT_LINKS[@]}"; do
        app_wanted "${entry}" && WANTED_AGENT_LINKS+=("${entry}")
    done
    for entry in "${SKILL_LINKS[@]}"; do
        app_wanted "${entry}" && WANTED_SKILL_LINKS+=("${entry}")
    done
    return 0
}

# Remember an explicitly chosen persona for later runs. The state directory is
# never reached through a symlinked parent, as with the backups.
save_persona() {
    local file parent
    [[ "${PERSONA_SOURCE}" == flag || "${PERSONA_SOURCE}" == env ]] || return 0
    [[ "${DRY_RUN}" -eq 0 ]] || return 0
    file="$(persona_state_file)"
    if [[ -f "${file}" && ! -L "${file}" && "$(cat "${file}")" == "${PERSONA_NAME}" ]]; then
        return 0
    fi
    for parent in "${DEST}/.local" "${DEST}/.local/state" "${DEST}/.local/state/dotfiles" "${file}"; do
        if [[ -L "${parent}" ]]; then
            log_error "Persona state path is a symlink: ${parent}; not saving the persona"
            return 1
        fi
    done
    (umask 077 && mkdir -p "$(dirname "${file}")" && printf '%s\n' "${PERSONA_NAME}" > "${file}")
    printf 'Saved persona %s\n' "${PERSONA_NAME}"
}

# Package directories under $1 (stow or seed) for the persona's layers: each
# layer, then its OS-specific part (<layer>.<os>).
packages_in() {
    local kind="$1" layer name
    for layer in ${PERSONA_LAYERS}; do
        for name in "${layer}" "${layer}.$(platform)"; do
            [[ -d "${REPO}/${kind}/${name}" ]] && printf '%s\n' "${name}"
        done
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
    stale_agent_links
    stale_skill_links
}

# True when a link points into the agents checkout or at the skills directory,
# existing or not.
is_agent_link() {
    local destination home
    [[ -L "$1" ]] || return 1
    destination="$(link_destination "$1")" || return 1
    home="$(cd -P "${DEST}" && pwd)" || return 1
    [[ "${destination}" == "${home}/.config/agents" || "${destination}" == "${home}/.config/agents/"* \
        || "${destination}" == "${home}/${SKILLS_DIR}" ]]
}

# Links directly inside the directories agent links live in, plus the skill
# links in ~/.agents/skills when this persona has no agents.
agent_link_candidates() {
    local entry dir
    for entry in "${AGENT_LINKS[@]}" "${SKILL_LINKS[@]}"; do
        dirname "${entry%%|*}"
    done | LC_ALL=C sort -u | while IFS= read -r dir; do
        [[ -d "${DEST}/${dir}" && ! -L "${DEST}/${dir}" ]] || continue
        find "${DEST}/${dir}" -mindepth 1 -maxdepth 1 -type l
    done
    if [[ "${PERSONA_AGENTS}" != yes && -d "${DEST}/${SKILLS_DIR}" && ! -L "${DEST}/${SKILLS_DIR}" ]]; then
        find "${DEST}/${SKILLS_DIR}" -mindepth 1 -maxdepth 1 -type l
    fi
}

# Absolute paths of agent links this persona does not want: every one when it
# has no agents, otherwise those no longer in AGENT_LINKS or SKILL_LINKS.
stale_agent_links() {
    local target wanted=""
    if [[ "${PERSONA_AGENTS}" == yes ]]; then
        wanted="$(printf '%s\n' ${WANTED_AGENT_LINKS[@]+"${WANTED_AGENT_LINKS[@]%%|*}"} \
            ${WANTED_SKILL_LINKS[@]+"${WANTED_SKILL_LINKS[@]}"})"
    fi
    while IFS= read -r target; do
        is_agent_link "${target}" || continue
        if [[ -n "${wanted}" ]] && grep -Fxq -- "${target#"${DEST}"/}" <<< "${wanted}"; then
            continue
        fi
        printf '%s\n' "${target}"
    done < <(agent_link_candidates | LC_ALL=C sort)
}

# Skill bundles some persona lists, one per line. The others belong to
# skills-add, so links into them are never stale.
persona_skill_bundles() {
    local file
    {
        printf 'core\n'
        for file in "${REPO}/personas"/*; do
            [[ -f "${file}" ]] || continue
            persona_settings "${file}" | sed -n 's/^skills=//p' | tr -s ' ' '\n'
        done
    } | sed '/^$/d' | LC_ALL=C sort -u
}

# Absolute paths of links in ~/.agents/skills into a bundle another persona
# lists but this one does not.
stale_skill_links() {
    local skills="${DEST}/${SKILLS_DIR}" home bundles target bundle listed
    [[ "${PERSONA_AGENTS}" == yes && -d "${skills}" && ! -L "${skills}" ]] || return 0
    home="$(cd -P "${DEST}" && pwd)" || return 0
    bundles="${home}/.config/agents/skills/"
    listed="$(persona_skill_bundles)"
    while IFS= read -r target; do
        bundle="$(link_destination "${target}")" || continue
        [[ "${bundle}" == "${bundles}"* ]] || continue
        bundle="${bundle#"${bundles}"}"
        bundle="${bundle%%/*}"
        [[ " ${PERSONA_SKILLS} " == *" ${bundle} "* ]] && continue
        grep -Fxq -- "${bundle}" <<< "${listed}" && printf '%s\n' "${target}"
    done < <(find "${skills}" -mindepth 1 -maxdepth 1 -type l | LC_ALL=C sort)
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
    for entry in ${WANTED_AGENT_LINKS[@]+"${WANTED_AGENT_LINKS[@]}"}; do
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

# Skills used to sit directly in the agents repo's skills/. A pull that moved
# them into bundles leaves behind any folder still holding untracked files
# (.DS_Store, caches), so skills/ looks flat again. Name them; never delete.
warn_flat_skill_leftovers() {
    local checkout="${DEST}/.config/agents" dir
    local -a leftovers=()
    [[ -d "${checkout}/.git" ]] && command -v git >/dev/null 2>&1 || return 0
    for dir in "${checkout}/skills/"*/; do
        dir="${dir%/}"
        [[ -d "${dir}" ]] || continue
        if [[ -z "$(git -C "${checkout}" ls-files -- "skills/${dir##*/}" 2>/dev/null | head -n 1)" ]]; then
            leftovers+=("${dir##*/}")
        fi
    done
    [[ "${#leftovers[@]}" -gt 0 ]] || return 0
    log_warn "${checkout}/skills has folders the agents repo does not track, likely left from the old flat layout: ${leftovers[*]}. Move them out once nothing in them is yours."
}

# ~/.agents/skills is machine-local: Stow links the persona's skill bundles
# into it, and skills-add links more. The old layout linked it to the whole
# library.
link_skills() {
    local skills="${DEST}/${SKILLS_DIR}" bundles="${DEST}/.config/agents/skills"
    local relative target bundle
    local -a wanted=()

    [[ -d "${bundles}/core" ]] || return 0
    warn_flat_skill_leftovers
    for bundle in ${PERSONA_SKILLS}; do
        if [[ -d "${bundles}/${bundle}" ]]; then
            wanted+=("${bundle}")
        else
            log_warn "No skill bundle '${bundle}' in ${bundles}; skipping it"
        fi
    done
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        printf 'Would stow skill bundles %s into %s\n' "${wanted[*]-none}" "${skills}"
        return 0
    fi

    [[ -L "${skills}" ]] && rm "${skills}"
    mkdir -p "${skills}"
    if [[ "${#wanted[@]}" -gt 0 ]] && ! stow --dir "${bundles}" --target "${skills}" --restow --ignore '\.DS_Store' "${wanted[@]}"; then
        log_warn "Could not stow the skill bundles ${wanted[*]} into ${skills}; resolve the conflict above and rerun"
    fi

    for relative in ${WANTED_SKILL_LINKS[@]+"${WANTED_SKILL_LINKS[@]}"}; do
        target="${DEST}/${relative}"
        [[ -L "${target}" && "$(readlink "${target}")" == "${skills}" ]] && continue
        if [[ -e "${target}" && ! -L "${target}" ]]; then
            backup_path "${target}"
        fi
        mkdir -p "$(dirname "${target}")"
        ln -sfn "${skills}" "${target}"
    done
}

warn_unused_agents_checkout() {
    [[ -e "${DEST}/.config/agents" ]] || return 0
    log_warn "${DEST}/.config/agents holds the private agents repo, which this persona does not use. It is left in place; delete it yourself if this machine should not keep it."
}

# destination|source for every shared editor file on this platform.
editor_links() {
    local entry dir name relative
    [[ "${PERSONA_EDITORS}" == yes ]] || return 0
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

# Every leading part of each relative path read on stdin (a/b/c: a, a/b, a/b/c).
path_prefixes() {
    awk -F/ '{ p = $1; print p; for (i = 2; i <= NF; i++) { p = p "/" $i; print p } }'
}

# Real files or folders where a layer this persona does not link would put its
# files, such as ~/.config/restic on work. Each is the shallowest path no other
# layer uses, so shared parents like ~/.config or ~/.local/bin are never named.
# Only reported; nothing is moved.
unlinked_layer_paths() {
    local dir layer relative shared
    for layer in $(for dir in "${REPO}"/stow/*/; do
        if [[ -d "${dir}" ]]; then dir="$(basename "${dir}")"; printf '%s\n' "${dir%%.*}"; fi
    done | LC_ALL=C sort -u); do
        [[ " ${PERSONA_LAYERS} " == *" ${layer} "* ]] && continue
        shared="$(for dir in "${REPO}"/stow/*/; do
            dir="$(basename "${dir}")"
            if [[ -d "${REPO}/stow/${dir}" && "${dir%%.*}" != "${layer}" ]]; then package_files stow "${dir}"; fi
        done | path_prefixes | LC_ALL=C sort -u)"
        for dir in "${REPO}/stow/${layer}" "${REPO}/stow/${layer}".*; do
            if [[ -d "${dir}" ]]; then package_files stow "$(basename "${dir}")"; fi
        done | path_prefixes | LC_ALL=C sort -u | while IFS= read -r relative; do
            grep -Fxq -- "${relative}" <<< "${shared}" && continue
            if [[ "${relative}" == */* ]] && ! grep -Fxq -- "${relative%/*}" <<< "${shared}"; then
                continue
            fi
            # An empty folder is what pruning stale links leaves behind.
            if [[ -e "${DEST}/${relative}" && ! -L "${DEST}/${relative}" ]] \
                && ! [[ -d "${DEST}/${relative}" && -z "$(ls -A "${DEST}/${relative}")" ]]; then
                printf 'unlinked %s\n' "${DEST}/${relative}"
            fi
        done
    done
    return 0
}

# Git reads ~/.gitconfig after ~/.config/git/config, so a [user] left there
# overrides config.local. Prints the problem as a status line, or nothing.
# Exit status 1 means no user.email; an unreadable config is left to git.
git_identity_state() {
    local status=0
    command -v git >/dev/null 2>&1 || return 0
    if git config --file "${DEST}/.gitconfig" --get-regexp '^user[.]' >/dev/null 2>&1; then
        printf 'shadowed %s\n' "${DEST}/.gitconfig"
        return 0
    fi
    HOME="${DEST}" XDG_CONFIG_HOME="${DEST}/.config" GIT_CONFIG_NOSYSTEM=1 \
        git config --global --includes --get user.email >/dev/null 2>&1 || status=$?
    [[ "${status}" -ne 1 ]] || printf 'unset %s\n' "${DEST}/.config/git/config.local"
}

warn_git_identity() {
    local state
    state="$(git_identity_state)"
    case "${state%% *}" in
        shadowed) log_warn "${state#* } sets [user] and overrides ~/.config/git/config.local; move anything you need into config.local, then archive it with file-review.sh --cleanup" ;;
        unset) log_warn "No git identity for persona '${PERSONA_NAME}': set name and email under [user] in ${state#* }" ;;
    esac
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
    [[ "${PERSONA_AGENTS}" == yes ]] || return 0
    for entry in ${WANTED_AGENT_LINKS[@]+"${WANTED_AGENT_LINKS[@]}"} ${WANTED_SKILL_LINKS[@]+"${WANTED_SKILL_LINKS[@]}"}; do
        printf '%s/%s\n' "${DEST}" "${entry%%|*}"
    done
    printf '%s/%s\n' "${DEST}" "${SKILLS_DIR}"
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
# where a link belongs), foreign (a link to somewhere else), broken, and for
# git, shadowed (~/.gitconfig overrides the identity) or unset (no user.email),
# and unlinked (a real path owned by a layer this persona does not link).
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

    for entry in ${WANTED_AGENT_LINKS[@]+"${WANTED_AGENT_LINKS[@]}"}; do
        [[ "${PERSONA_AGENTS}" == yes ]] || break
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

    if [[ "${PERSONA_AGENTS}" == yes ]]; then
        target="${DEST}/${SKILLS_DIR}"
        if [[ -L "${target}" || ( -e "${target}" && ! -d "${target}" ) ]]; then
            printf 'replaced %s\n' "${target}"
        elif [[ ! -d "${target}" ]]; then
            printf 'missing %s\n' "${target}"
        fi
        for entry in ${WANTED_SKILL_LINKS[@]+"${WANTED_SKILL_LINKS[@]}"}; do
            link_target="${DEST}/${SKILLS_DIR}"
            target="${DEST}/${entry}"
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
    elif [[ -e "${DEST}/.config/agents" ]]; then
        printf 'unused %s\n' "${DEST}/.config/agents"
    fi

    while IFS= read -r target; do
        printf 'stale %s\n' "${target}"
    done < <(stale_links)
    unlinked_layer_paths
    git_identity_state
}

# ---------------------------------------------------------------------------
# add: start managing files that already live in the home directory
# ---------------------------------------------------------------------------

# Why a home-relative path must not enter the repo, or nothing when it may.
# The repo is public, so secrets and machine-specific files stay out.
add_refusal() {
    local relative="$1" file="$2" name entry dir os banned="${DEST}/.config/banned-words"
    name="${relative##*/}"

    for dir in "${REPO}"/stow/*/ "${REPO}"/seed/*/; do
        if [[ -e "${dir}${relative}" || -L "${dir}${relative}" ]]; then
            printf 'already in the repo at %s\n' "${dir#"${REPO}"/}${relative}"
            return 0
        fi
    done
    case "${relative}" in
        .config/agents|.config/agents/*|.agents/*)
            printf 'belongs to the private agents repo\n'
            return 0
            ;;
        .claude/*|.cursor/*|.codex/*)
            printf 'belongs to the app, which keeps its own setup\n'
            return 0
            ;;
    esac
    for entry in "${AGENT_LINKS[@]}" "${SKILL_LINKS[@]}"; do
        if [[ "${relative}" == "${entry%%|*}" || "${relative}" == "${entry%%|*}/"* ]]; then
            printf 'belongs to the private agents repo\n'
            return 0
        fi
    done
    for os in darwin linux; do
        while IFS= read -r entry; do
            if [[ "${relative}" == "${entry%%|*}/"* ]]; then
                printf 'editor settings go in editors/, not stow/\n'
                return 0
            fi
        done < <(editor_dirs "${os}")
    done
    case "${name}" in
        *.local|*.local.*)
            printf 'a .local file holds this machine'"'"'s overrides\n'
            return 0
            ;;
        .env|.env.*|*.env|.netrc|.git-credentials|*.pem|*.key|*.p12|*.pfx)
            printf 'looks like a secret\n'
            return 0
            ;;
        id_*)
            if [[ "${name}" != *.pub ]]; then
                printf 'looks like a private key\n'
                return 0
            fi
            ;;
    esac
    if grep -qE -- '-----BEGIN ([A-Z]+ )*PRIVATE KEY-----' "${file}" 2>/dev/null; then
        printf 'contains a private key\n'
        return 0
    fi
    if [[ -f "${banned}" ]] && grep -qwiIE -f <(grep -v '^#' "${banned}" | grep -v '^[[:space:]]*$') "${file}" 2>/dev/null; then
        printf 'contains a banned word\n'
        return 0
    fi
    return 0
}

# Pick the layer for add: --layer, else a choice on a terminal. Only layers
# this persona links qualify, so the added file is linked right here.
choose_add_layer() {
    local layer choice index=1
    local -a layers=()
    read -r -a layers <<< "${PERSONA_LAYERS}"

    if [[ -n "${ADD_LAYER}" ]]; then
        for layer in "${layers[@]}"; do
            [[ "${layer}" == "${ADD_LAYER}" ]] && return 0
        done
        log_error "Persona '${PERSONA_NAME}' does not link layer '${ADD_LAYER}'. Choose one of: ${PERSONA_LAYERS}"
        exit 2
    fi
    if [[ ! -t 0 ]]; then
        log_error "Name the layer with --layer (one of: ${PERSONA_LAYERS})"
        exit 2
    fi
    if command -v gum >/dev/null 2>&1; then
        ADD_LAYER="$(gum choose --header "Layer for the new files" "${layers[@]}")" || ADD_LAYER=""
    else
        for layer in "${layers[@]}"; do
            printf '  %d) %s\n' "${index}" "${layer}"
            index=$((index + 1))
        done
        printf 'Layer for the new files [1-%d]: ' "${#layers[@]}"
        IFS= read -r choice || choice=""
        if [[ "${choice}" =~ ^[0-9]+$ && "${choice}" -ge 1 && "${choice}" -le "${#layers[@]}" ]]; then
            ADD_LAYER="${layers[$((choice - 1))]}"
        fi
    fi
    if [[ -z "${ADD_LAYER}" ]]; then
        log_error "No layer chosen; nothing added"
        exit 1
    fi
}

# Home-relative paths of the files to add, one per line. A directory adds
# every file inside it; each path must resolve inside the destination.
collect_add_files() {
    local path entry dir absolute real_dest relative
    real_dest="$(cd -P "${DEST}" && pwd)"
    for path in "${add_paths[@]}"; do
        if [[ -L "${path}" ]]; then
            if is_repo_link "${path}"; then
                log_error "Already managed: ${path}"
            else
                log_error "Not adding a symlink: ${path}"
            fi
            return 1
        fi
        if [[ ! -e "${path}" ]]; then
            log_error "No such file: ${path}"
            return 1
        fi
        dir="$(cd -P "$(dirname "${path}")" && pwd)" || return 1
        absolute="${dir}/$(basename "${path}")"
        if [[ "${absolute}" != "${real_dest}/"* ]]; then
            log_error "Not inside ${DEST}: ${path}"
            return 1
        fi
        relative="${absolute#"${real_dest}"/}"
        if [[ -d "${absolute}" ]]; then
            while IFS= read -r entry; do
                printf '%s/%s\n' "${relative}" "${entry#./}"
            done < <(cd "${absolute}" && find . -type f ! -name .DS_Store -print)
        elif [[ -f "${absolute}" ]]; then
            printf '%s\n' "${relative}"
        else
            log_error "Not a regular file: ${path}"
            return 1
        fi
    done
}

add_files() {
    local package kind=stow relative source reason refused=0 files
    local -a relatives=()

    files="$(collect_add_files)" || exit 1
    while IFS= read -r relative; do
        [[ -n "${relative}" ]] && relatives+=("${relative}")
    done < <(printf '%s\n' "${files}" | LC_ALL=C sort -u)
    if [[ "${#relatives[@]}" -eq 0 ]]; then
        log_error "No files to add"
        exit 1
    fi
    for relative in "${relatives[@]}"; do
        reason="$(add_refusal "${relative}" "${DEST}/${relative}")"
        if [[ -n "${reason}" ]]; then
            log_error "Not adding ~/${relative}: ${reason}"
            refused=1
        fi
    done
    [[ "${refused}" -eq 0 ]] || exit 1

    choose_add_layer
    package="${ADD_LAYER}"
    [[ "${ADD_PLATFORM}" -eq 1 ]] && package="${ADD_LAYER}.$(platform)"
    [[ "${ADD_SEED}" -eq 1 ]] && kind=seed

    # Copy everything before linking anything, so a failure leaves every live
    # file where it was.
    for relative in "${relatives[@]}"; do
        source="${REPO}/${kind}/${package}/${relative}"
        if [[ "${DRY_RUN}" -eq 1 ]]; then
            printf 'Would copy ~/%s to %s\n' "${relative}" "${kind}/${package}/${relative}"
            continue
        fi
        mkdir -p "$(dirname "${source}")"
        cp -p "${DEST}/${relative}" "${source}"
        printf 'Copied ~/%s to %s\n' "${relative}" "${kind}/${package}/${relative}"
    done
    [[ "${DRY_RUN}" -eq 0 ]] || return 0

    # The live files now match the repo, so linking swaps them for links
    # without a backup. Seed files stay as they are; the app owns them.
    if [[ "${kind}" == stow ]]; then
        run_stow
        secure_private_dirs
    fi
    printf 'Added %d file(s). Commit them with: git -C %s add %s\n' \
        "${#relatives[@]}" "${REPO}" "${kind}/${package}"
}

main() {
    local entry
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

    if [[ "${COMMAND}" == personas ]]; then
        list_personas
        return 0
    fi
    load_persona

    case "${COMMAND}" in
        persona) printf '%s %s\n' "${PERSONA_NAME:-none}" "${PERSONA_SOURCE:-legacy}" ;;
        installs)
            printf 'brew=%s\nbrew_optional=%s\nlinux_optional=%s\n' \
                "${PERSONA_BREW}" "${PERSONA_BREW_OPTIONAL}" "${PERSONA_LINUX_OPTIONAL}"
            ;;
        managed) print_managed ;;
        status) print_status ;;
        add) add_files ;;
        apply)
            if [[ "${PERSONA_SOURCE}" == default ]]; then
                log_warn "No persona chosen; linking as '${PERSONA_NAME}', the default for $(platform). Pick one with: install.sh --persona NAME"
            fi
            save_persona
            prune_stale_links
            run_stow
            link_editors
            if [[ "${PERSONA_AGENTS}" == yes ]]; then
                sync_agents_repo
                link_agents
                link_skills
            else
                warn_unused_agents_checkout
            fi
            copy_seeds
            secure_private_dirs
            [[ "${DRY_RUN}" -eq 1 ]] || warn_git_identity
            ;;
    esac
}

main "$@"

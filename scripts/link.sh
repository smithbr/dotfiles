#!/usr/bin/env bash
# Link the dotfiles into place with GNU Stow, and report what the repo owns.
#
#   personas/<name>         which layers, editors, agents and installs a machine
#                           gets: key=value lines for os, layers, agents,
#                           editors, brew, brew_optional, linux_optional.
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
#                           fills from the agents repo's skills/ bundles. Only
#                           core is stowed here; skill-import adds more locally.
#   CLAUDE_SETTINGS         a real file, not a link: Claude Code and other apps
#                           rewrite it. The agents repo's tools/claude/settings
#                           files are merged into it, and what the last merge
#                           applied is kept so dropped entries are removed too.
#
# A persona without agents gets none of these: its agent links are removed as
# stale, the merged settings are taken back out, and a leftover checkout is
# reported but never deleted.
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

# Relative to $HOME. The managed settings are tools/claude/settings.json in the
# agents checkout.
CLAUDE_SETTINGS=".claude/settings.json"
CLAUDE_SETTINGS_STATE=".local/state/dotfiles/claude-settings.json"

# sync(live; new; prev) applies the managed settings `new` to `live`, where
# `prev` is what the last run applied. Managed scalars win; arrays keep their
# live entries and gain the managed ones; whatever `prev` managed and `new` no
# longer does is removed, unless the live value has changed since. A null
# `new` takes everything `prev` applied back out.
# shellcheck disable=SC2016
SETTINGS_SYNC_JQ='
def sync($live; $new; $prev):
    if $new == null then
        if ($live | type) == "object" and ($prev | type) == "object" then
            reduce ($live | keys_unsorted[]) as $k ({};
                if ($prev | has($k)) then
                    sync($live[$k]; null; $prev[$k]) as $v
                    | if $v == null then . else .[$k] = $v end
                else .[$k] = $live[$k] end)
            | if . == {} then null else . end
        elif ($live | type) == "array" and ($prev | type) == "array" then
            ($live - $prev) | if . == [] then null else . end
        elif $live == $prev then null
        else $live end
    elif ($new | type) == "object" then
        ($live | if type == "object" then . else {} end) as $l
        | ($prev | if type == "object" then . else {} end) as $p
        | reduce (($l + $new + $p) | keys_unsorted[]) as $k ({};
            if ($new | has($k)) then .[$k] = sync($l[$k]; $new[$k]; $p[$k])
            elif ($l | has($k)) then
                sync($l[$k]; null; $p[$k]) as $v
                | if $v == null then . else .[$k] = $v end
            else . end)
    elif ($new | type) == "array" then
        ($live | if type == "array" then . else [] end) as $l
        | ($prev | if type == "array" then . else [] end) as $p
        | ($l - ($p - $new)) + ($new - $l)
    else $new end;
'

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
PRIVATE_DIRS=(.ssh .claude .config/glow)

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
    local name="" source file setting key value saved
    if [[ ! -d "${REPO}/personas" ]]; then
        PERSONA_LAYERS="common $(platform)"
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
    for entry in "${AGENT_LINKS[@]}" "${SKILL_LINKS[@]}" "${CLAUDE_SETTINGS}"; do
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
        wanted="$(printf '%s\n' "${AGENT_LINKS[@]%%|*}" "${SKILL_LINKS[@]}")"
    fi
    while IFS= read -r target; do
        is_agent_link "${target}" || continue
        if [[ -n "${wanted}" ]] && grep -Fxq -- "${target#"${DEST}"/}" <<< "${wanted}"; then
            continue
        fi
        printf '%s\n' "${target}"
    done < <(agent_link_candidates | LC_ALL=C sort)
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

# ~/.agents/skills is machine-local: Stow links the core bundle into it, and
# skill-import links more. The old layout linked it to the whole library.
link_skills() {
    local skills="${DEST}/${SKILLS_DIR}" bundles="${DEST}/.config/agents/skills"
    local relative target

    [[ -d "${bundles}/core" ]] || return 0
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        printf 'Would stow skill bundle core into %s\n' "${skills}"
        return 0
    fi

    [[ -L "${skills}" ]] && rm "${skills}"
    mkdir -p "${skills}"
    if ! stow --dir "${bundles}" --target "${skills}" --restow --ignore '\.DS_Store' core; then
        log_warn "Could not stow the core skills into ${skills}; resolve the conflict above and rerun"
    fi

    for relative in "${SKILL_LINKS[@]}"; do
        target="${DEST}/${relative}"
        [[ -L "${target}" && "$(readlink "${target}")" == "${skills}" ]] && continue
        if [[ -e "${target}" && ! -L "${target}" ]]; then
            backup_path "${target}"
        fi
        mkdir -p "$(dirname "${target}")"
        ln -sfn "${skills}" "${target}"
    done
}

# The managed Claude settings.
wanted_claude_settings() {
    jq . "${DEST}/.config/agents/tools/claude/settings.json"
}

# Print live settings with `new` applied and `prev` retired. live and prev are
# files (/dev/null when absent); new is JSON text, or null to retire it all.
sync_settings() {
    local live="$1" new="$2" prev="$3"
    jq -n --indent 4 --slurpfile live "${live}" --argjson new "${new}" --slurpfile prev "${prev}" \
        "${SETTINGS_SYNC_JQ} sync(\$live[0]; \$new; \$prev[0]) // {}"
}

same_json() {
    [[ "$(jq -S . "$1")" == "$(jq -S . <<< "$2")" ]]
}

# Replace a file's content in one rename, keeping it private.
write_private_file() {
    local target="$1" content="$2" tmp
    mkdir -p "$(dirname "${target}")"
    tmp="$(mktemp "${target}.XXXXXX")"
    printf '%s\n' "${content}" > "${tmp}"
    chmod 600 "${tmp}"
    mv "${tmp}" "${target}"
}

# Merge the managed settings into the real ~/.claude/settings.json. Keys apps
# add (plugins, their own hooks) survive; managed values are restored. The old
# link into the checkout is already gone by now: prune_stale_links removed it.
apply_claude_settings() {
    local target="${DEST}/${CLAUDE_SETTINGS}" state="${DEST}/${CLAUDE_SETTINGS_STATE}"
    local live=/dev/null prev=/dev/null wanted merged

    [[ -f "${DEST}/.config/agents/tools/claude/settings.json" ]] || return 0
    if ! command -v jq >/dev/null 2>&1; then
        log_warn "jq is not installed; skipping ${target}"
        return 0
    fi
    if ! wanted="$(wanted_claude_settings)"; then
        log_warn "Could not read the Claude settings in ${DEST}/.config/agents/tools/claude; skipping ${target}"
        return 0
    fi
    [[ -f "${state}" ]] && prev="${state}"

    if [[ -L "${target}" ]]; then
        if [[ "${DRY_RUN}" -eq 1 ]]; then
            is_agent_link "${target}" || printf 'Would back up %s before writing settings\n' "${target}"
        else
            backup_path "${target}"
        fi
    elif [[ -f "${target}" ]]; then
        if jq empty "${target}" 2>/dev/null; then
            live="${target}"
        elif [[ "${DRY_RUN}" -eq 1 ]]; then
            printf 'Would back up %s (not valid JSON) before writing settings\n' "${target}"
        else
            log_warn "${target} is not valid JSON; moving it aside"
            backup_path "${target}"
        fi
    fi

    merged="$(sync_settings "${live}" "${wanted}" "${prev}")"
    if [[ "${live}" != /dev/null ]] && same_json "${live}" "${merged}"; then
        [[ "${DRY_RUN}" -eq 1 ]] || write_private_file "${state}" "${wanted}"
        return 0
    fi
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        printf 'Would merge the managed Claude settings into %s\n' "${target}"
        return 0
    fi
    [[ "${live}" != /dev/null ]] && backup_path "${target}"
    write_private_file "${target}" "${merged}"
    write_private_file "${state}" "${wanted}"
    printf 'Merged the managed Claude settings into %s\n' "${target}"
}

# A persona without agents: take back out what apply_claude_settings merged
# in, leaving what apps wrote.
remove_claude_settings() {
    local target="${DEST}/${CLAUDE_SETTINGS}" state="${DEST}/${CLAUDE_SETTINGS_STATE}" merged

    [[ -f "${state}" ]] || return 0
    if ! command -v jq >/dev/null 2>&1; then
        log_warn "jq is not installed; leaving the managed settings in ${target}"
        return 0
    fi
    if [[ -f "${target}" && ! -L "${target}" ]] && jq empty "${target}" 2>/dev/null; then
        merged="$(sync_settings "${target}" null "${state}")"
        if ! same_json "${target}" "${merged}"; then
            if [[ "${DRY_RUN}" -eq 1 ]]; then
                printf 'Would remove the managed Claude settings from %s\n' "${target}"
                return 0
            fi
            backup_path "${target}"
            write_private_file "${target}" "${merged}"
            printf 'Removed the managed Claude settings from %s\n' "${target}"
        fi
    fi
    [[ "${DRY_RUN}" -eq 1 ]] || rm -f "${state}"
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
    for entry in "${AGENT_LINKS[@]}" "${SKILL_LINKS[@]}" "${CLAUDE_SETTINGS}"; do
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
        for entry in "${SKILL_LINKS[@]}"; do
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
        print_claude_settings_state
    elif [[ -e "${DEST}/.config/agents" ]]; then
        printf 'unused %s\n' "${DEST}/.config/agents"
    fi

    while IFS= read -r target; do
        printf 'stale %s\n' "${target}"
    done < <(stale_links)
}

# missing, foreign (a link other than the old one into the checkout, which is
# reported as stale), or drifted (the next run would change it). Needs jq and
# the checkout to say anything.
print_claude_settings_state() {
    local target="${DEST}/${CLAUDE_SETTINGS}" state="${DEST}/${CLAUDE_SETTINGS_STATE}"
    local prev=/dev/null wanted
    [[ -f "${DEST}/.config/agents/tools/claude/settings.json" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    if [[ -L "${target}" ]]; then
        is_agent_link "${target}" || printf 'foreign %s\n' "${target}"
        return 0
    elif [[ ! -e "${target}" ]]; then
        printf 'missing %s\n' "${target}"
        return 0
    fi
    [[ -f "${state}" ]] && prev="${state}"
    if ! jq empty "${target}" 2>/dev/null \
        || ! wanted="$(wanted_claude_settings 2>/dev/null)" \
        || ! same_json "${target}" "$(sync_settings "${target}" "${wanted}" "${prev}")"; then
        printf 'drifted %s\n' "${target}"
    fi
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
    esac
    for entry in "${AGENT_LINKS[@]}" "${SKILL_LINKS[@]}" "${CLAUDE_SETTINGS}"; do
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
                apply_claude_settings
            else
                remove_claude_settings
                warn_unused_agents_checkout
            fi
            copy_seeds
            secure_private_dirs
            ;;
    esac
}

main "$@"

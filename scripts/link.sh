#!/usr/bin/env bash
# Link the dotfiles into place with GNU Stow, and report what the repo owns.
#
#   personas/<name>         which layers, editors, agents and installs a machine
#                           gets: key=value lines for os, layers, agents,
#                           agent_apps, skills, editors, brew, brew_optional,
#                           roles (on by default), roles_optional (offered), and
#                           harden (yes: install.sh offers harden.sh first on a
#                           Linux box that harden-test.sh finds unhardened).
#   roles/<name>            what a machine is for (a Pi-hole, a hardened VPS):
#                           key=value lines for os, layers, brew, requires
#                           (installs run first), detect (a command that
#                           succeeds once the role is applied) and setup (the
#                           script install.sh runs, named after the role when
#                           unset). A role's layers link like the persona's own.
#   scripts/bootstrap/<os>/<name>.sh, scripts/bootstrap/<name>.sh
#                           a setup script with a "# detect: COMMAND" line is an
#                           optional install (Docker, Tailscale, Claude Code),
#                           offered to every persona and on by default. The
#                           chosen installs come from DOTFILES_INSTALLS, else the
#                           saved choice, else what is on by default.
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
REMOVE_DELETE=0
MOVE_NO_PLATFORM=0
declare -a path_args=()
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
  personas  List the personas this OS can use
  offered   List the installs offered here (the optional installs, then the
            persona's roles), one NAME<TAB>default|optional<TAB>DETECT line each
  installs  Print the persona's brew and brew_optional lists, its harden
            setting, the chosen installs in run order, and one
            install=NAME<TAB>SETUP<TAB>DETECT line each
  add PATH...
            Start managing files from the home directory: copy each one into
            a layer, then link it (a directory adds every file in it)
  rm PATH...
            Stop managing linked files: replace each link with a real copy
            of its repo file and git rm that file (a directory removes every
            managed link in it)
  mv PATH...
            Move linked files to another layer: git mv each repo file there,
            then relink it (a directory moves every managed link in it)

Options:
  -n, --dry-run           Report what would change without touching anything
      --persona NAME      Link as this persona (see personas/); a real apply
                          saves it for later runs
      --refresh           Pull the agents checkout even if it is fresh
      --repo PATH         Dotfiles repo to read (default: this script's repo)
      --destination PATH  Home directory to link into (default: $HOME)
      --layer NAME        add, mv: the layer to put the files in (asked on
                          a terminal when missing)
      --platform          add, mv: use the layer's part for this OS only
                          (stow/<layer>.<os>)
      --no-platform       mv: use the layer itself, not its part for this OS
                          (mv keeps the files' current choice otherwise)
      --seed              add: copy once as a seed file the app then owns,
                          instead of linking
      --delete            rm: drop the files from the home directory too,
                          moving them to ~/.local/state/dotfiles/cleanup/
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
            --delete) REMOVE_DELETE=1 ;;
            --no-platform) MOVE_NO_PLATFORM=1 ;;
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
            apply|managed|status|persona|personas|offered|installs|add|rm|mv) COMMAND="$1" ;;
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
                if [[ "${COMMAND}" != add && "${COMMAND}" != rm && "${COMMAND}" != mv ]]; then
                    log_error "Unknown argument: $1"
                    usage >&2
                    exit 2
                fi
                path_args+=("$1")
                ;;
        esac
        shift
    done

    if [[ ( "${COMMAND}" == add || "${COMMAND}" == rm || "${COMMAND}" == mv ) && "${#path_args[@]}" -eq 0 ]]; then
        log_error "${COMMAND} needs at least one path"
        exit 2
    fi
    if [[ "${COMMAND}" != add && "${COMMAND}" != mv && ( -n "${ADD_LAYER}" || "${ADD_PLATFORM}" -eq 1 ) ]]; then
        log_error "--layer and --platform only apply to add and mv"
        exit 2
    fi
    if [[ "${COMMAND}" != add && "${ADD_SEED}" -eq 1 ]]; then
        log_error "--seed only applies to add"
        exit 2
    fi
    if [[ "${COMMAND}" != mv && "${MOVE_NO_PLATFORM}" -eq 1 ]]; then
        log_error "--no-platform only applies to mv"
        exit 2
    fi
    if [[ "${ADD_PLATFORM}" -eq 1 && "${MOVE_NO_PLATFORM}" -eq 1 ]]; then
        log_error "--platform and --no-platform contradict each other"
        exit 2
    fi
    if [[ "${COMMAND}" != rm && "${REMOVE_DELETE}" -eq 1 ]]; then
        log_error "--delete only applies to rm"
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

# The persona in effect, set by load_persona.
PERSONA_NAME=""
PERSONA_SOURCE=""
PERSONA_LAYERS=""
PERSONA_AGENTS=yes
PERSONA_EDITORS=yes
PERSONA_AGENT_APPS="${AGENT_APPS}"
PERSONA_SKILLS=core
PERSONA_HARDEN=no
# Installs, for install.sh: Brewfiles installed in full, Brewfiles offered in
# the macOS picker, and the roles on by default or offered.
PERSONA_BREW=""
PERSONA_BREW_OPTIONAL=""
PERSONA_ROLES=""
PERSONA_ROLES_OPTIONAL=""
# The chosen installs in run order, set by load_installs, and where they came
# from.
INSTALLS=""
INSTALLS_SOURCE=""

state_dir() {
    printf '%s/.local/state/dotfiles\n' "${DEST}"
}

persona_state_file() {
    printf '%s/persona\n' "$(state_dir)"
}

installs_state_file() {
    printf '%s/installs\n' "$(state_dir)"
}

# True when no directory between $DEST and PATH (PATH included) is a symlink,
# so writing under PATH cannot land in someone else's tree.
no_symlinked_parents() {
    local path="$1" step="${DEST}" part
    local -a parts=()
    IFS=/ read -r -a parts <<< "${path#"${DEST}"/}"
    for part in "${parts[@]}"; do
        step="${step}/${part}"
        [[ -L "${step}" ]] && { printf '%s\n' "${step}"; return 1; }
    done
    return 0
}

default_persona() {
    case "$(platform)" in
        darwin) printf 'home\n' ;;
        *) printf 'server\n' ;;
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
    local file
    [[ -d "${REPO}/personas" ]] || return 0
    for file in "${REPO}/personas"/*; do
        [[ -f "${file}" ]] || continue
        persona_allows_platform "${file}" || continue
        basename "${file}"
    done
}

load_persona() {
    local name="" source file setting key value saved app bundle role
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
        log_error "Unknown persona '${name}'. Choose one of: $(list_personas | tr '\n' ' ')"
        exit 2
    fi
    if ! persona_allows_platform "${file}"; then
        log_error "Persona '${name}' is not for $(platform). Choose one of: $(list_personas | tr '\n' ' ')"
        exit 2
    fi

    PERSONA_NAME="${name}"
    PERSONA_SOURCE="${source}"
    while IFS= read -r setting; do
        key="${setting%%=*}"
        value="${setting#*=}"
        case "${key}" in
            os) ;;
            layers) PERSONA_LAYERS="${value}" ;;
            brew) PERSONA_BREW="${value}" ;;
            brew_optional) PERSONA_BREW_OPTIONAL="${value}" ;;
            roles|roles_optional)
                for role in ${value}; do
                    if [[ ! "${role}" =~ ^[a-z][a-z0-9-]*$ || ! -f "${REPO}/roles/${role}" ]]; then
                        log_error "${file}: no roles/${role} for ${key}"
                        exit 2
                    fi
                done
                if [[ "${key}" == roles ]]; then PERSONA_ROLES="${value}"; else PERSONA_ROLES_OPTIONAL="${value}"; fi
                ;;
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
            agents|editors|harden)
                if [[ "${value}" != yes && "${value}" != no ]]; then
                    log_error "${file}: ${key} must be yes or no, not '${value}'"
                    exit 2
                fi
                case "${key}" in
                    agents) PERSONA_AGENTS="${value}" ;;
                    editors) PERSONA_EDITORS="${value}" ;;
                    harden) PERSONA_HARDEN="${value}" ;;
                esac
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
    if ! parent="$(no_symlinked_parents "${file}")"; then
        log_error "Persona state path is a symlink: ${parent}; not saving the persona"
        return 1
    fi
    (umask 077 && mkdir -p "$(dirname "${file}")" && printf '%s\n' "${PERSONA_NAME}" > "${file}")
    printf 'Saved persona %s\n' "${PERSONA_NAME}"
}

# This platform's own directory of setup scripts.
bootstrap_dir() {
    case "$(platform)" in
        darwin) printf '%s/scripts/bootstrap/macos\n' "${REPO}" ;;
        *) printf '%s/scripts/bootstrap/%s\n' "${REPO}" "$(platform)" ;;
    esac
}

# The setup script NAME.sh for this platform: the platform's directory first,
# then the shared one.
setup_script() {
    local name="$1" dir
    for dir in "$(bootstrap_dir)" "${REPO}/scripts/bootstrap"; do
        if [[ -f "${dir}/${name}.sh" ]]; then
            printf '%s\n' "${dir}/${name}.sh"
            return 0
        fi
    done
    return 1
}

# The optional installs: the setup scripts for this platform that carry a
# "# detect:" line, offered to every persona and on by default. The platform's
# own directory first, then the shared one, each in name order.
optional_installs() {
    local dir script name seen=""
    for dir in "$(bootstrap_dir)" "${REPO}/scripts/bootstrap"; do
        for script in "${dir}"/*.sh; do
            [[ -f "${script}" ]] || continue
            grep -q '^# detect: ' "${script}" || continue
            name="$(basename "${script}" .sh)"
            [[ " ${seen} " != *" ${name} "* ]] || continue
            seen="${seen} ${name}"
            printf '%s\n' "${name}"
        done
    done
}

# True when NAME is a role or an optional install this platform has. The
# list is read whole: grep -q quitting early would end the pipeline in
# SIGPIPE, which pipefail reports as no match.
install_exists() {
    local file="${REPO}/roles/$1"
    if [[ -f "${file}" ]]; then
        persona_allows_platform "${file}"
    else
        grep -qxF "$1" <<< "$(optional_installs)"
    fi
}

# One setting of an install: from roles/NAME, where setup is the role's own
# name when unset, or for an optional install from its script, which declares
# only detect.
install_setting() {
    local name="$1" key="$2" value="" script
    if [[ -f "${REPO}/roles/${name}" ]]; then
        value="$(persona_settings "${REPO}/roles/${name}" | sed -n "s/^${key}=//p" | tail -n 1)"
    elif [[ "${key}" == detect ]] && script="$(setup_script "${name}")"; then
        value="$(sed -n 's/^# detect: //p' "${script}" | head -n 1)"
    fi
    [[ -n "${value}" || "${key}" != setup ]] || value="${name}"
    printf '%s\n' "${value}"
}

# What is offered on this platform, as NAME<TAB>default|optional<TAB>DETECT:
# the optional installs, then the persona's roles in its order.
offered_installs() {
    local name
    for name in $(optional_installs); do
        printf '%s\tdefault\t%s\n' "${name}" "$(install_setting "${name}" detect)"
    done
    for name in ${PERSONA_ROLES}; do
        persona_allows_platform "${REPO}/roles/${name}" || continue
        printf '%s\tdefault\t%s\n' "${name}" "$(install_setting "${name}" detect)"
    done
    for name in ${PERSONA_ROLES_OPTIONAL}; do
        persona_allows_platform "${REPO}/roles/${name}" || continue
        printf '%s\toptional\t%s\n' "${name}" "$(install_setting "${name}" detect)"
    done
    return 0
}

# Append NAME to ORDERED after what it requires, which joins even when not
# chosen; a requirement must be a role or an optional install this platform
# has.
visit_install() {
    local name="$1" depth="${2:-0}" required
    [[ " ${ORDERED} " != *" ${name} "* ]] || return 0
    if [[ "${depth}" -gt 10 ]]; then
        log_error "roles/${name}: requires chain too deep (a cycle?)"
        exit 2
    fi
    for required in $(install_setting "${name}" requires); do
        if ! install_exists "${required}"; then
            log_error "roles/${name} requires '${required}', which neither roles/ nor scripts/bootstrap/ has for $(platform)"
            exit 2
        fi
        visit_install "${required}" $((depth + 1))
    done
    ORDERED="${ORDERED} ${name}"
}

# The chosen installs: DOTFILES_INSTALLS (set, maybe empty), else the saved
# choice, else what is on by default. Each must be offered here; a saved one
# no longer offered (a persona switch) is dropped with a warning. A role's
# layers link like the persona's own.
load_installs() {
    local saved name offered kept=""
    if [[ -n "${DOTFILES_INSTALLS+x}" ]]; then
        INSTALLS="${DOTFILES_INSTALLS}" INSTALLS_SOURCE=env
    else
        saved="$(installs_state_file)"
        if [[ -f "${saved}" && ! -L "${saved}" ]]; then
            IFS= read -r INSTALLS < "${saved}" || true
            INSTALLS_SOURCE=saved
        else
            INSTALLS="$(offered_installs | awk -F'\t' '$2 == "default" { print $1 }' | tr '\n' ' ')" INSTALLS_SOURCE=default
        fi
    fi
    offered="$(offered_installs | cut -f1)"
    for name in ${INSTALLS}; do
        if grep -qxF "${name}" <<< "${offered}"; then
            kept="${kept} ${name}"
        elif [[ "${INSTALLS_SOURCE}" == saved ]]; then
            log_warn "Persona '${PERSONA_NAME}' does not offer the saved install '${name}' on $(platform); dropping it"
        else
            log_error "Persona '${PERSONA_NAME}' does not offer install '${name}' on $(platform). Choose from: $(tr '\n' ' ' <<< "${offered}")"
            exit 2
        fi
    done
    ORDERED=""
    for name in ${kept}; do
        visit_install "${name}"
    done
    INSTALLS="${ORDERED# }"
    for name in ${INSTALLS}; do
        PERSONA_LAYERS="${PERSONA_LAYERS} $(install_setting "${name}" layers)"
    done
}

# Remember installs chosen through DOTFILES_INSTALLS (install.sh sets it after
# its questions), like the persona.
save_installs() {
    local file parent
    [[ "${INSTALLS_SOURCE}" == env ]] || return 0
    [[ "${DRY_RUN}" -eq 0 ]] || return 0
    file="$(installs_state_file)"
    if [[ -f "${file}" && ! -L "${file}" && "$(cat "${file}")" == "${INSTALLS}" ]]; then
        return 0
    fi
    if ! parent="$(no_symlinked_parents "${file}")"; then
        log_error "Installs state path is a symlink: ${parent}; not saving the installs"
        return 1
    fi
    (umask 077 && mkdir -p "$(dirname "${file}")" && printf '%s\n' "${INSTALLS}" > "${file}")
    printf 'Saved installs %s\n' "${INSTALLS:-none}"
}

# The Brewfiles the persona and its roles install in full, deduplicated.
brewfiles() {
    local role name list="${PERSONA_BREW}"
    for role in ${INSTALLS}; do
        for name in $(install_setting "${role}" brew); do
            [[ " ${list} " == *" ${name} "* ]] || list="${list} ${name}"
        done
    done
    printf '%s\n' "${list# }"
}

# A persona layer with no stow/<layer> or stow/<layer>.<os> directory on any
# OS links nothing; say so rather than skip it quietly.
warn_missing_layers() {
    local layer dir found
    for layer in ${PERSONA_LAYERS}; do
        found=0
        for dir in "${REPO}/stow/${layer}" "${REPO}/stow/${layer}".*; do
            [[ -d "${dir}" ]] && found=1
        done
        [[ "${found}" -eq 1 ]] || log_warn "Persona '${PERSONA_NAME}' lists layer '${layer}', which has no directory under stow/"
    done
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

# package|relative for every file in every package of one kind. Each listing
# is captured before it is printed: a child exiting mid-write can interrupt
# printf on a full pipe, and bash drops the line.
package_entries() {
    local kind="$1" package relative files
    for package in $(packages_in "${kind}"); do
        files="$(package_files "${kind}" "${package}")"
        [[ -n "${files}" ]] || continue
        while IFS= read -r relative; do
            printf '%s|%s\n' "${package}" "${relative}"
        done <<< "${files}"
    done
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
    local entry
    while IFS= read -r entry; do
        printf '%s\n' "${entry#*|}"
    done < <(package_entries stow)
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
    backup_dir="${BACKUP_DIR:-$(state_dir)/clobbered/$(date +%Y%m%d-%H%M%S)}"
    if ! parent="$(no_symlinked_parents "${backup_dir}")"; then
        log_error "Backup parent is a symlink: ${parent}; not moving ${target}"
        return 1
    fi
    BACKUP_DIR="${backup_dir}"
    (umask 077 && mkdir -p "$(dirname "${BACKUP_DIR}/${relative}")")
    chmod 700 "${BACKUP_DIR}"
    mv "${target}" "${BACKUP_DIR}/${relative}"
    printf 'Backed up %s -> %s\n' "${target}" "${BACKUP_DIR}/${relative}"
}

# Clear real files and foreign links out of stow's way. BLOCKED counts the
# paths that still block stow, which is always 0 unless this is a dry run.
BLOCKED=0
# Make room for a link at TARGET to SOURCE. Nothing to do when it is absent
# or already that link; our own link elsewhere (the file moved between
# packages) and an identical copy go quietly; anything else is backed up. A
# dry run reports instead and returns 1.
clear_target() {
    local target="$1" source="$2" would=""
    [[ -e "${target}" || -L "${target}" ]] || return 0
    is_linked "${target}" "${source}" && return 0

    if is_repo_link "${target}"; then
        would="Would relink ${target}"
    elif [[ -f "${target}" && ! -L "${target}" ]] && cmp -s "${target}" "${source}"; then
        would="Would replace identical copy ${target} with a link"
    else
        would="Would back up ${target} before linking"
    fi
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        printf '%s\n' "${would}"
        BLOCKED=$((BLOCKED + 1))
        return 1
    fi
    if [[ "${would}" == "Would back up"* ]]; then
        backup_path "${target}"
    else
        rm -f "${target}"
    fi
}

# Link TARGET to SOURCE after clearing whatever is there.
place_link() {
    local target="$1" source="$2"
    is_linked "${target}" "${source}" && return 0
    clear_target "${target}" "${source}" || return 0
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        printf 'Would link %s -> %s\n' "${target}" "${source}"
        return 0
    fi
    mkdir -p "$(dirname "${target}")"
    ln -sfn "${source}" "${target}"
}

clear_conflicts() {
    local entry
    while IFS= read -r entry; do
        clear_target "${DEST}/${entry#*|}" "${REPO}/stow/${entry%%|*}/${entry#*|}" || true
    done < <(package_entries stow)
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

# A real file or directory where an agent link belongs is usually config an
# agent CLI wrote on its first run; place_link keeps it recoverable.
link_agents() {
    local entry
    for entry in ${WANTED_AGENT_LINKS[@]+"${WANTED_AGENT_LINKS[@]}"}; do
        place_link "${DEST}/${entry%%|*}" "${DEST}/.config/agents/${entry#*|}"
    done
}

# ~/.agents/skills is machine-local: Stow links the persona's skill bundles
# into it, and skills-add links more.
link_skills() {
    local skills="${DEST}/${SKILLS_DIR}" bundles="${DEST}/.config/agents/skills"
    local relative target bundle
    local -a wanted=()

    [[ -d "${bundles}/core" ]] || return 0
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

    mkdir -p "${skills}"
    if [[ "${#wanted[@]}" -gt 0 ]] && ! stow --dir "${bundles}" --target "${skills}" --restow --ignore '\.DS_Store' "${wanted[@]}"; then
        log_warn "Could not stow the skill bundles ${wanted[*]} into ${skills}; resolve the conflict above and rerun"
    fi

    for relative in ${WANTED_SKILL_LINKS[@]+"${WANTED_SKILL_LINKS[@]}"}; do
        place_link "${DEST}/${relative}" "${skills}"
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
# else is backed up first.
link_editors() {
    local entry
    while IFS= read -r entry; do
        place_link "${DEST}/${entry%%|*}" "${entry#*|}"
    done < <(editor_links)
}

copy_seeds() {
    local entry target
    while IFS= read -r entry; do
        target="${DEST}/${entry#*|}"
        [[ -e "${target}" || -L "${target}" ]] && continue
        if [[ "${DRY_RUN}" -eq 1 ]]; then
            printf 'Would create %s\n' "${target}"
            continue
        fi
        mkdir -p "$(dirname "${target}")"
        cp "${REPO}/seed/${entry%%|*}/${entry#*|}" "${target}"
        chmod 600 "${target}"
        printf 'Created %s\n' "${target}"
    done < <(package_entries seed)
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
# files, such as ~/.local/bin/cf-cert on work. Each is the shallowest path no other
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
    local kind entry
    for kind in stow seed; do
        while IFS= read -r entry; do
            printf '%s/%s\n' "${DEST}" "${entry#*|}"
        done < <(package_entries "${kind}")
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
        [[ -e "${target}" ]] || printf 'broken %s\n' "${target}"
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
    local target entry
    while IFS= read -r entry; do
        print_link_state "${DEST}/${entry#*|}" "${REPO}/stow/${entry%%|*}/${entry#*|}"
    done < <(package_entries stow)
    while IFS= read -r entry; do
        print_link_state "${DEST}/${entry%%|*}" "${entry#*|}"
    done < <(editor_links)

    if [[ "${PERSONA_AGENTS}" == yes ]]; then
        for entry in ${WANTED_AGENT_LINKS[@]+"${WANTED_AGENT_LINKS[@]}"}; do
            print_link_state "${DEST}/${entry%%|*}" "${DEST}/.config/agents/${entry#*|}"
        done
        target="${DEST}/${SKILLS_DIR}"
        if [[ -L "${target}" || ( -e "${target}" && ! -d "${target}" ) ]]; then
            printf 'replaced %s\n' "${target}"
        elif [[ ! -d "${target}" ]]; then
            printf 'missing %s\n' "${target}"
        fi
        for entry in ${WANTED_SKILL_LINKS[@]+"${WANTED_SKILL_LINKS[@]}"}; do
            print_link_state "${DEST}/${entry}" "${target}"
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

# Who links a layer: the personas whose layers= name it ("every persona" when
# all do), else the roles that bring it. Empty when nothing links it.
layer_owners() {
    local layer="$1" file owners="" total=0 linked=0
    for file in "${REPO}/personas"/*; do
        [[ -f "${file}" ]] || continue
        total=$((total + 1))
        [[ " $(persona_settings "${file}" | sed -n 's/^layers=//p') " == *" ${layer} "* ]] || continue
        linked=$((linked + 1))
        owners="${owners:+${owners}, }$(basename "${file}")"
    done
    [[ "${linked}" -eq 0 || "${linked}" -lt "${total}" ]] || owners="every persona"
    if [[ -z "${owners}" ]]; then
        for file in "${REPO}/roles"/*; do
            [[ -f "${file}" && "$(basename "${file}")" != README.md ]] || continue
            [[ " $(persona_settings "${file}" | sed -n 's/^layers=//p') " == *" ${layer} "* ]] || continue
            owners="${owners:+${owners}, }the $(basename "${file}") role"
        done
    fi
    printf '%s\n' "${owners}"
}

# What a layer holds, read from the tree so nothing is kept by hand: its
# top-level paths (dot-directories one level down, a few script names for
# .local/bin), the personas whose layers= name it (else the role that brings
# it), and the platform when it exists only as a platform part.
#   layer_description LAYER WIDTH
layer_description() {
    local layer="$1" width="$2" dir entry paths="" item owners platform="" file
    local -a entries=() names=()
    for dir in "${REPO}/stow/${layer}" "${REPO}/stow/${layer}.darwin" "${REPO}/stow/${layer}.linux"; do
        [[ -d "${dir}" ]] || continue
        while IFS= read -r entry; do
            [[ -n "${entry}" ]] || continue
            if [[ "${entry}" == .local/bin && -d "${dir}/${entry}" ]]; then
                names=()
                while IFS= read -r file && [[ "${#names[@]}" -lt 3 ]]; do
                    names+=("${file}")
                done < <(find "${dir}/${entry}" -mindepth 1 -maxdepth 1 -type f ! -name .DS_Store -exec basename {} \; | LC_ALL=C sort)
                [[ "$(find "${dir}/${entry}" -mindepth 1 -maxdepth 1 -type f ! -name .DS_Store | wc -l)" -le 3 ]] || names+=(...)
                [[ "${#names[@]}" -eq 0 ]] || entry="${entry}: $(IFS=,; printf '%s' "${names[*]}")" entry="${entry//,/, }"
            fi
            entries+=("${entry}")
        done < <({ find "${dir}" -mindepth 1 -maxdepth 1 -type f ! -name .DS_Store; find "${dir}" -mindepth 2 -maxdepth 2 ! -name .DS_Store; } | sed "s|^${dir}/||" | LC_ALL=C sort -u)
    done
    for item in "${entries[@]+"${entries[@]}"}"; do
        if [[ -n "${paths}" && "$(( ${#paths} + ${#item} ))" -gt 56 ]]; then
            paths="${paths}, ..."
            break
        fi
        paths="${paths:+${paths}, }${item}"
    done

    owners="$(layer_owners "${layer}")"
    if [[ ! -d "${REPO}/stow/${layer}" ]]; then
        if [[ -d "${REPO}/stow/${layer}.darwin" && ! -d "${REPO}/stow/${layer}.linux" ]]; then
            platform="macOS only"
        elif [[ -d "${REPO}/stow/${layer}.linux" && ! -d "${REPO}/stow/${layer}.darwin" ]]; then
            platform="Linux only"
        fi
    fi
    printf '%-*s  %s (%s%s)' "${width}" "${layer}" "${paths:-nothing yet}" "${owners:-no persona}" "${platform:+; ${platform}}"
}

# Pick the layer for add or mv: --layer, else a choice on a terminal titled
# $1, each layer described from the tree. Only layers this persona links
# qualify, so the files stay linked right here.
choose_add_layer() {
    local title="${1:-Layer for the new files}" layer width=0
    local -a layers=() choices=()
    read -r -a layers <<< "${PERSONA_LAYERS}"

    if [[ -n "${ADD_LAYER}" ]]; then
        for layer in "${layers[@]}"; do
            [[ "${layer}" == "${ADD_LAYER}" ]] && return 0
        done
        log_error "Persona '${PERSONA_NAME}' does not link layer '${ADD_LAYER}' (linked by $(layer_owners "${ADD_LAYER}" | sed 's/^$/no persona/')). Choose one of: ${PERSONA_LAYERS}"
        exit 2
    fi
    if [[ ! -t 0 ]]; then
        log_error "Name the layer with --layer (one of: ${PERSONA_LAYERS})"
        exit 2
    fi
    for layer in "${layers[@]}"; do
        [[ "${#layer}" -le "${width}" ]] || width="${#layer}"
    done
    for layer in "${layers[@]}"; do
        choices+=("$(layer_description "${layer}" "${width}")"$'\t'"${layer}")
    done
    ADD_LAYER="$(choose_one "${title}" "" "${choices[@]}")"
    if [[ -z "${ADD_LAYER}" ]]; then
        log_error "No layer chosen; nothing changed"
        exit 1
    fi
}

# Home-relative paths of the files to add, one per line. A directory adds
# every file inside it; each path must resolve inside the destination.
collect_add_files() {
    local path entry dir absolute real_dest relative
    real_dest="$(cd -P "${DEST}" && pwd)"
    for path in "${path_args[@]}"; do
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

# ---------------------------------------------------------------------------
# rm: stop managing files, keeping them in the home directory
# ---------------------------------------------------------------------------

# The repo file a link in the home directory stands for, relative to the repo
# (stow/<package>/...), when it is a regular file there.
stow_link_source() {
    local destination
    is_repo_link "$1" || return 1
    destination="$(link_destination "$1")" || return 1
    [[ "${destination}" == "${REPO}/stow/"*/* && -f "${destination}" && ! -L "${destination}" ]] || return 1
    printf '%s\n' "${destination#"${REPO}"/}"
}

# Why rm and mv will not take a path that is not a link into the repo's stow/.
link_refusal() {
    local path="$1" relative="$2" dir
    if [[ ! -L "${path}" ]]; then
        for dir in "${REPO}"/seed/*/; do
            if [[ -e "${dir}${relative}" ]]; then
                printf 'a seed file, copied once and never linked; delete %s from the repo instead\n' "${dir#"${REPO}"/}${relative}"
                return 0
            fi
        done
        printf 'a real file, not a link into the repo\n'
    elif is_agent_link "${path}"; then
        printf 'links into the private agents repo\n'
    elif ! is_repo_link "${path}"; then
        printf 'links outside the repo\n'
    elif [[ "$(link_destination "${path}")" == "${REPO}/editors/"* ]]; then
        printf 'shared editor settings, kept in editors/\n'
    else
        printf 'its repo file is gone; df-link removes the stale link\n'
    fi
}

# relative|source for each file rm or mv takes: a link into the repo's stow/,
# or every such link under a directory. Every other path is refused, each one
# reported (Not $1 ~/PATH) before any change.
collect_linked_files() {
    local verb="$1" path absolute link source real_dest relative refused=0
    real_dest="$(cd -P "${DEST}" && pwd)"
    for path in "${path_args[@]}"; do
        if [[ ! -e "${path}" && ! -L "${path}" ]]; then
            log_error "No such file: ${path}"
            refused=1
            continue
        fi
        if [[ -d "${path}" && ! -L "${path}" ]]; then
            absolute="$(cd -P "${path}" && pwd)" || return 1
        else
            absolute="$(cd -P "$(dirname "${path}")" && pwd)/$(basename "${path}")" || return 1
        fi
        if [[ "${absolute}" != "${real_dest}/"* ]]; then
            log_error "Not inside ${DEST}: ${path}"
            refused=1
            continue
        fi
        relative="${absolute#"${real_dest}"/}"
        if [[ -d "${absolute}" && ! -L "${absolute}" ]]; then
            while IFS= read -r link; do
                source="$(stow_link_source "${link}")" || continue
                printf '%s|%s\n' "${link#"${real_dest}"/}" "${source}"
            done < <(find "${absolute}" -type l)
        elif source="$(stow_link_source "${absolute}")"; then
            printf '%s|%s\n' "${relative}" "${source}"
        else
            log_error "Not ${verb} ~/${relative}: $(link_refusal "${absolute}" "${relative}")"
            refused=1
        fi
    done
    [[ "${refused}" -eq 0 ]]
}

# A private folder for files rm --delete takes out of the home directory,
# beside the file review's cleanup archives and never reached through a
# symlinked parent.
REMOVE_ARCHIVE=""
remove_archive() {
    local base parent
    [[ -z "${REMOVE_ARCHIVE}" ]] || return 0
    base="$(state_dir)/cleanup"
    if ! parent="$(no_symlinked_parents "${base}")"; then
        log_error "Archive parent is a symlink: ${parent}; nothing removed"
        return 1
    fi
    (umask 077 && mkdir -p "${base}")
    REMOVE_ARCHIVE="${base}/$(date +%Y%m%d-%H%M%S).remove"
    if ! (umask 077 && mkdir "${REMOVE_ARCHIVE}" 2>/dev/null); then
        REMOVE_ARCHIVE="$(mktemp -d "${REMOVE_ARCHIVE}.XXXXXX")"
    fi
}

# True when git tracks a repo-relative path.
repo_tracks() {
    command -v git >/dev/null 2>&1 \
        && git -C "${REPO}" ls-files --error-unmatch -- "$1" >/dev/null 2>&1
}

# Take one file out of the repo: git rm when it is tracked, then the folders
# that leaves empty inside its package.
drop_repo_file() {
    local source="$1"
    if repo_tracks "${source}"; then
        git -C "${REPO}" rm -q -f -- "${source}"
    else
        rm -f "${REPO}/${source}"
    fi
    prune_package_dirs "${source}"
}

# Remove the folders left empty above a repo file (stow/<package>/...) that
# is gone, up to but not including the package itself.
prune_package_dirs() {
    local source="$1" package dir
    package="${source#stow/}"
    package="${REPO}/stow/${package%%/*}"
    dir="$(dirname "${REPO}/${source}")"
    while [[ "${dir}" == "${package}/"* ]]; do
        if [[ -d "${dir}" ]]; then
            rmdir "${dir}" 2>/dev/null || break
        fi
        dir="$(dirname "${dir}")"
    done
}

remove_files() {
    local files entry relative source target tmp
    local -a entries=()

    files="$(collect_linked_files removing)" || exit 1
    while IFS= read -r entry; do
        [[ -n "${entry}" ]] && entries+=("${entry}")
    done < <(printf '%s\n' "${files}" | LC_ALL=C sort -u)
    if [[ "${#entries[@]}" -eq 0 ]]; then
        log_error "No managed files to remove"
        exit 1
    fi

    if [[ "${DRY_RUN}" -eq 1 ]]; then
        for entry in "${entries[@]}"; do
            relative="${entry%%|*}" source="${entry#*|}"
            if [[ "${REMOVE_DELETE}" -eq 1 ]]; then
                printf 'Would move ~/%s to %s/cleanup/ and git rm %s\n' "${relative}" "$(state_dir)" "${source}"
            else
                printf 'Would replace the link ~/%s with a copy of %s and git rm it\n' "${relative}" "${source}"
            fi
        done
        return 0
    fi

    # Every live file is in place (a real copy, or archived) before the repo
    # loses anything, so a failure part way never leaves a dangling link.
    [[ "${REMOVE_DELETE}" -eq 0 ]] || remove_archive || exit 1
    for entry in "${entries[@]}"; do
        relative="${entry%%|*}" source="${entry#*|}" target="${DEST}/${entry%%|*}"
        if [[ "${REMOVE_DELETE}" -eq 1 ]]; then
            (umask 077 && mkdir -p "$(dirname "${REMOVE_ARCHIVE}/${relative}")")
            cp -p "${REPO}/${source}" "${REMOVE_ARCHIVE}/${relative}"
            rm -f "${target}"
            printf 'Moved ~/%s to %s\n' "${relative}" "${REMOVE_ARCHIVE}/${relative}"
        else
            tmp="$(mktemp "$(dirname "${target}")/.df-rm.XXXXXX")"
            if ! cp -p "${REPO}/${source}" "${tmp}" || ! mv -f "${tmp}" "${target}"; then
                rm -f "${tmp}"
                log_error "Could not replace the link ~/${relative}; it is left in place"
                exit 1
            fi
            printf 'Kept ~/%s as a real file\n' "${relative}"
        fi
    done
    for entry in "${entries[@]}"; do
        drop_repo_file "${entry#*|}"
        printf 'Removed %s from the repo\n' "${entry#*|}"
    done

    printf 'Removed %d file(s) from the repo. Commit with: git -C %s commit\n' "${#entries[@]}" "${REPO}"
    printf 'Other machines drop these links on their next df-link or df-deploy, and the files go with them; to keep one there, run df-rm on it before pulling.\n'
}

# ---------------------------------------------------------------------------
# mv: move linked files to another layer
# ---------------------------------------------------------------------------

# The text for a link at TARGET that now points at stow/NEW/RELATIVE instead
# of stow/OLD/RELATIVE, written like the old one (a relative link stays
# relative), or the absolute path when the old text does not end that way.
#   moved_link_text TARGET OLD NEW RELATIVE
moved_link_text() {
    local text suffix="$2/$4"
    text="$(readlink "$1")"
    if [[ "${text}" == */"${suffix}" ]]; then
        printf '%s%s/%s\n' "${text%"${suffix}"}" "$3" "$4"
    else
        printf '%s/stow/%s/%s\n' "${REPO}" "$3" "$4"
    fi
}

move_files() {
    local files entry relative source dest old new inner target tmp refused=0 refs owners
    local -a entries=() moves=()

    files="$(collect_linked_files moving)" || exit 1
    while IFS= read -r entry; do
        [[ -n "${entry}" ]] && entries+=("${entry}")
    done < <(printf '%s\n' "${files}" | LC_ALL=C sort -u)
    if [[ "${#entries[@]}" -eq 0 ]]; then
        log_error "No managed files to move"
        exit 1
    fi
    choose_add_layer "Layer to move the files to"

    # Each file keeps its path inside the package; the package changes to the
    # layer, or its part for this OS when asked or when the file is in one.
    for entry in "${entries[@]}"; do
        relative="${entry%%|*}" source="${entry#*|}"
        old="${source#stow/}"
        old="${old%%/*}"
        inner="${source#stow/"${old}"/}"
        if [[ "${ADD_PLATFORM}" -eq 1 ]]; then
            new="${ADD_LAYER}.$(platform)"
        elif [[ "${MOVE_NO_PLATFORM}" -eq 0 && "${old}" == *.* ]]; then
            new="${ADD_LAYER}.${old#*.}"
        else
            new="${ADD_LAYER}"
        fi
        dest="stow/${new}/${inner}"
        if [[ "${new}" == "${old}" ]]; then
            log_error "Not moving ~/${relative}: already in stow/${old}"
            refused=1
        elif [[ -e "${REPO}/${dest}" || -L "${REPO}/${dest}" ]]; then
            log_error "Not moving ~/${relative}: ${dest} already exists"
            refused=1
        else
            moves+=("${relative}|${source}|${dest}")
        fi
    done
    [[ "${refused}" -eq 0 ]] || exit 1

    if [[ "${DRY_RUN}" -eq 1 ]]; then
        for entry in "${moves[@]}"; do
            IFS='|' read -r relative source dest <<< "${entry}"
            printf 'Would move %s to %s and relink ~/%s\n' "${source}" "${dest}" "${relative}"
        done
        return 0
    fi

    # The new copy exists before the link is swapped to it, and the swap is a
    # rename, so the file in ~ never goes missing.
    for entry in "${moves[@]}"; do
        IFS='|' read -r relative source dest <<< "${entry}"
        old="${source#stow/}" new="${dest#stow/}"
        target="${DEST}/${relative}"
        mkdir -p "$(dirname "${REPO}/${dest}")"
        cp -p "${REPO}/${source}" "${REPO}/${dest}"
        tmp="$(dirname "${target}")/.df-mv.$$"
        ln -s "$(moved_link_text "${target}" "${old%%/*}" "${new%%/*}" "${source#stow/*/}")" "${tmp}"
        mv -f "${tmp}" "${target}"
        if repo_tracks "${source}"; then
            git -C "${REPO}" mv -f -- "${source}" "${dest}"
        else
            mv -f "${REPO}/${source}" "${REPO}/${dest}"
        fi
        prune_package_dirs "${source}"
        printf 'Moved %s to %s; ~/%s links there\n' "${source}" "${dest}" "${relative}"
    done

    if command -v git >/dev/null 2>&1; then
        for entry in "${moves[@]}"; do
            IFS='|' read -r relative source dest <<< "${entry}"
            refs="$(git -C "${REPO}" grep -n -F -e "${source}" 2>/dev/null || true)"
            [[ -n "${refs}" ]] || continue
            printf 'References to %s, left for you to update:\n' "${source}"
            printf '  %s\n' "${refs//$'\n'/$'\n'  }"
        done
    fi

    printf 'Moved %d file(s) to layer %s. Commit with: git -C %s commit\n' "${#moves[@]}" "${ADD_LAYER}" "${REPO}"
    owners="$(layer_owners "${ADD_LAYER}")"
    if [[ "${owners}" == "every persona" ]]; then
        printf "Other machines follow the new layer on their next df-link or df-deploy; every persona links '%s'.\n" "${ADD_LAYER}"
    else
        printf "Other machines follow the new layer on their next df-link or df-deploy; one whose persona does not link '%s' (linked by %s) loses the file there.\n" \
            "${ADD_LAYER}" "${owners:-no persona}"
    fi
}

main() {
    local name
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
    load_installs

    case "${COMMAND}" in
        persona) printf '%s %s\n' "${PERSONA_NAME}" "${PERSONA_SOURCE}" ;;
        offered) offered_installs ;;
        installs)
            printf 'brew=%s\nbrew_optional=%s\nharden=%s\ninstalls=%s\ninstalls_source=%s\n' \
                "$(brewfiles)" "${PERSONA_BREW_OPTIONAL}" "${PERSONA_HARDEN}" "${INSTALLS}" "${INSTALLS_SOURCE}"
            for name in ${INSTALLS}; do
                printf 'install=%s\t%s\t%s\n' "${name}" "$(install_setting "${name}" setup)" "$(install_setting "${name}" detect)"
            done
            ;;
        managed) print_managed ;;
        status) print_status ;;
        add) add_files ;;
        rm) remove_files ;;
        mv) move_files ;;
        apply)
            if [[ "${PERSONA_SOURCE}" == default ]]; then
                log_warn "No persona chosen; linking as '${PERSONA_NAME}', the default for $(platform). Pick one with: install.sh --persona NAME"
            fi
            save_persona
            save_installs
            warn_missing_layers
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

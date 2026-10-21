#!/usr/bin/env bash
# doctor.sh — check this machine against the dotfiles repo (df-doctor runs
# it). Groups, keys and the fix list: usage() and scripts/README.md.

set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common.sh
source "${BASEDIR}/scripts/common.sh"

# Dotfiles repo whose stow/ and seed/ trees define what is managed.
SOURCE_DIR="${HOME}/.dotfiles"
DEST_DIR="${HOME}"
DAYS=90
SHOW_ALL=0
FIX=0
FIX_ONLY=0
REPORT_ONLY=0
HINT=1
TSV=0
EXPLAIN=""
REVIEW_INCOMPLETE=0
MANAGED_PATHS_CACHE=""
LINK_STATUS=""
LINK_OUTPUT=""
LOGIN_ENV=""
XDG_DB=""
XDG_PROGRAMS=""
# The XDG bin folder a new shell uses, else ~/.local/bin.
BIN_HOME=""
# Paths this machine's user marked to ignore, one ~/-relative path per line,
# and their absolute forms, one per line.
IGNORE_FILE=""
IGNORED_PATHS=""
declare -a extra_roots=() ignore_add=() ignore_remove=()
# Root for the OS-owner evidence paths; tests point it at a fake root.
OS_ROOT="${DF_DOCTOR_ROOT:-}"

# The findings, one index per path. action is the suggestion (archive, move,
# keep) or, for links, the link.sh state; target is where a move goes; how is
# advice to follow by hand; kind sorts the ignored ones (use, state, system,
# noxdg, marked); fixable is 0 when df-doctor must not touch the path.
declare -a f_path=() f_group=() f_action=() f_target=() f_reason=() f_how=() f_kind=() f_fixable=() f_size=()

usage() {
    cat <<'EOF'
Usage: df-doctor [--report] [--all] [--explain PATH] [--days N] [FOLDER...]
       df-doctor --ignore PATH | --unignore PATH

Check this machine against the dotfiles repo and sort what it finds:

  Links   repo links that are off; repair them, then run df-link
  Fix     changes df-doctor suggests (archive junk and old copies a tool no
          longer reads, move a file where xdg-ninja's advice says)
  Decide  needs you: no owner found, XDG advice to follow by hand, a file
          next to managed files that nothing explains, or a file of a layer
          this persona does not link
  Not in the repo
          config in ~/.config and commands in ~/.local/bin made outside the
          repo
  Ignore  left alone: in use, local state, made by the OS (each says whether
          it is normal or critical), tools without XDG support, or marked to
          ignore on this machine

On a terminal the report is followed by one list of everything df-doctor can
change, one row per item, each set to its suggestion (skip, unless it is under
Fix). Choose a row with the arrows and press s (skip: leave it alone this
time, and report it again next run), a (archive), d (delete), i (ignore from
now on), r (add to the repo), or m (move where xdg-ninja says); space cycles
through them. Enter applies every row at once; q or Esc changes
nothing. Missing or stale repo links get one row that runs df-link.
Archived files go to ~/.local/state/dotfiles/cleanup/, and moves are logged
with their undo in ~/.local/state/dotfiles/moves.tsv. Delete keeps no copy and
asks once more.

  --report        only report, even on a terminal
  --fix           show the list even when stdin or stdout is not a terminal
                  (then it reads one line: "delete 2 5-7 ignore 3")
  --all           also list the Ignore items one by one
  --explain PATH  everything df-doctor knows about one path, with xdg-ninja's
                  full advice
  --days N        an entry no installed tool owns counts as abandoned after N
                  days without a change (default 90)
  --ignore PATH   stop reporting PATH, and anything in it, on this machine
                  (listed in ~/.local/state/dotfiles/doctor-ignore)
  --unignore PATH report PATH again
  FOLDER...       also check everything in these folders (df-doctor ~/.config)

Moving to an XDG path follows xdg-ninja's advice: when it says to move the
file or directory to one place (tmux: ~/.config/tmux/tmux.conf), the item is
under Fix with "move". Advice that also exports variables waits until a new
shell has them: add them to the repo's stow/common/.config/zsh/.zshenv. Other
advice shows as a "how:" line under Decide, to follow by hand.

For the installer and tests: --source PATH (repo), --destination PATH (home),
--no-hint (no closing hint), --fix-only (the list without the
report), --tsv (findings as group, path, action, target, reason).
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --fix) FIX=1; REPORT_ONLY=0; shift ;;
            --fix-only) FIX=1; FIX_ONLY=1; REPORT_ONLY=0; shift ;;
            --report) FIX=0; FIX_ONLY=0; REPORT_ONLY=1; shift ;;
            --all) SHOW_ALL=1; shift ;;
            --tsv) TSV=1; shift ;;
            --no-hint) HINT=0; shift ;;
            --explain|--source|--destination|--days|--ignore|--unignore)
                if [[ $# -lt 2 ]]; then
                    log_error "$1 requires a value"
                    exit 1
                fi
                case "$1" in
                    --explain) EXPLAIN="$2" ;;
                    --ignore) ignore_add+=("$(absolute_path "$2")") ;;
                    --unignore) ignore_remove+=("$(absolute_path "$2")") ;;
                    --source) SOURCE_DIR="$2" ;;
                    --destination) DEST_DIR="$2" ;;
                    --days)
                        [[ "$2" =~ ^[0-9]+$ ]] || { log_error "--days needs a number"; exit 1; }
                        DAYS="$2"
                        ;;
                esac
                shift 2
                ;;
            -h|--help) usage; exit 0 ;;
            --)
                shift
                extra_roots+=("$@")
                break
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

# --- Paths and the repo ------------------------------------------------------

display_path() {
    if [[ "$1" == "${HOME}" ]]; then
        printf '~\n'
    elif [[ "$1" == "${HOME}/"* ]]; then
        # shellcheck disable=SC2088 # literal ~ for display
        printf '~/%s\n' "${1#"${HOME}"/}"
    else
        printf '%s\n' "$1"
    fi
}

# A path from the command line made absolute: a literal ~ the caller may have
# quoted, or relative to here, with its folder's ./ and ../ resolved when the
# folder exists.
absolute_path() {
    local path="$1" parent
    # shellcheck disable=SC2088 # a literal ~ the caller may have quoted
    case "${path}" in
        "~") path="${HOME}" ;;
        "~/"*) path="${HOME}/${path#"~/"}" ;;
        /*) ;;
        *) path="${PWD}/${path}" ;;
    esac
    path="${path%/}"
    parent="${path%/*}"
    if [[ -n "${parent}" && -d "${parent}" ]]; then
        parent="$(cd "${parent}" && pwd -L)"
        path="${parent%/}/${path##*/}"
    fi
    printf '%s
' "${path}"
}

# File names and environment values reach the terminal; replace control
# characters (escape sequences, tabs, newlines) so they cannot drive it or
# break the tab-separated output.
printable() {
    printf '%s' "$1" | LC_ALL=C tr '\000-\037\177' '?'
}

link_script() {
    bash "${BASEDIR}/scripts/link.sh" --repo "${SOURCE_DIR}" --destination "${DEST_DIR}" "$@"
}

# link_script's output in LINK_OUTPUT, through a file: macOS bash 3.2 can fail
# a write to a pipe with EINTR when a child exits, which read as a failed check.
link_output() {
    local file status=0
    file="$(mktemp)" || return 1
    link_script "$@" > "${file}" || status=$?
    LINK_OUTPUT="$(< "${file}")"
    rm -f "${file}"
    return "${status}"
}

prime_managed_paths_cache() {
    [[ -z "${MANAGED_PATHS_CACHE}" ]] || return 0
    if link_output managed; then
        MANAGED_PATHS_CACHE="${LINK_OUTPUT}"
    else
        log_error "Could not list managed paths; the check is incomplete"
        return 1
    fi
}

is_protected() {
    local path="$1"

    [[ "${SOURCE_DIR}" == "${path}/"* || "${BASEDIR}" == "${path}/"* ]] && return 0
    case "${path}" in
        "${DEST_DIR}" | "${DEST_DIR}/.config" | "${DEST_DIR}/.local" | "${DEST_DIR}/.git" | "${DEST_DIR}/.git/"* | "${DEST_DIR}/.dotfiles" | "${DEST_DIR}/.dotfiles/"* | "${DEST_DIR}/.cache" | "${DEST_DIR}/.cache/"* | "${DEST_DIR}/.Trash" | "${DEST_DIR}/.Trash/"*) return 0 ;;
        "${DEST_DIR}/.ssh" | "${DEST_DIR}/.ssh/"* | "${DEST_DIR}/.gnupg" | "${DEST_DIR}/.gnupg/"* | "${DEST_DIR}/.aws" | "${DEST_DIR}/.aws/"* | "${DEST_DIR}/.1password/"*) return 0 ;;
        "${DEST_DIR}/.netrc" | "${DEST_DIR}/.npmrc" | "${DEST_DIR}/.pypirc" | "${DEST_DIR}/.kube" | "${DEST_DIR}/.kube/"* | "${DEST_DIR}/.docker" | "${DEST_DIR}/.docker/"*) return 0 ;;
        "${DEST_DIR}/.agents" | "${DEST_DIR}/.agents/"* | "${DEST_DIR}/.claude" | "${DEST_DIR}/.claude/"* | "${DEST_DIR}/.codex" | "${DEST_DIR}/.codex/"* | "${DEST_DIR}/.cursor" | "${DEST_DIR}/.cursor/"* | "${DEST_DIR}/.claude.json" | "${DEST_DIR}/.config/agents" | "${DEST_DIR}/.config/agents/"*) return 0 ;;
        "${DEST_DIR}/.local/state/dotfiles" | "${DEST_DIR}/.local/state/dotfiles/"*) return 0 ;;
        "${SOURCE_DIR}" | "${SOURCE_DIR}/"* | "${BASEDIR}" | "${BASEDIR}/"*) return 0 ;;
    esac
    return 1
}

contains_managed_path() {
    local path="$1" managed=""

    while IFS= read -r managed; do
        [[ -n "${managed}" ]] || continue
        if [[ "${managed}" == "${path}" || "${managed}" == "${path}/"* || ( "${path}" == "${managed}/"* && -L "${managed}" ) ]]; then
            return 0
        fi
    done <<< "${MANAGED_PATHS_CACHE}"
    return 1
}

# An unmanaged file whose .example the repo manages (config.local, teams.toml).
is_expected_local_override() {
    grep -Fqx -- "$1.example" <<< "${MANAGED_PATHS_CACHE}"
}

# Files apps and the shell keep for themselves next to managed files.
is_local_state() {
    case "$1" in
        "${DEST_DIR}/.claude/"* | "${DEST_DIR}/.codex/"* | "${DEST_DIR}/.ssh/"* ) return 0 ;;
        "${DEST_DIR}/Library/Application Support/Code/"* | "${DEST_DIR}/Library/Application Support/Cursor/"* ) return 0 ;;
        "${DEST_DIR}/.config/1Password/ssh/agent.toml" | "${DEST_DIR}/.config/gh/config.yml" | "${DEST_DIR}/.config/homebrew" | "${DEST_DIR}/.config/git/config.local" | "${DEST_DIR}/.config/zsh/.zsh_history" | "${DEST_DIR}/.config/zsh/plugins.zsh" ) return 0 ;;
        *"/.DS_Store" | *"/.ignore.swp" | *"/Cookies" | *"/Cookies-journal" | *"/DIPS" | *"/DIPS-wal" | *"/Network Persistent State" | *"/SharedStorage" | *"/SharedStorage-wal" | *"/TransportSecurity" | *"/Trust Tokens" | *"/Trust Tokens-journal" | *"/code.lock" | *"/languagepacks.json" | *"/machineid" | *"/known_hosts" | *"/known_hosts.old" | *"/history.jsonl" | *"/mcp-needs-auth-cache.json" | *"/models_cache.json" | *"/policy-limits.json" | *"/readout-cost-cache.json" | *"/readout-pricing.json" | *"/session_index.jsonl" | *"/stats-cache.json" | *"/auth.json" | *"/.codex-global-state.json" | *"/.personality_migration" | *"/logs_"*.sqlite | *"/logs_"*.sqlite-shm | *"/logs_"*.sqlite-wal | *"/state_"*.sqlite | *"/state_"*.sqlite-shm | *"/state_"*.sqlite-wal ) return 0 ;;
    esac
    return 1
}

# --- Paths marked to ignore ---------------------------------------------------

# The ignore list holds ~/-relative paths, one per line; blank lines and
# # comments are skipped.
load_ignored() {
    local line

    IGNORED_PATHS=""
    [[ -f "${IGNORE_FILE}" ]] || return 0
    while IFS= read -r line || [[ -n "${line}" ]]; do
        # shellcheck disable=SC2088 # a literal ~ in the list
        case "${line}" in
            "~/"?*) line="${DEST_DIR}/${line#"~/"}" ;;
            *) continue ;;
        esac
        IGNORED_PATHS+="${line%/}"$'\n'
    done < "${IGNORE_FILE}"
}

# How the list writes a path in the destination.
ignore_entry() {
    # shellcheck disable=SC2088 # a literal ~ in the list
    printf '~/%s\n' "${1#"${DEST_DIR}"/}"
}

# The listed path that covers the path (itself or a folder holding it).
ignored_by() {
    local marked

    while IFS= read -r marked; do
        [[ -n "${marked}" ]] || continue
        if [[ "$1" == "${marked}" || "$1" == "${marked}/"* ]]; then
            printf '%s\n' "${marked}"
            return 0
        fi
    done <<< "${IGNORED_PATHS}"
    return 1
}

# Refuses a symlinked state folder or list, which would write elsewhere.
ignore_file_safe() {
    local path

    for path in "${DEST_DIR}/.local" "${DEST_DIR}/.local/state" "${DEST_DIR}/.local/state/dotfiles" "${IGNORE_FILE}"; do
        if [[ -L "${path}" ]]; then
            log_error "Ignore list path is a symlink: ${path}; nothing changed"
            return 1
        fi
    done
}

# Adds each path to the ignore list unless it is already there.
mark_ignored() {
    local path entry failed=0

    ignore_file_safe || return 1
    printf '\nIgnoring on this machine (list: %s)\n' "$(display_path "${IGNORE_FILE}")"
    for path in "$@"; do
        if [[ "${path}" != "${DEST_DIR}/"* || "${path}" == *$'\n'* || "${path}" == *$'\t'* ]]; then
            log_warn "Not ignored: $(printable "${path}") is not a plain path inside $(display_path "${DEST_DIR}")"
            failed=1
            continue
        fi
        entry="$(ignore_entry "${path}")"
        if [[ -f "${IGNORE_FILE}" ]] && grep -Fqx -- "${entry}" "${IGNORE_FILE}"; then
            printf '  already ignored %s\n' "$(printable "$(display_path "${path}")")"
            continue
        fi
        (umask 077 && mkdir -p "${IGNORE_FILE%/*}" && printf '%s\n' "${entry}" >> "${IGNORE_FILE}") || return 1
        printf '  ignoring %s (undo: df-doctor --unignore %s)\n' "$(printable "$(display_path "${path}")")" "$(printable "$(display_path "${path}")")"
    done
    return "${failed}"
}

# Takes each path off the ignore list; a path only covered by a listed folder
# stays ignored, and the message names that folder.
unmark_ignored() {
    local path entry covered tmp failed=0

    ignore_file_safe || return 1
    for path in "$@"; do
        entry="$(ignore_entry "${path}")"
        if [[ "${path}" == "${DEST_DIR}/"* && -f "${IGNORE_FILE}" ]] && grep -Fqx -- "${entry}" "${IGNORE_FILE}"; then
            tmp="$(mktemp "${IGNORE_FILE}.XXXXXX")"
            grep -Fvx -- "${entry}" "${IGNORE_FILE}" > "${tmp}" || [[ $? -eq 1 ]] || { rm -f "${tmp}"; return 1; }
            mv "${tmp}" "${IGNORE_FILE}"
            load_ignored
            if covered="$(ignored_by "${path}")"; then
                printf 'Removed %s from the ignore list; %s still covers it.\n' "$(printable "$(display_path "${path}")")" "$(printable "$(display_path "${covered}")")"
            else
                printf 'df-doctor reports %s again.\n' "$(printable "$(display_path "${path}")")"
            fi
        elif covered="$(ignored_by "${path}")"; then
            log_warn "Still ignored: $(printable "$(display_path "${path}")") is inside $(printable "$(display_path "${covered}")"); unignore that instead"
            failed=1
        else
            log_warn "Not on the ignore list: $(printable "$(display_path "${path}")")"
            failed=1
        fi
    done
    return "${failed}"
}

# A working command in the XDG bin folder is a tool someone installed (uv,
# claude); a broken link or a file that cannot run is a leftover.
is_local_command() {
    [[ "$1" == "${BIN_HOME}/"* && -f "$1" && -x "$1" ]]
}

# Whether df-doctor may change the path: inside the destination, a plain name,
# not protected or managed, and not reached through a symlinked folder (it
# would change someone else's tree).
can_change() {
    local path="$1" parent="${1%/*}"

    [[ "${path}" == "${DEST_DIR}/"* && "${path}" != *$'\n'* && "${path}" != *$'\t'* ]] || return 1
    is_protected "${path}" && return 1
    contains_managed_path "${path}" && return 1
    while [[ "${parent}" != "${DEST_DIR}" && "${parent}" != / ]]; do
        [[ ! -L "${parent}" ]] || return 1
        parent="${parent%/*}"
    done
}

# --- Findings ----------------------------------------------------------------

# Records one finding unless the path, or a folder holding it, already has one.
add_finding() {
    local group="$1" path="$2" action="$3" target="$4" reason="$5" how="${6:-}" kind="${7:-}" existing fixable=1

    for existing in ${f_path[@]+"${f_path[@]}"}; do
        [[ "${path}" != "${existing}" && "${path}" != "${existing}/"* ]] || return 0
    done
    # The user's say-so outranks every other group but a repo link that is off.
    if [[ "${group}" != links ]] && ignored_by "${path}" >/dev/null; then
        group=ignore action=keep target="" how="" kind=marked reason="marked to ignore"
    fi
    if [[ "${group}" == fix || "${group}" == decide ]] && ! can_change "${path}"; then
        group=decide action=keep target="" fixable=0
        reason="${reason}; df-doctor leaves it alone (protected, managed, or in a symlinked folder)"
    fi
    f_path+=("${path}")
    f_group+=("${group}")
    f_action+=("${action}")
    f_target+=("${target}")
    f_reason+=("${reason}")
    f_how+=("${how}")
    f_kind+=("${kind}")
    f_fixable+=("${fixable}")
    f_size+=("")
}

# Sizes are measured only for what the report or a question shows, once each:
# an Ignore folder can be large (~/.cache) and needs none.
measure() {
    [[ -n "${f_size[$1]}" ]] || f_size[$1]="$(size_of "${f_path[$1]}")"
    [[ -n "${f_size[$1]}" ]] || f_size[$1]="-"
}

finding_index() {
    local i
    for i in ${f_path[@]+"${!f_path[@]}"}; do
        [[ "${f_path[i]}" != "$1" ]] || { printf '%s\n' "${i}"; return 0; }
    done
    return 1
}

# --- What tools read: xdg-ninja and a new shell --------------------------------

# Looks in Homebrew's usual prefixes rather than running brew, which is slow
# and must not run during an install dry run.
find_programs_dir() {
    local dir
    local -a prefixes=()
    if [[ -n "${DF_DOCTOR_PROGRAMS:-}" ]]; then
        printf '%s\n' "${DF_DOCTOR_PROGRAMS}"
        return
    fi
    read -r -a prefixes <<< "${DF_DOCTOR_PREFIXES-${HOMEBREW_PREFIX:-} /opt/homebrew /home/linuxbrew/.linuxbrew /usr/local /usr}"
    for dir in ${prefixes[@]+"${prefixes[@]/%//share/xdg-ninja/programs}"}; do
        [[ -n "${dir}" && -d "${dir}" ]] && { printf '%s\n' "${dir}"; return; }
    done
    return 0
}

# name<TAB>program<TAB>movable<TAB>VAR,VAR<TAB>hint<TAB>move for every $HOME/.name
# entry. move is f:PATH or d:PATH when the advice names exactly one place to
# move the file or directory to ("move the file to _$XDG_CONFIG_HOME/x_"), else
# empty; advice that says only "move it" does not say what moves.
load_xdg_db() {
    local -a files=()
    XDG_PROGRAMS="$(find_programs_dir)"
    [[ -n "${XDG_PROGRAMS}" ]] && command -v jq >/dev/null 2>&1 || return 0
    # With no files jq would read stdin, taking the answers meant for --fix.
    files=("${XDG_PROGRAMS}"/*.json)
    [[ "${#files[@]}" -gt 0 ]] || { XDG_PROGRAMS=""; return 0; }
    XDG_DB="$(jq -r '
        .name as $prog | .files[]
        | select(.path | test("^\\$HOME/\\.[^/]+$"))
        | [ (.path | sub("^\\$HOME/"; "")),
            $prog,
            (.movable | tostring),
            ([.help | scan("export ([A-Z_][A-Z0-9_]*)=")[]] | join(",")),
            ((.help | split("\n") | map(select(test("^export ")))) as $e
              | if ($e | length) > 0 then ($e | join("; "))
                else ((.help | split("\n") | map(select(test("[Mm]ove ")))) + (.help | split("\n") | map(select(length > 0)))
                      | first // "" | gsub("[*`]"; "")) end),
            ([.help | scan("[Mm]ove (?:the|this) (file|directory|folder) (?:to|into) _(\\$XDG_(?:CONFIG|DATA|STATE|CACHE)_HOME/[^ ]*?)/?_(?=[ .,;:)]|$)")]
              | map((if .[0] == "file" then "f" else "d" end) + ":" + .[1]) | unique
              | if length == 1 then .[0] else "" end)
          ] | @tsv' "${files[@]}" 2>/dev/null </dev/null || true)"
}

# The environment a new zsh starts with, from the destination's own
# ~/.zshenv alone, read once: a value exported only in this shell does not
# say where tools will look from now on.
load_login_env() {
    local zsh
    zsh="$(command -v zsh 2>/dev/null)" || return 0
    LOGIN_ENV="$(env -i HOME="${DEST_DIR}" PATH=/usr/bin:/bin "${zsh}" -c env 2>/dev/null || true)"
}

login_value() {
    awk -v key="$1=" 'index($0, key) == 1 { print substr($0, length(key) + 1); exit }' <<< "${LOGIN_ENV}"
}

# A path xdg-ninja writes as $XDG_*_HOME/rest, under the base a new shell
# gives that variable, or its XDG default under the destination.
expand_xdg() {
    local var="${1%%/*}" rest="${1#*/}" base
    var="${var#\$}"
    base="$(login_value "${var}")"
    if [[ -z "${base}" ]]; then
        case "${var}" in
            XDG_CONFIG_HOME) base="${DEST_DIR}/.config" ;;
            XDG_DATA_HOME) base="${DEST_DIR}/.local/share" ;;
            XDG_STATE_HOME) base="${DEST_DIR}/.local/state" ;;
            XDG_CACHE_HOME) base="${DEST_DIR}/.cache" ;;
        esac
    fi
    printf '%s/%s\n' "${base}" "${rest}"
}

# stat arguments that print a modification time in epoch seconds (GNU, then BSD).
if stat -c %Y / >/dev/null 2>&1; then
    MTIME_ARGS=(-c %Y)
else
    MTIME_ARGS=(-f %m)
fi
NOW="$(date +%s)"

# Whole days since anything at or under the path (two levels deep) changed.
age_days() {
    local newest
    newest="$(find "$1" -maxdepth 2 -print0 2>/dev/null | xargs -0 stat "${MTIME_ARGS[@]}" 2>/dev/null | sort -n | tail -n 1 || true)"
    [[ "${newest}" =~ ^[0-9]+$ ]] || newest="${NOW}"
    printf '%d\n' $(((NOW - newest) / 86400))
}

age_text() {
    case "$1" in
        0) printf 'changed today' ;;
        1) printf 'changed yesterday' ;;
        *) printf 'changed %d days ago' "$1" ;;
    esac
}

# Files Debian and its desktops make in a home, by path from the home:
# "level<TAB>evidence<TAB>what it is". level is critical when removing it
# breaks something, else normal; evidence is space-separated system paths
# (globs) of which one exists while its owner is installed.
os_entry() {
    local desktops="/usr/bin/gnome-shell /usr/bin/xfce4-session /usr/bin/startplasma-* /usr/bin/lxsession /usr/bin/labwc /usr/bin/wayfire"
    local greeters="/usr/sbin/gdm3 /usr/sbin/lightdm /usr/bin/sddm"
    local x11="/usr/bin/Xorg /usr/bin/Xwayland"
    case "$1" in
        .profile) printf 'critical\t/bin/sh\tread by every login shell (Debian copies it from /etc/skel); without it ~/.local/bin leaves the PATH\n' ;;
        .bash_logout) printf 'normal\t/bin/bash\tbash runs it at logout to clear the console (from /etc/skel)\n' ;;
        .sudo_as_admin_successful) printf 'normal\t/usr/bin/sudo\tsudo'"'"'s marker that hides its first-use hint\n' ;;
        .hushlogin) printf 'normal\t/usr/bin/login /bin/login\thides the message shown at login; made on purpose\n' ;;
        .face | .face.icon) printf 'normal\t%s\tyour picture on the login screen\n' "${greeters}" ;;
        .dmrc) printf 'normal\t%s\tthe session and language last chosen at the login screen\n' "${greeters}" ;;
        .Xauthority) printf 'critical\t%s\tX11 login cookie; graphical apps cannot open windows without it\n' "${x11}" ;;
        .xsession-errors | .xsession-errors.old) printf 'normal\t%s\tlog of a desktop session; rewritten at each login\n' "${x11}" ;;
        .dbus) printf 'normal\t/usr/bin/dbus-daemon\tD-Bus session data\n' ;;
        .gtkrc-2.0) printf 'normal\t/usr/lib/*/libgtk-x11-2.0.so.0\tGTK 2 theme settings\n' ;;
        .config/user-dirs.dirs) printf 'critical\t/usr/bin/xdg-user-dirs-update\twhere Desktop, Downloads, and the other user folders are; file managers and save dialogs read it\n' ;;
        .config/user-dirs.locale) printf 'normal\t/usr/bin/xdg-user-dirs-update\tthe language the user folders were named in\n' ;;
        .config/mimeapps.list) printf 'normal\t/usr/bin/xdg-open /usr/bin/gio\tyour default app for each file type\n' ;;
        .config/dconf) printf 'critical\t/usr/bin/dconf /usr/libexec/dconf-service\tthe settings database of GNOME and GTK apps; removing it resets them all\n' ;;
        .config/gnome-initial-setup-done) printf 'critical\t/usr/libexec/gnome-initial-setup\tGNOME'"'"'s first-login marker; without it GNOME runs its setup again\n' ;;
        .config/goa-1.0) printf 'normal\t/usr/libexec/goa-daemon\tGNOME Online Accounts sign-ins\n' ;;
        .config/.gsd-keyboard.settings-ported) printf 'normal\t/usr/libexec/gsd-keyboard\tGNOME'"'"'s marker that keyboard settings were migrated\n' ;;
        .config/monitors.xml) printf 'normal\t/usr/bin/gnome-shell /usr/bin/mutter\tGNOME'"'"'s saved display layout\n' ;;
        .config/GNOME-xdg-terminals.list | .config/xdg-terminals.list) printf 'normal\t/usr/bin/gnome-shell /usr/bin/xdg-terminal-exec\twhich terminal the desktop opens\n' ;;
        .config/gtk-2.0) printf 'normal\t/usr/lib/*/libgtk-x11-2.0.so.0\tGTK 2 bookmarks and theme settings\n' ;;
        .config/gtk-3.0) printf 'normal\t/usr/lib/*/libgtk-3.so.0\tGTK 3 file-chooser bookmarks and theme settings\n' ;;
        .config/gtk-4.0) printf 'normal\t/usr/lib/*/libgtk-4.so.1\tGTK 4 file-chooser bookmarks and theme settings\n' ;;
        .config/pulse) printf 'normal\t/usr/bin/pulseaudio /usr/bin/pipewire-pulse\tPulseAudio'"'"'s cookie and saved volumes; made again when removed\n' ;;
        .config/ibus) printf 'normal\t/usr/bin/ibus\tinput method settings\n' ;;
        .config/autostart) printf 'normal\t%s\tapps your desktop starts at login\n' "${desktops}" ;;
        .config/menus) printf 'normal\t%s\tyour edits to the desktop'"'"'s app menu\n' "${desktops}" ;;
        .config/procps) printf 'normal\t/usr/bin/top\ttop'"'"'s saved layout\n' ;;
        .config/lxsession | .config/lxpanel | .config/pcmanfm | .config/libfm | .config/openbox | .config/lxterminal) printf 'normal\t/usr/bin/lxsession /usr/bin/lxpanel /usr/bin/pcmanfm /usr/bin/openbox\tRaspberry Pi or LXDE desktop settings\n' ;;
        .config/wayfire.ini | .config/wf-panel-pi.ini | .config/labwc | .config/kanshi) printf 'normal\t/usr/bin/wayfire /usr/bin/labwc /usr/bin/kanshi\tRaspberry Pi desktop settings (Wayland)\n' ;;
    esac
}

# A file the OS made: Ignore while its owner is installed, saying whether it is
# critical; a leftover to decide on once nothing on the system uses it.
classify_os_entry() {
    local path="$1" entry level evidence what glob candidate found=""
    local -a globs=()

    entry="$(os_entry "${path#"${DEST_DIR}/"}")"
    [[ -n "${entry}" ]] || return 1
    IFS=$'\t' read -r level evidence what <<< "${entry}"
    # read splits without globbing, so each glob expands under OS_ROOT only.
    read -r -a globs <<< "${evidence}"
    for glob in "${globs[@]}"; do
        for candidate in "${OS_ROOT}"${glob}; do
            [[ -e "${candidate}" ]] && found=1
        done
    done
    if [[ -n "${found}" ]]; then
        add_finding ignore "${path}" keep "" "${level}: ${what}" "" system
    else
        add_finding decide "${path}" archive "" "${what}; nothing installed uses it any more, so it is a leftover"
    fi
}

# Folders named after a product rather than its command.
owner_alias() {
    case "$1" in
        vscode*) printf 'code\n' ;;
        microsandbox) printf 'msb\n' ;;
        bottom) printf 'btm\n' ;;
        swiftpm) printf 'swift\n' ;;
        factory) printf 'droid\n' ;;
        kimi-code) printf 'kimi\n' ;;
    esac
}

find_owner() {
    local name="$1" program="$2" base candidate app
    base="$(printf '%s' "${name#.}" | tr '[:upper:]' '[:lower:]')"
    for candidate in "${program}" "$(owner_alias "${base}")" "${base}" "${base%%[-_.]*}"; do
        [[ -n "${candidate}" ]] || continue
        if command -v "${candidate}" >/dev/null 2>&1; then
            printf '%s\n' "${candidate}"
            return
        fi
    done
    if [[ "$(uname -s)" == Darwin ]]; then
        while IFS=$'\t' read -r candidate app; do
            [[ -n "${app}" ]] || continue
            # The app's name, or one starting with it when it is long enough
            # not to match by chance (amp is not Amphetamine).
            if [[ "${candidate}" == "${base}" || ( "${#base}" -ge 4 && "${candidate}" == "${base%%[-_.]*}"* ) ]]; then
                printf '%s\n' "${app}"
                return
            fi
        done <<< "$(installed_apps)"
    fi
}

# Installed apps as "lowercased name without spaces<TAB>Name.app", listed once:
# find_owner runs for every unmanaged path.
INSTALLED_APPS_CACHE=""
INSTALLED_APPS_LISTED=0
installed_apps() {
    local app name
    if [[ "${INSTALLED_APPS_LISTED}" -eq 0 ]]; then
        INSTALLED_APPS_LISTED=1
        INSTALLED_APPS_CACHE="$(
            for app in /Applications/*.app "${DEST_DIR}/Applications"/*.app; do
                [[ -e "${app}" ]] || continue
                name="${app##*/}"
                printf '%s\t%s\n' "${name%.app}" "${name}"
            done | awk -F'\t' -v OFS='\t' '{ $1 = tolower($1); gsub(/ /, "", $1); print }'
        )"
    fi
    printf '%s\n' "${INSTALLED_APPS_CACHE}"
}

size_of() {
    du -sk "$1" 2>/dev/null | awk '{ kb = $1; if (kb >= 1048576) printf "%.1fG", kb/1048576; else if (kb >= 1024) printf "%.0fM", kb/1024; else printf "%dK", kb }' || true
}

# --- Collecting ----------------------------------------------------------------

# Repo links that are off, from link.sh status, and broken managed links;
# unlinked files go under Decide.
collect_links() {
    local line state path

    if ! link_output status; then
        log_warn "Could not check the repo's links; the check is incomplete"
        REVIEW_INCOMPLETE=1
        return
    fi
    LINK_STATUS="${LINK_OUTPUT}"
    while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        state="${line%% *}"
        path="${line#* }"
        # A real file of a layer this persona does not link is the user's
        # call (archive or delete it, or keep it), not a link to repair.
        if [[ "${state}" == unlinked ]]; then
            add_finding decide "${path}" keep "" "$(link_hint "${state}")"
            continue
        fi
        add_finding links "${path}" "${state}" "" "$(link_hint "${state}")"
    done <<< "${LINK_STATUS}"
    while IFS= read -r path; do
        if [[ -L "${path}" && ! -e "${path}" ]] && ! finding_index "${path}" >/dev/null; then
            add_finding links "${path}" broken "" "$(link_hint broken) ($(readlink "${path}"))"
        fi
    done <<< "${MANAGED_PATHS_CACHE}"
}

# What each link.sh status state means and what to do about it.
link_hint() {
    case "$1" in
        missing) printf 'not linked yet; run df-link, or remove the repo file if it is obsolete' ;;
        replaced) printf 'a real file sits where a link belongs (an app may have replaced it); diff it against the repo, keep wanted changes there, then run df-link, which backs the file up' ;;
        foreign) printf 'points somewhere other than the repo; check it, then run df-link to relink' ;;
        stale) printf 'a link into the repo for a file that moved or no longer applies; run df-link to remove it' ;;
        broken) printf 'its repo file is missing; restore it or fix the link, then run df-link' ;;
        unlinked) printf 'belongs to a layer this persona does not link; keep it if this machine still uses it, else archive or delete it' ;;
        shadowed) printf 'sets [user], which overrides ~/.config/git/config.local; move what you need there, then archive this file' ;;
        unset) printf 'no git user.email, so git will refuse to commit; set [user] here' ;;
        unused) printf 'private agents checkout on a persona without agents; delete it if this machine should not keep it' ;;
        *) printf '%s' "$1" ;;
    esac
}

# One top-level dotfile in the home: what xdg-ninja and a new shell say about
# its tool, else who owns it and when it last changed.
classify_home() {
    local path="$1" name="${1##*/}" entry="" program="" movable="" vars="" hint="" stated=""
    local var value redirected="" target ready owner age
    local -a var_list=()

    if is_local_state "${path}"; then
        add_finding ignore "${path}" keep "" "local state" "" state
        return
    fi
    case "${name}" in
        *.bak | *.backup | *.old | *.orig | *.swp | *~ | .zcompdump*)
            add_finding fix "${path}" archive "" "backup copy or leftover cache"
            return
            ;;
        .1password)
            add_finding ignore "${path}" keep "" "1Password SSH agent socket link, made by the shell config" "" state
            return
            ;;
        .zshenv | .CFUserTextEncoding | .localized)
            return
            ;;
    esac
    classify_os_entry "${path}" && return

    entry="$(awk -F'\t' -v n="${name}" '$1 == n { print; exit }' <<< "${XDG_DB}")"
    # Tab is IFS whitespace, so read would merge an empty field into the next; split on \x1f.
    [[ -z "${entry}" ]] || IFS=$'\x1f' read -r _ program movable vars hint stated <<< "${entry//$'\t'/$'\x1f'}"
    IFS=',' read -r -a var_list <<< "${vars}"

    if [[ "${movable}" == true ]]; then
        # Move where xdg-ninja names one target, once a new shell sets every
        # variable the advice exports.
        if [[ -n "${stated}" && ! -L "${path}" ]]; then
            ready=1
            for var in ${var_list[@]+"${var_list[@]}"}; do
                [[ "${var}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && -n "$(login_value "${var}")" ]] || ready=0
            done
            case "${stated%%:*}" in
                f) [[ -f "${path}" ]] || ready=0 ;;
                d) [[ -d "${path}" ]] || ready=0 ;;
            esac
            target="$(expand_xdg "${stated#*:}")"
            if [[ "${ready}" -eq 1 && "${target}" == /* && "${target}" != "${path}" && "${target}" != "${path}/"* ]]; then
                if [[ -e "${target}" || -L "${target}" ]]; then
                    add_finding decide "${path}" keep "" "${program} reads $(display_path "${target}") too, which exists; merge them by hand, then archive this one"
                elif [[ "$(printable "${target}")" != "${target}" ]]; then
                    add_finding decide "${path}" keep "" "${program}: the XDG path holds control characters; move it by hand"
                else
                    add_finding fix "${path}" move "${target}" "${program} reads $(display_path "${target}")"
                fi
                return
            fi
        fi
        # A new shell already sends the tool elsewhere: this is the old copy.
        # Name the variable whose path has the entry's name ($NPM_CONFIG_CACHE
        # for ~/.npm, not npm's init module), else the first one set.
        for var in ${var_list[@]+"${var_list[@]}"}; do
            [[ "${var}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
            value="$(login_value "${var}")"
            if [[ -n "${value}" && "${value}" != "${path}" && "${value}" != "${path}/"* ]]; then
                [[ -n "${redirected}" ]] || redirected="${var}=${value}"
                if [[ "${value##*/}" == "${name#.}" ]]; then
                    redirected="${var}=${value}"
                    break
                fi
            fi
        done
        if [[ -n "${redirected}" ]]; then
            add_finding fix "${path}" archive "" "${program} now uses $(display_path "${redirected#*=}") (\$${redirected%%=*}); this is the old copy"
        else
            add_finding decide "${path}" keep "" "${program} supports XDG" "${hint:-see df-doctor --explain}"
        fi
        return
    fi
    if [[ "${movable}" == false ]]; then
        add_finding ignore "${path}" keep "" "${program}: no XDG support" "" noxdg
        return
    fi

    owner="$(find_owner "${name}" "${program}")"
    age="$(age_days "${path}")"
    if [[ "${age}" -lt "${DAYS}" ]]; then
        if [[ -n "${owner}" ]]; then
            add_finding ignore "${path}" keep "" "in use by ${owner}; $(age_text "${age}")" "" use
        else
            add_finding decide "${path}" keep "" "no owner found; $(age_text "${age}")"
        fi
    elif [[ -n "${owner}" ]]; then
        add_finding decide "${path}" keep "" "${owner} is installed, but this is untouched for ${age} days"
    else
        add_finding decide "${path}" archive "" "no owner found; untouched for ${age} days"
    fi
}

collect_home() {
    local path

    for path in "${DEST_DIR}"/.[!.]* "${DEST_DIR}"/..?*; do
        [[ -e "${path}" || -L "${path}" ]] || continue
        is_protected "${path}" && continue
        contains_managed_path "${path}" && continue
        classify_home "${path}"
    done
}

# Unmanaged files and links under a folder. Descends only into folders that
# hold managed paths; a wholly unmanaged folder is the home check's business.
list_unmanaged() {
    local dir="$1" entry=""

    for entry in "${dir}"/.[!.]* "${dir}"/..?* "${dir}"/*; do
        [[ -e "${entry}" || -L "${entry}" ]] || continue
        grep -Fqx -- "${entry}" <<< "${MANAGED_PATHS_CACHE}" && continue
        if [[ -d "${entry}" && ! -L "${entry}" ]]; then
            if grep -Fq -- "${entry}/" <<< "${MANAGED_PATHS_CACHE}"; then
                list_unmanaged "${entry}" || return 1
            fi
            continue
        fi
        printf '%s\n' "${entry}"
    done
}

# The folders that hold managed files, minus the broad and protected ones,
# plus any the caller named; nested ones dropped.
neighbor_roots() {
    local managed parent last=""

    {
        while IFS= read -r managed; do
            [[ -n "${managed}" ]] || continue
            parent="$(dirname "${managed}")"
            case "${parent}" in
                "${DEST_DIR}" | "${DEST_DIR}/.config" | "${DEST_DIR}/.local" | "${DEST_DIR}/Library" | "${DEST_DIR}/Library/Application Support") continue ;;
            esac
            is_protected "${parent}" && continue
            printf '%s\n' "${parent}"
        done <<< "${MANAGED_PATHS_CACHE}"
        [[ "${#extra_roots[@]}" -eq 0 ]] || printf '%s\n' "${extra_roots[@]}"
    } | sort -u | while IFS= read -r parent; do
        [[ -n "${parent}" ]] || continue
        [[ -z "${last}" || ( "${parent}" != "${last}" && "${parent}" != "${last}/"* ) ]] || continue
        printf '%s\n' "${parent}"
        last="${parent}"
    done
}

# One unmanaged file next to managed files.
classify_neighbor() {
    local path="$1"

    if is_expected_local_override "${path}" || is_protected "${path}"; then
        return
    elif is_local_command "${path}"; then
        if [[ -L "${path}" ]]; then
            add_finding unmanaged "${path}" keep "" "a command you installed; links to $(display_path "$(readlink "${path}")")"
        else
            add_finding unmanaged "${path}" keep "" "a command you installed"
        fi
    elif is_local_state "${path}" || [[ "${path}" == "${BIN_HOME}/python"* ]]; then
        add_finding ignore "${path}" keep "" "local state" "" state
    elif [[ -L "${path}" && ! -e "${path}" ]]; then
        add_finding fix "${path}" archive "" "broken link to $(readlink "${path}")"
    elif [[ "${path##*/}" == .zcompdump* ]]; then
        add_finding fix "${path}" archive "" "old zsh completion cache; zsh rebuilds it"
    elif [[ "${path}" == "${BIN_HOME}/"* ]]; then
        add_finding decide "${path}" keep "" "in $(display_path "${BIN_HOME}") but cannot run; check what put it there"
    else
        add_finding decide "${path}" keep "" "not managed; sits next to managed files"
    fi
}

collect_neighbors() {
    local root unmanaged path

    while IFS= read -r root; do
        [[ -n "${root}" && -e "${root}" ]] || continue
        if ! unmanaged="$(list_unmanaged "${root}")"; then
            log_warn "Could not inspect ${root}; the check is incomplete"
            REVIEW_INCOMPLETE=1
            continue
        fi
        while IFS= read -r path; do
            [[ -z "${path}" ]] || classify_neighbor "${path}"
        done <<< "${unmanaged}"
    done < <(neighbor_roots)
}

# One entry directly in the XDG config folder that the repo does not manage:
# config made outside the repo, which may belong in it, or a leftover.
classify_config_entry() {
    local path="$1" owner age

    if is_local_state "${path}"; then
        add_finding ignore "${path}" keep "" "local state" "" state
    elif [[ -L "${path}" && ! -e "${path}" ]]; then
        add_finding fix "${path}" archive "" "broken link to $(readlink "${path}")"
    elif [[ -L "${path}" ]]; then
        add_finding unmanaged "${path}" keep "" "links to $(display_path "$(readlink "${path}")")"
    elif classify_os_entry "${path}"; then
        return
    else
        owner="$(find_owner "${path##*/}" "")"
        age="$(age_days "${path}")"
        if [[ -n "${owner}" ]]; then
            add_finding unmanaged "${path}" keep "" "${owner} is installed; $(age_text "${age}")"
        elif [[ "${age}" -lt "${DAYS}" ]]; then
            add_finding unmanaged "${path}" keep "" "no owner found; $(age_text "${age}")"
        else
            add_finding decide "${path}" archive "" "no owner found; untouched for ${age} days"
        fi
    fi
}

# Unmanaged entries directly in the XDG config and bin folders; a folder with
# managed files is collect_neighbors' job.
collect_xdg_places() {
    local config path

    config="$(login_value XDG_CONFIG_HOME)"
    config="${config:-${DEST_DIR}/.config}"
    for path in "${config}"/* "${config}"/.[!.]* "${config}"/..?*; do
        [[ -e "${path}" || -L "${path}" ]] || continue
        is_protected "${path}" && continue
        contains_managed_path "${path}" && continue
        classify_config_entry "${path}"
    done
    for path in "${BIN_HOME}"/* "${BIN_HOME}"/.[!.]* "${BIN_HOME}"/..?*; do
        [[ -e "${path}" || -L "${path}" ]] || continue
        contains_managed_path "${path}" && continue
        classify_neighbor "${path}"
    done
}

collect() {
    prime_managed_paths_cache || return 1
    load_ignored
    load_xdg_db
    load_login_env
    BIN_HOME="$(login_value XDG_BIN_HOME)"
    BIN_HOME="${BIN_HOME:-${DEST_DIR}/.local/bin}"
    collect_links
    collect_home
    collect_xdg_places
    collect_neighbors
}

# --- The report ----------------------------------------------------------------

# Plain ANSI rather than gum style: the report prints a line per finding, and
# a gum process per line would make it slow. Off when piped or with NO_COLOR.
BOLD="" DIM="" RESET="" RED="" GREEN="" YELLOW="" MAGENTA="" CYAN=""
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    BOLD=$'\033[1m' DIM=$'\033[2m' RESET=$'\033[0m'
    RED=$'\033[31m' GREEN=$'\033[32m' YELLOW=$'\033[33m' MAGENTA=$'\033[35m' CYAN=$'\033[36m'
fi

count_group() {
    local i n=0
    for i in ${f_group[@]+"${!f_group[@]}"}; do
        [[ "${f_group[i]}" != "$1" ]] || n=$((n + 1))
    done
    printf '%d\n' "${n}"
}

count_kind() {
    local i n=0
    for i in ${f_group[@]+"${!f_group[@]}"}; do
        [[ "${f_group[i]}" != ignore || "${f_kind[i]}" != "$1" ]] || n=$((n + 1))
    done
    printf '%d\n' "${n}"
}

# "1 command you installed" or "3 commands you installed".
count_of() {
    if [[ "$1" -eq 1 ]]; then
        printf '%d %s\n' "$1" "$2"
    else
        printf '%d %s\n' "$1" "$3"
    fi
}

# The path column fits the longest path shown, within limits.
WIDTH=24
set_width() {
    local i shown len
    for i in ${f_group[@]+"${!f_group[@]}"}; do
        shown=0
        case "${f_group[i]}" in
            fix | decide | unmanaged) shown=1 ;;
            ignore) [[ "${SHOW_ALL}" -eq 0 ]] || shown=1 ;;
        esac
        [[ "${shown}" -eq 1 ]] || continue
        len="$(display_path "${f_path[i]}")"
        len="${#len}"
        [[ "${len}" -le "${WIDTH}" || "${len}" -gt 44 ]] || WIDTH="${len}"
    done
}

# One row of the report: the path, its size, and a note, with xdg-ninja's
# advice under it. A path too long for its column gets a line of its own.
print_row() {
    local path="$1" size="$2" note="$3" how="${4:-}"

    if [[ "${#path}" -gt "${WIDTH}" ]]; then
        printf '  %s\n' "${path}"
        path=""
    fi
    printf '  %-*s %6s  %s\n' "${WIDTH}" "${path}" "${size}" "${note}"
    [[ -z "${how}" ]] || printf '  %-*s %6s  %show: %s%s\n' "${WIDTH}" "" "" "${DIM}" "${how}" "${RESET}"
}

print_items() {
    local group="$1" i path note

    for i in ${f_group[@]+"${!f_group[@]}"}; do
        [[ "${f_group[i]}" == "${group}" ]] || continue
        path="$(printable "$(display_path "${f_path[i]}")")"
        note="$(printable "${f_reason[i]}")"
        case "${group}" in
            links)
                printf '  %s  %s%s%s\n    %s%s%s\n' "${path}" "${RED}" "${f_action[i]}" "${RESET}" "${DIM}" "${note}" "${RESET}"
                continue
                ;;
            fix) note="${YELLOW}${f_action[i]}${RESET}: ${note}" ;;
            decide) [[ "${f_action[i]}" != archive ]] || note="${note} ${YELLOW}· likely leftover${RESET}" ;;
        esac
        measure "${i}"
        print_row "${path}" "${f_size[i]}" "${note}" "$(printable "${f_how[i]}")"
    done
}

# The Ignore items by kind, each kind under its own heading; the note is left
# out where the heading already says it.
print_ignored() {
    local kind title i note

    for kind in use state system noxdg marked; do
        [[ "$(count_kind "${kind}")" -gt 0 ]] || continue
        case "${kind}" in
            use) title="In use" ;;
            state) title="Local state" ;;
            system) title="Made by the OS (critical: removing it breaks something)" ;;
            noxdg) title="No XDG support" ;;
            marked) title="Marked to ignore (df-doctor --unignore PATH reports one again)" ;;
        esac
        printf '  %s%s%s\n' "${DIM}" "${title}" "${RESET}"
        for i in ${f_group[@]+"${!f_group[@]}"}; do
            [[ "${f_group[i]}" == ignore && "${f_kind[i]}" == "${kind}" ]] || continue
            note="$(printable "${f_reason[i]}")"
            case "${note}" in
                "local state" | "marked to ignore") note="" ;;
            esac
            note="${note#in use }" note="${note%: no XDG support}"
            if [[ -n "${note}" ]]; then
                printf '    %-*s  %s%s%s\n' "${WIDTH}" "$(printable "$(display_path "${f_path[i]}")")" "${DIM}" "${note}" "${RESET}"
            else
                printf '    %s\n' "$(printable "$(display_path "${f_path[i]}")")"
            fi
        done
    done
}

print_backups() {
    local path count=0 oldest=0 age

    for path in "${DEST_DIR}/.local/state/dotfiles/clobbered/"* "${DEST_DIR}/.local/state/dotfiles/cleanup/"*; do
        [[ -e "${path}" ]] || continue
        count=$((count + 1))
        age="$(age_days "${path}")"
        [[ "${age}" -le "${oldest}" ]] || oldest="${age}"
    done
    [[ "${count}" -gt 0 ]] || return 0
    printf '\n%sBackups: %s under %s (oldest: %s); restore from them by hand, and remove them once unneeded.%s\n' \
        "${DIM}" "$(count_of "${count}" "saved copy" "saved copies")" "$(display_path "${DEST_DIR}/.local/state/dotfiles")" "$(count_of "${oldest}" "day" "days")" "${RESET}"
}

# A group's heading: its name and count in its color, then what it means.
print_heading() {
    printf '\n%s%s (%d)%s  %s%s%s\n' "${BOLD}$1" "$2" "$3" "${RESET}" "${DIM}" "$4" "${RESET}"
}

print_report() {
    local links fix decide unmanaged ignored parts="" counts=""
    local use state system critical noxdg marked i

    set_width
    links="$(count_group links)" fix="$(count_group fix)" decide="$(count_group decide)" unmanaged="$(count_group unmanaged)" ignored="$(count_group ignore)"
    use="$(count_kind use)" state="$(count_kind state)" system="$(count_kind system)" noxdg="$(count_kind noxdg)" marked="$(count_kind marked)"
    critical=0
    for i in ${f_kind[@]+"${!f_kind[@]}"}; do
        [[ "${f_kind[i]}" != system || "${f_reason[i]}" != critical:* ]] || critical=$((critical + 1))
    done
    [[ "${use}" -eq 0 ]] || parts="${parts:+${parts} · }${use} in use"
    [[ "${state}" -eq 0 ]] || parts="${parts:+${parts} · }$(count_of "${state}" "local state file" "local state files")"
    [[ "${system}" -eq 0 ]] || parts="${parts:+${parts} · }${system} made by the OS (${critical} critical)"
    [[ "${noxdg}" -eq 0 ]] || parts="${parts:+${parts} · }${noxdg} without XDG support"
    [[ "${marked}" -eq 0 ]] || parts="${parts:+${parts} · }${marked} marked to ignore"

    printf '%sdf-doctor%s %s\n' "${BOLD}" "${RESET}" "$(display_path "${DEST_DIR}")"
    if [[ "${REVIEW_INCOMPLETE}" -ne 0 ]]; then
        printf '%sThe check is incomplete: see the warnings above. Fixes are unavailable until it completes.%s\n' "${RED}" "${RESET}"
    elif [[ "$((links + fix + decide + unmanaged))" -eq 0 ]]; then
        printf '%s✓ Nothing to fix%s, %d ignored\n' "${GREEN}" "${RESET}" "${ignored}"
    else
        [[ "${links}" -eq 0 ]] || counts="${RED}$(count_of "${links}" "repo link off" "repo links off")${RESET} · "
        printf '%s%s%d to fix%s · %s%d to decide%s · %s%d not in the repo%s · %d ignored\n' "${counts}" \
            "${YELLOW}" "${fix}" "${RESET}" "${MAGENTA}" "${decide}" "${RESET}" "${CYAN}" "${unmanaged}" "${RESET}" "${ignored}"
    fi

    if [[ "${links}" -gt 0 ]]; then
        print_heading "${RED}" Links "${links}" "repair these, then run df-link"
        print_items links
    fi
    if [[ "${fix}" -gt 0 ]]; then
        print_heading "${YELLOW}" Fix "${fix}" "df-doctor suggests these changes"
        print_items fix
    fi
    if [[ "${decide}" -gt 0 ]]; then
        print_heading "${MAGENTA}" Decide "${decide}" "needs you"
        print_items decide
    fi
    if [[ "${unmanaged}" -gt 0 ]]; then
        print_heading "${CYAN}" "Not in the repo" "${unmanaged}" "config and commands made outside the repo"
        print_items unmanaged
    fi
    if [[ "${ignored}" -gt 0 ]]; then
        if [[ "${SHOW_ALL}" -eq 1 ]]; then
            print_heading "" Ignore "${ignored}" "${parts}"
            print_ignored
        else
            print_heading "" Ignore "${ignored}" "${parts}  (--all lists them)"
        fi
    fi
    print_backups
    [[ -n "${XDG_DB}" ]] || printf '\n%sxdg-ninja data or jq not found, so no XDG advice.%s\n' "${DIM}" "${RESET}"

    [[ "${HINT}" -eq 1 && "${FIX}" -eq 0 && "$((fix + decide + unmanaged))" -gt 0 ]] || return 0
    printf '\nRun df-doctor in a terminal (or with --fix) to choose a change for each item.\n'
}

print_tsv() {
    local i
    for i in ${f_path[@]+"${!f_path[@]}"}; do
        printf '%s\t%s\t%s\t%s\t%s\n' "${f_group[i]}" "$(printable "${f_path[i]}")" "${f_action[i]}" "$(printable "${f_target[i]}")" "$(printable "${f_reason[i]}")"
    done
}

# Everything known about one path, with xdg-ninja's full advice for it.
explain() {
    local path i name help
    path="$(absolute_path "${EXPLAIN}")"
    if ! i="$(finding_index "${path}")"; then
        printf 'df-doctor has nothing to report about %s: it is managed, protected, or not checked.\n' "$(printable "$(display_path "${path}")")"
        return 1
    fi
    printf '%s\n' "$(printable "$(display_path "${path}")")"
    printf '  group:      %s\n' "${f_group[i]}"
    [[ "${f_group[i]}" == ignore || "${f_group[i]}" == links ]] || printf '  suggestion: %s%s\n' "${f_action[i]}" "${f_target[i]:+ to $(printable "$(display_path "${f_target[i]}")")}"
    printf '  why:        %s\n' "$(printable "${f_reason[i]}")"
    [[ ! -e "${path}" ]] || printf '  size:       %s, %s\n' "$(size_of "${path}")" "$(age_text "$(age_days "${path}")")"
    [[ "${f_fixable[i]}" -eq 1 ]] || printf '  df-doctor will not change it.\n'
    [[ "${f_kind[i]}" != marked ]] || printf '  df-doctor --unignore %s reports it again.\n' "$(printable "$(display_path "$(ignored_by "${path}")")")"
    name="${path##*/}"
    if [[ "${path%/*}" == "${DEST_DIR}" && -n "${XDG_PROGRAMS}" ]] && command -v jq >/dev/null 2>&1; then
        help="$(jq -r --arg p "\$HOME/${name}" '.name as $n | .files[] | select(.path == $p) | "xdg-ninja (\($n)):\n\(.help)"' "${XDG_PROGRAMS}"/*.json 2>/dev/null </dev/null || true)"
        [[ -z "${help}" ]] || printf '\n%s\n' "${help}"
    fi
}

# --- Fixing --------------------------------------------------------------------

archive_paths() {
    local path="" archive="" relative=""

    for path in "${DEST_DIR}/.local" "${DEST_DIR}/.local/state" "${DEST_DIR}/.local/state/dotfiles" "${DEST_DIR}/.local/state/dotfiles/cleanup"; do
        if [[ -L "${path}" ]]; then
            log_error "Archive parent is a symlink: ${path}; nothing changed"
            return 1
        fi
    done
    umask 077
    mkdir -p "${DEST_DIR}/.local/state/dotfiles/cleanup"
    archive="$(mktemp -d "${DEST_DIR}/.local/state/dotfiles/cleanup/$(date +%Y%m%d-%H%M%S).XXXXXX")"
    printf '\nArchive: %s\n' "$(display_path "${archive}")"
    for path in "$@"; do
        [[ -e "${path}" || -L "${path}" ]] || continue
        relative="${path#"${DEST_DIR}"/}"
        mkdir -p "${archive}/$(dirname "${relative}")"
        mv "${path}" "${archive}/${relative}"
        printf '  archived %s\n' "$(display_path "${path}")"
    done
    printf 'Each file keeps its path under the archive; move one back under %s to restore it, checking for conflicts first.\n' "$(display_path "${DEST_DIR}")"
}

# Device number of the path, or of its nearest existing parent.
device_of() {
    local path="$1"
    while [[ ! -e "${path}" && "${path}" == /* && "${path}" != / ]]; do
        path="${path%/*}"
        path="${path:-/}"
    done
    stat -c %d "${path}" 2>/dev/null || stat -f %d "${path}"
}

# Whether a running program has the path, or anything under it, open. macOS
# keeps lsof in /usr/sbin, which a minimal PATH leaves out. Without lsof (a
# minimal Debian) this cannot be known, and the move goes ahead.
in_use() {
    local lsof candidate
    lsof="$(command -v lsof 2>/dev/null)" || lsof=""
    for candidate in /usr/sbin/lsof /usr/bin/lsof; do
        [[ -n "${lsof}" ]] || { [[ -x "${candidate}" ]] && lsof="${candidate}"; }
    done
    [[ -n "${lsof}" ]] || return 1
    if [[ -d "$1" ]]; then
        [[ -n "$("${lsof}" -t +D "$1" 2>/dev/null)" ]]
    else
        [[ -n "$("${lsof}" -t -- "$1" 2>/dev/null)" ]]
    fi
}

# Rename each path to its xdg-ninja target, refusing unsafe moves; each is
# logged with its undo.
move_paths() {
    local path="" target="" parent="" i log="${DEST_DIR}/.local/state/dotfiles/moves.tsv" failed=0

    for parent in "${DEST_DIR}/.local" "${DEST_DIR}/.local/state" "${DEST_DIR}/.local/state/dotfiles"; do
        if [[ -L "${parent}" ]]; then
            log_error "Move log parent is a symlink: ${parent}; nothing moved"
            return 1
        fi
    done
    printf '\nMoving to XDG paths (log: %s)\n' "$(display_path "${log}")"
    for path in "$@"; do
        [[ -e "${path}" || -L "${path}" ]] || continue
        target=""
        if i="$(finding_index "${path}")"; then
            target="${f_target[i]}"
        fi
        if [[ -z "${target}" || "${target}" != "${DEST_DIR}/"* || "${target}" == *"/../"* || "${target}" == *"/./"* ]]; then
            log_warn "Not moved: $(display_path "${path}") has no target inside ${DEST_DIR}"
            failed=1
            continue
        fi
        if [[ -L "${path}" ]]; then
            log_warn "Not moved: $(display_path "${path}") is a symlink; move it by hand"
            failed=1
            continue
        fi
        if [[ -e "${target}" || -L "${target}" ]]; then
            log_warn "Not moved: $(display_path "${target}") already exists; merge $(display_path "${path}") into it by hand or archive it"
            failed=1
            continue
        fi
        parent="${target%/*}"
        while [[ "${parent}" != "${DEST_DIR}" ]]; do
            if [[ -L "${parent}" ]]; then
                log_warn "Not moved: $(display_path "${parent}") is a symlink"
                failed=1
                continue 2
            fi
            parent="${parent%/*}"
        done
        if [[ "$(device_of "${path}")" != "$(device_of "${target}")" ]]; then
            log_warn "Not moved: $(display_path "${target}") is on another filesystem; move it by hand"
            failed=1
            continue
        fi
        if in_use "${path}"; then
            log_warn "Not moved: a running program has $(display_path "${path}") open; quit it (colima stop, for one) and run df-doctor again"
            failed=1
            continue
        fi
        mkdir -p "${target%/*}"
        if ! mv -n -- "${path}" "${target}" || [[ -e "${path}" || -L "${path}" || ! ( -e "${target}" || -L "${target}" ) ]]; then
            log_warn "Not moved: $(display_path "${path}")"
            failed=1
            continue
        fi
        mkdir -p "${log%/*}"
        printf '%s\t%s\t%s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "${path}" "${target}" >> "${log}"
        printf '  moved %s to %s (undo: mv %s %s)\n' "$(display_path "${path}")" "$(display_path "${target}")" "$(display_path "${target}")" "$(display_path "${path}")"
    done
    return "${failed}"
}

# Starts managing each path through link.sh add, one call per path so a
# refusal or a declined layer leaves the others unaffected.
manage_paths() {
    local path="" failed=0

    for path in "$@"; do
        [[ -e "${path}" || -L "${path}" ]] || continue
        printf '\nManaging %s\n' "$(display_path "${path}")"
        if ! link_script add "${path}"; then
            log_warn "Not managed: $(display_path "${path}")"
            failed=1
        fi
    done
    return "${failed}"
}

# The changes a row of the list can take, in the order space cycles through
# them: a finding's, or the one row for repo links df-link can repair.
row_choices() {
    if [[ "$1" == relink ]]; then
        printf 'skip relink\n'
    else
        printf 'skip archive delete ignore add%s\n' "${f_target[$1]:+ move}"
    fi
}

# Sets row R of the caller's list to ACTION when the row offers it.
set_row_action() {
    local r="$1" action="$2"
    case " $(row_choices "${row_ids[r]}") " in
        *" ${action} "*) row_actions[r]="${action}" ;;
        *) return 1 ;;
    esac
}

# An action padded to its column, colored on a terminal.
action_cell() {
    local color=""
    if [[ -n "${BOLD}" ]]; then
        case "$1" in
            archive | move) color="${YELLOW}" ;;
            delete) color="${RED}" ;;
            add | relink) color="${GREEN}" ;;
            skip | ignore) color="${DIM}" ;;
        esac
    fi
    printf '%s%-7s%s' "${color}" "$1" "${color:+${RESET}}"
}

# Two lines about row R for the foot of the list: its group and full reason,
# then xdg-ninja's advice, where a move goes, or the full path.
row_detail() {
    local i="${row_ids[$1]}" group

    if [[ "${i}" == relink ]]; then
        printf 'Links: df-link links what is missing and clears stale links\n%s\n' "${relink_paths}"
        return
    fi
    case "${f_group[i]}" in
        fix) group=Fix ;;
        decide) group=Decide ;;
        *) group="Not in the repo" ;;
    esac
    printf '%s: %s\n' "${group}" "$(printable "${f_reason[i]}")"
    if [[ -n "${f_how[i]}" ]]; then
        printf 'how: %s\n' "$(printable "${f_how[i]}")"
    elif [[ -n "${f_target[i]}" ]]; then
        printf 'move goes to %s\n' "$(printable "$(display_path "${f_target[i]}")")"
    else
        printf '%s\n' "$(printable "$(display_path "${f_path[i]}")")"
    fi
}

# What Enter would change, such as "archive 2 · delete 1", or "nothing".
row_tally() {
    local action r n out=""

    for action in archive delete move add ignore relink; do
        n=0
        for r in "${!row_actions[@]}"; do
            [[ "${row_actions[r]}" != "${action}" ]] || n=$((n + 1))
        done
        [[ "${n}" -eq 0 ]] || out="${out:+${out} · }${action} ${n}"
    done
    printf '%s\n' "${out:-nothing}"
}

# The list on a terminal, drawn on the alternate screen: one row per item,
# its change set by a key, with the highlighted row's details and what Enter
# would change at the foot. Returns 1 when cancelled.
pick_on_terminal() {
    local cursor=0 top=0 key rest size lines cols height r last note="" status=0 detail line1 line2
    local count="${#row_ids[@]}"
    local -a cycle=()
    local actions="s skip (leave it)  a archive  d delete  i ignore  r add to repo  m move"
    local keys="↑↓ PgUp PgDn Home End choose a row  space next change  enter apply all  q cancel"

    # Ctrl-C leaves the alternate screen too.
    trap 'printf "\033[?25h\033[?1049l" >&2; exit 130' INT
    printf '\033[?1049h\033[?25l' >&2
    while :; do
        size="$(stty size 2>/dev/null || printf '24 80')"
        lines="${size% *}" cols="${size#* }"
        # A terminal that reports no size (0 0) gets the usual 24 by 80.
        [[ "${lines}" =~ ^[1-9][0-9]*$ ]] || lines=24
        [[ "${cols}" =~ ^[1-9][0-9]*$ && "${cols}" -ge 20 ]] || cols=80
        # Three lines above the rows and three below.
        height=$((lines - 7))
        [[ "${height}" -ge 3 ]] || height=3
        [[ "${cursor}" -ge "${top}" ]] || top="${cursor}"
        [[ "${cursor}" -lt $((top + height)) ]] || top=$((cursor - height + 1))
        last=$((top + height))
        [[ "${last}" -le "${count}" ]] || last="${count}"
        {
            printf '\033[H\033[2J%sChoose a change for each item%s (%d)\n' "${BOLD}" "${RESET}" "${count}"
            printf '%s\n%s%s%s\n' "${actions:0:${cols}}" "${DIM}" "${keys:0:${cols}}" "${RESET}"
            for ((r = top; r < last; r++)); do
                if [[ "${r}" -eq "${cursor}" ]]; then
                    printf '%s> %s %s%s\n' "${BOLD}" "$(action_cell "${row_actions[r]}")" "${row_texts[r]:0:$((cols - 12))}" "${RESET}"
                else
                    printf '  %s %s\n' "$(action_cell "${row_actions[r]}")" "${row_texts[r]:0:$((cols - 12))}"
                fi
            done
            for ((r = last - top; r < height; r++)); do
                printf '\n'
            done
            [[ "${count}" -le "${height}" ]] || printf '%s%d-%d of %d%s  ' "${DIM}" "$((top + 1))" "${last}" "${count}" "${RESET}"
            if [[ -n "${note}" ]]; then
                printf '%s%s%s\n' "${YELLOW}" "${note}" "${RESET}"
            else
                printf 'Enter: %s\n' "$(row_tally)"
            fi
            detail="$(row_detail "${cursor}")"
            line1="${detail%%$'\n'*}" line2="${detail#*$'\n'}"
            printf '%s%s%s\n' "${BOLD}" "${line1:0:${cols}}" "${RESET}"
            printf '%s%s%s' "${DIM}" "${line2:0:${cols}}" "${RESET}"
        } >&2
        note=""
        IFS= read -rsn1 key || key=q
        case "${key}" in
            $'\033')
                IFS= read -rsn2 -t 1 rest || rest=""
                case "${rest}" in
                    '[A') [[ "${cursor}" -eq 0 ]] || cursor=$((cursor - 1)) ;;
                    '[B') [[ "${cursor}" -ge $((count - 1)) ]] || cursor=$((cursor + 1)) ;;
                    '[H' | 'OH') cursor=0 ;;
                    '[F' | 'OF') cursor=$((count - 1)) ;;
                    '[5' | '[6')
                        IFS= read -rsn1 -t 1 key || key=""
                        if [[ "${rest}" == '[5' ]]; then
                            cursor=$((cursor - height))
                            [[ "${cursor}" -ge 0 ]] || cursor=0
                        else
                            cursor=$((cursor + height))
                            [[ "${cursor}" -lt "${count}" ]] || cursor=$((count - 1))
                        fi
                        ;;
                    *) status=1; break ;;
                esac
                ;;
            ' ')
                read -r -a cycle <<< "$(row_choices "${row_ids[cursor]}")"
                for ((r = 0; r < ${#cycle[@]}; r++)); do
                    [[ "${cycle[r]}" == "${row_actions[cursor]}" ]] || continue
                    row_actions[cursor]="${cycle[$(((r + 1) % ${#cycle[@]}))]}"
                    break
                done
                ;;
            s | a | d | i | r | + | m)
                case "${key}" in
                    a) key=archive ;;
                    d) key=delete ;;
                    i) key=ignore ;;
                    r | +) key=add ;;
                    m) key=move ;;
                    s) key=skip ;;
                esac
                [[ "${row_ids[cursor]}" != relink || "${key}" == skip ]] || key=relink
                set_row_action "${cursor}" "${key}" || note="${key} is not offered for this item"
                ;;
            '') break ;;
            q) status=1; break ;;
        esac
    done
    printf '\033[?25h\033[?1049l' >&2
    trap - INT
    return "${status}"
}

# The list without a terminal (or with DOTFILES_PROMPT=read): numbered rows,
# then one line of actions and row numbers. Returns 1 on a line it cannot
# read, changing no row.
pick_by_line() {
    local r reply token action="" from to
    local -a picked=()

    printf '%s\n' "Choose a change for each item:" >&2
    for r in "${!row_ids[@]}"; do
        printf '  %2d) %s %s\n' "$((r + 1))" "$(action_cell "${row_actions[r]}")" "${row_texts[r]}" >&2
    done
    printf 'Actions then row numbers, like "delete 2 5-7 ignore 3" (skip, archive, delete, ignore, add, move, relink); none skips everything; Enter applies the list as shown: ' >&2
    IFS= read -r reply || return 1
    picked=(${row_actions[@]+"${row_actions[@]}"})
    # Unquoted on purpose: the line splits into words.
    for token in ${reply}; do
        case "${token}" in
            none)
                for r in "${!picked[@]}"; do
                    picked[r]=skip
                done
                ;;
            # keep is the old name for skip.
            keep) action=skip ;;
            skip | archive | delete | ignore | add | move | relink) action="${token}" ;;
            *)
                if [[ -z "${action}" || ! "${token}" =~ ^([0-9]{1,6})(-([0-9]{1,6}))?$ ]]; then
                    log_warn "Not understood: ${token}; nothing changed"
                    return 1
                fi
                from="${BASH_REMATCH[1]}" to="${BASH_REMATCH[3]:-${BASH_REMATCH[1]}}"
                if [[ "${from}" -lt 1 || "${to}" -gt "${#row_ids[@]}" || "${from}" -gt "${to}" ]]; then
                    log_warn "No such row: ${token}; nothing changed"
                    return 1
                fi
                for ((r = from - 1; r < to; r++)); do
                    case " $(row_choices "${row_ids[r]}") " in
                        *" ${action} "*) picked[r]="${action}" ;;
                        *)
                            log_warn "Row $((r + 1)) cannot ${action}; nothing changed"
                            return 1
                            ;;
                    esac
                done
                ;;
        esac
    done
    row_actions=(${picked[@]+"${picked[@]}"})
}

# Build the change list (Fix rows preset, links to relink, the rest skip),
# ask once, apply. Deleting asks again; a cancelled list changes nothing.
fix_flow() {
    local i r group relink=0 failed=0 answer summary="" relink_paths=""
    local -a row_ids=() row_actions=() row_texts=() to_archive=() to_delete=() to_move=() to_manage=() to_ignore=()

    if [[ "${REVIEW_INCOMPLETE}" -ne 0 ]]; then
        log_warn "Fixes unavailable because the check is incomplete"
        return 0
    fi
    set_width
    for i in ${f_group[@]+"${!f_group[@]}"}; do
        [[ "${f_group[i]}" == links ]] || continue
        case "${f_action[i]}" in
            missing | stale)
                relink=$((relink + 1))
                relink_paths="${relink_paths:+${relink_paths} }$(printable "$(display_path "${f_path[i]}")")"
                ;;
        esac
    done
    if [[ "${relink}" -gt 0 ]]; then
        row_ids+=(relink)
        row_actions+=(relink)
        row_texts+=("$(count_of "${relink}" "missing or stale repo link" "missing or stale repo links"); df-link repairs them")
    fi
    # Rows in the report's order: Fix, Decide, then Not in the repo.
    for group in fix decide unmanaged; do
        for i in ${f_group[@]+"${!f_group[@]}"}; do
            [[ "${f_group[i]}" == "${group}" && "${f_fixable[i]}" -eq 1 ]] || continue
            if [[ "${group}" == fix ]]; then
                row_actions+=("${f_action[i]}")
            else
                row_actions+=(skip)
            fi
            measure "${i}"
            row_ids+=("${i}")
            row_texts+=("$(printf '%-*s %6s  %s' "${WIDTH}" "$(printable "$(display_path "${f_path[i]}")")" "${f_size[i]}" "$(printable "${f_reason[i]}")")")
        done
    done
    if [[ "${#row_ids[@]}" -eq 0 ]]; then
        printf 'Nothing to fix.\n'
        return 0
    fi
    # Closed stdin cannot answer: say so instead of printing a question.
    if [[ ! -t 0 && /dev/stdin -ef /dev/null ]]; then
        printf 'Nothing changed: df-doctor asks before changing anything, and stdin is closed.\n'
        return 0
    fi

    printf '\n' >&2
    if [[ "${DOTFILES_PROMPT:-}" != read && -t 0 && -t 2 ]]; then
        pick_on_terminal || { printf 'Nothing changed.\n'; return 0; }
    else
        pick_by_line || { printf 'Nothing changed.\n'; return 0; }
    fi

    relink=0
    for r in "${!row_ids[@]}"; do
        i="${row_ids[r]}"
        case "${row_actions[r]}" in
            archive) to_archive+=("${f_path[i]}") ;;
            delete) to_delete+=("${f_path[i]}") ;;
            move) to_move+=("${f_path[i]}") ;;
            add) to_manage+=("${f_path[i]}") ;;
            ignore) to_ignore+=("${f_path[i]}") ;;
            relink) relink=1 ;;
        esac
    done
    if [[ "${#to_delete[@]}" -gt 0 ]]; then
        printf 'Delete for good, with no copy kept:\n'
        for i in "${to_delete[@]}"; do
            printf '  %s\n' "$(printable "$(display_path "${i}")")"
        done
        if [[ "$(prompt_mode)" == gum ]]; then
            answer=""
            gum confirm --default=false "Delete $(count_of "${#to_delete[@]}" item items) for good?" && answer=y
        else
            printf 'Delete %s? [y/N] ' "$(count_of "${#to_delete[@]}" item items)" >&2
            IFS= read -r answer || answer=""
        fi
        case "${answer}" in
            y | Y | yes) ;;
            *)
                printf 'Not deleting them.\n'
                to_delete=()
                ;;
        esac
    fi
    if [[ "${#to_archive[@]}" -eq 0 && "${#to_delete[@]}" -eq 0 && "${#to_move[@]}" -eq 0 && "${#to_manage[@]}" -eq 0 && "${#to_ignore[@]}" -eq 0 && "${relink}" -eq 0 ]]; then
        printf 'Nothing changed.\n'
        return 0
    fi

    [[ "${#to_delete[@]}" -eq 0 ]] || summary="${summary:+${summary}, }deleted ${#to_delete[@]}"
    [[ "${#to_archive[@]}" -eq 0 ]] || summary="${summary:+${summary}, }archived ${#to_archive[@]}"
    [[ "${#to_move[@]}" -eq 0 ]] || summary="${summary:+${summary}, }moved ${#to_move[@]}"
    [[ "${#to_manage[@]}" -eq 0 ]] || summary="${summary:+${summary}, }added ${#to_manage[@]} to the repo"
    [[ "${#to_ignore[@]}" -eq 0 ]] || summary="${summary:+${summary}, }ignored ${#to_ignore[@]}"
    [[ "${relink}" -eq 0 ]] || summary="${summary:+${summary}, }repaired the repo links"

    apply_changes || failed=1
    if [[ "${relink}" -eq 1 ]]; then
        printf '\nRepairing repo links\n'
        link_script || failed=1
    fi
    printf '\n'
    if [[ "${failed}" -eq 0 ]]; then
        _success "Done: ${summary}."
    else
        _warn "Done, with problems: ${summary}; see the messages above."
    fi
    return "${failed}"
}

# Removes each path for good, a symlink itself rather than what it points to.
delete_paths() {
    local path failed=0

    printf '\n'
    for path in "$@"; do
        [[ -e "${path}" || -L "${path}" ]] || continue
        if rm -rf -- "${path}"; then
            printf '  deleted %s\n' "$(display_path "${path}")"
        else
            log_warn "Not deleted: $(display_path "${path}")"
            failed=1
        fi
    done
    return "${failed}"
}

# Applies the caller's to_delete, to_archive, to_move, to_manage, and
# to_ignore: deletes, then archives, moves, and adds, after checking nothing
# became managed meanwhile, and records the paths to ignore last.
apply_changes() {
    local path failed=0

    MANAGED_PATHS_CACHE=""
    prime_managed_paths_cache || return 1
    for path in ${to_delete[@]+"${to_delete[@]}"} ${to_archive[@]+"${to_archive[@]}"} ${to_move[@]+"${to_move[@]}"} ${to_manage[@]+"${to_manage[@]}"}; do
        if contains_managed_path "${path}"; then
            log_error "Managed paths changed during the check; nothing changed"
            return 1
        fi
    done
    if [[ "${#to_delete[@]}" -gt 0 ]]; then
        delete_paths "${to_delete[@]}" || failed=1
    fi
    if [[ "${#to_archive[@]}" -gt 0 ]]; then
        archive_paths "${to_archive[@]}" || return 1
    fi
    if [[ "${#to_move[@]}" -gt 0 ]]; then
        move_paths "${to_move[@]}" || failed=1
    fi
    if [[ "${#to_manage[@]}" -gt 0 ]]; then
        manage_paths "${to_manage[@]}" || failed=1
    fi
    if [[ "${#to_ignore[@]}" -gt 0 ]]; then
        mark_ignored "${to_ignore[@]}" || failed=1
    fi
    return "${failed}"
}

main() {
    local status=0

    parse_args "$@"
    if [[ ! -d "${SOURCE_DIR}" ]]; then
        log_error "dotfiles repo not found: ${SOURCE_DIR}"
        exit 1
    fi
    DEST_DIR="$(cd "${DEST_DIR}" && pwd -L)" || return 1
    SOURCE_DIR="$(cd "${SOURCE_DIR}" && pwd -L)" || return 1
    IGNORE_FILE="${DEST_DIR}/.local/state/dotfiles/doctor-ignore"
    shopt -s nullglob

    if [[ "${#ignore_add[@]}" -gt 0 || "${#ignore_remove[@]}" -gt 0 ]]; then
        load_ignored
        [[ "${#ignore_add[@]}" -eq 0 ]] || mark_ignored "${ignore_add[@]}" || status=1
        [[ "${#ignore_remove[@]}" -eq 0 ]] || unmark_ignored "${ignore_remove[@]}" || status=1
        return "${status}"
    fi

    # The check takes a few seconds; say so on a terminal, then clear the line.
    if [[ -t 2 && "${TSV}" -eq 0 && -z "${EXPLAIN}" ]]; then
        printf '%sChecking %s…%s' "${DIM}" "$(display_path "${DEST_DIR}")" "${RESET}" >&2
        collect || status=1
        printf '\r\033[K' >&2
        [[ "${status}" -eq 0 ]] || return 1
    else
        collect || return 1
    fi
    if [[ -n "${EXPLAIN}" ]]; then
        explain
        return
    fi
    if [[ "${TSV}" -eq 1 ]]; then
        print_tsv
        return "${REVIEW_INCOMPLETE}"
    fi
    # A terminal gets the list without asking for it.
    [[ "${FIX}" -eq 1 || "${REPORT_ONLY}" -eq 1 || ! -t 0 || ! -t 1 ]] || FIX=1
    [[ "${FIX_ONLY}" -eq 1 ]] || print_report
    if [[ "${FIX}" -eq 1 ]]; then
        fix_flow || status=1
    fi
    [[ "${REVIEW_INCOMPLETE}" -eq 0 ]] || status=1
    return "${status}"
}

# One line, so bash has read it all before main runs: an edit to this file
# during a run cannot make bash read past the end of the old version.
main "$@"; exit

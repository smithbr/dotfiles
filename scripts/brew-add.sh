#!/usr/bin/env bash
# Install Homebrew packages and record them in one of the repo's Brewfiles.
#
# Each name goes into the chosen Brewfile and section in sorted order among
# entries of its kind (brew or cask). A name already listed in any Brewfile is
# skipped. The package is installed before it is recorded, so a failed install
# leaves the Brewfile unchanged.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

REPO="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
BREW_DIR="${REPO}/homebrew"
DRY_RUN=0
INSTALL=1
KIND=""
FILE=""
SECTION=""
declare -a names=()

usage() {
    cat <<'EOF'
Usage: brew-add.sh [OPTIONS] NAME...

Install each package and add it to a Brewfile in homebrew/, sorted among the
entries of its kind. Names already in any Brewfile are skipped.

Options:
      --file NAME     Brewfile to add to: core, home, personal, work, macos (asked on a
                      terminal when missing; offers the persona's Brewfiles)
      --section NAME  Section (the comment above a group of entries) to add
                      to, when the Brewfile has more than one
      --cask          Add as casks (default: detect, preferring a formula)
      --formula       Add as formulae
      --no-install    Only record the entries
  -n, --dry-run       Report what would change without touching anything
  -h, --help          Show this help and exit
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--dry-run) DRY_RUN=1 ;;
            --no-install) INSTALL=0 ;;
            --cask) KIND=cask ;;
            --formula) KIND=brew ;;
            --file|--section)
                if [[ $# -lt 2 ]]; then
                    log_error "$1 requires a value"
                    exit 2
                fi
                case "$1" in
                    --file) FILE="$2" ;;
                    *) SECTION="$2" ;;
                esac
                shift
                ;;
            -h|--help) usage; exit 0 ;;
            -*)
                log_error "Unknown argument: $1"
                usage >&2
                exit 2
                ;;
            *)
                if [[ ! "$1" =~ ^[A-Za-z0-9@._+-]+(/[A-Za-z0-9@._+-]+/[A-Za-z0-9@._+-]+)?$ ]]; then
                    log_error "Not a package name: $1"
                    exit 2
                fi
                names+=("$1")
                ;;
        esac
        shift
    done
    if [[ "${#names[@]}" -eq 0 ]]; then
        log_error "Name at least one package"
        usage >&2
        exit 2
    fi
}

# Print a picked item from the arguments, asking with gum or a numbered list.
# Fails on closed stdin or when nothing is picked.
choose() {
    local header="$1" item choice index=1
    shift
    [[ -t 0 ]] || return 1
    if command -v gum >/dev/null 2>&1; then
        gum choose --header "${header}" "$@" || return 1
        return 0
    fi
    for item in "$@"; do
        printf '  %d) %s\n' "${index}" "${item}" >&2
        index=$((index + 1))
    done
    printf '%s [1-%d]: ' "${header}" "$#" >&2
    IFS= read -r choice || return 1
    [[ "${choice}" =~ ^[0-9]+$ && "${choice}" -ge 1 && "${choice}" -le $# ]] || return 1
    printf '%s\n' "${!choice}"
}

# The persona's Brewfile names (brew, then brew_optional), from link.sh.
persona_brewfiles() {
    local line
    local -a files=()
    while IFS= read -r line; do
        case "${line}" in
            brew=*|brew_optional=*)
                read -r -a files <<< "${line#*=}"
                [[ "${#files[@]}" -eq 0 ]] || printf '%s\n' "${files[@]}"
                ;;
        esac
    done < <(bash "${REPO}/scripts/link.sh" installs 2>/dev/null || true)
}

choose_file() {
    local name
    local -a offered=()

    if [[ -n "${FILE}" ]]; then
        FILE="${FILE#Brewfile.}"
        if [[ ! -f "${BREW_DIR}/Brewfile.${FILE}" ]]; then
            log_error "No such Brewfile: homebrew/Brewfile.${FILE}"
            exit 2
        fi
        return 0
    fi
    while IFS= read -r name; do
        [[ -n "${name}" && -f "${BREW_DIR}/Brewfile.${name}" ]] && offered+=("${name}")
    done < <(persona_brewfiles)
    if [[ "${#offered[@]}" -eq 0 ]]; then
        for name in "${BREW_DIR}"/Brewfile.*; do
            offered+=("${name##*/Brewfile.}")
        done
    fi
    if ! FILE="$(choose "Brewfile for ${names[*]}" "${offered[@]}")" || [[ -z "${FILE}" ]]; then
        log_error "Name the Brewfile with --file (one of: ${offered[*]})"
        exit 2
    fi
}

# Print "start end name" for each group of entries: a run of non-blank lines
# with at least one entry, named by its leading comment (empty when it has none).
brewfile_sections() {
    awk '
        function flush() {
            if (start && entries) printf "%d %d %s\n", start, NR - 1, name
            start = 0; entries = 0; name = ""
        }
        /^[[:space:]]*$/ { flush(); next }
        {
            if (!start) {
                start = NR
                if ($0 ~ /^#/) { name = $0; sub(/^#+[[:space:]]*/, "", name) }
            }
            if ($0 ~ /^(brew|cask|tap|mas) "/) entries = 1
        }
        END { NR++; flush() }
    ' "$1"
}

# Set SECTION_START and SECTION_END (0 0 when the file has no entries yet).
choose_section() {
    local file="$1" start end name wanted
    local -a starts=() ends=() labels=()
    wanted="$(printf '%s' "${SECTION}" | tr '[:upper:]' '[:lower:]')"

    while read -r start end name; do
        starts+=("${start}")
        ends+=("${end}")
        labels+=("${name:-(unnamed, line ${start})}")
        if [[ -n "${wanted}" && "$(printf '%s' "${name}" | tr '[:upper:]' '[:lower:]')" == "${wanted}" ]]; then
            SECTION_START="${start}"
            SECTION_END="${end}"
            SECTION="${name}"
            return 0
        fi
    done < <(brewfile_sections "${file}")

    if [[ -n "${SECTION}" ]]; then
        log_error "No section '${SECTION}' in ${file#"${REPO}"/} (sections: ${labels[*]:-none})"
        exit 2
    fi
    case "${#starts[@]}" in
        0) SECTION_START=0; SECTION_END=0; return 0 ;;
        1) SECTION_START="${starts[0]}"; SECTION_END="${ends[0]}"; SECTION="${labels[0]}"; return 0 ;;
    esac
    if ! SECTION="$(choose "Section of Brewfile.${FILE}" "${labels[@]}")" || [[ -z "${SECTION}" ]]; then
        log_error "Name the section with --section (one of: $(printf '"%s" ' "${labels[@]}"))"
        exit 2
    fi
    local i
    for i in "${!labels[@]}"; do
        if [[ "${labels[i]}" == "${SECTION}" ]]; then
            SECTION_START="${starts[i]}"
            SECTION_END="${ends[i]}"
        fi
    done
}

short_name() { printf '%s\n' "${1##*/}"; }

# Print "Brewfile.x" when any Brewfile already lists the package.
listed_in() {
    local name="$1" file entry
    for file in "${BREW_DIR}"/Brewfile.*; do
        while IFS= read -r entry; do
            if [[ "${entry}" == "${name}" || "$(short_name "${entry}")" == "$(short_name "${name}")" ]]; then
                printf '%s\n' "${file##*/}"
                return 0
            fi
        done < <(sed -nE 's/^(brew|cask) "([^"]+)".*/\2/p' "${file}")
    done
    return 1
}

detect_kind() {
    local name="$1"
    if [[ -n "${KIND}" ]]; then
        printf '%s\n' "${KIND}"
    elif brew info --formula "${name}" >/dev/null 2>&1; then
        printf 'brew\n'
    elif brew info --cask "${name}" >/dev/null 2>&1; then
        printf 'cask\n'
    else
        return 1
    fi
}

install_package() {
    local kind="$1" name="$2"
    local -a flag=(--formula)
    [[ "${kind}" == cask ]] && flag=(--cask)
    if brew list "${flag[@]}" "${name}" >/dev/null 2>&1; then
        log_info "${name} is already installed"
        return 0
    fi
    brew install "${flag[@]}" "${name}"
}

# Write the file with LINE inserted into lines START..END: before the first
# entry of the same kind that sorts after it, else after the last one of that
# kind; formulae go before casks and casks after everything else. With no
# section (START 0), the line starts a new group at the end of the file.
insert_entry() {
    local file="$1" start="$2" end="$3" kind="$4" name="$5" line="$6"
    local tmp
    tmp="$(mktemp "${file}.XXXXXX")"
    LC_ALL=C awk -v start="${start}" -v end="${end}" -v kind="${kind}" \
        -v name="${name}" -v line="${line}" '
        { lines[NR] = $0 }
        END {
            at = 0
            if (start) {
                for (i = start; i <= end; i++) {
                    if (lines[i] !~ /^(brew|cask|tap|mas) "/) continue
                    split(lines[i], parts, "\"")
                    type = substr(lines[i], 1, index(lines[i], " ") - 1)
                    if (type == kind) {
                        last = i
                        if (!at && parts[2] > name) at = i
                    } else if (kind == "brew" && !first_other && type != "tap") {
                        first_other = i
                    }
                }
                if (!at && last) at = last + 1
                if (!at && first_other) at = first_other
                if (!at) at = end + 1
            }
            for (i = 1; i <= NR; i++) {
                if (i == at) print line
                print lines[i]
            }
            if (!start) {
                if (NR && lines[NR] != "") print ""
                print line
            } else if (at > NR) {
                print line
            }
        }
    ' "${file}" > "${tmp}"
    cat "${tmp}" > "${file}"
    rm -f "${tmp}"
}

main() {
    parse_args "$@"
    if [[ ! -d "${BREW_DIR}" ]]; then
        log_error "No homebrew/ directory in ${REPO}"
        exit 1
    fi

    local name kind where file line added=0 in_section
    local -a pending_names=() pending_kinds=()

    for name in "${names[@]}"; do
        if where="$(listed_in "${name}")"; then
            log_info "${name} is already in ${where}; skipping"
            continue
        fi
        if [[ -z "${KIND}" ]] && ! command -v brew >/dev/null 2>&1; then
            log_error "Homebrew is needed to tell a formula from a cask; pass --formula or --cask"
            exit 1
        fi
        if ! kind="$(detect_kind "${name}")"; then
            log_error "No formula or cask named ${name}"
            exit 1
        fi
        pending_names+=("${name}")
        pending_kinds+=("${kind}")
    done
    [[ "${#pending_names[@]}" -gt 0 ]] || return 0

    choose_file
    file="${BREW_DIR}/Brewfile.${FILE}"
    choose_section "${file}"
    in_section=""
    [[ "${SECTION_START}" -gt 0 && -n "${SECTION}" ]] && in_section=" (${SECTION})"

    local i
    for i in "${!pending_names[@]}"; do
        name="${pending_names[i]}"
        kind="${pending_kinds[i]}"
        line="${kind} \"${name}\""
        if [[ "${DRY_RUN}" -eq 1 ]]; then
            printf 'Would add %s to homebrew/Brewfile.%s%s\n' "${line}" "${FILE}" "${in_section}"
            continue
        fi
        if [[ "${INSTALL}" -eq 1 ]]; then
            if ! command -v brew >/dev/null 2>&1; then
                log_error "Homebrew is not installed; pass --no-install to only record ${name}"
                exit 1
            fi
            if ! install_package "${kind}" "${name}"; then
                log_error "Installing ${name} failed; not adding it"
                exit 1
            fi
        fi
        insert_entry "${file}" "${SECTION_START}" "${SECTION_END}" "${kind}" "${name}" "${line}"
        # A new group now exists at the end; later names join it.
        if [[ "${SECTION_START}" -eq 0 ]]; then
            read -r SECTION_START SECTION_END _ < <(brewfile_sections "${file}" | tail -n 1)
        else
            SECTION_END=$((SECTION_END + 1))
        fi
        printf 'Added %s to homebrew/Brewfile.%s%s\n' "${line}" "${FILE}" "${in_section}"
        added=$((added + 1))
    done
    if [[ "${added}" -gt 0 ]]; then
        printf 'Commit it with: git -C %s add homebrew/Brewfile.%s\n' "${REPO}" "${FILE}"
    fi
}

main "$@"

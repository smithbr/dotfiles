#!/usr/bin/env bats
# Tests for homebrew/brew.sh — Brewfile parsing, entry_is_brew_managed, OS
# platform detection, and cask filtering.
# These tests extract and exercise individual functions without running brew.

load test_helper

setup() {
    setup_tmpdir
}

teardown() {
    teardown_tmpdir
}

# ---------------------------------------------------------------------------
# Brewfile line-parsing regex (extracted from install_filtered_brewfile)
# ---------------------------------------------------------------------------

_parse_brewfile_line() {
    local line="$1"
    if [[ "${line}" =~ ^(brew|cask|tap|mas)[[:space:]]+\"([^\"]+)\" ]]; then
        echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
    elif [[ "${line}" =~ ^(brew|cask|tap|mas)[[:space:]]+\'([^\']+)\' ]]; then
        echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
    else
        echo "SKIP"
    fi
}

@test "parses brew \"package\" line" {
    run _parse_brewfile_line 'brew "git"'
    assert_success
    assert_output "brew git"
}

@test "parses cask \"package\" line" {
    run _parse_brewfile_line 'cask "1password-cli"'
    assert_success
    assert_output "cask 1password-cli"
}

@test "parses tap \"repo\" line" {
    run _parse_brewfile_line 'tap "homebrew/cask-fonts"'
    assert_success
    assert_output "tap homebrew/cask-fonts"
}

@test "parses mas \"app\" line" {
    run _parse_brewfile_line 'mas "Xcode"'
    assert_success
    assert_output "mas Xcode"
}

@test "parses single-quoted entries" {
    run _parse_brewfile_line "brew 'ripgrep'"
    assert_success
    assert_output "brew ripgrep"
}

@test "skips comment lines" {
    run _parse_brewfile_line '# This is a comment'
    assert_success
    assert_output "SKIP"
}

@test "skips blank lines" {
    run _parse_brewfile_line ''
    assert_success
    assert_output "SKIP"
}

@test "parses brew entry with args" {
    run _parse_brewfile_line 'brew "xdg-ninja", args:["--HEAD"]'
    assert_success
    assert_output "brew xdg-ninja"
}

# ---------------------------------------------------------------------------
# entry_is_brew_managed
# ---------------------------------------------------------------------------

@test "entry_is_brew_managed returns true for installed formula" {
    run bash -c '
        _installed_formulae=" git curl zsh "
        _installed_casks=" 1password-cli "
        _installed_taps=" homebrew/core "

        _brew_has_formula() { [[ "${_installed_formulae}" == *" $1 "* ]]; }
        _brew_has_cask()    { [[ "${_installed_casks}" == *" $1 "* ]]; }
        _brew_has_tap()     { [[ "${_installed_taps}" == *" $1 "* ]]; }

        entry_is_brew_managed() {
            local pkg_type="$1" pkg_name="$2"
            case "${pkg_type}" in
                brew) _brew_has_formula "${pkg_name}" && return 0 ;;
                cask) _brew_has_cask "${pkg_name}" && return 0 ;;
                tap)  _brew_has_tap "${pkg_name}" && return 0 ;;
            esac
            return 1
        }

        entry_is_brew_managed brew git && echo "MANAGED" || echo "NOT_MANAGED"
    '
    assert_success
    assert_output "MANAGED"
}

@test "entry_is_brew_managed returns false for missing formula" {
    run bash -c '
        _installed_formulae=" git curl "
        _installed_casks=""
        _installed_taps=""

        _brew_has_formula() { [[ "${_installed_formulae}" == *" $1 "* ]]; }
        _brew_has_cask()    { [[ "${_installed_casks}" == *" $1 "* ]]; }
        _brew_has_tap()     { [[ "${_installed_taps}" == *" $1 "* ]]; }

        entry_is_brew_managed() {
            local pkg_type="$1" pkg_name="$2"
            case "${pkg_type}" in
                brew) _brew_has_formula "${pkg_name}" && return 0 ;;
                cask) _brew_has_cask "${pkg_name}" && return 0 ;;
                tap)  _brew_has_tap "${pkg_name}" && return 0 ;;
            esac
            return 1
        }

        entry_is_brew_managed brew ripgrep && echo "MANAGED" || echo "NOT_MANAGED"
    '
    assert_success
    assert_output "NOT_MANAGED"
}

@test "entry_is_brew_managed detects installed cask" {
    run bash -c '
        _installed_formulae=""
        _installed_casks=" 1password-cli font-hack-nerd-font "
        _installed_taps=""

        _brew_has_formula() { [[ "${_installed_formulae}" == *" $1 "* ]]; }
        _brew_has_cask()    { [[ "${_installed_casks}" == *" $1 "* ]]; }
        _brew_has_tap()     { [[ "${_installed_taps}" == *" $1 "* ]]; }

        entry_is_brew_managed() {
            local pkg_type="$1" pkg_name="$2"
            case "${pkg_type}" in
                brew) _brew_has_formula "${pkg_name}" && return 0 ;;
                cask) _brew_has_cask "${pkg_name}" && return 0 ;;
                tap)  _brew_has_tap "${pkg_name}" && return 0 ;;
            esac
            return 1
        }

        entry_is_brew_managed cask 1password-cli && echo "MANAGED" || echo "NOT_MANAGED"
    '
    assert_success
    assert_output "MANAGED"
}

@test "entry_is_brew_managed detects installed tap" {
    run bash -c '
        _installed_formulae=""
        _installed_casks=""
        _installed_taps=" homebrew/core homebrew/cask "

        _brew_has_formula() { [[ "${_installed_formulae}" == *" $1 "* ]]; }
        _brew_has_cask()    { [[ "${_installed_casks}" == *" $1 "* ]]; }
        _brew_has_tap()     { [[ "${_installed_taps}" == *" $1 "* ]]; }

        entry_is_brew_managed() {
            local pkg_type="$1" pkg_name="$2"
            case "${pkg_type}" in
                brew) _brew_has_formula "${pkg_name}" && return 0 ;;
                cask) _brew_has_cask "${pkg_name}" && return 0 ;;
                tap)  _brew_has_tap "${pkg_name}" && return 0 ;;
            esac
            return 1
        }

        entry_is_brew_managed tap homebrew/cask && echo "MANAGED" || echo "NOT_MANAGED"
    '
    assert_success
    assert_output "MANAGED"
}

@test "optional cask detection treats matching app bundle as already installed" {
    run bash -c '
        set -euo pipefail

        os_name="Darwin"
        HOME="'"${TEST_TMPDIR}"'/home"
        mkdir -p "${HOME}/Applications/Example App.app"

        cask_app_bundle_exists() {
            local pkg_name="$1"
            local cask_json=""
            local app_candidate=""

            if [[ "${os_name}" != "Darwin" ]]; then
                return 1
            fi

            case "${pkg_name}" in
                example-app)
                    cask_json=$'"'"'{"casks":[{"artifacts":[{"app":["Example App.app"]}]}]}'"'"'
                    ;;
                *)
                    return 1
                    ;;
            esac

            while IFS= read -r app_candidate; do
                app_candidate="${app_candidate#\"}"
                app_candidate="${app_candidate%\"}"
                app_candidate="${app_candidate%%.app*}.app"
                app_candidate="${app_candidate##*/}"

                [[ -z "${app_candidate}" ]] && continue

                if [[ -d "/Applications/${app_candidate}" ]] || [[ -d "${HOME}/Applications/${app_candidate}" ]]; then
                    return 0
                fi
            done < <(printf "%s\n" "${cask_json}" | grep -o '"'"'"[^"]*\.app[^"]*"'"'"')

            return 1
        }

        optional_entry_is_installed() {
            local pkg_type="$1"
            local pkg_name="$2"

            if [[ "${pkg_type}" == "cask" ]] && cask_app_bundle_exists "${pkg_name}"; then
                return 0
            fi

            return 1
        }

        optional_entry_is_installed cask example-app && echo "INSTALLED" || echo "MISSING"
    '
    assert_success
    assert_output "INSTALLED"
}

@test "optional cask detection ignores unrelated app bundles" {
    run bash -c '
        set -euo pipefail

        os_name="Darwin"
        HOME="'"${TEST_TMPDIR}"'/home"
        mkdir -p "${HOME}/Applications/Claude.app"

        cask_app_bundle_exists() {
            local pkg_name="$1"
            local cask_json=""
            local app_candidate=""

            if [[ "${os_name}" != "Darwin" ]]; then
                return 1
            fi

            case "${pkg_name}" in
                example-app)
                    cask_json=$'"'"'{"casks":[{"artifacts":[{"app":["Example App.app"]}]}]}'"'"'
                    ;;
                *)
                    return 1
                    ;;
            esac

            while IFS= read -r app_candidate; do
                app_candidate="${app_candidate#\"}"
                app_candidate="${app_candidate%\"}"
                app_candidate="${app_candidate%%.app*}.app"
                app_candidate="${app_candidate##*/}"

                [[ -z "${app_candidate}" ]] && continue

                if [[ -d "/Applications/${app_candidate}" ]] || [[ -d "${HOME}/Applications/${app_candidate}" ]]; then
                    return 0
                fi
            done < <(printf "%s\n" "${cask_json}" | grep -o '"'"'"[^"]*\.app[^"]*"'"'"')

            return 1
        }

        cask_app_bundle_exists example-app && echo "INSTALLED" || echo "MISSING"
    '
    assert_success
    assert_output "MISSING"
}

# ---------------------------------------------------------------------------
# Linux cask filtering — non-font casks should be skipped on Linux
# ---------------------------------------------------------------------------

@test "Linux cask filtering skips non-font casks" {
    run bash -c '
        os_name="Linux"
        pkg_type="cask"
        pkg_name="1password-cli"
        if [[ "${os_name}" == "Linux" && "${pkg_type}" == "cask" && "${pkg_name}" != font-* ]]; then
            echo "SKIPPED"
        else
            echo "INCLUDED"
        fi
    '
    assert_success
    assert_output "SKIPPED"
}

@test "Linux cask filtering allows font casks" {
    run bash -c '
        os_name="Linux"
        pkg_type="cask"
        pkg_name="font-hack-nerd-font"
        if [[ "${os_name}" == "Linux" && "${pkg_type}" == "cask" && "${pkg_name}" != font-* ]]; then
            echo "SKIPPED"
        else
            echo "INCLUDED"
        fi
    '
    assert_success
    assert_output "INCLUDED"
}

@test "Darwin cask filtering includes all casks" {
    run bash -c '
        os_name="Darwin"
        pkg_type="cask"
        pkg_name="1password-cli"
        if [[ "${os_name}" == "Linux" && "${pkg_type}" == "cask" && "${pkg_name}" != font-* ]]; then
            echo "SKIPPED"
        else
            echo "INCLUDED"
        fi
    '
    assert_success
    assert_output "INCLUDED"
}

# ---------------------------------------------------------------------------
# Brewfile.core is well-formed
# ---------------------------------------------------------------------------

@test "Brewfile.core contains only valid entry types" {
    local brewfile="${PROJECT_ROOT}/homebrew/Brewfile.core"
    run bash -c '
        while IFS= read -r raw_line; do
            line="${raw_line#"${raw_line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            [[ -z "${line}" ]] && continue
            [[ "${line}" == \#* ]] && continue
            if [[ ! "${line}" =~ ^(brew|cask|tap|mas)[[:space:]]+ ]]; then
                echo "INVALID: ${line}"
                exit 1
            fi
        done < "'"${brewfile}"'"
        echo "ALL_VALID"
    '
    assert_success
    assert_output "ALL_VALID"
}

@test "Brewfile.core has no duplicate entries" {
    local brewfile="${PROJECT_ROOT}/homebrew/Brewfile.core"
    run bash -c '
        entries_file="$(mktemp)"
        while IFS= read -r raw_line; do
            line="${raw_line#"${raw_line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            [[ -z "${line}" ]] && continue
            [[ "${line}" == \#* ]] && continue
            if [[ "${line}" =~ ^(brew|cask|tap|mas)[[:space:]]+\"([^\"]+)\" ]]; then
                printf "%s:%s\n" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" >> "${entries_file}"
            fi
        done < "'"${brewfile}"'"
        duplicate="$(sort "${entries_file}" | uniq -d | head -n 1)"
        rm -f "${entries_file}"
        if [[ -n "${duplicate}" ]]; then
            echo "DUPLICATE: ${duplicate}"
            exit 1
        fi
        echo "NO_DUPLICATES"
    '
    assert_success
    assert_output "NO_DUPLICATES"
}

@test "Brewfile.macos tracks mactop as a formula" {
    run grep -qx 'brew "mactop"' "${PROJECT_ROOT}/homebrew/Brewfile.macos"
    assert_success
}

# ---------------------------------------------------------------------------
# OS platform detection (from brew.sh case statement)
# ---------------------------------------------------------------------------

@test "brew.sh OSTYPE case recognizes linux-gnu" {
    run bash -c '
        OSTYPE="linux-gnu"
        case "${OSTYPE}" in
            darwin*) echo "Darwin" ;;
            linux*)  echo "Linux" ;;
            *)       echo "Unsupported" ;;
        esac
    '
    assert_success
    assert_output "Linux"
}

@test "brew.sh OSTYPE case recognizes darwin23" {
    run bash -c '
        OSTYPE="darwin23"
        case "${OSTYPE}" in
            darwin*) echo "Darwin" ;;
            linux*)  echo "Linux" ;;
            *)       echo "Unsupported" ;;
        esac
    '
    assert_success
    assert_output "Darwin"
}

@test "brew.sh OSTYPE case rejects freebsd" {
    run bash -c '
        OSTYPE="freebsd14"
        case "${OSTYPE}" in
            darwin*) echo "Darwin" ;;
            linux*)  echo "Linux" ;;
            *)       echo "Unsupported"; exit 1 ;;
        esac
    '
    assert_failure
    assert_output "Unsupported"
}

# ---------------------------------------------------------------------------
# End-to-end brew flow in an isolated sandbox
# ---------------------------------------------------------------------------

@test "brew.sh installs only pending entries inside an isolated brew sandbox" {
    run bash -c '
        set -euo pipefail

        export HOME="'"${TEST_TMPDIR}"'/sandbox-home"
        export TEST_ROOT="'"${TEST_TMPDIR}"'/brew-sandbox"
        export TEST_BIN="${TEST_ROOT}/bin"
        export TEST_LOG="${TEST_TMPDIR}/brew-actions.log"
        export TEST_BUNDLE="${TEST_TMPDIR}/bundle.txt"
        export PATH="${TEST_BIN}:/usr/bin:/bin"
        export OSTYPE="linux-gnu"

        mkdir -p "${HOME}" "${TEST_BIN}"
        : > "${TEST_LOG}"

        cat > "${TEST_BIN}/brew" <<'"'"'MOCK'"'"'
#!/usr/bin/env bash
set -euo pipefail

printf "brew %s\n" "$*" >> "${TEST_LOG}"

case "${1:-}" in
    --prefix)
        printf "%s\n" "${TEST_ROOT}"
        ;;
    list)
        case "${2:-}" in
            --formula)
                printf "git\n"
                ;;
            --cask)
                exit 0
                ;;
        esac
        ;;
    tap)
        exit 0
        ;;
    bundle)
        if [[ "${2:-}" == "install" ]]; then
            bundle_file="${3#--file=}"
            cp "${bundle_file}" "${TEST_BUNDLE}"
            exit 0
        fi
        ;;
esac

exit 0
MOCK

        chmod +x "${TEST_BIN}/brew"

        cd "'"${PROJECT_ROOT}"'"
        ./homebrew/brew.sh

        [[ -f "${TEST_BUNDLE}" ]] || { echo "missing bundle file"; exit 1; }
        grep -qx '"'"'brew "curl"'"'"' "${TEST_BUNDLE}" || { echo "missing curl"; exit 1; }
        grep -qx '"'"'brew "gum"'"'"' "${TEST_BUNDLE}" || { echo "missing gum"; exit 1; }
        grep -qx '"'"'cask "font-hack-nerd-font"'"'"' "${TEST_BUNDLE}" || { echo "missing font cask"; exit 1; }
        if grep -qx '"'"'brew "git"'"'"' "${TEST_BUNDLE}"; then
            echo "installed formula was not filtered"
            exit 1
        fi
        if grep -qx '"'"'cask "1password-cli"'"'"' "${TEST_BUNDLE}"; then
            echo "linux should skip non-font casks"
            exit 1
        fi
    '
    assert_success
    assert_output --partial "Installing core Homebrew packages..."
}

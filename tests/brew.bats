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
        declare -A seen
        while IFS= read -r raw_line; do
            line="${raw_line#"${raw_line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            [[ -z "${line}" ]] && continue
            [[ "${line}" == \#* ]] && continue
            if [[ "${line}" =~ ^(brew|cask|tap|mas)[[:space:]]+\"([^\"]+)\" ]]; then
                key="${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"
                if [[ -n "${seen[${key}]:-}" ]]; then
                    echo "DUPLICATE: ${key}"
                    exit 1
                fi
                seen["${key}"]=1
            fi
        done < "'"${brewfile}"'"
        echo "NO_DUPLICATES"
    '
    assert_success
    assert_output "NO_DUPLICATES"
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

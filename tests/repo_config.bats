#!/usr/bin/env bats
# Checks on the configuration the repo ships rather than its scripts: the
# personas and roles agree with stow/, homebrew/ and scripts/bootstrap/, and
# every tracked config file parses. A typo in a persona otherwise only shows
# on the machine that uses it, mid-install.

load test_helper

setup() {
    setup_tmpdir
}

teardown() {
    teardown_tmpdir
}

# The value of KEY in a persona or role file (last one wins, as in link.sh).
setting() {
    sed -n "s/^$2=//p" "$1" | tail -n 1
}

# The settings of a persona or role file, without comments and blank lines.
settings_of() {
    grep -Ev '^[[:space:]]*(#|$)' "$1"
}

# True when LAYER has a stow package on one of the platforms in OS_LIST.
layer_exists() {
    local layer="$1" os
    [[ -d "${PROJECT_ROOT}/stow/${layer}" ]] && return 0
    for os in ${2//,/ }; do
        [[ -d "${PROJECT_ROOT}/stow/${layer}.${os}" ]] && return 0
    done
    return 1
}

# The tracked files matching the given git pathspecs.
tracked() {
    git -C "${PROJECT_ROOT}" ls-files -- "$@"
}

# ---------------------------------------------------------------------------
# Personas
# ---------------------------------------------------------------------------

@test "every persona sets only settings link.sh knows, with valid values" {
    local file line key value app problems=""
    for file in "${PROJECT_ROOT}"/personas/*; do
        while IFS= read -r line; do
            key="${line%%=*}" value="${line#*=}"
            case "${key}" in
                os)
                    [[ "${value}" =~ ^(darwin|linux)(,(darwin|linux))*$ ]] \
                        || problems+="${file##*/}: os=${value}"$'\n'
                    ;;
                agents | editors | harden)
                    [[ "${value}" == yes || "${value}" == no ]] \
                        || problems+="${file##*/}: ${key}=${value}"$'\n'
                    ;;
                agent_apps)
                    for app in ${value}; do
                        [[ " claude cursor codex " == *" ${app} "* ]] \
                            || problems+="${file##*/}: agent_apps has ${app}"$'\n'
                    done
                    ;;
                layers | skills | brew | brew_optional | roles | roles_optional) ;;
                *) problems+="${file##*/}: unknown setting '${line}'"$'\n' ;;
            esac
        done < <(settings_of "${file}")
        [[ -n "$(setting "${file}" os)" ]] || problems+="${file##*/}: no os"$'\n'
        [[ -n "$(setting "${file}" layers)" ]] || problems+="${file##*/}: no layers"$'\n'
    done

    run printf '%s' "${problems}"
    assert_output ""
}

@test "every persona's layers, Brewfiles and roles exist" {
    local file os name problems=""
    for file in "${PROJECT_ROOT}"/personas/*; do
        os="$(setting "${file}" os)"
        for name in $(setting "${file}" layers); do
            layer_exists "${name}" "${os}" \
                || problems+="${file##*/}: no stow/${name} for ${os}"$'\n'
        done
        for name in $(setting "${file}" brew) $(setting "${file}" brew_optional); do
            [[ -f "${PROJECT_ROOT}/homebrew/Brewfile.${name}" ]] \
                || problems+="${file##*/}: no homebrew/Brewfile.${name}"$'\n'
        done
        for name in $(setting "${file}" roles) $(setting "${file}" roles_optional); do
            [[ -f "${PROJECT_ROOT}/roles/${name}" ]] \
                || problems+="${file##*/}: no roles/${name}"$'\n'
        done
    done

    run printf '%s' "${problems}"
    assert_output ""
}

@test "every persona for this platform loads in link.sh and writes nothing" {
    local file platform loaded=0
    case "${OSTYPE}" in
        darwin*) platform=darwin ;;
        *) platform=linux ;;
    esac
    for file in "${PROJECT_ROOT}"/personas/*; do
        [[ ",$(setting "${file}" os)," == *",${platform},"* ]] || continue
        mkdir -p "${TEST_TMPDIR}/home"
        run env DOTFILES_INSTALLS= bash "${PROJECT_ROOT}/scripts/link.sh" \
            --destination "${TEST_TMPDIR}/home" --persona "${file##*/}" installs
        assert_success
        assert_line "brew=$(setting "${file}" brew)"
        run ls -A "${TEST_TMPDIR}/home"
        assert_output ""
        loaded=$((loaded + 1))
    done
    [ "${loaded}" -gt 0 ]
}

@test "every stow package and Brewfile is used by a persona or role" {
    local dir package layer os file used problems=""
    for dir in "${PROJECT_ROOT}"/stow/*/; do
        package="$(basename "${dir}")"
        layer="${package%%.*}" os=""
        [[ "${package}" != *.* ]] || os="${package#*.}"
        used=0
        for file in "${PROJECT_ROOT}"/personas/* "${PROJECT_ROOT}"/roles/*; do
            [[ "${file}" != */README.md ]] || continue
            [[ " $(setting "${file}" layers) " == *" ${layer} "* ]] || continue
            if [[ -z "${os}" || ",$(setting "${file}" os)," == *",${os},"* ]]; then
                used=1
            fi
        done
        [[ "${used}" -eq 1 ]] || problems+="stow/${package} is linked by no persona or role"$'\n'
    done
    for file in "${PROJECT_ROOT}"/homebrew/Brewfile.*; do
        package="${file##*/Brewfile.}"
        cat "${PROJECT_ROOT}"/personas/* "${PROJECT_ROOT}"/roles/* \
            | grep -Eq "^brew(_optional)?=(.* )?${package}( .*)?$" \
            || problems+="homebrew/Brewfile.${package} is installed by no persona or role"$'\n'
    done

    run printf '%s' "${problems}"
    assert_output ""
}

# ---------------------------------------------------------------------------
# Roles and optional installs
# ---------------------------------------------------------------------------

@test "every role sets known settings whose layers, setup scripts and requirements exist" {
    local file line name os key value required setup problems=""
    for file in "${PROJECT_ROOT}"/roles/*; do
        [[ "${file}" != */README.md ]] || continue
        name="${file##*/}"
        os="$(setting "${file}" os)"
        while IFS= read -r line; do
            key="${line%%=*}"
            case "${key}" in
                os | layers | brew | requires | detect | setup) ;;
                *) problems+="${name}: unknown setting '${line}'"$'\n' ;;
            esac
        done < <(settings_of "${file}")
        [[ "${os}" =~ ^(darwin|linux)(,(darwin|linux))*$ ]] || problems+="${name}: os=${os}"$'\n'
        [[ -n "$(setting "${file}" detect)" ]] || problems+="${name}: no detect"$'\n'

        for value in $(setting "${file}" layers); do
            layer_exists "${value}" "${os}" || problems+="${name}: no stow/${value} for ${os}"$'\n'
        done
        for value in $(setting "${file}" brew); do
            [[ -f "${PROJECT_ROOT}/homebrew/Brewfile.${value}" ]] \
                || problems+="${name}: no homebrew/Brewfile.${value}"$'\n'
        done

        setup="$(setting "${file}" setup)"
        setup="${setup:-${name}}"
        for value in ${os//,/ }; do
            [[ "${value}" == darwin ]] && value=macos
            [[ -f "${PROJECT_ROOT}/scripts/bootstrap/${value}/${setup}.sh" \
                || -f "${PROJECT_ROOT}/scripts/bootstrap/${setup}.sh" ]] \
                || problems+="${name}: no setup script ${setup}.sh for ${value}"$'\n'
        done

        for required in $(setting "${file}" requires); do
            [[ -f "${PROJECT_ROOT}/roles/${required}" ]] && continue
            grep -qs '^# detect: ' "${PROJECT_ROOT}"/scripts/bootstrap/{,*/}"${required}.sh" \
                || problems+="${name}: requires ${required}, which is no role or optional install"$'\n'
        done
    done

    run printf '%s' "${problems}"
    assert_output ""
}

@test "every detect command parses as bash" {
    local file detect problems=""
    for file in "${PROJECT_ROOT}"/roles/*; do
        [[ "${file}" != */README.md ]] || continue
        detect="$(setting "${file}" detect)"
        bash -n -c "${detect}" 2>/dev/null || problems+="roles/${file##*/}: ${detect}"$'\n'
    done
    for file in "${PROJECT_ROOT}"/scripts/bootstrap/*.sh "${PROJECT_ROOT}"/scripts/bootstrap/*/*.sh; do
        detect="$(sed -n 's/^# detect: //p' "${file}" | head -n 1)"
        [[ -n "${detect}" ]] || continue
        bash -n -c "${detect}" 2>/dev/null || problems+="${file#"${PROJECT_ROOT}"/}: ${detect}"$'\n'
    done

    run printf '%s' "${problems}"
    assert_output ""
}

@test "a role's setup script declares no detect line of its own" {
    local file setup script problems=""
    for file in "${PROJECT_ROOT}"/roles/*; do
        [[ "${file}" != */README.md ]] || continue
        setup="$(setting "${file}" setup)"
        for script in "${PROJECT_ROOT}"/scripts/bootstrap/{,*/}"${setup:-${file##*/}}.sh"; do
            [[ -f "${script}" ]] || continue
            ! grep -q '^# detect: ' "${script}" \
                || problems+="${script#"${PROJECT_ROOT}"/} would also be offered as an optional install"$'\n'
        done
    done

    run printf '%s' "${problems}"
    assert_output ""
}

# ---------------------------------------------------------------------------
# Config file syntax
# ---------------------------------------------------------------------------

@test "every tracked JSON file parses" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    local file problems=""
    while IFS= read -r file; do
        jq empty "${PROJECT_ROOT}/${file}" 2>/dev/null || problems+="${file}"$'\n'
    done < <(tracked '*.json')

    run printf '%s' "${problems}"
    assert_output ""
}

@test "every tracked TOML file parses, examples included" {
    python3 -c 'import tomllib' 2>/dev/null || skip "python3 with tomllib (3.11+) not installed"
    local file problems=""
    while IFS= read -r file; do
        python3 -c 'import sys, tomllib; tomllib.load(open(sys.argv[1], "rb"))' \
            "${PROJECT_ROOT}/${file}" 2>/dev/null || problems+="${file}"$'\n'
    done < <(tracked '*.toml' '*.toml.example')

    run printf '%s' "${problems}"
    assert_output ""
}

@test "every tracked YAML file parses" {
    command -v ruby >/dev/null 2>&1 || skip "ruby not installed"
    local file problems=""
    while IFS= read -r file; do
        ruby -ryaml -e 'YAML.load_file(ARGV[0])' "${PROJECT_ROOT}/${file}" 2>/dev/null \
            || problems+="${file}"$'\n'
    done < <(tracked '*.yml' '*.yaml')

    run printf '%s' "${problems}"
    assert_output ""
}

@test "every tracked iTerm2 color preset is a valid property list" {
    command -v plutil >/dev/null 2>&1 || skip "plutil is macOS only"
    local file problems=""
    while IFS= read -r file; do
        plutil -lint -s "${PROJECT_ROOT}/${file}" || problems+="${file}"$'\n'
    done < <(tracked '*.itermcolors')

    run printf '%s' "${problems}"
    assert_output ""
}

@test "zsh startup files and the shared shell files parse under zsh" {
    command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
    local file problems=""
    for file in stow/common/.zshenv stow/common/.config/zsh/.zshenv stow/common/.config/zsh/.zprofile \
        stow/common/.config/zsh/.zshrc stow/common/.config/zsh/.zshrc.local.example \
        stow/common/.config/shell/aliases stow/common/.config/shell/functions; do
        [[ -f "${PROJECT_ROOT}/${file}" ]] || { problems+="${file} is missing"$'\n'; continue; }
        zsh -n "${PROJECT_ROOT}/${file}" 2>/dev/null || problems+="${file}"$'\n'
    done

    run printf '%s' "${problems}"
    assert_output ""
}

@test "bash startup files parse under the system bash" {
    local file problems=""
    for file in stow/common/.bashrc stow/common/.bash_profile; do
        /bin/bash -n "${PROJECT_ROOT}/${file}" 2>/dev/null || problems+="${file}"$'\n'
    done

    run printf '%s' "${problems}"
    assert_output ""
}

@test "the vimrc keeps Vim's defaults and keeps its history under XDG_STATE_HOME" {
    local vim
    vim="$(command -v vim)" || skip "vim not installed"
    mkdir -p "${TEST_TMPDIR}/home"

    # The values the vimrc leaves set, as Vim sees them after loading it.
    vim_settings() {
        local out="${TEST_TMPDIR}/vim.out"
        rm -f "${out}"
        env -i HOME="${TEST_TMPDIR}/home" PATH=/usr/bin:/bin "$@" "${vim}" -Nu "${PROJECT_ROOT}/stow/common/.config/vim/vimrc" -es \
            -c "call writefile([&viminfofile, g:netrw_home, &incsearch, &scrolloff], '${out}')" -c 'qa!' </dev/null
        cat "${out}"
    }

    run vim_settings XDG_STATE_HOME="${TEST_TMPDIR}/state"
    assert_success
    assert_output "${TEST_TMPDIR}/state/vim/viminfo"$'\n'"${TEST_TMPDIR}/state/vim"$'\n'"1"$'\n'"5"
    assert test -d "${TEST_TMPDIR}/state/vim"
    [ "$(stat -c %a "${TEST_TMPDIR}/state/vim" 2>/dev/null || stat -f %Lp "${TEST_TMPDIR}/state/vim")" = 700 ]

    # Without XDG_STATE_HOME, its default under the home.
    run vim_settings
    assert_success
    assert_line --index 0 "${TEST_TMPDIR}/home/.local/state/vim/viminfo"
}

@test "a new zsh points xdg-ninja at the ignore file the repo ships" {
    command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
    local home="${TEST_TMPDIR}/home" ignore
    mkdir -p "${home}/.config/zsh"
    cp "${PROJECT_ROOT}/stow/common/.config/zsh/.zshenv" "${home}/.config/zsh/"

    run env -i HOME="${home}" ZDOTDIR="${home}/.config/zsh" PATH=/usr/bin:/bin zsh -c 'printf "%s\n" "${XN_IGNOREFILE}"'
    assert_success
    assert_output "${home}/.config/xdg-ninja/ignore"

    # The common layer links that path; xdg-ninja matches whole basenames.
    ignore="${PROJECT_ROOT}/stow/common/${output#"${home}"/}"
    assert test -f "${ignore}"
    run grep -vx '#.*' "${ignore}"
    assert_line ".zshenv"
    assert_line ".trash"
}

@test "zsh plugin list names GitHub repos, with optional antidote annotations" {
    run grep -Ev '^[[:space:]]*(#|$)|^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+( [a-z]+:[^ ]+)*$' \
        "${PROJECT_ROOT}/stow/common/.config/zsh/.zsh_plugins.txt"
    assert_failure 1
    assert_output ""
}

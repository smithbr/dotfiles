#!/usr/bin/env bats

load test_helper

@test "top-level zshenv shim points zsh at XDG config" {
    run bash -c '
        set -euo pipefail
        file="'"${PROJECT_ROOT}"'/stow/common/.zshenv"

        [[ -f "${file}" ]] || { echo "missing ${file}"; exit 1; }
        grep -qxF "export XDG_CONFIG_HOME=\"\${XDG_CONFIG_HOME:-\${HOME}/.config}\"" "${file}" || {
            echo "missing XDG_CONFIG_HOME export"
            exit 1
        }
        grep -qxF "export ZDOTDIR=\"\${XDG_CONFIG_HOME}/zsh\"" "${file}" || {
            echo "missing ZDOTDIR export"
            exit 1
        }
        grep -qxF "if [[ -f \"\${ZDOTDIR}/.zshenv\" ]]; then" "${file}" || {
            echo "missing source guard"
            exit 1
        }
        grep -qxF "    source \"\${ZDOTDIR}/.zshenv\"" "${file}" || {
            echo "missing source statement"
            exit 1
        }
    '

    assert_success
}

@test "inner zshenv sets XDG_CONFIG_HOME when zsh enters through ZDOTDIR" {
    command -v zsh >/dev/null || skip "zsh not installed"
    setup_tmpdir
    local home="${TEST_TMPDIR}/home" zdotdir="${TEST_TMPDIR}/home/.config/zsh"
    mkdir -p "${zdotdir}"
    cp "${PROJECT_ROOT}/stow/common/.config/zsh/.zshenv" "${zdotdir}/"

    # A system /etc/zshenv that sets ZDOTDIR skips ~/.zshenv, so the inner
    # file must not rely on the top-level shim having set XDG_CONFIG_HOME.
    run env -i HOME="${home}" ZDOTDIR="${zdotdir}" PATH="/usr/bin:/bin" \
        zsh -c 'printf "%s\n" "${XDG_CONFIG_HOME}"'
    assert_success
    assert_output "${home}/.config"

    run env -i HOME="${home}" ZDOTDIR="${zdotdir}" PATH="/usr/bin:/bin" \
        XDG_CONFIG_HOME="${TEST_TMPDIR}/config" zsh -c 'printf "%s\n" "${XDG_CONFIG_HOME}"'
    assert_success
    assert_output "${TEST_TMPDIR}/config"
    teardown_tmpdir
}

@test "zprofile bootstraps brew for macOS and Linux" {
    run bash -c '
        set -euo pipefail
        file="'"${PROJECT_ROOT}"'/stow/common/.config/zsh/.zprofile"

        [[ -f "${file}" ]] || { echo "missing ${file}"; exit 1; }
        grep -qxF "if [[ -x /opt/homebrew/bin/brew ]]; then" "${file}" || {
            echo "missing /opt/homebrew guard"
            exit 1
        }
        grep -qxF "    eval \"\$(/opt/homebrew/bin/brew shellenv zsh)\"" "${file}" || {
            echo "missing /opt/homebrew shellenv"
            exit 1
        }
        grep -qxF "elif [[ -x /usr/local/bin/brew ]]; then" "${file}" || {
            echo "missing /usr/local guard"
            exit 1
        }
        grep -qxF "    eval \"\$(/usr/local/bin/brew shellenv zsh)\"" "${file}" || {
            echo "missing /usr/local shellenv"
            exit 1
        }
        grep -qxF "elif [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then" "${file}" || {
            echo "missing /home/linuxbrew guard"
            exit 1
        }
        grep -qxF "    eval \"\$(/home/linuxbrew/.linuxbrew/bin/brew shellenv zsh)\"" "${file}" || {
            echo "missing /home/linuxbrew shellenv"
            exit 1
        }
    '

    assert_success
}

@test "zshrc uses ZDOTDIR for local overrides and plugins" {
    run bash -c '
        set -euo pipefail
        file="'"${PROJECT_ROOT}"'/stow/common/.config/zsh/.zshrc"

        [[ -f "${file}" ]] || { echo "missing ${file}"; exit 1; }
        grep -qF "\${ZDOTDIR}/.zshrc.local" "${file}" || {
            echo "missing ZDOTDIR for .zshrc.local"
            exit 1
        }
        grep -qF "\${ZDOTDIR}/.zsh_plugins.txt" "${file}" || {
            echo "missing ZDOTDIR for .zsh_plugins.txt"
            exit 1
        }
        grep -qF "antidote bundle <\"\${zsh_plugins_file}\"" "${file}" || {
            echo "missing antidote bundle cache generation"
            exit 1
        }
        grep -qF "\${XDG_CACHE_HOME}/zsh/.zsh_plugins.zsh" "${file}" || {
            echo "missing cached bundle path"
            exit 1
        }
    '

    assert_success
}

# Runs only the zshrc nvm block, so the rest of the interactive setup stays out.
run_nvm_block() {
    local block="${TEST_TMPDIR}/nvm_block.zsh"
    awk '/^# nvm/ { on = 1 } on { print } on && /^unset nvm_sh$/ { exit }' \
        "${PROJECT_ROOT}/stow/common/.config/zsh/.zshrc" > "${block}"
    [[ -s "${block}" ]] || { echo "nvm block not found"; return 1; }
    run env -i PATH="/usr/bin:/bin" NVM_DIR="${TEST_TMPDIR}/nvm" "$@" \
        zsh -f -c "source '${block}'; print -r -- \"loaded=\${NVM_LOADED:-no}\""
}

@test "zshrc nvm block is quiet when nvm is not installed" {
    command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
    setup_tmpdir

    run_nvm_block HOMEBREW_PREFIX="${TEST_TMPDIR}/brew"
    assert_success
    assert_output "loaded=no"

    teardown_tmpdir
}

@test "zshrc nvm block loads nvm.sh from the Homebrew prefix" {
    command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
    setup_tmpdir
    mkdir -p "${TEST_TMPDIR}/brew/opt/nvm"
    printf 'NVM_LOADED="$1"\n' > "${TEST_TMPDIR}/brew/opt/nvm/nvm.sh"

    run_nvm_block HOMEBREW_PREFIX="${TEST_TMPDIR}/brew"
    assert_success
    assert_output "loaded=--no-use"

    teardown_tmpdir
}

@test "bash keeps its history under XDG_STATE_HOME and creates the folder" {
    setup_tmpdir
    local home="${TEST_TMPDIR}/home"
    mkdir -p "${home}"
    cp "${PROJECT_ROOT}/stow/common/.bashrc" "${PROJECT_ROOT}/stow/common/.bash_profile" "${home}/"

    run env -i HOME="${home}" PATH="/usr/bin:/bin" bash -lc 'printf "%s\n" "${HISTFILE}"'
    assert_success
    assert_output "${home}/.local/state/bash/history"
    [[ -d "${home}/.local/state/bash" ]]

    run env -i HOME="${home}" PATH="/usr/bin:/bin" XDG_STATE_HOME="${TEST_TMPDIR}/state" bash -lc 'printf "%s\n" "${HISTFILE}"'
    assert_success
    assert_output "${TEST_TMPDIR}/state/bash/history"
    teardown_tmpdir
}

@test "lg follows lazygit to the directory it left in, and stays put otherwise" {
    command -v zsh >/dev/null || skip "zsh not installed"
    setup_tmpdir
    local bin="${TEST_TMPDIR}/bin" target="${TEST_TMPDIR}/repo dir"
    mkdir -p "${bin}" "${TEST_TMPDIR}/home/.lazygit" "${target}"
    # lazygit writes the directory it was in on exit when LAZYGIT_NEW_DIR_FILE is set.
    cat > "${bin}/lazygit" <<'MOCK'
#!/bin/sh
printf 'lazygit %s\n' "$*"
[ -n "${LG_TARGET:-}" ] && printf '%s' "${LG_TARGET}" > "${LAZYGIT_NEW_DIR_FILE}"
exit 0
MOCK
    chmod +x "${bin}/lazygit"
    local fns="${PROJECT_ROOT}/stow/common/.config/shell/functions"

    run env HOME="${TEST_TMPDIR}/home" PATH="${bin}:/usr/bin:/bin" LG_TARGET="${target}" \
        zsh -fc "cd '${TEST_TMPDIR}'; source '${fns}'; lg log; pwd"
    assert_success
    assert_line --index 0 "lazygit log"
    assert_line --index 1 "${target}"
    [ ! -e "${TEST_TMPDIR}/home/.lazygit/newdir" ]

    run env HOME="${TEST_TMPDIR}/home" PATH="${bin}:/usr/bin:/bin" \
        zsh -fc "cd '${TEST_TMPDIR}'; source '${fns}'; lg; pwd"
    assert_success
    assert_line --index 1 "${TEST_TMPDIR}"
    teardown_tmpdir
}

@test "na appends an alias to the repo aliases file and defines it" {
    command -v zsh >/dev/null || skip "zsh not installed"
    setup_tmpdir
    local aliases="${TEST_TMPDIR}/stow/common/.config/shell/aliases"
    mkdir -p "$(dirname "${aliases}")"
    echo 'alias h="history"' > "${aliases}"

    run env DOTFILES_DIR="${TEST_TMPDIR}" zsh -fc '
        source "'"${PROJECT_ROOT}"'/stow/common/.config/shell/functions"
        na drm2 "docker rm \$(docker ps -q) \"x\"" || exit 1
        alias drm2
    '

    assert_success
    [[ "${output}" == *"drm2="* ]]
    run tail -n1 "${aliases}"
    assert_output 'alias drm2="docker rm \$(docker ps -q) \"x\""'
    teardown_tmpdir
}

@test "na refuses duplicates and bad usage without writing" {
    command -v zsh >/dev/null || skip "zsh not installed"
    setup_tmpdir
    local aliases="${TEST_TMPDIR}/stow/common/.config/shell/aliases"
    mkdir -p "$(dirname "${aliases}")"
    echo 'alias h="history"' > "${aliases}"
    local fns="${PROJECT_ROOT}/stow/common/.config/shell/functions"

    run env DOTFILES_DIR="${TEST_TMPDIR}" zsh -fc "source '${fns}'; na h ls"
    assert_failure 1
    run env DOTFILES_DIR="${TEST_TMPDIR}" zsh -fc "source '${fns}'; na onlyname"
    assert_failure 2
    run env DOTFILES_DIR="${TEST_TMPDIR}" zsh -fc "source '${fns}'; na 'bad name' ls"
    assert_failure 2

    run cat "${aliases}"
    assert_output 'alias h="history"'
    teardown_tmpdir
}

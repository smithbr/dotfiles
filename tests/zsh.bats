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

@test "non-interactive zsh keeps Docker config under XDG_CONFIG_HOME" {
    command -v zsh >/dev/null || skip "zsh not installed"
    setup_tmpdir
    local home="${TEST_TMPDIR}/home" zdotdir="${TEST_TMPDIR}/home/.config/zsh"
    mkdir -p "${zdotdir}"
    cp "${PROJECT_ROOT}/stow/common/.config/zsh/.zshenv" "${zdotdir}/"

    # Scripts and colima run non-interactive; without this they read ~/.docker.
    run env -i HOME="${home}" ZDOTDIR="${zdotdir}" PATH="/usr/bin:/bin" \
        zsh -c 'printf "%s\n" "${DOCKER_CONFIG}"'
    assert_success
    assert_output "${home}/.config/docker"
    teardown_tmpdir
}

@test "non-interactive zsh keeps bun's global packages under XDG_DATA_HOME, on PATH" {
    command -v zsh >/dev/null || skip "zsh not installed"
    setup_tmpdir
    local home="${TEST_TMPDIR}/home" zdotdir="${TEST_TMPDIR}/home/.config/zsh"
    mkdir -p "${zdotdir}"
    cp "${PROJECT_ROOT}/stow/common/.config/zsh/.zshenv" "${zdotdir}/"

    run env -i HOME="${home}" ZDOTDIR="${zdotdir}" PATH="/usr/bin:/bin" \
        zsh -c 'printf "%s\n" "${BUN_INSTALL}"; print -rl -- $path'
    assert_success
    assert_line --index 0 "${home}/.local/share/bun"
    assert_line "${home}/.local/share/bun/bin"
    teardown_tmpdir
}

@test "non-interactive zsh sets the tool paths df-doctor and scripts rely on" {
    command -v zsh >/dev/null || skip "zsh not installed"
    setup_tmpdir
    local home="${TEST_TMPDIR}/home" zdotdir="${TEST_TMPDIR}/home/.config/zsh"
    mkdir -p "${zdotdir}"
    cp "${PROJECT_ROOT}/stow/common/.config/zsh/.zshenv" "${zdotdir}/"

    # git's gpg signing and df-doctor run zsh without .zshrc.
    run env -i HOME="${home}" ZDOTDIR="${zdotdir}" PATH="/usr/bin:/bin" \
        zsh -c 'for v in GNUPGHOME AWS_CONFIG_FILE GOBIN GOPATH; do printenv "${v}"; done'
    assert_success
    assert_line --index 0 "${home}/.local/share/gnupg"
    assert_line --index 1 "${home}/.config/aws/config"
    assert_line --index 2 "${home}/.local/bin"
    assert_line --index 3 "${home}/.local/share/go"
    teardown_tmpdir
}

@test "interactive zsh keeps unexported history under XDG_STATE_HOME and creates the folder" {
    command -v zsh >/dev/null || skip "zsh not installed"
    setup_tmpdir
    local home="${TEST_TMPDIR}/home" zdotdir="${TEST_TMPDIR}/home/.config/zsh"
    mkdir -p "${zdotdir}"
    cp "${PROJECT_ROOT}/stow/common/.config/zsh/.zshenv" "${PROJECT_ROOT}/stow/common/.config/zsh/.zshrc" "${zdotdir}/"
    : > "${zdotdir}/.zprofile"

    run env -i HOME="${home}" ZDOTDIR="${zdotdir}" PATH="/usr/bin:/bin" TERM=dumb \
        zsh -ic 'print -r -- "${HISTFILE}"; printenv HISTFILE || print -r -- unexported'
    assert_success
    assert_line --index 0 "${home}/.local/state/zsh/history"
    assert_line --index 1 "unexported"
    [[ -d "${home}/.local/state/zsh" ]]
    teardown_tmpdir
}

@test "non-interactive zsh sends colima's VM to data, Go's downloads to cache, Copilot to config, and lets parallel split" {
    command -v zsh >/dev/null || skip "zsh not installed"
    setup_tmpdir
    local home="${TEST_TMPDIR}/home" zdotdir="${TEST_TMPDIR}/home/.config/zsh"
    mkdir -p "${zdotdir}"
    cp "${PROJECT_ROOT}/stow/common/.config/zsh/.zshenv" "${zdotdir}/"

    run env -i HOME="${home}" ZDOTDIR="${zdotdir}" PATH="/usr/bin:/bin" \
        zsh -c 'printf "%s\n" "${LIMA_HOME}" "${GOMODCACHE}" "${COPILOT_HOME}" "${PARALLEL_HOME-unset}"'
    assert_success
    assert_output "${home}/.local/share/lima"$'\n'"${home}/.cache/go/mod"$'\n'"${home}/.config/copilot"$'\n'"unset"
    # parallel uses these only when they exist, else it falls back to ~/.parallel.
    assert test -d "${home}/.config/parallel"
    assert test -d "${home}/.cache/parallel"
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

@test "interactive zsh: repo aliases win over plugins, and .zshrc.local wins over both" {
    command -v zsh >/dev/null || skip "zsh not installed"
    setup_tmpdir
    local home="${TEST_TMPDIR}/home" zdotdir="${TEST_TMPDIR}/home/.config/zsh"
    mkdir -p "${zdotdir}" "${home}/.config/shell" "${home}/.cache/zsh"
    cp "${PROJECT_ROOT}/stow/common/.config/zsh/.zshenv" "${PROJECT_ROOT}/stow/common/.config/zsh/.zshrc" "${zdotdir}/"
    cp "${PROJECT_ROOT}/stow/common/.config/shell/aliases" "${home}/.config/shell/"
    : > "${zdotdir}/.zprofile"
    : > "${zdotdir}/.zsh_plugins.txt"
    printf "alias ls='ls -G'\nalias lsa='ls -lah'\n" > "${home}/.cache/zsh/.zsh_plugins.zsh"
    touch -t 203001010000 "${home}/.cache/zsh/.zsh_plugins.zsh"
    printf "alias lsa='local-lsa'\n" > "${zdotdir}/.zshrc.local"

    run env -i HOME="${home}" ZDOTDIR="${zdotdir}" PATH="/usr/bin:/bin" TERM=dumb \
        zsh -ic 'alias ls lsa'
    assert_success
    assert_line --index 0 "ls='eza --group-directories-first'"
    assert_line --index 1 "lsa=local-lsa"
    teardown_tmpdir
}


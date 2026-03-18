#!/usr/bin/env bats

load test_helper

@test "top-level zshenv shim points zsh at XDG config" {
    run bash -c '
        set -euo pipefail
        file="'"${PROJECT_ROOT}"'/dotfiles/dot_zshenv"

        [[ -f "${file}" ]] || { echo "missing ${file}"; exit 1; }
        grep -qxF "export XDG_CONFIG_HOME=\"\${XDG_CONFIG_HOME:-\${HOME}/.config}\"" "${file}" || {
            echo "missing XDG_CONFIG_HOME export"
            exit 1
        }
        grep -qxF "export ZDOTDIR=\"\${XDG_CONFIG_HOME}/zsh\"" "${file}" || {
            echo "missing ZDOTDIR export"
            exit 1
        }
        grep -qxF "if [[ -f \"\${ZDOTDIR}/zshenv\" ]]; then" "${file}" || {
            echo "missing source guard"
            exit 1
        }
        grep -qxF "    source \"\${ZDOTDIR}/zshenv\"" "${file}" || {
            echo "missing source statement"
            exit 1
        }
    '

    assert_success
}

@test "zprofile bootstraps brew for macOS and Linux" {
    run bash -c '
        set -euo pipefail
        file="'"${PROJECT_ROOT}"'/dotfiles/dot_config/zsh/dot_zprofile"

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

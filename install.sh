#!/usr/bin/env bash

set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "${BASEDIR}/scripts/common.sh"

require_non_root

if [[ -z "${HOME:-}" ]]; then
    log_error "Seems you're \$HOMEless :("
    exit 1
fi

CHEZMOI_SOURCE="${BASEDIR}/dotfiles"
CHEZMOI_DEFAULT_SOURCE="${HOME}/.dotfiles/dotfiles"
CHEZMOI_CONFIG_DIR="${HOME}/.config/chezmoi"
CHEZMOI_CONFIG_FILE="${CHEZMOI_CONFIG_DIR}/chezmoi.toml"

cd "${BASEDIR}"

run_system_bootstrap=1
run_brew=1
declare -a chezmoi_args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-system)
            run_system_bootstrap=0
            ;;
        --skip-brew)
            run_brew=0
            ;;
        *)
            chezmoi_args+=("$1")
            ;;
    esac
    shift
done

if ! command -v chezmoi >/dev/null 2>&1; then
    log_info "Installing chezmoi"
    if command -v brew >/dev/null 2>&1; then
        brew install chezmoi
    else
        bin_dir="${HOME}/.local/bin"
        mkdir -p "${bin_dir}"
        sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "${bin_dir}"
        export PATH="${bin_dir}:${PATH}"
    fi
fi

log_info "Linking dotfiles repo to ${HOME}/.dotfiles"
ln -sfn "${BASEDIR}" "${HOME}/.dotfiles"

log_info "Applying dotfiles with chezmoi source ${CHEZMOI_SOURCE}"
if [[ "${#chezmoi_args[@]}" -gt 0 ]]; then
    chezmoi --source "${CHEZMOI_SOURCE}" apply "${chezmoi_args[@]}"
else
    chezmoi --source "${CHEZMOI_SOURCE}" apply
fi

# Ensure plain `chezmoi` commands use this repo on new machines.
current_source="$(chezmoi source-path 2>/dev/null || true)"
if [[ "${current_source}" != "${CHEZMOI_DEFAULT_SOURCE}" ]]; then
    mkdir -p "${CHEZMOI_CONFIG_DIR}"
    if [[ -f "${CHEZMOI_CONFIG_FILE}" ]]; then
        if grep -qE '^[[:space:]]*sourceDir[[:space:]]*=' "${CHEZMOI_CONFIG_FILE}"; then
            tmp_config="$(mktemp)"
            sed -E "s|^[[:space:]]*sourceDir[[:space:]]*=.*$|sourceDir = \"${CHEZMOI_DEFAULT_SOURCE}\"|" \
                "${CHEZMOI_CONFIG_FILE}" > "${tmp_config}"
            mv "${tmp_config}" "${CHEZMOI_CONFIG_FILE}"
        else
            printf "\nsourceDir = \"%s\"\n" "${CHEZMOI_DEFAULT_SOURCE}" >> "${CHEZMOI_CONFIG_FILE}"
        fi
    else
        printf "sourceDir = \"%s\"\n" "${CHEZMOI_DEFAULT_SOURCE}" > "${CHEZMOI_CONFIG_FILE}"
    fi
fi

if [[ "$(chezmoi source-path 2>/dev/null || true)" != "${CHEZMOI_DEFAULT_SOURCE}" ]]; then
    log_warn "chezmoi sourceDir is not set to ${CHEZMOI_DEFAULT_SOURCE}"
fi

if [[ "${run_system_bootstrap}" -eq 1 ]]; then
    if [[ "$(uname -s)" == "Darwin" ]]; then
        chmod +x scripts/bootstrap/macos.sh && ./scripts/bootstrap/macos.sh
    elif [[ "$(uname -s)" == "Linux" ]]; then
        chmod +x scripts/bootstrap/linux.sh && ./scripts/bootstrap/linux.sh
    fi
fi

if [[ "${run_brew}" -eq 1 ]]; then
    chmod +x homebrew/brew.sh && ./homebrew/brew.sh
fi

zsh_path="$(command -v zsh || true)"
if [[ -n "${zsh_path}" ]]; then
    if ! grep -qxF "${zsh_path}" /etc/shells; then
        echo "adding $zsh_path to /etc/shells"
        if command -v sudo >/dev/null 2>&1; then
            echo "$zsh_path" | sudo tee -a /etc/shells >/dev/null
        else
            log_warn "sudo not found; could not update /etc/shells"
        fi
    fi
    if [[ "${SHELL}" != "${zsh_path}" ]]; then
        chsh -s "$zsh_path"
        echo "default shell changed to $zsh_path"
    fi
    echo 'run "exec zsh -l" (or open a new terminal) to load latest shell config'
fi

printf "\nDone.\n"

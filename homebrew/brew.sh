#!/usr/bin/env bash

set -euo pipefail

if [[ "$(uname -s)" == "Darwin" ]]; then
    brewplatform=Homebrew
    brewpath=homebrew
    if [[ "$(uname -m)" == "arm64" ]]; then
        brewbinpath=/opt/homebrew/bin
        brewsbinpath=/opt/homebrew/sbin
    else
        brewbinpath=/usr/local/bin
        brewsbinpath=/usr/local/sbin
    fi
elif [[ "$(uname -s)" == "Linux" ]]; then
    brewplatform=Homebrew
    brewpath=homebrew
    brewbinpath=/home/linuxbrew/.linuxbrew/bin
    brewsbinpath=/home/linuxbrew/.linuxbrew/sbin
else
    echo "Unsupported OS: $(uname -s)" >&2
    exit 1
fi

export PATH="${brewbinpath}:${brewsbinpath}:${PATH}"

if [[ ! -x "${brewbinpath}/brew" ]] && ! command -v brew >/dev/null 2>&1; then
    printf "\n\nInstalling %s...\n\n" "${brewpath}"
    /bin/bash -c "$(curl -fsSL "https://raw.githubusercontent.com/${brewplatform}/install/HEAD/install.sh")"
fi

brew_prefix="$(brew --prefix)"
export PATH="${brew_prefix}/bin:${brew_prefix}/sbin:${PATH}"

brew update && brew upgrade

BREWFILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/Brewfile"
brew bundle install --file="${BREWFILE}"

brew cleanup
brew doctor

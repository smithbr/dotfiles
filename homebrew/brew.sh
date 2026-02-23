#!/usr/bin/env bash

set -euo pipefail

if [[ "$(uname -s)" == "Darwin" ]]; then
    brewplatform=Homebrew
    brewpath=homebrew
    if [[ "$(uname -m)" == "arm64" ]]; then
        brewbinpath=/opt/homebrew/bin
    else
        brewbinpath=/usr/local/bin
    fi
elif [[ "$(uname -s)" == "Linux" ]]; then
    brewplatform=Homebrew
    brewpath=homebrew
    brewbinpath=/home/linuxbrew/.linuxbrew/bin
else
    echo "Unsupported OS: $(uname -s)" >&2
    exit 1
fi

export PATH="${brewbinpath}:${PATH}"

if [[ ! -x "${brewbinpath}/brew" ]] && ! command -v brew >/dev/null 2>&1; then
    printf "\n\nInstalling %s...\n\n" "${brewpath}"
    /bin/bash -c "$(curl -fsSL "https://raw.githubusercontent.com/${brewplatform}/install/HEAD/install.sh")"
fi

brew update && brew upgrade

BREWFILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/Brewfile"
brew bundle install --file="${BREWFILE}"

brew cleanup
brew doctor

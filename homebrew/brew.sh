#!/usr/bin/env bash

set -euo pipefail

if [[ "$(uname -s)" == "Darwin" ]];
then
    brewplatform=Homebrew
    brewpath=homebrew
    if [[ "$(uname -m)" == "arm64" ]];
    then
        brewbinpath=/opt/homebrew/bin
    else
        brewbinpath=/usr/local/bin
    fi
elif [[ "$( uname )" == "Linux" ]];
then
    brewplatform=Linuxbrew
    brewpath=linuxbrew
    brewbinpath=/home/linuxbrew/.linuxbrew/bin
fi

if ! command -v brew >/dev/null 2>&1;
then
    echo -e "\\n\\nInstalling $brewpath...\\n"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/$brewplatform/install/HEAD/install.sh)"
fi

export PATH=$brewbinpath:$PATH
brew update && brew upgrade

BREWFILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/Brewfile"
brew bundle install --file="$BREWFILE"

brew cleanup
brew doctor

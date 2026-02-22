#!/usr/bin/env bash

set -euo pipefail

if [[ "$(uname -s)" == "Darwin" ]];
then
    brewplatform=Homebrew
    brewpath=homebrew
    brewbinpath=/usr/local/bin
elif [[ "$( uname )" == "Linux" ]];
then
    brewplatform=Linuxbrew
    brewpath=linuxbrew
    brewbinpath=/home/linuxbrew/.linuxbrew/bin
fi

if test ! "$( which brew )";
then
    echo -e "\\n\\nInstalling $brewpath...\\n"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/$brewplatform/install/HEAD/install.sh)"
fi

export PATH=$brewbinpath:$PATH
brew update && brew upgrade

formulas=(
    htop
    bat
    tree
    asciiquarium
    nerdfetch
    onefetch
)
for formula in "${formulas[@]}"; do
    if brew list "$formula" > /dev/null 2>&1;
    then
        echo "$formula already installed... skipping."
    else
        brew install "$formula"
    fi
done

brew cleanup
brew doctor

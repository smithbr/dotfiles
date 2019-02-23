#!/usr/bin/env bash

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
    /usr/bin/ruby -e "$(curl -fsSL https://raw.githubusercontent.com/$brewplatform/install/master/install)"
fi

echo -e "\\n\\nAdding $brewpath to PATH...\\n"
export PATH=$brewbinpath:$PATH

echo -e "\\n\\nUpdating $brewpath...\\n"
brew update && brew upgrade

echo -e "\\n\\nAdding taps...\\n"
brew tap caskroom/cask
brew tap caskroom/fonts

echo -e "\\n\\nInstalling binaries...\\n"
formulas=(
    zsh
    pipenv
    htop
    curl
    wget
    bat
    tldr
    tree
    neofetch
    cowthink
    fortune
    asciiquarium
    screenfetch
    lolcat
    nyancat
    telegraf
)
for formula in "${formulas[@]}"; do
    if brew list "$formula" > /dev/null 2>&1;
    then
        echo "$formula already installed... skipping."
    else
        brew install "$formula"
    fi
done

echo -e "\\n\\nCleaning up $brewpath...\\n"
brew cleanup
brew doctor

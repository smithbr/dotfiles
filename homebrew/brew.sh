#!/usr/bin/env bash

if [[ "$(uname -s)" == "Darwin" ]];
then
    brewplatform=Homebrew
    brewpath=homebrew
    brewbinpath=/home/homebrew/.homebrew/bin
elif [[ "$( uname )" == "Linux" ]];
then
    brewplatform=Linuxbrew
    brewpath=linuxbrew
    brewbinpath=/usr/local/bin
fi

if test ! "$( which brew )";
then
    echo -e "\\n\\nInstalling homebrew...\\n"
    /usr/bin/ruby -e "$(curl -fsSL https://raw.githubusercontent.com/$brewplatform/install/master/install)"
fi


echo -e "\\n\\nUpdating homebrew...\\n"
brew update && brew upgrade
export PATH=$brewbinpath:$PATH


echo -e "\\n\\nAdding taps...\\n"
brew tap caskroom/cask
brew tap caskroom/fonts


echo -e "\\n\\nInstalling binaries...\\n"
formulas=(
    zsh
    cowsay
    fortune
    htop
    nyancat
    screenfetch
    tldr
    tree
)
for formula in "${formulas[@]}"; do
    if brew list "$formula" > /dev/null 2>&1;
    then
        echo "$formula already installed... skipping."
    else
        brew install "$formula"
    fi
done


echo -e "\\n\\nCleaning up homebrew...\\n"
brew prune
brew cleanup

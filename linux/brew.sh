#!/usr/bin/env bash

if test ! "$( which brew )";
then
    echo -e "\\n\\nInstalling linuxbrew..."
    echo "========================================"
    /usr/bin/ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Linuxbrew/install/master/install)"
fi


echo -e "\\n\\nUpdating linuxbrew..."
echo "========================================"

brew update && brew upgrade


echo -e "\\n\\nAdding taps..."
echo "========================================"

brew tap caskroom/cask
brew tap caskroom/fonts
brew tap loadimpact/k6


echo -e "\\n\\nInstalling binaries..."
echo "========================================"

formulas=(
    ack
    antigen
    cowsay
    fortune
    git
    grafana
    groovy
    htop
    influxdb
    jenkins
    loadimpact/k6/k6
    maven
    nginx
    node
    nyancat
    screenfetch
    selenium-server-standalone
    tldr
    tree
    wget
    yarn
    zsh
)

for formula in "${formulas[@]}"; do
    if brew list "$formula" > /dev/null 2>&1;
    then
        echo "$formula already installed... skipping."
    else
        brew install "$formula"
    fi
done


echo -e "\\n\\nCleaning up..."
echo "========================================"

brew prune
brew cleanup

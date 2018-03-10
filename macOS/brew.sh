#!/usr/bin/env bash

echo -e "\\n\\nInstalling homebrew..."
echo "=============================="

if test ! "$( which brew )"; then
    echo "Installing homebrew"
    ruby -e "$( curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install )"
fi


echo -e "\\n\\nUpdating homebrew..."
echo "=============================="

brew update && brew upgrade


echo -e "\\n\\nAdding taps..."
echo "=============================="

brew tap caskroom/cask
brew tap loadimpact/k6


echo -e "\\n\\nInstalling binaries..."
echo "=============================="

formulas=(
    ack
    cowsay
    fortune
    git
    groovy
    htop
    maven
    nginx
    node
    nyancat
    python@2
    tldr
    tree
    wget
    yarn
    zsh
    # k6
    # selenium-server-standalone
    # jenkins
    # influxdb
    # grafana
)

for formula in "${formulas[@]}"; do
    if brew list "$formula" > /dev/null 2>&1; then
        echo "$formula already installed... skipping."
    else
        brew install "$formula"
    fi
done


echo -e "\\n\\nCleaning up..."
echo "=============================="

brew prune
brew cleanup

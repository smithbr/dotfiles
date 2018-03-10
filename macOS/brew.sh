#!/usr/bin/env bash

# Update homebrew
brew update
brew upgrade

# Add taps
brew tap caskroom/cask
brew tap loadimpact/k6

# Install binaries
brew install zsh
brew install groovy
brew install yarn
brew install maven
brew install htop
brew install node
brew install python
brew install tree
brew install cowsay
brew install fortune
brew install git

# Install extras
# brew install k6
# brew install selenium-server-standalone
# brew install jenkins
# brew install influxdb
# brew install grafana

# Clean up
brew prune
brew cleanup

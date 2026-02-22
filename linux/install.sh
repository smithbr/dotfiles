#!/usr/bin/env bash

set -euo pipefail

sudo -v

sudo apt-get update
sudo apt-get -y upgrade

sudo apt-get install -y build-essential
sudo apt-get install -y fonts-powerline
sudo apt-get install -y zsh

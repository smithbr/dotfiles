#!/usr/bin/env bash

set -euo pipefail

sudo -v
sudo apt-get update
sudo apt-get -y upgrade
sudo apt-get install -y curl build-essential fonts-powerline zsh

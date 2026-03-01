#!/usr/bin/env bash

set -euo pipefail

apt-get update
apt-get -y upgrade
apt-get install -y curl build-essential fonts-powerline zsh

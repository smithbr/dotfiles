#!/usr/bin/env bash

sudo -v

sudo apt-get update
sudo apt-get -y upgrade

sudo apt-get install -y build-essential

echo -e "\\n\\nInstalling curl and wget...\\n"
sudo apt-get install -y curl wget

echo -e "\\n\\nInstalling fonts...\\n"
sudo apt-get install -y fonts-powerline

echo -e "\\n\\nInstalling python and python-pip...\\n"
sudo apt-get install -y python python-pip

echo -e "\\n\\nInstalling ruby...\\n"
sudo apt-get install -y ruby-full

echo -e "\\n\\nInstalling zsh...\\n"
sudo apt-get install -y zsh

echo -e "\\n\\nInstalling cryptomator...\\n"
sudo add-apt-repository ppa:sebastian-stenzel/cryptomator
sudo apt-get update
sudo apt-get install cryptomator

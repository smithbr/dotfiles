#!/usr/bin/env bash

sudo -v

sudo apt-get update
sudo apt-get upgrade

sudo apt-get install -y build-essential

echo -e "\\n\\nInstalling fonts...\\n"
sudo apt-get install -y fonts-powerline

echo -e "\\n\\nInstalling python and python-pip...\\n"
sudo apt-get install -y python python-pip

echo -e "\\n\\nInstalling ruby...\\n"
sudo apt-get install -y ruby-full

echo -e "\\n\\nInstalling zsh...\\n"
sudo apt-get install -y zsh

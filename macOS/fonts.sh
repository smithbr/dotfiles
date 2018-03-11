#!/usr/bin/env bash

echo -e "\\n\\nInstalling fonts...\\n"
git clone https://github.com/powerline/fonts.git --depth=1
cd fonts
./install.sh
cd ..
rm -rf fonts

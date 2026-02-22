#!/usr/bin/env bash

set -euo pipefail

# via https://github.com/powerline/fonts/blob/master/README.rst
git clone https://github.com/powerline/fonts.git --depth=1 $TMPDIR/fonts
cd $TMPDIR/fonts
./install.sh
cd ..
rm -rf $TMPDIR/fonts

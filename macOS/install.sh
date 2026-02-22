#!/usr/bin/env bash

set -euo pipefail

# via https://github.com/powerline/fonts/blob/master/README.rst
if compgen -G "$HOME/Library/Fonts/*Powerline*.ttf" >/dev/null;
then
    echo "Powerline fonts already installed... skipping."
    exit 0
fi

tmp_fonts_dir="$(mktemp -d "${TMPDIR:-/tmp}/powerline-fonts.XXXXXX")"
trap 'rm -rf "$tmp_fonts_dir"' EXIT

git clone https://github.com/powerline/fonts.git --depth=1 "$tmp_fonts_dir"
"$tmp_fonts_dir/install.sh"

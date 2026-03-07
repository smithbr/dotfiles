#!/usr/bin/env bash

set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${BASEDIR}/scripts/common.sh"

log_info "Starting macOS bootstrap"

# via https://github.com/powerline/fonts/blob/master/README.rst
if compgen -G "$HOME/Library/Fonts/*Powerline*.ttf" >/dev/null; then
    log_info "Powerline fonts already installed; skipping"
else
    tmp_fonts_dir="$(mktemp -d "${TMPDIR:-/tmp}/powerline-fonts.XXXXXX")"
    trap 'rm -rf "$tmp_fonts_dir"' EXIT

    log_info "Installing Powerline fonts"
    git clone https://github.com/powerline/fonts.git --depth=1 "$tmp_fonts_dir"
    "$tmp_fonts_dir/install.sh"
fi

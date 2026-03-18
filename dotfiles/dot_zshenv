# zsh only reads ~zshenv before it knows to look under XDG paths.
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}"
export ZDOTDIR="${XDG_CONFIG_HOME}/zsh"

if [[ -f "${ZDOTDIR}/.zshenv" ]]; then
    source "${ZDOTDIR}/.zshenv"
fi

# shellcheck shell=bash
export HISTFILE="${XDG_STATE_HOME:-${HOME}/.local/state}/bash/history"
[[ -d "${HISTFILE%/*}" ]] || mkdir -p "${HISTFILE%/*}"

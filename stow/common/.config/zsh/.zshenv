SHELL_SESSIONS_DISABLE=1

# Every zsh, interactive or not, gets the XDG paths and ~/.local/bin.
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-${HOME}/.cache}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-${HOME}/.local/run}"
export XDG_BIN_HOME="${XDG_BIN_HOME:-${HOME}/.local/bin}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-${HOME}/.local/state}"
export PATH="${XDG_BIN_HOME}:${PATH}"

# Keep $path/$PATH entries unique so re-sourcing / exec reloads don't duplicate them.
typeset -U path PATH

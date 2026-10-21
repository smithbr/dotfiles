# /etc/zshrc_Apple_Terminal reads this in the same shell: no ~/.zsh_sessions.
SHELL_SESSIONS_DISABLE=1

# Every zsh, interactive or not, gets the XDG paths and ~/.local/bin.
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-${HOME}/.cache}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-${HOME}/.local/run}"
export XDG_BIN_HOME="${XDG_BIN_HOME:-${HOME}/.local/bin}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-${HOME}/.local/state}"
export PATH="${XDG_BIN_HOME}:${PATH}"

# Where tools keep their files, instead of a dotfile in the home. Set here, not
# in .zshrc, so scripts, git's gpg signing, and df-doctor see the same paths as
# the interactive shell. Apps launched from the GUI (Claude's MCP servers, say)
# never run zsh and miss all of this; a tool they start needs its own config.
export AWS_CLI_HISTORY_FILE="${XDG_STATE_HOME}/aws/cli/history.db"
export AWS_CONFIG_FILE="${XDG_CONFIG_HOME}/aws/config"
export AWS_DATA_PATH="${XDG_DATA_HOME}/aws/models"
export AWS_SDK_LOAD_CONFIG=1
export AWS_SHARED_CREDENTIALS_FILE="${XDG_CONFIG_HOME}/aws/credentials"
# GitHub Copilot's runtime and VS Code's Copilot keep settings, sessions, and
# logs here, not ~/.copilot. VS Code started from the Dock reads it from a
# login shell when it launches, so restart VS Code after changing it.
export COPILOT_HOME="${XDG_CONFIG_HOME}/copilot"
export GNUPGHOME="${XDG_DATA_HOME}/gnupg"
export GOBIN="${XDG_BIN_HOME}"
export GOMODCACHE="${XDG_CACHE_HOME}/go/mod"
export GOPATH="${XDG_DATA_HOME}/go"
export GRADLE_USER_HOME="${XDG_DATA_HOME}/gradle"
export LIMA_HOME="${XDG_DATA_HOME}/lima"
export NODE_REPL_HISTORY="${XDG_STATE_HOME}/node/repl_history"
export PYTHON_HISTORY="${XDG_STATE_HOME}/python_history"
export XN_IGNOREFILE="${XDG_CONFIG_HOME}/xdg-ninja/ignore"

# colima keeps its settings in ~/.config/colima but its VM (the 20G disk) under
# LIMA_HOME, data rather than config. colima started without this, such as by
# `brew services`, would make a new, empty VM in ~/.config/colima/_lima.

# Docker keeps its current context here, so scripts and colima must agree with
# the interactive shell or they fall back to ~/.docker and lose the context.
export DOCKER_CONFIG="${XDG_CONFIG_HOME}/docker"

# npm has no tmp setting since npm 7 and warns about NPM_CONFIG_TMP, so it is
# left out. brew.sh writes the same cache into Homebrew's global npmrc for npm
# started outside zsh.
export NPM_CONFIG_CACHE="${XDG_CACHE_HOME}/npm"
export NPM_CONFIG_INIT_MODULE="${XDG_CONFIG_HOME}/npm/npm-init.js"
export NPM_CONFIG_USERCONFIG="${XDG_CONFIG_HOME}/npm/npmrc"

# pip refuses to install outside a virtualenv; a Python tool you keep goes
# through `uv tool install` (homebrew/README.md, "Where a tool comes from").
export PIP_REQUIRE_VIRTUALENV=1

# bun's global packages and their commands (domain-check-mcp, say). Without
# BUN_INSTALL, bun puts them under XDG_CACHE_HOME, where a cache cleanup would
# delete them.
export BUN_INSTALL="${XDG_DATA_HOME}/bun"
export PATH="${BUN_INSTALL}/bin:${PATH}"

# Keep $path/$PATH entries unique so re-sourcing / exec reloads don't duplicate them.
typeset -U path PATH

# zmodload zsh/zprof

# Homebrew, when this shell did not go through .zprofile.
[[ -n "${HOMEBREW_PREFIX:-}" ]] || source "${ZDOTDIR}/.zprofile"

# Tool paths every zsh needs are in .zshenv; these only matter at the prompt.
export ANTIDOTE_HOME="${XDG_CACHE_HOME}/antidote"
export STARSHIP_CACHE="${XDG_CACHE_HOME}/starship/cache"
export STARSHIP_CONFIG="${XDG_CONFIG_HOME}/starship/starship.toml"

# History: zsh's own parameters, not exported, so child shells keep their defaults.
HISTFILE="${XDG_STATE_HOME}/zsh/history"
HISTSIZE=20000
SAVEHIST=20000
[[ -d "${HISTFILE:h}" ]] || mkdir -p "${HISTFILE:h}"
setopt APPEND_HISTORY HIST_EXPIRE_DUPS_FIRST HIST_FIND_NO_DUPS HIST_IGNORE_ALL_DUPS
setopt HIST_IGNORE_DUPS HIST_IGNORE_SPACE HIST_REDUCE_BLANKS HIST_SAVE_NO_DUPS
setopt HIST_VERIFY SHARE_HISTORY

[[ -f "${XDG_CONFIG_HOME}/shell/aliases" ]] && source "${XDG_CONFIG_HOME}/shell/aliases"
[[ -f "${XDG_CONFIG_HOME}/shell/functions" ]] && source "${XDG_CONFIG_HOME}/shell/functions"

# 1Password
op_sock="${HOME}/.1password/agent.sock"
op_target="${HOME}/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
[[ "${OSTYPE}" == darwin* ]] && [[ ! -S "${op_sock}" ]] && [[ -S "${op_target}" ]] && mkdir -p "${HOME}/.1password" && ln -sf "${op_target}" "${op_sock}"
[[ -S "${op_sock}" ]] && export SSHKEY_IDENTITY_AGENT="${op_sock}" SSH_AUTH_SOCK="${op_sock}"

# Local overrides
[[ -f "${ZDOTDIR}/.zshrc.local" ]] && source "${ZDOTDIR}/.zshrc.local"

# Antidote
zsh_plugins_file="${ZDOTDIR}/.zsh_plugins.txt"
zsh_plugins_static="${XDG_CACHE_HOME}/zsh/.zsh_plugins.zsh"
antidote_zsh="${HOMEBREW_PREFIX:-/nonexistent}/opt/antidote/share/antidote/antidote.zsh"

# Always source antidote when installed so `antidote bundle`, `antidote load`, etc. work in this shell.
# (If we only sourced the static bundle below, startup would skip antidote.zsh and those commands would not exist.)
[[ -f "${antidote_zsh}" ]] && source "${antidote_zsh}"

if [[ -r "${zsh_plugins_static}" ]] && [[ "${zsh_plugins_static}" -nt "${zsh_plugins_file}" ]]; then
  source "${zsh_plugins_static}"
elif [[ -f "${zsh_plugins_file}" ]] && [[ -f "${antidote_zsh}" ]]; then
  mkdir -p "${zsh_plugins_static:h}"
  if antidote bundle <"${zsh_plugins_file}" >|"${zsh_plugins_static}.tmp"; then
    mv "${zsh_plugins_static}.tmp" "${zsh_plugins_static}"
    source "${zsh_plugins_static}"
  else
    rm -f "${zsh_plugins_static}.tmp"
    antidote load "${zsh_plugins_file}"
  fi
fi

# Starship
command -v starship >/dev/null 2>&1 && eval "$(starship init zsh)"

# Completion
zstyle ':completion:*' menu select

# zprof

source ~/.shell/aliases.sh
source ~/.shell/secrets.sh
source ~/.shell/external.sh

if [[ "$( uname )" == "Darwin" ]];
then
    source ~/.shell/macOS.sh
elif [[ "$( uname )" == "Linux" ]];
then
    :
fi

# Initialize completion before loading plugins that call compdef.
autoload -Uz compinit
compinit

if command -v brew >/dev/null 2>&1;
then
    antidote_zsh="$(brew --prefix)/opt/antidote/share/antidote/antidote.zsh"
    if [[ -f "$antidote_zsh" ]];
    then
        source "$antidote_zsh"
        antidote load ~/.zsh_plugins.txt
    else
        echo "antidote not found at $antidote_zsh" >&2
    fi
else
    echo "brew is not available; cannot load antidote" >&2
fi

eval "$(starship init zsh)"

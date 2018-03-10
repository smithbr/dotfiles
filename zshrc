source ~/.shell/aliases.sh
source ~/.shell/secrets.sh
source ~/.shell/settings.sh
source ~/.zsh/spaceship.zsh

export ZSH=$HOME/.oh-my-zsh

plugins=(git colored-man colorize github jira vagrant virtualenv pip python brew osx zsh-syntax-highlighting zsh-autosuggestions)

# Finally...
source $ZSH/oh-my-zsh.sh

# Set Spaceship ZSH as a prompt
autoload -U promptinit; promptinit
prompt spaceship

export PATH='$(brew --prefix)/bin:$(brew --prefix)/sbin':$PATH

# Aliases
source ~/.shell/aliases.sh

# Secrets file
source ~/.shell/secrets.sh

# External settings
source ~/.shell/external.sh

# OS-specific
if [[ "$( uname )" == "Darwin" ]];
then
    source ~/.shell/macOS.sh
fi

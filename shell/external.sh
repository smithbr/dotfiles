# Homebrew or Linuxbrew
if [[ "$( uname )" == "Darwin" ]];
then
    if [[ "$(uname -m)" == "arm64" ]];
    then
        export PATH=/opt/homebrew/bin:$PATH
        export PATH=/opt/homebrew/sbin:$PATH
    else
        export PATH=/usr/local/bin:$PATH
        export PATH=/usr/local/sbin:$PATH
    fi
elif [[ "$( uname )" == "Linux" ]];
then
    export PATH=/home/linuxbrew/.linuxbrew/bin:$PATH
    export PATH=/home/linuxbrew/.linuxbrew/sbin:$PATH
    export PATH=$HOME/.local/bin:$PATH
fi

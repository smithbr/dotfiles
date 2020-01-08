# Homebrew or Linuxbrew
if [[ "$( uname )" == "Darwin" ]];
then
    export PATH=/usr/local/bin:$PATH
    export PATH=/usr/local/sbin:$PATH
elif [[ "$( uname )" == "Linux" ]];
then
    export PATH=/home/linuxbrew/.linuxbrew/bin:$PATH
    export PATH=/home/linuxbrew/.linuxbrew/sbin:$PATH
    export PATH=$HOME/.local/bin:$PATH
fi

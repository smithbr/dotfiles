# Homebrew or Linuxbrew
if [[ "$( uname )" == "Darwin" ]];
then
    export PATH=/usr/local/bin:$PATH
elif [[ "$( uname )" == "Linux" ]];
then
    export PATH=/home/linuxbrew/.linuxbrew/bin:$PATH
    export PATH=/home/linuxbrew/.linuxbrew/sbin:$PATH
    export PATH=$HOME/.local/bin:$PATH
fi

# go
export GOPATH=$HOME/.go
export PATH=$PATH:/usr/local/opt/go/libexec/bin
PATH="$GOPATH/bin:$PATH"

# java
export JAVA_HOME=/usr/local/opt/java

# jmeter
export JMETER_HOME=/usr/local/opt/jmeter
export PATH=$JMETER_HOME/bin:$PATH

# maven
export M2_HOME=/usr/local/opt/maven
export M2=$M2_HOME/bin
export MAVEN_OPTS="-Xmx1048m -Xms256m -XX:MaxPermSize=312M"
export PATH=$M2:$PATH

# nvm
export NVM_DIR=~/.nvm
source $(brew --prefix nvm)/nvm.sh

# gatling
export GATLING_HOME=/usr/local/opt/gatling
export PATH=$GATLING_HOME/bin/gatling.sh:$PATH

# influxdb
export INFLUXDB_CONFIG_PATH=/usr/local/etc/influxdb.conf

# python
# export PYTHONPATH=/custom/path:$PYTHONPATH

# python pip
# Cache pip-installed packages to avoid re-downloading
mkdir -p $HOME/.pip/cache
export PIP_DOWNLOAD_CACHE=$HOME/.pip/cache

# sqlite
export PATH=/usr/local/opt/sqlite/bin:$PATH

# virtualenvwrapper
export WORKON_HOME=~/.virtualenvs
export PROJECT_HOME=$HOME/projects
if [[ "$( uname )" == "Darwin" ]];
then
    source /usr/local/bin/virtualenvwrapper.sh
elif [[ "$( uname )" == "Linux" ]];
then
    source $HOME/.local/bin/virtualenvwrapper.sh
fi

# yarn
export PATH="$PATH:/usr/local/Cellar/yarn/1.9.4/bin"

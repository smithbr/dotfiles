# jmeter
export JMETER_HOME=$HOME/apps/jmeter
export PATH=$PATH:$JMETER_HOME/bin

# gatling
export GATLING_HOME=$HOME/apps/gatling
export PATH=$PATH:$GATLING_HOME/bin

# java
export JAVA_HOME=$HOME/apps/java/Contents/Home
export PATH=$PATH:$JAVA_HOME/bin

# maven
export M2_HOME=$HOME/apps/maven
export M2=$M2_HOME/bin
export PATH=$PATH:$M2

# influxdb
export INFLUXDB_CONFIG_PATH=/usr/local/etc/influxdb.conf

# virtualenvwrapper
export WORKON_HOME=~/.virtualenvs
source /usr/local/bin/virtualenvwrapper.sh

# os x
export PATH=/usr/local/bin:$PATH

# python
# pip should only run if there is a virtualenv currently activated
export PIP_REQUIRE_VIRTUALENV=true
# Cache pip-installed packages to avoid re-downloading
export PIP_DOWNLOAD_CACHE=$HOME/.pip/cache

# rvm
# Add RVM to PATH for scripting. Make sure this is the last PATH variable change.
export PATH="$PATH:$HOME/.rvm/bin"
[[ -s "$HOME/.rvm/scripts/rvm" ]] && source "$HOME/.rvm/scripts/rvm" # Load RVM into a shell session *as a function*

# yarn
export PATH="$PATH:/usr/local/Cellar/yarn/1.5.1/bin"

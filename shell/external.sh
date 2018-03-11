# JMeter
export JMETER_HOME=/usr/local/opt/jmeter
export PATH=$JMETER_HOME/bin/jmeter:$PATH

# Maven
export M2_HOME=/usr/local/opt/maven
export M2=$M2_HOME/bin
export MAVEN_OPTS="-Xmx1048m -Xms256m -XX:MaxPermSize=312M"
export PATH=$M2:$PATH

# Gatling
export GATLING_HOME=/usr/local/opt/gatling
export PATH=$GATLING_HOME/bin/gatling.sh:$PATH

# InfluxDB
export INFLUXDB_CONFIG_PATH=/usr/local/etc/influxdb.conf

# Python
# virtualenvwrapper
export WORKON_HOME=~/.virtualenvs
export PROJECT_HOME=$HOME/projects
if [[ "$(uname)" == "Darwin" ]]; then
    source /usr/local/bin/virtualenvwrapper.sh
elif [[ "$(uname)" == "Linux" ]]; then
    source $HOME/.local/bin/virtualenvwrapper.sh
fi


# pip
# pip should only run if there is a virtualenv activated
# export PIP_REQUIRE_VIRTUALENV=true

# Cache pip-installed packages to avoid re-downloading
# mkdir -p $HOME/.pip/cache
# export PIP_DOWNLOAD_CACHE=$HOME/.pip/cache

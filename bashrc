# aliases
alias ls='ls -l'
alias lsa='ls -FGlAhp'
alias gh="git log --graph --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit"
alias jp='cd $HOME/projects/aegaxs/jmeter/jmeterMaven'
alias jt='cd $HOME/projects/aegaxs/jmeter/jmeterTaurus'

# terminal
export CLICOLOR=1
export LSCOLORS=GxFxCxDxBxegedabagaced

# jmeter
export JMETER_HOME=$HOME/apps/jmeter
export PATH=$PATH:$JMETER_HOME/bin

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

# Add RVM to PATH for scripting. Make sure this is the last PATH variable change.
export PATH="$PATH:$HOME/.rvm/bin"

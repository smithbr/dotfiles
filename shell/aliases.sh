# navigation
alias lsa="ls -FGlAhp"
alias h="history"

# shell
alias reload="exec $SHELL -l"
alias fish='asciiquarium'

if [[ "$( uname )" == "Darwin" ]];
then
    alias ip_local="ipconfig getifaddr en0"
elif [[ "$( uname )" == "Linux" ]];
then
    alias ip_local="hostname -I"
fi

# network
alias ip_public="curl ipinfo.io/ip"
alias dns="cat /etc/resolv.conf"

# remove junk files
alias cleanup="find ~ -type f \( -name 'jmeter.log' -o -name 'results.xml' -o -name '.zcompdump*' \) -ls -delete"
alias cleanupds="find . -type f -name '*.DS_Store' -ls -delete"

# encode/decode strings
alias urlencode='python -c "import sys, urllib as ul; print ul.quote_plus(sys.argv[1])"'
alias urldecode='python -c "import sys, urllib as ul; print ul.unquote_plus(sys.argv[1])"'

# list of aws instances
alias awsi="workon aws; aws ec2 describe-instances --query 'Reservations[].Instances[].[InstanceId, Tags[?Key==\"Name\"] | [0].Value, State.Name, PublicDnsName]' --output table"

# start vnc server
alias startvnc="sudo systemctl start x11vnc.service"

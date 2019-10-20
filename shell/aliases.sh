# navigation
alias lsa="ls -FGlAhp"
alias h="history"

# shell
alias reload="exec $SHELL -l"
alias fish='asciiquarium'

if [[ "$( uname )" == "Darwin" ]];
then
    alias ip_local="ipconfig getifaddr en0"
    alias flushdns="dscacheutil -flushcache"
    # open firefox profile switcher
    alias ff='/Applications/Firefox.app/Contents/MacOS/firefox -P --no-remote'
elif [[ "$( uname )" == "Linux" ]];
then
    alias ip_local="hostname -I"
fi

# network
alias ip_public="dig +short myip.opendns.com @resolver1.opendns.com"
alias dns="cat /etc/resolv.conf"
alias ip_locale="curl https://freegeoip.app/xml/"

# remove junk files
alias cleanup="find ~ -type f \( -name 'jmeter.log' -o -name 'results.xml' -o -name '.zcompdump*' \) -ls -delete"
alias cleanupds="find . -type f -name '*.DS_Store' -ls -delete"
alias emptyfolders="du -a --max-depth=1 | sort -n"

# encode/decode strings
alias urlencode='python -c "import sys, urllib as ul; print ul.quote_plus(sys.argv[1])"'
alias urldecode='python -c "import sys, urllib as ul; print ul.unquote_plus(sys.argv[1])"'

# list of aws instances
alias awsi="workon aws; aws ec2 describe-instances --query 'Reservations[].Instances[].[InstanceId, Tags[?Key==\"Name\"] | [0].Value, State.Name, PublicDnsName]' --output table"

# start vnc server
alias startvnc="sudo systemctl start x11vnc.service"

# start portainer
alias portainer="docker run -dit --restart unless-stopped -d -p 9000:9000 -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer"

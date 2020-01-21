# navigation
alias lsa="ls -FGlAhp"
alias h="history"

# shell
alias reload="exec $SHELL -l"
alias fish='asciiquarium'

# network
alias ip_public="dig +short myip.opendns.com @resolver1.opendns.com"
alias dns="cat /etc/resolv.conf"
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

# remove junk files
alias cleanupds="find . -type f -name '*.DS_Store' -ls -delete"
alias emptyfolders="du -a --max-depth=1 | sort -n"

# encode/decode strings
alias urlencode='python -c "import sys, urllib as ul; print ul.quote_plus(sys.argv[1])"'
alias urldecode='python -c "import sys, urllib as ul; print ul.unquote_plus(sys.argv[1])"'

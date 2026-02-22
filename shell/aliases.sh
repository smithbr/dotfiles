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
elif [[ "$( uname )" == "Linux" ]];
then
    alias ip_local="hostname -I"
    alias flushdns="sudo systemd-resolve --flush-caches"
fi

# remove junk files
alias cleanupds="find . -type f -name '*.DS_Store' -ls -delete"
alias emptyfolders="du -a --max-depth=1 | sort -n"

# encode/decode strings
alias urlencode='python3 -c "import sys, urllib.parse; print(urllib.parse.quote_plus(sys.argv[1]))"'
alias urldecode='python3 -c "import sys, urllib.parse; print(urllib.parse.unquote_plus(sys.argv[1]))"'

# fix macOS time
alias time="sudo sntp -sS time.apple.com"

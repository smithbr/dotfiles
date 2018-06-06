# Navigation
alias lsa="ls -FGlAhp"
alias h="history"

# Reload shell
alias reload="exec $SHELL -l"

# Network
alias ip_public="curl ipinfo.io/ip"
alias ip_local="ipconfig getifaddr en0"
alias dns="cat /etc/resolv.conf"

# Remove junk files
alias cleanup="find ~ -type f \( -name 'jmeter.log' -o -name 'results.xml' -o -name '.zcompdump*' \) -ls -delete"
alias cleanupds="find . -type f -name '*.DS_Store' -ls -delete"

# Web tools
alias urlencode='python -c "import sys, urllib as ul; print ul.quote_plus(sys.argv[1])"'
alias urldecode='python -c "import sys, urllib as ul; print ul.unquote_plus(sys.argv[1])"'

# aws instances
alias awsi="workon aws; aws ec2 describe-instances --query 'Reservations[].Instances[].[InstanceId, Tags[?Key==\"Name\"] | [0].Value, State.Name, PublicDnsName]' --output table"

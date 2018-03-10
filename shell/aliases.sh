# Navigation
alias lsa="ls -FGlAhp"

# Network
alias ip_public="curl ipinfo.io/ip"
alias ip_local="ipconfig getifaddr en0"

# Remove junk files
alias cleanup="find ~ -type f \( -name 'jmeter.log' -o -name 'results.xml' -o -name '.zcompdump*' \) -ls -delete"
alias cleanupds="find . -type f -name '*.DS_Store' -ls -delete"

# Web tools
alias urlencode='python -c "import sys, urllib as ul; print ul.quote_plus(sys.argv[1])"'
alias urldecode='python -c "import sys, urllib as ul; print ul.unquote_plus(sys.argv[1])"'

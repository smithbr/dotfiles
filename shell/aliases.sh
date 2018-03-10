# Navigation
alias lsa="ls -FGlAhp"

# Network
alias ip_public="curl ipinfo.io/ip"
alias ip_local="ipconfig getifaddr en0"

# Remove junk files
alias cleanup="find ~ -type f \( -name 'jmeter.log' -o -name 'results.xml' -o -name '.zcompdump*' \) -ls -delete"
alias cleanupds="find . -type f -name '*.DS_Store' -ls -delete"

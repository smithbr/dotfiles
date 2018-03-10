# navigation
alias lsa="ls -FGlAhp"
alias f="open -a Finder ./"

# cleanup
alias cleanup="find ~ -type f \( -name 'jmeter.log' -o -name 'results.xml' -o -name '.zcompdump*' \) -ls -delete"
alias cleanupds="find . -type f -name '*.DS_Store' -ls -delete"

# network
alias ip_public="curl ipinfo.io/ip"
alias ip_local="ipconfig getifaddr en0"

# os x finder hidden files
alias hf_show="defaults write com.apple.finder AppleShowAllFiles YES; killall Finder /System/Library/CoreServices/Finder.app"
alias hf_hide="defaults write com.apple.finder AppleShowAllFiles NO; killall Finder /System/Library/CoreServices/Finder.app"

# macOS settings

# Navigation
alias f="open -a Finder ./"

# Show/hide hidden files in Finder
alias hf_show="defaults write com.apple.finder AppleShowAllFiles YES; killall Finder /System/Library/CoreServices/Finder.app"
alias hf_hide="defaults write com.apple.finder AppleShowAllFiles NO; killall Finder /System/Library/CoreServices/Finder.app"

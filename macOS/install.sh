#!/usr/bin/env bash

echo -e "\\n\\nInstalling oh-my-zsh..."
echo "=============================="

if [ -d "$HOME/.oh-my-zsh" ]; then
    echo "Removing existing ~/.oh-my-zsh directory first..."
    rm -rf $HOME/.oh-my-zsh
fi
git clone https://github.com/robbyrussell/oh-my-zsh.git $HOME/.oh-my-zsh


echo -e "\\n\\nInstalling spaceship-prompt..."
echo "=============================="

echo "Making spaceship-prompt directory..."
mkdir -p $HOME/.oh-my-zsh/custom/themes/spaceship-prompt

echo "Cloning spaceship-prompt..."
git clone https://github.com/denysdovhan/spaceship-prompt.git "$HOME/.oh-my-zsh/custom/themes/spaceship-prompt"
ln -s "$HOME/.oh-my-zsh/custom/themes/spaceship-prompt/spaceship.zsh-theme" "$HOME/.oh-my-zsh/custom/themes/spaceship.zsh-theme"


echo -e "\\n\\nChanging default shell to zsh..."
echo "=============================="

zsh_path="$( which zsh )"

if ! grep "$zsh_path" /etc/shells; then
    echo "adding $zsh_path to /etc/shells"
    echo "$zsh_path" | sudo tee -a /etc/shells
fi

if [[ "$SHELL" != "$zsh_path" ]]; then
    chsh -s "$zsh_path"
    echo "default shell changed to $zsh_path"
fi

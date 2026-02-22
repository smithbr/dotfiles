# dotfiles
🗃 My dotfiles

## Quick start

```bash
$ git clone https://github.com/smithbr/dotfiles.git dotfiles
$ cd dotfiles/
$ ./install
$ zsh # or bash
```

`install` now bootstraps `chezmoi` and applies files from `./chezmoi`.

## Chezmoi workflow

Apply directly from this repo without using `install`:

```bash
$ chezmoi init --source "$PWD/chezmoi"
$ chezmoi apply
```

Preview pending changes:

```bash
$ chezmoi diff
```

Re-apply after edits to files in `chezmoi/`:

```bash
$ chezmoi apply
```

## Sync from live dotfiles

If you change a file directly in `$HOME`, add it back to this repo's chezmoi source:

```bash
$ chezmoi add ~/.zshrc
```

Common examples:

```bash
$ chezmoi add ~/.zshrc
$ chezmoi add ~/.gitconfig
$ chezmoi add ~/.config/ghostty/config
$ chezmoi add ~/.config/Code/User/settings.json
```

If it is already tracked and you want to refresh the source copy from the live file:

```bash
$ chezmoi re-add ~/.zshrc
```

Common refresh examples:

```bash
$ chezmoi re-add ~/.zshrc
$ chezmoi re-add ~/.gitconfig
$ chezmoi re-add ~/.config/ghostty/config
$ chezmoi re-add ~/.config/Code/User/settings.json
```

Then review and commit:

```bash
$ git status
$ git add .
$ git commit -m "update dotfiles"
```

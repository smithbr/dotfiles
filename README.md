## 🗃 My dotfiles

```bash
git clone https://github.com/smithbr/dotfiles.git ~/.dotfiles
~/.dotfiles/install.sh
```

Chezmoi docs: [https://www.chezmoi.io/](https://www.chezmoi.io/)

### Optional flags

Run `~/.dotfiles/install.sh --help` for the full list.

- `-n`, `--dry-run` to report what would change without touching the system
- `-v`, `--verbose` to stream command output instead of collecting it into boxes
- `-d`, `--debug` for verbose output plus shell command tracing
- `-h`, `--help` to show usage and exit
- `--skip-system` to skip OS bootstrap
- `--skip-brew` to skip Homebrew install/update/bundle
- `--skip-shell` to skip adding zsh to `/etc/shells` and `chsh`

Anything else is passed through to `chezmoi apply`, as is everything after `--`:

```bash
~/.dotfiles/install.sh --skip-brew -- --force --exclude=scripts
```

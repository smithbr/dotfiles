# My dotfiles

macOS and Debian/Ubuntu dotfiles linked into place with [GNU Stow](https://www.gnu.org/software/stow/).
Every managed file in `~` is a symlink into this repo, so edit it in place and commit.

```bash
git clone https://github.com/smithbr/dotfiles.git ~/.dotfiles
~/.dotfiles/install.sh
```

Run `~/.dotfiles/install.sh --help` for installation options. After adding a
file under `stow/`, run `~/.dotfiles/scripts/link.sh` to link it.

See [AGENTS.md](AGENTS.md) for maintenance and quality rules.

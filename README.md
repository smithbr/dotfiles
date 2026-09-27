# My dotfiles

macOS and Debian/Ubuntu dotfiles linked into place with [GNU Stow](https://www.gnu.org/software/stow/).
Every managed file in `~` is a symlink into this repo, so edit it in place and commit.

```bash
git clone https://github.com/smithbr/dotfiles.git ~/.dotfiles
~/.dotfiles/install.sh --persona home
```

Pick the persona that fits the machine: `home` (your Mac), `work` (a work Mac,
no private agents config), `server` (a headless box, macOS or Linux), or
`sandbox` (throwaway VMs and CI). The choice is saved; without `--persona`,
the installer asks. Run `~/.dotfiles/install.sh --help` for installation options. After adding a
file under `stow/`, run `~/.dotfiles/scripts/link.sh` to link it.

See [AGENTS.md](AGENTS.md) for maintenance and quality rules.

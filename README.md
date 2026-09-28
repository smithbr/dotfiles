# My dotfiles

macOS and Debian/Ubuntu dotfiles linked into place with [GNU Stow](https://www.gnu.org/software/stow/).
Every managed file in `~` is a symlink into this repo, so edit it in place and commit.

```bash
git clone https://github.com/smithbr/dotfiles.git ~/.dotfiles
~/.dotfiles/install.sh --persona home
```
## Personas
Pick the persona that fits the machine:

- `home` (everything),
- `work` (scoped config),
- `server` (a headless box, macOS or Linux)
- `sandbox` (throwaway VMs and CI).

## Managing files
```bash
df-add stow ~/.config/tool/config  # adds file and symlinks it
df-add brew llmfit                 # installs it and adds it to a Brewfile
df-link status                     # shows drift
df-file-review                     # shows leftovers to archive
df-link                            # After adding a file under `stow/`
df-deploy pihole                   # After pushing: pull and relink on other machines
```

See [AGENTS.md](AGENTS.md) for maintenance and quality rules.

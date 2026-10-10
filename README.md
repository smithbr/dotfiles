# My dotfiles

macOS and Debian/Ubuntu dotfiles linked into place with [GNU Stow](https://www.gnu.org/software/stow/).
Every managed file in `~` is a symlink into this repo, so edit it in place and commit; the few files under `seed/` are copied once instead.

```bash
git clone https://github.com/smithbr/dotfiles.git ~/.dotfiles
~/.dotfiles/install.sh --persona home
```
The install ends by offering the persona's setup scripts on a terminal: Docker, Tailscale, Claude Code, and on a `vps` first `harden` (key-only SSH over Tailscale, firewall, unattended upgrades; for a new machine, never one already serving). A VPS that only has a root login needs its admin user before the install; create it with the same script, then install as that user:

```bash
ssh root@HOST 'bash -s -- --user NAME --allow 80 --allow 443' < ~/.dotfiles/scripts/bootstrap/linux/harden.sh
```

## Personas
Pick the persona that fits the machine:

- `home` (everything),
- `work` (scoped config),
- `server` (a headless box at home, macOS or Linux),
- `vps` (a Linux box on the public internet; its setup step offers `harden`).

## Managing files
```bash
df-add stow ~/.config/tool/config  # adds file and symlinks it
df-add brew llmfit                 # installs it and adds it to a Brewfile
df-link status                     # shows drift
df-file-review                     # shows leftovers to archive
df-link                            # After adding a file under `stow/`
df-deploy pihole                   # After pushing: pull and relink on other machines
```

See [AGENTS.md](AGENTS.md) for maintenance and quality rules. Each part of the repo has its own README: [scripts](scripts/README.md) (linking, file review), [bootstrap](scripts/bootstrap/README.md) (OS setup, `harden.sh` options), [stow](stow/README.md) (layers), [homebrew](homebrew/README.md) (where packages go), and [tests](tests/README.md).

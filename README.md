# My dotfiles

macOS and Debian dotfiles linked into place with [GNU Stow](https://www.gnu.org/software/stow/). Every managed file in `~` is a symlink into this repo, so edit it in place and commit. The files under `seed/` are copied once instead.

```bash
git clone https://github.com/smithbr/dotfiles.git ~/.dotfiles
~/.dotfiles/install.sh
```

On a machine with nothing yet, one line clones and installs. As root on a new VPS, `--user NAME` first creates and hardens for that admin user:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/smithbr/dotfiles/main/bootstrap.sh) --persona vps
```

The install asks what the machine is up front, remembers the answers, and changes only what differs, so it is safe to run again. `--persona NAME`, `--install NAME`, and `--no-install NAME` answer without a terminal; `-n` prints what would change. `install.sh --help` lists the rest. On a Linux `server` or `vps` that is not yet hardened, the install first offers to harden it.

## Personas and roles

A persona says whose machine it is; a role says what it is for ([roles/](roles/README.md)). Docker and Tailscale on Linux and Claude Code on both OSes are offered to every persona, on by default.

- `home`: everything.
- `work`: scoped config.
- `server`: a headless box at home, macOS or Linux; offers the Pi-hole role.
- `vps`: a Linux box on the public internet; hardened first when it is not.

## Managing files

```bash
df-add stow ~/.config/tool/config  # adds file and symlinks it
df-add brew llmfit                 # installs it and adds it to a Brewfile
df-rm ~/.config/tool/config        # stops managing it and keeps the file
df-mv ~/.config/tool/config        # moves it to another layer
df-link status                     # shows drift
df-doctor                          # checks the machine, then lets you choose a change for each item
df-link                            # After adding a file under `stow/`
df-deploy pihole                   # After pushing: pull and relink on other machines
```

See [AGENTS.md](AGENTS.md) for repo-wide rules. Each directory has its own README: [scripts](scripts/README.md), [bootstrap](scripts/bootstrap/README.md), [roles](roles/README.md), [stow](stow/README.md), [homebrew](homebrew/README.md), [seed](seed/README.md), [editors](editors/README.md), and [tests](tests/README.md).

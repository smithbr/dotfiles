# My dotfiles

macOS and Debian/Ubuntu dotfiles linked into place with [GNU Stow](https://www.gnu.org/software/stow/).
Every managed file in `~` is a symlink into this repo, so edit it in place and commit; the few files under `seed/` are copied once instead.

```bash
git clone https://github.com/smithbr/dotfiles.git ~/.dotfiles
~/.dotfiles/install.sh
```
On a machine with nothing yet, one line does the clone and the install (as root on a new VPS, `--user NAME` first creates and hardens for that admin user):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/smithbr/dotfiles/main/bootstrap.sh) --persona vps
```

The install asks what the machine is once, up front (persona, installs, optional packages), remembers the answers, and then only changes what differs, so it is safe to run on a machine already set up. `--persona NAME`, `--install NAME`, and `--no-install NAME` answer without a terminal, `--reconfigure` asks again, and `-n` prints what would change. On a Linux `server` or `vps` that is not yet hardened, the install first offers to harden it (key-only SSH over Tailscale, firewall, unattended upgrades; `scripts/bootstrap/linux/harden-test.sh` is the check, and runs on its own against any Linux box). Installs are applied last: Docker and Tailscale (Linux) and Claude Code (both), which every persona offers pre-checked and skips when the tool is already there through Homebrew or natively, and the persona's roles, such as a Pi-hole with Unbound as its upstream (`--install pihole` on a `server`).

## Personas and roles
Pick the persona that fits the machine, then the installs it should have: Docker, Tailscale, and Claude Code are offered to every persona, pre-checked, and a role is what the machine is for ([roles/](roles/README.md)):

- `home` (everything),
- `work` (scoped config),
- `server` (a headless box at home, macOS or Linux; offers the Pi-hole role),
- `vps` (a Linux box on the public internet; hardened first when it is not).

## Managing files
```bash
df-add stow ~/.config/tool/config  # adds file and symlinks it
df-add brew llmfit                 # installs it and adds it to a Brewfile
df-rm ~/.config/tool/config        # stops managing it and keeps the file
df-link status                     # shows drift
df-file-review                     # shows leftovers to archive
df-link                            # After adding a file under `stow/`
df-deploy pihole                   # After pushing: pull and relink on other machines
```

See [AGENTS.md](AGENTS.md) for maintenance and quality rules. Each part of the repo has its own README: [scripts](scripts/README.md) (linking, file review), [bootstrap](scripts/bootstrap/README.md) (OS setup, `harden.sh` and its check), [roles](roles/README.md) (what a machine is for), [stow](stow/README.md) (layers), [homebrew](homebrew/README.md) (where packages go), and [tests](tests/README.md).

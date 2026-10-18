# roles/

What a machine is for, beside the persona that says whose it is. A role is `roles/<name>`: plain `key=value` lines, parsed like a persona and never sourced. Its keys:

- `os`: allowed platforms.
- `layers`: linked like the persona's own.
- `brew`: Brewfiles installed in full, joining the persona's.
- `requires`: installs applied first, chosen or not; a role or an optional install.
- `detect`: a command that succeeds once the role is applied, run with `bash -c` with `scripts/common.sh` sourced.
- `setup`: the script `install.sh` runs when detect fails, `scripts/bootstrap/<os>/<setup>.sh` or `scripts/bootstrap/<setup>.sh`; the role's own name when left out.

A persona lists roles in `roles` (on by default) and `roles_optional` (offered).

## Optional installs

Beside the roles stand the optional installs, which no persona lists. A setup script in `scripts/bootstrap/<os>/` or `scripts/bootstrap/` with a `# detect: COMMAND` line is offered to every persona on its OS, on by default unless it also says `# default: off`. A role's setup script declares no detect line; the role file does. A command-line tool detects with `tool_installed NAME` from `scripts/common.sh`, which looks on PATH, in `~/.local/bin`, and in Homebrew's bin, so a tool installed through one manager is not installed again through the other.

## How install.sh applies them

- On a terminal, `install.sh` asks on every run, like the persona: first the roles ("What is this machine for?"), then the optional installs, with the saved choice and the installs already applied preselected so Enter keeps them. The answer is saved in `~/.local/state/dotfiles/installs`. `--install NAME`, `--no-install NAME`, and `DOTFILES_INSTALLS` answer without a terminal. Closed stdin keeps the saved choice; a fresh machine gets the installs on by default and the persona's `roles`, and nothing off by default or only offered.
- Installs run last, in `requires` order, each skipped when its detect command succeeds. A failed one stays chosen, so the next run retries it. A setup script's output streams under its step; `install.sh --verbose` shows it raw.
- `scripts/link.sh offered` lists what this persona is offered on this OS, with each detect command; `scripts/link.sh installs` lists the chosen installs in run order.

## pihole

The `pihole` role brings the `pihole` layer (the `ph-*` tools) and sets up Pi-hole with Unbound as its upstream through `scripts/bootstrap/linux/pihole.sh` ([`scripts/bootstrap/README.md`](../scripts/bootstrap/README.md)). It requires `tailscale`, which joins even when unticked. It counts as applied once both are installed and Unbound has its Pi-hole config.

## Adding one

A new role is a file here plus a setup script in `scripts/bootstrap/`; add it to the personas that should offer it. A new optional install is only the setup script, with its detect line. Either must be safe to run again.

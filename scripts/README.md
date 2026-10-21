# scripts/

Repository tooling: the linker, the Brewfile helper, the machine check, and `common.sh`. Bootstrap has its own rules in [`bootstrap/README.md`](bootstrap/README.md); repo-wide rules are in the [root `AGENTS.md`](../AGENTS.md). Each script's `--help` is the reference for its flags; this page says what each one is for and the rules around it.

## link.sh

`scripts/link.sh` links the persona's layers, editor settings, agent links, skills, and seed files into `~` and removes stale links. A run prints the persona and its layers, each link it makes and each file it clears, one count line per step, and a closing count; a dry run lists the links it would make. Stow's `--target` and `--dir` are rejected; use `--destination`. The agents checkout is pulled at most weekly; `--refresh` pulls it now, and `install.sh` always passes it.

Subcommands:

- `add PATH... [--layer NAME] [--platform] [--seed]` copies files from `~` into a layer (its `<layer>.<os>` part with `--platform`, `seed/` with `--seed`) and links them. Without `--layer` it asks on a terminal, describing each layer (`layer_rule` in `link.sh`), and fails on closed stdin. Before copying anything it refuses paths outside the destination, symlinks, files already in the repo, `.local` overrides, editor settings, private agent paths, and private keys and other secrets.
- `rm PATH... [--delete]` replaces each link with a real copy of its repo file, keeping its mode, then `git rm`s the repo file and the folders left empty. `--delete` moves the file to `~/.local/state/dotfiles/cleanup/<timestamp>.remove/` instead. A path must be a link into `stow/`, or a directory of them. It refuses real files, seed files, and foreign, agent, and editor links, and leaves the commit to you. Other machines drop the link as stale on their next `df-link` or `df-deploy`, losing the file there unless `link.sh rm` ran first.
- `mv PATH... [--layer NAME] [--platform | --no-platform]` moves linked files to another layer, or renames a repo file to match a file already moved in `~`. The link in `~` is swapped by a rename, so the file never goes missing, and the index shows a `git mv`. It refuses whatever `rm` refuses, a layer this persona does not link, the file's current place, and a destination the layer already has. Afterwards it lists, without editing, the repo lines that still name the old path. A machine whose persona does not link the new layer loses the file.
- `persona`, `personas`, `offered`, and `installs` print the persona in effect, the ones this OS allows, the installs offered, and the chosen installs in run order ([`roles/README.md`](../roles/README.md)).
- `status` lists missing, replaced, foreign, broken, and stale links, plus `shadowed` when `~/.gitconfig` sets `[user]`, `unset` when git has no `user.email`, and `unlinked` for a real file where a layer this persona does not link would put one. `managed` prints every path the repo owns.

Rules:

- Links into the private agents checkout (`~/.config/agents`) and the directories kept at mode 700 are `AGENT_LINKS` and `PRIVATE_DIRS` in `link.sh`. Git keeps only the executable bit; any other permission is applied there.
- A skill that ships with a Homebrew CLI is listed in `TOOL_SKILLS`: it is linked from Homebrew's `opt` directory while the CLI is installed and removed once it is gone.
- A link into `stow/` or `editors/` that no longer belongs on this host is stale: `link.sh` removes it and `status` reports it. Only links are removed, never real files, so moving or deleting a managed file needs no manual cleanup.
- An application that saves by replacing its config file turns the link into a real file; `status` and `df-doctor` report it as `replaced`.

## Wrappers

The `tools` layer puts `df-link`, `df-doctor`, `df-mv`, and `df-add` on the PATH. Each finds the repo through its own stow link and runs the script with its arguments, so the scripts stay in `scripts/`, where bootstrap needs them before anything is linked. `df-add stow PATH...` is `link.sh add`; `df-add brew NAME...` runs `scripts/brew-add.sh`.

## brew-add.sh

Installs each package (`--no-install` skips that) and adds it to a Brewfile in `homebrew/`, sorted among entries of its kind in the chosen section, formulae before casks. It detects a cask when no formula has the name (`--cask` and `--formula` override), skips names any Brewfile already lists, and records nothing when the install fails. Without `--file` it offers the persona's Brewfiles on a terminal, and without `--section` it asks when the file has more than one; closed stdin fails with the choices.

## doctor.sh (df-doctor)

`scripts/doctor.sh` checks the machine against the repo in one pass and sorts every finding into **Links** (repo links `link.sh status` reports as off), **Fix** (changes it suggests: archive junk, backup copies, broken links in `~/.local/bin`, old zsh completion caches, and the old copy of a tool a new shell sends elsewhere; move a file where xdg-ninja says), **Decide** (needs a person), **Not in the repo** (config in `~/.config` and commands in `~/.local/bin` made outside the repo), and **Ignore** (in use, local state, made by the OS, no XDG support, or marked to ignore; `--all` lists them). Without a terminal, or with `--report`, it only reports. Unmanaged does not mean unused.

- It checks each unmanaged dotfile in the home, everything directly in the XDG config and bin folders, and the unmanaged files in folders that hold managed files; folders named on the command line are checked in full. Credentials, private agent directories, the repo, managed paths, and expected local overrides (a file whose `.example` the repo manages) are never findings.
- Files Debian and its desktops make in a home are in `os_entry`, each `critical` or `normal` with a system path that shows its owner is installed; while that path exists the file is ignored as made by the OS, afterwards it is a leftover to archive. `DF_DOCTOR_ROOT` moves the lookup for tests.
- XDG knowledge comes from xdg-ninja's program data (`DF_DOCTOR_PROGRAMS` and `DF_DOCTOR_PREFIXES` override where it is found) and from the environment a new zsh starts with, read from the home's own `.zshenv`; a value exported only in the running shell does not count. Without xdg-ninja or jq there is no XDG advice. An owner is a command or app named like the entry; other names map in `owner_alias`.
- On a terminal the report is followed by one list of every item it may change, each row set to its suggestion (a Fix item's archive or move, skip for the rest, plus a `relink` row when repo links are off). Enter applies every row at once; `q` or Esc changes nothing. Delete lists what goes and asks once more, defaulting to no. `--fix` shows the list without a terminal and reads one line (`delete 2 5-7 ignore 3`; `DOTFILES_PROMPT=read` forces this). Closed stdin, non-interactive installs, dry runs, and an incomplete check never change anything; an incomplete check makes the run fail.
- Archive moves a file to `~/.local/state/dotfiles/cleanup/<timestamp>.<suffix>/` with private permissions and original relative paths; restore by moving it back. Delete is `rm -rf` and keeps no copy. Add runs `link.sh add` on that path. Move follows xdg-ninja's advice when it names one `$XDG_*_HOME` target; it is a rename that refuses a symlink, an existing target, a symlinked parent, another filesystem, or a path a running program has open (`lsof`), and logs its undo to `~/.local/state/dotfiles/moves.tsv`. Deletes run first, then archives, moves, and adds; `relink` last.
- Ignore marks a path as fine for this machine (`--ignore PATH`, `--unignore PATH`; `--explain PATH` names what covers one). The list is `~/.local/state/dotfiles/doctor-ignore`, per machine and editable by hand; anything every machine should ignore belongs in `is_local_state` in `doctor.sh`.
- For the installer and tests: `--source`, `--destination`, `--no-hint`, `--fix-only`, `--report`, and `--tsv`. Installation ends with the report in a box, then interactive installs run `doctor.sh --fix-only` unboxed.

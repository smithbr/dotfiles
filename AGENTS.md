# Dotfiles change quality

These rules apply throughout this repository. Before changing a directory, read its `README.md`: it says how that part works, and its rules apply there too.

- [`scripts/`](scripts/README.md): `link.sh`, the `df-*` wrappers, `brew-add.sh`, and the file review and cleanup.
- [`scripts/bootstrap/`](scripts/bootstrap/README.md): OS bootstrap, optional Linux installs, `iterm2.sh`, and `harden.sh` for new servers.
- [`stow/`](stow/README.md): layers, where a new file goes, git identity, iTerm2's profile and `st`, `home-audit`, `df-deploy`.
- [`homebrew/`](homebrew/README.md): which package manager and Brewfile a package belongs in.
- [`seed/`](seed/README.md) and [`editors/`](editors/README.md): copied-once app config and shared editor settings.
- [`tests/`](tests/README.md): what each suite covers and how tests are written.

## Installer reference

`install.sh --help` lists the supported options:

- `-n`, `--dry-run`: report changes without modifying the system.
- `-v`, `--verbose`: stream command output instead of collecting it into boxes.
- `-d`, `--debug`: enable verbose output and shell command tracing.
- `-h`, `--help`: show usage and exit.
- `--persona NAME`: set the machine up as a persona from `personas/` (`home`, `work`, `server`, `vps`) and save the choice.
- `--skip-system`: skip OS bootstrap.
- `--skip-brew`: skip Homebrew installation, updates, and bundles.
- `--skip-shell`: skip adding zsh to `/etc/shells` and running `chsh`.

Unrecognized arguments and everything after `--` are passed to `stow` through `scripts/link.sh`:

```bash
~/.dotfiles/install.sh --skip-brew -- --verbose=2
```

## Personas

- A persona (`personas/<name>`, plain `key=value` lines that are parsed, never sourced) says what a machine gets: `os` (allowed platforms), `layers`, `agents` (the private agents checkout), `agent_apps` (which apps get its links: `claude` for `~/.claude`, `cursor` for `~/.cursor`, `codex` for `~/.codex`; `home` and `server` use Claude Code and Codex, `work` adds Cursor, and switching removes the links of any app the new persona drops; left out, every app; each app keeps its own settings, which the repo never touches), `skills` (skill bundles from the agents checkout linked into `~/.agents/skills`; `core` when left out), `editors` (shared editor settings), `brew` (Brewfiles installed in full), `brew_optional` (Brewfiles offered in the macOS picker), and `setup` (setup scripts offered at the end of the install: a name is `scripts/bootstrap/<os>/<name>.sh` or `scripts/bootstrap/<name>.sh`, such as `docker`, `tailscale`, `claude-code`). `install.sh` passes the lists to `homebrew/brew.sh` as `DOTFILES_BREWFILES` and `DOTFILES_BREW_OPTIONAL` (run on its own, brew.sh installs core plus the macOS picker) and keeps `setup` for its own last step, which asks on a terminal and otherwise names the scripts to run later. A persona with no Brewfiles skips the Homebrew step. Hardening (`harden`, which runs `scripts/bootstrap/linux/harden.sh` through sudo for the user) is one of those setup scripts, offered by `vps` only, and never runs unasked: on a server already in use it would close every port but the tailnet's and allow only one SSH user. The persona comes from `--persona`, then `DOTFILES_PERSONA`, then `~/.local/state/dotfiles/persona`, then the OS default (`home` on macOS, `server` on Linux), which warns until one is chosen. Without `--persona` or `DOTFILES_PERSONA`, `install.sh` asks on a terminal every run, with the saved choice preselected; closed stdin keeps the saved choice or the default, and dry runs never save. A real apply with `--persona` or `DOTFILES_PERSONA` saves it.

## Installation behavior

- Changes to managed paths must preserve existing user data. `scripts/link.sh` replaces a real file only when it matches the repo and otherwise moves it to `~/.local/state/dotfiles/clobbered/<timestamp>/` first; keep that behavior and cover transitions in `tests/link.bats`.
- Bootstrap must work before the managed shell configuration and Homebrew tools are available. Establish prerequisites before use; do not rely on the developer's current PATH, aliases, or installed utilities.
- Keep repeated installs safe: avoid duplicate configuration entries, needless reinstalls, or overwriting local overrides. For changes to installation state, check both a fresh setup and an already-configured setup.
- Preserve `install.sh`'s dry-run and skip flags and argument forwarding to stow. Dry-run must not install packages, change the login shell, or write destination files.
- A closed stdin or absent TTY must not hang bootstrap or accidentally opt into optional installs. Exercise EOF explicitly when changing prompts; account for `set -e` when `read` fails.
- Shared paths must work on macOS and Debian/Ubuntu. Check BSD/GNU utility differences and the shell available at the affected install stage before adding flags or shell features. Keep OS-specific operations in their platform branch.
- Reuse `scripts/common.sh` for logging, privilege handling, and command presentation. Required command failures must remain failures through wrappers and pipelines, with useful diagnostics.

## Verification

- For shell behavior, bootstrap, package-list, or runtime configuration changes, run `./tests/run_tests.sh` from the repository root. It runs ShellCheck and Bats and may install missing test dependencies through Homebrew.
- Add behavioral regression coverage for bug fixes and meaningful new behavior in the relevant existing Bats suite. Assert exit status, resulting files, or external command calls; checking source text alone does not establish runtime correctness.
- For changes that affect a fresh install, run `./tests/sandbox-install.sh` once the changes are committed and a Docker daemon is available. It archives `HEAD`, so it cannot verify uncommitted edits. Do not create a commit solely to run it without a commit request; report that validation as pending.
- The container check covers a bare Debian install with closed stdin, but skips Homebrew and login-shell changes. CI runs on macOS. Report these limits when relevant rather than treating either check as full cross-platform coverage.
- For documentation-only changes, check the diff, referenced paths, and commands; no runtime suite is required. Report checks actually run, failures, and relevant gaps when handing off any change.

## Keeping the workflow accurate

- Keep `README.md` focused on installation and discovery. Document a directory in its own `README.md`, and keep only repo-wide rules here. Never add a file under `personas/`: every file there is read as a persona. Update the corresponding guidance when behavior changes.
- Keep CI and local validation aligned through `tests/run_tests.sh`. If test discovery or lint coverage changes, verify that the intended files and tests actually run.
- Commit policy (straight to `main`, short subjects), how this repo stays consistent with the private agents checkout, and the notes outside the repo that must change with it are in `~/.config/agents/MAINTENANCE.md`, when that checkout is present.

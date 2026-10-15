# Dotfiles change quality

These rules apply throughout this repository. Before changing a directory, read its `README.md`: it says how that part works, and its rules apply there too.

- [`scripts/`](scripts/README.md): `link.sh`, the `df-*` wrappers, `brew-add.sh`, and the file review and cleanup.
- [`roles/`](roles/README.md): what a machine is for (a Pi-hole), chosen in the install and applied last with the optional installs (Docker, Tailscale, Claude Code), which every persona gets on by default.
- [`scripts/bootstrap/`](scripts/bootstrap/README.md): OS bootstrap, optional Linux installs, `iterm2.sh`, and `harden.sh` with its check `harden-test.sh` for servers.
- [`stow/`](stow/README.md): layers, where a new file goes, git identity, iTerm2's profile and `st`, `home-audit`, `df-deploy`.
- [`homebrew/`](homebrew/README.md): which package manager and Brewfile a package belongs in.
- [`seed/`](seed/README.md) and [`editors/`](editors/README.md): copied-once app config and shared editor settings.
- [`tests/`](tests/README.md): what each suite covers and how tests are written.

## Installer reference

`install.sh --help` lists the supported options:

- `-n`, `--dry-run`: report changes without modifying the system, including what the OS bootstrap and Homebrew would install.
- `-v`, `--verbose`: stream command output instead of collecting it into boxes.
- `-d`, `--debug`: enable verbose output and shell command tracing.
- `-h`, `--help`: show usage and exit.
- `--persona NAME`: set the machine up as a persona from `personas/` (`home`, `work`, `server`, `vps`) and save the choice.
- `--install NAME`, `--no-install NAME`: add or drop an install: one of the optional installs every persona gets (`docker`, `tailscale`, `holeberry`, `claude-code`, on by default) or a role the persona offers (`roles/`); `DOTFILES_INSTALLS="a b"` sets the whole list. Saved like the persona.
- `--reconfigure`: ask the persona and install questions again.
- `--skip-system`: skip OS bootstrap.
- `--skip-brew`: skip Homebrew installation, updates, and bundles.
- `--skip-shell`: skip adding zsh to `/etc/shells` and running `chsh`.

Unrecognized arguments and everything after `--` are passed to `stow` through `scripts/link.sh`:

```bash
~/.dotfiles/install.sh --skip-brew -- --verbose=2
```

## Personas

- A persona (`personas/<name>`, plain `key=value` lines that are parsed, never sourced) says what a machine gets: `os` (allowed platforms), `layers`, `agents` (the private agents checkout), `agent_apps` (which apps get its links: `claude` for `~/.claude`, `cursor` for `~/.cursor`, `codex` for `~/.codex`; `home` and `server` use Claude Code and Codex, `work` adds Cursor, and switching removes the links of any app the new persona drops; left out, every app; each app keeps its own settings, which the repo never touches), `skills` (skill bundles from the agents checkout linked into `~/.agents/skills`; `core` when left out), `editors` (shared editor settings), `brew` (Brewfiles installed in full), `brew_optional` (Brewfiles offered in the macOS picker), `roles` (roles on by default), `roles_optional` (roles offered), and `harden` (`yes` on `server` and `vps`: on Linux, `install.sh` offers `scripts/bootstrap/linux/harden.sh` first when `harden-test.sh` finds the box unhardened). The optional installs are not listed per persona: a setup script `scripts/bootstrap/<os>/<name>.sh` or `scripts/bootstrap/<name>.sh` with a `# detect: COMMAND` line is offered to every persona, on by default (today `docker` and `tailscale` on Linux, `holeberry` on macOS, `claude-code` on both OSes). `install.sh` passes the lists to `homebrew/brew.sh` as `DOTFILES_BREWFILES` and `DOTFILES_BREW_OPTIONAL` (run on its own, brew.sh installs core plus the macOS picker). A persona with no Brewfiles skips the Homebrew step. The persona comes from `--persona`, then `DOTFILES_PERSONA`, then `~/.local/state/dotfiles/persona`, then the OS default (`home` on macOS, `server` on Linux), which warns until one is chosen. Without `--persona` or `DOTFILES_PERSONA`, `install.sh` asks on a terminal until a choice is saved, and again with `--reconfigure`; closed stdin keeps the saved choice or the default, and dry runs never save. A real apply with `--persona` or `DOTFILES_PERSONA` saves it.
- Every question is asked up front, before anything changes: the persona, then the installs (the optional installs, preselected, and the persona's roles, `roles=` preselected and `roles_optional=` offered; see [`roles/README.md`](roles/README.md) for the role files, the detect line, the saved choice, `--install`, `--no-install`, and `DOTFILES_INSTALLS`), then on macOS the optional Homebrew packages (`brew.sh --pending` lists them, `DOTFILES_BREW_PICKS` carries the answer, so `brew.sh` asks nothing inside an install). The header then states the persona, installs, and skipped steps before the first step runs, and one `sudo -v` up front covers the steps that need it. Installs are applied last, in `requires` order, each skipped when its `detect` command already succeeds; the command-line optional installs (Docker, Tailscale, Claude Code) detect through `tool_installed` in `scripts/common.sh`, which checks PATH, `~/.local/bin`, and Homebrew's bin, so a tool that came through either manager is not installed again the other way. Hardening is a question too, asked before the Homebrew one and run as the first step, before anything is installed: on Linux, a persona with `harden=yes` runs `scripts/bootstrap/linux/harden-test.sh --brief` and, when it lists gaps, offers `harden.sh` (through sudo for the user; `HARDEN_ARGS` adds its options), defaulting to no; `--harden` runs it outright and `--no-harden` skips the question. It never runs unasked and closed stdin never opts in: on a server already in use it would close every port but the tailnet's and allow only one SSH user. A declined or skipped offer leaves the gaps in the header and a next step. `bootstrap.sh` is the entry point for a machine without the repo (curl-able, installs git, clones, as root creates the admin user through `harden.sh --user`, then runs `install.sh`); keep it free of anything else in the repo.

## Installation behavior

- Changes to managed paths must preserve existing user data. `scripts/link.sh` replaces a real file only when it matches the repo and otherwise moves it to `~/.local/state/dotfiles/clobbered/<timestamp>/` first; keep that behavior and cover transitions in `tests/link.bats`.
- Bootstrap must work before the managed shell configuration and Homebrew tools are available. Establish prerequisites before use; do not rely on the developer's current PATH, aliases, or installed utilities.
- Keep repeated installs safe: avoid duplicate configuration entries, needless reinstalls, or overwriting local overrides. For changes to installation state, check both a fresh setup and an already-configured setup.
- Preserve `install.sh`'s dry-run and skip flags and argument forwarding to stow. Dry-run must not install packages, change the login shell, or write destination files.
- A closed stdin or absent TTY must not hang bootstrap or accidentally opt into optional installs. Exercise EOF explicitly when changing prompts; account for `set -e` when `read` fails. Prompts belong in the preflight of `install.sh` (through `choose_one` and `choose_many` in `scripts/common.sh`), not inside a step; a step that must wait for something polls with a timeout (the macOS CLT installer) rather than reading a key.
- Shared paths must work on macOS and Debian/Ubuntu. Check BSD/GNU utility differences and the shell available at the affected install stage before adding flags or shell features. Keep OS-specific operations in their platform branch.
- Reuse `scripts/common.sh` for logging, privilege handling, and command presentation. Required command failures must remain failures through wrappers and pipelines, with useful diagnostics.

## Verification

- For shell behavior, bootstrap, package-list, or runtime configuration changes, run `./tests/run_tests.sh` from the repository root. It runs ShellCheck and Bats and may install missing test dependencies through Homebrew.
- Add behavioral regression coverage for bug fixes and meaningful new behavior in the relevant existing Bats suite. Assert exit status, resulting files, or external command calls; checking source text alone does not establish runtime correctness.
- For changes that affect a fresh install, run `./tests/sandbox-install.sh` once the changes are committed and a Docker daemon is available. It archives `HEAD`, so it cannot verify uncommitted edits. Do not create a commit solely to run it without a commit request; report that validation as pending.
- The container check covers a bare Debian install with closed stdin, but skips Homebrew and login-shell changes. CI runs on macOS. Report these limits when relevant rather than treating either check as full cross-platform coverage.
- For documentation-only changes, check the diff, referenced paths, and commands; no runtime suite is required. Report checks actually run, failures, and relevant gaps when handing off any change.

## Keeping the workflow accurate

- Keep `README.md` focused on installation and discovery. Document a directory in its own `README.md`, and keep only repo-wide rules here. Never add a file under `personas/` or `roles/` except `roles/README.md`: every other file there is read as a persona or a role. Update the corresponding guidance when behavior changes.
- Keep CI and local validation aligned through `tests/run_tests.sh`: CI runs it in full on every push, and the pre-push hook runs its `--lint-only` half plus the container install. If test discovery or lint coverage changes, verify that the intended files and tests actually run.
- Commit policy (straight to `main`, short subjects), how this repo stays consistent with the private agents checkout, and the notes outside the repo that must change with it are in `~/.config/agents/MAINTENANCE.md`, when that checkout is present.

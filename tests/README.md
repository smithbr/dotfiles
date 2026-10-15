# Tests

This directory contains the shell test suite for the dotfiles repo.

## Runner

Run the full suite with:

```bash
./tests/run_tests.sh
```

The runner uses Homebrew-installed `bats-core`, `bats-support`, and `bats-assert`. If they are missing, [`run_tests.sh`](run_tests.sh) installs them first.
It also ensures `shellcheck` and `stow` are installed, then lints the repo's shell scripts before running Bats.

## Git Hooks

This repo can use the versioned hooks in [`.githooks`](../.githooks):

- `pre-commit` runs `~/.config/agents/scripts/check-drift` (retired terms, and `AGENT_LINKS` against the
  agents repo); it skips with a note when the agents checkout is missing
- `pre-push` runs ShellCheck (`run_tests.sh --lint-only`), then a container
  install via [`sandbox-install.sh`](sandbox-install.sh); CI runs the full suite
  on every push

To enable them locally:

```bash
git config core.hooksPath .githooks
chmod +x .githooks/pre-commit .githooks/pre-push
```

## Sandbox Install

[`sandbox-install.sh`](sandbox-install.sh) runs `install.sh` inside a throwaway Debian
container. It is the only check that sees a genuinely bare machine: no `git`,
no `curl`, no `zsh`, and stdin closed. The Bats suite mocks all of that away, so
regressions in the non-interactive bootstrap path are invisible to it.

It needs a container runtime. On macOS:

```bash
brew install colima docker && colima start
```

Run it directly with:

```bash
./tests/sandbox-install.sh
```

Notes:

- It tests `HEAD`, not the working tree, so commit before running it.
- Homebrew and `chsh` are skipped: Linux aarch64 has no brew bottles, and `chsh`
  needs a password the container user does not have.
- `pre-push` only runs it when the pushed commits touch `install.sh`, `scripts/`,
  `stow/`, `seed/`, `editors/`, `homebrew/`, or the script itself. Set `SKIP_SANDBOX_INSTALL=1` to bypass it, and it
  skips itself when `docker` is absent.

## Isolation Model

The suite uses Bats plus temporary directories, overridden `HOME`, overridden `PATH`, and stub executables to keep tests isolated.

- Unit-style tests exercise parsing, guard clauses, and helper behavior in-process.
- Integration-style tests run the real scripts with sandboxed `HOME` and mocked commands so actions stay inside temporary test directories instead of your live home directory.

This is process-level isolation, not a real container or VM.

## Test Files

[`bootstrap.bats`](bootstrap.bats)

- Validates `scripts/bootstrap/linux/apt-packages.txt`
- Verifies Linux bootstrap guard clauses for missing `apt-get`
- Runs `docker.sh` and `tailscale.sh` to verify they skip a tool on PATH or in Homebrew's bin, and `claude-code.sh` to verify the native installer runs only when Claude Code is in neither place
- Dry-runs `harden.sh` against a scratch root (`HARDEN_ROOT`) with mocked system tools: required arguments, closing public SSH only once Tailscale is connected, Cloudflare-only ports, and stopping before user or SSH changes when there is no key to copy
- Verifies the macOS iTerm2 step enables the Python API, makes the repo profile the default, adds the Catppuccin color presets (rewriting a stale one, keeping the user's own), and rewrites nothing on a second run
- Verifies that `harden.sh` re-runs itself through sudo for the user who ran it
- Checks shell script shebangs, strict mode, `common.sh` sourcing, and `BASEDIR` conventions

[`harden_test.bats`](harden_test.bats)

- Runs `scripts/bootstrap/linux/harden-test.sh` against a scratch root (`HARDEN_ROOT`) with mocked `sshd`, `ufw`, `tailscale`, `docker`, `systemctl`, `apt-get`, and `getent`: a hardened box passes with its open ports listed, a fresh box fails with the config files read the way sshd does (`sshd_config.d/` first, first value wins) and the checks that need root skipped, `--brief` prints only the failures, a locked-out or root admin user fails, public SSH is judged against Tailscale, Docker ports published to all interfaces, pending upgrades, and a needed reboot warn, and bad arguments are rejected

[`bin_scripts.bats`](bin_scripts.bats)

- Covers scripts in [`stow/tools/.local/bin`](../stow/tools/.local/bin), [`stow/personal/.local/bin`](../stow/personal/.local/bin), and [`stow/server.linux/.local/bin`](../stow/server.linux/.local/bin)
- Runs `st` (in `stow/desktop.darwin/.local/bin`) under plain Python: team listing and dry runs, a team without agents as one tab, the missing-teams-file hint, every team in the tracked `teams.toml.example`, a directory or the current directory as a one-tab team, a team winning over a same-named directory, and each tab running its command as the tab's program
- Verifies help output, startup probing, and the Unbound rows for `ph-padd`
- Runs `cf-cert` against a mocked acme.sh: argument checks, issue-only runs, the combined-pem install and chained reload command, stopping on a failed issue, a missing token on closed stdin, and `--pihole` refusing to run without root
- Verifies non-root self-elevation behavior for `ph-update`, `ph-test`, and `ph-backup`
- Runs `ph-backup` against mocked Pi-hole, Unbound, and Tailscale and inspects the resulting tar.gz
- Runs `os-update` and `ph-sec-audit` against mocked system tools
- Runs `ts-test` in a fully mocked sandbox
- Runs `sshkey` help, local key creation, and cleanup flows inside an isolated home directory
- Runs `df-link` and `df-file-review` through a stow-style link into a fake repo: arguments pass through, `df-file-review` defaults to `--cleanup`, and a wrapper outside a repo fails clearly
- Runs `df-deploy` with a stub `ssh` that runs the remote command against a scratch clone: pull and relink, every named or `DF_DEPLOY_HOSTS` host, a non-fast-forward pull failing that host before linking, dry runs, a missing host, and the unpushed-commit warning

[`brew_add.bats`](brew_add.bats)

- Runs `scripts/brew-add.sh` in a fake repo with scratch Brewfiles and a stub `brew`: sorted insertion into the chosen section with formulae before casks, cask detection and the formula preference, a Brewfile with one section or none, skipping names already listed (tap-qualified too), no entry after a failed install, skipping an installed package, dry runs, closed stdin needing `--file` and `--section`, and rejected names, files, and sections
- Runs `df-add` through a stow-style link: `brew` reaches `brew-add.sh`, `stow` becomes `link.sh add` with every argument, and a missing or unknown kind fails

[`brew.bats`](brew.bats)

- Checks `homebrew/Brewfile.core` for valid lines, duplicates, and casks kept to macOS
- Runs [`homebrew/brew.sh`](../homebrew/brew.sh) against a mocked brew: bundling without upgrades, skipping an installed Brewfile, `--verbose`, trusting tap-qualified entries, the macOS picker over pending entries, and the persona's Brewfile selection (`DOTFILES_BREWFILES`, `DOTFILES_BREW_OPTIONAL`) with failure on a missing one

[`common.bats`](common.bats)

- Tests logging helpers in [`scripts/common.sh`](../scripts/common.sh)
- Verifies `gum` and non-`gum` behavior
- Tests `require_non_root`, `sudo_cmd`, `spin`, and `tool_installed` (a tool on PATH, in `~/.local/bin`, or under `HOMEBREW_PREFIX`, with Homebrew's usual prefixes as the fallback)

[`file_review.bats`](file_review.bats)

- Exercises file inventory against a fixture repo, replaced links, broken managed links, and migration backup reporting
- Explains a `~/.gitconfig` `[user]` that overrides `config.local`
- Keeps a local file out of the review when the repo manages its `.example` (`teams.toml` beside `teams.toml.example`)
- Verifies bulk archival preserves contents and symlinks, excludes protected paths, and is safe to repeat
- Checks closed stdin, invalid selections, a failed inventory query, alternate destinations, and installer report integration
- Verifies home dotfiles are grouped by `home-audit` verdict and the picker lists them in that order with their reasons

[`home_audit.bats`](home_audit.bats)

- Runs `home-audit` against a sandboxed home, a fixture xdg-ninja database, and a fixture dotfiles repo
- Verifies JUNK/LEFTOVER/MOVE/REVIEW/KEEP classification, environment-redirect detection, and `--days`/`--all`
- Checks that the audited home is left untouched and that missing data sources are reported, including a machine with no xdg-ninja at all
- Verifies last-change ages in notes, the 1Password agent link and folder-to-command aliases, and `--tsv` output

[`link.bats`](link.bats)

- Runs the real [`scripts/link.sh`](../scripts/link.sh) and GNU Stow against a scratch home and a local agents repo fixture
- Verifies linking per platform, shared editor settings, backups of changed copies and foreign links, removal of stale repo links (files that moved, were deleted, or belong to an unused package) while real files and foreign links stay, persona choice (flag, environment, saved state, OS default, unknown or wrong-OS names), personas without agents or editors, idempotency, and dry runs
- Covers agent links (clone, backup of real agent config, unreachable repo), seed files (the gh login only for personas with the `personal` layer), the `managed` and `status` reports, and the git identity: only `personal` sets `user.email`, `config.local` overrides it, and a missing email or a `[user]` in `~/.gitconfig` is warned about and reported; `status` names real files a layer the persona does not link would own (not shared parents or the empty folders a persona switch leaves) and never moves them
- Runs `add` against a fixture repo: a file becomes a link with no backup and keeps its executable bit; directories, `--platform`, relative paths, `--seed`, dry runs; refusals of secrets, private keys, `.local` overrides, agent and editor paths, repo files, outside paths, symlinks, banned words (without naming them), a layer the persona does not link, and a missing layer on closed stdin

[`install.bats`](install.bats)

- Tests `install.sh` argument parsing, including `--persona`, the persona picker (number, name, empty answer, EOF), rejecting an unknown persona before any change, and the closing setup step (offered on a terminal, named otherwise, a failing script reported)
- Verifies SSH key helper behavior
- Tests error handling when `HOME` is unset
- Runs an isolated integration test for [`install.sh`](../install.sh) with sandboxed home and mocked external commands

[`zsh.bats`](zsh.bats)

- Checks the zsh startup files for the XDG layout and the Homebrew bootstrap, runs the nvm block with and without nvm installed, and runs the `na` alias helper
- Runs the bash startup files with a scratch home and checks the history path

[`test_helper.bash`](test_helper.bash)

- Shared Bats setup helpers
- Sets `PROJECT_ROOT`
- Creates and cleans temporary directories for each test

[`run_tests.sh`](run_tests.sh)

- Bootstraps Bats dependencies from Homebrew
- Exports `BATS_LIB_PATH`
- Runs all `*.bats` files in this directory, or only ShellCheck with `--lint-only`

## Writing tests

- Use the temporary-directory helpers in `tests/test_helper.bash` and isolate destination paths and external commands. Tests must not install software, change services, or modify the real home directory as part of exercising the code under test.
- The ShellCheck runner selects tracked shell files and managed bin scripts. Explicitly lint newly created, untracked shell files and changed shell entrypoints outside that selection, such as `.githooks/pre-push`; a passing runner does not cover them automatically.

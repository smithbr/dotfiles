# Tests

This directory contains the shell test suite for the dotfiles repo.

## Runner

Run the full suite with:

```bash
./tests/run_tests.sh
```

The runner uses Homebrew-installed `bats-core`, `bats-support`, and `bats-assert`. If they are missing, [`run_tests.sh`](/Users/bran/.dotfiles/tests/run_tests.sh) installs them first.
It also ensures `shellcheck` and `stow` are installed, then lints the repo's shell scripts before running Bats.

## Git Hooks

This repo can use the versioned hooks in [`.githooks`](/Users/bran/.dotfiles/.githooks):

- `pre-commit` runs `~/.config/agents/scripts/check-drift` (retired terms, and `AGENT_LINKS` against the
  agents repo); it skips with a note when the agents checkout is missing
- `pre-push` runs the full test suite via [`run_tests.sh`](/Users/bran/.dotfiles/tests/run_tests.sh), then a
  container install via [`sandbox-install.sh`](/Users/bran/.dotfiles/tests/sandbox-install.sh)

To enable them locally:

```bash
git config core.hooksPath .githooks
chmod +x .githooks/pre-commit .githooks/pre-push
```

## Sandbox Install

[`sandbox-install.sh`](/Users/bran/.dotfiles/tests/sandbox-install.sh) runs `install.sh` inside a throwaway Debian
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
  `stow/`, `seed/`, `editors/`, or `homebrew/`. Set `SKIP_SANDBOX_INSTALL=1` to bypass it, and it
  skips itself when `docker` is absent.

## Isolation Model

The suite uses Bats plus temporary directories, overridden `HOME`, overridden `PATH`, and stub executables to keep tests isolated.

- Unit-style tests exercise parsing, guard clauses, and helper behavior in-process.
- Integration-style tests run the real scripts with sandboxed `HOME` and mocked commands so actions stay inside temporary test directories instead of your live home directory.

This is process-level isolation, not a real container or VM.

## Test Files

[`bootstrap.bats`](/Users/bran/.dotfiles/tests/bootstrap.bats)

- Validates `scripts/bootstrap/linux/apt-packages.txt`
- Verifies Linux bootstrap guard clauses for missing `apt-get`
- Verifies idempotency guards for `docker` and `tailscale`
- Verifies that the Linux optional installs follow the persona (`DOTFILES_LINUX_OPTIONAL`), including Claude Code through the shared `scripts/bootstrap/claude-code.sh`, and keep Docker and Tailscale when run on their own
- Checks shell script shebangs, strict mode, `common.sh` sourcing, and `BASEDIR` conventions

[`bin_scripts.bats`](/Users/bran/.dotfiles/tests/bin_scripts.bats)

- Covers scripts in [`stow/tools/.local/bin`](/Users/bran/.dotfiles/stow/tools/.local/bin) and [`stow/server.linux/.local/bin`](/Users/bran/.dotfiles/stow/server.linux/.local/bin)
- Verifies help output and startup probing for `ph-padd`
- Verifies non-root self-elevation behavior for `ph-update`, `ph-test`, and `ph-backup`
- Runs `ph-backup` against mocked Pi-hole, Unbound, and Tailscale and inspects the resulting zip
- Runs `ts-test` in a fully mocked sandbox
- Runs `sshkey` help, local key creation, and cleanup flows inside an isolated home directory
- Runs `ph-agent-setup` steps with mocked identity, sudo, git, crontab, `ob`, and `claude`: wrong-user and off-Linux refusals; `authorize` writing one comment-free fetch-only key line and rejecting multi-line, CR, non-ed25519, and unreadable keys; `user` copying only option-less keys into a root-owned key file and installing the script and wrappers root-owned; one cron entry pointing at `/usr/local/bin`; an empty-inbox import that never starts Claude; an import that refuses to start without the root-owned helpers; a Claude allowlist that scopes Write/Edit to the vault, denies `~/.local`, `~/.ssh`, `~/.claude`, `~/.config`, and the tools checkout, and has no `find`, `cp`, or `mv`; and `mv` (vault-mv) refusing links, overwrites, and destinations outside the vault or in `.claude/`

[`brew.bats`](/Users/bran/.dotfiles/tests/brew.bats)

- Verifies Brewfile entry parsing
- Tests `entry_is_brew_managed` behavior for formulas, casks, and taps
- Verifies Linux cask filtering and OS detection logic
- Checks `homebrew/Brewfile.core` for valid entry types and duplicates
- Verifies Brewfile selection from the persona (`DOTFILES_BREWFILES`, `DOTFILES_BREW_OPTIONAL`), the standalone defaults, and failure on a missing Brewfile
- Runs an isolated integration test for [`homebrew/brew.sh`](/Users/bran/.dotfiles/homebrew/brew.sh) against a fake Homebrew environment

[`common.bats`](/Users/bran/.dotfiles/tests/common.bats)

- Tests logging helpers in [`scripts/common.sh`](/Users/bran/.dotfiles/scripts/common.sh)
- Verifies `gum` and non-`gum` behavior
- Tests `require_non_root`, `sudo_cmd`, and `spin`

[`file_review.bats`](/Users/bran/.dotfiles/tests/file_review.bats)

- Exercises file inventory against a fixture repo, replaced links, broken managed links, and migration backup reporting
- Verifies bulk archival preserves contents and symlinks, excludes protected paths, and is safe to repeat
- Checks closed stdin, invalid selections, a failed inventory query, alternate destinations, and installer report integration

[`home_audit.bats`](/Users/bran/.dotfiles/tests/home_audit.bats)

- Runs `home-audit` against a sandboxed home, a fixture xdg-ninja database, and a fixture dotfiles repo
- Verifies JUNK/LEFTOVER/MOVE/REVIEW/KEEP classification, environment-redirect detection, and `--days`/`--all`
- Checks that the audited home is left untouched and that missing data sources are reported, including a machine with no xdg-ninja at all

[`link.bats`](/Users/bran/.dotfiles/tests/link.bats)

- Runs the real [`scripts/link.sh`](/Users/bran/.dotfiles/scripts/link.sh) and GNU Stow against a scratch home and a local agents repo fixture
- Verifies linking per platform, shared editor settings, backups of changed copies and foreign links, removal of stale repo links (files that moved, were deleted, or belong to an unused package) while real files and foreign links stay, persona choice (flag, environment, saved state, OS default, unknown or wrong-OS names), personas without agents or editors, idempotency, and dry runs
- Covers agent links (clone, backup of real agent config, unreachable repo), seed files, and the `managed` and `status` reports

[`install.bats`](/Users/bran/.dotfiles/tests/install.bats)

- Tests `install.sh` argument parsing, including `--persona`, the persona picker (number, name, empty answer, EOF), and rejecting an unknown persona before any change
- Verifies SSH key helper behavior
- Tests error handling when `HOME` is unset
- Runs an isolated integration test for [`install.sh`](/Users/bran/.dotfiles/install.sh) with sandboxed home and mocked external commands

[`test_helper.bash`](/Users/bran/.dotfiles/tests/test_helper.bash)

- Shared Bats setup helpers
- Sets `PROJECT_ROOT`
- Creates and cleans temporary directories for each test

[`run_tests.sh`](/Users/bran/.dotfiles/tests/run_tests.sh)

- Bootstraps Bats dependencies from Homebrew
- Exports `BATS_LIB_PATH`
- Runs all `*.bats` files in this directory

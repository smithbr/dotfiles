# Tests

This directory contains the shell test suite for the dotfiles repo.

## Runner

Run the full suite with:

```bash
./tests/run_tests.sh
```

The runner uses Homebrew-installed `bats-core`, `bats-support`, and `bats-assert`. If they are missing, [`run_tests.sh`](/Users/bran/.dotfiles/tests/run_tests.sh) installs them first.
It also ensures `shellcheck` is installed, then lints the repo's shell scripts before running Bats.

## Git Hooks

This repo can use the versioned hooks in [`.githooks`](/Users/bran/.dotfiles/.githooks):

- `pre-push` runs the full test suite via [`run_tests.sh`](/Users/bran/.dotfiles/tests/run_tests.sh)

To enable them locally:

```bash
git config core.hooksPath .githooks
chmod +x .githooks/pre-push
```

## Isolation Model

The suite uses Bats plus temporary directories, overridden `HOME`, overridden `PATH`, and stub executables to keep tests isolated.

- Unit-style tests exercise parsing, guard clauses, and helper behavior in-process.
- Integration-style tests run the real scripts with sandboxed `HOME` and mocked commands so actions stay inside temporary test directories instead of your live home directory.

This is process-level isolation, not a real container or VM.

## Test Files

[`bootstrap.bats`](/Users/bran/.dotfiles/tests/bootstrap.bats)

- Validates `scripts/bootstrap/linux/apt-packages.txt`
- Verifies Linux bootstrap guard clauses for missing `apt-get`
- Verifies idempotency guards for `docker`, `tailscale`, and `opencode`
- Checks shell script shebangs, strict mode, `common.sh` sourcing, and `BASEDIR` conventions

[`bin_scripts.bats`](/Users/bran/.dotfiles/tests/bin_scripts.bats)

- Covers scripts in [`dotfiles/dot_local/bin`](/Users/bran/.dotfiles/dotfiles/dot_local/bin)
- Verifies help output for `ph-padd` and `ph-padd-unbound`
- Verifies non-root self-elevation behavior for `ph-update` and `ph-test`
- Runs `ts-test` in a fully mocked sandbox
- Runs `sshkey` help, local key creation, and cleanup flows inside an isolated home directory

[`brew.bats`](/Users/bran/.dotfiles/tests/brew.bats)

- Verifies Brewfile entry parsing
- Tests `entry_is_brew_managed` behavior for formulas, casks, and taps
- Verifies Linux cask filtering and OS detection logic
- Checks `homebrew/Brewfile.core` for valid entry types and duplicates
- Runs an isolated integration test for [`homebrew/brew.sh`](/Users/bran/.dotfiles/homebrew/brew.sh) against a fake Homebrew environment

[`common.bats`](/Users/bran/.dotfiles/tests/common.bats)

- Tests logging helpers in [`scripts/common.sh`](/Users/bran/.dotfiles/scripts/common.sh)
- Verifies `gum` and non-`gum` behavior
- Tests `require_non_root`, `sudo_cmd`, and `spin`

[`install.bats`](/Users/bran/.dotfiles/tests/install.bats)

- Tests `install.sh` argument parsing
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

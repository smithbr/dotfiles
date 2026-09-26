# Dotfiles change quality

These rules apply throughout this repository.

## Installer reference

`install.sh --help` lists the supported options:

- `-n`, `--dry-run`: report changes without modifying the system.
- `-v`, `--verbose`: stream command output instead of collecting it into boxes.
- `-d`, `--debug`: enable verbose output and shell command tracing.
- `-h`, `--help`: show usage and exit.
- `--skip-system`: skip OS bootstrap.
- `--skip-brew`: skip Homebrew installation, updates, and bundles.
- `--skip-shell`: skip adding zsh to `/etc/shells` and running `chsh`.

Unrecognized arguments and everything after `--` are passed to `chezmoi apply`:

```bash
~/.dotfiles/install.sh --skip-brew -- --force --exclude=scripts
```

## Source and deployment boundaries

- `.chezmoiroot` selects `dotfiles/` as the managed source tree. Edit source files there rather than their deployed copies in the home directory. Repository tooling belongs outside that tree.
- Preserve chezmoi attributes (`dot_`, `private_`, `executable_`, `symlink_`, `create_`, and `.tmpl`) when moving or renaming entries; they affect destination paths, permissions, and update behavior.
- For template or platform-specific changes, inspect the rendered destination and the relevant conditions in `dotfiles/.chezmoiignore`. Keep shared editor configuration in `dotfiles/.chezmoitemplates/` rather than duplicating it in platform wrappers.
- Changes to managed paths must preserve existing user data. When replacing a real file or directory with a symlink, retain the backup behavior in `dotfiles/run_before_backup-agent-symlinks.sh` and cover the transition in `tests/agent_symlinks.bats`.

## Installation behavior

- Bootstrap must work before the managed shell configuration and Homebrew tools are available. Establish prerequisites before use; do not rely on the developer's current PATH, aliases, or installed utilities.
- Keep repeated installs safe: avoid duplicate configuration entries, needless reinstalls, or overwriting local overrides. For changes to installation state, check both a fresh setup and an already-configured setup.
- Preserve `install.sh`'s dry-run and skip flags and argument forwarding to chezmoi. Dry-run must not install packages, change the login shell, or write destination files.
- A closed stdin or absent TTY must not hang bootstrap or accidentally opt into optional installs. Exercise EOF explicitly when changing prompts; account for `set -e` when `read` fails.
- Shared paths must work on macOS and Debian/Ubuntu. Check BSD/GNU utility differences and the shell available at the affected install stage before adding flags or shell features. Keep OS-specific operations in their platform branch.
- Reuse `scripts/common.sh` for logging, privilege handling, and command presentation. Required command failures must remain failures through wrappers and pipelines, with useful diagnostics.

## Verification

- For shell behavior, bootstrap, package-list, or runtime configuration changes, run `./tests/run_tests.sh` from the repository root. It runs ShellCheck and Bats and may install missing test dependencies through Homebrew.
- Add behavioral regression coverage for bug fixes and meaningful new behavior in the relevant existing Bats suite. Assert exit status, resulting files, or external command calls; checking source text alone does not establish runtime correctness.
- Use the temporary-directory helpers in `tests/test_helper.bash` and isolate destination paths and external commands. Tests must not install software, change services, or modify the real home directory as part of exercising the code under test.
- The ShellCheck runner selects tracked shell files and managed bin scripts. Explicitly lint newly created, untracked shell files and changed shell entrypoints outside that selection, such as `.githooks/pre-push`; a passing runner does not cover them automatically.
- For changes that affect a fresh install, run `./tests/sandbox-install.sh` once the changes are committed and a Docker daemon is available. It archives `HEAD`, so it cannot verify uncommitted edits. Do not create a commit solely to run it without a commit request; report that validation as pending.
- The container check covers a bare Debian install with closed stdin, but skips Homebrew and login-shell changes. CI runs on macOS. Report these limits when relevant rather than treating either check as full cross-platform coverage.
- For documentation-only changes, check the diff, referenced paths, and commands; no runtime suite is required. Report checks actually run, failures, and relevant gaps when handing off any change.

## Keeping the workflow accurate

- Keep `README.md` focused on installation and discovery. Document installer details and maintenance rules here, and test-suite details in `tests/README.md`; update the corresponding guidance when behavior changes.
- Keep CI and local validation aligned through `tests/run_tests.sh`. If test discovery or lint coverage changes, verify that the intended files and tests actually run.

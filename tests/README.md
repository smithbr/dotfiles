# tests/

The Bats suite for the repo. Run it with `./tests/run_tests.sh`; the [root `AGENTS.md`](../AGENTS.md) says when to run which files.

## Runner

- `run_tests.sh` lints the repo's shell scripts with ShellCheck first, then runs Bats with `--jobs` set to the core count. `--lint-only` stops after the lint (named files limit it to those it would lint anyway) and touches neither the network nor the cache; `--no-lint` skips the lint and does not need `shellcheck`. Test files or directories named on the command line replace the default of every suite; other arguments go to Bats (`./tests/run_tests.sh tests/link.bats --filter add`).
- The suite's own tools live in `~/.cache/dotfiles/tests` (`XDG_CACHE_HOME` or `DOTFILES_TEST_DEPS` move it), which `deps.sh` fills on the first run: `bats-core`, `bats-support`, `bats-assert`, GNU `parallel`, a `python3` link to a uv-managed Python 3.11+ (without `uv`, the tests that need it skip), and on macOS a `bash` 5 built from source. Each download is checked against the sha256 pinned in `deps.sh`; a rerun with everything present is offline and silent; `rm -rf ~/.cache/dotfiles/tests` starts over. Nothing is installed through Homebrew for the tests. The machine's own `shellcheck` and `stow` are required, not installed (`Brewfile.core`, apt), and on Debian `bzip2`.
- Bats runs on the cache's bash through a `bash` shim first on `PATH` that sends only Bats' own programs there: `bash -c`, `run bash script`, and `#!/usr/bin/env bash` scripts under test still run on `/bin/bash`, as on a fresh Mac. Code a test sources in-process runs on the new bash. The cache's `python3` comes first on `PATH`, its `bats` and `parallel` last.
- Bumping a pin: set the version and the tarball's sha256 in `deps.sh` (cross-check with the GNU `.sig` or `brew info --json=v2 NAME`), then delete the cache directory. CI's cache key is the file's hash.
- CI ([`ci.yml`](../.github/workflows/ci.yml)) runs on every push as four parallel macOS jobs: one `--lint-only` and three `--no-lint` Bats shards: `link.bats`; `doctor.bats` with `install.bats`; and every other `*.bats` file by glob, so a new file runs there without a workflow change. Move a file between shards (and in `NAMED`) when one shard grows well past the others.

## Git hooks

The versioned hooks in [`.githooks`](../.githooks): `pre-commit` runs ShellCheck on the staged shell scripts (`run_tests.sh --lint-only FILE...`), then `~/.config/agents/scripts/check-drift`, skipped with a note when the agents checkout is missing. `pre-push` runs `run_tests.sh --lint-only`, then `sandbox-install.sh` when the pushed commits touch `install.sh`, `scripts/`, `stow/`, `seed/`, `editors/`, `homebrew/`, or the script itself; `SKIP_SANDBOX_INSTALL=1` bypasses it, and it skips itself without `docker`. Enable them with:

```bash
git config core.hooksPath .githooks
chmod +x .githooks/pre-commit .githooks/pre-push
```

## Sandbox install

`sandbox-install.sh` runs `install.sh` inside a throwaway Debian container: the only check that sees a bare machine, with no `git`, `curl`, or `zsh` and stdin closed. It needs a container runtime (`brew install colima docker && colima start` on macOS). It tests `HEAD`, not the working tree. A failed run prints the last 40 lines and keeps the full log at `~/.local/state/dotfiles/sandbox-install.log` (`SANDBOX_LOG` moves it). Homebrew and `chsh` are skipped: Linux aarch64 has no brew bottles, and `chsh` needs a password the container user does not have.

## What each file covers

Tests run against scratch homes, overridden `PATH`, and stub executables: process-level isolation, not a container. Each `.bats` file names its cases; this list says only what each is for.

- `ai_doctor.bats`: `ai-doctor` against fixture Claude Code, Codex, and Cursor config: every finding, `--fix`, and that nothing changes without it.
- `bin_scripts.bats`: the scripts in `stow/*/.local/bin` other than `ai-doctor` and `ph`, with their external commands mocked.
- `bootstrap.bats`: `apt-packages.txt`, the Linux and macOS bootstrap scripts, the optional installs, `pihole.sh` (`PIHOLE_ROOT`), `harden.sh` dry runs (`HARDEN_ROOT`), `iterm2.sh`, `bootstrap.sh`, and script conventions (shebang, strict mode, `common.sh`).
- `brew_add.bats`: `brew-add.sh` and `df-add` against scratch Brewfiles and a stub `brew`.
- `brew.bats`: the Brewfiles' shape and `brew.sh` against a mocked brew.
- `common.bats`: the helpers in `scripts/common.sh`.
- `deps.bats`: `deps.sh` against a scratch cache with a stub `curl`, and `run_tests.sh`'s tool checks.
- `doctor.bats`: `doctor.sh` against a scratch home, a fixture repo, and fixture xdg-ninja data: every group, the list of changes, and what it never touches.
- `githooks.bats`: `pre-commit` and `sandbox-install.sh` against stubs.
- `harden_test.bats`: `harden-test.sh` against a scratch root (`HARDEN_ROOT`) with mocked system tools.
- `install.bats`: `install.sh`'s arguments, prompts, SSH key step, and an isolated integration run with mocked commands.
- `link.bats`: the real `link.sh` and GNU Stow against a scratch home: linking, stale links, backups, personas, agent links, seed files, `status`, `managed`, the installs, git identity, `add`, `rm`, and `mv`.
- `ph.bats`: `ph` against a mocked `curl` answering from fixtures.
- `repo_config.bats`: the shipped personas and roles, every tracked JSON, TOML, YAML, and `.itermcolors` file, the shell startup files, and the vimrc.
- `runner.bats`: the runner itself: a failing `[[ ]]` before a test's last line fails the test, and a script under test still runs on `/bin/bash`.
- `zsh.bats`: the zsh and bash startup files.
- `test_helper.bash`: shared setup: `PROJECT_ROOT`, a temporary directory per test, fixture personas.

## Writing tests

- Use the temporary-directory helpers in `test_helper.bash` and isolate destination paths and external commands. Tests must not install software, change services, or modify the real home directory.
- Run Bats through `run_tests.sh`, never plain `bats`: on macOS that runs on `/bin/bash` 3.2, where a failing `[[ ]]` or `(( ))` fails a test only as its last command, so a test can pass for the wrong reason; `runner.bats` fails there to flag it. Prefer bats-assert forms (`assert test -f ...`, `refute test -e ...`, `assert_equal`) for checks that name what failed.
- The ShellCheck runner selects tracked `*.sh` and `*.bash` files and `stow/*/.local/bin/*` scripts with a sh or bash shebang. Lint anything outside that selection by hand, such as `.githooks/pre-push`; a passing runner does not cover it.

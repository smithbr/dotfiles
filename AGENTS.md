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

Unrecognized arguments and everything after `--` are passed to `stow` through `scripts/link.sh`:

```bash
~/.dotfiles/install.sh --skip-brew -- --verbose=2
```

`scripts/link.sh` is the linking step on its own: `link.sh` links, `link.sh status` lists missing, replaced, foreign, and broken links, `link.sh managed` prints every path the repo owns, and `--dry-run`, `--refresh` (pull `~/.config/agents` now), and `--destination PATH` adjust a run. Stow's `--target` and `--dir` are rejected; use `--destination`.

## Source and deployment boundaries

- `stow/<package>/` mirrors the home directory under real file names; `common` always links, and `darwin` or `linux` links on that platform. Linking uses `--no-folding`, so directories in `~` stay real and only files are symlinks. Repository tooling belongs outside `stow/`.
- `seed/<package>/` holds files an application rewrites itself (Docker's and gh's config). They are copied once with mode 600 when missing and never overwritten; do not move them into `stow/`.
- Shared editor settings live once in `editors/`, and nowhere under `stow/`. `editor_dirs` in `scripts/link.sh` lists each editor's user directory per platform, and every file in the matching `editors/` directory is linked there with the same backup rules as stow packages. Add an editor or platform there, not as symlinks in `stow/`.
- Links into the private agents checkout (`~/.config/agents`) and the directories kept at mode 700 are listed in `AGENT_LINKS` and `PRIVATE_DIRS` in `scripts/link.sh`. Git keeps only the executable bit, so any other permission must be applied there.
- Changes to managed paths must preserve existing user data. `scripts/link.sh` replaces a real file only when it matches the repo and otherwise moves it to `~/.local/state/dotfiles/clobbered/<timestamp>/` first; keep that behavior and cover transitions in `tests/link.bats`.
- An application that saves by replacing its config file turns the link into a real file and silently detaches it from the repo. `link.sh status` and the file review report these as `replaced`.

## Installation behavior

- Bootstrap must work before the managed shell configuration and Homebrew tools are available. Establish prerequisites before use; do not rely on the developer's current PATH, aliases, or installed utilities.
- Keep repeated installs safe: avoid duplicate configuration entries, needless reinstalls, or overwriting local overrides. For changes to installation state, check both a fresh setup and an already-configured setup.
- Preserve `install.sh`'s dry-run and skip flags and argument forwarding to stow. Dry-run must not install packages, change the login shell, or write destination files.
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

## Existing files and cleanup

- Installation ends with a file review. It lists unmanaged dotfiles directly under the destination home, unmanaged neighbors of managed files, broken managed links, and saved migration backups. Unmanaged does not mean unused; credentials, private agent directories, managed paths, and expected local overrides are excluded from cleanup.
- Interactive installs offer one numbered selection (or `all`) to archive reviewed candidates. Enter skips cleanup. Closed stdin, non-interactive installs, and dry runs only report; they never archive. Failed inventory queries disable cleanup and report an incomplete review.
- Run `./scripts/file-review.sh --cleanup` to repeat the review and selection without reinstalling. Use `--source PATH` for another source tree and `--destination PATH` for another destination. Extra positional roots expand the recursive scan; `--all` shows normally hidden runtime state but does not select it for cleanup.
- `home-audit` (deployed to `~/.local/bin`) is the read-only triage view of top-level `~/.*` entries: JUNK, LEFTOVER (the environment already redirects the tool, or no installed owner and inactive past `--days`), MOVE (XDG-capable per xdg-ninja data), REVIEW, and KEEP (managed, required, in use, or not movable). It never changes files; archive decisions go through `file-review.sh --cleanup`.
- Cleanup moves selected paths into `~/.local/state/dotfiles/cleanup/<timestamp>.<suffix>/` with private permissions and original relative paths. It never permanently deletes them or follows symlinked parents. Restore needed files to their original paths after checking for conflicts. Existing migration backups are reported separately and are not cleanup candidates.

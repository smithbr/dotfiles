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
  agents repo); it skips with a note when the agents checkout is missing, and
  says when `check-drift` crashed (killed by a signal) rather than found drift
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
- A failed run prints the last 40 lines of the install and keeps the full log at
  `~/.local/state/dotfiles/sandbox-install.log` (`SANDBOX_LOG` moves it); read it
  there before running the install again.
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

[`ai_doctor.bats`](ai_doctor.bats)

- Runs `ai-doctor` (in `stow/tools/.local/bin`) against a scratch home with fixture Claude Code, Codex, and Cursor config, a fixture agents checkout with a logging `skills-add`, and a fixture persona; only `python3` is on PATH, so no real `claude` or `codex` runs
- Verifies the default output (a summary line, then only the numbered fixes and trims, or `Nothing to do.`) and `-v` (instruction sizes, skill sizes from names and descriptions only, folded lines too, experimental flags and a default agent)
- Verifies each finding and its `--fix --yes`: bundles beyond or missing from the persona's `skills=` (through `skills-add`), a broken skill link removed, Claude servers that can't start removed from `~/.claude.json` (user and project scope, other keys kept, the original backed up once), a missing folder reported rather than every file under it, a Cursor URL moved from `command` to `url` and the file made private while its token, never printed, stays a fix, a Codex table and its sub-tables removed (turned-off servers kept; needs Python 3.11), and a plugin both installed and synced removed with its cache while the claude.ai copy stays; servers waiting for sign-in are one trim and connector placeholders none
- Verifies `--fix` on closed stdin and answering no change nothing, `--help`, a bad `--app`, a home with no AI apps, the exit status, and that a run without `--fix` through its stow link changes nothing

[`bootstrap.bats`](bootstrap.bats)

- Validates `scripts/bootstrap/linux/apt-packages.txt`
- Verifies Linux bootstrap guard clauses for missing `apt-get`
- Runs `pihole.sh` against a scratch root (`PIHOLE_ROOT`) with mocked `apt-get`, `systemctl`, `sysctl`, `unbound-checkconf`, `dig`, `curl`, and `pihole-FTL`: a fresh install writes Unbound's Pi-hole config, disables the resolvconf hook, raises the receive buffer, restarts Unbound, seeds `pihole.toml` and runs the installer unattended; a rerun changes nothing but sets Pi-hole's upstreams and DNSSEC back; a rejected Unbound config stops before Pi-hole
- Runs `macos/holeberry.sh` with mocked `curl`, `hdiutil`, `codesign`, `spctl`, and `ditto` into a scratch `HOLEBERRY_APPS_DIR`: the release's DMG is installed and unmounted with its download removed, an installed copy is left alone, and an app from another team, one Gatekeeper rejects, or a release without a DMG stops with nothing installed
- Runs `docker.sh` and `tailscale.sh` to verify they skip a tool on PATH or in Homebrew's bin, and `claude-code.sh` to verify the native installer runs only when Claude Code is in neither place
- Dry-runs `harden.sh` against a scratch root (`HARDEN_ROOT`) with mocked system tools: required arguments, closing public SSH only once Tailscale is connected, Cloudflare-only ports, and stopping before user or SSH changes when there is no key to copy
- Verifies the macOS iTerm2 step enables the Python API, makes the repo profile the default, adds the Catppuccin color presets (rewriting a stale one, keeping the user's own), and rewrites nothing on a second run
- Verifies that `harden.sh` re-runs itself through sudo for the user who ran it
- Runs `bootstrap.sh` with logging `git`, `sudo`, `curl`, and `apt-get`: the clone and its rerun, `--help`, git installed through apt (and refused without sudo), and as root with `--user` the fetched `harden.sh`, then the clone and `install.sh` as that user
- Checks shell script shebangs, strict mode, `common.sh` sourcing, and `BASEDIR` conventions

[`harden_test.bats`](harden_test.bats)

- Runs `scripts/bootstrap/linux/harden-test.sh` against a scratch root (`HARDEN_ROOT`) with mocked `sshd`, `ufw`, `tailscale`, `docker`, `systemctl`, `apt-get`, and `getent`: a hardened box passes with its open ports listed, a fresh box fails with the config files read the way sshd does (`sshd_config.d/` first, first value wins) and the checks that need root skipped, `--brief` prints only the failures, a locked-out or root admin user fails, public SSH is judged against Tailscale, Docker ports published to all interfaces, pending upgrades, and a needed reboot warn, and bad arguments are rejected

[`bin_scripts.bats`](bin_scripts.bats)

- Covers scripts in [`stow/tools/.local/bin`](../stow/tools/.local/bin), [`stow/personal/.local/bin`](../stow/personal/.local/bin), and [`stow/pihole.linux/.local/bin`](../stow/pihole.linux/.local/bin)
- Runs `st` (in `stow/desktop.darwin/.local/bin`) under plain Python: team listing and dry runs, a team without agents as one tab, the missing-teams-file hint, every team in the tracked `teams.toml.example`, a directory or the current directory as a one-tab team, a team winning over a same-named directory, and each tab running its command as the tab's program
- Verifies help output, startup probing, and the Unbound rows for `ph-padd`
- Runs `cf-cert` against a mocked acme.sh: argument checks, issue-only runs, the combined-pem install and chained reload command, stopping on a failed issue, a missing token on closed stdin, `--pihole` refusing to run without root or without `pihole-FTL`, and as root pointing Pi-hole at the pem with a chown and restart on renewal; paths with spaces, `;`, and `$(...)` stay quoted when the saved reload command runs
- Verifies non-root self-elevation behavior for `ph-update`, `ph-test`, and `ph-backup`, and that `ph-update -r` does not restart after a failed update
- Runs `ph-backup` against mocked Pi-hole, Unbound, and Tailscale and inspects the resulting tar.gz
- Runs `os-doctor` and `ph-sec-audit` against mocked system tools
- Runs `ts-test` in a fully mocked sandbox
- Runs `sshkey` help, local key creation, and cleanup flows inside an isolated home directory; `delete` only once confirmed, `--dry-run` refused outside `cleanup` (it would skip the confirmation), the protected `id_rsa` never deleted, recreated, or touched by `cleanup` unless `SSHKEY_PROTECTED_LOCAL_KEY_NAME=''`, and an orphaned private key removed
- Runs `df-link`, `df-rm`, `df-mv`, and `df-doctor` through a stow-style link into a fake repo: arguments pass through (`df-rm` as `link.sh rm`, `df-mv` as `link.sh mv`, `df-doctor` to `doctor.sh`), and a wrapper outside a repo fails clearly
- Runs `df-deploy` with a stub `ssh` that runs the remote command against a scratch clone: pull and relink, every named or `DF_DEPLOY_HOSTS` host, a non-fast-forward pull failing that host before linking, a failed host not stopping the rest, dry runs, a missing host, and the unpushed-commit warning

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
- Tests what sourcing sets (`XDG_CONFIG_HOME` under `HOME`, only when `HOME` is set), `die` (stderr, exit 1, through gum when styled), the run summary (`add_result` counts, `add_next_step` keeps each step once), `prompt_mode` (`DOTFILES_PROMPT`, plain reads without a terminal), and the plain markers when stdout is captured

[`doctor.bats`](doctor.bats)

- Runs `scripts/doctor.sh` against a scratch home, a fixture repo, and fixture xdg-ninja data, with a new zsh's environment from the home's own `.zshenv`
- Verifies the Links, Fix, Decide, and Ignore groups, the closing hint, `--all`, `--tsv`, `--explain` with xdg-ninja's full advice, `--days`, option errors, and that a report changes nothing
- Classifies by xdg-ninja (export-only advice on a `how:` line, no XDG support, a stated move target only for that kind of entry and only once a new shell sets any variable the advice exports, an existing target left for a hand merge), by a new shell's redirect (the old copy, naming the variable whose path matches the entry), and by owner and last change
- Lists config directly in `~/.config` and commands in `~/.local/bin` that the repo does not manage under Not in the repo (with owner, age, or link target; a stale unowned folder under Decide; the XDG places from a new shell), makes broken links and old zsh completion caches fixes, replaces control characters in names, and reports missing xdg-ninja data and an incomplete check (which offers no fixes)
- The list of changes: Enter applies the Fix suggestions and skips the rest (`keep` still reads as skip); one line archives, adds (`link.sh add`), and ignores together; delete removes only after a yes and never follows a symlink; missing links get a `relink` row that runs `df-link` (skipped without GNU Stow); an unreadable line, `none`, closed stdin (no question printed), and nothing to fix change nothing; on macOS a test drives the terminal list through `script` with one key per change
- Never touches managed parents, credentials, private agents, local overrides, or the repo; archives folders and links without following them, once; respects `--destination`; leaves files in a symlinked folder alone; refuses a symlinked archive, a move through a symlinked parent, and a move while a program has the files open
- The installer's boxed report with closed stdin, its incomplete-check warning, and the unboxed `--fix-only` list after the report

[`githooks.bats`](githooks.bats)

- Runs `.githooks/pre-commit` against stub `check-drift` scripts: a pass, a failure reported as drift, a crash (killed by a signal) reported as a crash, and a missing agents checkout skipped; and runs `sandbox-install.sh` against a stub `docker` whose install fails, checking that only the tail is printed and the full log is kept

[`link.bats`](link.bats)

- Runs the real [`scripts/link.sh`](../scripts/link.sh) and GNU Stow against a scratch home and a local agents repo fixture
- Verifies linking per platform, shared editor settings, backups of changed copies and foreign links, removal of stale repo links (files that moved, were deleted, or belong to an unused package) while real files and foreign links stay, persona choice (flag, environment, saved state, OS default, unknown or wrong-OS names), personas without agents or editors, idempotency, and dry runs
- Covers agent links (clone, backup of real agent config, unreachable repo), seed files (the gh login only for personas with the `personal` layer), the `managed` and `status` reports, the installs (`offered` and `installs`: the optional installs read from setup scripts' detect lines, the OS directory first, a role requiring one, `DOTFILES_INSTALLS`, the saved choice, and a persona switch dropping what it does not offer), and the git identity: only `personal` sets `user.email`, `config.local` overrides it, and a missing email or a `[user]` in `~/.gitconfig` is warned about and reported; `status` names real files a layer the persona does not link would own (not shared parents or the empty folders a persona switch leaves) and never moves them
- Runs `add` against a fixture repo: a file becomes a link with no backup and keeps its executable bit; directories, `--platform`, relative paths, `--seed`, dry runs; refusals of secrets, private keys, `.local` overrides, agent and editor paths, repo files, outside paths, symlinks, banned words (without naming them), a layer the persona does not link, and a missing layer on closed stdin; the layer prompt on a pseudo-terminal describes each layer (paths, personas, platform) and takes a number or a name
- Runs `rm` against the fixture repo: a link becomes a real file with the same content and mode, gone from the layer (empty folders too) and the index, and left alone by the next link run; a directory removes every managed link in it and keeps its real files and foreign links; real files, seed files, foreign, agent, and editor links, paths outside the destination, and the destination itself are refused with nothing changed; dry runs; `--delete` moves the file to a private `cleanup/<timestamp>.remove/` folder
- Runs `mv` against the fixture repo: a moved file stays linked (relative, same content and mode) but into the new layer, the old repo file and its empty folders are gone and the index shows a rename, and the next link run keeps it; `--platform`, the platform part kept by default, and `--no-platform`; a directory moves every managed link in it; the layer prompt on a pseudo-terminal and closed stdin needing `--layer`; refusals (what `rm` refuses, a layer this persona does not link, the current layer, a taken destination, contradictory flags) leave the tree unchanged; dry runs; references to the old path listed and left as they are; and the closing note naming the personas that link the new layer

[`install.bats`](install.bats)

- Tests `install.sh` argument parsing, including `--persona`, `--install`, and `--no-install`, the persona picker (number, name, empty answer, EOF), a saved persona confirmed on every terminal run (Enter keeps it) and never asked without a terminal or after `--persona` or `DOTFILES_PERSONA`, rejecting an unknown persona or install before any change, and the closing installs step (the default install applied on a fresh machine, a chosen role, the saved choice, an applied one skipped, a failing script reported)
- Verifies SSH key helper behavior
- Tests error handling when `HOME` is unset
- Runs an isolated integration test for [`install.sh`](../install.sh) with sandboxed home and mocked external commands

[`ph.bats`](ph.bats)

- Runs `ph` (in `stow/personal/.local/bin`) against a mocked `curl` that records each request and answers from fixtures
- Verifies the login (password on stdin, never in argv; the saved password file; a wrong or missing password) and the logout on exit, blocking on and off with and without a timer (a bad duration fails before any request), allow and deny adds with comments and regexes, URL-encoded removals, API errors, the list, `check`, the blocked domains grouped one line each, newest first, over `--since` (a bad duration fails before any request), and the query log by client IP or name with control characters stripped, `--json`, and `api`

[`zsh.bats`](zsh.bats)

- Checks the zsh startup files for the XDG layout and the Homebrew bootstrap, and runs the `na` alias helper and `lg` (following lazygit to the directory it left in)
- Runs the bash startup files with a scratch home and checks the history path

[`repo_config.bats`](repo_config.bats)

- Checks the shipped personas and roles: only settings `link.sh` knows, with valid values; their layers, Brewfiles, roles, setup scripts, and `requires` exist; every persona for this OS loads in `link.sh` without writing anything; every stow package and Brewfile is used; every detect command parses; a role's setup script has no detect line of its own
- Parses every tracked JSON, TOML (examples too), YAML, and `.itermcolors` file, the zsh and bash startup files, and the zsh plugin list, skipping a check whose parser is missing
- Runs Vim with the shipped vimrc: Vim's defaults still load, and history and netrw's bookmarks go under `XDG_STATE_HOME` (or `~/.local/state`) in a private `vim` folder

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

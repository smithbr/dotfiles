# homebrew/

Brewfiles and `brew.sh`. A persona's `brew` and `brew_optional` keys pick which Brewfiles install, and a role's `brew` Brewfiles join the persona's ([root `AGENTS.md`](../AGENTS.md), [`roles/`](../roles/README.md)). `df-add brew NAME` adds a package ([`scripts/README.md`](../scripts/README.md)).

`brew.sh` installs Homebrew if needed, runs `brew bundle install --no-upgrade` on each `brew` Brewfile, on macOS offers the not-yet-installed entries of each `brew_optional` Brewfile in a picker (inside an install, `install.sh` asks this up front: `brew.sh --pending` lists the entries and `DOTFILES_BREW_PICKS` carries the answer), trusts tap-qualified entries first (Homebrew 7 refuses untrusted taps), writes `$(brew --prefix)/etc/npmrc` with `cache=~/.cache/npm` so npm started outside zsh never caches in `~/.npm` (a global npmrc without the repo's marker line is left alone with a warning), and ends with `brew cleanup`. `-n` reports what would be installed. Upgrades are `os-doctor`'s job: `brew upgrade --fetch-HEAD`, so a formula installed from HEAD (`args: ["HEAD"]`, as `xdg-ninja` is) is rebuilt from new commits too; on a machine with a stable copy installed earlier, run `brew reinstall --HEAD NAME` once.

- Keep Brewfiles flat lists of entries: no comment explaining an entry and no `if OS.*` block beyond the one for casks in `Brewfile.core`. A package that doesn't suit every machine goes in another Brewfile.
- Never install the same tool through two managers. apt (`scripts/bootstrap/linux/apt-packages.txt`) takes what needs root or runs before brew: `build-essential`, `curl`, zsh until Homebrew's is installed, and network utilities that want raw sockets. `Brewfile.core` is the default for userland CLI tools on both platforms; other Brewfiles hold persona-specific, GUI, or macOS-only apps and casks. Vault tooling (Obsidian, restic) is in `Brewfile.home` only. System daemons (Docker, Tailscale, Pi-hole, and Unbound from apt beside it) come through a script in `scripts/bootstrap/linux/`, applied as an optional install or a role; on a Mac, Docker and Tailscale are in the macOS picker, and the install scripts skip a tool Homebrew already put in place. A Mac app with no cask gets an install script in `scripts/bootstrap/macos/`. Bootstrap runs apt first, then brew. `tests/brew.bats` fails when the git config references a tool no Brewfile installs.

## Where a tool comes from

One source per kind of tool. Agents follow this on every machine, and the shell refuses the two installs it rules out.

- **zsh:** Homebrew's on both platforms (`Brewfile.core`); `install.sh` makes the first `zsh` on PATH the login shell when the login shell is not zsh already. On Linux, apt's zsh is the shell that exists before Homebrew does.
- **What the OS ships:** on a Mac, git, curl, and bash are Apple's, never Homebrew's. The test suite builds its own bash into its cache ([`tests/README.md`](../tests/README.md)).
- **A command-line tool you always want:** `Brewfile.core` (`df-add brew NAME`), or apt for what needs root or runs before brew.
- **A Mac app:** a cask in a Brewfile; adopt one installed by hand with `brew install --cask --adopt NAME`. App Store apps are `mas` entries.
- **A one-off run:** `uvx`, `npx`, or `bunx`; nothing stays installed.
- **A Python tool you keep:** `uv tool install`, recorded as a `uv "NAME"` entry in a Brewfile so `brew bundle` installs it. Never `pipx`, and never `pip` outside a virtualenv; `.zshenv` sets `PIP_REQUIRE_VIRTUALENV=1`.
- **Python itself:** uv's, never Homebrew's or Apple's. A Python script in this repo starts with `#!/usr/bin/env -S uv run --script` and a `requires-python` line, so uv supplies a new enough interpreter wherever `python3` is not; the test suite's `python3` is uv's too.
- **Never `npm install -g`:** the `npm` shell function refuses global installs (`NPM_ALLOW_GLOBAL=1 npm …` for a one-time exception). Homebrew's own npm updates with `brew upgrade node`.
- **MCP servers:** as `uvx`, `npx`, or `bunx` commands where possible, so nothing has to be installed first; give a GUI app an absolute path, since it doesn't read the shell's PATH.

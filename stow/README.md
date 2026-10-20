# stow/

Everything linked into `~`. Linking itself is in [`scripts/README.md`](../scripts/README.md); repo-wide rules are in the [root `AGENTS.md`](../AGENTS.md).

## Layers

`stow/<layer>/` mirrors the home directory under real file names; `stow/<layer>.<os>/` holds that layer's platform-only files. A machine links the layers its persona and its chosen roles list ([`roles/`](../roles/README.md)).

- `common`: shell, git, and CLI config every persona gets.
- `tools`: personal CLI tools: `sshkey`, `os-doctor`, `ai-doctor`, and the `df-*` wrappers.
- `personal`: what `home`, `server`, and `vps` use but a work Mac does not: `cf-cert`, `df-deploy`, `firetv` (debloats the TCL Fire TV over ADB), `ph` (administers the Pi-hole over its API from the tailnet), `ts-test`, the personal git identity, and the gh login seed.
- `desktop`: GUI app config, iTerm2, and `st`. Only the Mac personas link it, so it needs no `desktop.darwin` part.
- `server`: `server.linux` holds the server git config.
- `pihole`: `pihole.linux` holds the `ph-*` tools; linked by the `pihole` role, not a persona.

Rules:

- Put a new file in the narrowest layer that fits. Repository tooling belongs outside `stow/`.
- A script that calls a tool from another layer must also find it when run from the repo.
- Linking uses `--no-folding`: directories in `~` stay real and only files are symlinks. Switching persona removes the old layers' links as stale.
- Edit the repo file, never replace the link in `~`. After adding, removing, or renaming a file under `stow/`, run `df-link`.

## Git identity

`stow/common/.config/git/config` sets no `[user]`. It includes `config.desktop`, `config.server`, and `config.personal`, then `config.local`, which wins. Only the `personal` layer brings an identity, so a `work` machine sets name, email, and any signing key in `~/.config/git/config.local`. Git reads `~/.gitconfig` after `~/.config/git/config`, so a `[user]` left there silently beats `config.local`; `link.sh` warns about that and about a missing `user.email`, and `status` and `df-doctor` report them. Nothing edits git config for you.

## iTerm2 and `st` (`desktop`)

- The profile is the Dynamic Profile `stow/desktop/Library/Application Support/iTerm2/DynamicProfiles/dotfiles.json`, named `dotfiles`. It holds only settings that differ from iTerm2's defaults, and its colors are copied from the presets in `stow/desktop/.config/iterm2/`. It is not `Rewritable`, so GUI edits do not persist: change this file. Settings outside profiles are `scripts/bootstrap/macos/iterm2.sh`'s; keep the `Guid` in both files the same.
- `st` opens Claude Code in a new iTerm2 window: a team from `~/.config/claude-team/teams.toml`, one agent, a directory, or the current one (`st --help`). The teams file is local and untracked; the repo tracks `teams.toml.example` beside it, which documents every key. Keep team and agent names short; they are what you type.

## Tools

- `df-link`, `df-doctor`, `df-add`, `df-rm`, `df-mv` (`tools`): wrappers for `scripts/`, in [`scripts/README.md`](../scripts/README.md).
- `df-deploy HOST...` (or the hosts in `DF_DEPLOY_HOSTS`): after a push, each host pulls `~/.dotfiles` fast-forward only and runs `scripts/link.sh` over `ssh -t`. It warns about unpushed commits, and one failing host does not stop the rest.
- `ai-doctor`: trims what Claude Code, Codex, and Cursor load. One row per plugin, skill bundle, skill, and MCP server shows its `/` entries, tokens (from `claude -p /context`), and last use (from Claude Code's transcripts); a row unused for 30 days starts on off. The menu turns rows off through each tool's own command (`claude plugin disable`, `skill-drop`, `skillOverrides`, `claude mcp remove`), logs each change in `~/.local/state/ai-doctor/actions.jsonl`, and `ai-doctor --reset` undoes them. `ai-doctor --help` has the rest.

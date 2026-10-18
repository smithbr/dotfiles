# Dotfiles change quality

These rules apply throughout this repository. Before changing a directory, read its `README.md`; its rules apply there too.

- [`scripts/`](scripts/README.md): `link.sh`, the `df-*` wrappers, `brew-add.sh`, and `doctor.sh` (`df-doctor`).
- [`roles/`](roles/README.md): roles, the optional installs, and how `install.sh` asks for and applies them.
- [`scripts/bootstrap/`](scripts/bootstrap/README.md): OS bootstrap, the setup scripts, `harden.sh` and its check `harden-test.sh`.
- [`stow/`](stow/README.md): layers, where a new file goes, git identity, iTerm2, the tools.
- [`homebrew/`](homebrew/README.md): which package manager and Brewfile a package belongs in.
- [`seed/`](seed/README.md) and [`editors/`](editors/README.md): copied-once app config and shared editor settings.
- [`tests/`](tests/README.md): what each suite covers and how tests are written.

Any new script, or a change to how one talks to the person running it (help, flags, output, prompts, the end of a run), follows [`scripts/DESIGN.md`](scripts/DESIGN.md), under `scripts/` and `stow/*/.local/bin/` alike. It overrides a skill's own wrapper template.

## Installer reference

`install.sh --help` lists the supported options:

- `-n`, `--dry-run`: report changes without modifying the system, including what the OS bootstrap and Homebrew would install.
- `-v`, `--verbose`: stream command output instead of collecting it into boxes.
- `-d`, `--debug`: verbose output plus shell command tracing.
- `-h`, `--help`: show usage and exit.
- `--persona NAME`: set the machine up as a persona from `personas/` and save the choice.
- `--install NAME`, `--no-install NAME`: add or drop an install, an optional install or a role; `DOTFILES_INSTALLS="a b"` sets the whole list. Saved like the persona.
- `--harden`, `--no-harden`: run `scripts/bootstrap/linux/harden.sh` first, or skip the question.
- `--skip-system`: skip OS bootstrap.
- `--skip-brew`: skip Homebrew installation, updates, and bundles.
- `--skip-shell`: skip adding zsh to `/etc/shells` and running `chsh`.

Unrecognized arguments and everything after `--` are passed to `stow` through `scripts/link.sh`:

```bash
~/.dotfiles/install.sh --skip-brew -- --verbose=2
```

Every question is asked up front, before anything changes: the persona, the roles, the optional installs, hardening, then on macOS the optional Homebrew packages (`brew.sh --pending` lists them and `DOTFILES_BREW_PICKS` carries the answer, so `brew.sh` asks nothing inside an install). The header then states the persona, installs, and skipped steps, and one `sudo -v` covers the steps that need it. Hardening runs first ([`scripts/bootstrap/README.md`](scripts/bootstrap/README.md)) and the installs last ([`roles/README.md`](roles/README.md)).

`bootstrap.sh` is the entry point for a machine without the repo: curl-able, it installs git, clones, as root creates the admin user through `harden.sh --user`, then runs `install.sh`. Keep it free of anything else in the repo.

## Personas

A persona is `personas/<name>`: plain `key=value` lines, parsed and never sourced. Its keys:

- `os`: allowed platforms.
- `layers`: the `stow/` layers it links.
- `agents`: the private agents checkout.
- `agent_apps`: which apps get its links (`claude` for `~/.claude`, `cursor` for `~/.cursor`, `codex` for `~/.codex`; every app when left out). Switching persona removes the links of an app the new one drops. Each app's own settings are never touched.
- `skills`: skill bundles from the agents checkout linked into `~/.agents/skills` (`core` when left out).
- `editors`: shared editor settings.
- `brew`, `brew_optional`: Brewfiles installed in full, and offered in the macOS picker. `install.sh` passes them to `homebrew/brew.sh` as `DOTFILES_BREWFILES` and `DOTFILES_BREW_OPTIONAL`. A persona with no Brewfiles skips the Homebrew step.
- `roles`, `roles_optional`: roles on by default, and offered.
- `harden`: `yes` offers `harden.sh` on an unhardened Linux box.

The persona comes from `--persona`, then `DOTFILES_PERSONA`, then `~/.local/state/dotfiles/persona`, then the OS default (`home` on macOS, `server` on Linux), which warns until one is chosen. Without `--persona` or `DOTFILES_PERSONA`, a terminal is asked every run with the saved choice preselected, so Enter confirms it. Closed stdin keeps the saved choice or the default. A real apply with `--persona` or `DOTFILES_PERSONA` saves it; dry runs never save.

## Installation behavior

- Changes to managed paths must preserve existing user data. `scripts/link.sh` replaces a real file only when it matches the repo and otherwise moves it to `~/.local/state/dotfiles/clobbered/<timestamp>/` first; keep that behavior and cover transitions in `tests/link.bats`.
- Bootstrap must work before the managed shell configuration and Homebrew tools are available. Establish prerequisites before use; do not rely on the developer's current PATH, aliases, or installed utilities.
- Keep repeated installs safe: no duplicate configuration entries, needless reinstalls, or overwritten local overrides. For changes to installation state, check both a fresh setup and an already-configured one.
- Preserve `install.sh`'s dry-run and skip flags and argument forwarding to stow. Dry-run must not install packages, change the login shell, or write destination files.
- A closed stdin or absent TTY must not hang bootstrap. It keeps the saved choices or, on a fresh machine, the defaults: the installs on by default run, and nothing off by default or only offered (`# default: off`, `roles_optional=`, hardening) is opted into. Exercise EOF explicitly when changing prompts; account for `set -e` when `read` fails. Prompts belong in the preflight of `install.sh`, through `choose_one` and `choose_many` in `scripts/common.sh`, not inside a step; a step that must wait for something polls with a timeout rather than reading a key.
- Support only the latest OS release and the one before it. Let older releases degrade rather than adding workarounds for them.
- Shared paths must work on macOS and Debian. Check BSD/GNU utility differences and the shell available at the affected install stage before adding flags or shell features. Keep OS-specific operations in their platform branch.
- Reuse `scripts/common.sh` for logging, privilege handling, and command presentation. Required command failures must remain failures through wrappers and pipelines, with useful diagnostics.

## Verification

- For shell behavior, bootstrap, package-list, or runtime configuration changes, run only the Bats files the change can affect, from the repository root (`./tests/run_tests.sh tests/link.bats`; ShellCheck and `tests/lint-docs.sh` always run first). Do not run the full suite locally: CI runs it after every push. The suite's own tools come from a cache `tests/deps.sh` fills on the first run; `shellcheck`, `stow`, and `uv` must already be on PATH (`Brewfile.core`).
- Add behavioral regression coverage for bug fixes and meaningful new behavior in the relevant existing Bats suite. Assert exit status, resulting files, or external command calls; checking source text alone does not establish runtime correctness.
- For changes that affect a fresh install, run `./tests/sandbox-install.sh` once the changes are committed and a Docker daemon is available. It archives `HEAD`, so it cannot verify uncommitted edits. Do not create a commit solely to run it without a commit request; report that validation as pending.
- The container check covers a bare Debian install with closed stdin, but skips Homebrew and login-shell changes. CI runs on macOS. Report these limits when relevant rather than treating either check as full cross-platform coverage.
- For documentation-only changes, check the diff, referenced paths, and commands; no runtime suite is required. Report checks actually run, failures, and relevant gaps when handing off any change.

## Keeping the workflow accurate

- Keep `README.md` focused on installation and discovery. Document a directory in its own `README.md`, once, and keep only repo-wide rules here; other pages link to the owning page instead of repeating it. Never add a file under `personas/` or `roles/` except `roles/README.md`: every other file there is read as a persona or a role. Update the corresponding guidance when behavior changes.
- Keep CI and local validation aligned through `tests/run_tests.sh`: CI runs it in full on every push, and the pre-push hook runs its `--lint-only` half plus the container install ([`tests/README.md`](tests/README.md)). If test discovery or lint coverage changes, verify that the intended files and tests actually run.
- Commit policy (straight to `main`, short subjects), how this repo stays consistent with the private agents checkout, and the notes outside the repo that must change with it are in `~/.config/agents/MAINTENANCE.md`, when that checkout is present.

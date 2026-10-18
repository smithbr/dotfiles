# Script design

How a script in this repo looks and behaves to the person running it: help, arguments, output, prompts, and the end of a run. It applies to every new script under `scripts/` and `stow/*/.local/bin/`, and to any script whose interface you reshape. Shell standards (quoting, `[[ ]]`, `printf`, functions) come from `~/.config/agents/rules/08-shell.mdc`; where a layer goes is in [`stow/README.md`](../stow/README.md). Bootstrap scripts that run before the repo is linked follow [`bootstrap/README.md`](bootstrap/README.md) first.

The model scripts are `stow/tools/.local/bin/os-doctor` (a check-and-fix run), `stow/personal/.local/bin/firetv` (subcommands), and `scripts/doctor.sh` (a report followed by a list of changes). `sshkey` predates the shared helpers and redefines them; do not copy its header.

## 1. Use the shared helpers, never your own copies

Every bash script sources [`common.sh`](common.sh) and uses what it offers instead of defining its own:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Shared helpers from the dotfiles repo, reached through this script's stow
# link; DOTFILES_DIR names the repo when a copy runs from elsewhere.
DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../../.." && pwd)}"
# shellcheck source=scripts/common.sh
source "${DOTFILES_DIR}/scripts/common.sh"
```

Under `scripts/`, set `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"` and source `"${SCRIPT_DIR}/common.sh"`, as `brew-add.sh` does.

| Need | Use |
|---|---|
| Section title | `_header "Name: detail"` |
| Row in a section | `_check` (passed), `_cross` (failed), `_skip` (skipped), `_item` (plain) |
| Block of text, summary, next steps | `_box` |
| Final good or bad line | `_success`, `_warn` |
| Log lines | `log_info`, `log_warn`, `log_error` |
| Stop with an error | `die "message"` |
| Slow command (network, install, build) | `spin "Title" cmd args...` |
| Pick one / pick several | `choose_one`, `choose_many` |
| Results and follow-ups | `add_result PASS\|WARN\|FAIL "message"`, `add_next_step "command"` |
| Root and sudo | `require_non_root`, `sudo_cmd` |
| Is a tool installed | `tool_installed NAME` |

A helper two scripts would share (a `confirm`, a summary printer) goes in `common.sh` with a test in `tests/common.bats`, not inline. Colors are the ones these helpers use (212 headers, 76 pass, 214 warn, 196 fail, 244 dim, 240 borders); a script does not pick its own palette.

## 2. Shape of the file

Top to bottom: shebang and `set -euo pipefail`, a one-line comment saying what the script is for, the `common.sh` block, settings, `usage()`, the work functions, `parse_args()`, `main()`, and `main "$@"` as the last line.

- Settings are uppercase variables with an environment override: `FOO_BIN="${FOO_BIN:-foo}"` for every external command, so tests can stub it, and state under `${XDG_STATE_HOME:-${HOME}/.local/state}/<script>`.
- Name a script for what it does, with the family prefix where one exists: `df-` wraps a repo script, `ph-` works on the Pi-hole, `<area>-doctor` checks something and offers fixes.
- A script with more than one action takes a subcommand (`firetv disable ads`), never a flag per action.

## 3. Help

- `-h`, `--help`, and `help` as a subcommand print help and exit 0.
- Help is one markdown heredoc in `usage()`: `# name`, one sentence on what it does, then `## Commands` (a table) or `## Steps` (a list), `## Options`, and `## Examples`. On a terminal with gum it goes through `gum format`; otherwise the same text prints as is. Never keep a second, shorter plain version.
- Help says what the script changes and what it never touches, and the first-run setup a person needs.

## 4. Arguments and exit codes

- `parse_args` is a `while (($# > 0)); case "$1"` loop. Long options accept `--opt value` and `--opt=value`; an option missing its value dies with `"--opt needs <what>"`.
- An unknown option dies with `Unknown option: X (see NAME --help)`. A missing required subcommand prints usage to stderr and exits 2.
- The standard flags, with these exact spellings when the script has the behavior: `-n, --dry-run` (report what would change, change nothing), `-y, --yes` (take every default, ask nothing), `-v, --verbose` (stream command output; sets `VERBOSE=1`, which `spin` honors).
- Exit 0 when everything passed or was done, 1 when something failed or a check found a problem, 2 for bad usage. A doctor that only found things worth trimming exits 0.

## 5. Output

- A run opens with `_header "<name>: <target>"` and, when it helps, a `_box` of what it will act on (platform, host, paths).
- Each stage is a `_header` followed by rows: `_check` for done, `_cross` for failed, `_skip` for skipped with the reason. One line per thing, no prose paragraphs.
- Every failure is two parts: what went wrong, then what to do, as a command when there is one (`add_next_step "ph login"`). Never a bare "failed".
- Wrap slow commands in `spin`, never fast local ones. With `--verbose` the output streams instead.
- Styling only on a terminal: `HAS_GUM` is true when gum is installed and stdout is a terminal, and every helper falls back to plain text. `NAME | cat` must read cleanly with no escape codes.
- Data goes to stdout, messages to stderr, so `NAME list | grep x` works. A `--tsv` or plain listing is better than parsing styled output.

## 6. End of a run

Every run that does more than one thing ends the same way:

1. A count line: `Passed: N  Warnings: N  Failed: N` (`_success` when nothing failed, `_warn` otherwise).
2. `_header "Next steps"` and a `_box` of `- command` lines from `add_next_step`, only when there are any.
3. The exit code from section 4.

A single action ends with one line saying what changed (`Disabled 4 packages`), or what would have with `--dry-run`.

## 7. Prompts

- Ask every question up front, before the first change, then run without stopping. A step that must wait polls with a timeout; it never reads a key mid-run.
- Choices go through `choose_one` and `choose_many`, which use gum when stdin and stderr are a terminal and a numbered list otherwise; `DOTFILES_PROMPT=gum|read` forces one. Offer the current or safe answer as the default so Enter accepts it.
- A yes/no question defaults to no: `gum confirm` on a terminal, else `Question? [y/N]`. `--yes` answers yes; `--dry-run` asks nothing.
- No terminal or closed stdin never hangs and never opts in to anything: the script takes the saved choice or the safe default, or fails with the choices it would have offered and the flag that sets one. Guard `read` for `set -e` (`IFS= read -r reply || reply=""`).
- A script with subcommands and no arguments, on a terminal, may offer `gum choose` over the subcommands; without a terminal it prints usage and exits 2.
- More than a handful of items to decide on get one list with each row set to its suggestion and Enter applying all of them, as `df-doctor` does, not a question per item.

## 8. Making changes

- Show what will change before changing it, and support `--dry-run` for anything that writes outside the script's own state.
- Prefer reversible: archive to `~/.local/state/<script>/<timestamp>/` (private permissions, original relative paths) over deleting, and back up a config file before editing it. Say where the copy went.
- Deleting or anything irreversible lists what goes and asks once more, defaulting to no, even after other answers.
- Re-running is safe: a second run with nothing to do says so and changes nothing.
- One failing item does not stop the rest; it is counted, reported, and makes the exit code 1.

## 9. Python instead of bash

Use a `uv run --script` Python file (as `ai-doctor` and `st` do) when the script parses JSON or TOML, keeps real data structures, or would pass a few hundred lines of bash logic. It keeps the same interface: help in the module docstring shown by `--help` (usage lines first, then prose), argparse with the flag spellings above, the same exit codes, color only when stdout is a terminal and `NO_COLOR` is unset, `--no-color`, and errors as `name: message` on stderr.

## 10. Before it is done

- Tests in the relevant Bats file (`tests/bin_scripts.bats` for small tools, or the script's own file): `--help`, an unknown option, closed stdin, `--dry-run` changing nothing, and the main path with stubbed commands. Assert exit status and output or files.
- `./tests/run_tests.sh tests/<file>.bats` passes; it runs ShellCheck first.
- The script is listed where its layer is described in [`stow/README.md`](../stow/README.md), or in this directory's [`README.md`](README.md) for repo tooling.
- `NAME | cat`, `NAME < /dev/null`, and `NAME --help` all read well.

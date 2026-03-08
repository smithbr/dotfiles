# Shell Script Standards

Standards for all shell scripts. Follow these when writing or modifying any `.sh` file or executable script.

## Shebang and Safety

- Use `#!/usr/bin/env bash` — never `#!/bin/bash` or `#!/bin/bash -e`.
- Always include `set -euo pipefail` as the first command after the shebang and comments.
- Exception: POSIX `sh` scripts use `#!/usr/bin/env sh` and `set -eu`.

## OS and Architecture Detection

- Use `case "$OSTYPE"` for OS branching — never `uname -s` or custom variables like `$OS_NAME`.
- Match `darwin*` for macOS and `linux*` for Linux.
- Use `case "$(uname -m)"` for architecture detection (e.g. `arm64` vs `x86_64`).
- Prefer `case` statements over `if/elif` chains for OS/arch branching.

```bash
case "$OSTYPE" in
    darwin*)
        # macOS
        ;;
    linux*)
        # Linux
        ;;
esac
```

## Shared Utilities

- If the project has shared helper functions (e.g. logging, privilege checks), use them consistently — never duplicate their logic inline.
- Prefer `printf`-based logging helpers over raw `echo` for user-facing output.

## Variables

- Always brace-wrap: `"${var}"` not `"$var"`.
- Always quote variables in expansions: `"${var}"` not `${var}`.
- Exception: arithmetic contexts and simple loop vars where quoting is unnecessary.

## Conditionals

- Use `[[ ]]` in bash scripts — never `[ ]`.
- Exception: POSIX `sh` scripts must use `[ ]`.

## Output

- Use `printf` — never `echo -e`.
- For colored output, use `%b` format specifier to interpret escape sequences:

```bash
printf '%b%s%b\n' "${RED}" "error message" "${RESET}"
```

## Functions

- Use `name() {` style — no `function` keyword, opening brace on same line.
- Declare variables with `local` at the top of each function.
- Keep functions focused — one responsibility per function.

## Dependencies

- Check dependencies with `command -v` — never `which`.
- Validate required commands before use, ideally in a dedicated function.

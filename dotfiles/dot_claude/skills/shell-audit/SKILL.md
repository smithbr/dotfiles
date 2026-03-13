---
name: shell-audit
description: Audit and refactor shell scripts for consistency, safety, and modern best practices. Use when adding, modifying, or reviewing shell scripts.
allowed-tools: Read Grep Glob Bash Edit
compatibility: Requires shellcheck, prefer `brew install shellcheck` for latest version.
---

# Shell Script Audit

## When to Use

- When a new shell script is added to the repo.
- When modifying an existing shell script.
- When the user asks to review or audit shell scripts.
- As a follow-up pass after making changes to multiple scripts.

## Prerequisites

- Read `~/.claude/rules/06-shell.md` for the established standards.

## Audit Checklist

Run through each item for every script in scope.

### 1. Shebang and Safety Flags
- [ ] Shebang is `#!/usr/bin/env bash` (or `#!/usr/bin/env sh` for POSIX scripts)
- [ ] `set -euo pipefail` is present immediately after shebang/comments
- [ ] No flags embedded in the shebang line (e.g. `#!/bin/bash -e`)

### 2. Shared Utilities
- [ ] If the project has shared helpers (logging, privilege checks, etc.), scripts use them consistently
- [ ] No duplicated logic that belongs in a shared module
- [ ] No raw `echo` for user-facing output when logging helpers exist

### 3. OS Detection
- [ ] Uses `case "$OSTYPE"` with `darwin*`/`linux*` patterns
- [ ] No `uname -s` for OS detection (use `uname -m` only for architecture)
- [ ] No custom OS variables (e.g. `$OS_NAME`)

### 4. Variables and Quoting
- [ ] All variables brace-wrapped: `"${var}"`
- [ ] All expansions quoted
- [ ] No unquoted variables in conditionals or command arguments

### 5. Conditionals
- [ ] Uses `[[ ]]` — no `[ ]` in bash scripts
- [ ] Uses `command -v` — no `which`

### 6. Output
- [ ] Uses `printf` — no `echo -e`
- [ ] Color variables use `%b` format specifier, not embedded in format strings
- [ ] No SC2059 shellcheck warnings

### 7. Functions
- [ ] `name() {` style — no `function` keyword
- [ ] Opening brace on same line as function name
- [ ] `local` declarations for all function-scoped variables
- [ ] No unused variables (SC2034)

### 8. Validation
- [ ] `bash -n <file>` passes (syntax check)
- [ ] `shellcheck <file>` passes with no warnings/errors
- [ ] SC2030/SC2031 infos reviewed and confirmed as intentional if present

## Procedure

1. **Discover scripts**: Find all `.sh` files, `executable_*` files, and shebanged scripts in the project.
2. **Read each script**: Review against the checklist above.
3. **Group findings**: Report inconsistencies by category, not by file.
4. **Propose fixes**: Present a numbered list of fixes for user approval.
5. **Apply fixes**: Make approved changes.
6. **Validate**: Run `bash -n` and `shellcheck` on all changed files.
7. **Second pass**: Re-read changed files and re-run shellcheck to confirm zero regressions.

## Exclusions

- **POSIX `sh` scripts** (e.g. upstream forks): Only audit for safety flags (`set -eu`) and quoting. Do not convert to bash conventions.
- **Sourced shell files** (e.g. aliases, shell functions): These have no shebang and inherit the parent shell. Audit for quoting and `[[` usage but skip shebang/safety flag checks.

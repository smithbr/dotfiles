---
name: commit
description: Stage and commit changes with a concise message. Use when the user asks to commit.
user-invocable: true
allowed-tools: Bash
---

# Commit

## Procedure

1. Run `git status --short` and `git diff --stat` to review what changed.
2. Run `git diff --cached --stat` to check for already-staged changes.
3. Stage all changes with `git add -A` unless the user specifies particular files.
4. Generate a short message summarizing the changes. Refer to the user's previous messages for message style, length, and tone.
5. Show the proposed message and ask the user to confirm or edit before committing.
6. Commit with the confirmed message. Do not push.

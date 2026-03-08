# Meta

Read rules in this directory in numbered order. Lower numbers are higher priority.

## Priority
1. `00-meta.md` — how to interpret rules
2. `01-security.md` — secrets, credentials, privacy
3. `02-git.md` — commit and push behavior
4. `03-coding.md` — code style and conventions
5. `04-style.md` — communication preferences
6. `05-frugality.md` — token and cost management
7. `06-shell.md` — shell script standards

## Sources of Truth
- Rules in `~/.config/agents/rules/` are the source of truth.
- Skills in `~/.config/agents/skills/` are required skills.

## Conflict Resolution
- If a project-level rule conflicts with a shared rule, the project-level rule wins.
- If a tool-specific instruction conflicts with a shared rule, the shared rule wins unless the tool instruction explicitly overrides it.
- If two shared rules conflict, the lower-numbered file takes priority.
- If a rule feels wrong for the current context, flag it rather than silently ignoring it.
- Never invent rules that weren't specified. If something isn't covered, use good judgment and state your assumption.
- If a task would require violating a rule, say so and ask how to proceed rather than bending the rule quietly.
- If the user establishes a new rule or preference during a session, suggest where it should be persisted (shared rules vs tool config) and ask before writing it.

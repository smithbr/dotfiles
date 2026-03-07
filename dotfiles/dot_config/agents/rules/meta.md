# Meta

- Rules in `~/.config/agents/rules/` are the source of truth.
- If a project-level rule conflicts with a shared rule, the project-level rule wins.
- If a tool-specific instruction conflicts with a shared rule, the shared rule wins unless the tool instruction explicitly overrides it.
- If two shared rules conflict, ask for clarification.

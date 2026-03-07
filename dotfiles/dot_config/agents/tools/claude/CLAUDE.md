# Global Claude Instructions

## Shared Rules
Read and follow all rules in `~/.config/agents/rules/`.

## Chromium Browser
- Preferred Chromium browser: Comet (located in /Applications)

## Tools & Stack
<!-- Fill in your preferred tools, e.g.: -->
<!-- - Package manager: bun / npm / pnpm / yarn -->
<!-- - Language: TypeScript / Python / etc. -->
<!-- - Formatter: prettier / black / etc. -->
<!-- - Test runner: vitest / pytest / jest / etc. -->

## Project Notes
- I work primarily on macOS, sometimes on Debian.
- I use zsh
- I prefer Homebrew for package installations whenever possible

## Obsidian - Overview
- I use Obsidian for all of my documentation
- My Obsidian vault is located at `/Users/bran/Library/Mobile Documents/iCloud~md~obsidian/Documents/Bran's Vault`
- Everything goes into my single vault

## Obsidian - Dev Diary
- At the end of each code session (or just every so often, or when asked), write a new, or append to an existing, dated dev diary entry for the current project or task
- Structure: `<vault>/dev/projects/<project-name>/diary/YYYY-MM-DD.md`
- Format: `# Dev Notes — YYYY-MM-DD` header, then `## <section>` headings with bullet-point summaries
- When appending to an existing file, do NOT add a new header — only add new `## section` content
- Keep it high-level — what changed and why, not implementation details
- Base diary content on git commit history, not just Claude session activity

## Obsidian - Tasks Diary
- At the end of each non-project-work session, write a new, or append to an existing, dated diary entry
- Structure: `<vault>/dev/agent-diary/<short-name-for-task-or-session>-YYYY-MM-DD.md`
- Format: `# <Short Name for Task/Session> — YYYY-MM-DD` header, then `## <section>` headings with bullet-point summaries
- When appending to an existing file, do NOT add a new header — only add new `## section` content
- Keep it high-level — what we did and why
- Don't log every little troubleshooting session/question in these entries. I don't want those

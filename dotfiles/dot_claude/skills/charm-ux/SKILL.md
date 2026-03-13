---
name: charm-ux
description: Redesign shell script UX using Charmbracelet tools (gum, glow, etc). Use when the user asks to improve, redesign, or add interactive UX to a shell script, or mentions Charmbracelet/gum/glow.
allowed-tools: Read Grep Glob Bash Edit Write WebFetch
compatibility: Requires gum (brew install gum). Optional: glow (brew install glow).
---

# Charmbracelet UX Redesign for Shell Scripts

## When to Use

- When the user asks to redesign or improve UX of a shell script
- When the user asks to add interactive prompts, styled output, or spinners to a script
- When the user mentions Charmbracelet, gum, or glow

## Prerequisites

- Read `~/.claude/rules/06-shell.md` for shell coding standards
- Read the reference implementation for established patterns: `~/.dotfiles/dotfiles/dot_local/bin/executable_sshkey` (lines 1-110 for gum wrappers, full file for usage examples)

## Design Principles

1. **Graceful degradation**: Every gum/glow call MUST have a plain-text fallback for non-interactive (piped, CI, cron) environments
2. **Respect `-y` / `FORCE` flags**: Non-interactive mode must work without TTY
3. **Don't change core logic**: Only modify the presentation layer — inputs, outputs, confirmations, progress indication
4. **Minimal dependencies**: `gum` is the primary tool; use `glow` for markdown rendering if already installed; avoid requiring additional installs
5. **Consistency**: Follow the established wrapper pattern below, but adapt freely when a script's workflow calls for a different UX (e.g., `gum table` for tabular data, `gum filter` for fuzzy search, `gum pager` for long output)

## Charmbracelet Tools Reference

Consult the official docs for the full API when designing UX:

- **gum**: https://github.com/charmbracelet/gum — interactive prompts, styled text, spinners, tables, filtering, paging, file picking, markdown formatting
- **glow**: https://github.com/charmbracelet/glow — terminal markdown renderer, good for help/docs output
- **vhs**: https://github.com/charmbracelet/vhs — terminal GIF recorder (useful for demos, not for script UX)
- **freeze**: https://github.com/charmbracelet/freeze — terminal screenshot tool
- **mods**: https://github.com/charmbracelet/mods — AI on the CLI (pipe stdin to LLMs)

When a tool isn't installed, check its README for capabilities that might benefit the script. Suggest installation only if clearly valuable.

## Established Wrapper Pattern

Add these near the top of the script, after `set -euo pipefail` and variable declarations. This is the baseline — adapt, extend, or pare down to fit the script.

```bash
# -- gum helpers (graceful degradation) --
HAS_GUM=false
command -v gum >/dev/null 2>&1 && [[ -t 1 ]] && HAS_GUM=true

_header() {
    if [[ "${HAS_GUM}" == true ]]; then
        gum style --bold --foreground 212 "$1"
    else
        printf '%s\n' "$1"
    fi
}

_success() {
    if [[ "${HAS_GUM}" == true ]]; then
        gum log --level info "$1"
    else
        printf '%s\n' "$1"
    fi
}

_warn() {
    if [[ "${HAS_GUM}" == true ]]; then
        gum log --level warn "$1" >&2
    else
        printf '%s\n' "$1" >&2
    fi
}

_check() {
    if [[ "${HAS_GUM}" == true ]]; then
        gum style --foreground 76 "  $(printf '\xe2\x9c\x93') $1"
    else
        printf '  %s\n' "$1"
    fi
}

_cross() {
    if [[ "${HAS_GUM}" == true ]]; then
        gum style --foreground 196 "  $(printf '\xe2\x9c\x97') $1"
    else
        printf '  %s\n' "$1"
    fi
}

_item() {
    if [[ "${HAS_GUM}" == true ]]; then
        gum style --foreground 244 "  $1"
    else
        printf '  %s\n' "$1"
    fi
}

_box() {
    local content="$1"
    if [[ "${HAS_GUM}" == true ]]; then
        printf '%s' "${content}" | gum style --border rounded --border-foreground 240 --margin "0 0" --padding "0 1"
    else
        printf '%s\n' "${content}" | sed 's/^/  /'
    fi
}

_spin() {
    local title="$1"
    shift
    if [[ "${HAS_GUM}" == true ]]; then
        gum spin --spinner dot --title "${title}" -- "$@"
    else
        "$@"
    fi
}
```

### Key implementation notes

- **`_box()` must use piped input** — passing multiline content as an argument to `gum style` causes blank-line artifacts. Always pipe via `printf '%s' "${content}" | gum style ...`
- **Section headers use the format**: `_header "Source: detail"` (colon separator)
- **Error messages use a two-line pattern**: `_warn "What went wrong"` followed by `_warn "Tip: how to fix it"` — always give the user an actionable next step
- **`_spin` wraps slow commands** (network calls, API requests, key generation) but not fast local operations

## Redesign Procedure

1. **Read the script end-to-end** to understand its workflow, commands, and output patterns
2. **Identify UX touchpoints**:
   - User input (prompts, confirmations, selections)
   - Progress/status output (headers, success/error messages, spinners)
   - Data display (lists, tables, key-value pairs, diagnostics)
   - Help/usage text
3. **Choose gum components** for each touchpoint:
   - `gum choose` / `gum filter` — selection from a list
   - `gum input` / `gum write` — text input (single line / multiline)
   - `gum confirm` — yes/no confirmation
   - `gum spin` — spinner for slow operations
   - `gum style` — styled text, bordered boxes
   - `gum table` — tabular data display
   - `gum format` — markdown rendering (or use `glow` for richer output)
   - `gum pager` — scrollable long output
   - `gum log` — leveled log messages (info, warn, error, debug)
   - `gum file` — file picker
4. **Add the wrapper functions** (only include wrappers the script actually uses)
5. **Add interactive no-args mode** if the script has subcommands — use `gum choose` to pick a command, then prompt for required arguments
6. **Replace raw prompts** (`read -p`, `read -r`) with `gum input` / `gum choose` / `gum confirm`
7. **Replace raw output** (`printf` for headers/status) with wrapper functions
8. **Wrap slow operations** with `_spin`
9. **Style help/usage** with `gum format` or `glow`
10. **Validate**: Run `bash -n` and `shellcheck --severity=style` on the result

## Freedom to Deviate

The wrapper pattern above is a starting point, not a straitjacket. Each script has its own workflow. Consider:

- **`gum table`** for scripts that display inventories, status matrices, or config summaries
- **`gum filter`** for scripts with many options (fuzzy search is better than a long `gum choose` list)
- **`gum pager`** for scripts that dump long logs or diffs
- **`gum write`** for scripts that accept multiline input (commit messages, notes)
- **`glow`** for scripts with rich help docs or README-style output
- **Custom color schemes** — the 212 (magenta) / 76 (green) / 196 (red) / 244 (gray) palette is the default, but scripts with a different identity can use different accent colors
- **Different box styles** — `--border double`, `--border thick`, `--border hidden` depending on visual hierarchy
- **Nested layouts** — `gum join --vertical` / `--horizontal` for dashboard-style output

When deviating, document *why* in a code comment so future maintainers understand the choice.

## Checklist

- [ ] `HAS_GUM` detection present (with TTY check)
- [ ] All gum calls have plain-text fallbacks
- [ ] `-y` / `FORCE` / non-interactive flags bypass all prompts
- [ ] Error messages follow the warn + tip pattern
- [ ] Section headers use consistent `"Name: detail"` format
- [ ] Slow operations wrapped with `_spin`
- [ ] `bash -n` passes
- [ ] `shellcheck --severity=style` passes
- [ ] Piped output degrades gracefully (`script | cat` produces readable plain text)

#!/usr/bin/env bats
# Tests for ai-doctor: one row per source with what it adds and when it was
# last used, the changes the menu makes, the log, and --reset, run against a
# scratch home with fixture config and a fake claude command.
# shellcheck disable=SC2088 # "~/" is literal display text in expected output

load test_helper

AI_DOCTOR="${PROJECT_ROOT}/stow/tools/.local/bin/ai-doctor"

setup() {
    setup_tmpdir
    local python uv
    python="$(command -v python3 || true)"
    [[ -n "${python}" ]] || skip "python3 is required"
    "${python}" -c 'import sys; sys.exit(sys.version_info < (3, 11))' || skip "python3 3.11+ is required"
    uv="$(command -v uv || true)"
    [[ -n "${uv}" ]] || skip "uv is required"
    # Only uv and python3 on PATH, and AI_DOCTOR_CLAUDE and AI_DOCTOR_CODEX
    # empty, so no real claude or codex command is ever run; a test that
    # wants one installs fake_claude.
    mkdir -p "${TEST_TMPDIR}/bin"
    ln -s "${python}" "${TEST_TMPDIR}/bin/python3"
    ln -s "${uv}" "${TEST_TMPDIR}/bin/uv"
    export PATH="${TEST_TMPDIR}/bin:/usr/bin:/bin"
    export UV_PYTHON="${TEST_TMPDIR}/bin/python3" UV_NO_PYTHON_DOWNLOADS=1 UV_NO_CONFIG=1
    export UV_CACHE_DIR="${BATS_FILE_TMPDIR}/uv-cache"
    export AI_DOCTOR_CLAUDE="" AI_DOCTOR_CODEX=""

    export HOME="${TEST_TMPDIR}/home"
    export XDG_CONFIG_HOME="${HOME}/.config"
    export XDG_STATE_HOME="${HOME}/.local/state"
    unset NO_COLOR DOTFILES_PROMPT
    STATE="${XDG_STATE_HOME}/ai-doctor"
    PROJECT="${TEST_TMPDIR}/project"
    mkdir -p "${PROJECT}" "${HOME}/.claude" "${HOME}/.agents/skills"
    PROJECT="$(cd "${PROJECT}" && pwd -P)"
    ln -s "${HOME}/.agents/skills" "${HOME}/.claude/skills"
    add_skill core commit-work
    add_skill vault obsidian-vault
    used commit-work 1
    used obsidian-vault 2

    # skills-add from the agents checkout, logging what it was asked to do.
    mkdir -p "${XDG_CONFIG_HOME}/agents/scripts"
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/skills-add.log"\n' "${TEST_TMPDIR}" > "${XDG_CONFIG_HOME}/agents/scripts/skills-add"
    chmod +x "${XDG_CONFIG_HOME}/agents/scripts/skills-add"
}

teardown() {
    teardown_tmpdir
}

ai_doctor() {
    (cd "${PROJECT}" && python3 "${AI_DOCTOR}" --no-color "$@")
}

# add_skill BUNDLE NAME: a skill in the agents checkout, linked the way skills-add leaves it.
add_skill() {
    local dir="${XDG_CONFIG_HOME}/agents/skills/$1/$2"
    mkdir -p "${dir}"
    printf -- '---\nname: %s\ndescription: >\n  Does %s things\n  across two lines.\nlicense: MIT\n---\nBody text that is not loaded.\n' "$2" "$2" > "${dir}/SKILL.md"
    ln -s "${dir}" "${HOME}/.agents/skills/$2"
}

# used KEY DAYS_AGO [mcp]: a transcript line in which the model ran skill KEY,
# or a tool of MCP server KEY, that many days ago.
used() {
    mkdir -p "${HOME}/.claude/projects/p"
    python3 - "$1" "$2" "${3:-skill}" "${HOME}/.claude/projects/p/t.jsonl" <<'PY'
import datetime, json, sys
key, days, kind, path = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
when = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%S.000Z")
tool = {"type": "tool_use", "name": "Skill", "input": {"skill": key}} if kind == "skill" else \
    {"type": "tool_use", "name": f"mcp__{key}__list", "input": {}}
with open(path, "a") as handle:
    handle.write(json.dumps({"type": "assistant", "timestamp": when, "message": {"content": [tool]}}) + "\n")
PY
}

# synced_plugin NAME SKILL...: a plugin synced from claude.ai with those skills.
synced_plugin() {
    local name="$1" root="${HOME}/.claude/plugins/synced/org/$1"
    shift
    mkdir -p "${root}/.claude-plugin"
    printf '{"name": "%s"}\n' "${name}" > "${root}/.claude-plugin/plugin.json"
    for skill in "$@"; do
        mkdir -p "${root}/skills/${skill}"
        printf -- '---\nname: %s\ndescription: Skill %s\n---\n' "${skill}" "${skill}" > "${root}/skills/${skill}/SKILL.md"
    done
}

# fake_claude: a claude command that answers /context from context.md, turns
# plugins on and off in settings.json as the real one does, and logs the rest.
fake_claude() {
    cat > "${TEST_TMPDIR}/bin/claude" <<SH
#!/bin/sh
if [ "\$1" = "-p" ] && [ "\$2" = "/context" ]; then
    cat "${TEST_TMPDIR}/context.md"
    exit
fi
printf '%s\n' "\$*" >> "${TEST_TMPDIR}/claude.log"
if [ "\$1" = "plugin" ]; then
    python3 -c 'import json, os, sys
p = os.path.expanduser("~/.claude/settings.json")
d = json.load(open(p)) if os.path.exists(p) else {}
plugins = d.setdefault("enabledPlugins", {})
if sys.argv[1] == "disable": plugins[sys.argv[2]] = False
else: plugins.pop(sys.argv[2], None)
json.dump(d, open(p, "w"))' "\$2" "\$3"
fi
SH
    chmod +x "${TEST_TMPDIR}/bin/claude"
    export AI_DOCTOR_CLAUDE="${TEST_TMPDIR}/bin/claude"
    cat > "${TEST_TMPDIR}/context.md" <<'MD'
## Context Usage

### Estimated usage by category

| Category | Tokens | Percentage |
|----------|--------|------------|
| System prompt | 4k | 0.4% |
| System tools | 2k | 0.2% |
| MCP tools (deferred) | 9k | 0.9% |
| Skills | 4k | 0.4% |
| Free space | 900k | 90% |

### Skills

| Skill | Source | Tokens |
|-------|--------|--------|
| commit-work | User | ~110 |
| obsidian-vault | User | ~90 |
| idle:a | Plugin (idle) | ~700 |
| simplify | Built-in | ~1.0k |
MD
}

on_terminal() {
    if [[ "$(uname -s)" == Darwin ]]; then
        run bash -c 'cd "$1" && shift && printf "$0" | script -q /dev/null "$@"' "$1" "${PROJECT}" python3 "${AI_DOCTOR}" --no-color
    else
        run bash -c 'cd "$1" && shift && printf "$0" | script -qec "$*" /dev/null' "$1" "${PROJECT}" python3 "${AI_DOCTOR}" --no-color
    fi
}

settings_value() {
    python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print(d.get(sys.argv[2]))' "${HOME}/.claude/settings.json" "$1"
}

@test "ai-doctor: a setup in use prints the summary and nothing to turn off" {
    run ai_doctor
    assert_success
    assert_line --index 0 --regexp "^ai-doctor: claude · ~[0-9]+ tokens of yours before you type \(estimated; no claude command to measure Claude's defaults\) · / menu: 2 of yours$"
    assert_output --partial "Nothing to turn off. 4 sources in use; -v lists them."
    refute_output --partial "--fix"
    # Each run keeps the dates it found, for when the transcripts are gone.
    run python3 -c 'import json, sys; print(sorted(json.load(open(sys.argv[1]))["last"]))' "${STATE}/usage.json"
    assert_output "['skill:commit-work', 'skill:obsidian-vault']"
}

@test "ai-doctor: -v lists kept rows, instructions, agents, and what is already off" {
    printf '# Rules\n' > "${HOME}/.claude/CLAUDE.md"
    mkdir -p "${HOME}/.claude/agents"
    printf -- '---\nname: lead\ndescription: Runs the team\n---\n' > "${HOME}/.claude/agents/lead.md"
    synced_plugin gone x
    printf '{"enabledPlugins": {"gone@synced": false}}\n' > "${HOME}/.claude/settings.json"
    run ai_doctor -v
    assert_success
    assert_output --partial "~/.claude/CLAUDE.md: ~2 tokens"
    assert_output --regexp "~/.claude/agents: 1 agent, ~[0-9]+ tokens: lead"
    assert_output --partial "plugin gone (claude.ai): claude plugin enable gone@synced"
    assert_output --regexp "keep +1 +[0-9]+ +1d ago \(1\) +bundle core: 1 skill"
    assert_output --partial "1 already off"
    refute_output --partial "Body text"
}

@test "ai-doctor: a plugin unused for 30 days starts on off; one in use, protected, or turned off does not" {
    synced_plugin idle a b
    synced_plugin busy c
    synced_plugin old d
    synced_plugin loved e
    synced_plugin gone f
    used busy:c 3
    used old:d 40
    printf '{"pluginUsage": {"loved@synced": {"usageCount": 4}}}\n' > "${HOME}/.claude.json"
    printf '{"enabledPlugins": {"gone@synced": false}}\n' > "${HOME}/.claude/settings.json"
    run ai_doctor
    assert_success
    assert_output --regexp "1  off +2 +[0-9]+ +never +plugin idle \(from claude.ai\): 2 skills"
    assert_output --regexp "off +1 +[0-9]+ +40d ago \(1\) +plugin old"
    refute_output --partial "plugin busy"
    refute_output --partial "plugin loved"
    refute_output --partial "plugin gone"
    assert_output --partial "· / menu: 7 of yours · 1 already off"
    assert_output --partial "Run ai-doctor --fix to choose, or ai-doctor --yes to turn off what is preselected."
}

@test "ai-doctor: --yes turns plugins off in settings.json without claude, logs it, and --reset turns them back on" {
    synced_plugin idle a
    run ai_doctor --yes
    assert_success
    assert_output --partial "claude plugin disable idle@synced: done"
    assert_output --partial "Done: 1 changed. ai-doctor --reset undoes them."
    run settings_value enabledPlugins
    assert_output "{'idle@synced': False}"
    run grep -c '"category": "plugins"' "${STATE}/actions.jsonl"
    assert_output 1

    run ai_doctor
    assert_output --partial "1 already off"
    assert_output --regexp "keep +- +- +- +reset plugins: undo 1 change by ai-doctor"

    run ai_doctor --reset plugins
    assert_success
    assert_output --partial "claude plugin enable idle@synced: done"
    run settings_value enabledPlugins
    assert_output "{}"
    run ai_doctor --reset
    assert_output --partial "Nothing to reset."
}

@test "ai-doctor: with claude it measures with /context and uses claude plugin disable and enable" {
    fake_claude
    synced_plugin idle a
    run ai_doctor
    assert_line --index 0 --partial "before you type ~10.0k tokens: yours ~3.0k (30%), Claude's defaults ~7.0k (70%)"
    assert_output --regexp "off +1 +700 +never +plugin idle"

    run ai_doctor --fix <<< "off 1"
    assert_success
    assert_output --partial "claude plugin disable idle@synced: done"
    run cat "${TEST_TMPDIR}/claude.log"
    assert_output "plugin disable idle@synced"

    run ai_doctor --reset plugins
    assert_output --partial "claude plugin enable idle@synced: done"
    run tail -1 "${TEST_TMPDIR}/claude.log"
    assert_output "plugin enable idle@synced"
}

@test "ai-doctor: a dormant bundle drops with skill-drop, a dormant skill gets skillOverrides, and reset undoes both" {
    add_skill design figma
    add_skill core grill-me
    run ai_doctor
    assert_output --regexp "off +1 +[0-9]+ +never +bundle design: 1 skill"
    assert_output --regexp "keep +2 +[0-9]+ +1d ago \(1\) +bundle core: 2 skills"
    assert_output --regexp "off +1 +[0-9]+ +never +  skill grill-me"

    run ai_doctor --fix <<< "keep 1-9 off 1 menu 4"
    assert_success
    assert_output --partial "skill-drop design: unlinks it for Claude Code: done"
    assert_output --partial 'skillOverrides "grill-me": "user-invocable-only": out of context, still /grill-me: done'
    run cat "${TEST_TMPDIR}/skills-add.log"
    assert_output "-D design"
    run settings_value skillOverrides
    assert_output "{'grill-me': 'user-invocable-only'}"

    run ai_doctor --reset
    assert_success
    assert_output --partial 'skillOverrides "grill-me" removed: done'
    assert_output --partial "skills-add design: done"
    run tail -1 "${TEST_TMPDIR}/skills-add.log"
    assert_output "design"
    run settings_value skillOverrides
    assert_output "None"
}

@test "ai-doctor: rows sit under their tool, and a shared skill says an override reaches Claude Code only" {
    mkdir -p "${HOME}/.cursor" "${HOME}/.codex"
    ln -s "${HOME}/.agents/skills" "${HOME}/.cursor/skills"
    printf '[mcp_servers.web]\nurl = "https://example.com"\n' > "${HOME}/.codex/config.toml"
    add_skill core grill-me
    synced_plugin idle a
    # claude.ai leaves an older copy beside the current one; only one row shows.
    cp -R "${HOME}/.claude/plugins/synced/org/idle" "${HOME}/.claude/plugins/synced/org/idle~g2"
    run ai_doctor -v
    assert_output --partial "  Claude Code: the terminal and the desktop app's Code tab"
    assert_output --partial "  Skills folder ~/.agents/skills, loaded by Claude Code, Codex and Cursor"
    assert_output --partial "  Codex"
    assert_equal "$(grep -c 'plugin idle' <<< "${output}")" 1
    run ai_doctor --app claude --app cursor --fix <<< "keep 1-99 menu 3"
    assert_output --partial 'still /grill-me; Claude Code only, Cursor still loads it: done'
}

@test "ai-doctor: a claude.ai skill is a row turned off with skillOverrides, then counted as off" {
    local synced="${HOME}/.agents/skills/synced/org/docx"
    mkdir -p "${synced}"
    printf -- '---\nname: docx\ndescription: Word files\n---\n' > "${synced}/SKILL.md"
    run ai_doctor
    assert_output --regexp "off +1 +[0-9]+ +never +skill docx \(from claude.ai\)"
    run ai_doctor --yes
    assert_output --partial 'skillOverrides "docx": "off": done'
    run ai_doctor -v
    assert_output --partial "claude.ai skill docx: ai-doctor --reset skills"
    refute_output --partial "skill docx (from claude.ai)"
}

@test "ai-doctor: a dormant MCP server is removed with its config kept, and reset puts it back" {
    printf '#!/bin/sh\n' > "${TEST_TMPDIR}/bin/good-mcp"
    chmod +x "${TEST_TMPDIR}/bin/good-mcp"
    cat > "${HOME}/.claude.json" <<JSON
{"mcpServers": {"busy": {"command": "good-mcp"}, "idle": {"command": "good-mcp", "args": ["-x"]},
 "lastfm": {"type": "http", "url": "https://example.com/lastfm"}, "gone": {"command": "no-such-mcp"}},
 "projects": {"${PROJECT}": {"mcpServers": {"local": {"command": "/missing/python"}}}}}
JSON
    printf '{"lastfm": {}}\n' > "${HOME}/.claude/mcp-needs-auth-cache.json"
    used busy 1 mcp
    cp "${HOME}/.claude.json" "${TEST_TMPDIR}/before.json"
    run ai_doctor
    assert_failure 1
    assert_output --partial "MCP server lastfm: waits for a sign-in"
    assert_output --partial "MCP server gone: can't start, no-such-mcp is not installed"
    assert_output --partial "MCP server local: can't start, /missing/python is missing"
    refute_output --partial "server busy"

    run ai_doctor --yes
    assert_success
    assert_output --partial 'delete "idle" from ~/.claude.json: done'
    assert_output --partial 'delete "local" from ~/.claude.json: done'
    run python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print(sorted(d["mcpServers"]), d["projects"][sys.argv[2]]["mcpServers"])' "${HOME}/.claude.json" "${PROJECT}"
    assert_output "['busy'] {}"
    assert test -n "$(find "${STATE}/backups" -name '*claude.json')"

    run ai_doctor --reset servers
    assert_success
    run python3 -c 'import json, sys; a, b = (json.load(open(p)) for p in sys.argv[1:]); print(a == b)' "${HOME}/.claude.json" "${TEST_TMPDIR}/before.json"
    assert_output "True"
}

@test "ai-doctor: Codex and Cursor servers start on keep with no date, and a written-in token is a health line" {
    mkdir -p "${HOME}/.codex" "${HOME}/.cursor"
    printf 'model = "x"\n\n[mcp_servers.web]\nurl = "https://example.com"\n\n[mcp_servers.web.env]\nA = "1"\n' > "${HOME}/.codex/config.toml"
    printf '{"mcpServers": {"gh": {"url": "https://example.com", "headers": {"Authorization": "Bearer ghp_abc"}}}}\n' > "${HOME}/.cursor/mcp.json"
    run ai_doctor -v
    assert_failure 1
    assert_output --regexp "keep +- +- +- +MCP server web"
    assert_output --regexp "keep +- +- +- +MCP server gh"
    assert_output --partial "health: Cursor's gh MCP server has a token written into ~/.cursor/mcp.json (Authorization)"
    refute_output --partial "ghp_abc"

    run ai_doctor --app codex --fix <<< "keep 1-9 off 5"
    assert_output --partial "delete [mcp_servers.web] from ~/.codex/config.toml: done"
    run cat "${HOME}/.codex/config.toml"
    assert_output 'model = "x"'
    run ai_doctor --reset servers
    run python3 -c 'import tomllib, sys; print(tomllib.load(open(sys.argv[1], "rb")))' "${HOME}/.codex/config.toml"
    assert_output "{'model': 'x', 'mcp_servers': {'web': {'url': 'https://example.com', 'env': {'A': '1'}}}}"
}

@test "ai-doctor: a Codex-only skill moves to the archive and back, and a broken link is deleted and relinked" {
    mkdir -p "${HOME}/.codex/skills/shot"
    printf -- '---\nname: shot\ndescription: Screens\n---\n' > "${HOME}/.codex/skills/shot/SKILL.md"
    ln -s "${TEST_TMPDIR}/gone" "${HOME}/.agents/skills/gone"
    run ai_doctor -v
    assert_failure 1
    assert_output --regexp "off +- +- +never +broken skill link ~/.agents/skills/gone"
    assert_output --regexp "keep +1 +[0-9]+ +- +skill shot"

    run ai_doctor --fix <<< "off 1-9"
    assert_success
    refute test -e "${HOME}/.codex/skills/shot"
    refute test -L "${HOME}/.agents/skills/gone"
    run ai_doctor --reset skills
    assert_success
    assert test -f "${HOME}/.codex/skills/shot/SKILL.md"
    assert_equal "$(readlink "${HOME}/.agents/skills/gone")" "${TEST_TMPDIR}/gone"
}

@test "ai-doctor: the menu line takes words and ranges, refuses what a row can't do, and changes nothing when unsure" {
    synced_plugin idle a
    run ai_doctor --fix <<< "menu 1"
    assert_output --partial "Row 1 can't menu; it offers keep / off; nothing changed"
    run ai_doctor --fix <<< "off 99"
    assert_output --partial "No row 99; nothing changed"
    run ai_doctor --fix <<< "off 1 bogus"
    assert_output --partial "Not understood: bogus; nothing changed"
    run ai_doctor --fix <<< "none"
    assert_output --partial "Nothing changed."
    refute test -e "${HOME}/.claude/settings.json"

    run ai_doctor --fix < /dev/null
    assert_output --partial "Nothing changed: ai-doctor asks before changing anything, and stdin is closed."
    run ai_doctor --dry-run
    assert_output --partial "would: claude plugin disable idle@synced"
    assert_output --partial "Nothing changed (--dry-run)."
    refute test -e "${HOME}/.claude/settings.json"
    refute test -e "${STATE}/actions.jsonl"
}

@test "ai-doctor: on a terminal q changes nothing and Enter applies the preselected rows" {
    command -v script >/dev/null || skip "script is required for a terminal"
    synced_plugin idle a
    on_terminal q
    assert_output --partial "Keep or turn off each source"
    assert_output --partial "Nothing changed."
    refute test -e "${HOME}/.claude/settings.json"

    on_terminal 'k\n'
    assert_output --partial "Nothing changed."
    refute test -e "${HOME}/.claude/settings.json"
    on_terminal '\n'
    assert_output --partial "claude plugin disable idle@synced: done"
    run settings_value enabledPlugins
    assert_output "{'idle@synced': False}"
}

@test "ai-doctor: help, bad usage, and a home with no AI apps" {
    run ai_doctor --help
    assert_success
    assert_output --partial "ai-doctor --reset [WHAT]"
    run ai_doctor --app vim
    assert_failure 2
    run ai_doctor --reset everything
    assert_failure 2

    rm -rf "${HOME:?}/.claude"
    run ai_doctor
    assert_success
    assert_output "ai-doctor: no Claude Code, Codex, or Cursor config in this home directory"
}

@test "ai-doctor: without --fix it changes nothing but its own usage record, run through its stow link" {
    synced_plugin idle a
    ln -s "${TEST_TMPDIR}/gone" "${HOME}/.agents/skills/gone"
    ln -s "${AI_DOCTOR}" "${TEST_TMPDIR}/ai-doctor"
    local before after
    before="$(find "${HOME}" -mindepth 1 -not -path "${HOME}/.local*" -exec ls -ld {} + | sort)"
    run "${TEST_TMPDIR}/ai-doctor" --no-color -v
    assert_failure 1
    after="$(find "${HOME}" -mindepth 1 -not -path "${HOME}/.local*" -exec ls -ld {} + | sort)"
    assert_equal "${after}" "${before}"
    assert test -f "${STATE}/usage.json"
    refute test -e "${STATE}/actions.jsonl"
}

#!/usr/bin/env bats
# Tests for ai-doctor: the short list of what to fix or trim in Claude Code,
# Codex, and Cursor, and --fix, run against a scratch home with fixture config.
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
    # Only uv and python3 on PATH, so no real claude or codex command is ever
    # run; ai-doctor's shebang is `uv run --script`, held to this python3 and
    # kept offline, with uv's cache shared by the file's tests.
    mkdir -p "${TEST_TMPDIR}/bin"
    ln -s "${python}" "${TEST_TMPDIR}/bin/python3"
    ln -s "${uv}" "${TEST_TMPDIR}/bin/uv"
    export PATH="${TEST_TMPDIR}/bin:/usr/bin:/bin"
    export UV_PYTHON="${TEST_TMPDIR}/bin/python3" UV_NO_PYTHON_DOWNLOADS=1 UV_NO_CONFIG=1
    export UV_CACHE_DIR="${BATS_FILE_TMPDIR}/uv-cache"

    export HOME="${TEST_TMPDIR}/home"
    export XDG_CONFIG_HOME="${HOME}/.config"
    export XDG_STATE_HOME="${HOME}/.local/state"
    export DOTFILES_DIR="${TEST_TMPDIR}/dotfiles"
    unset DOTFILES_PERSONA NO_COLOR
    PROJECT="${TEST_TMPDIR}/project"
    mkdir -p "${PROJECT}" "${HOME}/.claude" "${HOME}/.agents/skills" "${DOTFILES_DIR}/personas" "${XDG_STATE_HOME}/dotfiles"
    PROJECT="$(cd "${PROJECT}" && pwd -P)"
    ln -s "${HOME}/.agents/skills" "${HOME}/.claude/skills"
    printf 'skills=core vault\n' > "${DOTFILES_DIR}/personas/home"
    printf 'home\n' > "${XDG_STATE_HOME}/dotfiles/persona"
    add_skill core commit-work
    add_skill vault obsidian-vault

    # skills-add from the agents checkout, logging what it was asked to do.
    mkdir -p "${XDG_CONFIG_HOME}/agents/scripts"
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/skills-add.log"\n' "${TEST_TMPDIR}" > "${XDG_CONFIG_HOME}/agents/scripts/skills-add"
    chmod +x "${XDG_CONFIG_HOME}/agents/scripts/skills-add"
}

teardown() {
    teardown_tmpdir
}

# add_skill BUNDLE NAME: a skill in the agents checkout, linked the way skills-add leaves it.
add_skill() {
    local dir="${XDG_CONFIG_HOME}/agents/skills/$1/$2"
    mkdir -p "${dir}"
    printf -- '---\nname: %s\ndescription: >\n  Does %s things\n  across two lines.\nlicense: MIT\n---\nBody text that is not loaded.\n' "$2" "$2" > "${dir}/SKILL.md"
    ln -s "${dir}" "${HOME}/.agents/skills/$2"
}

ai_doctor() {
    (cd "${PROJECT}" && python3 "${AI_DOCTOR}" --no-color "$@")
}

# broken_servers: Claude servers that cannot start, and two that can.
broken_servers() {
    printf '#!/bin/sh\n' > "${TEST_TMPDIR}/bin/good-mcp"
    chmod +x "${TEST_TMPDIR}/bin/good-mcp"
    cat > "${HOME}/.claude.json" <<JSON
{"numStartups": 7,
 "mcpServers": {
  "good": {"command": "good-mcp", "args": ["${TEST_TMPDIR}/bin"]},
  "nocmd": {"command": "no-such-mcp-command"},
  "noarg": {"command": "good-mcp", "args": ["--project", "${TEST_TMPDIR}/gone", "${TEST_TMPDIR}/gone/server.py"]},
  "web": {"type": "http", "url": "https://example.com/mcp"}
 },
 "projects": {"${PROJECT}": {"mcpServers": {"local": {"command": "/missing/python"}}}}}
JSON
}

@test "ai-doctor: a tidy setup prints one line and nothing to do" {
    printf '# Rules\n' > "${HOME}/.claude/CLAUDE.md"
    run ai_doctor
    assert_success
    assert_line --index 0 --regexp "^ai-doctor: claude · 2 skills \(~[0-9]+ tokens\) · 0 plugins$"
    assert_line --index 1 "  Nothing to do."
    refute_output --partial "ok  "
    refute_output --partial "--fix"
}

@test "ai-doctor: -v lists everything checked, sizing only skill names and descriptions" {
    printf '# Rules\n' > "${HOME}/.claude/CLAUDE.md"
    run ai_doctor -v
    assert_success
    assert_output --partial "Claude global ~/.claude/CLAUDE.md: ~2 tokens"
    assert_output --partial "~/.claude/skills -> ~/.agents/skills: 2 skills"
    # "commit-work Does commit-work things across two lines." is 54 characters.
    assert_output --regexp "core +1 skills +~14 tokens"
    assert_output --partial "linked bundles match the home persona"
    assert_output --partial "Nothing to do."
    refute_output --partial "Body text"
}

@test "ai-doctor: bundles beyond the persona are a trim, missing ones a fix, and --fix runs skills-add" {
    add_skill cloud aws-solution-architect
    add_skill data senior-data-engineer
    rm "${HOME}/.agents/skills/obsidian-vault"
    run ai_doctor
    assert_failure 1
    assert_output --partial "fix   1 skill bundle the home persona asks for are not linked"
    assert_output --partial "skills-add vault  [auto]"
    assert_output --regexp "trim  2 skill bundles beyond the home persona cost ~[0-9]+ tokens a session"
    assert_output --partial "skill-drop cloud data  [auto]"
    assert_output --partial "Run ai-doctor --fix to do 1, 2 (asks before each)"
    refute test -e "${TEST_TMPDIR}/skills-add.log"

    run ai_doctor --fix --yes
    assert_success
    assert_equal "$(cat "${TEST_TMPDIR}/skills-add.log")" "$(printf 'vault\n-D cloud data')"
}

@test "ai-doctor: skips the persona comparison without a dotfiles persona" {
    rm "${XDG_STATE_HOME}/dotfiles/persona"
    add_skill cloud aws-solution-architect
    run ai_doctor
    assert_success
    assert_output --partial "Nothing to do."
}

@test "ai-doctor: --fix deletes a broken skill link" {
    ln -s "${TEST_TMPDIR}/gone" "${HOME}/.agents/skills/gone"
    run ai_doctor
    assert_failure 1
    assert_output --partial "fix   Skill link ~/.agents/skills/gone is broken"
    assert_output --partial "rm ~/.agents/skills/gone  [auto]"

    run ai_doctor --fix --yes
    assert_success
    refute test -L "${HOME}/.agents/skills/gone"
    assert test -L "${HOME}/.agents/skills/commit-work"
}

@test "ai-doctor: lists Claude servers that can't start, and --fix removes them with a backup" {
    broken_servers
    run ai_doctor
    assert_failure 1
    assert_output --partial "Claude's nocmd MCP server can't start: no-such-mcp-command is not installed"
    assert_output --partial "claude mcp remove nocmd -s user  [auto]"
    # A missing folder is reported, not every file under it.
    assert_output --partial "Claude's noarg MCP server can't start: ${TEST_TMPDIR}/gone is missing"
    assert_output --partial "claude mcp remove local -s local  [auto]"
    refute_output --partial "good"
    refute_output --partial "web"

    run ai_doctor --fix --yes
    assert_success
    run python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print(sorted(d["mcpServers"]), d["projects"][sys.argv[2]]["mcpServers"], d["numStartups"])' "${HOME}/.claude.json" "${PROJECT}"
    assert_output "['good', 'web'] {} 7"
    run grep -rl '"nocmd"' "${XDG_STATE_HOME}/ai-doctor"
    assert_success

    run ai_doctor
    assert_success
}

@test "ai-doctor: --fix asks before each fix, and no or closed stdin changes nothing" {
    broken_servers
    cp "${HOME}/.claude.json" "${TEST_TMPDIR}/before.json"

    run ai_doctor --fix < /dev/null
    assert_failure 1
    assert_output --partial "--fix asks before each fix and needs a terminal"
    assert_equal "$(cat "${HOME}/.claude.json")" "$(cat "${TEST_TMPDIR}/before.json")"
    refute test -e "${XDG_STATE_HOME}/ai-doctor"

    command -v script >/dev/null || skip "script is required for a terminal"
    if [[ "$(uname -s)" == Darwin ]]; then
        run bash -c 'cd "$1" && shift && printf "n\nn\nn\n" | script -q /dev/null "$@"' _ "${PROJECT}" python3 "${AI_DOCTOR}" --no-color --fix
    else
        run bash -c 'cd "$1" && shift && printf "n\nn\nn\n" | script -qec "$*" /dev/null' _ "${PROJECT}" python3 "${AI_DOCTOR}" --no-color --fix
    fi
    assert_output --partial "claude mcp remove nocmd -s user? [y/N]"
    assert_equal "$(cat "${HOME}/.claude.json")" "$(cat "${TEST_TMPDIR}/before.json")"
}

@test "ai-doctor: a token in a config is a fix that never prints it, and --fix repairs the URL and permissions" {
    mkdir -p "${HOME}/.cursor"
    printf '{"mcpServers": {"GitHub": {"command": "https://api.example.com/mcp/", "headers": {"Authorization": "Bearer github_pat_FAKE123"}}, "ok": {"url": "http://127.0.0.1:1/mcp", "headers": {"Authorization": "Bearer ${TOKEN}"}}}}\n' > "${HOME}/.cursor/mcp.json"
    chmod 644 "${HOME}/.cursor/mcp.json"
    run ai_doctor --app cursor
    assert_failure 1
    assert_output --partial "Cursor's GitHub MCP server can't start: its URL is in \"command\""
    assert_output --partial "Cursor's GitHub MCP server has a token written into ~/.cursor/mcp.json, and other users can read the file"
    assert_output --partial "chmod 600 ~/.cursor/mcp.json  [auto]"
    assert_output --partial 'rotate it, set headers.Authorization to "Bearer ${env:MCP_TOKEN}"'
    refute_output --partial "github_pat_FAKE123"
    refute_output --partial "ok MCP server"

    run ai_doctor --app cursor --fix --yes
    # The token still has to be rotated by hand.
    assert_failure 1
    run python3 -c 'import json, os, sys; print(json.load(open(sys.argv[1]))["mcpServers"]["GitHub"].get("url"), oct(os.stat(sys.argv[1]).st_mode & 0o777))' "${HOME}/.cursor/mcp.json"
    assert_output "https://api.example.com/mcp/ 0o600"
}

@test "ai-doctor: reads Codex servers, skips turned-off ones, and --fix removes a table and its sub-tables" {
    python3 -c 'import tomllib' 2>/dev/null || skip "needs Python 3.11"
    mkdir -p "${HOME}/.codex"
    printf 'model = "x"\n\n[mcp_servers.gone]\ncommand = "/missing/node"\n\n[mcp_servers.gone.env]\nA = "1"\n\n[mcp_servers.off]\ncommand = "/missing/off"\nenabled = false\n\n[mcp_servers.web]\nurl = "https://example.com/mcp"\n' > "${HOME}/.codex/config.toml"
    run ai_doctor --app codex
    assert_failure 1
    assert_output --partial "Codex's gone MCP server can't start: /missing/node is missing"
    assert_output --partial "delete [mcp_servers.gone] from ~/.codex/config.toml  [auto]"
    refute_output --partial "off"

    run ai_doctor --app codex --fix --yes
    assert_success
    run cat "${HOME}/.codex/config.toml"
    refute_output --partial "gone"
    assert_output --partial 'model = "x"'
    assert_output --partial "[mcp_servers.off]"
    assert_output --partial "[mcp_servers.web]"
}

@test "ai-doctor: a plugin installed and synced is a trim --fix removes, and sign-in waits are one trim" {
    local installed="${HOME}/.claude/plugins/cache/cf/cloudflare/1.0.0" synced="${HOME}/.claude/plugins/synced/org/abc"
    mkdir -p "${installed}/skills/deploy" "${synced}/.claude-plugin" "${synced}/skills/deploy" "${HOME}/.claude/plugins/synced/org/eng/.claude-plugin" "${TEST_TMPDIR}/elsewhere"
    touch "${installed}/skills/deploy/SKILL.md" "${synced}/skills/deploy/SKILL.md"
    printf '{"name": "cloudflare"}\n' > "${synced}/.claude-plugin/plugin.json"
    printf '{"mcpServers": {"cloudflare": {"type": "http", "url": "https://example.com/mcp"}}}\n' > "${installed}/.mcp.json"
    cp "${installed}/.mcp.json" "${synced}/.mcp.json"
    printf '{"name": "engineering"}\n' > "${HOME}/.claude/plugins/synced/org/eng/.claude-plugin/plugin.json"
    printf '{"mcpServers": {"slack": {"type": "http", "url": "https://example.com/slack"}, "gmail": {"type": "http", "url": ""}}}\n' > "${HOME}/.claude/plugins/synced/org/eng/.mcp.json"
    printf '{"version": 2, "plugins": {"cloudflare@cloudflare": [{"installPath": "%s"}], "other@m": [{"installPath": "%s"}]}}\n' "${installed}" "${TEST_TMPDIR}/elsewhere" > "${HOME}/.claude/plugins/installed_plugins.json"
    printf '{"plugin:cloudflare:cloudflare": {}, "plugin:engineering:slack": {}}\n' > "${HOME}/.claude/mcp-needs-auth-cache.json"
    run ai_doctor
    assert_success
    assert_output --partial "· 4 plugins ·"
    assert_output --partial "trim  Plugin cloudflare loads twice: installed here and synced from claude.ai"
    assert_output --partial "claude plugin uninstall cloudflare@cloudflare  [auto]"
    assert_output --partial "trim  2 MCP servers from plugins wait for a sign-in"
    assert_output --partial "turn off the plugins you don't use in Claude's settings: cloudflare, engineering"
    refute_output --partial "gmail"

    run ai_doctor --fix --yes
    assert_success
    run python3 -c 'import json, sys; print(sorted(json.load(open(sys.argv[1]))["plugins"]))' "${HOME}/.claude/plugins/installed_plugins.json"
    assert_output "['other@m']"
    refute test -e "${HOME}/.claude/plugins/cache/cf"
    assert test -d "${synced}"
}

@test "ai-doctor: -v reports experimental flags and a default agent" {
    printf '{"agent": "lead", "env": {"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1", "CLAUDE_CODE_EXPERIMENTAL_OFF": "0"}}\n' > "${HOME}/.claude/settings.json"
    run ai_doctor
    refute_output --partial "EXPERIMENTAL"
    run ai_doctor -v
    assert_success
    assert_output --partial "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS is on"
    refute_output --partial "CLAUDE_CODE_EXPERIMENTAL_OFF"
    assert_output --partial "every session starts as the lead agent"
}

@test "ai-doctor: help, a bad app, and a home with no AI apps" {
    run ai_doctor --help
    assert_success
    assert_output --partial "ai-doctor --fix"

    run ai_doctor --app vim
    assert_failure 2

    rm -rf "${HOME:?}/.claude"
    run ai_doctor
    assert_success
    assert_output "ai-doctor: no Claude Code, Codex, or Cursor config in this home directory"
}

@test "ai-doctor: without --fix it changes nothing, run through its stow link" {
    broken_servers
    ln -s "${TEST_TMPDIR}/gone" "${HOME}/.agents/skills/gone"
    ln -s "${AI_DOCTOR}" "${TEST_TMPDIR}/ai-doctor"
    local before after
    before="$(find "${HOME}" -exec ls -ld {} + | sort)"
    run "${TEST_TMPDIR}/ai-doctor" --no-color -v
    assert_failure 1
    after="$(find "${HOME}" -exec ls -ld {} + | sort)"
    assert_equal "${after}" "${before}"
}

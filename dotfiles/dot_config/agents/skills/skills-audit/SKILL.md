---
name: skills-audit
description: Audit agent skills for compliance with the AgentSkills specification. Use when adding, modifying, or reviewing skills in the skills directory.
allowed-tools: Read Grep Glob WebFetch Edit
---

# Agent Skills Audit

Audit all skills in `~/.config/agents/skills/` against the AgentSkills open standard.

## Reference

Fetch the specification before auditing:

- Specification: https://agentskills.io/specification
- Overview: https://agentskills.io/home

## Audit Checklist

### 1. Directory Structure
- [ ] Skill lives in its own directory under the skills root
- [ ] Directory contains a `SKILL.md` file
- [ ] Optional subdirectories follow convention: `scripts/`, `references/`, `assets/`

### 2. Frontmatter
- [ ] YAML frontmatter is present between `---` delimiters
- [ ] `name` is present and valid:
  - 1-64 characters
  - Lowercase alphanumeric and hyphens only
  - No leading/trailing/consecutive hyphens
  - Matches the parent directory name
- [ ] `description` is present and valid:
  - 1-1024 characters
  - Describes what the skill does and when to use it
  - Includes keywords that help agents identify relevant tasks
- [ ] Optional fields use correct format if present:
  - `license`: string
  - `compatibility`: 1-500 characters
  - `metadata`: map of string keys to string values
  - `allowed-tools`: space-delimited list (not comma-separated)

### 3. Body Content
- [ ] Markdown body follows frontmatter
- [ ] Instructions are clear and actionable
- [ ] Total `SKILL.md` is under 500 lines
- [ ] Detailed reference material is split into separate files if needed

### 4. Progressive Disclosure
- [ ] Metadata (name + description) is concise enough for startup loading (~100 tokens)
- [ ] Full instructions are under ~5000 tokens
- [ ] Supplementary files (scripts, references, assets) are loaded on demand, not inlined

### 5. File References
- [ ] Internal references use relative paths from skill root
- [ ] References are one level deep (no deeply nested chains)

### 6. Consistency
- [ ] All skills in the directory follow the same structural conventions
- [ ] Heading hierarchy is consistent across skills
- [ ] Frontmatter fields are consistent (same fields used where applicable)

## Procedure

1. **Fetch spec**: Fetch https://agentskills.io/specification for the latest requirements.
2. **Discover skills**: Find all `SKILL.md` files under the skills root.
3. **Audit each skill**: Review against the checklist above.
4. **Report findings**: Group by category, not by skill. Note what passes and what doesn't.
5. **Propose fixes**: Present a numbered list of fixes for approval.
6. **Apply fixes**: Make approved changes.
7. **Verify**: Re-read changed files and confirm compliance.

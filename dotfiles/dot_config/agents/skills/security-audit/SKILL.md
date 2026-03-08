---
name: security-audit
description: Reviews code for security issues including injection vulnerabilities, auth flaws, and secrets in code.
allowed-tools: Read Grep Glob
---

# Security Audit

Review code for common security vulnerabilities and issues.

## Audit Checklist

### Injection Vulnerabilities
- SQL injection (unsanitized input in queries)
- Command injection (shell commands with user input)
- Remote code execution (`curl | bash` and similar patterns — flag unless using well-known upstream URLs over HTTPS)
- XSS (unescaped output in HTML/templates)
- Path traversal (user input in file paths)

### Authentication & Authorization
- Missing auth checks on sensitive endpoints
- Hardcoded credentials or API keys
- Weak session management
- Improper access control

### Secrets & Sensitive Data
- API keys, tokens, passwords in source code
- Credentials in configuration files
- Secrets in error messages or logs
- Sensitive data in URLs or query strings

### Data Handling
- Sensitive data logged or exposed in errors
- Missing input validation
- Insecure deserialization
- Improper error handling revealing internals

## Output Format

Report findings with:
1. **Location**: File and line number
2. **Issue**: What the vulnerability is
3. **Risk**: Severity (Critical/High/Medium/Low)
4. **Fix**: Recommended remediation

If no issues found, report "No security issues identified" with a brief summary of what was reviewed.

## Procedure

1. **Discover scope**: Identify files to review (changed files, specified directory, or full project).
2. **Read each file**: Review against the checklist above.
3. **Group findings**: Report issues by category, not by file.
4. **Propose fixes**: Present a numbered list of fixes for approval.
5. **Apply fixes**: Make approved changes.
6. **Verify**: Re-read changed files and confirm issues are resolved.

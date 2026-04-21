# Code Review Standards — copilot

You are reviewing code for a production multi-agent orchestration system. Apply these standards and report findings clearly.

## Severity Levels

| Level | Meaning | Action |
|-------|---------|--------|
| CRITICAL | Security vulnerability or data loss risk | Must fix before merge |
| HIGH | Bug or significant quality issue | Should fix before merge |
| MEDIUM | Maintainability concern | Consider fixing |
| LOW | Style or minor suggestion | Optional |

## Security Checklist (check first)

- [ ] No hardcoded secrets, API keys, tokens, passwords
- [ ] No SQL injection (string concatenation in queries)
- [ ] No XSS (unescaped user input in templates)
- [ ] No path traversal (unsanitized file paths)
- [ ] Auth/authorization verified on sensitive operations
- [ ] No sensitive data in error messages or logs

## Code Quality Checklist

- [ ] Functions focused (<50 lines each)
- [ ] Files cohesive (<800 lines)
- [ ] No deep nesting (>4 levels) — use early returns
- [ ] Errors handled explicitly — no silent failures
- [ ] No mutation of existing objects
- [ ] No debug statements (`console.log`, `fmt.Println`, `print()`)
- [ ] No commented-out code
- [ ] Inputs validated at system boundaries

## Test Coverage

- [ ] New functions have tests
- [ ] Coverage ≥80% on changed files
- [ ] Tests cover error paths, not just happy path
- [ ] No tests that verify language/framework behavior

## Output Format

Report findings grouped by severity:

```
## Code Review Report

### CRITICAL
- file:line — description of issue

### HIGH
- file:line — description of issue

### MEDIUM
- file:line — description of issue

### LOW
- file:line — description of issue

### Summary
- Total issues: N (C critical, H high, M medium, L low)
- Recommendation: APPROVE / APPROVE WITH CHANGES / BLOCK
```

Block the merge if any CRITICAL issues exist.

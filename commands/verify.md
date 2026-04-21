---
description: Run a full verification loop after implementation — build, types, lint, tests (≥80% coverage), security scan, diff review. Reports READY or NOT READY for next pipeline step.
---

Run the verification loop on the current working state.

Follow the `everything-claude-code:verification-loop` skill — run each phase in order and stop on FAIL:

**Phase 1 — Build**
Run the project build command. If it fails, STOP and fix before continuing.

**Phase 2 — Types**
Run type checker (tsc --noEmit, pyright, etc.). Fix critical type errors.

**Phase 3 — Lint**
Run linter. Fix errors; document suppressions if warnings are intentional.

**Phase 4 — Tests**
Run test suite with coverage. Target ≥80%. If below, report which modules are uncovered.

**Phase 5 — Security scan**
Check for hardcoded secrets, API keys, console.log/debug statements in committed code.

**Phase 6 — Diff review**
Run `git diff --stat` and review each changed file for unintended changes, missing error handling, edge cases.

Output a verification report:

```
VERIFICATION REPORT
===================
Build:    [PASS/FAIL]
Types:    [PASS/FAIL] (N errors)
Lint:     [PASS/FAIL] (N warnings)
Tests:    [PASS/FAIL] (N/M passed, X% coverage)
Security: [PASS/FAIL] (N issues)
Diff:     N files changed

Overall: [READY / NOT READY] for next pipeline step

Issues to fix:
1. ...
```

If NOT READY: list specific issues with file:line references. Do not proceed to the next agent step until READY.

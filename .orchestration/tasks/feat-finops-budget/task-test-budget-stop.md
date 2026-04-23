---
id: test-budget-stop
agent: copilot
priority: low
timeout: 180
depends_on: [impl-budget-dispatcher, impl-budget-dashboard]
---

# Task: Verify — Budget Hard Stop end-to-end

## Verification Checklist
1. `bash -n bin/task-dispatch.sh` — must pass
2. `node --check mcp-server/server.mjs` — must pass
3. Confirm `check_budget()` function exists in task-dispatch.sh
4. Confirm `budget_tokens: 0` disables enforcement (grep for guard condition)
5. Confirm escalation inbox file has fields: batch_id, budget_tokens, used_tokens

## Expected Output
```
PASS bash -n bin/task-dispatch.sh
PASS node --check mcp-server/server.mjs
PASS check_budget() function exists
PASS budget_tokens=0 disables enforcement
PASS escalation file format valid
```

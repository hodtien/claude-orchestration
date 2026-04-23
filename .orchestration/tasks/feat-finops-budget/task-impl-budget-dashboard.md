---
id: impl-budget-dashboard
agent: copilot
priority: normal
timeout: 300
depends_on: [impl-budget-dispatcher]
---

# Task: Implement — Budget % on PM Dashboard (server.mjs)

## Objective
Update `get_project_health` in `mcp-server/server.mjs` to include live token budget usage.

## Files to modify
- `mcp-server/server.mjs` — update `getProjectHealth()` function

## Implementation Instructions
1. In `getProjectHealth()`, find the most recent `batch.conf` with `budget_tokens` set
2. Sum `prompt_chars + output_chars` from `tasks.jsonl` for that batch
3. Compute `used_tokens = total_chars / 4`, `budget_pct = (used / budget * 100).toFixed(1)`
4. Add to return object under `orchestration`:
   ```json
   "budget": {
     "batch": "<batch_id>",
     "budget_tokens": 200000,
     "used_tokens": 45000,
     "budget_pct": "22.5",
     "status": "ok"
   }
   ```
   Status: "ok" (<80%), "warning" (80-95%), "critical" (>95%)
5. Run `node --check mcp-server/server.mjs` to validate.

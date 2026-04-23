---
id: design-budget-stop
agent: gemini
priority: high
timeout: 240
depends_on: []
---

# Task: Design — Budget Hard Stop for task-dispatch.sh

## Objective
Design the exact implementation spec for a token budget enforcement mechanism in the claude-orchestration system.

## Context
- `bin/task-dispatch.sh` is the core async dispatcher
- After each task completes, it logs to `.orchestration/tasks.jsonl` with fields: `prompt_chars`, `output_chars`, `duration_s`, `agent`, `task_id`, `status`
- `batch.conf` already supports fields like `failure_mode`, `max_failures`
- `.orchestration/dlq/` is where failed tasks go with a `.meta.json` escalation report
- `bin/agent-cost.sh` already has estimation logic (reference it for token counting approach)
- `mcp-server/server.mjs` has `get_project_health` tool — it reads `tasks.jsonl` for metrics

## Design Requirements
Produce a precise implementation spec covering:

1. **New `batch.conf` field**: `budget_tokens` (integer, 0 = disabled). Example: `budget_tokens: 200000`
2. **Tracking logic**: After each task completes in `task-dispatch.sh`, read `prompt_chars + output_chars` for ALL tasks in this batch from `tasks.jsonl`, sum them, compare to budget (1 char ≈ 0.25 tokens)
3. **Halt behavior**: If budget exceeded → (a) cancel all running pids, (b) write `budget-exceeded.escalation.md` to `.orchestration/inbox/`, (c) exit with code 3
4. **Dashboard integration**: `get_project_health` in `server.mjs` should include `{ budget_tokens, used_tokens, budget_pct }` in response
5. **Exact bash variable names and insertion points** in `task-dispatch.sh`

## Expected Output
Return a structured spec with pseudocode for the bash tracking block and JS dashboard addition.

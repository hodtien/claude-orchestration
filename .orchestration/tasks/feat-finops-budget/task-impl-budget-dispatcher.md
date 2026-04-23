---
id: impl-budget-dispatcher
agent: copilot
priority: normal
timeout: 420
depends_on: [design-budget-stop]
reviewer: copilot
---

# Task: Implement — Budget Hard Stop in task-dispatch.sh

## Objective
Add token budget enforcement to `bin/task-dispatch.sh` based on the design spec injected from upstream task.

## Files to modify
- `bin/task-dispatch.sh` — add budget tracking after each task completion
- `templates/task-spec.example.md` — document the new `budget_tokens` field in batch.conf comment block

## Implementation Instructions
1. Read the DESIGN SPEC from injected context (upstream task output).
2. Parse `budget_tokens` from `batch.conf` at dispatcher startup (default: 0 = disabled).
3. After each task completes, add a `check_budget()` bash function call:
   - Read `tasks.jsonl`, filter by current `BATCH_ID`, sum `prompt_chars + output_chars`
   - Convert: `tokens = chars / 4`
   - If `budget_tokens > 0` and `used_tokens >= budget_tokens`: trigger halt
4. Budget halt procedure:
   - Kill all child PIDs in `$PIDS_DIR`
   - Write `.orchestration/inbox/BATCH_ID-budget-exceeded.md` with: batch_id, budget_tokens, used_tokens, top 5 expensive tasks
   - Print `[dispatch] 💸 BUDGET EXCEEDED — batch halted`
   - Exit with code 3
5. Run `bash -n bin/task-dispatch.sh` to validate syntax.

## Constraints
- Surgical inserts only — do NOT rewrite the dispatcher
- `check_budget()` must be a standalone function
- Keep DLQ, circuit breaker, state sync logic untouched

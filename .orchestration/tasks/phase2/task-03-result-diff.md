---
id: phase2-03-result-diff
agent: copilot
reviewer: ""
timeout: 240
retries: 1
priority: normal
deadline: ""
context_cache: []
context_from: []
depends_on: []
task_type: code
output_format: code
---

# Task: Implement Task Result Diffing (`bin/task-diff.sh`)

## Objective
Create `bin/task-diff.sh` u2014 a tool to compare task outputs across retries, batch re-runs, or between two result files. Shows what changed between agent outputs.

## Context
The orchestration system is at `/Users/hodtien/claude-orchestration/`.

Result files live in `.orchestration/results/`:
- `<task-id>.out` u2014 primary output
- `<task-id>.v1.out`, `<task-id>.v2.out` u2014 revision outputs (if retried)
- `<task-id>.review.out` u2014 reviewer output

## Deliverables

### `bin/task-diff.sh`
```
Usage:
  task-diff.sh <task-id>                   # diff v1 vs current (if revisions exist)
  task-diff.sh <task-id> v1 v2             # diff two specific versions
  task-diff.sh <file-a> <file-b>           # diff any two result files
  task-diff.sh <task-id> --summary         # show only change stats (lines added/removed)
  task-diff.sh <task-id> --review          # diff main output vs review output
  task-diff.sh --batch <batch-id>          # compare all tasks in batch vs their revisions
```

### Output format (colored diff with context):
```
Diff: phase1-01-agent-health-beacon  (v1 u2192 current)
u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550
@@ -1,3 +1,5 @@
  # Agent Health Beacon
- The beacon reads from tasks.jsonl
+ The beacon reads from .orchestration/tasks.jsonl
+ Added --window flag support
  ...
u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550u2550
Changes: +2 lines added, -1 lines removed
```

### `--summary` mode:
```
Result Diffs Summary (batch: phase1)
  task-01: +45 lines, -12 lines  (revised)
  task-02: no revisions
  task-04: +8 lines, -3 lines    (revised)
```

### `--batch` mode:
- Find all tasks in `.orchestration/results/` matching batch prefix
- For each, check if `.v1.out` exists
- Show summary table of all diffs

## Implementation Notes
- Use `diff -u` or `diff --unified` under the hood (standard Unix tool)
- Fall back to Python `difflib` if `diff` unavailable
- Support ANSI colors: red for removals, green for additions (detect tty)
- Disable colors when output is piped: `[ -t 1 ]` check
- Make executable: `chmod +x bin/task-diff.sh`
- Gracefully handle: missing files ("no revisions found"), identical files ("no changes")
- Keep under 120 lines

## Version naming convention
When `task-dispatch.sh` retries a task, save previous output:
```bash
# In dispatch_task(), before overwriting:
if [ -f "$RESULTS_DIR/${tid}.out" ]; then
  rev_n=$(ls "$RESULTS_DIR/${tid}".v*.out 2>/dev/null | wc -l)
  cp "$RESULTS_DIR/${tid}.out" "$RESULTS_DIR/${tid}.v$((rev_n+1)).out"
fi
```
Add this versioning snippet to `bin/task-dispatch.sh` in `dispatch_task()` before the agent.sh call.

## Expected Output
Write:
1. `/Users/hodtien/claude-orchestration/bin/task-diff.sh`
2. Update `bin/task-dispatch.sh` to save versioned outputs before retry

Test: `bin/task-diff.sh --batch phase1` (may show "no revisions" if none exist yet u2014 that's fine).

Report what was written.

---
id: phase2-07-partial-failure
agent: copilot
reviewer: ""
timeout: 300
retries: 1
priority: normal
deadline: ""
context_cache: []
context_from: []
depends_on: []
task_type: code
output_format: code
---

# Task: Implement Partial Failure Recovery

## Objective
Add a `failure_mode` field to batch configuration so users can control what happens when a task fails u2014 instead of all-or-nothing behavior, batches can skip failed tasks, continue with remaining work, and report partial success.

## Context
The orchestration system is at `/Users/hodtien/claude-orchestration/`.

Current behavior in `bin/task-dispatch.sh`:
- Sequential mode: if task fails, dispatch continues to next task regardless
- Parallel mode: all tasks dispatched at once; failures don't affect others
- No batch-level failure policy
- The inbox notification marks tasks as u274c but no structured policy

## Deliverables

### 1. Add `failure_mode` to batch-level config
Create a new optional file: `.orchestration/tasks/<batch-id>/batch.conf`
```yaml
# batch.conf u2014 optional batch-level configuration
failure_mode: skip-failed   # fail-fast | skip-failed | retry-failed
max_failures: 2             # stop batch after this many failures (0 = unlimited)
notify_on_failure: true     # emit extra warning to stdout
```

### 2. Update `bin/task-dispatch.sh` to read batch.conf

At batch start, check for `<batch-dir>/batch.conf` and parse:
- `failure_mode` (default: `skip-failed` for backward compat)
- `max_failures` (default: 0 = unlimited)

#### `fail-fast` mode:
- On first task failure: print `[dispatch] FAIL-FAST: $tid failed u2014 aborting remaining tasks`
- Exit immediately after writing inbox notification
- Remaining tasks marked as skipped in inbox

#### `skip-failed` mode (default, current behavior):
- Task fails u2192 log it, continue to next task
- Print `[dispatch] SKIP: $tid failed u2014 continuing with remaining tasks`
- Summary shows partial success count

#### `retry-failed` mode:
- After all tasks run (including failures), do a second pass
- Re-run only failed tasks (those missing results)
- Max 1 extra retry pass
- Print `[dispatch] RETRY PASS: re-running $N failed tasks`

#### `max_failures` enforcement:
- Track failure count across dispatch
- When `failures >= max_failures > 0`: switch to fail-fast behavior
- Print `[dispatch] MAX FAILURES ($max_failures) REACHED u2014 aborting`

### 3. Update inbox notification format
Add a `failure_mode` field and `partial_success` indicator to `.orchestration/inbox/<batch-id>.done.md`:
```markdown
**Failure Mode**: skip-failed
**Result**: PARTIAL u2014 4/5 tasks succeeded
```

### 4. Update `templates/task-spec.example.md`
Add a note about `batch.conf` with a link/example.

### 5. Create `.orchestration/tasks/phase2/batch.conf`
As a working example for the current phase2 batch:
```yaml
failure_mode: skip-failed
max_failures: 0
notify_on_failure: true
```

## Implementation Notes
- Parse `batch.conf` using Python3 (simple key: value YAML subset, no full YAML parser needed)
- Backward-compatible: if `batch.conf` absent, default to `skip-failed, max_failures=0`
- Do NOT change the existing `dispatch_task()` return value convention (0=success, 1=fail)
- Add `batch_failure_count` counter at dispatch level
- Keep changes minimal u2014 only modify dispatch control flow, not task spec parsing
- Test: verify `fail-fast` mode stops after first failure

## Expected Output
Write:
1. Updated `/Users/hodtien/claude-orchestration/bin/task-dispatch.sh`
2. `/Users/hodtien/claude-orchestration/.orchestration/tasks/phase2/batch.conf`
3. Updated `/Users/hodtien/claude-orchestration/templates/task-spec.example.md`

Report: what was changed, which code paths were modified.

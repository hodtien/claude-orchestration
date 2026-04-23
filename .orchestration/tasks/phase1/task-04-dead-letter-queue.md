---
id: phase1-04-dead-letter-queue
agent: copilot
reviewer: ""
timeout: 300
retries: 1
priority: normal
deadline: ""
context_cache: []
context_from: []
depends_on: []
read_files: []
output_format: code
---

# Task: Implement Dead-Letter Queue (DLQ)

## Objective
Create a dead-letter queue for failed tasks: exhausted tasks are automatically moved to `.orchestration/dlq/`, and a replay script lets users retry them with an optional refined prompt.

## Context
The orchestration system lives at `/Users/hodtien/claude-orchestration/`.
- `bin/task-dispatch.sh` u2014 dispatches tasks; on failure writes `.orchestration/results/<tid>.out` (empty) and `.orchestration/results/<tid>.log`
- Failed tasks currently just show in the inbox notification as u274c u2014 no structured way to replay them
- `.orchestration/results/` u2014 task output files
- `.orchestration/inbox/` u2014 batch completion notifications

## Deliverables

### 1. Create `.orchestration/dlq/` directory structure
Failed tasks land here as:
```
.orchestration/dlq/
  <task-id>.spec.md       # copy of original task spec
  <task-id>.error.log     # copy of the error log
  <task-id>.meta.json     # metadata: batch_id, failed_at, attempt_count, error_summary
```

### 2. Update `bin/task-dispatch.sh` u2014 DLQ on exhaustion
In `dispatch_task()`, when task fails (after all retries):
- Create `.orchestration/dlq/` if not exists
- Copy task spec to `dlq/<tid>.spec.md`
- Copy error log to `dlq/<tid>.error.log`  
- Write metadata to `dlq/<tid>.meta.json`:
  ```json
  {
    "task_id": "...",
    "batch_id": "...",
    "agent": "...",
    "failed_at": "ISO8601",
    "attempt_count": N,
    "error_summary": "first 200 chars of log",
    "original_spec": "path/to/spec"
  }
  ```
- Print: `[dispatch] u2192 DLQ: $tid moved to .orchestration/dlq/`

### 3. Create `bin/task-dlq.sh`
```
Usage:
  task-dlq.sh                          # list all DLQ items
  task-dlq.sh list                     # same as above
  task-dlq.sh show <task-id>           # show error log + spec for a DLQ item
  task-dlq.sh replay <task-id>         # replay task with original spec
  task-dlq.sh replay <task-id> --refine "new hint for agent"  # replay with extra context prepended
  task-dlq.sh clear <task-id>          # remove item from DLQ (after successful replay)
  task-dlq.sh clear-all                # remove all resolved items
```

#### `task-dlq.sh list` output:
```
Dead-Letter Queue (3 items)
============================================================
TASK ID                AGENT      FAILED AT             ATTEMPTS
phase1-02-slo-track    copilot    2026-04-20T10:15:00Z  2
phase1-03-capability   gemini     2026-04-20T10:16:00Z  1
...
```

#### `task-dlq.sh replay <task-id>`:
- Read the `.spec.md` from dlq/
- If `--refine "text"` provided: prepend text to the prompt body
- Create a temp batch dir: `.orchestration/tasks/dlq-replay-<timestamp>/`
- Copy spec there, run `task-dispatch.sh` on it
- On success: move DLQ item to `.orchestration/dlq/resolved/`

## Implementation Notes
- `task-dlq.sh` must be standalone bash + python3 only
- Make executable: `chmod +x bin/task-dlq.sh`
- DLQ dir: `.orchestration/dlq/` (create in script, add to .gitignore pattern)
- Resolved subdir: `.orchestration/dlq/resolved/`
- Keep under 200 lines
- Handle missing dlq dir gracefully ("DLQ is empty")

## Expected Output
Write these files:
1. `/Users/hodtien/claude-orchestration/bin/task-dlq.sh`
2. Updated `/Users/hodtien/claude-orchestration/bin/task-dispatch.sh`

Report what was changed.

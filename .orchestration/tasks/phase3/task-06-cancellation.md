---
id: phase3-06-cancellation
agent: copilot
reviewer: ""
timeout: 360
retries: 1
priority: normal
deadline: ""
context_cache: []
context_from: []
depends_on: []
task_type: code
output_format: code
slo_duration_s: 360
---

# Task: Implement Task Cancellation & Graceful Shutdown

## Objective
Add the ability to cancel a running task and gracefully shut down the entire batch dispatcher.
Tasks should save partial progress before exiting, and the dispatcher should not leave orphaned
agent processes on SIGTERM.

## Context
Orchestration system at `/Users/hodtien/claude-orchestration/`.

Key files:
- `bin/task-dispatch.sh` u2014 runs agent subprocesses in parallel (`&`) or sequential loop
- `bin/agent.sh` u2014 thin wrapper; the agent subprocess PID is the PID of `agent.sh`
- `.orchestration/tasks.jsonl` u2014 event log
- `.orchestration/results/<task-id>.out` u2014 task output files

Current behavior: no cancellation; `Ctrl+C` kills the shell but may leave background agent.sh
processes running. No PID tracking.

## Deliverables

### 1. PID tracking in `bin/task-dispatch.sh`
In `dispatch_task()` and `dispatch_parallel()`:
- After starting an agent subprocess, write its PID to `.orchestration/pids/<task-id>.pid`
- On task completion (success or failure), remove the `.pid` file
- Directory `.orchestration/pids/` should be created if absent

### 2. `bin/task-dispatch.sh` u2014 SIGTERM / SIGINT trap
Add a trap at the top of the dispatcher:
```bash
trap 'handle_shutdown SIGTERM' TERM
trap 'handle_shutdown SIGINT' INT
```

`handle_shutdown()` logic:
1. Log `{event: shutdown_requested, signal, ts, batch_id}` to `tasks.jsonl`
2. For each `.pid` file in `.orchestration/pids/`:
   a. Send `SIGTERM` to the PID
   b. Wait up to 10 seconds for it to exit
   c. If still alive after 10s u2192 send `SIGKILL`
3. Mark all tasks that were `in_progress` (have a `.pid`) as `cancelled` in a `.cancelled` marker file
4. Log `{event: shutdown_complete, cancelled_tasks: [...], ts}` to `tasks.jsonl`
5. Exit with code 130 (SIGINT) or 143 (SIGTERM)

### 3. `bin/task-cancel.sh` (new)
```
task-cancel.sh <task-id>        # cancel a specific running task
task-cancel.sh --all            # cancel all running tasks in current batch
task-cancel.sh --batch <id>     # cancel all running tasks in a named batch
task-cancel.sh status           # show which tasks are currently running (have .pid files)
```

Logic for `task-cancel.sh <task-id>`:
1. Check `.orchestration/pids/<task-id>.pid` u2014 read PID
2. Verify process is still alive (`kill -0 <PID>`)
3. Send SIGTERM; wait 5s; send SIGKILL if needed
4. Remove `.pid` file
5. Write `.orchestration/results/<task-id>.cancelled` marker
6. Log `{event: task_cancelled, task_id, pid, ts}` to `tasks.jsonl`

### 4. Partial output preservation in `bin/agent.sh`
Update `agent.sh` to trap SIGTERM:
```bash
trap 'save_partial_output' TERM
```

`save_partial_output()`:
- If a partial output file exists (the agent was writing to stdout), append a footer:
  `\n\n--- CANCELLED at <timestamp> ---\n`
- Flush stdout
- Exit 130

### 5. `bin/task-cancel.sh` u2014 `status` command
Read all `.pid` files and show:
```
Running tasks:
  phase3-01  PID=12345  started=14:32:01  elapsed=1m23s
  phase3-02  PID=12346  started=14:32:05  elapsed=1m19s
```

## Implementation Notes
- PID files go in `.orchestration/pids/` u2014 create dir if not present
- The shutdown trap must fire even when `wait` is blocking on background jobs
- Use `wait -n` (bash 4.3+) in parallel dispatch to reap jobs one at a time
- Keep `task-cancel.sh` under 120 lines
- Add `.orchestration/pids/` to `.gitignore` (runtime state, not committed)

## Expected Output
Write:
- `/Users/hodtien/claude-orchestration/bin/task-cancel.sh` (executable)
Modify:
- `/Users/hodtien/claude-orchestration/bin/task-dispatch.sh` (PID tracking + trap)
- `/Users/hodtien/claude-orchestration/bin/agent.sh` (SIGTERM trap)
- `/Users/hodtien/claude-orchestration/.gitignore` (add pids/ dir)

Report: files written/modified, `task-cancel.sh status` output (empty, no running tasks), brief description of changes.

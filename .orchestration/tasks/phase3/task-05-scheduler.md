---
id: phase3-05-scheduler
agent: copilot
reviewer: ""
timeout: 420
retries: 1
priority: normal
deadline: ""
context_cache: []
context_from: []
depends_on: []
task_type: code
output_format: code
slo_duration_s: 420
---

# Task: Implement Scheduled Task Dispatch

## Objective
Add a cron-style scheduled task system: tasks defined in `.orchestration/scheduled-tasks/`
are dispatched automatically at specified times without manual invocation.

## Context
Orchestration system at `/Users/hodtien/claude-orchestration/`.

Key files:
- `bin/task-dispatch.sh` u2014 existing dispatcher (single-run, not daemon)
- `bin/agent.sh` u2014 agent invocation wrapper
- `.orchestration/tasks.jsonl` u2014 event log

Goal: a lightweight cron-like runner that reads schedule files, checks which are due,
and dispatches them. Users run it from their own cron/launchd, or via a watch loop.

## Deliverables

### 1. Schedule spec format
Schedule files live in `.orchestration/scheduled-tasks/<name>.schedule.md`.
Same YAML frontmatter as task specs, plus scheduling fields:
```yaml
---
id: daily-health-report
agent: gemini
task_type: analysis
schedule: "0 9 * * *"       # cron expression (5-field, UTC)
schedule_tz: local           # local | UTC
last_run: ""                 # filled in by runner after each dispatch
next_run: ""                 # filled in by runner
enabled: true
---

# Prompt content below (sent to agent as task body)
Generate a daily health summary from `.orchestration/tasks.jsonl` ...
```

### 2. `bin/task-schedule.sh` (new)
```
task-schedule.sh list                    # show all scheduled tasks with next_run
task-schedule.sh run-due                 # dispatch all tasks due right now
task-schedule.sh run-due --dry-run       # show what would run, don't dispatch
task-schedule.sh enable <id>             # set enabled: true
task-schedule.sh disable <id>            # set enabled: false
task-schedule.sh trigger <id>            # force-dispatch regardless of schedule
task-schedule.sh next <id>               # print next scheduled time
```

Core logic for `run-due`:
1. Read all `*.schedule.md` files
2. For each enabled schedule, compute `next_run` from `schedule` + `last_run`
3. If `next_run <= now` u2192 dispatch via `task-dispatch.sh <tmp_task_spec>` (write a temp spec from the schedule body)
4. Update `last_run` and `next_run` in the schedule file after dispatch
5. Log `{event: scheduled_dispatch, id, schedule, ts}` to `tasks.jsonl`

Cron parsing: use Python3's `datetime` + a minimal cron-next-time calculator
(implement a simple `cron_next(expr, from_dt)` function u2014 no external libraries needed;
5-field cron with `*`, `*/N`, and comma-separated values is sufficient).

### 3. Example schedule file
Create `.orchestration/scheduled-tasks/example-daily-report.schedule.md` with:
- `schedule: "0 9 * * *"` (9am daily)
- Agent: gemini
- Prompt: "Summarize yesterday's task completions and failure count from `.orchestration/tasks.jsonl`"
- `enabled: false` (example only, not actually scheduled)

### 4. `templates/schedule-spec.md` (new)
Document the schedule spec format with all fields explained.

## Implementation Notes
- `task-schedule.sh run-due` is designed to be called from an external cron job:
  `*/5 * * * * /path/to/bin/task-schedule.sh run-due >> /tmp/orch-schedule.log 2>&1`
- The temp task spec written for dispatch should use a unique ID like `scheduled-<id>-<timestamp>`
- Keep the cron-next-time implementation simple: handle `*`, `*/N`, single values, comma lists
- Do not implement ranges (`1-5`) u2014 document this as a known limitation
- Keep `task-schedule.sh` under 250 lines

## Expected Output
Write:
- `/Users/hodtien/claude-orchestration/bin/task-schedule.sh` (executable)
- `/Users/hodtien/claude-orchestration/.orchestration/scheduled-tasks/example-daily-report.schedule.md`
- `/Users/hodtien/claude-orchestration/templates/schedule-spec.md`

Report: files written, `task-schedule.sh list` output, `task-schedule.sh run-due --dry-run` output.

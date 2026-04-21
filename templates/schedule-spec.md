---
# Schedule Spec Template
# Place in: .orchestration/scheduled-tasks/<name>.schedule.md
---

```yaml
---
id: daily-health-report
agent: gemini
task_type: analysis
schedule: "0 9 * * *"
schedule_tz: local
last_run: ""
next_run: ""
enabled: true
---
```

Prompt body below frontmatter is dispatched as the task prompt.

## Required scheduling fields
- `schedule`: 5-field cron (`minute hour day-of-month month day-of-week`)
- `schedule_tz`: `local` or `UTC`
- `last_run`: last dispatch timestamp (managed by scheduler)
- `next_run`: next dispatch timestamp (managed by scheduler)
- `enabled`: `true` or `false`

## Supported cron syntax (minimal)
- `*`
- `*/N`
- comma-separated values (example: `0,15,30,45`)
- single numeric values

## Not supported
- ranges like `1-5`

## CLI
- `bin/task-schedule.sh list`
- `bin/task-schedule.sh run-due`
- `bin/task-schedule.sh run-due --dry-run`
- `bin/task-schedule.sh enable <id>`
- `bin/task-schedule.sh disable <id>`
- `bin/task-schedule.sh trigger <id>`
- `bin/task-schedule.sh next <id>`

---
id: scheduled-runners
agent: copilot
timeout: 180
priority: high
---

# Task: Scheduled Autonomous Runners

## Objective
Implement cron-based batch scheduling for autonomous CI/CD-style orchestration. Run batches on schedule or conditional triggers.

## Scope
- New file: `bin/orch-scheduler.sh`
- New file: `bin/scheduled-run.sh`
- New file: `.orchestration/scheduled/` (scheduled task configs)
- New file: `lib/scheduler-lib.sh`
- Modified: `bin/task-dispatch.sh` (add schedule mode)

## Instructions

### Step 1: Scheduled Task Config Format

Create `.orchestration/scheduled/` directory structure.
Config file format (`.scheduled` extension):
```
name: hourly-smoke-test
batch: smoke-tests
cron: "0 * * * *"          # Every hour
enabled: true
priority: high
on_failure: notify
notify_channel: slack
timeout_batch: 3600         # Max 1 hour
conditions:
  - type: git_branch
    value: main
  - type: file_changed
    patterns: ["src/**/*.ts", "lib/**/*.sh"]
```

### Step 2: Scheduler Core

Create `bin/orch-scheduler.sh`:
1. Load all `.scheduled` configs from `.orchestration/scheduled/`
2. Evaluate cron expressions (use croniter or awk)
3. Determine which batches should run now
4. Queue ready batches for execution
5. Handle overlapping schedules (queue vs skip)

Functions:
- `scheduler_load_configs()` — load all scheduled configs
- `scheduler_is_due(config)` — check if cron matches now
- `scheduler_queue_batch(config)` — add to execution queue
- `scheduler_run_queued()` — execute queued batches

### Step 3: Scheduled Execution

Create `bin/scheduled-run.sh`:
1. Takes scheduled task config as argument
2. Validates conditions before run:
   - git_branch: current branch matches
   - file_changed: files modified since last run
   - time_window: within allowed hours
3. Runs batch with task-dispatch.sh
4. Logs execution to `.orchestration/scheduled/<name>-history.json`
5. Handles timeout and failure notification

### Step 4: Git Hook Integration

Support conditional triggers:
- `.orchestration/scheduled/git-hooks/` directory
- `post-commit`: run after commits
- `pre-push`: run before push (if tests pass)
- `post-merge`: run after merge

### Step 5: Pre-warm Agents

Before scheduled run:
1. Check agent availability
2. If agent is cold (no recent calls), send warmup request
3. Reduce first-task latency

## Expected Output
- `bin/orch-scheduler.sh` — scheduler daemon (runs via cron)
- `bin/scheduled-run.sh` — executes single scheduled task
- `lib/scheduler-lib.sh` — shared scheduling utilities
- `.orchestration/scheduled/` — scheduled task configs
- `.orchestration/scheduled/<name>-history.json` — execution history

## Constraints
- Use system cron as trigger (no daemon mode by default)
- Max concurrent scheduled runs: configurable (default 2)
- Queue overflow: skip with warning, don't block
- Timezone: use local timezone for cron expressions
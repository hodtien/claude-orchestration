---
id: phase3-03-load-routing
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

# Task: Implement Load-Based Agent Routing

## Objective
Add load-aware routing to `bin/task-dispatch.sh` so that when dispatching in parallel mode,
tasks are distributed to the least-loaded agent rather than always picking arbitrarily.

## Context
Orchestration system at `/Users/hodtien/claude-orchestration/`.

Key files:
- `bin/task-dispatch.sh` u2014 `dispatch_parallel()`, `dispatch_task()`
- `bin/orch-health-beacon.sh` u2014 already tracks per-agent metrics from `tasks.jsonl`
- `.orchestration/tasks.jsonl` u2014 event log with `{event: start, agent, task_id, ts}` entries
- `.orchestration/agents.json` u2014 capability registry

Current behavior in parallel mode: tasks are dispatched to whichever agent is specified in the
task spec `agent:` field. No balancing occurs.

## Deliverables

### 1. `bin/agent-load.sh` (new)
A lightweight script to track active task count per agent:
```
agent-load.sh status              # print agent -> active_count table
agent-load.sh increment <agent>   # mark one task starting
agent-load.sh decrement <agent>   # mark one task finishing
agent-load.sh least-loaded <agent1> <agent2> ...  # print the least-loaded agent name
```

State file: `.orchestration/agent-load.json`
```json
{"copilot": 0, "gemini": 0}
```

Make writes atomic (write-to-tmp + mv). Use Python3 for JSON ops.

### 2. `bin/task-dispatch.sh` u2014 update `dispatch_parallel()`
In parallel dispatch mode:
- Before spawning a task, if the spec has `route: auto` (new optional field), call
  `agent-load.sh least-loaded copilot gemini` and use the returned agent instead of spec's `agent:`
- After spawning: `agent-load.sh increment <chosen-agent>` (background)
- On task completion (in wait loop): `agent-load.sh decrement <agent>` (background)
- If `route:` is absent or not `auto`, preserve existing behavior (use spec's `agent:` directly)

New optional frontmatter field:
```yaml
route: auto   # enable load-based routing
```

### 3. `bin/orch-health-beacon.sh` u2014 add `--load` flag
Add a `--load` output mode that also shows current active task count alongside health status:
```
Agent Status  Health   Active
copilot HEALTHY  fail=2%   active=3
gemini  HEALTHY  fail=0%   active=1
```

Read active count from `.orchestration/agent-load.json`.

### 4. `templates/task-spec.example.md`
Document the new `route: auto` field.

## Implementation Notes
- Use file-based counter (JSON), not in-memory, so parallel subprocesses see consistent state
- Atomic write pattern: `python3 -c "..." > .tmp && mv .tmp state.json`
- Keep `agent-load.sh` under 80 lines
- The `least-loaded` command must be deterministic on ties (e.g., pick first alphabetically)

## Expected Output
Write:
- `/Users/hodtien/claude-orchestration/bin/agent-load.sh` (executable)
- `/Users/hodtien/claude-orchestration/.orchestration/agent-load.json`
Modify:
- `/Users/hodtien/claude-orchestration/bin/task-dispatch.sh`
- `/Users/hodtien/claude-orchestration/bin/orch-health-beacon.sh`
- `/Users/hodtien/claude-orchestration/templates/task-spec.example.md`

Report: files written/modified, `agent-load.sh status` output, brief description of changes.

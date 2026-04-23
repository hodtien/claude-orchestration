---
id: phase1-02-slo-tracking
agent: copilot
reviewer: ""
timeout: 300
retries: 1
priority: high
deadline: ""
context_cache: []
context_from: []
depends_on: []
read_files: []
output_format: code
---

# Task: Implement Task SLO Tracking

## Objective
Add SLO (Service Level Objective) tracking to the orchestration system: each task spec can declare an expected duration, and the dispatch script alerts when a task violates it.

## Context
The orchestration system lives at `/Users/hodtien/claude-orchestration/`.
- `bin/task-dispatch.sh` u2014 dispatches tasks, calls `agent.sh`, captures timing
- `templates/task-spec.example.md` u2014 task spec format with YAML frontmatter
- `.orchestration/tasks.jsonl` u2014 JSONL audit log with duration_s field

## Deliverables

### 1. Add `slo_duration_s` field to task spec format
Update `templates/task-spec.example.md`: add `slo_duration_s: 0` field (0 = disabled) with a comment explaining it.

### 2. Update `bin/task-dispatch.sh` u2014 SLO violation detection
In the `dispatch_task()` function, after a task completes:
- Read `slo_duration_s` from task frontmatter using the existing `parse_front` helper
- Compare actual duration against SLO
- If actual > slo * 1.5: print `[dispatch] u26a0ufe0f  SLO VIOLATION: $tid took ${duration}s (SLO: ${slo}s, ${pct}% over)`
- If actual > slo * 1.2: print `[dispatch] u26a0ufe0f  SLO WARNING: $tid took ${duration}s (SLO: ${slo}s, ${pct}% over)`
- Store SLO result in the JSON completion report (add `slo_s`, `slo_status` fields)

### 3. Create `bin/orch-slo-report.sh`
```
Usage:
  orch-slo-report.sh              # report all SLO violations from tasks.jsonl
  orch-slo-report.sh --batch ID   # filter by batch ID  
  orch-slo-report.sh --agent A    # filter by agent
```

Logic:
- Read `.orchestration/tasks.jsonl`
- Find tasks where duration_s is known
- Cross-reference with task specs in `.orchestration/tasks/` to get slo_duration_s
- Report: task_id, agent, actual_s, slo_s, violation_level (OK/WARNING/VIOLATION)
- Show summary: total violations, worst offenders, p50/p95 durations per agent

## Implementation Notes
- SLO check only runs if `slo_duration_s > 0` (skip if 0 or missing)
- Capture actual task duration in `dispatch_task()`: time the `agent.sh` call
- The existing `generate_report()` function already creates JSON u2014 add slo fields there
- Script must be executable: `chmod +x bin/orch-slo-report.sh`
- Keep under 120 lines each

## Timing in dispatch_task()
Add this pattern around the agent.sh call:
```bash
task_start=$(date +%s)
# ... existing agent.sh call ...
task_end=$(date +%s)
actual_duration=$(( task_end - task_start ))
```

## Expected Output
Write these files:
1. Updated `/Users/hodtien/claude-orchestration/bin/task-dispatch.sh`
2. `/Users/hodtien/claude-orchestration/bin/orch-slo-report.sh`
3. Updated `/Users/hodtien/claude-orchestration/templates/task-spec.example.md`

Report what was changed.

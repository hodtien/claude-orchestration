---
id: phase1-01-agent-health-beacon
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

# Task: Implement Agent Health Beacon

## Objective
Create `bin/orch-health-beacon.sh` that tracks per-agent failure rates and response times from the audit log, then integrate it into `bin/task-dispatch.sh` to skip unhealthy agents before dispatch.

## Context
The orchestration system lives at `/Users/hodtien/claude-orchestration/`.
- `bin/agent.sh` — runs copilot/gemini, writes to `.orchestration/tasks.jsonl`
- `bin/task-dispatch.sh` — dispatches batches, calls agent.sh per task
- `.orchestration/tasks.jsonl` — JSONL audit log with fields: ts, event, task_id, agent, status, duration_s

The audit log already records success/failed/exhausted events per agent. We need to:
1. Parse recent events (last 1 hour) per agent
2. Compute failure_rate and avg_response_time
3. Flag agents as DEGRADED (>20% failures) or DOWN (>50% failures)
4. Emit a health report + set an exit code agents can check

## Deliverables

### 1. `bin/orch-health-beacon.sh`
```
Usage:
  orch-health-beacon.sh                   # show health report for all agents
  orch-health-beacon.sh --json            # output JSON (machine-readable)
  orch-health-beacon.sh --check copilot   # exit 0=healthy, 1=degraded, 2=down
  orch-health-beacon.sh --window 3600     # lookback window in seconds (default: 3600)
```

Logic:
- Read `.orchestration/tasks.jsonl` (one JSON object per line)
- Filter events with `event=complete` within the --window
- Per agent: count total, success, failed, compute failure_rate, avg duration_s
- Thresholds: HEALTHY (<10% failures), DEGRADED (10-50%), DOWN (>50% or 0 calls in window)
- Output table with: agent, status, total_calls, failure_rate, avg_duration_s, last_seen
- --json mode: output raw JSON object
- --check <agent>: exit 0/1/2 based on health

### 2. Update `bin/task-dispatch.sh` — pre-dispatch health gate
Before dispatching any task, add a call to `orch-health-beacon.sh --check <agent>`.
- If DOWN (exit 2): skip task, log `[dispatch] SKIP $tid — agent $agent is DOWN`
- If DEGRADED (exit 1): warn but continue: `[dispatch] WARN: agent $agent is DEGRADED`
- If HEALTHY (exit 0): proceed normally

Only add this check if `bin/orch-health-beacon.sh` exists (backward-compatible).

## Implementation Notes
- Use Python3 for JSON parsing (same pattern as existing task-dispatch.sh)
- Handle missing/empty log file gracefully (treat as HEALTHY if no data)
- The beacon script should be standalone (no external deps beyond python3, bash)
- Keep the script under 150 lines
- Make the file executable: `chmod +x bin/orch-health-beacon.sh`

## Expected Output
Write the two files:
1. `/Users/hodtien/claude-orchestration/bin/orch-health-beacon.sh`
2. Updated `/Users/hodtien/claude-orchestration/bin/task-dispatch.sh` with health gate

Report what was changed and test the beacon script works on the existing tasks.jsonl if present.

---
id: phase1-05-trace-correlation
agent: gemini
reviewer: ""
timeout: 300
retries: 1
priority: normal
deadline: ""
context_cache: []
context_from: []
depends_on: [phase1-02-slo-tracking, phase1-04-dead-letter-queue]
read_files: []
output_format: code
---

# Task: Implement Task Trace Correlation

## Objective
Add trace correlation to the audit log: every task gets a `trace_id` (batch-scoped) and `parent_task_id` (for chained tasks), enabling end-to-end tracing of multi-hop task chains.

## Context
The orchestration system lives at `/Users/hodtien/claude-orchestration/`.
- `bin/agent.sh` u2014 core runner; writes JSONL events to `.orchestration/tasks.jsonl`
- `bin/task-dispatch.sh` u2014 orchestrates batches; calls agent.sh per task; has `context_from` chaining
- `.orchestration/tasks.jsonl` u2014 current log schema: `{ts, event, task_id, agent, project, status, duration_s, prompt_chars, output_chars, output, error}`
- `depends_on` and `context_from` in task specs create implicit parent-child relationships

## Deliverables

### 1. Update `bin/agent.sh` u2014 add trace_id and parent_task_id to log

In `log_event()` Python block, add two new fields:
- `trace_id`: passed via env var `ORCH_TRACE_ID` (set by task-dispatch.sh per batch)
- `parent_task_id`: passed via env var `ORCH_PARENT_TASK_ID` (set when context_from chain exists)

Updated log schema:
```json
{
  "ts": "...",
  "event": "...",
  "task_id": "...",
  "trace_id": "batch-phase1-20260420-abc123",
  "parent_task_id": "task-01" or null,
  "agent": "...",
  ...
}
```

### 2. Update `bin/task-dispatch.sh` u2014 set trace context

At the start of any batch dispatch:
- Generate a `TRACE_ID`: `<batch-id>-<timestamp>-<random4chars>` e.g. `phase1-20260420-a3f2`
- Export as `ORCH_TRACE_ID` before calling `agent.sh`

For tasks with `context_from`:
- Set `ORCH_PARENT_TASK_ID` to the first context task ID before calling `agent.sh`
- Unset after the call

### 3. Create `bin/orch-trace.sh`
```
Usage:
  orch-trace.sh <trace_id>           # show all events for a trace
  orch-trace.sh --task <task_id>     # show all events for a task (across traces)
  orch-trace.sh --list               # list all trace IDs (recent first)
  orch-trace.sh --waterfall <trace_id>  # show timing waterfall (ASCII)
```

#### `--waterfall` output format:
```
Trace: phase1-20260420-a3f2  (total: 145s)
u251cu2500u2500 task-01 [copilot] start: 00:00  duration: 45s  u2705
u251cu2500u2500 task-02 [copilot] start: 00:00  duration: 52s  u2705
u251cu2500u2500 task-03 [gemini]  start: 00:00  duration: 38s  u2705
u2514u2500u2500 task-05 [gemini]  start: 00:52  duration: 93s  u2705  (parent: task-02)
```

- Start times are relative to trace start
- Show critical path (longest sequential chain)
- Show parallelism: tasks at same start time ran in parallel

## Implementation Notes
- `ORCH_TRACE_ID` and `ORCH_PARENT_TASK_ID` are env vars u2014 no changes to agent.sh CLI interface
- Handle missing env vars gracefully in log_event (null values)
- Make `orch-trace.sh` executable: `chmod +x bin/orch-trace.sh`
- Use Python3 for JSONL parsing
- Keep under 150 lines
- Backward-compatible: old log entries without trace_id/parent_task_id still parse fine

## Expected Output
Write these files:
1. Updated `/Users/hodtien/claude-orchestration/bin/agent.sh`
2. Updated `/Users/hodtien/claude-orchestration/bin/task-dispatch.sh`
3. `/Users/hodtien/claude-orchestration/bin/orch-trace.sh`

Report what was changed.

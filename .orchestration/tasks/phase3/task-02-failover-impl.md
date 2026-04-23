---
id: phase3-02-failover-impl
agent: copilot
reviewer: ""
timeout: 420
retries: 1
priority: high
deadline: ""
context_cache: []
context_from: [phase3-01-failover-design]
depends_on: [phase3-01-failover-design]
task_type: code
output_format: code
slo_duration_s: 420
---

# Task: Implement Agent Failover Chains & Circuit Breaker

## Objective
Implement the agent failover chain feature based on the design in context (phase3-01-failover-design).
A task with `agents: [copilot, gemini]` should automatically fall back to the next agent if the
primary is DOWN or fails.

## Context
Orchestration system at `/Users/hodtien/claude-orchestration/`.

Design document is injected above from `phase3-01-failover-design`.

Existing files to modify:
- `bin/task-dispatch.sh` u2014 `dispatch_task()` function, `check_agent_health()`, `parse_list()`
- `bin/agent.sh` u2014 agent invocation wrapper
- `templates/task-spec.example.md` u2014 document new `agents:` field

New files to create:
- `bin/circuit-breaker.sh` u2014 read/update circuit-breaker state
- `.orchestration/circuit-breaker.json` u2014 initial empty state `{}`

## Deliverables

### 1. `bin/task-dispatch.sh` u2014 update `dispatch_task()`
- Parse `agents:` list from frontmatter (falls back to `agent:` scalar if not present)
- Loop through agents in order:
  1. Check circuit breaker state (`circuit-breaker.sh check <agent>`)
  2. If OPEN u2192 skip to next agent, log `{event: failover_skip, agent, reason: circuit_open}`
  3. Call `agent.sh <agent> <spec>` with the current agent
  4. On success u2192 record success in circuit breaker, break loop
  5. On failure u2192 record failure in circuit breaker, try next agent
- If all agents exhausted u2192 mark task FAILED (existing DLQ path)
- Add JSONL events for each failover attempt: `{event: failover_attempt, agent, position, outcome}`

### 2. `bin/circuit-breaker.sh`
Commands:
```
circuit-breaker.sh check <agent>         # exits 0=CLOSED/HALF-OPEN, 1=OPEN
circuit-breaker.sh record-success <agent>
circuit-breaker.sh record-failure <agent>
circuit-breaker.sh status                # print all agents and their state
circuit-breaker.sh reset <agent>         # force back to CLOSED
```

State file: `.orchestration/circuit-breaker.json`
```json
{
  "copilot": {"state": "CLOSED", "failures": 0, "last_failure": null, "last_probe": null},
  "gemini":  {"state": "CLOSED", "failures": 0, "last_failure": null, "last_probe": null}
}
```

State transitions:
- Record 3 failures within 5 minutes u2192 trip to OPEN
- After 300s in OPEN u2192 transition to HALF-OPEN (allow one probe)
- probe success u2192 CLOSED; probe failure u2192 back to OPEN

Use Python3 for JSON read/write (same pattern as existing scripts).
Make atomic write: write to `.tmp` then `mv` to avoid corruption.

### 3. `templates/task-spec.example.md`
Document the new `agents:` field with example:
```yaml
agents: [copilot, gemini]  # try copilot first; fall back to gemini
```

## Implementation Notes
- `parse_list` already exists in `task-dispatch.sh` for reading YAML lists u2014 reuse it
- Keep failover loop changes isolated inside `dispatch_task()` u2014 don't touch other functions
- Circuit breaker threshold: 3 failures in 300s window (hardcoded constants, no config needed now)
- Test: create a minimal task spec with `agents: [copilot, gemini]`, verify log shows failover attempt

## Expected Output
Write:
- `/Users/hodtien/claude-orchestration/bin/circuit-breaker.sh` (executable)
- `/Users/hodtien/claude-orchestration/.orchestration/circuit-breaker.json`
Modify:
- `/Users/hodtien/claude-orchestration/bin/task-dispatch.sh`
- `/Users/hodtien/claude-orchestration/templates/task-spec.example.md`

Report: files written/modified, circuit-breaker.sh status output, brief smoke test result.

---
id: phase3-01-failover-design
agent: gemini
reviewer: ""
timeout: 300
retries: 1
priority: high
deadline: ""
context_cache: []
context_from: []
depends_on: []
task_type: analysis
output_format: markdown
slo_duration_s: 300
---

# Task: Design Agent Failover Chain & Circuit-Breaker Algorithm

## Objective
Design the algorithm and data model for agent failover chains in the orchestration system.
A task spec should be able to declare `agents: [copilot, gemini]` meaning "try copilot first;
if it fails or is DOWN, fall back to gemini".

## Context
The orchestration system is at `/Users/hodtien/claude-orchestration/`.

Key existing files:
- `bin/task-dispatch.sh` — dispatcher; calls `bin/agent.sh <agent> <task-spec>`
- `bin/orch-health-beacon.sh` — health check; `--check <agent>` exits 0=HEALTHY, 1=DEGRADED, 2=DOWN
- `bin/agent.sh` — thin wrapper that calls MCP agent by name
- `.orchestration/agents.json` — capability registry with `{copilot: {...}, gemini: {...}}`
- `.orchestration/tasks.jsonl` — append-only event log (task start/complete/fail events)

Current task spec frontmatter (relevant fields):
```yaml
agent: copilot          # single agent today
retries: 1
```

## What to Design

### 1. Failover Chain Spec
Propose the task spec YAML extension:
```yaml
agents: [copilot, gemini]   # ordered fallback list; overrides `agent:`
```
- If `agents` is present, `agent` is ignored.
- Try agents in order until one succeeds.
- A "failure" = exit code ≠ 0 OR health status = DOWN.

### 2. Circuit-Breaker State Machine
Design a per-agent circuit breaker with three states:
- **CLOSED** (normal): route traffic to agent
- **OPEN** (tripped): agent is DOWN; skip immediately to next fallback
- **HALF-OPEN** (recovery probe): after `reset_timeout` seconds, allow one probe request

State transitions:
- CLOSED → OPEN when `failure_rate > threshold` in recent window
- OPEN → HALF-OPEN after `reset_timeout` seconds
- HALF-OPEN → CLOSED on success; HALF-OPEN → OPEN on failure

Where should circuit-breaker state be persisted? (suggest `.orchestration/circuit-breaker.json`)

### 3. Failover Execution Flow in task-dispatch.sh
Pseudocode for how `dispatch_task()` should iterate over the `agents` list.

### 4. Cost-Aware Failover
When multiple agents are HEALTHY, how should the dispatcher choose order?
- Option A: always try in spec order (predictable)
- Option B: sort by cost tier first (prefer cheapest HEALTHY agent)
- Recommend one and explain tradeoffs.

### 5. Logging & Audit
What fields to add to `tasks.jsonl` to track failover events:
- Which agent was tried, in which position, and with what outcome

## Expected Output
A detailed design document covering:
- YAML spec extension with examples
- Circuit-breaker state machine (diagram or pseudocode)
- `dispatch_task()` failover loop pseudocode
- `circuit-breaker.json` schema
- JSONL event fields for failover audit
- Recommendation on cost-aware ordering

This output feeds copilot for implementation (phase3-02).

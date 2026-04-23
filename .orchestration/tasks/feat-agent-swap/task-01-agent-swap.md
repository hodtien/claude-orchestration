---
id: agent-swap-protocol
agent: copilot
timeout: 180
priority: high
---

# Task: Agent Swap Protocol

## Objective
Implement automatic agent failover when primary agent is DOWN. Dynamically route tasks to available fallback agents without blocking batches.

## Scope
- File: `bin/task-dispatch.sh` (modify agent selection logic)
- New file: `bin/agent-swap.sh` (swap decision engine)
- New file: `lib/agent-failover.sh` (failover logic library)

## Instructions

### Step 1: Agent Health Check Before Dispatch

Create `bin/agent-swap.sh`:
1. Takes desired agent and task spec as arguments
2. Checks agent health via orch-health-beacon.sh
3. If primary agent is DOWN → find available fallback
4. Fallback priority: copilot > gemini > haiku (by availability, not just preference)
5. Returns: preferred agent or "no-agent-available"

### Step 2: Failover Logic Library

Create `lib/agent-failover.sh`:
- `failover_get_chain(spec)` — get failover agent chain from task spec
- `failover_find_available(chain)` — find first available agent in chain
- `failover_is_healthy(agent)` — check agent health
- `failover_log_swap(task, from, to, reason)` — log swap decision

Agent priority for fallback (when no explicit chain):
```bash
FALLBACK_PRIORITY=(copilot gemini haiku)
```

### Step 3: Integrate into task-dispatch.sh

Modify dispatch_task() function:
1. Before dispatching, call agent-swap.sh
2. If swap needed, log the swap
3. Use swapped agent for dispatch
4. Update audit log with swap reason

Add to audit log:
```json
{"event":"agent_swap","task_id":"xxx","original_agent":"gemini","swapped_agent":"copilot","reason":"primary_down"}
```

### Step 4: Dynamic Agent Discovery

Enhance orch-health-beacon.sh to support:
- `--quick` flag for fast health check
- JSON output mode for programmatic use
- Cached results (don't check every task)

## Expected Output
- `bin/agent-swap.sh` — executable swap decision engine
- `lib/agent-failover.sh` — failover library
- Modified `bin/task-dispatch.sh` — integrated swap logic
- Modified `bin/orch-health-beacon.sh` — enhanced health checks

## Constraints
- Fallback must be capability-compatible (check task_type)
- Never swap security reviews to haiku
- Log all swap decisions for audit trail
- Max 2 swaps per task (prevent chain failures)
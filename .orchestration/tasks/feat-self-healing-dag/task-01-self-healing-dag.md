---
id: self-healing-dag
agent: copilot
timeout: 240
priority: high
---

# Task: Self-Healing DAG Enhancement

## Objective
Enhance the existing DAG implementation to automatically detect failures, identify blocked paths, and re-route around failures autonomously.

## Scope
- File: `bin/task-dag.sh` (existing)
- Directory: `.orchestration/healed-dags/` (existing)
- New file: `lib/dag-healer.sh`
- New file: `bin/dag-heal.sh`
- Modified: `bin/task-dispatch.sh`

## Instructions

### Step 1: Failure Detection

Create `lib/dag-healer.sh`:
- `healer_detect_failure(task_result)` — parse task result, detect failure type
- `healer_classify_failure()` — classify: agent_down, timeout, invalid_spec, conflict
- `healer_find_blocked_paths()` — find DAG paths blocked by failure

Failure types:
```bash
FAIL_AGENT_DOWN="agent_down"
FAIL_TIMEOUT="timeout"
FAIL_INVALID_SPEC="invalid_spec"
FAIL_CONFLICT="conflict"
FAIL_UNKNOWN="unknown"
```

### Step 2: Re-routing Logic

Create `bin/dag-heal.sh`:
1. Takes failed task + DAG as input
2. Analyzes failure cause
3. Generates healed DAG with:
   - Blocked nodes removed or modified
   - Dependencies re-computed
   - Alternative agents suggested
4. Stores healed DAG alongside original

Output:
```bash
healed-dags/<batch_id>-original.dot
healed-dags/<batch_id>-healed.dot
healed-dags/<batch_id>-healing-log.json
```

### Step 3: Healing Strategies

Implement healing strategies:
```bash
heal_retry()         # Retry same agent
heal_fallback_agent() # Try different agent
heal_remove_node()    # Remove blocked node, continue
heal_modify_spec()    # Modify task spec to avoid failure
heal_split_node()     # Break large node into smaller
heal_parallelize()    # Convert sequential to parallel
```

### Step 4: Compare & Learn

After healing:
1. Execute healed DAG
2. Compare with original (success rate, duration, cost)
3. Log healing decision + outcome
4. Store as learning for future

## Expected Output
- `lib/dag-healer.sh` — healing logic library
- `bin/dag-heal.sh` — executable healer
- `healed-dags/<batch>-healed.dot` — healed DAG
- `healed-dags/<batch>-healing-log.json` — decision log
- Modified `bin/task-dispatch.sh` — integrated healing

## Constraints
- Max healing attempts: 3
- Never heal security-critical paths without human approval
- Log all healing decisions for audit
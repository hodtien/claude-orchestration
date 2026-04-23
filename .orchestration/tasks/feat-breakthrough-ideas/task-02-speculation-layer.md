---
id: speculation-layer-impl
agent: copilot
timeout: 240
priority: high
depends_on: [budget-tier-triage-design]
---

# Task: Shared State Speculation Layer

## Objective
Build a speculation buffer where agents publish provisional state; conflict detector runs after batch to promote valid speculations or trigger re-execution.

## Scope
- New file: `lib/speculation-buffer.sh`
- New file: `bin/speculation-detector.sh`
- Modified: `bin/task-dispatch.sh` (speculation hooks)
- New file: `lib/state-conflict-resolver.sh`

## Instructions

### Step 1: Speculation Buffer Design

Create `lib/speculation-buffer.sh`:
- Functions: `speculate_publish()`, `speculate_list()`, `speculate_promote()`, `speculate_invalidate()`
- Storage: `~/.claude/orchestration/speculation/` — one JSON per agent per batch
- Schema per speculation:
  ```json
  {
    "agent_id": "copilot",
    "batch_id": "batch-xxx",
    "state_key": "file:path/to/file",
    "provisional_value": "hash or summary of expected state",
    "dependencies": ["other_agent_id"],
    "created_at": "ISO8601",
    "status": "provisional|confirmed|invalidated"
  }
  ```

### Step 2: Speculation Detector

Create `bin/speculation-detector.sh`:
1. Run after each batch completes
2. For each speculation with status=provisional:
   - Compare `provisional_value` against actual file state
   - If match → promote to confirmed
   - If conflict → invalidate + log conflict
3. Output conflict report: `speculation-conflicts-<batch_id>.json`

### Step 3: State Conflict Resolver

Create `lib/state-conflict-resolver.sh`:
- `resolve_conflict()` — given conflict JSON, decide: retry | skip | escalate
- Heuristic: if <3 agents published different state for same key → retry; else → escalate to orchestrator
- Auto-generate retry task specs for invalidated speculations

### Step 4: Integrate into task-dispatch.sh

Add hooks:
- `PRE_TASK`: call `speculate_publish` with agent's intended state
- `POST_BATCH`: call `speculation-detector.sh`
- Update audit log with speculation metrics

## Expected Output
- `lib/speculation-buffer.sh` — speculation pub/sub library
- `lib/state-conflict-resolver.sh` — conflict resolution logic
- `bin/speculation-detector.sh` — post-batch conflict detector
- Modified `bin/task-dispatch.sh` — speculation hooks integrated

## Constraints
- Non-blocking: speculation failures don't halt batch
- Idempotent: re-running detector on same batch produces same result
- Max 100 speculations per batch (overflow → log warning + skip)
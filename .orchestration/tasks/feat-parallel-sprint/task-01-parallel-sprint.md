---
id: parallel-sprint
agent: copilot
timeout: 300
priority: low
---

# Task: Parallel Sprint Execution

## Objective
Run multiple independent batches in true parallel. Achieve 3-5x throughput improvement.

## Scope
- New file: `lib/sprint-queue.sh`
- New file: `bin/parallel-run.sh`
- New file: `bin/sprint-manager.sh`
- Modified: `bin/task-dispatch.sh`

## Instructions

### Step 1: Sprint Queue

Create `lib/sprint-queue.sh`:
- `queue_add(batch_id, priority)` — add batch to queue
- `queue_get_ready()` — get next batch to run
- `queue_get_active()` — get currently running batches
- `queue_complete(batch_id)` — mark batch complete
- `queue_get_stats()` — get queue statistics

Queue priority levels:
```bash
PRIORITY_CRITICAL=1  # Blocked by user
PRIORITY_HIGH=2       # Scheduled or high priority
PRIORITY_NORMAL=3     # Standard batch
PRIORITY_LOW=4        # Background task
```

### Step 2: Parallel Execution Manager

Create `bin/sprint-manager.sh`:
1. Manages concurrent batch execution
2. Respects resource limits:
   - Max concurrent batches (default: 3)
   - Max concurrent agents per batch
   - Memory/CPU awareness
3. Distributes agents across batches
4. Handles inter-batch dependencies

### Step 3: True Parallel Dispatch

Create `bin/parallel-run.sh`:
```bash
# Run multiple batches in parallel
./bin/parallel-run.sh batch1 batch2 batch3
```

1. Queue all batches
2. Start N batches concurrently
3. Monitor completion
4. Start next batch when slot available
5. Continue until all batches complete

### Step 4: Resource Management

Implement resource tracking:
```json
{
  "max_concurrent_batches": 3,
  "max_concurrent_agents": 5,
  "current_batches": ["phase2", "phase3"],
  "current_agents": ["copilot", "gemini"],
  "resource_usage": {
    "memory_mb": 512,
    "cpu_percent": 45
  }
}
```

### Step 5: Dependency Handling

Handle cross-batch dependencies:
```bash
# Batch with dependency
./bin/parallel-run.sh batch1
# batch2 depends on batch1 completing
./bin/parallel-run.sh batch2 --wait-for batch1
```

## Expected Output
- `lib/sprint-queue.sh` — queue management
- `bin/sprint-manager.sh` — execution manager
- `bin/parallel-run.sh` — parallel launcher
- Modified `bin/task-dispatch.sh` — parallel mode

## Constraints
- Default max concurrent: 3 batches
- Never exceed max agents per provider
- Queue overflow: warn but don't block
- Monitor for resource exhaustion
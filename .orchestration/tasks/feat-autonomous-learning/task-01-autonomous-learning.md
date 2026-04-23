---
id: autonomous-learning
agent: copilot
timeout: 240
priority: medium
---

# Task: Autonomous Learning Loop

## Objective
Build orchestrator that learns from every batch execution. Improve routing/triage decisions over time.

## Scope
- New file: `lib/learning-engine.sh`
- New file: `bin/learn-from-batch.sh`
- New file: `bin/routing-advisor.sh`
- Directory: `.orchestration/learnings/`

## Instructions

### Step 1: Learning Data Collection

Create `lib/learning-engine.sh`:
- `learning_record_outcome(batch_id, task_id, agent, success, duration, tokens)` — record result
- `learning_get_agent_stats(agent)` — get agent performance stats
- `learning_get_task_type_stats(task_type)` — get task type patterns
- `learning_suggest_agent(task_type)` — suggest best agent for task type

Metrics to track:
```json
{
  "agent": "copilot",
  "task_type": "refactor",
  "total_tasks": 50,
  "success_count": 45,
  "success_rate": 0.90,
  "avg_duration_s": 120,
  "avg_tokens": 5000,
  "last_updated": "2026-04-22"
}
```

### Step 2: Batch Analysis

Create `bin/learn-from-batch.sh`:
1. After each batch completes
2. Analyze all task outcomes
3. Update agent performance stats
4. Identify patterns:
   - Which agents succeed on which task types
   - Average cost per task type
   - Retry patterns
5. Generate recommendations

Output:
```json
{
  "batch_id": "phase2",
  "completed_at": "2026-04-22T10:00:00Z",
  "total_tasks": 7,
  "successful": 6,
  "failed": 1,
  "recommendations": [
    {"type": "routing", "agent": "copilot", "task_type": "refactor", "suggestion": "increase usage"},
    {"type": "budget", "task_type": "design", "suggestion": "increase timeout"}
  ]
}
```

### Step 3: Routing Advisor

Create `bin/routing-advisor.sh`:
1. Takes task spec as input
2. Queries learning data
3. Returns routing recommendation:
   - Best agent for this task type
   - Expected duration
   - Expected cost
   - Confidence in recommendation

Output:
```bash
SUGGESTED_AGENT=copilot
CONFIDENCE=0.85
EXPECTED_DURATION=120
EXPECTED_COST=0.05
REASON="copilot has 90% success on refactoring tasks"
```

### Step 4: Auto-Tuning

Implement auto-tuning:
- Adjust tier thresholds based on actual outcomes
- Weight agent selection by learned performance
- Update routing recommendations after each batch

### Step 5: Learning Storage

Create `.orchestration/learnings/` structure:
```
learnings/
  agent-stats.json      # Per-agent performance
  task-type-stats.json  # Per-task-type patterns
  routing-history.jsonl # All routing decisions
  recommendations.json  # Current recommendations
```

## Expected Output
- `lib/learning-engine.sh` — learning logic
- `bin/learn-from-batch.sh` — batch analyzer
- `bin/routing-advisor.sh` — routing advisor
- `.orchestration/learnings/` — learning data

## Constraints
- Conservative delta: don't change routing drastically
- Minimum 10 samples before suggesting changes
- Log all learning updates for audit
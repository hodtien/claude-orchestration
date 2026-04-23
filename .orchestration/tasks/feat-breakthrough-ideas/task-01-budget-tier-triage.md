---
id: budget-tier-triage-impl
agent: copilot
timeout: 300
priority: high
---

# Task: Budget-Tiered Task Triage — Design & Implementation

## Objective
Design and implement a complexity classifier that routes tasks into four tiers by estimated token budget and intent clarity.

## Scope
- File: `bin/task-dispatch.sh` (main dispatcher logic)
- New file: `bin/classify-tokens.sh` (token estimator)
- New file: `lib/triage-tiers.sh` (tier routing logic)

## Instructions

### Step 1: Define Four Tiers

Create the following tier definitions:
```
TIER_MICRO   — <100 tokens, clear intent         → direct execution (Claude or HAIKU)
TIER_STANDARD — 100-5k tokens, standard scope   → normal dispatch
TIER_COMPLEX  — 5k-50k tokens, multi-agent      → full pipeline with DAG
TIER_CRITICAL — >50k or ambiguous                → council protocol + intent fork
```

### Step 2: Implement Token Estimator

Create `bin/classify-tokens.sh` that:
1. Reads task spec from argument
2. Counts words in `## Instructions` section
3. Estimates tokens (words × 1.3 + buffer for context)
4. Reads intent clarity from task spec `intent_clarity` field (high/medium/low)
5. Outputs tier: `TIER_MICRO|TIER_STANDARD|TIER_COMPLEX|TIER_CRITICAL`

### Step 3: Integrate into task-dispatch.sh

Modify `bin/task-dispatch.sh` to:
1. Call `classify-tokens.sh` on each task before dispatch
2. Route based on tier:
   - TIER_MICRO → spawn lightweight agent (haiku or direct exec)
   - TIER_STANDARD → use standard gemini/copilot dispatch
   - TIER_COMPLEX → add DAG wrapper + checkpoint
   - TIER_CRITICAL → invoke council skill first, then dispatch
3. Log tier assignment with reasoning to audit log

### Step 4: Add Tier Metrics

Add to audit log (`.orchestration/audit.jsonl`):
- `tier_assigned`
- `tokens_estimated`
- `routing_decision`

## Expected Output
- `bin/classify-tokens.sh` — executable token classifier
- `lib/triage-tiers.sh` — tier routing library (sourced, not executed)
- Modified `bin/task-dispatch.sh` — tier-aware routing
- Updated `CLAUDE.md` — document tier routing in agent routing rules

## Constraints
- Backward compatible: existing tasks without tier info default to TIER_STANDARD
- Tier assignment is advisory: orchestrator can override based on context
- No external API calls for classification — all local
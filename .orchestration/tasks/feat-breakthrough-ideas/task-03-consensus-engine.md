---
id: consensus-engine-impl
agent: copilot
timeout: 240
priority: high
---

# Task: Consensus Engine

## Objective
Implement weighted vote council for when agents reach conflicting conclusions. Store losing positions as "discarded alternatives" with reasoning.

## Scope
- New file: `lib/consensus-vote.sh`
- New file: `bin/consensus-trigger.sh`
- Modified: `lib/council-protocol.sh` (or create if not exists)
- New file: `lib/discarded-alternatives.sh`

## Instructions

### Step 1: Define Agent Weights

Create `lib/consensus-vote.sh` with weight configuration:
```bash
declare -A AGENT_WEIGHTS=(
  [architect]=3.0
  [security]=3.0
  [senior-engineer]=2.5
  [code-reviewer]=2.0
  [gemini]=2.0
  [copilot]=1.5
  [qa-agent]=1.5
  [default]=1.0
)
```

### Step 2: Consensus Trigger

Create `bin/consensus-trigger.sh`:
1. Takes conflicting conclusions as arguments (JSON array)
2. Each conclusion includes: `agent_id`, `position`, `confidence`, `reasoning`
3. Compute weighted vote:
   - `score = weight(agent) × confidence(position)`
4. If top score margin < threshold (0.3) → invoke council skill for tie-break
5. Output: winning position + losing positions as discarded alternatives

### Step 3: Discarded Alternatives Store

Create `lib/discarded-alternatives.sh`:
- `alternatives_store()` — save losing position with:
  - `winning_position`: what won
  - `losing_position`: what lost
  - `margin`: score difference
  - `reasoning`: why it lost
  - `timestamp`
- Storage: `~/.claude/orchestration/discarded-alternatives/`
- Auto-tag by domain: `auth`, `performance`, `security`, `architecture`, etc.

### Step 4: Context Replay

When orchestrator encounters similar decision point:
1. Query discarded alternatives for relevant domain
2. Include top 3 alternatives in new agent prompt (as "past considerations")
3. Log: whether alternative would have won with new context

## Expected Output
- `lib/consensus-vote.sh` — weighted voting logic
- `lib/discarded-alternatives.sh` — alternative store & query
- `bin/consensus-trigger.sh` — trigger + resolution script
- Updated audit log schema with consensus events

## Constraints
- Max 3 alternatives per decision stored (keep most recent)
- Alternatives auto-expire after 30 days
- Threshold for tie-break is configurable via `CONSENSUS_TIE_THRESHOLD` env var
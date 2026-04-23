---
id: provenance-chains-impl
agent: copilot
timeout: 240
priority: medium
---

# Task: Provenance Chains

## Objective
Implement tracking of every file's origin: which agent drafted it, reasoning at time of creation, rejected alternatives. Commit messages include provenance. git-blame style tool reconstructs decision lineage.

## Scope
- New file: `lib/provenance-tracker.sh`
- New file: `bin/provenance-commit.sh`
- New file: `bin/provenance-blame.sh`
- New file: `bin/provenance-query.sh`
- Storage: `~/.claude/orchestration/provenance/`

## Instructions

### Step 1: Provenance Schema

Create `lib/provenance-tracker.sh` with functions:
- `provenance_record(file, agent, reasoning, alternatives[])` — record file origin
- `provenance_query(file)` — retrieve provenance for file
- `provenance_link(commit_sha)` — link commit to provenance record

Schema per record:
```json
{
  "file": "bin/task-dispatch.sh",
  "primary_agent": "copilot",
  "session_id": "session-xxx",
  "created_at": "2026-04-22T10:00:00Z",
  "reasoning": "Expanded tier routing to handle TIER_MICRO with direct exec",
  "alternatives_considered": [
    {
      "approach": "use external classifier API",
      "rejected_reason": "external dependency, latency, cost",
      "rejected_by": "architect"
    }
  ],
  "prompts_used": [
    {
      "prompt": "...",
      "agent": "gemini-fast",
      "output": "design spec"
    }
  ],
  "files_modified": ["bin/task-dispatch.sh"],
  "tests_added": ["tests/test-triage.sh"]
}
```

### Step 2: Provenance-Aware Commit

Create `bin/provenance-commit.sh`:
1. Run before `git commit`
2. For each staged file, query provenance tracker
3. Generate extended commit message with provenance footer:
   ```
   ## Provenance
   - Drafted by: copilot (session xxx)
   - Reasoning: expanded tier routing logic
   - Alternatives rejected:
     - External classifier API (rejected: dependency cost)
   - Agents consulted: gemini (design), copilot (impl)
   ```
4. Append to commit message automatically
5. Store provenance record linked to commit SHA

### Step 3: Provenance Blame Tool

Create `bin/provenance-blame.sh`:
```bash
./bin/provenance-blame.sh bin/task-dispatch.sh
```
Output:
```
bin/task-dispatch.sh:15-47  (tier routing logic)
  Agent: copilot | Session: sess-123 | 2026-04-22
  Reasoning: Added tier-aware routing based on classify-tokens.sh output
  Alternatives: [inline classifier] rejected (too complex)

bin/task-dispatch.sh:48-92  (speculation hooks)
  Agent: gemini-fast | Session: sess-124 | 2026-04-22
  Reasoning: Integrated speculation buffer for parallel agent state
  Alternatives: [async-only] rejected (insufficient consistency)
```

### Step 4: Provenance Query Tool

Create `bin/provenance-query.sh`:
1. `provenance-query.sh --agent <name>` — all files drafted by agent
2. `provenance-query.sh --session <id>` — all files from session
3. `provenance-query.sh --file <path>` — full provenance for file
4. `provenance-query.sh --reasoning <keyword>` — files with reasoning matching keyword

### Step 5: Git Integration

Modify `bin/task-dispatch.sh` to:
1. Call `provenance_record()` after each agent completes
2. Pass session ID as env var `PROVENANCE_SESSION_ID`
3. Log file changes with agent attribution

## Expected Output
- `lib/provenance-tracker.sh` — core provenance library
- `bin/provenance-commit.sh` — git commit integration
- `bin/provenance-blame.sh` — blame-style viewer
- `bin/provenance-query.sh` — query CLI
- `~/.claude/orchestration/provenance/` — provenance storage

## Constraints
- Provenance records are append-only (never delete)
- Max 1MB per provenance file (compress older records)
- Privacy: don't store full prompts or file contents
- Git integration is opt-in (disabled by default, enable via `PROVENANCE_ENABLED=true`)
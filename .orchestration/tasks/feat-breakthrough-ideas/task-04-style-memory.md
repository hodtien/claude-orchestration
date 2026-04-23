---
id: style-memory-persist-impl
agent: copilot
timeout: 240
priority: medium
---

# Task: Style Memory Persistence

## Objective
Build a persistent style memory that survives sessions. Agents query at session start, write back inferred style changes at session end. Diff tool surfaces drift between batches.

## Scope
- New file: `lib/style-memory.sh`
- New file: `bin/style-memory-query.sh`
- New file: `bin/style-memory-sync.sh`
- New file: `bin/style-diff.sh`
- Storage directory: `~/.claude/orchestration/style-memory/`

## Instructions

### Step 1: Style Memory Schema

Create `lib/style-memory.sh` with functions:
- `style_memory_init()` — load or create style memory file
- `style_memory_write(key, value)` — persist convention
- `style_memory_read(key)` — retrieve convention
- `style_memory_merge(entries[])` — batch merge from multiple agents

Schema per entry:
```json
{
  "key": "naming.convention.function",
  "value": "camelCase with action prefix (e.g., fetchUserById)",
  "source": "copilot|gemini|claude",
  "confidence": 0.9,
  "file_pattern": "**/*.sh",
  "first_observed": "2026-04-22",
  "last_confirmed": "2026-04-22",
  "confirmation_count": 5
}
```

### Step 2: Session Query Tool

Create `bin/style-memory-query.sh`:
1. Takes project path as argument
2. Reads `style-memory.json` for this project
3. Outputs relevant conventions as shell exports:
   ```bash
   export STYLE_NAMING_CONVENTION="camelCase"
   export STYLE_ERROR_HANDLING="explicit-errors-only"
   export STYLE_COMMENT_POLICY="no-obvious-comments"
   ```
4. Called at session start → injects into agent environment

### Step 3: Session Sync Tool

Create `bin/style-memory-sync.sh`:
1. After each batch completes, analyze modified files
2. Inferred conventions: naming patterns, patterns observed, guardrails
3. Compare against existing style memory
4. Write new/updated entries
5. Log: `style_memory_sync.log` with changes made

### Step 4: Drift Diff Tool

Create `bin/style-diff.sh`:
1. Takes two batch IDs as arguments
2. Compares style memory state between batches
3. Output: markdown report of drift:
   - New conventions added
   - Conventions modified
   - Conventions that disappeared
4. Flag high-drift areas (>30% change in domain)

## Expected Output
- `lib/style-memory.sh` — core style memory library
- `bin/style-memory-query.sh` — session start query
- `bin/style-memory-sync.sh` — session end sync
- `bin/style-diff.sh` — batch-to-batch drift analysis
- `style-memory.json` in project orchestration dir (gitignored)

## Constraints
- Style memory is per-project, not global
- Max 500 entries per project (LRU eviction for oldest/lowest-confidence)
- Privacy: do not store file content, only patterns
- Drift threshold configurable via `STYLE_DRIFT_THRESHOLD` env var (default 0.3)
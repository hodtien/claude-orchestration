---
id: context-compression
agent: copilot
timeout: 180
priority: medium
---

# Task: Context Compression Engine

## Objective
Automatically compress old context to fit more in window. Handle larger batches without context overflow.

## Scope
- New file: `lib/context-compressor.sh`
- New file: `bin/compress-context.sh`
- Modified: `bin/task-dispatch.sh`

## Instructions

### Step 1: Compression Library

Create `lib/context-compressor.sh`:
- `compress_summary(content)` — generate summary of content
- `compress_extract_decisions(content)` — extract key decisions
- `compress_extract_artifacts(content)` — extract artifact references
- `compress_archive(old_content)` — archive for later retrieval

Compression levels:
```bash
LEVEL_LIGHT=0.3   # Keep 30% (summaries)
LEVEL_MEDIUM=0.5 # Keep 50% (key decisions)
LEVEL_HEAVY=0.7  # Keep 70% (most content)
```

### Step 2: Priority System

Define preservation priority:
1. **Recent** — newer content > older
2. **Important** — decisions, artifacts, errors > logs
3. **Relevant** — current batch context > historical

Priority weights:
```bash
PRIORITY_RECENT=3.0
PRIORITY_DECISION=2.5
PRIORITY_ARTIFACT=2.0
PRIORITY_LOG=0.5
```

### Step 3: Compression Trigger

Create `bin/compress-context.sh`:
1. Monitor context usage per session
2. When >70% full, trigger compression
3. Select content to compress based on priority
4. Generate compressed summary
5. Store original for retrieval

Output:
```bash
context-cache/<session>/compressed/
  summary.json      # Compressed summary
  archive/         # Original content (for retrieval)
```

### Step 4: Retrieval

Implement retrieval for archived content:
- `retrieve_archive(key)` — get original content
- `search_archive(query)` — search archived content
- `reconstruct_context()` — rebuild context from compressed

### Step 5: Integration

Modify `bin/task-dispatch.sh`:
1. Track context usage per agent call
2. Call compression when threshold reached
3. Pass compressed context to next agent

## Expected Output
- `lib/context-compressor.sh` — compression logic
- `bin/compress-context.sh` — executable compressor
- `context-cache/<session>/compressed/` — compressed archives
- Modified `bin/task-dispatch.sh` — trigger integration

## Constraints
- Never compress security-related content
- Always archive before compressing (retrievable)
- Max compression ratio: 5x (prevent excessive loss)
- Track compression ratio for learning
---
id: cross-project
agent: copilot
timeout: 180
priority: low
---

# Task: Cross-Project Context Transfer

## Objective
Share learnings and patterns between different projects. Enable faster onboarding for new projects.

## Scope
- New file: `lib/cross-project.sh`
- New file: `bin/share-learnings.sh`
- New file: `bin/transfer-context.sh`
- Directory: `$HOME/.claude/orchestration/shared/`

## Instructions

### Step 1: Shared Learnings Store

Create `$HOME/.claude/orchestration/shared/` structure:
```
shared/
  patterns/           # Reusable patterns
    naming.json
    error-handling.json
    architecture.json
  task-specs/        # Successful task specs by type
  style-memory/      # Shared style conventions
  privacy-rules.json  # What can be shared
```

Privacy rules:
```json
{
  "share": ["naming", "patterns", "architecture"],
  "dont_share": ["credentials", "api_keys", "business_logic"],
  "anonymize": ["file_paths", "company_names"]
}
```

### Step 2: Pattern Extraction

Create `lib/cross-project.sh`:
- `share_extract_pattern(project, pattern_type)` — extract reusable pattern
- `share_import_pattern(source_project, pattern_type)` — import pattern
- `share_suggest_patterns(project)` — suggest patterns for project

### Step 3: Context Transfer

Create `bin/transfer-context.sh`:
1. Takes source project + target project as input
2. Identifies transferable context:
   - Tech stack matches
   - Similar task patterns
   - Common conventions
3. Transfers:
   - Style memory
   - Successful task specs
   - Learnings
4. Adapts to target project context

### Step 4: Project Similarity

Create `bin/share-learnings.sh`:
1. Analyze project similarities
2. Suggest knowledge transfer opportunities
3. Show overlap between projects

Output:
```
# Knowledge Transfer Opportunities

Project: my-new-project
Similar projects:
  - claude-orchestration (85% match)
  - my-other-project (62% match)

Transferable:
  ✓ Shell script patterns
  ✓ Error handling conventions
  ✓ Test structure

Not transferable:
  ✗ Python-specific patterns
  ✗ Business logic
```

## Expected Output
- `lib/cross-project.sh` — sharing logic
- `bin/share-learnings.sh` — project analyzer
- `bin/transfer-context.sh` — context transfer
- `$HOME/.claude/orchestration/shared/` — shared knowledge

## Constraints
- Respect privacy rules (never share secrets)
- Anonymize before sharing
- Allow opt-in/opt-out per project
- Version shared patterns
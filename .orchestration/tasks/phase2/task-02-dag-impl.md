---
id: phase2-02-dag-impl
agent: copilot
reviewer: ""
timeout: 360
retries: 1
priority: high
deadline: ""
context_cache: []
context_from: [phase2-01-dag-design]
depends_on: [phase2-01-dag-design]
task_type: code
output_format: code
---

# Task: Implement Task DAG Visualization (`bin/task-dag.sh`)

## Objective
Implement `bin/task-dag.sh` based on the design provided in context. This script reads task spec files from a batch directory and renders an ASCII or Mermaid dependency graph.

## Context
The orchestration system is at `/Users/hodtien/claude-orchestration/`.

The design document is injected above as context from `phase2-01-dag-design`.

Task spec format (YAML frontmatter markdown):
```yaml
---
id: task-01
agent: copilot
depends_on: [task-02, task-03]
context_from: [task-04]
priority: high
---
```

Existing parsing utilities in `bin/task-dispatch.sh`:
- `parse_front <file> <key> [default]` u2014 reads a scalar YAML frontmatter value
- `parse_list <file> <key>` u2014 reads a YAML list value (returns space-separated)
- These use Python3 internally

You can reuse the same Python-based parsing approach.

## Deliverables

### `bin/task-dag.sh`
```
Usage:
  task-dag.sh <batch-dir>              # ASCII DAG
  task-dag.sh <batch-dir> --mermaid    # Mermaid diagram
  task-dag.sh <batch-dir> --critical-path  # highlight critical path only
  task-dag.sh <batch-dir> --json       # JSON adjacency list (machine-readable)
```

The script must:
1. Read all `task-*.md` files in batch-dir
2. Parse `id`, `agent`, `depends_on`, `priority` from each
3. Build adjacency graph in Python
4. Detect and warn on cycles (but don't exit u2014 still render what's possible)
5. Compute:
   - **Topological levels** (parallel groups): tasks at depth 0 run first, depth 1 after, etc.
   - **Critical path**: longest chain from root to leaf
6. Render ASCII or Mermaid based on flag
7. Show summary line: total tasks, parallel groups, critical path length

ASCII output must work on standard 80-col terminals.
Mermaid output must be valid `graph LR` syntax.

## Implementation Notes
- Use a single Python3 heredoc for the core algorithm (same pattern as existing dispatch scripts)
- Bash handles arg parsing + file finding; Python handles the graph logic + rendering
- Make executable: `chmod +x bin/task-dag.sh`
- Handle empty batch dir gracefully
- Handle tasks with no deps (roots) and tasks with no dependents (leaves)
- Keep under 200 lines

## Expected Output
Write: `/Users/hodtien/claude-orchestration/bin/task-dag.sh`

Test it against the existing phase1 batch:
```bash
bin/task-dag.sh .orchestration/tasks/phase1/
bin/task-dag.sh .orchestration/tasks/phase1/ --mermaid
```

Report: what was written, test output.
